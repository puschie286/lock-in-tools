local _, addon = ...
local PREFIX, MAX_MESSAGE_BYTES = "LockInToolsData", 255

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function ValidFeature(feature)
    return type(feature) == "string" and #feature <= 32 and feature:match("^[a-z][a-z0-9_-]*$")
end

function addon:GetDataPrefix()
    return PREFIX
end

function addon:InitializeData()
    if not self.dataState then self.dataState = { features = {} } end
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

-- A validated backend owns channel membership, peer discovery and native events.
-- It sends (prefix, framedMessage), returning true only when accepted for delivery.
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
    NotifyConnection(self)
end

function addon:OnDataGroupChanged()
    if self.dataState then self:SetDataTransport(nil) end
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
    if not self:HasGroup() then return "No group configured." end
    local name = self:GetGroupDataChannelName()
    return name .. (self:IsDataConnected() and " is connected." or " is configured; waiting for a group connection.")
end
