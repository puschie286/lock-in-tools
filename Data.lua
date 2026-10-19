local _, addon = ...
local PREFIX, MAX_MESSAGE_BYTES = "LockInToolsData", 255
local RETRY_DELAYS = { 2, 4, 8, 8 }
local TERMINAL_NOTICES = {
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

local function ValidFeature(feature)
    return type(feature) == "string" and #feature <= 32 and feature:match("^[a-z][a-z0-9_-]*$")
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

local function Wanted(self)
    local state = self.dataState
    return self.initialized and self.ready and not self.savedDataReadOnly and self:HasGroup()
        and state.wanted and not state.paused and not state.failed and not state.stopped
        and (not state.send or state.send == state.nativeSend)
end

local function Refresh(self)
    if self.RefreshOptions then self:RefreshOptions() end
end

local function Disconnect(self)
    if self.dataState.send then self:SetDataTransport(nil) end
end

function addon:GetDataPrefix()
    return PREFIX
end

function addon:InitializeData()
    if self.dataState then return end
    self.dataState = { features = {}, phase = "idle", attempts = 0, generation = 0,
        channelName = self:GetGroupDataChannelName() }
    self.dataFrame = CreateFrame("Frame")
    for _, event in ipairs({ "CHAT_MSG_ADDON", "PLAYER_ENTERING_WORLD", "CHANNEL_UI_UPDATE",
        "CHANNEL_LEFT", "CHAT_MSG_CHANNEL_NOTICE", "CHANNEL_PASSWORD_REQUEST", "PLAYER_LOGOUT" }) do
        self.dataFrame:RegisterEvent(event)
    end
    self.dataFrame:SetScript("OnEvent", function(_, event, ...) self:OnDataEvent(event, ...) end)
end

function addon:IsDataConnected()
    local state = self.dataState
    return state ~= nil and self.initialized == true and self.ready == true and not self.savedDataReadOnly
        and self:HasGroup() and state.send ~= nil and state.groupFingerprint == self:GetGroupFingerprint()
end

local function NotifyConnection(self)
    local connected = self:IsDataConnected()
    for _, feature in pairs(self.dataState.features) do
        if feature.connectionChanged then pcall(feature.connectionChanged, connected) end
    end
end

function addon:RegisterDataFeature(name, receive, connectionChanged)
    local state = self.dataState
    if not state then return false, "Group data is still loading." end
    if not ValidFeature(name) or type(receive) ~= "function"
        or (connectionChanged ~= nil and type(connectionChanged) ~= "function") then
        return false, "Invalid data feature registration."
    end
    if state.features[name] then return false, "Data feature already registered." end
    state.features[name] = { receive = receive, connectionChanged = connectionChanged }
    if connectionChanged then pcall(connectionChanged, self:IsDataConnected()) end
    return true
end

-- Features share this transport boundary; native acceptance is not a peer receipt.
function addon:SetDataTransport(send)
    local state = self.dataState
    if not state then return false, "Group data is still loading." end
    if send ~= nil and type(send) ~= "function" then return false, "Invalid data connection." end
    if send and (self.savedDataReadOnly or not self:HasGroup()) then
        return false, "A writable group configuration is required."
    end
    state.send = send
    state.groupFingerprint = send and self:GetGroupFingerprint() or nil
    NotifyConnection(self)
    return true
end

function addon:OnDataLogin()
    local state = self.dataState
    NotifyConnection(self)
    if self.savedDataReadOnly then return end
    state.nativeStarted = true
    state.wanted = self:HasGroup()
    if state.wanted then self:JoinDataChannel(false) end
end

function addon:OnDataGroupChanged()
    local state = self.dataState
    if not state then return end
    self:CancelDataTimer()
    Disconnect(self)
    local previous = state.channelName
    state.channelName = self:GetGroupDataChannelName()
    state.nativeSend = nil
    state.phase, state.detail = "idle", nil
    state.attempts, state.pending, state.paused, state.failed = 0, false, false, false
    state.wanted = self:HasGroup() and not self.savedDataReadOnly
    if previous and type(LeaveChannelByName) == "function" then pcall(LeaveChannelByName, previous) end
    -- Group.lua must finish clearing old feature data before a new connection can dispatch.
    if state.nativeStarted and Wanted(self) then self:ScheduleDataCheck(1) end
    Refresh(self)
end

function addon:CancelDataTimer()
    local state = self.dataState
    state.generation = state.generation + 1
    if state.timer then state.timer:Cancel(); state.timer = nil end
end

function addon:ScheduleDataCheck(delay)
    self:CancelDataTimer()
    local state = self.dataState
    local generation = state.generation
    state.timer = C_Timer.NewTimer(delay, function()
        if state.generation ~= generation then return end
        state.timer = nil
        if Wanted(self) then self:JoinDataChannel(false) end
    end)
end

function addon:FailDataJoin(detail)
    self:CancelDataTimer()
    local state = self.dataState
    Disconnect(self)
    state.failed, state.pending, state.wanted = true, false, false
    state.phase, state.detail = "error", detail
    Refresh(self)
    return false
end

function addon:ConfirmDataMembership()
    local state = self.dataState
    if not Wanted(self) then return false end
    local name = self:GetGroupDataChannelName()
    if not state.prefixRegistered or not ChannelID(name) then return false end
    if state.phase == "joined" and state.send == state.nativeSend then return true end
    self:CancelDataTimer()
    state.channelName = name
    state.attempts, state.pending = 0, false
    state.phase, state.detail = "joined", nil
    local fingerprint = self:GetGroupFingerprint()
    local send
    send = function(prefix, message)
        if not Wanted(self) or state.send ~= send or self:GetGroupFingerprint() ~= fingerprint
            or self:GetGroupDataChannelName() ~= name then return false end
        local id = ChannelID(name)
        if not id then
            Disconnect(self)
            state.phase, state.attempts = "joining", 0
            if not state.timer then self:ScheduleDataCheck(1) end
            Refresh(self)
            return false
        end
        -- Resolve local channel numbers for every send; no queue and no whisper fallback.
        local ok, result = pcall(C_ChatInfo.SendAddonMessage, prefix, message, "CHANNEL", tostring(id))
        return ok and not IsSecret(result) and result == Enum.SendAddonMessageResult.Success
    end
    state.nativeSend = send
    self:SetDataTransport(send)
    Refresh(self)
    return true
end

function addon:JoinDataChannel(manual)
    local state = self.dataState
    if not state or not self.ready then return false, "Still loading. Please try again after login." end
    if self.savedDataReadOnly then return false, "Saved preferences are read-only." end
    if not self:HasGroup() then return false, "Join a LockInTools group first." end
    state.nativeStarted = true
    if manual then
        self:CancelDataTimer()
        state.paused, state.failed, state.stopped = false, false, false
        state.attempts, state.wanted = 0, true
    end
    if not Wanted(self) then return false end
    state.channelName = self:GetGroupDataChannelName()
    if not C_ChatInfo or type(C_ChatInfo.RegisterAddonMessagePrefix) ~= "function"
        or type(C_ChatInfo.SendAddonMessage) ~= "function" or type(JoinTemporaryChannel) ~= "function"
        or not Enum or not Enum.RegisterAddonMessagePrefixResult or not Enum.SendAddonMessageResult then
        return self:FailDataJoin("The native group-data API is unavailable.")
    end
    if not state.prefixRegistered then
        local ok, result = pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
        local results = Enum.RegisterAddonMessagePrefixResult
        if not ok or IsSecret(result) or (result ~= results.Success and result ~= results.DuplicatePrefix) then
            return self:FailDataJoin("Could not register group-data messages.")
        end
        state.prefixRegistered = true
    end
    if self:ConfirmDataMembership() then return true end
    if state.attempts >= #RETRY_DELAYS then
        return self:FailDataJoin("Could not join the group data channel.")
    end
    state.attempts = state.attempts + 1
    state.pending, state.phase, state.detail = true, "joining", nil
    local ok = pcall(JoinTemporaryChannel, state.channelName, self:GetGroupDataChannelPassword())
    if not ok then return self:FailDataJoin("The data-channel join request failed.") end
    if Wanted(self) and not self:ConfirmDataMembership() then
        self:ScheduleDataCheck(RETRY_DELAYS[state.attempts])
    end
    Refresh(self)
    return not state.failed
end

function addon:LeaveDataChannel()
    local state = self.dataState
    if not state or not self.ready then return false, "Still loading. Please try again after login." end
    if self.savedDataReadOnly then return false, "Saved preferences are read-only." end
    self:CancelDataTimer()
    state.wanted, state.paused, state.pending, state.failed = false, true, false, false
    state.phase, state.detail = "paused", nil
    Disconnect(self)
    local name = self:GetGroupDataChannelName()
    if name and type(LeaveChannelByName) == "function" then pcall(LeaveChannelByName, name) end
    Refresh(self)
    return true
end

function addon:OnDataEvent(event, ...)
    local state = self.dataState
    if event == "PLAYER_LOGOUT" then
        self:CancelDataTimer()
        state.stopped, state.wanted = true, false
        Disconnect(self)
        return
    end
    if not self.ready or self.savedDataReadOnly or not self:HasGroup()
        or (state.send and state.send ~= state.nativeSend) then return end
    local name = self:GetGroupDataChannelName()
    if event == "CHAT_MSG_ADDON" then
        local prefix, message, distribution, sender, _, _, localID, channelName = ...
        if IsSecret(prefix) or IsSecret(distribution) or prefix ~= PREFIX or distribution ~= "CHANNEL"
            or state.send ~= state.nativeSend or not self:IsDataConnected() then return end
        local currentID = ChannelID(name)
        if not currentID or IsSecret(localID) or IsSecret(channelName) then return end
        if type(localID) == "number" and localID > 0 then
            if localID ~= currentID then return end
        elseif not SameChannel(channelName, name) then return end
        return self:ReceiveData(sender, message)
    elseif event == "CHANNEL_LEFT" or event == "CHAT_MSG_CHANNEL_NOTICE" then
        local reason, noticeName
        if event == "CHANNEL_LEFT" then reason, noticeName = "YOU_LEFT", select(2, ...)
        else reason, noticeName = ..., select(9, ...) end
        if not SameChannel(noticeName, name) or IsSecret(reason) then return end
        if TERMINAL_NOTICES[reason] then
            self:FailDataJoin(TERMINAL_NOTICES[reason])
        elseif reason == "YOU_LEFT" then
            -- Native membership can remain cached until the next UI event.
            self:CancelDataTimer()
            state.paused, state.pending, state.wanted = true, false, false
            Disconnect(self)
            if not state.failed then state.phase, state.detail = "paused", nil end
            Refresh(self)
        elseif reason == "YOU_JOINED" or reason == "YOU_CHANGED" then
            if ChannelID(name) then state.paused, state.failed, state.wanted = false, false, true end
            self:ConfirmDataMembership()
        end
    elseif event == "CHANNEL_PASSWORD_REQUEST" then
        local requestedName = ...
        if state.pending and SameChannel(requestedName, name) then
            self:FailDataJoin(TERMINAL_NOTICES.WRONG_PASSWORD)
        end
    elseif event == "CHANNEL_UI_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        if not Wanted(self) then return end
        if not self:ConfirmDataMembership() then
            Disconnect(self)
            if not state.timer then
                if state.phase == "joined" then state.attempts = 0 end
                state.phase = "joining"
                self:ScheduleDataCheck(1)
                Refresh(self)
            end
        end
    end
end

function addon:SendData(feature, payload)
    if not self:IsDataConnected() then return false, "Group data is disconnected." end
    if not ValidFeature(feature) or not self.dataState.features[feature] then
        return false, "Unknown data feature."
    end
    if IsSecret(payload) or type(payload) ~= "string" then return false, "Invalid data payload." end
    local message = "1|" .. feature .. "|" .. payload
    if #message > MAX_MESSAGE_BYTES or message:find("\000", 1, true) then
        return false, "Data message exceeds the supported format."
    end
    -- No queue or automatic retry: each feature decides when its data is current.
    local ok, accepted = pcall(self.dataState.send, PREFIX, message)
    if not ok or accepted ~= true then return false, "Data message was not accepted." end
    return true
end

-- The backend supplies WoW's sender after matching our prefix and current group route.
function addon:ReceiveData(sender, message)
    if not self:IsDataConnected() or IsSecret(sender) or type(sender) ~= "string" or sender == ""
        or IsSecret(message) or type(message) ~= "string" or #message > MAX_MESSAGE_BYTES
        or message:find("\000", 1, true) then return false end
    local feature, payload = message:match("^1|([a-z][a-z0-9_-]*)|(.*)$")
    if not feature or not ValidFeature(feature) then return false end
    local registration = self.dataState.features[feature]
    if not registration then return false end
    local ok, accepted = pcall(registration.receive, sender, payload)
    return ok and accepted ~= false
end

function addon:GetDataStatusText()
    if not self.dataState then return "Still loading." end
    if self.savedDataReadOnly then return "Saved preferences are read-only." end
    if not self:HasGroup() then return "No group configured." end
    local state = self.dataState
    local name = self:GetGroupDataChannelName()
    local label = self.GetChannelDisplayName and self:GetChannelDisplayName(name) or "LockInTools Data"
    if self:IsDataConnected() then return "Joined " .. label .. "; channel broadcasts within this internal realm." end
    if state.phase == "joining" then return "Joining " .. label .. "..." end
    if state.phase == "error" then return (state.detail or "Group data is unavailable.") .. " Use /lit data join to retry." end
    if state.phase == "paused" then return "Group data left. Use /lit data join to reconnect." end
    return label .. " is configured; waiting for a group connection."
end
