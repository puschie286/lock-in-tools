local _, addon = ...
local PREFIX, MAX_MESSAGE_BYTES = "LockInToolsData", 255
local REQUEST_WINDOW, MAX_REQUEST_SEQUENCE = 10, 999999999
local PLAYER_DATA_MAX_AGE, PLAYER_DATA_CLEANUP_INTERVAL = 10 * 86400, 3600

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

function addon:IsDataFrame(message)
    return not IsSecret(message) and type(message) == "string" and #message <= MAX_MESSAGE_BYTES
        and not message:find("\000", 1, true)
end

local function ValidFeature(feature)
    return not IsSecret(feature) and type(feature) == "string" and #feature <= 32
        and feature:match("^[a-z][a-z0-9_-]*$")
end

local function SenderName(self, name)
    local character, realm = name:match("^([^%-]+)%-(.+)$")
    if not character then
        if not self.dataState.nameAPIs.realm then return nil end
        character, realm = name, GetNormalizedRealmName()
        if IsSecret(realm) or type(realm) ~= "string" or realm == "" then return nil end
    end
    return (character .. "-" .. realm:gsub("%s", "")):lower()
end

local function SelfNames(self)
    local names = {}
    local apis = self.dataState.nameAPIs
    if apis.fullName then
        local ok, name, realm = pcall(UnitFullName, "player")
        if ok and not IsSecret(name) and type(name) == "string" and name ~= ""
            and not IsSecret(realm) then
            if type(realm) == "string" and realm ~= "" then name = name .. "-" .. realm end
            local normalized = SenderName(self, name)
            if normalized then names[normalized] = true end
        end
    end
    if apis.unmodifiedFullName then
        local ok, name = pcall(NameUtil.GetUnmodifiedUnitFullName, "player")
        local normalized = ok and not IsSecret(name) and type(name) == "string" and name ~= ""
            and SenderName(self, name)
        if normalized then names[normalized] = true end
    end
    return names
end

local function IsSelfName(self, normalized)
    return normalized ~= nil and SelfNames(self)[normalized] == true
end

function addon:GetDataSenderIdentity(sender)
    local normalized = SenderName(self, sender)
    return normalized, IsSelfName(self, normalized)
end

local function ResetRequests(state)
    state.pendingRequests, state.repliedRequests = {}, {}
end

local function PruneRequests(state)
    local now = GetTime()
    for id, request in pairs(state.pendingRequests) do
        if request.expires <= now then state.pendingRequests[id] = nil end
    end
    for key, expires in pairs(state.repliedRequests) do
        if expires <= now then state.repliedRequests[key] = nil end
    end
    return now
end

local function ValidRequestID(id)
    return id and #id <= 32 and id:match("^[a-zA-Z0-9_-]+$")
end

local function SendFailureReason(ok, result)
    -- Native errors may contain payloads or credentials. Report only the result
    -- enum/code, never the message or the exception returned by pcall.
    if not ok then return "native API error" end
    if IsSecret(result) or type(result) ~= "number" or result ~= result
        or result == math.huge or result == -math.huge then return "native result unavailable" end
    for name, code in pairs(Enum.SendAddonMessageResult) do
        if code == result and type(name) == "string" and name:match("^[a-zA-Z]+$") then
            return name .. ", code " .. tostring(result)
        end
    end
    return "code " .. tostring(result)
end

function addon:GetDataSendFailure(ok, result)
    if not ok or IsSecret(result) or result ~= Enum.SendAddonMessageResult.Success then
        return SendFailureReason(ok, result)
    end
end

function addon:GetDataSendStatusText()
    local failures, parts = self.dataState and self.dataState.sendFailures, {}
    if not failures then return "" end
    for _, route in ipairs({ { "GUILD", "legacy guild" }, { "COMPACT_GUILD", "compact guild" } }) do
        local reason = failures[route[1]]
        if reason then parts[#parts + 1] = route[2] .. " (" .. reason .. ")" end
    end
    local friends = self:GetFriendsDataSendFailure()
    if friends then parts[#parts + 1] = "friends (" .. friends .. ")" end
    return #parts > 0 and ("Send failures: " .. table.concat(parts, "; ") .. ".") or ""
end

function addon:SetDataConnected(connected)
    local state = self.dataState
    if state.connected == connected then return end
    state.connected = connected
    ResetRequests(state)
    self:NotifyDataConnection()
end

local function SendFrame(self, message, compact)
    if not self:IsDataConnected() then return false, "Data sharing is disconnected." end
    if not self:IsDataFrame(message) then
        return false, "Data message exceeds the supported format."
    end
    self:RefreshDataRoutes()
    if not self:IsDataConnected() then return false, "Data sharing is disconnected." end
    local state = self.dataState
    if (compact and not state.guildCompactActive) or (not compact and not state.guildLegacyActive) then
        return false, "Data message was not accepted."
    end
    local prefix = compact and self:GetCompactGuildDataPrefix() or PREFIX
    local format = compact and "COMPACT_GUILD" or "GUILD"
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, prefix, message, "GUILD")
    local reason = self:GetDataSendFailure(ok, result)
    if state.sendFailures[format] ~= reason then
        state.sendFailures[format] = reason
        self:Notify("DATA_CHANGED")
    end
    if reason then return false, "Data message was not accepted." end
    return true
end

function addon:GetDataPrefix()
    return PREFIX
end

function addon:InitializeData()
    if self.dataState then return end
    self.dataState = { features = {}, requests = {}, sendFailures = {}, connected = false, nextRequestID = 0,
        nameAPIs = { fullName = type(UnitFullName) == "function", realm = type(GetNormalizedRealmName) == "function",
            unmodifiedFullName = NameUtil and type(NameUtil.GetUnmodifiedUnitFullName) == "function" or false },
        requestSession = string.format("%x-%x", GetServerTime(), math.floor(GetTime() * 1000) % 2147483647) }
    ResetRequests(self.dataState)
    self:InitializeDataChannel()
end

function addon:NotifyDataConnection()
    local connected = self:IsDataConnected()
    for _, feature in pairs(self.dataState.features) do
        if feature.connectionChanged then pcall(feature.connectionChanged, connected) end
    end
end

function addon:RegisterDataFeature(name, receive, connectionChanged)
    local state = self.dataState
    if not state then return false, "Data sharing is still loading." end
    if not ValidFeature(name) or type(receive) ~= "function"
        or (connectionChanged ~= nil and type(connectionChanged) ~= "function") then
        return false, "Invalid data feature registration."
    end
    if state.features[name] then return false, "Data feature already registered." end
    state.features[name] = { receive = receive, connectionChanged = connectionChanged }
    if connectionChanged then pcall(connectionChanged, self:IsDataConnected()) end
    return true
end

-- A snapshot request fans out once; each peer may return one payload of its own.
function addon:RegisterDataRequest(name, onRequest, onResponse)
    local state = self.dataState
    if not state then return false, "Data sharing is still loading." end
    if not ValidFeature(name) or type(onRequest) ~= "function" or type(onResponse) ~= "function" then
        return false, "Invalid data request registration."
    end
    if state.requests[name] then return false, "Data request already registered." end
    state.requests[name] = { onRequest = onRequest, onResponse = onResponse }
    return true
end

function addon:IsDataSelf(sender)
    return self.dataState ~= nil and not IsSecret(sender) and type(sender) == "string" and sender ~= ""
        and IsSelfName(self, SenderName(self, sender)) or false
end

local function RequestFrame(self, feature, payload, compact)
    if not self:IsDataConnected() then return false, "Data sharing is disconnected." end
    local state = self.dataState
    local targets = SelfNames(self)
    if not next(targets) then return false, "The local player name is unavailable." end
    if state.nextRequestID >= MAX_REQUEST_SEQUENCE then return false, "Data request identifiers exhausted." end
    PruneRequests(state)
    state.nextRequestID = state.nextRequestID + 1
    local id = state.requestSession .. "-" .. string.format("%d", state.nextRequestID)
    local header = compact and "Q" or "1|Q|" .. feature .. "|"
    local accepted, problem = SendFrame(self, header .. id .. "|" .. payload, compact)
    if not accepted then return false, problem end
    state.pendingRequests[id] = { feature = feature, targets = targets, compact = compact == true,
        expires = GetTime() + REQUEST_WINDOW, responders = {} }
    return true, id
end

function addon:RequestData(feature, payload)
    if not self:IsDataConnected() then return false, "Data sharing is disconnected." end
    if not ValidFeature(feature) or not self.dataState.requests[feature] then return false, "Unknown data request." end
    if IsSecret(payload) or type(payload) ~= "string" then return false, "Invalid data payload." end
    return RequestFrame(self, feature, payload)
end

function addon:RequestCompactGuildStatus(payload)
    return RequestFrame(self, "status", payload, true)
end

function addon:SendCompactGuildStatus(payload)
    return SendFrame(self, payload, true)
end

function addon:SendData(feature, payload)
    if not self:IsDataConnected() then return false, "Data sharing is disconnected." end
    if not ValidFeature(feature) or not self.dataState.features[feature] then
        return false, "Unknown data feature."
    end
    if IsSecret(payload) or type(payload) ~= "string" then return false, "Invalid data payload." end
    return SendFrame(self, "1|" .. feature .. "|" .. payload)
end

local function ReceiveRequest(self, sender, feature, id, payload, nativeSender, compact)
    local state = self.dataState
    local normalized = SenderName(self, sender)
    if not feature or not ValidRequestID(id) or not normalized or IsSelfName(self, normalized) then return false end
    local registration = state.requests[feature]
    if not registration then return false end
    local now = PruneRequests(state)
    local key = normalized .. "|" .. feature .. "|" .. id
    if state.repliedRequests[key] then return false end
    state.repliedRequests[key] = now + REQUEST_WINDOW
    local target = nativeSender and SenderName(self, nativeSender) or normalized
    local header = (compact and "R" or "1|R|" .. feature .. "|") .. id .. "|" .. target .. "|"
    local ok, response = pcall(registration.onRequest, sender, payload, MAX_MESSAGE_BYTES - #header, compact)
    local sent = ok and not IsSecret(response) and type(response) == "string" and SendFrame(self, header .. response, compact)
    -- A malformed request or failed reply must not consume the matching
    -- discovery request arriving over the other guild prefix.
    if not sent and feature == "status" then state.repliedRequests[key] = nil end
    return sent
end

local function ReceiveResponse(self, sender, feature, id, target, payload, compact)
    local normalized = SenderName(self, sender)
    if not feature or not ValidRequestID(id) or not normalized or IsSelfName(self, normalized) then return false end
    local state = self.dataState
    PruneRequests(state)
    local request = state.pendingRequests[id]
    if not request or request.feature ~= feature or not request.targets[target] or request.responders[normalized]
        or request.compact ~= (compact == true) then
        return false
    end
    local registration = state.requests[feature]
    if not registration then return false end
    if feature == "status" and not self:DecodeGuildStatus(payload, compact) then return false end
    request.responders[normalized] = true
    local ok, accepted = pcall(registration.onResponse, sender, payload, compact)
    return ok and accepted ~= false
end

local function ReceiveFeature(self, sender, feature, payload, compact)
    local registration = self.dataState.features[feature]
    if not registration then return false end
    local ok, accepted = pcall(registration.receive, sender, payload, compact)
    return ok and accepted ~= false
end

function addon:OnDataMessage(sender, message, nativeSender)
    if IsSecret(sender) or type(sender) ~= "string" or sender == "" or not self:IsDataFrame(message) then return false end
    local kind, body = message:match("^1|([^|]+)|(.*)$")
    if not kind then return false end
    if kind == "Q" then
        local feature, id, payload = body:match("^([a-z][a-z0-9_-]*)|([^|]+)|(.*)$")
        return ReceiveRequest(self, sender, feature, id, payload, nativeSender)
    end
    if kind == "R" then
        local feature, id, target, payload = body:match("^([a-z][a-z0-9_-]*)|([^|]+)|([^|]+)|(.*)$")
        return ReceiveResponse(self, sender, feature, id, target, payload)
    end
    return ReceiveFeature(self, sender, kind, body)
end

function addon:ParseCompactGuildStatusFrame(message)
    if not self:IsDataFrame(message) then return nil end
    local kind = message:sub(1, 1)
    if kind == "S" then return kind, message end
    if kind == "Q" then
        local id, payload = message:match("^Q([^|]+)|(S.*)$")
        if ValidRequestID(id) then return kind, payload, id end
    elseif kind == "R" then
        local id, target, payload = message:match("^R([^|]+)|([^|%c%-]+%-[^|%s%c]+)|(S.*)$")
        if ValidRequestID(id) then return kind, payload, id, target end
    end
end

function addon:OnCompactGuildDataMessage(sender, message, nativeSender)
    if IsSecret(sender) or type(sender) ~= "string" or sender == "" then return false end
    local kind, payload, id, target = self:ParseCompactGuildStatusFrame(message)
    if kind == "S" then return ReceiveFeature(self, sender, "status", payload, true) end
    if kind == "Q" then return ReceiveRequest(self, sender, "status", id, payload, nativeSender, true) end
    if kind == "R" then return ReceiveResponse(self, sender, "status", id, target, payload, true) end
    return false
end

function addon:GetPlayerDataCleanupEnabled()
    return not self.db or type(self.db.data) ~= "table" or self.db.data.cleanupOldPlayers ~= false
end

local function CanChangePlayerData(self)
    if not self.initialized or not self.rosterState then
        return false, "Still loading. Please try again after login."
    end
    if self.savedDataReadOnly then return false, "Update LockInTools before changing saved preferences." end
    return true
end

local function PlayerDataMaps(self)
    return { self.db.roster.peers, self.rosterState.peers, self.rosterState.progress, self.burnedState.peers,
        self.dataState.status.received }
end

local function RefreshPlayerData(self)
    if not next(self.burnedState.peers) and self.burnedState.timer then
        self.burnedState.timer:Cancel()
        self.burnedState.timer = nil
    end
    self:Notify("ROSTER_CHANGED")
    self:Notify("BURNED_CHANGED")
end

function addon:PrunePlayerData()
    if not CanChangePlayerData(self) or not self:GetPlayerDataCleanupEnabled() then return 0 end
    local lastSeen, activeCharacters, cutoff = {}, {}, GetServerTime() - PLAYER_DATA_MAX_AGE
    -- Expire a player's history together using the most recent roster contact.
    for _, peers in ipairs({ self.db.roster.peers, self.rosterState.peers }) do
        for id, peer in pairs(peers) do
            local stamp = peer.seenAt
            if type(stamp) == "number" then
                lastSeen[id] = math.max(lastSeen[id] or 0, stamp)
                if stamp > cutoff then activeCharacters[self:GetRankingPlayerKey(id)] = true end
            end
        end
    end
    local count = 0
    for id, stamp in pairs(lastSeen) do
        if stamp <= cutoff then
            self.db.roster.peers[id], self.rosterState.peers[id], self.rosterState.progress[id] = nil, nil, nil
            -- Both protocol maps use the same character key across name forms.
            local key = self:GetRankingPlayerKey(id)
            if not activeCharacters[key] then
                self.burnedState.peers[key], self.dataState.status.received[key] = nil, nil
            end
            count = count + 1
        end
    end
    if count > 0 then RefreshPlayerData(self) end
    return count
end

function addon:ClearPlayerData()
    local allowed, message = CanChangePlayerData(self)
    if not allowed then return false, message end
    for _, map in ipairs(PlayerDataMaps(self)) do
        for id in pairs(map) do map[id] = nil end
    end
    ResetRequests(self.dataState)
    RefreshPlayerData(self)
    return true
end

function addon:UpdatePlayerDataCleanupTimer()
    if self.playerDataCleanupTimer then
        self.playerDataCleanupTimer:Cancel()
        self.playerDataCleanupTimer = nil
    end
    if not self.ready or self.playerDataCleanupStopped or self.savedDataReadOnly
        or not self:GetPlayerDataCleanupEnabled() then return end
    self.playerDataCleanupTimer = C_Timer.NewTimer(PLAYER_DATA_CLEANUP_INTERVAL, function()
        self.playerDataCleanupTimer = nil
        self:PrunePlayerData()
        self:UpdatePlayerDataCleanupTimer()
    end)
end

function addon:SetPlayerDataCleanupEnabled(enabled)
    local allowed, message = CanChangePlayerData(self)
    if not allowed then return false, message end
    if type(enabled) ~= "boolean" then return false, "Choose on or off." end
    self.db.data.cleanupOldPlayers = enabled
    self:PrunePlayerData()
    self:UpdatePlayerDataCleanupTimer()
    self:Notify("DATA_CHANGED")
    return true
end

function addon:InitializePlayerDataCleanup()
    self:PrunePlayerData()
    self.playerDataCleanupEvents = self:RegisterGameEvents({ "PLAYER_LOGOUT" }, function(self)
        self.playerDataCleanupStopped = true
        self:UpdatePlayerDataCleanupTimer()
    end)
end
