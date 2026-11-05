local _, addon = ...

-- Guild and party/raid membership define the audience for native addon data.
local CHANNEL_OPTIONS = { party = true, guild = true }
local PREFIX_RETRY_DELAY = 30

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function NativeMembership(api)
    if type(api) ~= "function" then return false end
    local ok, member = pcall(api)
    return ok and not IsSecret(member) and member == true
end

local function CanUseData(self)
    return self.initialized == true and self.ready == true and not self.savedDataReadOnly
        and not self.dataState.stopped
end

local function Enabled(self)
    return self:GetDataChannelEnabled("party") or self:GetDataChannelEnabled("guild")
end

function addon:GetDataChannelEnabled(channel)
    if IsSecret(channel) or type(channel) ~= "string" or not CHANNEL_OPTIONS[channel] then return false end
    local database = self.savedDataReadOnly and type(LockInToolsDB) == "table" and LockInToolsDB or self.db
    local settings = type(database) == "table" and database.data
    local channels = type(settings) == "table" and settings.channels
    return type(channels) ~= "table" or channels[channel] ~= false
end

function addon:HasGuild()
    return NativeMembership(IsInGuild)
end

function addon:HasDataGroup()
    return (self:GetDataChannelEnabled("guild") and self:HasGuild())
        or (self:GetDataChannelEnabled("party") and (NativeMembership(IsInRaid) or NativeMembership(IsInGroup)))
end

function addon:InitializeDataChannel()
    local state = self.dataState
    state.routes = {}
    local prefixResults = Enum and Enum.RegisterAddonMessagePrefixResult
    local sendResults = Enum and Enum.SendAddonMessageResult
    state.nativeAvailable = C_ChatInfo and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function"
        and type(C_ChatInfo.SendAddonMessage) == "function" and prefixResults and sendResults
        and prefixResults.Success ~= nil and prefixResults.DuplicatePrefix ~= nil and sendResults.Success ~= nil
        or false
    self.dataEvents = self:RegisterGameEvents({ "CHAT_MSG_ADDON", "PLAYER_ENTERING_WORLD",
        "GROUP_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "PLAYER_LOGOUT" }, self.OnDataEvent)
end

function addon:IsDataConnected()
    local state = self.dataState
    return state ~= nil and CanUseData(self) and state.connected
end

function addon:RefreshDataRoutes()
    local state, routes = self.dataState, {}
    if CanUseData(self) and state.nativeStarted and state.nativeAvailable and state.prefixRegistered then
        if self:GetDataChannelEnabled("party") then
            if NativeMembership(IsInRaid) then routes.RAID = true
            elseif NativeMembership(IsInGroup) then routes.PARTY = true end
        end
        if self:GetDataChannelEnabled("guild") and self:HasGuild() then routes.GUILD = true end
    end
    local previous, connected = state.routes, state.connected
    state.routes = routes
    for distribution in pairs(state.sendFailures) do
        if not routes[distribution] then state.sendFailures[distribution] = nil end
    end
    -- Keep sessions and request caches while any existing route remains active.
    self:SetDataConnected(next(routes) ~= nil)
    if connected and state.connected and self.RequestDataStatusSnapshot then
        for distribution in pairs(routes) do
            if not previous[distribution] then self:RequestDataStatusSnapshot(); break end
        end
    end
    return routes
end

function addon:CancelDataTimer()
    local state = self.dataState
    if state.timer then state.timer:Cancel(); state.timer = nil end
end

function addon:StartDataMessages()
    local state = self.dataState
    if state and CanUseData(self) and state.nativeStarted then
        self:CancelDataTimer()
        state.detail = nil
        if Enabled(self) then
            if not state.nativeAvailable then
                state.detail = "The native group-data API is unavailable."
            elseif not state.prefixRegistered then
                local ok, result = pcall(C_ChatInfo.RegisterAddonMessagePrefix, self:GetDataPrefix())
                local results = Enum.RegisterAddonMessagePrefixResult
                if ok and not IsSecret(result) and (result == results.Success or result == results.DuplicatePrefix) then
                    state.prefixRegistered = true
                else
                    state.detail = "Could not register group-data messages. Retrying automatically."
                    state.timer = C_Timer.NewTimer(PREFIX_RETRY_DELAY, function()
                        state.timer = nil
                        self:StartDataMessages()
                    end)
                end
            end
        end
        self:RefreshDataRoutes()
    end
    self:Notify("DATA_CHANGED")
end

function addon:SetDataChannelEnabled(channel, enabled)
    if not self.initialized or type(self.db) ~= "table" then return false, "Still loading. Please try again after login." end
    if self.savedDataReadOnly then return false, "Saved preferences are read-only." end
    if IsSecret(channel) or type(channel) ~= "string" or not CHANNEL_OPTIONS[channel]
        or IsSecret(enabled) or type(enabled) ~= "boolean" then return false, "Choose a data channel and on or off." end
    local previous = self:GetDataChannelEnabled(channel)
    if type(self.db.data) ~= "table" then self.db.data = {} end
    if type(self.db.data.channels) ~= "table" then self.db.data.channels = {} end
    self.db.data.channels[channel] = enabled
    if previous == enabled then return true end
    self:StartDataMessages()
    return true
end

function addon:OnDataLogin()
    self:NotifyDataConnection()
    self.dataState.nativeStarted = true
    self:StartDataMessages()
end

function addon:OnDataEvent(event, ...)
    local state = self.dataState
    if event == "PLAYER_LOGOUT" then
        self:CancelDataTimer()
        state.stopped, state.routes, state.sendFailures = true, {}, {}
        self:SetDataConnected(false)
        return
    end
    if not CanUseData(self) then return end
    if event == "CHAT_MSG_ADDON" then
        local prefix, message, distribution, sender = ...
        if prefix ~= self:GetDataPrefix() or not self:IsDataConnected() or not state.routes[distribution] then return end
        return self:OnDataMessage(sender, message)
    else
        self:RefreshDataRoutes()
        self:Notify("DATA_CHANGED")
    end
end

function addon:GetDataStatusText()
    if not self.dataState then return "Still loading." end
    if self.savedDataReadOnly then return "Saved preferences are read-only." end
    if not Enabled(self) then return "All data channels are disabled." end
    local state, routes = self.dataState, {}
    if state.routes.PARTY then routes[#routes + 1] = "party" end
    if state.routes.RAID then routes[#routes + 1] = "raid" end
    if state.routes.GUILD then routes[#routes + 1] = "guild" end
    if #routes == 0 then return state.detail or "Waiting for an enabled party, raid or guild membership." end
    local status = "Data routes: " .. table.concat(routes, ", ") .. "."
    local failures = self:GetDataSendStatusText()
    return failures ~= "" and (status .. " " .. failures) or status
end
