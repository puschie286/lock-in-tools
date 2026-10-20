local _, addon = ...

-- Pack discovery and bounded, authenticated transfers share LIT's native channel.
-- Hashes identify content; the selected source decides which content to follow.
local FEATURE, AUTH = "guides", "restedxp"
local CHUNK, WINDOW, INTERVAL = 128, 8, 0.15
local MAX_BYTES, MAX_CACHE, MAX_PACKS, MAX_PEERS = 2097152, 8388608, 8, 32
local OFFER_AGE = 180
local TryInstall, Reconcile, Schedule, Announce, Receive

local function Secret(value) return issecretvalue and issecretvalue(value) end
local function Hash(value)
    return not Secret(value) and type(value) == "string" and #value == 64 and not value:find("[^0-9a-f]")
end
local function PackID(value)
    return not Secret(value) and type(value) == "string" and #value > 0 and #value <= 40
        and value:match("^[a-z0-9][a-z0-9_-]*$")
end
local function Integer(value, maximum)
    if type(value) ~= "string" or #value > 8 or not value:match("^[1-9]%d*$") then return nil end
    local number = tonumber(value)
    if number and number <= maximum then return number end
end
local function Count(items)
    local count = 0
    for _ in pairs(items) do count = count + 1 end
    return count
end
local function Prune(state)
    local now = GetTime()
    if state.pruneAt and now < state.pruneAt then return end
    state.pruneAt = now + 15
    for id, sources in pairs(state.offers) do
        for source, offer in pairs(sources) do if now - offer.seen > OFFER_AGE then sources[source] = nil end end
        if not next(sources) then state.offers[id] = nil end
    end
    for _, entries in ipairs({ state.replies, state.requests }) do
        for source, at in pairs(entries) do if now - at > 60 then entries[source] = nil end end
    end
end
local function Changed(self, message)
    if message then self.restedxpState.status = message end
    self:Notify("RESTEDXP_CHANGED")
end
local function StartJob(self, message, work, complete)
    local state = self.restedxpState
    if state.job then return false, "Guide processing is already in progress." end
    local job = { thread = coroutine.create(work), generation = state.generation }
    state.job = job
    Changed(self, message)
    local function Step()
        state.jobTimer = nil
        if state.job ~= job or state.generation ~= job.generation then return end
        local success, value, problem = coroutine.resume(job.thread)
        if not success then
            state.job = nil
            complete(nil, "Guide processing failed. Check the export and try again.")
        elseif coroutine.status(job.thread) == "dead" then
            state.job = nil
            complete(value, problem)
        else state.jobTimer = C_Timer.NewTimer(0.01, Step) end
    end
    state.jobTimer = C_Timer.NewTimer(0, Step)
    return true
end
local function LocalIdentity(self)
    local name, realm = UnitFullName("player")
    if Secret(name) or Secret(realm) or type(name) ~= "string" or name == "" then return nil end
    if type(realm) == "string" and realm ~= "" then name = name .. "-" .. realm:gsub("%s", "") end
    return self:GetDataSenderIdentity(name)
end
local function Address(self, name)
    return self.Crypto.Hex(self.Crypto.SHA256(name)):sub(1, 12)
end
local function Available(self)
    return self.restedxpState and self.ready and self:HasGroup() and not self.savedDataReadOnly
        and not self:IsGroupSwitching() and self:IsDataConnected() and not self.restedxpState.stopped
end
local function CurrentGroup(self)
    local state = self.restedxpState
    local fingerprint = self:GetGroupFingerprint()
    if self.savedDataReadOnly or not fingerprint then return nil end
    local groups = self.db.restedxp.groups
    if type(groups[fingerprint]) ~= "table" then groups[fingerprint] = {} end
    local group = groups[fingerprint]
    for _, name in ipairs({ "packs", "sources", "installed" }) do
        if type(group[name]) ~= "table" then group[name] = {} end
    end
    return group
end
local function Installed(self)
    local group, identity = CurrentGroup(self), LocalIdentity(self)
    if not group or not identity then return {} end
    if type(group.installed[identity]) ~= "table" then group.installed[identity] = {} end
    return group.installed[identity]
end
local function Queue(self, body, key)
    local state = self.restedxpState
    if not Available(self) or #body + 65 + 9 > 255 then return false end
    if key and state.queued[key] then
        state.queued[key].body = body
        return true
    end
    if #state.queue >= 64 then return false end
    local entry = { body = body, key = key, failures = 0 }
    state.queue[#state.queue + 1] = entry
    if key then state.queued[key] = entry end
    Schedule(self)
    return true
end
local function SavedPack(self, id)
    local group = CurrentGroup(self)
    local saved = group and group.packs[id]
    if type(saved) ~= "table" or not Hash(saved.hash) or type(saved.data) ~= "string"
        or #saved.data == 0 or #saved.data > MAX_BYTES then return nil end
    return saved
end
local function DecodeSaved(self, id)
    local saved = SavedPack(self, id)
    if not saved then return nil, "This pack is not available locally." end
    local state = self.restedxpState
    local cached = state.decoded[id]
    if cached and cached.hash == saved.hash then return cached end
    local pack, problem = self.RestedXPCodec.DecodeCanonical(saved.data)
    if not pack or pack.hash ~= saved.hash then return nil, problem or "Saved guide data failed verification." end
    state.decoded[id] = pack
    return pack
end
local function StorePack(self, id, pack, source)
    local group = CurrentGroup(self)
    if not group then return false, "Join a LIT group before sharing guides." end
    if not group.packs[id] and Count(group.packs) >= MAX_PACKS then return false, "The guide pack limit has been reached." end
    local total = #pack.data
    for other, saved in pairs(group.packs) do
        if other ~= id and type(saved) == "table" and type(saved.data) == "string" then total = total + #saved.data end
    end
    local old = SavedPack(self, id)
    -- Keep one previous copy for recovery, subject to the same total cache limit.
    local previous = old and old.hash ~= pack.hash and { data = old.data, hash = old.hash } or old and old.previous
    if type(previous) ~= "table" or type(previous.data) ~= "string" or not Hash(previous.hash) then previous = nil end
    if previous then total = total + #previous.data end
    for other, saved in pairs(group.packs) do
        if other ~= id and type(saved) == "table" and type(saved.previous) == "table"
            and type(saved.previous.data) == "string" then total = total + #saved.previous.data end
    end
    if total > MAX_CACHE then return false, "There is not enough guide cache space for this update." end
    group.packs[id] = { data = pack.data, hash = pack.hash, source = source, previous = previous }
    self.restedxpState.decoded[id] = pack
    return true
end

Announce = function(self)
    local group = CurrentGroup(self)
    if not group or not Available(self) then return end
    local ids = {}
    for id in pairs(group.packs) do if PackID(id) then ids[#ids + 1] = id end end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local pack = SavedPack(self, id)
        if pack then Queue(self, "1|O|" .. id .. "|" .. pack.hash .. "|" .. #pack.data, "offer:" .. id) end
    end
end

local function RequestWindow(self)
    local state, incoming = self.restedxpState, self.restedxpState.incoming
    if not incoming or not Available(self) then return end
    local first = 1
    while incoming.chunks[first] do first = first + 1 end
    incoming.nextRequest = GetTime() + 4
    Queue(self, "1|W|" .. Address(self, incoming.source) .. "|" .. incoming.id .. "|" .. incoming.hash
        .. "|" .. first .. "|" .. math.min(WINDOW, incoming.count - first + 1), "want")
    Schedule(self)
end

TryInstall = function(self)
    local state = self.restedxpState
    if not state or state.installing or state.incoming or state.job or state.stopped or self.savedDataReadOnly
        or not self:HasGroup() or self:IsGroupSwitching() then return end
    local id = next(state.pending)
    if not id then return end
    local installation = self:GetRestedXPInstallation()
    if not installation.loaded or not installation.compatible then
        Changed(self, installation.problem or "Guide update is ready. Enable a supported RestedXP version to install it.")
        return
    end
    if InCombatLockdown and InCombatLockdown() then Changed(self, "Guide update is ready; waiting until combat ends."); return end
    local saved = SavedPack(self, id)
    if not saved then state.pending[id] = nil; Changed(self, "This guide pack is unavailable."); return end
    local pack, problem = state.decoded[id]
    if not pack or pack.hash ~= saved.hash then
        StartJob(self, "Checking cached " .. id .. "...", function() return DecodeSaved(self, id) end,
            function(decoded, failure)
                if not decoded then state.pending[id] = nil; state.failed[id] = saved.hash; Changed(self, failure)
                else TryInstall(self) end
            end)
        return
    end
    local generation = state.generation
    state.installing = id
    Changed(self, "Installing " .. id .. "...")
    local accepted, code
    accepted, problem, code = self:InstallRestedXPPack(pack, function(success, failure)
        if state.generation ~= generation or state.installing ~= id then return end
        state.installing, state.pending[id] = nil, nil
        if success then
            Installed(self)[id] = pack.hash
            state.failed[id] = nil
            Changed(self, "Installed " .. id .. ".")
            Announce(self)
            Queue(self, "1|Q|" .. self.dataState.requestSession, "query")
        else
            state.failed[id] = pack.hash
            Changed(self, failure or "RestedXP could not install the guide pack.")
        end
        Reconcile(self)
    end)
    if not accepted and state.installing == id then
        state.installing = nil
        -- Busy native imports can finish without a public event; retry at a modest cadence.
        if code == "busy" then state.installRetry = GetTime() + 2; Schedule(self)
        else state.pending[id] = nil; state.failed[id] = pack.hash end
        Changed(self, problem or "The guide pack could not be installed.")
    end
end

Reconcile = function(self, force)
    local state, group = self.restedxpState, CurrentGroup(self)
    if not group or state.incoming or state.installing or state.job then return end
    Prune(state)
    local ids = {}
    for id in pairs(group.sources) do if PackID(id) then ids[#ids + 1] = id end end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local source = group.sources[id]
        local offer = state.offers[id] and state.offers[id][source]
        local saved = SavedPack(self, id)
        if force then state.failed[id] = nil end
        if offer and GetTime() - offer.seen <= OFFER_AGE and (not saved or saved.hash ~= offer.hash)
            and state.failed[id] ~= offer.hash then
            state.incoming = { id = id, source = source, hash = offer.hash, size = offer.size,
                count = math.ceil(offer.size / CHUNK), chunks = {}, bytes = 0, progressAt = GetTime(), retries = 0 }
            Changed(self, "Receiving " .. id .. " (0%)...")
            RequestWindow(self)
            return
        elseif saved and (saved.source == source or offer and offer.hash == saved.hash)
            and (force or Installed(self)[id] ~= saved.hash) and state.failed[id] ~= saved.hash then
            state.pending[id] = true
        end
    end
    TryInstall(self)
end

local function FinishDownload(self)
    local state, incoming = self.restedxpState, self.restedxpState.incoming
    local data = table.concat(incoming.chunks)
    state.incoming = nil
    StartJob(self, "Verifying " .. incoming.id .. "...", function()
        return self.RestedXPCodec.DecodeCanonical(data)
    end, function(pack, problem)
    if not pack or pack.hash ~= incoming.hash then
        state.failed[incoming.id] = incoming.hash
        Changed(self, problem or "The downloaded pack failed verification.")
        Reconcile(self)
        return
    end
    local stored
    stored, problem = StorePack(self, incoming.id, pack, incoming.source)
    if not stored then state.failed[incoming.id] = incoming.hash; Changed(self, problem); Reconcile(self); return end
    state.pending[incoming.id] = true
    Changed(self, "Received " .. incoming.id .. ".")
    Announce(self)
    TryInstall(self)
    end)
end

local function Tick(self)
    local state = self.restedxpState
    state.timer = nil
    if not Available(self) then return end
    local now = GetTime()
    local entry = state.queue[1]
    if entry then
        local tag = self:SignGroupMessage(AUTH, entry.body)
        local sent = tag and self:SendData(FEATURE, entry.body .. "|" .. tag)
        if sent then
            table.remove(state.queue, 1)
            if entry.key then state.queued[entry.key] = nil end
        else
            entry.failures = entry.failures + 1
            if entry.failures >= 20 then
                table.remove(state.queue, 1)
                if entry.key then state.queued[entry.key] = nil end
                Changed(self, "Guide traffic is throttled. Use Update guides to retry.")
            end
            state.backoff = now + 1
        end
    end
    local incoming = state.incoming
    if incoming and now >= incoming.nextRequest then
        if now - incoming.progressAt >= 30 or incoming.retries >= 8 then
            state.incoming = nil
            state.failed[incoming.id] = incoming.hash
            Changed(self, "Guide transfer timed out. Use Update guides to retry.")
            Reconcile(self)
        else
            incoming.retries = incoming.retries + 1
            RequestWindow(self)
        end
    end
    if state.updateAt and now >= state.updateAt then
        state.updateAt = nil
        Reconcile(self, true)
        if not state.incoming and not state.installing and not next(state.pending) then
            local group = CurrentGroup(self)
            local message = next(group.sources) and "Guide check complete. Followed packs are current or their publishers are offline."
                or next(state.offers) and "Choose Follow beside a publisher, then use Update guides."
                or "No group packs found. An online member can share an export."
            Changed(self, message)
        else Changed(self) end
    end
    if state.installRetry and now >= state.installRetry then state.installRetry = nil; TryInstall(self) end
    if #state.queue > 0 or state.incoming or state.updateAt or state.installRetry then Schedule(self) end
end

Schedule = function(self)
    local state = self.restedxpState
    if state.timer or not Available(self) then return end
    local delay = math.max(INTERVAL, (state.backoff or 0) - GetTime())
    state.timer = C_Timer.NewTimer(delay, function() Tick(self) end)
end

Receive = function(self, sender, wire)
    if not Available(self) or Secret(sender) or type(sender) ~= "string" or #sender > 128
        or sender:find("[|%c]") or type(wire) ~= "string" or #wire > 246 then return false end
    local source, isSelf = self:GetDataSenderIdentity(sender)
    if not source or isSelf then return false end
    local body, signature = wire:match("^(.*)|([0-9a-f]+)$")
    if not body or not self:VerifyGroupMessage(AUTH, body, signature) then return false end
    local kind, rest = body:match("^1|([QOWD])|(.*)$")
    if not kind then return false end
    local state, group, now = self.restedxpState, CurrentGroup(self), GetTime()
    Prune(state)
    if kind == "Q" then
        if #rest > 32 or not rest:match("^[a-zA-Z0-9_-]+$") then return false end
        if state.replies[source] and now - state.replies[source] < 5 then return false end
        if not state.replies[source] and Count(state.replies) >= MAX_PEERS then return false end
        state.replies[source] = now
        if not state.replyTimer then
            state.replyTimer = C_Timer.NewTimer(0.3 + math.random() * 0.7, function()
                state.replyTimer = nil
                Announce(self)
            end)
        end
    elseif kind == "O" then
        local id, hash, length = rest:match("^([^|]+)|([^|]+)|(%d+)$")
        local size = Integer(length, MAX_BYTES)
        if not PackID(id) or not Hash(hash) or not size then return false end
        if not state.offers[id] and Count(state.offers) >= MAX_PACKS * MAX_PEERS then return false end
        state.offers[id] = state.offers[id] or {}
        if not state.offers[id][source] and Count(state.offers[id]) >= MAX_PEERS then return false end
        state.offers[id][source] = { hash = hash, size = size, seen = now }
        Changed(self)
        if group.sources[id] == source and not state.updateAt then Reconcile(self) end
    elseif kind == "W" then
        local target, id, hash, startText, countText = rest:match("^([^|]+)|([^|]+)|([^|]+)|(%d+)|(%d+)$")
        local identity = LocalIdentity(self)
        local first, count = Integer(startText, math.ceil(MAX_BYTES / CHUNK)), Integer(countText, WINDOW)
        if not identity or target ~= Address(self, identity) or not PackID(id) or not Hash(hash) or not first or not count then return false end
        if state.requests[source] and now - state.requests[source] < 0.5 then return false end
        if not state.requests[source] and Count(state.requests) >= MAX_PEERS then return false end
        local pack = SavedPack(self, id)
        if not pack or pack.hash ~= hash then return false end
        local last = math.min(first + count - 1, math.ceil(#pack.data / CHUNK))
        if first > last then return false end
        state.requests[source] = now
        for sequence = first, last do
            Queue(self, "1|D|" .. hash:sub(1, 16) .. "|" .. sequence .. "|"
                .. pack.data:sub((sequence - 1) * CHUNK + 1, sequence * CHUNK), hash .. ":" .. sequence)
        end
    elseif kind == "D" then
        local hash, sequenceText, data = rest:match("^([0-9a-f]+)|(%d+)|(.*)$")
        local incoming = state.incoming
        local sequence = incoming and Integer(sequenceText, incoming.count)
        if not incoming or source ~= incoming.source or hash ~= incoming.hash:sub(1, 16)
            or not sequence or #data ~= math.min(CHUNK, incoming.size - (sequence - 1) * CHUNK)
            or data:find("[^A-Za-z0-9+/=%%|:%d%-]") then return false end
        if incoming.chunks[sequence] then return incoming.chunks[sequence] == data end
        incoming.chunks[sequence], incoming.bytes = data, incoming.bytes + #data
        incoming.progressAt, incoming.retries = now, 0
        Changed(self, "Receiving " .. incoming.id .. " (" .. math.floor(100 * incoming.bytes / incoming.size) .. "%)...")
        if incoming.bytes == incoming.size then FinishDownload(self)
        elseif sequence % WINDOW == 0 then RequestWindow(self) end
    end
    return true
end

local function Reset(self, stopped)
    local state = self.restedxpState
    if state.timer then state.timer:Cancel() end
    if state.replyTimer then state.replyTimer:Cancel() end
    if state.jobTimer then state.jobTimer:Cancel() end
    if self.CancelRestedXPInstallation then self:CancelRestedXPInstallation() end
    state.timer, state.replyTimer, state.incoming, state.installing = nil, nil, nil, nil
    state.job, state.jobTimer = nil, nil
    state.updateAt, state.installRetry, state.backoff, state.pruneAt = nil, nil, nil, nil
    state.queue, state.queued, state.offers, state.replies, state.requests, state.pending, state.failed = {}, {}, {}, {}, {}, {}, {}
    state.generation, state.stopped = state.generation + 1, stopped
end

function addon:InitializeRestedXP()
    if self.restedxpState then return end
    if not self.savedDataReadOnly then
        if type(self.db.restedxp) ~= "table" then self.db.restedxp = {} end
        if type(self.db.restedxp.groups) ~= "table" then self.db.restedxp.groups = {} end
    end
    self.restedxpState = { generation = 0, fingerprint = self:GetGroupFingerprint(), decoded = {}, queue = {}, queued = {}, offers = {},
        replies = {}, requests = {}, pending = {}, failed = {}, status = "Use Update guides to check your group." }
    self:RegisterDataFeature(FEATURE, function(sender, wire) return Receive(self, sender, wire) end, function(connected)
        Reset(self, false)
        if connected and Available(self) then
            CurrentGroup(self)
            Queue(self, "1|Q|" .. self.dataState.requestSession, "query")
            Announce(self)
            Changed(self, "Checking available group guides...")
        else Changed(self, "Group data is disconnected.") end
    end)
    self:RegisterNotification("GROUP_CHANGED", function()
        local state, fingerprint = self.restedxpState, self:GetGroupFingerprint()
        if state.fingerprint ~= fingerprint then
            local previous = state.fingerprint
            Reset(self, false)
            state.decoded, state.fingerprint = {}, fingerprint
            if previous and not self.savedDataReadOnly then self.db.restedxp.groups[previous] = nil end
            CurrentGroup(self)
            if Available(self) then Queue(self, "1|Q|" .. self.dataState.requestSession, "query"); Announce(self) end
            -- GROUP_CHANGED already refreshes Settings; avoid a second render.
            state.status = "Guide sources reset for the selected group."
        end
    end)
    self.restedxpEvents = self:RegisterGameEvents({ "ADDON_LOADED", "PLAYER_REGEN_ENABLED", "PLAYER_LOGOUT" }, function(_, event)
        if event == "PLAYER_LOGOUT" then Reset(self, true)
        else TryInstall(self); Changed(self) end
    end)
end

function addon:ImportRestedXPPack(id, raw, sourceBattleTag)
    if not self.restedxpState or self.savedDataReadOnly then return false, "Saved preferences are read-only." end
    if not self:HasGroup() or self:IsGroupSwitching() then return false, "Join a LIT group before sharing guides." end
    if self.restedxpState.incoming or self.restedxpState.installing or self.restedxpState.job then return false, "A guide update is already in progress." end
    if type(id) == "string" and not Secret(id) then id = id:lower():gsub("%s+", "-") end
    if not PackID(id) then return false, "Use a pack ID of up to 40 letters, numbers, hyphens or underscores." end
    if type(raw) ~= "string" or #raw == 0 or #raw > MAX_BYTES then return false, "Paste an export no larger than 2 MiB." end
    local source = LocalIdentity(self)
    return StartJob(self, "Validating " .. id .. "...", function()
        return self.RestedXPCodec.Decode(raw, sourceBattleTag)
    end, function(pack, problem)
    if not pack then Changed(self, problem or "The export could not be validated."); return end
    local stored
    stored, problem = StorePack(self, id, pack, source)
    if not stored then Changed(self, problem); return end
    Announce(self)
    Changed(self, "Shared " .. id .. " (" .. pack.guideCount .. " guides).")
    end)
end

function addon:SelectRestedXPPack(id, source)
    if not self.restedxpState or self.savedDataReadOnly then return false, "Saved preferences are read-only." end
    if self.restedxpState.incoming or self.restedxpState.installing or self.restedxpState.job then return false, "Wait for the current guide update before changing its publisher." end
    local group = CurrentGroup(self)
    if not group or not PackID(id) or Secret(source) or type(source) ~= "string" then return false, "Invalid guide source." end
    local normalized = self:GetDataSenderIdentity(source)
    local offer = self.restedxpState.offers[id] and self.restedxpState.offers[id][normalized]
    if not offer or GetTime() - offer.seen > OFFER_AGE then return false, "Refresh guides to find this source again." end
    if not group.sources[id] and Count(group.sources) >= MAX_PACKS then return false, "The guide subscription limit has been reached." end
    group.sources[id] = normalized
    Changed(self, "Following " .. id .. " from " .. normalized .. ". Use Update guides to install it.")
    return true
end
addon.SetRestedXPPublisher = addon.SelectRestedXPPack

function addon:UpdateRestedXPGuides()
    if not Available(self) then return false, "Connect to your LIT group to check for updates." end
    local state = self.restedxpState
    if state.incoming or state.installing or state.job then return false, "A guide update is already in progress." end
    state.updateAt = GetTime() + 2
    Queue(self, "1|Q|" .. self.dataState.requestSession, "query")
    Announce(self)
    -- Locally published packs can also be installed without an online peer.
    local group, identity = CurrentGroup(self), LocalIdentity(self)
    for id in pairs(group.packs) do
        local saved = SavedPack(self, id)
        if saved and saved.source == identity then state.pending[id] = true end
    end
    Changed(self, "Checking guides from followed group sources...")
    Schedule(self)
    return true
end

function addon:GetRestedXPState()
    local result = self:GetRestedXPInstallation()
    local state = self.restedxpState
    result.installationProblem = result.problem
    result.packs, result.readOnly = {}, self.savedDataReadOnly == true
    result.status = state and state.status or "Guides are loading."
    result.busy = state and (state.incoming ~= nil or state.installing ~= nil or state.job ~= nil or state.updateAt ~= nil) or false
    result.canUpdate = Available(self) and not result.busy or false
    if not state then return result end
    if state.fingerprint ~= self:GetGroupFingerprint() then
        result.busy, result.canUpdate, result.status = false, false, "Guide sources are changing with your group."
        return result
    end
    local group, added = CurrentGroup(self), {}
    if not group then return result end
    local installed = Installed(self)
    for id, sources in pairs(state.offers) do
        for source, offer in pairs(sources) do
            if GetTime() - offer.seen <= OFFER_AGE then
                local saved = SavedPack(self, id)
                result.packs[#result.packs + 1] = { id = id, label = id, hash = offer.hash, source = source,
                    selected = group.sources[id] == source, canFollow = true, installed = installed[id] == offer.hash,
                    updateAvailable = installed[id] ~= offer.hash, status = installed[id] == offer.hash and "Last installed"
                        or saved and saved.hash == offer.hash and "Downloaded" or "Available" }
                added[id .. "|" .. source] = true
            end
        end
    end
    for id in pairs(group.packs) do
        local saved = SavedPack(self, id)
        if saved and not added[id .. "|" .. tostring(saved.source)] then
            result.packs[#result.packs + 1] = { id = id, label = id, hash = saved.hash,
                source = saved.source, selected = group.sources[id] == saved.source, canFollow = false,
                localPack = saved.source == LocalIdentity(self),
                installed = installed[id] == saved.hash, updateAvailable = installed[id] ~= saved.hash,
                status = installed[id] == saved.hash and "Last installed" or "Cached locally" }
        end
    end
    table.sort(result.packs, function(a, b) return a.id == b.id and (a.source or "") < (b.source or "") or a.id < b.id end)
    return result
end
