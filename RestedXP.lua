local _, addon = ...

-- Pack discovery and bounded, authenticated transfers share LIT's native channel.
-- Installed discovery compares guide IDs/versions; transfers keep native cache
-- compression intact. Only the recipient converts it for RestedXP's importer.
local FEATURE, AUTH = "guides", "restedxp"
local CHUNK, WINDOW, INTERVAL = 128, 8, 0.15
local PREPARATION_TIMEOUT, PREPARATION_RETRY = 120, 8
local MAX_BYTES, MAX_CACHE, MAX_PACKS, MAX_PEERS = 2097152, 8388608, 8, 32
local OFFER_AGE = 180
local TryInstall, Reconcile, Schedule, Announce, Receive, RefreshInstalled, CheckCompleteMessage, ServeWindow
local PeerTestFinish, PeerTestSelect

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
local function Changed(self, message, attention)
    if message then
        self.restedxpState.status = message
        self.restedxpState.attention = attention == true
    end
    self:Notify("RESTEDXP_CHANGED")
end
local function BackgroundJob(state)
    return state.job and state.job.kind == "installed"
end
local function ForegroundJob(state)
    if state.job and not BackgroundJob(state) then return state.job end
end
local function WorkClock()
    if type(GetTimePreciseSec) == "function" then return GetTimePreciseSec end
    if type(debugprofilestop) == "function" then return function() return debugprofilestop() / 1000 end end
end
local function WallTime()
    return type(GetTimePreciseSec) == "function" and GetTimePreciseSec() or GetTime()
end
local function NewTraffic()
    return { Q = 0, O = 0, V = 0, W = 0, D = 0, X = 0, messages = 0, bytes = 0 }
end
local function NewPerformance()
    return { startedAt = WallTime(), tx = NewTraffic(), rx = NewTraffic(), jobs = {},
        rejectedSends = 0, retryWindows = 0, duplicateChunks = 0,
        serving = { addressed = 0, other = 0, windows = 0, preparing = 0, busy = 0,
            unavailable = 0, queueFull = 0, cacheBypasses = 0 } }
end
local function AddTraffic(traffic, kind, bytes)
    traffic[kind], traffic.messages, traffic.bytes = traffic[kind] + 1, traffic.messages + 1, traffic.bytes + bytes
end
local function PeerTestPhase(state, name)
    local run = state.peerTest
    if not run then return end
    local report, now = run.report, WallTime()
    local previous = report.phases[report.phase]
    if previous and previous.startedAt then previous.wall = math.max(0, now - previous.startedAt) end
    report.phase = name
    report.phases[name].startedAt = now
end
local function PeerTestIncoming(state, incoming)
    local run = state.peerTest
    if not run or not incoming or not incoming.test then return end
    run.report.bytes, run.report.expectedBytes = incoming.bytes, incoming.size
    run.report.retries = incoming.retryCount
end
local function RecordWire(state, direction, body, bytes)
    local performance = state.performance
    if not performance then return end
    local kind = body:match("^1|([QOVWDX])|")
    if not kind then return end
    local traffic = performance[direction]
    AddTraffic(traffic, kind, bytes)
    if direction == "tx" and kind == "Q" then state.lastQuerySentAt = GetTime() end
    local run = state.peerTest
    if run then
        local report = run.report
        AddTraffic(report[direction], kind, bytes)
        AddTraffic(report.phases[report.phase][direction], kind, bytes)
        if direction == "tx" and kind == "Q" and not run.querySentAt then
            run.querySentAt = GetTime()
            report.queryWaitWall = math.max(0, WallTime() - report.startedAt)
            state.updateAt = GetTime() + 10
            if run.timer then run.timer:Cancel() end
            run.timer = C_Timer.NewTimer(10, run.discoveryTimeout)
        end
    end
    if kind == "O" or kind == "V" then
        local field = direction == "tx" and "firstPublishedAt" or "firstOfferAt"
        performance[field] = performance[field] or WallTime()
    end
end
local function StartJob(self, message, work, complete, kind)
    local state = self.restedxpState
    if state.job then return false, "Guide processing is already in progress." end
    local job = { thread = coroutine.create(work), generation = state.generation, kind = kind }
    state.job = job
    Changed(self, kind ~= "installed" and message or nil)
    local clock = WorkClock()
    local metrics = { startedAt = WallTime(), wall = 0, cpu = clock and 0, maxSlice = clock and 0, slices = 0, resumes = 0 }
    job.metrics = metrics
    local function Finish(value, problem)
        metrics.wall = math.max(0, WallTime() - metrics.startedAt)
        if type(problem) == "table" and type(problem.metrics) == "table" then metrics.metrics = problem.metrics end
        metrics.metadataOnly = type(problem) == "table" and problem.metadataOnly == true
        if state.performance then state.performance.jobs[kind or "processing"] = metrics end
        state.job = nil
        complete(value, problem, metrics)
    end
    local function Step()
        state.jobTimer = nil
        if state.job ~= job or state.generation ~= job.generation then return end
        -- Several cheap checkpoints fit in one frame. The clock bounds work,
        -- while the resume cap also covers clients without a profiling clock.
        local sliceStart = clock and clock()
        local deadline = sliceStart and sliceStart + 0.002
        metrics.slices = metrics.slices + 1
        local function RecordSlice()
            if not clock then return end
            local elapsed = math.max(0, clock() - sliceStart)
            metrics.cpu, metrics.maxSlice = metrics.cpu + elapsed, math.max(metrics.maxSlice, elapsed)
        end
        for _ = 1, clock and 32 or 8 do
            metrics.resumes = metrics.resumes + 1
            local success, value, problem = coroutine.resume(job.thread)
            if not success then
                RecordSlice()
                Finish(nil, "Guide processing failed. Check the export and try again.")
                return
            elseif coroutine.status(job.thread) == "dead" then
                RecordSlice()
                Finish(value, problem)
                return
            end
            if state.job ~= job or state.generation ~= job.generation then return end
            if deadline and clock() >= deadline then break end
        end
        RecordSlice()
        state.jobTimer = C_Timer.NewTimer(0.01, Step)
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
local function IsLocalAddress(self, target)
    -- Native addon senders can use the unmodified player name. Accept the same
    -- local aliases as the data layer instead of assuming UnitFullName matches.
    if type(self.GetDataSelfIdentities) == "function" then
        for identity in pairs(self:GetDataSelfIdentities()) do
            if target == Address(self, identity) then return true end
        end
        return false
    end
    local identity = LocalIdentity(self)
    return identity and target == Address(self, identity) or false
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
local function Queue(self, body, key, notBefore)
    local state = self.restedxpState
    if not Available(self) or #body + 65 + 9 > 255 then return false end
    if key and state.queued[key] then
        state.queued[key].body = body
        state.queued[key].notBefore = notBefore
        return true
    end
    if #state.queue >= 64 then return false end
    local entry = { body = body, key = key, failures = 0, notBefore = notBefore }
    state.queue[#state.queue + 1] = entry
    if key then state.queued[key] = entry end
    Schedule(self)
    return true
end

PeerTestFinish = function(self, status, message)
    local state, now = self.restedxpState, WallTime()
    local run = state.peerTest
    if not run then return end
    PeerTestIncoming(state, state.incoming)
    local report = run.report
    local phase = report.phases[report.phase]
    if phase.startedAt then phase.wall = math.max(0, now - phase.startedAt) end
    report.wall, report.status, report.message = math.max(0, now - report.startedAt), status, message
    if run.timer then run.timer:Cancel() end
    if state.incoming and state.incoming.test then state.incoming = nil end
    if run.checking and state.job then
        if state.jobTimer then state.jobTimer:Cancel() end
        state.job, state.jobTimer = nil, nil
    end
    if run.id then
        state.pending[run.id] = nil
        state.installRetry = nil
        if state.installing == run.id then
            if self.CancelRestedXPInstallation then self:CancelRestedXPInstallation() end
            state.installing = nil
        end
        local group = CurrentGroup(self)
        if not group or group.sources[run.id] ~= run.source then
            state.failed[run.id] = run.previousFailed
        elseif status ~= "complete" then state.failed[run.id] = run.revision end
    end
    for index = #state.queue, 1, -1 do
        local entry = state.queue[index]
        if entry.test == run then
            if entry.key then state.queued[entry.key] = nil end
            table.remove(state.queue, index)
        end
    end
    state.peerTest, state.updateAt = nil, nil
    state.performance.peerTest = report
    Changed(self, message, status == "failed")
    if self.PrintRestedXPPeerTest then self:PrintRestedXPPeerTest(report) end
end
local function SavedPack(self, id)
    local group = CurrentGroup(self)
    local saved = group and group.packs[id]
    if type(saved) ~= "table" or not Hash(saved.hash) or type(saved.data) ~= "string"
        or #saved.data == 0 or #saved.data > MAX_BYTES then return nil end
    return saved
end
local function Revision(pack)
    return pack and (pack.revision or pack.hash)
end
local function ReadyPack(pack)
    return pack and (pack.cacheFormat and type(pack.cachedSources) == "table"
        or not pack.cacheFormat and type(pack.guides) == "table")
end
local function DecodeTransfer(self, data, id, revision)
    local codec = self.RestedXPCodec
    if type(codec.IsCachedPack) == "function" and codec.IsCachedPack(data) then
        if not Hash(revision) or type(self.RestedXPCodec.DecodeCachedPack) ~= "function" then
            return nil, "This cached guide transfer is unsupported. Reload LockInTools and try again."
        end
        -- Framing, compressed lengths and completeness are checked here. The
        -- guide content stays compressed until recipient-side native conversion.
        local pack, problem = self.RestedXPCodec.DecodeCachedPack(data)
        if pack then pack.id, pack.hash, pack.revision = id, revision, revision end
        return pack, problem
    end
    return self.RestedXPCodec.DecodeCanonical(data)
end
local function DecodeSaved(self, id)
    local saved = SavedPack(self, id)
    if not saved then return nil, "This pack is not available locally." end
    local state = self.restedxpState
    local cached = state.decoded[id]
    if cached and cached.hash == saved.hash and ReadyPack(cached) then return cached end
    local pack, problem = DecodeTransfer(self, saved.data, id, saved.revision)
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
    local previous = old and old.hash ~= pack.hash and { data = old.data, hash = old.hash,
        revision = old.revision, cacheFormat = old.cacheFormat, guideCount = old.guideCount,
        id = old.id, expectedGuides = old.expectedGuides } or old and old.previous
    if type(previous) ~= "table" or type(previous.data) ~= "string" or not Hash(previous.hash) then previous = nil end
    if previous then total = total + #previous.data end
    for other, saved in pairs(group.packs) do
        if other ~= id and type(saved) == "table" and type(saved.previous) == "table"
            and type(saved.previous.data) == "string" then total = total + #saved.previous.data end
    end
    if total > MAX_CACHE then return false, "There is not enough guide cache space for this update." end
    group.packs[id] = { data = pack.data, hash = pack.hash, source = source, previous = previous,
        label = options and options.label or old and old.label,
        guideCount = pack.guideCount,
        revision = options and options.revision,
        cacheFormat = pack.cacheFormat == true or nil,
        id = pack.cacheFormat and id or nil,
        expectedGuides = pack.cacheFormat and pack.expectedGuides or nil,
        localInstalled = options and options.localInstalled == true or nil }
    local decoded = self.restedxpState.decoded[id]
    if ReadyPack(pack) or not decoded or decoded.hash ~= pack.hash then self.restedxpState.decoded[id] = pack end
    return true
end

Announce = function(self, requestedSince)
    local group = CurrentGroup(self)
    if not group or not Available(self) then return end
    local ids = {}
    local added = {}
    for id in pairs(self.restedxpState.inventory) do if PackID(id) then ids[#ids + 1], added[id] = id, true end end
    for id in pairs(group.packs) do if PackID(id) and not added[id] then ids[#ids + 1] = id end end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local pack = SavedPack(self, id)
        local inventory = self.restedxpState.inventory[id]
        if inventory or pack and (not pack.localInstalled or self.restedxpState.autoReady) then
            local item = inventory or pack
            local label = PackLabel(item.label)
            local versioned = inventory ~= nil or pack.revision ~= nil
            local body = "1|" .. (versioned and "V" or "O") .. "|" .. id .. "|" .. (inventory and inventory.revision or Revision(pack))
                .. "|" .. (versioned and item.guideCount or #pack.data) .. (label and ("|" .. label) or "")
            local sent = self.restedxpState.sentOffers[id]
            if not sent or sent.body ~= body or requestedSince and sent.at <= requestedSince then
                Queue(self, body, "offer:" .. id)
            end
        end
    end
end

local function RequestInstalledRefresh(self, delay, quiet)
    local state = self.restedxpState
    if not state or state.stopped or self.savedDataReadOnly or not self:HasGroup() or self:IsGroupSwitching()
        or type(self.CollectRestedXPInstalledInventory) ~= "function" and type(self.CollectRestedXPInstalledPacks) ~= "function" then return end
    -- The collector detects mutations during its scan and retries itself. A
    -- duplicate login/observer request must not queue the same scan again.
    if BackgroundJob(state) then return end
    local at = GetTime() + (delay or 0.5)
    if state.refreshAt then
        state.refreshAt = math.min(state.refreshAt, at)
        return
    end
    state.refreshAt = at
    state.refreshingInstalled = true
    state.checkedInstalled = {}
    state.sharingStatus = "Checking guide IDs and versions..."
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
    if state.servedPack and state.servedPack.id == id then state.servedPack = nil end
    state.sentOffers[id] = nil
    -- Drop an announcement or transfer that was queued before the native removal.
    for index = #state.queue, 1, -1 do
        local entry = state.queue[index]
        if entry.key == "offer:" .. id or entry.key and entry.key:sub(1, 64) == Revision(saved) then
            if entry.key then state.queued[entry.key] = nil end
            table.remove(state.queue, index)
        end
    end
    Queue(self, "1|X|" .. id, "withdraw:" .. id)
end

local function InstalledRefreshChanged(self)
    local state = self.restedxpState
    local awaitingPreparation = state.status == "Guide discovery complete. Imported guides are still being prepared."
        or state.status:find("No LIT-shared packs found.", 1, true) == 1
    if awaitingPreparation and not state.updateAt and not state.incoming and not state.installing
        and not state.job and not next(state.pending) then
        Changed(self, CheckCompleteMessage(self))
    else Changed(self) end
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
    local metadataOnly = type(self.CollectRestedXPInstalledInventory) == "function"
    StartJob(self, "Reading installed RestedXP guides...", function()
        if metadataOnly then
            local items, info = self:CollectRestedXPInstalledInventory()
            info = type(info) == "table" and info or { problem = info }
            info.metadataOnly = true
            return items, info
        end
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
        if metadataOnly then
            local inventory, count, skipped = {}, 0, tonumber(info.skipped) or 0
            for _, item in ipairs(packs) do
                if PackID(item.id) and Hash(item.revision) and type(item.guideCount) == "number"
                    and item.guideCount >= 1 and item.guideCount <= 10000 and Count(inventory) < MAX_PACKS then
                    inventory[item.id] = item
                    local saved = SavedPack(self, item.id)
                    -- A recipient can own additional guides in this group.
                    -- Keep the followed subset's version when all its native
                    -- guide IDs/versions are installed, without opening source.
                    if saved and saved.cacheFormat and type(self.MatchesRestedXPCachedPack) == "function"
                        and self:MatchesRestedXPCachedPack(saved) then
                        Installed(self)[item.id] = Revision(saved)
                    else Installed(self)[item.id] = item.revision end
                    count = count + item.guideCount
                else skipped = skipped + (tonumber(item.guideCount) or 1) end
            end
            for id in pairs(state.inventory) do
                if not inventory[id] and not SavedPack(self, id) then
                    state.sentOffers[id], Installed(self)[id] = nil, nil
                    Queue(self, "1|X|" .. id, "withdraw:" .. id)
                end
            end
            for id in pairs(group.packs) do
                local saved = SavedPack(self, id)
                if saved and saved.localInstalled and not inventory[id] then WithdrawInstalledPack(self, id, saved) end
            end
            state.inventory = inventory
            local served = state.servedPack
            if served and (not inventory[served.id] or inventory[served.id].revision ~= served.revision) then
                state.servedPack = nil
            end
            state.autoReady, state.sharedInstalledGuides, state.unshareableGuides = true, count, skipped
            state.refreshingInstalled = state.refreshAt ~= nil
            if self.AcknowledgeRestedXPInstalledGuides then self:AcknowledgeRestedXPInstalledGuides() end
            state.sharingStatus = "Sharing " .. count .. " guides by ID and version; cached guides are sent compressed when requested."
            if info.problem then state.sharingStatus = state.sharingStatus .. " " .. info.problem end
            Announce(self)
            Reconcile(self)
            InstalledRefreshChanged(self)
            Schedule(self)
            return
        end
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
        if self.AcknowledgeRestedXPInstalledGuides then self:AcknowledgeRestedXPInstalledGuides() end
        state.sharingStatus = count > 0 and ("Automatically sharing " .. count .. " imported guides.")
            or "No imported guides with recoverable source were found."
        if skipped > 0 then state.sharingStatus = state.sharingStatus .. " " .. skipped .. " unavailable." end
        if problem then state.sharingStatus = state.sharingStatus .. " " .. problem end
        Announce(self)
        Reconcile(self)
        InstalledRefreshChanged(self)
        Schedule(self)
    end, "installed")
end

local function RequestWindow(self)
    local state, incoming = self.restedxpState, self.restedxpState.incoming
    if not incoming or not Available(self) then return end
    if not incoming.size then
        incoming.windowFirst, incoming.windowLast = 1, WINDOW
        local notBefore = math.max(GetTime(), (state.wantSentAt or -1) + 0.55)
        incoming.nextRequest = notBefore + PREPARATION_RETRY
        Queue(self, "1|W|" .. Address(self, incoming.source) .. "|" .. incoming.id .. "|" .. incoming.hash
            .. "|1|" .. WINDOW, "want", notBefore)
        if incoming.test and state.queued.want then state.queued.want.test = state.peerTest end
        Schedule(self)
        return
    end
    local first = 1
    while incoming.chunks[first] do first = first + 1 end
    if first > incoming.count then return end
    local last = first
    while last < math.min(first + WINDOW - 1, incoming.count) and not incoming.chunks[last + 1] do last = last + 1 end
    incoming.windowFirst, incoming.windowLast = first, last
    -- Respect the publisher's request cooldown even for a one-chunk recovery.
    local notBefore = math.max(GetTime(), (state.wantSentAt or -1) + 0.55)
    incoming.nextRequest = notBefore + 4
    Queue(self, "1|W|" .. Address(self, incoming.source) .. "|" .. incoming.id .. "|" .. incoming.hash
        .. "|" .. first .. "|" .. (last - first + 1), "want", notBefore)
    if incoming.test and state.queued.want then state.queued.want.test = state.peerTest end
    Schedule(self)
end

PeerTestSelect = function(self, early)
    local state, group = self.restedxpState, CurrentGroup(self)
    local run = state.peerTest
    if not run or run.report.phase ~= "discovery" or state.updateAt and not early then return end
    if state.job or state.incoming or state.installing or state.refreshingInstalled then return end
    -- Gather the normal discovery replies before drawing, so the earliest
    -- response cannot decide the random publisher or hide its later packs.
    if run.random and early then return end
    local candidates = {}
    for id, sources in pairs(state.offers) do
        for source, offer in pairs(sources) do
            if (not run.requestedSource or source == run.requestedSource)
                and (not run.requestedID or id == run.requestedID)
                and run.querySentAt and offer.seen >= run.querySentAt and GetTime() - offer.seen <= OFFER_AGE then
                candidates[#candidates + 1] = { id = id, source = source, offer = offer,
                    followed = group.sources[id] == source }
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.followed ~= b.followed then return a.followed end
        if a.source ~= b.source then return a.source < b.source end
        return a.id < b.id
    end)
    local chosen = candidates[1]
    if run.random and chosen then
        local publishers, packs = {}, {}
        for _, candidate in ipairs(candidates) do
            if not packs[candidate.source] then
                publishers[#publishers + 1], packs[candidate.source] = candidate.source, {}
            end
            local available = packs[candidate.source]
            available[#available + 1] = candidate
        end
        table.sort(publishers)
        local available = packs[publishers[math.random(#publishers)]]
        table.sort(available, function(a, b) return a.id < b.id end)
        -- Equal chance per player first; sharing more packs must not make a
        -- player more likely to be selected.
        chosen = available[math.random(#available)]
    end
    if early and (not chosen or not run.requestedSource and not run.requestedID
        and next(group.sources) and not chosen.followed) then return end
    if not chosen then
        PeerTestFinish(self, "failed", run.querySentAt and "No matching online publisher answered guide discovery."
            or "The guide discovery request could not be sent.")
        return
    end
    local offer = chosen.offer
    state.updateAt = nil
    run.previousFailed = state.failed[chosen.id]
    run.id, run.source, run.revision = chosen.id, chosen.source, offer.hash
    run.report.id, run.report.source = chosen.id, chosen.source
    PeerTestPhase(state, "transfer")
    if run.timer then run.timer:Cancel(); run.timer = nil end
    -- This one-time selection leaves followed publishers and installed markers
    -- intact. Tests deliberately fetch the pack even when it is already cached.
    state.incoming = { id = chosen.id, source = chosen.source, hash = offer.hash, size = offer.size, label = offer.label,
        startedAt = WallTime(), retryCount = 0, versioned = offer.versioned,
        count = offer.size and math.ceil(offer.size / CHUNK), chunks = {}, bytes = 0,
        progressAt = GetTime(), retries = 0, test = true }
    Changed(self, "Testing guide transfer from " .. chosen.source .. ": " .. chosen.id .. ".")
    RequestWindow(self)
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
    if not saved then state.pending[id] = nil; Changed(self, "This guide pack is unavailable.", true); return end
    local pack, problem = state.decoded[id]
    if not pack or pack.hash ~= saved.hash or not ReadyPack(pack) then
        StartJob(self, "Checking cached " .. id .. "...", function() return DecodeSaved(self, id) end,
            function(decoded, failure)
                if not decoded then state.pending[id] = nil; state.failed[id] = Revision(saved); Changed(self, failure, true)
                else TryInstall(self) end
            end)
        return
    end
    local generation = state.generation
    local revision = Revision(saved)
    local test = state.peerTest and state.peerTest.id == id and state.peerTest.report.phase == "import"
    if not test and pack.cacheFormat and type(self.MatchesRestedXPCachedPack) == "function" and self:MatchesRestedXPCachedPack(pack) then
        Installed(self)[id] = revision
        state.pending[id], state.failed[id] = nil, nil
        Changed(self, id .. " is already up to date. No import needed.")
        Reconcile(self)
        return
    end
    if not test and not saved.revision and type(self.MatchesRestedXPInstalledPack) == "function" and state.checkedInstalled[id] ~= pack.hash then
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
    local installStarted = WallTime()
    Changed(self, "Installing " .. id .. "...")
    local accepted, code
    accepted, problem, code = self:InstallRestedXPPack(pack, function(success, failure, info)
        if state.generation ~= generation or state.installing ~= id then return end
        state.installing, state.pending[id] = nil, nil
        state.performance.lastInstall = { wall = math.max(0, WallTime() - installStarted), success = success == true }
        if success then
            Installed(self)[id] = revision
            state.failed[id] = nil
            Changed(self, "Installed " .. id .. ".")
        else
            state.failed[id] = revision
            Changed(self, failure or "RestedXP could not install the guide pack.", true)
        end
        if test and state.peerTest then
            local report = state.peerTest.report
            info = type(info) == "table" and info or {}
            report.importUnchanged, report.conversionWall, report.nativeWall = info.unchanged == true, info.conversionWall, info.nativeWall
            PeerTestFinish(self, success and "complete" or "failed", success and "Two-player guide test completed."
                or failure or "RestedXP could not install the guide pack.")
        end
        Reconcile(self)
    end, test and { test = true } or nil)
    if not accepted and state.installing == id then
        state.installing = nil
        -- Busy native imports can finish without a public event; retry at a modest cadence.
        if code == "busy" then state.installRetry = GetTime() + 2; Schedule(self)
        else
            state.pending[id] = nil; state.failed[id] = revision
            if test then PeerTestFinish(self, "failed", problem or "The guide pack could not be installed.") end
        end
        Changed(self, problem or "The guide pack could not be installed.", code ~= "busy")
    end
end

Reconcile = function(self)
    local state, group = self.restedxpState, CurrentGroup(self)
    if not group or state.incoming or state.installing or state.job or state.refreshingInstalled then return end
    if state.peerTest then
        if state.peerTest.report.phase == "discovery" then PeerTestSelect(self, state.updateAt ~= nil)
        elseif state.peerTest.report.phase == "import" then TryInstall(self) end
        return
    end
    Prune(state)
    local ids = {}
    for id in pairs(group.sources) do if PackID(id) then ids[#ids + 1] = id end end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local source = group.sources[id]
        local offer = state.offers[id] and state.offers[id][source]
        local saved = SavedPack(self, id)
        if offer and GetTime() - offer.seen <= OFFER_AGE and Installed(self)[id] ~= offer.hash
            and (not saved or Revision(saved) ~= offer.hash)
            and state.failed[id] ~= offer.hash then
            state.incoming = { id = id, source = source, hash = offer.hash, size = offer.size, label = offer.label,
                startedAt = WallTime(), retryCount = 0,
                versioned = offer.versioned, count = offer.size and math.ceil(offer.size / CHUNK),
                chunks = {}, bytes = 0, progressAt = GetTime(), retries = 0 }
            Changed(self, "Receiving " .. id .. " (0%)...")
            RequestWindow(self)
            return
        -- A failed newer transfer must not reinstall an older cached revision.
        -- Use the cache only for the currently offered version, or offline when
        -- no newer availability is known for the followed publisher.
        elseif saved and (offer and offer.hash == Revision(saved) or not offer and saved.source == source)
            and Installed(self)[id] ~= Revision(saved) and state.failed[id] ~= Revision(saved) then
            state.pending[id] = true
        end
    end
    TryInstall(self)
end

local function FinishDownload(self)
    local state, incoming = self.restedxpState, self.restedxpState.incoming
    -- Preparing an outgoing pack may overlap an incoming transfer. Keep a
    -- completed download until that bounded job releases the processing slot.
    if state.job then incoming.complete = true; return end
    local data = table.concat(incoming.chunks)
    local receivedAt = WallTime()
    state.incoming = nil
    local test = incoming.test and state.peerTest
    if test then
        test.report.bytes, test.report.retries = incoming.size, incoming.retryCount
        PeerTestPhase(state, "import")
        test.checking = true
        test.timer = C_Timer.NewTimer(300, function()
            if state.peerTest == test then PeerTestFinish(self, "failed", "The test timed out waiting for guide import.") end
        end)
    end
    StartJob(self, "Checking transfer " .. incoming.id .. "...", function()
        return DecodeTransfer(self, data, incoming.id, incoming.versioned and incoming.hash or nil)
    end, function(pack, problem)
    if test then test.checking = false end
    if not pack or not incoming.versioned and pack.hash ~= incoming.hash then
        state.failed[incoming.id] = incoming.hash
        Changed(self, problem or "The downloaded pack failed verification.", true)
        if test then PeerTestFinish(self, "failed", problem or "The downloaded pack failed transfer checks.") end
        Reconcile(self)
        return
    end
    local stored
    stored, problem = StorePack(self, incoming.id, pack, incoming.source,
        { label = incoming.label, revision = incoming.versioned and incoming.hash or nil })
    if not stored then
        state.failed[incoming.id] = incoming.hash; Changed(self, problem, true)
        if test then PeerTestFinish(self, "failed", problem) end
        Reconcile(self)
        return
    end
    state.pending[incoming.id] = true
    state.performance.lastTransfer = { wall = math.max(0, receivedAt - incoming.startedAt), bytes = incoming.size,
        verified = math.max(0, WallTime() - receivedAt), retries = incoming.retryCount }
    Changed(self, "Received " .. incoming.id .. ".")
    Announce(self)
    TryInstall(self)
    end)
end

CheckCompleteMessage = function(self)
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
        if saved and saved.source == identity and not (saved.revision and state.inventory[id]) then
            if installed[id] ~= Revision(saved) then return "Your shared packs are ready. Use Update guides to install them locally." end
            shared = true
        end
    end
    if next(state.inventory) then return "Installed guide IDs and versions are shared with your group." end
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
    local entry, entryIndex
    for index, candidate in ipairs(state.queue) do
        if not candidate.notBefore or now >= candidate.notBefore then entry, entryIndex = candidate, index; break end
    end
    if entry then
        if entry.key == "want" and not state.incoming then
            table.remove(state.queue, entryIndex)
            state.queued[entry.key] = nil
            entry = nil
        end
    end
    if entry then
        local tag = self:SignGroupMessage(AUTH, entry.body)
        local sent = tag and self:SendData(FEATURE, entry.body .. "|" .. tag)
        if sent then
            RecordWire(state, "tx", entry.body, #entry.body + 65 + 9)
            if entry.key and entry.key:sub(1, 6) == "offer:" then
                state.sentOffers[entry.key:sub(7)] = { body = entry.body, at = now }
            elseif entry.key == "want" then state.wantSentAt = now end
            table.remove(state.queue, entryIndex)
            if entry.key then state.queued[entry.key] = nil end
        else
            state.performance.rejectedSends = state.performance.rejectedSends + 1
            entry.failures = entry.failures + 1
            if entry.failures >= 20 then
                table.remove(state.queue, entryIndex)
                if entry.key then state.queued[entry.key] = nil end
                Changed(self, "Guide traffic is throttled. Use Update guides to retry.", true)
                if state.peerTest and entry.test == state.peerTest then
                    PeerTestFinish(self, "failed", "The test could not send guide traffic through the data channel.")
                end
            end
            state.backoff = now + 1
        end
    end
    local incoming = state.incoming
    if incoming and incoming.complete and not state.job then
        FinishDownload(self)
        incoming = state.incoming
    end
    if incoming and now >= incoming.nextRequest then
        -- An installed pack has no encoded size until the publisher prepares
        -- its requested source. Allow that work separately from a stalled wire.
        local timedOut = incoming.complete and now - incoming.progressAt >= PREPARATION_TIMEOUT
            or not incoming.complete and (incoming.size and (now - incoming.progressAt >= 30 or incoming.retries >= 8)
                or not incoming.size and now - incoming.progressAt >= PREPARATION_TIMEOUT)
        if timedOut then
            PeerTestIncoming(state, incoming)
            state.incoming = nil
            state.failed[incoming.id] = incoming.hash
            Changed(self, "Guide transfer timed out. Use Update guides to retry.", true)
            if incoming.test then PeerTestFinish(self, "failed", "The guide transfer timed out during the test.") end
            Reconcile(self)
        elseif not incoming.complete then
            incoming.retries = incoming.retries + 1
            incoming.retryCount = incoming.retryCount + 1
            state.performance.retryWindows = state.performance.retryWindows + 1
            RequestWindow(self)
        else incoming.nextRequest = now + PREPARATION_RETRY
        end
    end
    if state.updateAt and now >= state.updateAt then
        local test = state.peerTest
        state.updateAt = nil
        Reconcile(self)
        if test then
            if state.peerTest then Changed(self) end
        elseif not state.incoming and not state.installing and not ForegroundJob(state) and not next(state.pending) then
            Changed(self, state.refreshingInstalled and "Guide discovery complete. Imported guides are still being prepared."
                or CheckCompleteMessage(self))
        else Changed(self) end
        state.performance.discoveryAt = WallTime()
    end
    if not state.performance.firstReadyAt and not state.peerTest and not state.updateAt and not state.incoming
        and not state.installing and not ForegroundJob(state) then state.performance.firstReadyAt = WallTime() end
    if state.installRetry and now >= state.installRetry then state.installRetry = nil; TryInstall(self) end
    if #state.queue > 0 or state.incoming or state.updateAt or state.installRetry or state.refreshAt then Schedule(self) end
end

Schedule = function(self)
    local state = self.restedxpState
    if state.timer or not Available(self) then return end
    local delay = math.max(INTERVAL, (state.backoff or 0) - GetTime())
    state.timer = C_Timer.NewTimer(delay, function() Tick(self) end)
end

ServeWindow = function(self, source, id, hash, first, count)
    local state = self.restedxpState
    local serving = state.performance.serving
    local request = { source = source, id = id, status = "received" }
    serving.last = request
    local function Send(pack, packLabel)
        serving.last = request
        local last = math.min(first + count - 1, math.ceil(#pack.data / CHUNK))
        if first > last then request.status = "invalid window"; return false end
        local queued = true
        if pack.revision and first == 1 then
            local label = PackLabel(packLabel or pack.label)
            queued = Queue(self, "1|O|" .. id .. "|" .. hash .. "|" .. #pack.data
                .. (label and ("|" .. label) or ""), "ready:" .. id .. ":" .. source)
            if not queued then
                serving.queueFull, request.status = serving.queueFull + 1, "send queue full"
                return false
            end
        end
        for sequence = first, last do
            if not Queue(self, "1|D|" .. hash:sub(1, 16) .. "|" .. sequence .. "|"
                .. pack.data:sub((sequence - 1) * CHUNK + 1, sequence * CHUNK), hash .. ":" .. sequence)
                then queued = false end
        end
        local counter = queued and "windows" or "queueFull"
        serving[counter] = serving[counter] + 1
        request.status = queued and "data queued" or "send queue full"
        return queued
    end
    local saved = SavedPack(self, id)
    local inventory = state.inventory[id]
    if saved and Revision(saved) == hash and (not saved.localInstalled or state.autoReady) then return Send(saved) end
    local served = state.servedPack
    if served and served.id == id and served.revision == hash and inventory and inventory.revision == hash then
        return Send(served.pack, inventory.label)
    end
    if not inventory or inventory.revision ~= hash or type(self.PrepareRestedXPInstalledPack) ~= "function" then
        serving.unavailable, request.status = serving.unavailable + 1, "requested guide version unavailable"
        return false
    end
    if state.job or state.installing then
        serving.busy, request.status = serving.busy + 1, "waiting for guide processing"
        return false
    end
    -- Receiving bytes does not change the native guide cache. Allow preparing
    -- a reply while downloading, so two peers cannot wait on each other.
    serving.preparing, request.status = serving.preparing + 1, "preparing cached guides"
    return StartJob(self, "Collecting cached guide data...", function()
        return self:PrepareRestedXPInstalledPack(id, hash)
    end, function(pack, problem)
        if not pack then
            request.status, request.problem = "preparation failed", problem
            state.inventory[id], state.sentOffers[id] = nil, nil
            state.sharingStatus = problem or "The requested guide source could not be prepared."
            Queue(self, "1|X|" .. id, "withdraw:" .. id)
            Changed(self, state.sharingStatus, true)
            return
        end
        local stored, failure = StorePack(self, id, pack, LocalIdentity(self),
            { label = inventory.label, localInstalled = true, revision = hash })
        if not stored then
            -- The native source is already retained by RestedXP. A full LIT
            -- cache must not prevent sending this prepared response directly.
            serving.cacheBypasses = serving.cacheBypasses + 1
            request.cacheProblem = failure
            -- Keep at most one transient pack (bounded by MAX_BYTES) so later
            -- windows do not rebuild an export that could not be persisted.
            state.servedPack = { id = id, revision = hash, pack = pack }
        else state.servedPack = nil
        end
        Send(stored and SavedPack(self, id) or pack, inventory.label)
        Changed(self, "Requested guide pack is ready to share.")
    end, "export")
end

Receive = function(self, sender, wire)
    if not Available(self) or Secret(sender) or type(sender) ~= "string" or #sender > 128
        or sender:find("[|%c]") or type(wire) ~= "string" or #wire > 246 then return false end
    local source, isSelf = self:GetDataSenderIdentity(sender)
    if not source or isSelf then return false end
    local body, signature = wire:match("^(.*)|([0-9a-f]+)$")
    if not body or not self:VerifyGroupMessage(AUTH, body, signature) then return false end
    local kind, rest = body:match("^1|([QOVWDX])|(.*)$")
    if not kind then return false end
    local state, group, now = self.restedxpState, CurrentGroup(self), GetTime()
    -- Count authenticated observed guide traffic, including frames for other
    -- group members; this measures payload use without sending diagnostics.
    RecordWire(state, "rx", body, #wire + 9)
    Prune(state)
    if kind == "Q" then
        if #rest > 32 or not rest:match("^[a-zA-Z0-9_-]+$") then return false end
        if state.replies[source] and now - state.replies[source] < 5 then return false end
        if not state.replies[source] and Count(state.replies) >= MAX_PEERS then return false end
        state.replies[source] = now
        if not state.replyTimer then
            local requestedSince = now
            state.replyTimer = C_Timer.NewTimer(0.3 + math.random() * 0.7, function()
                state.replyTimer = nil
                Announce(self, requestedSince)
            end)
        end
    elseif kind == "O" or kind == "V" then
        local id, hash, length = rest:match("^([^|]+)|([^|]+)|(%d+)$")
        local label
        if not id then id, hash, length, label = rest:match("^([^|]+)|([^|]+)|(%d+)|([^|]+)$") end
        local size = Integer(length, kind == "V" and 10000 or MAX_BYTES)
        if not PackID(id) or not Hash(hash) or not size or label and (#label > 48 or label:find("%c")) then return false end
        if not state.offers[id] and Count(state.offers) >= MAX_PACKS * MAX_PEERS then return false end
        state.offers[id] = state.offers[id] or {}
        if not state.offers[id][source] and Count(state.offers[id]) >= MAX_PEERS then return false end
        local previous = state.offers[id][source]
        local versioned = kind == "V" or previous and previous.versioned
        -- A readiness response for an older download must not replace a newer
        -- ID/version announcement received while its source was being prepared.
        if not (kind == "O" and previous and previous.versioned and previous.hash ~= hash) then
            state.offers[id][source] = { hash = hash, size = kind == "O" and size or nil,
                guideCount = kind == "V" and size or previous and previous.guideCount,
                seen = now, label = label, versioned = versioned }
        end
        local incoming = state.incoming
        if kind == "O" and incoming and incoming.id == id and incoming.source == source and incoming.hash == hash then
            if not incoming.size then
                incoming.size, incoming.count = size, math.ceil(size / CHUNK)
                incoming.windowLast = math.min(incoming.windowLast or WINDOW, incoming.count)
                incoming.progressAt, incoming.retries, incoming.nextRequest = now, 0, now + 4
            end
        end
        if state.peerTest and state.peerTest.report.phase == "discovery" then PeerTestSelect(self, true) end
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
            local test = state.incoming.test
            PeerTestIncoming(state, state.incoming)
            state.incoming = nil
            Changed(self, "The publisher no longer has this installed guide pack.", true)
            if test then PeerTestFinish(self, "failed", "The publisher withdrew the guide pack during the test.") end
            Reconcile(self)
        else Changed(self) end
    elseif kind == "W" then
        local target, id, hash, startText, countText = rest:match("^([^|]+)|([^|]+)|([^|]+)|(%d+)|(%d+)$")
        local first, count = Integer(startText, math.ceil(MAX_BYTES / CHUNK)), Integer(countText, WINDOW)
        if not PackID(id) or not Hash(hash) or not first or not count then return false end
        local serving = state.performance.serving
        if not IsLocalAddress(self, target) then serving.other = serving.other + 1; return false end
        serving.addressed = serving.addressed + 1
        if state.requests[source] and now - state.requests[source] < 0.5 then return false end
        if not state.requests[source] and Count(state.requests) >= MAX_PEERS then return false end
        state.requests[source] = now
        if not ServeWindow(self, source, id, hash, first, count) then return false end
    elseif kind == "D" then
        local hash, sequenceText, data = rest:match("^([0-9a-f]+)|(%d+)|(.*)$")
        local incoming = state.incoming
        local sequence = incoming and Integer(sequenceText, incoming.count)
        if not incoming or not incoming.size or source ~= incoming.source or hash ~= incoming.hash:sub(1, 16)
            or not sequence or #data ~= math.min(CHUNK, incoming.size - (sequence - 1) * CHUNK)
            or data:find("[^A-Za-z0-9+/=%%|:%d%-]") then return false end
        if incoming.chunks[sequence] then
            if incoming.chunks[sequence] ~= data then return false end
            state.performance.duplicateChunks = state.performance.duplicateChunks + 1
            return true
        end
        incoming.chunks[sequence], incoming.bytes = data, incoming.bytes + #data
        incoming.progressAt, incoming.retries = now, 0
        local percent = math.floor(100 * incoming.bytes / incoming.size)
        if percent ~= incoming.percent then
            incoming.percent = percent
            Changed(self, "Receiving " .. incoming.id .. " (" .. percent .. "%)...")
        end
        if incoming.bytes == incoming.size then FinishDownload(self)
        else
            local complete = true
            for index = incoming.windowFirst, incoming.windowLast do
                if not incoming.chunks[index] then complete = false; break end
            end
            if complete then RequestWindow(self) end
        end
    end
    return true
end

local function Reset(self, stopped)
    local state = self.restedxpState
    if state.peerTest then PeerTestFinish(self, "cancelled", "The two-player guide test stopped when the connection or group changed.") end
    if state.timer then state.timer:Cancel() end
    if state.replyTimer then state.replyTimer:Cancel() end
    if state.jobTimer then state.jobTimer:Cancel() end
    if self.CancelRestedXPInstallation then self:CancelRestedXPInstallation() end
    if self.StopWatchingRestedXPInstalledGuides then self:StopWatchingRestedXPInstalledGuides() end
    state.timer, state.replyTimer, state.incoming, state.installing = nil, nil, nil, nil
    state.job, state.jobTimer = nil, nil
    state.updateAt, state.installRetry, state.backoff, state.pruneAt = nil, nil, nil, nil
    state.refreshAt, state.refreshingInstalled, state.watching, state.autoReady = nil, false, false, false
    state.sentOffers, state.wantSentAt = {}, nil
    state.lastQuerySentAt = nil
    state.inventory, state.servedPack = {}, nil
    if state.benchmarkRunning then
        state.benchmarkRunning = nil
        state.performance.benchmarkCancelled = true
    end
    state.checkedInstalled, state.sharedInstalledGuides, state.unshareableGuides = {}, 0, 0
    state.sharingStatus = "Imported guides are shared automatically with your LIT group."
    state.queue, state.queued, state.offers, state.replies, state.requests, state.pending, state.failed = {}, {}, {}, {}, {}, {}, {}
    state.generation, state.stopped, state.attention = state.generation + 1, stopped, false
end

function addon:InitializeRestedXP()
    if self.restedxpState then return end
    if not self.savedDataReadOnly then
        if type(self.db.restedxp) ~= "table" then self.db.restedxp = {} end
        if type(self.db.restedxp.groups) ~= "table" then self.db.restedxp.groups = {} end
    end
    self.restedxpState = { generation = 0, fingerprint = self:GetGroupFingerprint(), decoded = {}, queue = {}, queued = {}, offers = {},
        replies = {}, requests = {}, pending = {}, failed = {}, checkedInstalled = {}, sentOffers = {},
        performance = NewPerformance(), inventory = {}, status = "Use Update guides to check your group." }
    self:RegisterDataFeature(FEATURE, function(sender, wire) return Receive(self, sender, wire) end, function(connected)
        Reset(self, false)
        if connected and Available(self) then
            local previousTest = self.restedxpState.performance.peerTest
            self.restedxpState.performance = NewPerformance()
            self.restedxpState.performance.peerTest = previousTest
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
    self.restedxpEvents = self:RegisterGameEvents({ "ADDON_LOADED", "PLAYER_REGEN_ENABLED", "PLAYER_LOGOUT" }, function(_, event, name)
        if event == "PLAYER_LOGOUT" then Reset(self, true)
        else
            if event == "ADDON_LOADED" and name == "RXPGuides" and Available(self) then
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
    if self.restedxpState.peerTest or self.restedxpState.incoming or self.restedxpState.installing or ForegroundJob(self.restedxpState) then return false, "A guide update is already in progress." end
    if type(id) == "string" and not Secret(id) then id = id:lower():gsub("%s+", "-") end
    if not PackID(id) then return false, "Use a pack ID of up to 40 letters, numbers, hyphens or underscores." end
    if type(raw) ~= "string" or #raw == 0 or #raw > MAX_BYTES then return false, "Paste an export no larger than 2 MiB." end
    local source = LocalIdentity(self)
    -- User imports take priority; restart a paused background scan afterwards.
    local state = self.restedxpState
    if BackgroundJob(state) then
        if state.jobTimer then state.jobTimer:Cancel() end
        state.job, state.jobTimer = nil, nil
        RequestInstalledRefresh(self)
    end
    -- An explicit import owns the status even if login discovery is still finishing.
    self.restedxpState.updateAt = nil
    -- The source BattleTag is transient conversion input, never saved or sent.
    -- Only the canonical pack is shared; recipients personalize it locally.
    return StartJob(self, "Validating " .. id .. "...", function()
        return self.RestedXPCodec.Decode(raw, sourceBattleTag)
    end, function(pack, problem)
    if not pack then Changed(self, problem or "The export could not be validated.", true); return end
    local stored
    stored, problem = StorePack(self, id, pack, source)
    if not stored then Changed(self, problem, true); return end
    Announce(self)
    Changed(self, "Shared " .. id .. " (" .. pack.guideCount .. " guides).")
    end)
end

function addon:SelectRestedXPPack(id, source)
    if not self.restedxpState or self.savedDataReadOnly then return false, "Saved preferences are read-only." end
    if self.restedxpState.peerTest or self.restedxpState.incoming or self.restedxpState.installing or ForegroundJob(self.restedxpState) then return false, "Wait for the current guide update before changing its publisher." end
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

function addon:SelectRestedXPPublisher(source)
    local state = self.restedxpState
    if not state or self.savedDataReadOnly then return false, "Saved preferences are read-only." end
    if state.peerTest or state.incoming or state.installing or ForegroundJob(state) then
        return false, "Wait for the current guide update before changing its publisher."
    end
    if not self:HasGroup() or self:IsGroupSwitching() or state.fingerprint ~= self:GetGroupFingerprint() then
        return false, "Join a LIT group before following a publisher."
    end
    if Secret(source) or type(source) ~= "string" or #source == 0 or #source > 128 or source:find("[|%c]") then
        return false, "Invalid guide source."
    end
    local normalized, isSelf = self:GetDataSenderIdentity(source)
    if not normalized or isSelf or normalized == LocalIdentity(self) then return false, "Choose another group member as your publisher." end
    local group, ids, additional = CurrentGroup(self), {}, 0
    if not group then return false, "Invalid guide source." end
    for id, sources in pairs(state.offers) do
        local offer = sources[normalized]
        if PackID(id) and offer and GetTime() - offer.seen <= OFFER_AGE then
            ids[#ids + 1] = id
            if not group.sources[id] then additional = additional + 1 end
        end
    end
    if #ids == 0 then return false, "Refresh guides to find this source again." end
    -- Following a player is a single choice over their current offers. Keep the
    -- existing per-pack subscriptions, and never save a partially accepted set.
    if Count(group.sources) + additional > MAX_PACKS then return false, "The guide subscription limit has been reached." end
    for _, id in ipairs(ids) do group.sources[id] = normalized end
    Changed(self, "Following current guides from " .. normalized .. ". Use Update guides to install them.")
    return true
end

function addon:UpdateRestedXPGuides()
    if not Available(self) then return false, "Connect to your LIT group to check for updates." end
    local state = self.restedxpState
    if state.peerTest or state.incoming or state.installing or ForegroundJob(state) then return false, "A guide update is already in progress." end
    state.updateAt = GetTime() + 2
    WatchInstalled(self)
    RequestInstalledRefresh(self, 0, true)
    Queue(self, "1|Q|" .. self.dataState.requestSession, "query")
    -- Locally published packs can also be installed without an online peer.
    local group, identity = CurrentGroup(self), LocalIdentity(self)
    -- A manual request retries failures once, including when source recovery
    -- completes before discovery does. Later completion must not clear a new failure.
    for id in pairs(group.sources) do state.failed[id] = nil end
    for id in pairs(group.packs) do
        local saved = SavedPack(self, id)
        if saved and saved.source == identity and not (saved.revision and state.inventory[id])
            and Installed(self)[id] ~= Revision(saved) then
            state.failed[id], state.pending[id] = nil, true
        end
    end
    Changed(self, "Checking guides from followed group sources...")
    Schedule(self)
    return true
end

local function PublisherIdentity(self, source)
    if Secret(source) or type(source) ~= "string" or source == "" then return nil end
    return self:GetDataSenderIdentity(source)
end

local function PublisherSummaries(self, result, group, installed)
    local state, identity, catalog = self.restedxpState, LocalIdentity(self), {}
    local function Get(source)
        source = PublisherIdentity(self, source)
        if not source then return nil end
        if not catalog[source] then
            catalog[source] = { row = { source = source, localPack = source == identity }, packs = {}, live = {}, followed = {} }
        end
        return catalog[source]
    end
    for _, pack in ipairs(result.packs) do
        local publisher = Get(pack.source)
        if publisher then
            publisher.packs[pack.id] = true
            if pack.canFollow and not publisher.row.localPack then publisher.live[pack.id] = pack end
        end
    end
    -- A followed publisher remains visible when their offer expires, even if
    -- none of their guide data has ever been downloaded on this character.
    for id, source in pairs(group.sources) do
        local publisher = PackID(id) and Get(source)
        if publisher then publisher.packs[id], publisher.followed[id] = true, true end
    end
    for source, publisher in pairs(catalog) do
        local row = publisher.row
        row.packCount, row.livePackCount, row.followedPackCount = Count(publisher.packs), Count(publisher.live), Count(publisher.followed)
        row.selectedPackCount, row.updateCount, row.failedCount, row.offlinePackCount = 0, 0, 0, 0
        for id in pairs(publisher.followed) do
            local pack, saved = publisher.live[id], SavedPack(self, id)
            if pack then
                row.selectedPackCount = row.selectedPackCount + 1
                if not pack.installed then
                    row.updateCount = row.updateCount + 1
                    if state.failed[id] == pack.hash then row.failedCount = row.failedCount + 1 end
                end
            else
                row.offlinePackCount = row.offlinePackCount + 1
                if state.failed[id] and installed[id] ~= state.failed[id]
                    and (not saved or PublisherIdentity(self, saved.source) == source and state.failed[id] == Revision(saved)) then
                    row.failedCount = row.failedCount + 1
                end
            end
        end
        local updating = state.incoming and PublisherIdentity(self, state.incoming.source) == source
        for id in pairs(publisher.packs) do
            local saved = SavedPack(self, id)
            if state.installing == id and saved and PublisherIdentity(self, saved.source) == source then updating = true end
            if row.localPack and saved and PublisherIdentity(self, saved.source) == source
                and installed[id] ~= Revision(saved) and state.failed[id] == Revision(saved) then
                row.failedCount = row.failedCount + 1
            end
        end
        row.selected = row.livePackCount > 0 and row.selectedPackCount == row.livePackCount
            or row.livePackCount == 0 and row.followedPackCount > 0
        row.canFollow = not row.localPack and row.livePackCount > 0
        row.status = updating and "Updating" or row.failedCount > 0 and "Update failed"
            or row.offlinePackCount > 0 and "Publisher offline" or row.updateCount > 0 and "Updates available"
            or row.followedPackCount > 0 and (row.selected and "Up to date" or "Partly followed")
            or row.localPack and "Shared" or row.livePackCount > 0 and "Available" or "Cached"
        result.publishers[#result.publishers + 1] = row
    end
    table.sort(result.publishers, function(a, b) return a.source < b.source end)
end

local function GuideStatus(self, result)
    if not result.installed then return "Not installed" end
    if not result.loaded then return "Not loaded" end
    if not result.compatible then return "Unavailable" end
    if result.readOnly then return "Read-only" end
    local state = self.restedxpState
    if not state then return "Loading" end
    if self:IsGroupSwitching() or state.fingerprint ~= self:GetGroupFingerprint() then return "Changing group" end
    if not Available(self) then return "Disconnected" end
    if state.incoming then
        if not state.incoming.size then return "Preparing update" end
        return "Updating (" .. math.floor(100 * state.incoming.bytes / state.incoming.size) .. "%)"
    end
    if state.installing then return "Installing" end
    if ForegroundJob(state) then return "Processing" end
    if state.peerTest then return "Testing" end
    if state.updateAt then return "Checking" end
    if next(state.pending) then
        return InCombatLockdown and InCombatLockdown() and "Waiting for combat" or "Ready to install"
    end
    local followed, failed, offline, updates, available = 0, 0, 0, 0, false
    for _, publisher in ipairs(result.publishers) do
        followed = followed + publisher.followedPackCount
        failed, offline, updates = failed + publisher.failedCount, offline + publisher.offlinePackCount, updates + publisher.updateCount
        available = available or publisher.canFollow
    end
    if failed > 0 then return "Update failed" end
    if state.attention then return "Needs attention" end
    if offline > 0 then return "Publisher offline" end
    if updates > 0 then return "Updates available" end
    if state.refreshingInstalled then return "Checking" end
    -- Local publications alone prove availability, not comparison with an
    -- online followed publisher. Reserve this result for verified revisions.
    if followed > 0 then return "Up to date" end
    if available then return "Choose a publisher" end
    if #(result.guides or {}) > 0 or #result.packs > 0 then return "Ready" end
    return "No guides"
end

function addon:GetRestedXPState()
    local result = self:GetRestedXPInstallation()
    local state = self.restedxpState
    result.installationProblem = result.problem
    result.packs, result.publishers, result.readOnly = {}, {}, self.savedDataReadOnly == true
    result.status = state and state.status or "Guides are loading."
    result.sharingStatus = state and state.sharingStatus
    result.sharedInstalledGuides = state and state.sharedInstalledGuides or 0
    result.unshareableGuides = state and state.unshareableGuides or 0
    result.refreshingInstalled = state and state.refreshingInstalled or false
    result.busy = state and (state.peerTest ~= nil or state.incoming ~= nil or state.installing ~= nil or ForegroundJob(state) ~= nil
        or state.updateAt ~= nil) or false
    result.canUpdate = Available(self) and not result.busy or false
    result.guideStatus = GuideStatus(self, result)
    if not state then return result end
    if state.fingerprint ~= self:GetGroupFingerprint() then
        result.busy, result.canUpdate, result.status = false, false, "Guide sources are changing with your group."
        return result
    end
    local group, added = CurrentGroup(self), {}
    if not group then return result end
    local installed = Installed(self)
    local identity = LocalIdentity(self)
    for id, item in pairs(state.inventory) do
        result.packs[#result.packs + 1] = { id = id, label = item.label, hash = item.revision, source = identity,
            localPack = true, canFollow = false, installed = true, updateAvailable = false, versioned = true,
            status = "Installed; shared by ID/version" }
        added[id .. "|" .. tostring(identity)] = true
    end
    for id, sources in pairs(state.offers) do
        for source, offer in pairs(sources) do
            if GetTime() - offer.seen <= OFFER_AGE then
                local saved = SavedPack(self, id)
                result.packs[#result.packs + 1] = { id = id, label = offer.label or saved and saved.label or id, hash = offer.hash, source = source,
                    selected = group.sources[id] == source, canFollow = true, installed = installed[id] == offer.hash,
                    updateAvailable = installed[id] ~= offer.hash, status = installed[id] == offer.hash and "Last installed"
                        or saved and Revision(saved) == offer.hash and "Downloaded" or "Available", versioned = offer.versioned }
                added[id .. "|" .. source] = true
            end
        end
    end
    for id in pairs(group.packs) do
        local saved = SavedPack(self, id)
        if saved and not added[id .. "|" .. tostring(saved.source)] then
            result.packs[#result.packs + 1] = { id = id, label = saved.label or id, hash = Revision(saved),
                source = saved.source, selected = group.sources[id] == saved.source, canFollow = false,
                localPack = saved.source == LocalIdentity(self),
                installed = installed[id] == Revision(saved), updateAvailable = installed[id] ~= Revision(saved),
                versioned = saved.revision ~= nil,
                status = installed[id] == Revision(saved) and "Last installed" or "Cached locally" }
        end
    end
    table.sort(result.packs, function(a, b) return a.id == b.id and (a.source or "") < (b.source or "") or a.id < b.id end)
    PublisherSummaries(self, result, group, installed)
    result.guideStatus = GuideStatus(self, result)
    return result
end

local function CopyPerformance(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = CopyPerformance(item) end
    return result
end

function addon:GetRestedXPPerformance()
    local state = self.restedxpState
    if not state then return nil end
    local result = CopyPerformance(state.performance)
    result.elapsed = math.max(0, WallTime() - result.startedAt)
    if state.peerTest then
        local report = result.peerTest
        report.wall = math.max(0, WallTime() - report.startedAt)
        local phase = report.phases[report.phase]
        if phase.startedAt then phase.wall = math.max(0, WallTime() - phase.startedAt) end
        if state.incoming and state.incoming.test then
            report.bytes, report.expectedBytes, report.retries = state.incoming.bytes, state.incoming.size, state.incoming.retryCount
        end
    end
    result.queue = #state.queue
    result.publisherIdentities = {}
    local identities = type(self.GetDataSelfIdentities) == "function" and self:GetDataSelfIdentities()
        or { [LocalIdentity(self) or "unavailable"] = true }
    for identity in pairs(identities) do result.publisherIdentities[#result.publisherIdentities + 1] = identity end
    table.sort(result.publisherIdentities)
    if state.job then
        result.activeJob = CopyPerformance(state.job.metrics)
        result.activeJob.kind = state.job.kind or "processing"
        result.activeJob.wall = math.max(0, WallTime() - result.activeJob.startedAt)
    end
    if state.incoming then
        result.receiving = { bytes = state.incoming.bytes, total = state.incoming.size,
            wall = math.max(0, WallTime() - state.incoming.startedAt) }
    end
    return result
end

local function TimingText(run)
    return string.format("%.2fs elapsed, %s work, %s longest slice", run.wall,
        run.cpu and string.format("%.1fms", run.cpu * 1000) or "unmeasured",
        run.maxSlice and string.format("%.1fms", run.maxSlice * 1000) or "unmeasured")
end

local function PrintBenchmark(self, benchmark)
    local cold, warm = benchmark.cold, benchmark.warm
    if not cold or not warm then return end
    if benchmark.metadataOnly then
        self:Print(string.format("RestedXP local test: %d guides, %d packs; guide IDs and versions only. No guide content processed or test messages sent.",
            cold.guides, cold.packs))
    else
        self:Print(string.format("RestedXP local test: %d guides, %d packs, %.1f KiB prepared. No test messages sent.",
            cold.guides, cold.packs, cold.bytes / 1024))
    end
    self:Print("Cold: " .. TimingText(cold) .. "; warm: " .. TimingText(warm) .. ".")
    if benchmark.metadataOnly then return end
    local first, second = cold.metrics or {}, warm.metrics or {}
    self:Print(string.format("Cold decoded %d sources / built %d groups; warm reused %d sources / %d groups.",
        first.decodedSources or 0, first.groupsBuilt or 0, second.cacheHits or 0, second.groupsReused or 0))
end

function addon:StartRestedXPBenchmark()
    local state = self.restedxpState
    if not self.ready or not state then return false, "RestedXP is still loading." end
    if state.peerTest or state.job or state.incoming or state.installing or state.updateAt or state.refreshAt
        or state.refreshingInstalled or state.benchmarkRunning or next(state.pending) then
        return false, "Wait for the current guide preparation or update to finish, then run /lit rxp test local."
    end
    local metadataOnly = type(self.CollectRestedXPInstalledInventory) == "function"
    if metadataOnly and type(self.ResetRestedXPInventoryMemo) ~= "function"
        or not metadataOnly and (type(self.CollectRestedXPInstalledPacks) ~= "function"
            or type(self.ResetRestedXPSourceMemo) ~= "function") then
        return false, "Installed-guide timing is unavailable. Reload LockInTools and try again."
    end
    local installation = self:GetRestedXPInstallation()
    if not installation.compatible then return false, installation.problem or "Enable a supported RestedXP version first." end
    if metadataOnly then self:ResetRestedXPInventoryMemo() else self:ResetRestedXPSourceMemo() end
    local benchmark = { metadataOnly = metadataOnly }
    state.performance.benchmark, state.performance.benchmarkError = nil, nil
    state.performance.benchmarkCancelled = nil
    state.benchmarkRunning = benchmark
    self:Print(metadataOnly and "RestedXP local test: measuring guide ID/version scans, fresh and repeated. No discovery or guide traffic is requested."
        or "RestedXP local test: measuring full preparation and unchanged-cache reuse. No discovery or guide traffic is requested.")
    local function Run(phase)
        StartJob(self, "Measuring local RestedXP guides...", function()
            if metadataOnly then
                local items, info = self:CollectRestedXPInstalledInventory()
                info = type(info) == "table" and info or { problem = info }
                info.metadataOnly = true
                return items, info
            end
            return self:CollectRestedXPInstalledPacks()
        end, function(packs, info, timing)
            if state.benchmarkRunning ~= benchmark then return end
            if type(packs) ~= "table" then
                local problem = type(info) == "table" and info.problem or type(info) == "string" and info
                    or "RestedXP changed or is importing guides. Try again when it is idle."
                state.performance.benchmarkError, state.benchmarkRunning = problem, nil
                self:Print("RestedXP local test stopped: " .. problem)
                Changed(self, problem)
                if Available(self) then Reconcile(self) end
                return
            end
            timing.guides, timing.packs, timing.bytes = 0, #packs, 0
            for _, item in ipairs(packs) do
                timing.guides = timing.guides + (metadataOnly and item.guideCount or item.pack.guideCount)
                if not metadataOnly then timing.bytes = timing.bytes + #item.pack.data end
            end
            timing.metrics = type(info) == "table" and info.metrics or {}
            benchmark[phase] = timing
            if phase == "cold" then Run("warm")
            else
                state.performance.benchmark, state.benchmarkRunning = benchmark, nil
                PrintBenchmark(self, benchmark)
                Changed(self, "Local timing test complete. No guide traffic was requested.")
                if Available(self) then Reconcile(self) end
            end
        end, "benchmark" .. phase)
    end
    Run("cold")
    return true
end

function addon:StartRestedXPPeerTest(source, id, options)
    local state = self.restedxpState
    if not self.ready or not state then return false, "RestedXP is still loading." end
    if not Available(self) then return false, "Connect to your LIT group before running a two-player guide test." end
    if state.peerTest or state.job or state.incoming or state.installing or state.updateAt or state.refreshAt
        or state.refreshingInstalled or state.benchmarkRunning or next(state.pending) then
        return false, "Wait for the current guide work to finish before running the two-player test."
    end
    local installation = self:GetRestedXPInstallation()
    if not installation.compatible then return false, installation.problem or "Enable a supported RestedXP version first." end
    local random = type(options) == "table" and options.random == true
    if random and (source ~= nil or id ~= nil) then return false, "A random test chooses both the player and guide pack." end
    if source ~= nil then
        if Secret(source) or type(source) ~= "string" or #source == 0 or #source > 128 or source:find("[|%c]") then
            return false, "Use an online player's character name, optionally followed by its realm."
        end
        local identity, isSelf = self:GetDataSenderIdentity(source)
        if not identity or isSelf then return false, "Choose another LIT player as the test publisher." end
        source = identity
    end
    if id ~= nil and not PackID(id) then return false, "Choose a valid shared guide pack ID." end
    local report = { status = "running", phase = "discovery", startedAt = WallTime(), wall = 0,
        source = source, id = id, random = random, phases = {}, tx = NewTraffic(), rx = NewTraffic(), retries = 0 }
    for _, name in ipairs({ "discovery", "transfer", "import" }) do
        report.phases[name] = { wall = 0, tx = NewTraffic(), rx = NewTraffic() }
    end
    report.phases.discovery.startedAt = report.startedAt
    local run = { report = report, requestedSource = source, requestedID = id, random = random }
    state.peerTest, state.performance.peerTest = run, report
    -- Reuse the regular discovery request. Waiting out its existing cooldown
    -- avoids extra probes or a special handshake, even just after login.
    local queryAt = math.max(GetTime(), (state.lastQuerySentAt or -6) + 5.1)
    state.updateAt = queryAt + 12
    if not Queue(self, "1|Q|" .. self.dataState.requestSession, "query", queryAt) then
        state.peerTest, state.updateAt, state.performance.peerTest = nil, nil, nil
        return false, "The guide data queue is full. Try the test again after current traffic finishes."
    end
    state.queued.query.test = run
    run.discoveryTimeout = function()
        if state.peerTest ~= run or report.phase ~= "discovery" then return end
        state.updateAt = nil
        Reconcile(self)
        if state.peerTest == run and report.phase == "discovery" then
            PeerTestFinish(self, "failed", run.querySentAt and "Guide discovery timed out during the test."
                or "The guide discovery request could not be sent.")
        end
    end
    run.timer = C_Timer.NewTimer(math.max(0, queryAt - GetTime()) + 12, run.discoveryTimeout)
    RequestInstalledRefresh(self, 0, true)
    self:Print(random and "RestedXP random test: collecting discovery replies, then choosing a random player and one of their packs to download and re-import. No diagnostic messages are sent."
        or "RestedXP two-player test: discovering one guide pack, then downloading and re-importing it even if versions match. No diagnostic messages are sent.")
    Changed(self, random and "Discovering online publishers for a random guide test..." or "Discovering an online guide publisher for the test...")
    Schedule(self)
    return true
end

function addon:CancelRestedXPPeerTest()
    if not self.restedxpState or not self.restedxpState.peerTest then return false, "No two-player guide test is running." end
    PeerTestFinish(self, "cancelled", "Two-player guide test cancelled.")
    return true
end

function addon:PrintRestedXPPeerTest(report)
    if type(report) ~= "table" then return end
    local function Text(value) return tostring(value):gsub("|", "||") end
    local function Seconds(value) return math.max(0, tonumber(value) or 0) end
    local function Traffic(traffic)
        traffic = traffic or {}
        return string.format("%d messages / %.1f KiB", traffic.messages or 0, (traffic.bytes or 0) / 1024)
    end
    local target = report.source and Text(report.source) or "publisher pending"
    if report.id then target = target .. " / " .. Text(report.id) end
    local status = Text(report.status or "running")
    if report.status == "running" and report.phase then status = status .. " (" .. Text(report.phase) .. ")" end
    self:Print(string.format("RestedXP peer test: %s; %s; %.2fs total.", status, target, Seconds(report.wall)))
    if report.queryWaitWall and report.queryWaitWall > 0.5 then
        self:Print(string.format("Discovery includes %.2fs waiting for the normal request cooldown or send queue; no extra probes were sent.",
            Seconds(report.queryWaitWall)))
    end
    local phases = report.phases or {}
    for _, entry in ipairs({ { "discovery", "Discovery" }, { "transfer", "Transfer" }, { "import", "Native import" } }) do
        local phase = phases[entry[1]]
        if phase and phase.startedAt ~= nil then
            local elapsed = phase.wall or phase.startedAt and WallTime() - phase.startedAt or 0
            self:Print(string.format("%s: %.2fs; sent %s; observed %s.", entry[2], Seconds(elapsed), Traffic(phase.tx), Traffic(phase.rx)))
        end
    end
    self:Print("Total: sent " .. Traffic(report.tx) .. "; observed " .. Traffic(report.rx) .. ".")
    if report.bytes and report.bytes > 0 then
        local elapsed = phases.transfer and Seconds(phases.transfer.wall) or 0
        local rate = elapsed > 0 and string.format("; %.2f KiB/s", report.bytes / 1024 / elapsed) or ""
        self:Print(string.format("Payload: %.1f KiB%s; %d retry windows.", report.bytes / 1024, rate, report.retries or 0))
    end
    local timing = {}
    if report.conversionWall then timing[#timing + 1] = string.format("Recipient conversion %.2fs", Seconds(report.conversionWall)) end
    if report.nativeWall then timing[#timing + 1] = string.format("native confirmation %.2fs", Seconds(report.nativeWall)) end
    if #timing > 0 then self:Print(table.concat(timing, "; ") .. ".") end
    if report.importUnchanged then self:Print("RestedXP processed the import and retained the matching installed guides.") end
    if report.message then self:Print("Result: " .. Text(report.message)) end
    self:Print("Counts cover local sends and observed group guide payload, including framing; other features and server overhead are excluded.")
end

function addon:ShowRestedXPPerformance()
    local report = self:GetRestedXPPerformance()
    if not report then return false, "RestedXP is still loading." end
    if report.peerTest then self:PrintRestedXPPeerTest(report.peerTest) end
    if report.benchmark then PrintBenchmark(self, report.benchmark) end
    local function Since(value)
        return value and string.format("%.2fs", math.max(0, value - report.startedAt)) or "pending"
    end
    self:Print("RestedXP since connection: first publisher " .. Since(report.firstOfferAt)
        .. ", first announcement " .. Since(report.firstPublishedAt) .. ", Update available " .. Since(report.firstReadyAt) .. ".")
    local work = report.activeJob or report.jobs.installed
    if work then
        local label = work.metadataOnly and "Guide ID/version scan: " or report.activeJob and "Active preparation: " or "Last preparation: "
        self:Print(label .. TimingText(work) .. ".")
    end
    if report.jobs.export then self:Print("Last requested pack preparation: " .. TimingText(report.jobs.export) .. ".") end
    local tx, rx = report.tx, report.rx
    self:Print(string.format("Guide traffic: sent %d messages / %.1f KiB (Q%d V%d O%d W%d D%d X%d); observed %d / %.1f KiB (Q%d V%d O%d W%d D%d X%d).",
        tx.messages, tx.bytes / 1024, tx.Q, tx.V, tx.O, tx.W, tx.D, tx.X,
        rx.messages, rx.bytes / 1024, rx.Q, rx.V, rx.O, rx.W, rx.D, rx.X))
    self:Print(string.format("Queue %d; rejected sends %d; retry windows %d; duplicate chunks %d. Counts include addon payload framing; other features and WoW overhead are excluded.",
        report.queue, report.rejectedSends, report.retryWindows, report.duplicateChunks))
    local serving = report.serving
    if serving then
        self:Print(string.format("Publisher requests: %d addressed here, %d for other addresses; %d windows queued, %d preparations, %d busy, %d unavailable, %d full queue, %d cache bypasses.",
            serving.addressed, serving.other, serving.windows, serving.preparing, serving.busy,
            serving.unavailable, serving.queueFull, serving.cacheBypasses))
        local function Display(value) return tostring(value):gsub("|", "||") end
        self:Print("Local guide identities: " .. Display(table.concat(report.publisherIdentities, ", ")) .. ".")
        if serving.last then
            local last = serving.last
            self:Print("Last publisher request: " .. Display(last.source) .. " / " .. Display(last.id)
                .. "; " .. Display(last.status) .. ".")
            if last.problem or last.cacheProblem then self:Print(Display(last.problem or last.cacheProblem)) end
        end
    end
    local transfer = report.receiving or report.lastTransfer
    if transfer then
        self:Print(string.format("%s %.1f KiB in %.2fs (%.2f KiB/s)%s.", report.receiving and "Receiving" or "Last download:",
            transfer.bytes / 1024, transfer.wall, transfer.bytes / 1024 / math.max(0.001, transfer.wall),
            transfer.verified and string.format("; transfer checks %.2fs", transfer.verified) or ""))
    end
    if report.lastInstall then self:Print(string.format("Last native import: %.2fs, %s.",
        report.lastInstall.wall, report.lastInstall.success and "confirmed" or "failed")) end
    if report.benchmarkError then self:Print("Last local test stopped: " .. report.benchmarkError) end
    if report.benchmarkCancelled then self:Print("The local test was cancelled when the connection or group changed.") end
    return true
end
