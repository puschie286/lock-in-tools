local _, addon = ...

-- Pack discovery and bounded, authenticated transfers share LIT's native channel.
-- Hashes identify content; the selected source decides which content to follow.
local FEATURE, AUTH = "guides", "restedxp"
local CHUNK, WINDOW, INTERVAL = 128, 8, 0.15
local MAX_BYTES, MAX_CACHE, MAX_PACKS, MAX_PEERS = 2097152, 8388608, 8, 32
local OFFER_AGE = 180
local TryInstall, Reconcile, Schedule, Announce, Receive, RefreshInstalled

local function Secret(value) return issecretvalue and issecretvalue(value) end
local function Hash(value)
    return not Secret(value) and type(value) == "string" and #value == 64 and not value:find("[^0-9a-f]")
end
local function PackID(value)
    return not Secret(value) and type(value) == "string" and #value > 0 and #value <= 40
        and value:match("^[a-z0-9][a-z0-9_-]*$")
end
local function PackLabel(value)
    if type(value) ~= "string" or Secret(value) then return nil end
    value = value:gsub("[|%c]", " ")
    -- Keep complete UTF-8 characters inside the native channel's byte limit.
    local last, index = 0, 1
    while index <= #value and index <= 48 do
        local first = value:byte(index)
        local size = first < 128 and 1 or first < 224 and 2 or first < 240 and 3 or 4
        if index + size - 1 > 48 then break end
        last, index = index + size - 1, index + size
    end
    value = value:sub(1, last)
    return value ~= "" and value or nil
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
local function StorePack(self, id, pack, source, options)
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
    group.packs[id] = { data = pack.data, hash = pack.hash, source = source, previous = previous,
        label = options and options.label or old and old.label,
        localInstalled = options and options.localInstalled == true or nil }
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
        if pack and (not pack.localInstalled or self.restedxpState.autoReady) then
            local label = PackLabel(pack.label)
            Queue(self, "1|O|" .. id .. "|" .. pack.hash .. "|" .. #pack.data
                .. (label and ("|" .. label) or ""), "offer:" .. id)
        end
    end
end

local function RequestInstalledRefresh(self, delay, quiet)
    local state = self.restedxpState
    if not state or state.stopped or self.savedDataReadOnly or not self:HasGroup() or self:IsGroupSwitching()
        or type(self.CollectRestedXPInstalledPacks) ~= "function" then return end
    state.refreshAt = GetTime() + (delay or 0.5)
    state.refreshingInstalled = true
    state.checkedInstalled = {}
    state.sharingStatus = "Checking imported guides for automatic sharing..."
    if Available(self) then Schedule(self) end
    if not quiet then Changed(self) end
end

local function WatchInstalled(self)
    local state = self.restedxpState
    if state.watching or not Available(self) or type(self.WatchRestedXPInstalledGuides) ~= "function" then return end
    local generation = state.generation
    state.watching = self:WatchRestedXPInstalledGuides(function()
        if state.generation == generation and Available(self) then RequestInstalledRefresh(self) end
    end) ~= false
end

local function WithdrawInstalledPack(self, id, saved)
    local state, group = self.restedxpState, CurrentGroup(self)
    group.packs[id], state.decoded[id], state.pending[id], Installed(self)[id] = nil, nil, nil, nil
    -- Drop an announcement or transfer that was queued before the native removal.
    for index = #state.queue, 1, -1 do
        local entry = state.queue[index]
        if entry.key == "offer:" .. id or entry.key and entry.key:sub(1, 64) == saved.hash then
            if entry.key then state.queued[entry.key] = nil end
            table.remove(state.queue, index)
        end
    end
    Queue(self, "1|X|" .. id, "withdraw:" .. id)
end

RefreshInstalled = function(self)
    local state = self.restedxpState
    if not state.refreshAt or GetTime() < state.refreshAt or state.incoming or state.installing or state.job then return end
    -- Finish an already downloaded update before rebuilding its pack from the
    -- native cache; that cache still contains the previous guides until import.
    if next(state.pending) then
        state.refreshAt = GetTime() + 2
        TryInstall(self)
        return
    end
    state.refreshAt = nil
    StartJob(self, "Reading installed RestedXP guides...", function()
        return self:CollectRestedXPInstalledPacks()
    end, function(packs, info)
        info = type(info) == "table" and info or { problem = info }
        if not packs then
            state.sharingStatus = info.problem or "Automatic guide sharing is unavailable."
            if info.busy then state.refreshAt = GetTime() + 2
            else state.refreshingInstalled = false end
            Changed(self)
            Schedule(self)
            return
        end
        local group, identity = CurrentGroup(self), LocalIdentity(self)
        if not group or not identity then state.refreshingInstalled = false; return end
        local found = {}
        for _, item in ipairs(packs) do if PackID(item.id) then found[item.id] = true end end
        for id in pairs(group.packs) do
            local saved = SavedPack(self, id)
            if saved and saved.localInstalled and not found[id] then
                WithdrawInstalledPack(self, id, saved)
            end
        end
        local count, skipped, problem = 0, tonumber(info.skipped) or 0, info.problem
        for _, item in ipairs(packs) do
            if PackID(item.id) and type(item.pack) == "table" and Hash(item.pack.hash) then
                local stored, failure = StorePack(self, item.id, item.pack, identity,
                    { label = item.label, localInstalled = true })
                if stored then
                    Installed(self)[item.id] = item.pack.hash
                    state.pending[item.id] = nil
                    if state.failed[item.id] == item.pack.hash then state.failed[item.id] = nil end
                    count = count + item.pack.guideCount
                else
                    skipped, problem = skipped + item.pack.guideCount, failure
                    local previous = SavedPack(self, item.id)
                    if previous and previous.localInstalled then
                        WithdrawInstalledPack(self, item.id, previous)
                    end
                end
            end
        end
        state.autoReady, state.sharedInstalledGuides, state.unshareableGuides = true, count, skipped
        state.refreshingInstalled = state.refreshAt ~= nil
        state.sharingStatus = count > 0 and ("Automatically sharing " .. count .. " imported guides.")
            or "No imported guides with recoverable source were found."
        if skipped > 0 then state.sharingStatus = state.sharingStatus .. " " .. skipped .. " unavailable." end
        if problem then state.sharingStatus = state.sharingStatus .. " " .. problem end
        Announce(self)
        if state.updateAt then state.updateAt = GetTime() + 2 end
        Changed(self, "Installed guides checked for automatic sharing.")
        Reconcile(self)
        Schedule(self)
    end)
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
    if type(self.MatchesRestedXPInstalledPack) == "function" and state.checkedInstalled[id] ~= pack.hash then
        StartJob(self, "Comparing installed " .. id .. "...", function()
            return self:MatchesRestedXPInstalledPack(pack)
        end, function(matches)
            state.checkedInstalled[id] = pack.hash
            if matches == true then
                Installed(self)[id] = pack.hash
                state.pending[id], state.failed[id] = nil, nil
                Changed(self, id .. " is already up to date. No import needed.")
                Reconcile(self)
            else TryInstall(self) end
        end)
        return
    end
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

Reconcile = function(self)
    local state, group = self.restedxpState, CurrentGroup(self)
    if not group or state.incoming or state.installing or state.job or state.refreshingInstalled then return end
    Prune(state)
    local ids = {}
    for id in pairs(group.sources) do if PackID(id) then ids[#ids + 1] = id end end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local source = group.sources[id]
        local offer = state.offers[id] and state.offers[id][source]
        local saved = SavedPack(self, id)
        if offer and GetTime() - offer.seen <= OFFER_AGE and (not saved or saved.hash ~= offer.hash)
            and state.failed[id] ~= offer.hash then
            state.incoming = { id = id, source = source, hash = offer.hash, size = offer.size, label = offer.label,
                count = math.ceil(offer.size / CHUNK), chunks = {}, bytes = 0, progressAt = GetTime(), retries = 0 }
            Changed(self, "Receiving " .. id .. " (0%)...")
            RequestWindow(self)
            return
        elseif saved and (saved.source == source or offer and offer.hash == saved.hash)
            and Installed(self)[id] ~= saved.hash and state.failed[id] ~= saved.hash then
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
    stored, problem = StorePack(self, incoming.id, pack, incoming.source, { label = incoming.label })
    if not stored then state.failed[incoming.id] = incoming.hash; Changed(self, problem); Reconcile(self); return end
    state.pending[incoming.id] = true
    Changed(self, "Received " .. incoming.id .. ".")
    Announce(self)
    TryInstall(self)
    end)
end

local function CheckCompleteMessage(self)
    local state, group = self.restedxpState, CurrentGroup(self)
    if next(state.failed) then return "Some guide updates failed. Use Update guides to retry." end
    if next(group.sources) then
        for id, source in pairs(group.sources) do
            local offer = state.offers[id] and state.offers[id][source]
            if not offer or GetTime() - offer.seen > OFFER_AGE then
                return "Some followed publishers are offline. Their latest packs could not be checked."
            end
        end
        return "Followed guide packs are up to date. No download needed."
    end
    local identity, installed = LocalIdentity(self), Installed(self)
    local shared = false
    for id in pairs(group.packs) do
        local saved = SavedPack(self, id)
        if saved and saved.source == identity then
            if installed[id] ~= saved.hash then return "Your shared packs are ready. Use Update guides to install them locally." end
            shared = true
        end
    end
    if shared then return "Your shared guide packs are up to date. No download needed." end
    if next(state.offers) then return "Choose Follow beside a publisher, then use Update guides." end
    return "No LIT-shared packs found. Recoverable imported guides are shared automatically."
end

local function Tick(self)
    local state = self.restedxpState
    state.timer = nil
    if not Available(self) then return end
    local now = GetTime()
    if state.refreshAt and now >= state.refreshAt then RefreshInstalled(self) end
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
    if state.updateAt and now >= state.updateAt and not state.refreshingInstalled then
        state.updateAt = nil
        Reconcile(self)
        if not state.incoming and not state.installing and not state.job and not next(state.pending) then
            Changed(self, CheckCompleteMessage(self))
        else Changed(self) end
    end
    if state.installRetry and now >= state.installRetry then state.installRetry = nil; TryInstall(self) end
    if #state.queue > 0 or state.incoming or state.updateAt or state.installRetry or state.refreshAt then Schedule(self) end
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
    local kind, rest = body:match("^1|([QOWDX])|(.*)$")
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
        local label
        if not id then id, hash, length, label = rest:match("^([^|]+)|([^|]+)|(%d+)|([^|]+)$") end
        local size = Integer(length, MAX_BYTES)
        if not PackID(id) or not Hash(hash) or not size or label and (#label > 48 or label:find("%c")) then return false end
        if not state.offers[id] and Count(state.offers) >= MAX_PACKS * MAX_PEERS then return false end
        state.offers[id] = state.offers[id] or {}
        if not state.offers[id][source] and Count(state.offers[id]) >= MAX_PEERS then return false end
        state.offers[id][source] = { hash = hash, size = size, seen = now, label = label }
        local noPacks = state.status:find("No LIT-shared packs found.", 1, true) == 1
        Changed(self, noPacks and not state.refreshingInstalled and CheckCompleteMessage(self) or nil)
        if group.sources[id] == source and not state.updateAt then Reconcile(self) end
    elseif kind == "X" then
        if not PackID(rest) then return false end
        local sources = state.offers[rest]
        if sources then
            sources[source] = nil
            if not next(sources) then state.offers[rest] = nil end
        end
        if state.incoming and state.incoming.id == rest and state.incoming.source == source then
            state.incoming = nil
            Changed(self, "The publisher no longer has this installed guide pack.")
            Reconcile(self)
        else Changed(self) end
    elseif kind == "W" then
        local target, id, hash, startText, countText = rest:match("^([^|]+)|([^|]+)|([^|]+)|(%d+)|(%d+)$")
        local identity = LocalIdentity(self)
        local first, count = Integer(startText, math.ceil(MAX_BYTES / CHUNK)), Integer(countText, WINDOW)
        if not identity or target ~= Address(self, identity) or not PackID(id) or not Hash(hash) or not first or not count then return false end
        if state.requests[source] and now - state.requests[source] < 0.5 then return false end
        if not state.requests[source] and Count(state.requests) >= MAX_PEERS then return false end
        local pack = SavedPack(self, id)
        if not pack or pack.hash ~= hash or pack.localInstalled and not state.autoReady then return false end
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
    if self.StopWatchingRestedXPInstalledGuides then self:StopWatchingRestedXPInstalledGuides() end
    state.timer, state.replyTimer, state.incoming, state.installing = nil, nil, nil, nil
    state.job, state.jobTimer = nil, nil
    state.updateAt, state.installRetry, state.backoff, state.pruneAt = nil, nil, nil, nil
    state.refreshAt, state.refreshingInstalled, state.watching, state.autoReady = nil, false, false, false
    state.checkedInstalled, state.sharedInstalledGuides, state.unshareableGuides = {}, 0, 0
    state.sharingStatus = "Imported guides are shared automatically with your LIT group."
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
        replies = {}, requests = {}, pending = {}, failed = {}, checkedInstalled = {}, status = "Use Update guides to check your group." }
    self:RegisterDataFeature(FEATURE, function(sender, wire) return Receive(self, sender, wire) end, function(connected)
        Reset(self, false)
        if connected and Available(self) then
            CurrentGroup(self)
            self.restedxpState.updateAt = GetTime() + 2
            WatchInstalled(self)
            RequestInstalledRefresh(self, 0, true)
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
            if Available(self) then
                WatchInstalled(self)
                RequestInstalledRefresh(self, 0, true)
                Queue(self, "1|Q|" .. self.dataState.requestSession, "query")
                Announce(self)
            end
            -- GROUP_CHANGED already refreshes Settings; avoid a second render.
            state.status = "Guide sources reset for the selected group."
        end
    end)
    self.restedxpEvents = self:RegisterGameEvents({ "ADDON_LOADED", "PLAYER_REGEN_ENABLED", "PLAYER_LOGOUT" }, function(_, event)
        if event == "PLAYER_LOGOUT" then Reset(self, true)
        else
            if event == "ADDON_LOADED" and Available(self) then
                WatchInstalled(self)
                RequestInstalledRefresh(self)
            end
            TryInstall(self)
            Changed(self)
        end
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
    -- An explicit import owns the status even if login discovery is still finishing.
    self.restedxpState.updateAt = nil
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
    WatchInstalled(self)
    RequestInstalledRefresh(self, 0, true)
    Queue(self, "1|Q|" .. self.dataState.requestSession, "query")
    Announce(self)
    -- Locally published packs can also be installed without an online peer.
    local group, identity = CurrentGroup(self), LocalIdentity(self)
    -- A manual request retries failures once, including when source recovery
    -- completes before discovery does. Later completion must not clear a new failure.
    for id in pairs(group.sources) do state.failed[id] = nil end
    for id in pairs(group.packs) do
        local saved = SavedPack(self, id)
        if saved and saved.source == identity and Installed(self)[id] ~= saved.hash then
            state.failed[id], state.pending[id] = nil, true
        end
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
    result.sharingStatus = state and state.sharingStatus
    result.sharedInstalledGuides = state and state.sharedInstalledGuides or 0
    result.unshareableGuides = state and state.unshareableGuides or 0
    result.refreshingInstalled = state and state.refreshingInstalled or false
    result.busy = state and (state.incoming ~= nil or state.installing ~= nil or state.job ~= nil
        or state.updateAt ~= nil or state.refreshingInstalled) or false
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
                result.packs[#result.packs + 1] = { id = id, label = offer.label or saved and saved.label or id, hash = offer.hash, source = source,
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
            result.packs[#result.packs + 1] = { id = id, label = saved.label or id, hash = saved.hash,
                source = saved.source, selected = group.sources[id] == saved.source, canFollow = false,
                localPack = saved.source == LocalIdentity(self),
                installed = installed[id] == saved.hash, updateAvailable = installed[id] ~= saved.hash,
                status = installed[id] == saved.hash and "Last installed" or "Cached locally" }
        end
    end
    table.sort(result.packs, function(a, b) return a.id == b.id and (a.source or "") < (b.source or "") or a.id < b.id end)
    return result
end
