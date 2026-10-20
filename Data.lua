local _, addon = ...
local PREFIX, MAX_MESSAGE_BYTES = "LockInToolsData", 255
local REQUEST_WINDOW, MAX_REQUEST_SEQUENCE = 10, 999999999

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
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

function addon:SetDataConnected(connected)
    local state = self.dataState
    if state.connected == connected then return end
    state.connected = connected
    ResetRequests(state)
    self:NotifyDataConnection()
end

local function SendFrame(self, message)
    if not self:IsDataConnected() then return false, "Group data is disconnected." end
    if #message > MAX_MESSAGE_BYTES or message:find("\000", 1, true) then
        return false, "Data message exceeds the supported format."
    end
    local id = self:GetDataChannelID()
    if not id then return false, "Group data is disconnected." end
    -- No queue or automatic retry: each feature decides when its data is current.
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, message, "CHANNEL", tostring(id))
    if not ok or IsSecret(result) or result ~= Enum.SendAddonMessageResult.Success then
        return false, "Data message was not accepted."
    end
    return true
end

function addon:GetDataPrefix()
    return PREFIX
end

function addon:InitializeData()
    if self.dataState then return end
    self.dataState = { features = {}, requests = {}, connected = false, nextRequestID = 0,
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

-- A snapshot request fans out once; each peer may return one payload of its own.
function addon:RegisterDataRequest(name, onRequest, onResponse)
    local state = self.dataState
    if not state then return false, "Group data is still loading." end
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

function addon:RequestData(feature, payload)
    if not self:IsDataConnected() then return false, "Group data is disconnected." end
    local state = self.dataState
    if not ValidFeature(feature) or not state.requests[feature] then return false, "Unknown data request." end
    if IsSecret(payload) or type(payload) ~= "string" then return false, "Invalid data payload." end
    local targets = SelfNames(self)
    if not next(targets) then return false, "The local player name is unavailable." end
    if state.nextRequestID >= MAX_REQUEST_SEQUENCE then return false, "Data request identifiers exhausted." end
    PruneRequests(state)
    state.nextRequestID = state.nextRequestID + 1
    local id = state.requestSession .. "-" .. string.format("%d", state.nextRequestID)
    local accepted, problem = SendFrame(self, "1|Q|" .. feature .. "|" .. id .. "|" .. payload)
    if not accepted then return false, problem end
    state.pendingRequests[id] = { feature = feature, targets = targets,
        expires = GetTime() + REQUEST_WINDOW, responders = {} }
    return true, id
end

function addon:SendData(feature, payload)
    if not self:IsDataConnected() then return false, "Group data is disconnected." end
    if not ValidFeature(feature) or not self.dataState.features[feature] then
        return false, "Unknown data feature."
    end
    if IsSecret(payload) or type(payload) ~= "string" then return false, "Invalid data payload." end
    return SendFrame(self, "1|" .. feature .. "|" .. payload)
end

local function ReceiveRequest(self, sender, body)
    local state = self.dataState
    local feature, id, payload = body:match("^([a-z][a-z0-9_-]*)|([^|]+)|(.*)$")
    local normalized = SenderName(self, sender)
    if not feature or not ValidRequestID(id) or not normalized or IsSelfName(self, normalized) then return false end
    local registration = state.requests[feature]
    if not registration then return false end
    local now = PruneRequests(state)
    local key = normalized .. "|" .. feature .. "|" .. id
    if state.repliedRequests[key] then return false end
    state.repliedRequests[key] = now + REQUEST_WINDOW
    local header = "1|R|" .. feature .. "|" .. id .. "|" .. normalized .. "|"
    local ok, response = pcall(registration.onRequest, sender, payload, MAX_MESSAGE_BYTES - #header)
    if not ok or IsSecret(response) or type(response) ~= "string" then return false end
    return SendFrame(self, header .. response)
end

local function ReceiveResponse(self, sender, body)
    local feature, id, target, payload = body:match("^([a-z][a-z0-9_-]*)|([^|]+)|([^|]+)|(.*)$")
    local normalized = SenderName(self, sender)
    if not feature or not ValidRequestID(id) or not normalized or IsSelfName(self, normalized) then return false end
    local state = self.dataState
    PruneRequests(state)
    local request = state.pendingRequests[id]
    if not request or request.feature ~= feature or not request.targets[target] or request.responders[normalized] then
        return false
    end
    local registration = state.requests[feature]
    if not registration then return false end
    request.responders[normalized] = true
    local ok, accepted = pcall(registration.onResponse, sender, payload)
    return ok and accepted ~= false
end

-- Native events supply ordinary bounded strings. Only the addon protocol needs
-- decoding; all receives enter through the connected native-channel event.
function addon:OnDataMessage(sender, message)
    local kind, body = message:match("^1|([^|]+)|(.*)$")
    if not kind then return false end
    if kind == "Q" then return ReceiveRequest(self, sender, body) end
    if kind == "R" then return ReceiveResponse(self, sender, body) end
    local registration = self.dataState.features[kind]
    if not registration then return false end
    local ok, accepted = pcall(registration.receive, sender, body)
    return ok and accepted ~= false
end
