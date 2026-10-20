local _, addon = ...

-- Complete player-status snapshots on change and periodic presence refreshes.
local STATUS_INTERVAL, STATUS_REFRESH_INTERVAL = 5, 30
local MAX_STATUS_REVISION, MAX_STATUS_STAMP = 999999999, 9999999999

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function ValidProviderName(feature)
    return not IsSecret(feature) and type(feature) == "string" and #feature <= 32
        and feature:match("^[a-z][a-z0-9_-]*$")
end

local function ValidStatusSession(id)
    return id and #id <= 32 and id:match("^[a-zA-Z0-9_-]+$")
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

local function StatusInteger(value, maximum, minimum)
    if not value or #value > 10 or not value:match("^[0-9]+$")
        or (#value > 1 and value:sub(1, 1) == "0") then return nil end
    local number = tonumber(value)
    if number < minimum or number > maximum then return nil end
    return number
end

local function StatusFieldID(value)
    return StatusInteger(value, 65535, 1)
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
    if not value:find("[%z\001-\031\127]") then return value end
end

local function DecodeStatus(payload)
    local session, stampText, revisionText, body = payload:match("^3|F|([^|]+)|(%d+)|(%d+)|(.*)$")
    local stamp = StatusInteger(stampText, MAX_STATUS_STAMP, 0)
    local revision = StatusInteger(revisionText, MAX_STATUS_REVISION, 1)
    if not ValidStatusSession(session) or not stamp or not revision then return nil end
    local message = { session = session, stamp = stamp, revision = revision, fields = {} }
    if body ~= "" then
        if body:sub(-1) == "|" then return nil end
        for part in (body .. "|"):gmatch("(.-)|") do
            local idText, encoded = part:match("^([^=]+)=(.*)$")
            local id = StatusFieldID(idText)
            if not id or message.fields[id] ~= nil then return nil end
            local value = UnescapeStatus(encoded)
            if value == nil then return nil end
            message.fields[id] = value
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
    for _, name in ipairs(status.providerNames) do
        local ok, values = pcall(status.providers[name].collect)
        if ok and not IsSecret(values) and type(values) == "table" then
            local collected, valid = {}, true
            for key, value in pairs(values) do
                local encoded = StatusString(value)
                if IsSecret(key) or not STATUS_FIELD_IDS[key] or encoded == nil then valid = false; break end
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
    local fields = CollectStatus(self)
    if not fields then return nil end
    if not SameStatus(fields, status.current) then
        if status.revision >= MAX_STATUS_REVISION then return nil end
        status.revision, status.current = status.revision + 1, fields
    end
    return status.current, status.revision
end

local function EncodeStatus(self, fields, revision)
    local status = self.dataState.status
    local stamp = GetServerTime()
    if IsSecret(stamp) or type(stamp) ~= "number" or stamp ~= stamp or stamp < 0
        or stamp > MAX_STATUS_STAMP or stamp % 1 ~= 0 then return nil end
    stamp = math.max(stamp, status.lastStamp or 0)
    status.lastStamp = stamp
    local encoded = {}
    for _, id in ipairs(STATUS_FIELD_ORDER) do
        local name = STATUS_FIELD_NAMES[id]
        local value = name and fields[name]
        if value ~= nil and name then encoded[#encoded + 1] = id .. "=" .. EscapeStatus(value) end
    end
    return "3|F|" .. status.session .. "|" .. string.format("%.0f", stamp) .. "|" .. revision .. "|" .. table.concat(encoded, "|")
end

local function ProcessStatus(self, sender, message, requested)
    local status = self.dataState.status
    local normalized, isSelf = self:GetDataSenderIdentity(sender)
    if not normalized or isSelf then return false end
    local peer = status.received[normalized]
    if not peer then
        peer = { retired = {} }
        status.received[normalized] = peer
    end
    if peer.retired[message.session] then return false end
    if peer.session ~= message.session then
        if peer.stamp and message.stamp < peer.stamp then return false end
        if peer.session then peer.retired[peer.session] = true end
    else
        if message.revision < peer.revision then return false end
        if message.revision == peer.revision then
            -- Unknown field IDs also belong to this complete snapshot.
            if not SameStatus(message.fields, peer.fields) then return false end
            if message.stamp < peer.stamp or (not requested and message.stamp == peer.stamp) then return false end
        end
    end
    peer.session, peer.fields = message.session, message.fields
    peer.revision, peer.stamp = message.revision, message.stamp
    local metadata = { kind = "full", session = message.session, revision = message.revision,
        hasBaseline = true, coherent = true, synchronized = true }
    for _, name in ipairs(status.providerNames) do
        local provider = status.providers[name]
        if provider.contact then pcall(provider.contact, sender, message.stamp, CopyStatus(metadata)) end
    end
    for _, name in ipairs(status.providerNames) do
        local provider = status.providers[name]
        pcall(provider.receive, sender, NamedStatus(message.fields), message.stamp, message.revision, CopyStatus(metadata))
    end
    return true
end

local function ScheduleStatus(self)
    local status = self.dataState.status
    if status.timer or not status.connected or not self:IsDataConnected() then return end
    status.timer = C_Timer.NewTimer(STATUS_INTERVAL, function()
        status.timer = nil
        self:DataStatusTick()
    end)
end

local function StatusConnectionChanged(self, connected)
    local state, status = self.dataState, self.dataState.status
    if status.connected == connected then return end
    if status.timer then status.timer:Cancel(); status.timer = nil end
    status.connected = connected
    status.received, status.lastAttemptAt, status.lastBroadcastAt = {}, nil, nil
    status.current, status.revision, status.lastSentRevision = nil, 0, 0
    if connected then
        -- Revisions restart after reconnecting. Peers need a fresh wire session
        -- even when the group and server timestamp are unchanged.
        status.sessionSequence = status.sessionSequence + 1
        status.session = state.requestSession .. "-" .. status.sessionSequence
    end
    status.requestNeeded = connected
    for _, name in ipairs(status.providerNames) do
        local callback = status.providers[name].connectionChanged
        if callback then pcall(callback, connected) end
    end
    if connected then ScheduleStatus(self); self:DataStatusTick() end
end

-- Polling, change suppression and join snapshots belong to the data protocol,
-- so adding a provider does not add another wire feature or another scheduler.
function addon:RegisterDataStatusProvider(name, collect, receive, connectionChanged, contact)
    local state = self.dataState
    if not state then return false, "Group data is still loading." end
    if not ValidProviderName(name) or type(collect) ~= "function" or type(receive) ~= "function"
        or (connectionChanged ~= nil and type(connectionChanged) ~= "function")
        or (contact ~= nil and type(contact) ~= "function") then
        return false, "Invalid status provider registration."
    end
    if state.status and state.status.providers[name] then return false, "Status provider already registered." end
    local first = not state.status
    if first then
        if state.features.status or state.requests.status then return false, "Status data is already registered." end
        state.status = { providers = {}, received = {}, sessionSequence = 0, revision = 0 }
    end
    local status = state.status
    status.providers[name] = { collect = collect, receive = receive, connectionChanged = connectionChanged, contact = contact }
    -- Replace the snapshot so registration during a callback cannot alter its active iteration.
    status.providerNames = StatusNames(status.providers)
    if first then
        self:RegisterDataRequest("status", function(sender, payload, budget)
            local message = DecodeStatus(payload)
            if not message then return nil end
            ProcessStatus(self, sender, message, true)
            local fields, revision = CurrentStatus(self)
            if fields == nil then return nil end
            local response = EncodeStatus(self, fields, revision)
            if response and #response <= budget then return response end
            -- Replies do not replace the public snapshot or postpone its refresh.
        end, function(sender, payload)
            local message = DecodeStatus(payload)
            return message and ProcessStatus(self, sender, message, true) or false
        end)
        self:RegisterDataFeature("status", function(sender, payload)
            local message = DecodeStatus(payload)
            return message and ProcessStatus(self, sender, message) or false
        end, function(connected) StatusConnectionChanged(self, connected) end)
    elseif connectionChanged then pcall(connectionChanged, self:IsDataConnected()) end
    return true
end

function addon:DataStatusTick()
    local state = self.dataState
    local status = state and state.status
    if not status or self:IsGroupSwitching() then return false end
    if not self:IsDataConnected() then
        StatusConnectionChanged(self, false)
        return false
    end
    local now = GetTime()
    if status.lastAttemptAt and now - status.lastAttemptAt < STATUS_INTERVAL then ScheduleStatus(self); return false end
    local fields, revision = CurrentStatus(self)
    local sent = false
    if fields ~= nil and self:IsDataConnected() and (status.requestNeeded or revision ~= status.lastSentRevision
        or (status.lastBroadcastAt and now - status.lastBroadcastAt >= STATUS_REFRESH_INTERVAL)) then
        local payload = EncodeStatus(self, fields, revision)
        if payload then
            status.lastAttemptAt = now
            if status.requestNeeded then sent = self:RequestData("status", payload)
            else sent = self:SendData("status", payload) end
            if sent then
                status.requestNeeded, status.lastSentRevision, status.lastBroadcastAt = false, revision, now
            end
        end
    end
    ScheduleStatus(self)
    return sent
end
