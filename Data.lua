local _, addon = ...
local PREFIX, MAX_MESSAGE_BYTES = "LockInToolsData", 255
local REQUEST_WINDOW, MAX_REQUEST_SEQUENCE = 10, 999999999
local RETRY_DELAYS = { 2, 4, 8, 8, 30 }
local CONNECTION_CHECK_INTERVAL, FAILURE_RETRY_DELAY = 15, 30
local LEAVE_CACHE_CHECK_LIMIT = 5
local STATUS_INTERVAL, STATUS_HEARTBEAT_INTERVAL, MAX_STATUS_STAMP = 5, 30, 9999999999
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

local function ValidFeature(feature)
    return not IsSecret(feature) and type(feature) == "string" and #feature <= 32
        and feature:match("^[a-z][a-z0-9_-]*$")
end

local function SenderName(name)
    if IsSecret(name) or type(name) ~= "string" or name == "" or #name > 128
        or name:find("[|%z]") then return nil end
    local character, realm = name:match("^([^%-]+)%-(.+)$")
    if not character then character, realm = name, GetNormalizedRealmName() end
    if IsSecret(realm) or type(realm) ~= "string" or realm == "" then return nil end
    return (character .. "-" .. realm:gsub("%s", "")):lower()
end

local function SelfNames()
    local names = {}
    if type(UnitFullName) == "function" then
        local ok, name, realm = pcall(UnitFullName, "player")
        if ok and not IsSecret(name) and type(name) == "string" and name ~= ""
            and not IsSecret(realm) then
            if type(realm) == "string" and realm ~= "" then name = name .. "-" .. realm end
            local normalized = SenderName(name)
            if normalized then names[normalized] = true end
        end
    end
    if NameUtil and type(NameUtil.GetUnmodifiedUnitFullName) == "function" then
        local ok, name = pcall(NameUtil.GetUnmodifiedUnitFullName, "player")
        local normalized = ok and SenderName(name)
        if normalized then names[normalized] = true end
    end
    return names
end

local function ResetRequests(state)
    state.requestEpoch = (state.requestEpoch or 0) + 1
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

local function SendFrame(self, message)
    if not self:IsDataConnected() then return false, "Group data is disconnected." end
    if #message > MAX_MESSAGE_BYTES or message:find("\000", 1, true) then
        return false, "Data message exceeds the supported format."
    end
    -- No queue or automatic retry: each feature decides when its data is current.
    local ok, accepted = pcall(self.dataState.send, PREFIX, message)
    if not ok or accepted ~= true then return false, "Data message was not accepted." end
    return true
end

local function ValidRequestID(id)
    return type(id) == "string" and #id <= 32 and id:match("^[a-zA-Z0-9_-]+$")
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
        and state.wanted and not state.stopped
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
    self:InitializeGroupChannelCleanup()
    self.dataState = { features = {}, requests = {}, phase = "idle", attempts = 0, generation = 0,
        channelName = self:GetGroupDataChannelName(), nextRequestID = 0,
        requestSession = string.format("%x-%x", GetServerTime(), math.floor(GetTime() * 1000) % 2147483647) }
    ResetRequests(self.dataState)
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

local function StatusNames(providers)
    local names = {}
    for name in pairs(providers) do names[#names + 1] = name end
    table.sort(names)
    return names
end

local function StatusField(name)
    return not IsSecret(name) and type(name) == "string" and #name <= 32
        and name:match("^[a-z][a-zA-Z0-9_]*$")
end

-- Permanent wire registry. Add fields with new IDs; never renumber or reuse an
-- ID. Keep retired entries with false in place of their former Lua field name.
local STATUS_FIELD_REGISTRY = {
    { 1, "level" },
    { 2, "xp" },
    { 3, "xpMax" },
    { 4, "xpState" },
    { 5, "inParty" },
    { 6, "canInvite" },
    { 7, "partyFull" },
    { 8, "sharing" },
}
local STATUS_FIELD_NAMES, STATUS_FIELD_IDS, STATUS_FIELD_ORDER = {}, {}, {}
for _, field in ipairs(STATUS_FIELD_REGISTRY) do
    local id, name = field[1], field[2]
    assert(type(id) == "number" and id >= 1 and id <= 65535 and id % 1 == 0
        and STATUS_FIELD_NAMES[id] == nil, "Invalid or duplicate status field ID.")
    assert(name == false or (StatusField(name) and STATUS_FIELD_IDS[name] == nil),
        "Invalid or duplicate status field name.")
    STATUS_FIELD_NAMES[id] = name
    if name then STATUS_FIELD_IDS[name] = id end
    STATUS_FIELD_ORDER[#STATUS_FIELD_ORDER + 1] = id
end
table.sort(STATUS_FIELD_ORDER)

local function StatusFieldID(value)
    if not value or #value > 5 or not value:match("^[1-9][0-9]*$") then return nil end
    local id = tonumber(value)
    return id <= 65535 and id or nil
end

local function StatusString(value)
    if IsSecret(value) then return nil end
    if type(value) == "number" then
        if value ~= value or value < -9007199254740991 or value > 9007199254740991 then return nil end
        value = string.format("%.17g", value)
    elseif type(value) == "boolean" then value = value and "true" or "false"
    elseif type(value) ~= "string" then return nil end
    if value:find("[%z\001-\031\127]") then return nil end
    return value
end

local function EscapeStatus(value)
    return (value:gsub("[%%|=]", function(character) return string.format("%%%02X", string.byte(character)) end))
end

local function UnescapeStatus(value)
    if value:find("=", 1, true) then return nil end
    local index = 1
    while true do
        local at = value:find("%", index, true)
        if not at then break end
        if not value:sub(at + 1, at + 2):match("^[0-9A-F][0-9A-F]$") then return nil end
        index = at + 3
    end
    value = value:gsub("%%([0-9A-F][0-9A-F])", function(hex) return string.char(tonumber(hex, 16)) end)
    return StatusString(value)
end

local function StatusInteger(value, maximum, minimum)
    if not value or #value > 10 or not value:match("^%d+$")
        or (#value > 1 and value:sub(1, 1) == "0") then return nil end
    local number = tonumber(value)
    if number < minimum or number > maximum then return nil end
    return number
end

local function DecodeStatus(payload)
    if IsSecret(payload) or type(payload) ~= "string" or payload:find("[%z\001-\031\127]") then return nil end
    local kind, session, stampText, revisionText, body = payload:match("^3|([FDH])|([^|]+)|(%d+)|(%d+)(.*)$")
    local stamp = StatusInteger(stampText, MAX_STATUS_STAMP, 0)
    local revision = StatusInteger(revisionText, MAX_REQUEST_SEQUENCE, 1)
    if not kind or not ValidRequestID(session) or not stamp or not revision then return nil end
    -- Keep unknown IDs in the baseline so future fields obey the same revision
    -- checks and delta recovery. Only provider callbacks translate known names.
    local message = { kind = kind, session = session, stamp = stamp, revision = revision, fields = {} }
    if kind == "H" then return body == "" and message or nil end
    if kind == "D" then
        local baseText
        baseText, body = body:match("^|(%d+)|(.*)$")
        message.base = StatusInteger(baseText, MAX_REQUEST_SEQUENCE, 1)
        if not message.base or message.base >= revision or body == "" then return nil end
    else
        body = body:match("^|(.*)$")
        if body == nil then return nil end
    end
    if body ~= "" then
        if body:sub(-1) == "|" then return nil end
        for part in (body .. "|"):gmatch("(.-)|") do
            local idText, encoded = part:match("^([^=]+)=(.*)$")
            if not idText and kind == "D" then idText = part end
            local id = StatusFieldID(idText)
            if not id or message.fields[id] ~= nil then return nil end
            local value = encoded ~= nil and UnescapeStatus(encoded)
            if encoded ~= nil and value == nil then return nil end
            message.fields[id] = encoded == nil and false or value
        end
    end
    return message
end

local function SameStatus(left, right)
    if not left or not right then return left == right end
    for name, value in pairs(left) do if value ~= right[name] then return false end end
    for name in pairs(right) do if left[name] == nil then return false end end
    return true
end

local function CopyStatus(fields)
    local copy = {}
    for name, value in pairs(fields) do copy[name] = value end
    return copy
end

local function NamedStatus(fields)
    local named = {}
    for id, value in pairs(fields) do
        local name = STATUS_FIELD_NAMES[id]
        if name then named[name] = value end
    end
    return named
end

-- Providers share one complete snapshot. A broken provider cannot stop healthy
-- providers, and omitted fields remain unavailable rather than retaining old data.
local function CollectStatus(self)
    local status, fields, available = self.dataState.status, {}, false
    for _, name in ipairs(StatusNames(status.providers)) do
        local ok, values = pcall(status.providers[name].collect)
        if ok and not IsSecret(values) and type(values) == "table" then
            local collected, valid = {}, true
            for key, value in pairs(values) do
                local encoded = StatusString(value)
                if not StatusField(key) or not STATUS_FIELD_IDS[key] or encoded == nil then valid = false; break end
                collected[key] = encoded
            end
            if valid then
                available = true
                for key, value in pairs(collected) do
                    if fields[key] ~= nil then return nil end
                    fields[key] = value
                end
            end
        end
    end
    if not available and not status.current then return nil end
    return fields
end

local function CurrentStatus(self)
    local status = self.dataState.status
    local generation = status.generation
    local fields = CollectStatus(self)
    if not fields or generation ~= status.generation then return nil end
    if not SameStatus(fields, status.current) then
        if status.revision >= MAX_REQUEST_SEQUENCE then return nil end
        status.revision, status.current = status.revision + 1, fields
    end
    return status.current, status.revision
end

local function EncodeStatus(self, kind, fields, revision, base)
    local status = self.dataState.status
    local stamp = GetServerTime()
    if IsSecret(stamp) or type(stamp) ~= "number" or stamp ~= stamp or stamp < 0
        or stamp > MAX_STATUS_STAMP or stamp % 1 ~= 0 then return nil end
    stamp = math.max(stamp, status.lastStamp or 0)
    status.lastStamp = stamp
    local header = "3|" .. kind .. "|" .. status.session .. "|" .. string.format("%.0f", stamp) .. "|" .. revision
    if kind == "H" then return header end
    local encoded = {}
    for _, id in ipairs(STATUS_FIELD_ORDER) do
        local name = STATUS_FIELD_NAMES[id]
        local value = name and fields[name]
        if value ~= nil and name then
            encoded[#encoded + 1] = value == false and tostring(id) or id .. "=" .. EscapeStatus(value)
        end
    end
    return header .. "|" .. (base and base .. "|" or "") .. table.concat(encoded, "|")
end

local function ContactStatus(self, sender, message, peer)
    local status, generation = self.dataState.status, self.dataState.status.generation
    local synchronized = peer.fields ~= nil and not peer.unsynchronized
    local metadata = { kind = ({ F = "full", D = "delta", H = "heartbeat" })[message.kind],
        session = message.session, revision = message.revision, hasBaseline = peer.fields ~= nil,
        coherent = synchronized, synchronized = synchronized }
    for _, name in ipairs(StatusNames(status.providers)) do
        local provider = status.providers[name]
        if provider.contact then pcall(provider.contact, sender, message.stamp, CopyStatus(metadata)) end
        if status.generation ~= generation then return false end
    end
    return metadata
end

local function ProcessStatus(self, sender, payload, requested)
    local status, normalized = self.dataState.status, SenderName(sender)
    local message = DecodeStatus(payload)
    if not message or not normalized or normalized:find("[%z\001-\031\127]") or self:IsDataSelf(sender) then return false end
    local peer, generation = status.received[normalized], status.generation
    if not peer then
        peer = { retired = {}, revision = 0, advertised = 0 }
        status.received[normalized] = peer
    end
    if peer.retired[message.session] then return false end
    if peer.session ~= message.session then
        if peer.stamp and message.stamp < peer.stamp then return false end
        if peer.session then peer.retired[peer.session] = true end
        peer.session, peer.fields, peer.revision, peer.advertised = message.session, nil, 0, 0
        peer.unsynchronized, peer.contactStamp = true, nil
    end
    if message.revision < peer.revision or message.revision < peer.advertised then return false end
    if peer.stamp and message.stamp < peer.stamp and message.revision <= peer.revision then return false end
    if message.kind == "H" then
        if peer.contactStamp and message.stamp <= peer.contactStamp then return false end
        peer.advertised = message.revision
        if not peer.fields or message.revision ~= peer.revision then peer.unsynchronized = true; status.resyncNeeded = true end
        peer.stamp, peer.contactStamp = message.stamp, message.stamp
        return ContactStatus(self, sender, message, peer) ~= false
    end
    if message.kind == "D" then
        if message.revision == peer.revision then return false end
        if not peer.fields or peer.unsynchronized or message.base ~= peer.revision then
            peer.unsynchronized, peer.advertised = true, message.revision
            peer.stamp, peer.contactStamp, status.resyncNeeded = message.stamp, message.stamp, true
            ContactStatus(self, sender, message, peer)
            return false
        end
        local merged = CopyStatus(peer.fields)
        for name, value in pairs(message.fields) do merged[name] = value ~= false and value or nil end
        peer.fields = merged
    else
        if message.revision == peer.revision and not SameStatus(message.fields, peer.fields) then return false end
        if message.revision == peer.revision and not requested and message.stamp <= (peer.contactStamp or -1) then return false end
        peer.fields = message.fields
    end
    peer.revision, peer.advertised, peer.stamp = message.revision, message.revision, message.stamp
    peer.contactStamp, peer.unsynchronized = message.stamp, false
    local metadata = ContactStatus(self, sender, message, peer)
    if not metadata or generation ~= status.generation then return false end
    for _, name in ipairs(StatusNames(status.providers)) do
        -- Each callback owns its copies. Central revision ordering keeps one
        -- coherent baseline even if a consumer throws or rejects the sample.
        local provider = status.providers[name]
        pcall(provider.receive, sender, NamedStatus(peer.fields), message.stamp, message.revision, CopyStatus(metadata))
        if status.generation ~= generation then return false end
    end
    return true
end

local function ReceiveStatus(self, sender, payload, requested)
    local status = self.dataState.status
    if status.receiving then
        if not DecodeStatus(payload) or #status.receiveQueue >= 64 then return false end
        status.receiveQueue[#status.receiveQueue + 1] = {
            sender = sender, payload = payload, requested = requested, generation = status.generation }
        return true
    end
    -- Deliver one coherent sample to all consumers before processing a nested
    -- transport callback. Otherwise one provider could see an old revision with
    -- the fields of a newer sample received reentrantly by another provider.
    status.receiving, status.receiveQueue = true, {}
    local ok, accepted = pcall(ProcessStatus, self, sender, payload, requested)
    local count = 0
    while #status.receiveQueue > 0 and count < 64 do
        local nextMessage = table.remove(status.receiveQueue, 1)
        count = count + 1
        if nextMessage.generation == status.generation then
            pcall(ProcessStatus, self, nextMessage.sender, nextMessage.payload, nextMessage.requested)
        end
    end
    status.receiving, status.receiveQueue = false, {}
    return ok and accepted
end

local function ScheduleStatus(self)
    local status = self.dataState.status
    if status.timer or not status.connected or not self:IsDataConnected() then return end
    local generation = status.generation
    status.timer = C_Timer.NewTimer(STATUS_INTERVAL, function()
        if status.generation ~= generation then return end
        status.timer = nil
        self:DataStatusTick()
    end)
end

local function StatusConnectionChanged(self, connected)
    local state, status = self.dataState, self.dataState.status
    -- Another feature callback may have changed the route reentrantly.
    connected = self:IsDataConnected()
    local send, fingerprint = connected and state.send or nil, connected and state.groupFingerprint or nil
    if status.connected == connected and status.send == send and status.fingerprint == fingerprint then return end
    status.generation = status.generation + 1
    if status.timer then status.timer:Cancel(); status.timer = nil end
    status.connected, status.send, status.fingerprint = connected, send, fingerprint
    status.received, status.lastBroadcast, status.lastAttemptAt = {}, nil, nil
    status.receiveQueue = {}
    status.current, status.revision, status.broadcastRevision = nil, 0, 0
    status.forceFull, status.resyncNeeded, status.lastResyncAttemptAt, status.lastTrafficAt = false, false, nil, nil
    status.session = state.requestSession .. "-" .. status.generation
    status.requestNeeded = connected
    local generation = status.generation
    for _, name in ipairs(StatusNames(status.providers)) do
        local callback = status.providers[name].connectionChanged
        if callback then pcall(callback, connected) end
        if status.generation ~= generation then return end
    end
    if connected then ScheduleStatus(self); self:DataStatusTick() end
end

-- Polling, change suppression and join snapshots belong to the data protocol,
-- so adding a provider does not add another wire feature or another scheduler.
function addon:RegisterDataStatusProvider(name, collect, receive, connectionChanged, contact)
    local state = self.dataState
    if not state then return false, "Group data is still loading." end
    if not ValidFeature(name) or type(collect) ~= "function" or type(receive) ~= "function"
        or (connectionChanged ~= nil and type(connectionChanged) ~= "function")
        or (contact ~= nil and type(contact) ~= "function") then
        return false, "Invalid status provider registration."
    end
    if state.status and state.status.providers[name] then return false, "Status provider already registered." end
    local first = not state.status
    if first then
        if state.features.status or state.requests.status then return false, "Status data is already registered." end
        state.status = { providers = {}, received = {}, generation = 0, revision = 0 }
    end
    local status = state.status
    status.providers[name] = { collect = collect, receive = receive, connectionChanged = connectionChanged, contact = contact }
    if first then
        self:RegisterDataRequest("status", function(sender, payload, budget)
            local generation = status.generation
            if payload ~= "3|S" then
                local message = DecodeStatus(payload)
                if not message or message.kind ~= "F" then return nil end
                ReceiveStatus(self, sender, payload, true)
            end
            if status.generation ~= generation then return nil end
            local fields, revision = CurrentStatus(self)
            if fields == nil or status.generation ~= generation then return nil end
            local response = EncodeStatus(self, "F", fields, revision)
            -- A recipient of an unpublished full snapshot cannot apply a later
            -- patch against the older broadcast baseline. Publish a full next.
            if revision ~= status.broadcastRevision then status.forceFull = true end
            if response and #response <= budget then return response end
            -- A reply never marks a changed snapshot as broadcast to all peers.
        end, function(sender, payload)
            local message = DecodeStatus(payload)
            return message and message.kind == "F" and ReceiveStatus(self, sender, payload, true) or false
        end)
        self:RegisterDataFeature("status", function(sender, payload) return ReceiveStatus(self, sender, payload) end,
            function(connected) StatusConnectionChanged(self, connected) end)
    elseif connectionChanged then pcall(connectionChanged, self:IsDataConnected()) end
    return true
end

function addon:DataStatusTick()
    local state = self.dataState
    local status = state and state.status
    if not status or status.ticking then return false end
    if not self:IsDataConnected() then
        StatusConnectionChanged(self, false)
        return false
    end
    local generation, now = status.generation, GetTime()
    if status.lastAttemptAt and now - status.lastAttemptAt < STATUS_INTERVAL then ScheduleStatus(self); return false end
    status.ticking = true
    local fields, revision = CurrentStatus(self)
    local sent = false
    if fields ~= nil and generation == status.generation and self:IsDataConnected() then
        local payload, request, broadcast
        if status.requestNeeded then
            payload, request, broadcast = EncodeStatus(self, "F", fields, revision), true, true
        elseif status.resyncNeeded and (not status.lastResyncAttemptAt or now - status.lastResyncAttemptAt >= STATUS_HEARTBEAT_INTERVAL) then
            payload, request = "3|S", true
        elseif status.forceFull or revision ~= status.broadcastRevision then
            local changed = {}
            for name, value in pairs(fields) do
                if not status.lastBroadcast or status.lastBroadcast[name] ~= value then changed[name] = value end
            end
            for name in pairs(status.lastBroadcast or {}) do if fields[name] == nil then changed[name] = false end end
            local kind = (status.forceFull or not status.lastBroadcast or not next(changed)) and "F" or "D"
            payload, broadcast = EncodeStatus(self, kind, kind == "F" and fields or changed, revision,
                kind == "D" and status.broadcastRevision or nil), true
        elseif status.lastTrafficAt and now - status.lastTrafficAt >= STATUS_HEARTBEAT_INTERVAL then
            payload = EncodeStatus(self, "H", nil, status.broadcastRevision)
        end
        if payload then
            status.lastAttemptAt = now
            if payload == "3|S" then
                status.resyncNeeded, status.lastResyncAttemptAt = false, now
            end
            if request then sent = self:RequestData("status", payload)
            else sent = self:SendData("status", payload) end
            if generation == status.generation and sent then
                if broadcast then
                    status.requestNeeded, status.lastBroadcast, status.broadcastRevision = false, fields, revision
                    -- Synchronous callbacks can collect newer local state.
                    status.forceFull = status.revision ~= revision
                end
                if payload ~= "3|S" then status.lastTrafficAt = now end
            elseif generation == status.generation and payload == "3|S" then
                status.resyncNeeded = true
            end
        end
    end
    status.ticking = false
    if generation == status.generation then ScheduleStatus(self) end
    return sent
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
    local normalized = SenderName(sender)
    return normalized ~= nil and SelfNames()[normalized] == true
end

function addon:RequestData(feature, payload)
    if not self:IsDataConnected() then return false, "Group data is disconnected." end
    local state = self.dataState
    if not ValidFeature(feature) or not state.requests[feature] then return false, "Unknown data request." end
    if IsSecret(payload) or type(payload) ~= "string" then return false, "Invalid data payload." end
    local targets = SelfNames()
    if not next(targets) then return false, "The local player name is unavailable." end
    if state.nextRequestID >= MAX_REQUEST_SEQUENCE then return false, "Data request identifiers exhausted." end
    PruneRequests(state)
    state.nextRequestID = state.nextRequestID + 1
    local id = state.requestSession .. "-" .. string.format("%d", state.nextRequestID)
    local request = { feature = feature, targets = targets, expires = GetTime() + REQUEST_WINDOW, responders = {} }
    -- Install before sending so an immediate transport response can already correlate.
    state.pendingRequests[id] = request
    local accepted, problem = SendFrame(self, "1|Q|" .. feature .. "|" .. id .. "|" .. payload)
    if not accepted then
        if state.pendingRequests[id] == request then state.pendingRequests[id] = nil end
        return false, problem
    end
    return true, id
end

-- Features share this transport boundary; native acceptance is not a peer receipt.
function addon:SetDataTransport(send)
    local state = self.dataState
    if not state then return false, "Group data is still loading." end
    if send ~= nil and type(send) ~= "function" then return false, "Invalid data connection." end
    if send and (self.savedDataReadOnly or not self:HasGroup()) then
        return false, "A writable group configuration is required."
    end
    local fingerprint = send and self:GetGroupFingerprint() or nil
    if state.send ~= send or state.groupFingerprint ~= fingerprint then ResetRequests(state) end
    state.send = send
    state.groupFingerprint = fingerprint
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
    ResetRequests(state)
    local previous = state.channelName
    state.channelName = self:GetGroupDataChannelName()
    state.nativeSend = nil
    state.phase, state.detail = "idle", nil
    state.attempts, state.pending, state.failed, state.awaitingLeave = 0, false, false, false
    state.leaveChecks = 0
    state.wanted = self:HasGroup() and not self.savedDataReadOnly
    if previous then self:LeaveGroupChannel(previous) end
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
    local state = self.dataState
    -- Repeated notices must not restart or postpone the same cooldown.
    if not state.failed then self:CancelDataTimer() end
    Disconnect(self)
    state.failed, state.pending = true, false
    state.phase, state.detail = "error", detail
    if Wanted(self) and not state.timer then self:ScheduleDataCheck(FAILURE_RETRY_DELAY) end
    Refresh(self)
    return false
end

function addon:ConfirmDataMembership()
    local state = self.dataState
    if not Wanted(self) or state.awaitingLeave then return false end
    local name = self:GetGroupDataChannelName()
    if not state.prefixRegistered or not ChannelID(name) then return false end
    if state.phase == "joined" and state.send == state.nativeSend then
        if not state.timer then self:ScheduleDataCheck(CONNECTION_CHECK_INTERVAL) end
        return true
    end
    self:CancelDataTimer()
    state.channelName = name
    state.attempts, state.pending, state.failed = 0, false, false
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
            self:ScheduleDataCheck(1)
            Refresh(self)
            return false
        end
        -- Resolve local channel numbers for every send; no queue and no whisper fallback.
        local ok, result = pcall(C_ChatInfo.SendAddonMessage, prefix, message, "CHANNEL", tostring(id))
        return ok and not IsSecret(result) and result == Enum.SendAddonMessageResult.Success
    end
    state.nativeSend = send
    self:SetDataTransport(send)
    self:ScheduleDataCheck(CONNECTION_CHECK_INTERVAL)
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
        state.failed, state.stopped = false, false
        state.attempts, state.wanted = 0, true
    end
    if not Wanted(self) then return false end
    state.channelName = self:GetGroupDataChannelName()
    if state.awaitingLeave then
        -- Native leave notices can arrive before cached membership disappears.
        if ChannelID(state.channelName) then
            state.leaveChecks = (state.leaveChecks or 0) + 1
            if state.leaveChecks < LEAVE_CACHE_CHECK_LIMIT then
                if not state.timer then self:ScheduleDataCheck(1) end
                return false
            end
            -- A delayed notice or failed leave must not stall recovery forever.
            state.leaveChecks = 0
            self:LeaveGroupChannel(state.channelName)
            if ChannelID(state.channelName) then
                self:ScheduleDataCheck(FAILURE_RETRY_DELAY)
                return false
            end
        end
        state.awaitingLeave, state.leaveChecks = false, 0
    end
    state.failed = false
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
    Disconnect(self)
    state.attempts = math.min(state.attempts + 1, #RETRY_DELAYS)
    state.pending, state.phase, state.detail = true, "joining", nil
    local ok = pcall(JoinTemporaryChannel, state.channelName, self:GetGroupDataChannelPassword())
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
    if self.savedDataReadOnly then return false, "Saved preferences are read-only." end
    self:CancelDataTimer()
    state.wanted = self:HasGroup()
    state.pending, state.failed, state.awaitingLeave, state.attempts = false, false, true, 0
    state.leaveChecks = 0
    state.phase, state.detail = "joining", nil
    Disconnect(self)
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
        state.stopped, state.wanted = true, false
        Disconnect(self)
        ResetRequests(state)
        return
    end
    if state.stopped or not self.ready or self.savedDataReadOnly or not self:HasGroup()
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
        if FAILURE_NOTICES[reason] then
            self:FailDataJoin(FAILURE_NOTICES[reason])
        elseif reason == "YOU_LEFT" then
            if state.awaitingLeave then return end
            state.awaitingLeave, state.pending = true, false
            state.leaveChecks = 0
            Disconnect(self)
            if not state.failed then
                state.phase, state.detail, state.attempts = "joining", nil, 0
                self:ScheduleDataCheck(1)
            end
            Refresh(self)
        elseif reason == "YOU_JOINED" or reason == "YOU_CHANGED" then
            if state.awaitingLeave then return end
            if ChannelID(name) then state.failed, state.wanted = false, true end
            self:ConfirmDataMembership()
        end
    elseif event == "CHANNEL_PASSWORD_REQUEST" then
        local requestedName = ...
        if state.pending and SameChannel(requestedName, name) then
            self:FailDataJoin(FAILURE_NOTICES.WRONG_PASSWORD)
        end
    elseif event == "CHANNEL_UI_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        if not Wanted(self) then return end
        if state.awaitingLeave or state.failed then return end
        if not self:ConfirmDataMembership() then
            Disconnect(self)
            if state.phase == "joined" or not state.timer then
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
    return SendFrame(self, "1|" .. feature .. "|" .. payload)
end

local function ReceiveRequest(self, sender, message)
    local state = self.dataState
    local feature, id, payload = message:match("^1|Q|([a-z][a-z0-9_-]*)|([^|]+)|(.*)$")
    local normalized = SenderName(sender)
    if not ValidFeature(feature) or not ValidRequestID(id) or not normalized or self:IsDataSelf(sender) then return false end
    local registration = state.requests[feature]
    if not registration then return false end
    local now = PruneRequests(state)
    local key = normalized .. "|" .. feature .. "|" .. id
    if state.repliedRequests[key] then return false end
    state.repliedRequests[key] = now + REQUEST_WINDOW
    local epoch = state.requestEpoch
    local header = "1|R|" .. feature .. "|" .. id .. "|" .. normalized .. "|"
    local ok, response = pcall(registration.onRequest, sender, payload, MAX_MESSAGE_BYTES - #header)
    if not ok or IsSecret(response) or type(response) ~= "string" or state.requestEpoch ~= epoch then return false end
    return SendFrame(self, header .. response)
end

local function ReceiveResponse(self, sender, message)
    local feature, id, target, payload = message:match("^1|R|([a-z][a-z0-9_-]*)|([^|]+)|([^|]+)|(.*)$")
    local normalized = SenderName(sender)
    if not ValidFeature(feature) or not ValidRequestID(id) or not normalized or self:IsDataSelf(sender) then return false end
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

-- The backend supplies WoW's sender after matching our prefix and current group route.
function addon:ReceiveData(sender, message)
    if not self:IsDataConnected() or IsSecret(sender) or type(sender) ~= "string" or sender == ""
        or IsSecret(message) or type(message) ~= "string" or #message > MAX_MESSAGE_BYTES
        or message:find("\000", 1, true) then return false end
    if message:sub(1, 4) == "1|Q|" then return ReceiveRequest(self, sender, message) end
    if message:sub(1, 4) == "1|R|" then return ReceiveResponse(self, sender, message) end
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
    if state.phase == "joining" then return "Joining " .. label .. "; reconnecting automatically." end
    if state.phase == "error" then return (state.detail or "Group data is unavailable.") .. " Retrying automatically in up to 30 seconds." end
    return label .. " is configured; waiting for a group connection."
end
