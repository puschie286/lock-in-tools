local _, addon = ...

-- Guild and party/raid data routes are always used when available; the custom
-- global channel is an additional route. CHANNEL remains realm/faction limited.
-- Packets have no group filter or authentication on the shared native routes.
local RETRY_DELAYS = { 2, 4, 8, 8, 30 }
local CONNECTION_CHECK_INTERVAL, FAILURE_RETRY_DELAY = 15, 30
local LEAVE_CACHE_CHECK_LIMIT = 5
local FAILURE_NOTICES = {
    WRONG_PASSWORD = "The data-channel password was rejected.",
    BANNED = "You are banned from the data channel.",
    YOU_KICKED = "You were removed from the data channel.",
    INVALID_NAME = "WoW rejected the data-channel name.",
    CHANNEL_FULL = "The data channel is full.",
    TOO_MANY_CHANNELS = "Leave another channel before joining group data.",
    THROTTLED = "WoW is limiting channel requests.",
    RESTRICTED = "Your account cannot join the data channel.",
}

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function SameChannel(first, second)
    return not IsSecret(first) and not IsSecret(second)
        and type(first) == "string" and type(second) == "string" and first:lower() == second:lower()
end

local function ChannelID(name)
    if not name or type(GetChannelName) ~= "function" then return nil end
    local ok, id = pcall(GetChannelName, name)
    if ok and not IsSecret(id) and type(id) == "number" and id > 0 then return id end
end

local function NativeMembership(api)
    if type(api) ~= "function" then return false end
    local ok, member = pcall(api)
    return ok and not IsSecret(member) and member == true
end

local function CanUseData(self)
    return self.initialized == true and self.ready == true and not self.savedDataReadOnly and self:HasGroup()
        and not self:IsGroupSwitching() and not self.dataState.stopped
end

local function Wanted(self)
    return CanUseData(self) and self.dataState.wanted
end

local function Refresh(self)
    self:Notify("DATA_CHANGED")
end

function addon:InitializeDataChannel()
    self:InitializeGroupChannelCleanup()
    local state = self.dataState
    state.phase, state.attempts = "idle", 0
    state.routes, state.channelConnected = {}, false
    local prefixResults = Enum and Enum.RegisterAddonMessagePrefixResult
    local sendResults = Enum and Enum.SendAddonMessageResult
    -- Native capabilities are stable for this UI session; retry connection
    -- failures without probing API availability again.
    state.nativeAvailable = C_ChatInfo and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function"
        and type(C_ChatInfo.SendAddonMessage) == "function" and prefixResults and sendResults
        and prefixResults.Success ~= nil and prefixResults.DuplicatePrefix ~= nil and sendResults.Success ~= nil
        or false
    state.channelAvailable = state.nativeAvailable and type(JoinTemporaryChannel) == "function"
        and type(GetChannelName) == "function"
    self.dataEvents = self:RegisterGameEvents({ "CHAT_MSG_ADDON", "PLAYER_ENTERING_WORLD", "CHANNEL_UI_UPDATE",
        "CHANNEL_LEFT", "CHAT_MSG_CHANNEL_NOTICE", "CHANNEL_PASSWORD_REQUEST", "GROUP_ROSTER_UPDATE",
        "PLAYER_GUILD_UPDATE", "PLAYER_LOGOUT" }, self.OnDataEvent)
end

function addon:IsDataConnected()
    local state = self.dataState
    return state ~= nil and CanUseData(self) and state.connected
end

-- Resolve on every send because native channel numbers can change.
function addon:GetDataChannelID()
    return ChannelID(self:GetGroupDataChannelName())
end

function addon:RefreshDataRoutes()
    local state, routes = self.dataState, {}
    local channelLost = false
    if Wanted(self) and state.nativeStarted and state.nativeAvailable and state.prefixRegistered then
        if NativeMembership(IsInRaid) then routes.RAID = true
        elseif NativeMembership(IsInGroup) then routes.PARTY = true end
        if NativeMembership(IsInGuild) then routes.GUILD = true end
        if state.channelConnected then
            local id = self:GetDataChannelID()
            if id then routes.CHANNEL = tostring(id)
            else
                state.channelConnected = false
                state.phase, state.attempts = "joining", 0
                self:ScheduleDataCheck(1)
                channelLost = true
            end
        end
    end
    local previous, connected = state.routes, state.connected
    state.routes = routes
    -- Changing one route must not clear request caches or reset feature sessions
    -- while another route remains available.
    self:SetDataConnected(next(routes) ~= nil)
    if connected and state.connected and self.RequestDataStatusSnapshot then
        for distribution in pairs(routes) do
            if not previous[distribution] then self:RequestDataStatusSnapshot(); break end
        end
    end
    if channelLost then Refresh(self) end
    return routes
end

function addon:SetDataChannelConnected(connected)
    self.dataState.channelConnected = connected
    self:RefreshDataRoutes()
end

function addon:OnDataLogin()
    local state = self.dataState
    self:NotifyDataConnection()
    state.nativeStarted = true
    -- Status discovery stays active with human chat or position sharing off.
    state.wanted = self:HasGroup()
    if state.wanted then self:JoinDataChannel(false) end
end

function addon:ResetDataForGroupSwitch()
    local state = self.dataState
    if not state then return end
    self:CancelDataTimer()
    state.wanted, state.channelConnected, state.routes = false, false, {}
    self:SetDataConnected(false)
    state.phase, state.detail = "idle", nil
    state.attempts, state.pending, state.failed, state.awaitingLeave = 0, false, false, false
    state.leaveChecks = 0
    Refresh(self)
end

function addon:ResumeDataAfterGroupSwitch()
    local state = self.dataState
    if not state then return end
    state.wanted = self:HasGroup()
    if state.nativeStarted and Wanted(self) then self:JoinDataChannel(false) end
    Refresh(self)
end

function addon:OnDataGroupChanged()
    self:ResetDataForGroupSwitch()
    self:ResumeDataAfterGroupSwitch()
end

function addon:CancelDataTimer()
    local state = self.dataState
    if state.timer then state.timer:Cancel(); state.timer = nil end
end

function addon:ScheduleDataCheck(delay)
    self:CancelDataTimer()
    local state = self.dataState
    state.timer = C_Timer.NewTimer(delay, function()
        state.timer = nil
        if Wanted(self) then self:JoinDataChannel(false) end
    end)
end

function addon:FailDataJoin(detail)
    local state = self.dataState
    -- Repeated notices must not restart or postpone the same cooldown.
    if not state.failed then self:CancelDataTimer() end
    state.failed, state.pending = true, false
    state.phase, state.detail = "error", detail
    self:SetDataChannelConnected(false)
    if Wanted(self) and not state.timer then self:ScheduleDataCheck(FAILURE_RETRY_DELAY) end
    Refresh(self)
    return false
end

function addon:ConfirmDataMembership()
    local state = self.dataState
    if not state.channelAvailable or not Wanted(self) or state.awaitingLeave then return false end
    local name = self:GetGroupDataChannelName()
    if not state.prefixRegistered or not ChannelID(name) then return false end
    if state.channelConnected then
        self:RefreshDataRoutes()
        if not state.timer then self:ScheduleDataCheck(CONNECTION_CHECK_INTERVAL) end
        return true
    end
    self:CancelDataTimer()
    state.attempts, state.pending, state.failed = 0, false, false
    state.phase, state.detail = "joined", nil
    self:SetDataChannelConnected(true)
    self:ScheduleDataCheck(CONNECTION_CHECK_INTERVAL)
    Refresh(self)
    return true
end

function addon:JoinDataChannel(manual)
    local state = self.dataState
    if not state or not self.ready then return false, "Still loading. Please try again after login." end
    if self:IsGroupSwitching() then return false, "Waiting to leave the previous group." end
    if self.savedDataReadOnly then return false, "Saved preferences are read-only." end
    if not self:HasGroup() then return false, "Join a LockInTools group first." end
    state.nativeStarted = true
    if manual then
        self:CancelDataTimer()
        state.failed, state.stopped = false, false
        state.attempts, state.wanted = 0, true
    end
    if not Wanted(self) then return false end
    if not state.nativeAvailable then return self:FailDataJoin("The native group-data API is unavailable.") end
    if not state.prefixRegistered then
        local ok, result = pcall(C_ChatInfo.RegisterAddonMessagePrefix, self:GetDataPrefix())
        local results = Enum.RegisterAddonMessagePrefixResult
        if not ok or IsSecret(result) or (result ~= results.Success and result ~= results.DuplicatePrefix) then
            return self:FailDataJoin("Could not register group-data messages.")
        end
        state.prefixRegistered = true
    end
    self:RefreshDataRoutes()
    -- Connecting a native route invokes feature callbacks, which may switch or
    -- remove the configured group before its global-channel join begins.
    if not Wanted(self) then return false end
    if not state.channelAvailable then return self:FailDataJoin("The global data-channel API is unavailable.") end
    local name = self:GetGroupDataChannelName()
    if state.awaitingLeave then
        -- Native leave notices can arrive before cached membership disappears.
        if ChannelID(name) then
            state.leaveChecks = (state.leaveChecks or 0) + 1
            if state.leaveChecks < LEAVE_CACHE_CHECK_LIMIT then
                if not state.timer then self:ScheduleDataCheck(1) end
                return false
            end
            -- A delayed notice or failed leave must not stall recovery forever.
            state.leaveChecks = 0
            self:LeaveGroupChannel(name)
            if ChannelID(name) then
                self:ScheduleDataCheck(FAILURE_RETRY_DELAY)
                return false
            end
        end
        state.awaitingLeave, state.leaveChecks = false, 0
    end
    state.failed = false
    if self:ConfirmDataMembership() then return true end
    self:SetDataChannelConnected(false)
    state.attempts = math.min(state.attempts + 1, #RETRY_DELAYS)
    state.pending, state.phase, state.detail = true, "joining", nil
    local ok = pcall(JoinTemporaryChannel, name, self:GetGroupDataChannelPassword())
    if not ok then return self:FailDataJoin("The data-channel join request failed.") end
    if Wanted(self) and not state.failed and not self:ConfirmDataMembership() then
        self:ScheduleDataCheck(RETRY_DELAYS[state.attempts])
    end
    Refresh(self)
    return not state.failed
end

function addon:LeaveDataChannel()
    local state = self.dataState
    if not state or not self.ready then return false, "Still loading. Please try again after login." end
    if self:IsGroupSwitching() then return false, "Waiting to leave the previous group." end
    if self.savedDataReadOnly then return false, "Saved preferences are read-only." end
    self:CancelDataTimer()
    state.wanted = self:HasGroup()
    state.pending, state.failed, state.awaitingLeave, state.attempts = false, false, true, 0
    state.leaveChecks = 0
    state.phase, state.detail = "joining", nil
    self:SetDataChannelConnected(false)
    local name = self:GetGroupDataChannelName()
    if name then self:LeaveGroupChannel(name) end
    if Wanted(self) then self:ScheduleDataCheck(1) end
    Refresh(self)
    return true
end

function addon:OnDataEvent(event, ...)
    local state = self.dataState
    if event == "PLAYER_LOGOUT" then
        self:CancelDataTimer()
        state.stopped, state.wanted, state.channelConnected, state.routes = true, false, false, {}
        self:SetDataConnected(false)
        return
    end
    if not CanUseData(self) then return end
    local name = self:GetGroupDataChannelName()
    if event == "CHAT_MSG_ADDON" then
        local prefix, message, distribution, sender = ...
        if prefix ~= self:GetDataPrefix() or not self:IsDataConnected() or not state.routes[distribution] then return end
        return self:OnDataMessage(sender, message)
    elseif event == "CHANNEL_LEFT" or event == "CHAT_MSG_CHANNEL_NOTICE" then
        local reason, noticeName
        if event == "CHANNEL_LEFT" then reason, noticeName = "YOU_LEFT", select(2, ...)
        else reason, noticeName = ..., select(9, ...) end
        if not SameChannel(noticeName, name) or IsSecret(reason) then return end
        if FAILURE_NOTICES[reason] then
            self:FailDataJoin(FAILURE_NOTICES[reason])
        elseif reason == "YOU_LEFT" then
            if state.awaitingLeave then return end
            state.awaitingLeave, state.pending = true, false
            state.leaveChecks = 0
            self:SetDataChannelConnected(false)
            if not state.failed then
                state.phase, state.detail, state.attempts = "joining", nil, 0
                self:ScheduleDataCheck(1)
            end
            Refresh(self)
        elseif reason == "YOU_JOINED" or reason == "YOU_CHANGED" then
            if state.awaitingLeave then return end
            if state.channelAvailable and ChannelID(name) then state.failed, state.wanted = false, true end
            self:ConfirmDataMembership()
        end
    elseif event == "CHANNEL_PASSWORD_REQUEST" then
        local requestedName = ...
        if state.pending and SameChannel(requestedName, name) then
            self:FailDataJoin(FAILURE_NOTICES.WRONG_PASSWORD)
        end
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_GUILD_UPDATE" then
        self:RefreshDataRoutes()
        Refresh(self)
    elseif event == "CHANNEL_UI_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        if not Wanted(self) then return end
        self:RefreshDataRoutes()
        if state.awaitingLeave or state.failed then return end
        if not self:ConfirmDataMembership() then
            self:SetDataChannelConnected(false)
            if state.phase == "joined" or not state.timer then
                if state.phase == "joined" then state.attempts = 0 end
                state.phase = "joining"
                self:ScheduleDataCheck(1)
                Refresh(self)
            end
        end
    end
end

function addon:GetDataStatusText()
    if not self.dataState then return "Still loading." end
    if self.savedDataReadOnly then return "Saved preferences are read-only." end
    if self:IsGroupSwitching() then return "Leaving the previous group before connecting." end
    if not self:HasGroup() then return "No group configured." end
    local state = self.dataState
    local name = self:GetGroupDataChannelName()
    local label = self.GetChannelDisplayName and self:GetChannelDisplayName(name) or "LockInTools Data"
    local routes = {}
    if state.routes.PARTY then routes[#routes + 1] = "party" end
    if state.routes.RAID then routes[#routes + 1] = "raid" end
    if state.routes.GUILD then routes[#routes + 1] = "guild" end
    if state.routes.CHANNEL then routes[#routes + 1] = label end
    local active = #routes > 0 and ("Data routes: " .. table.concat(routes, ", ") .. ". ") or ""
    if state.phase == "joined" then return active .. "Global channel broadcasts within this internal realm." end
    if active ~= "" then
        if state.phase == "error" then return active .. (state.detail or "Global channel unavailable.") .. " Retrying automatically." end
        return active .. "Joining " .. label .. "; reconnecting automatically."
    end
    if state.phase == "joining" then return "Joining " .. label .. "; reconnecting automatically." end
    if state.phase == "error" then return (state.detail or "Group data is unavailable.") .. " Retrying automatically in up to 30 seconds." end
    return label .. " is configured; waiting for a group connection."
end
