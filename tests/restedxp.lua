-- Exercise the real codec and guide protocol between independent clients.
local function loadModule(file, addon, env)
    local chunk = assert(loadfile(file))
    setfenv(chunk, env)
    chunk("LockInTools", addon)
end

local function client(name, saved, readOnly, automatic, metadata)
    local world = { now = 0, timers = {}, sent = {}, observed = {}, output = {}, listeners = {}, events = {}, installs = {}, installPayloads = {}, installOptions = {}, notifications = 0 }
    local addon = { db = saved or {}, savedDataReadOnly = readOnly, ready = true, initialized = true,
        connected = false, fingerprint = "test-group", dataState = { requestSession = name .. "-session" } }
    local env = setmetatable({ bit = false, bit32 = false, GetTime = function() return world.now end,
        UnitFullName = function() return name, "TestRealm" end,
        InCombatLockdown = function() return world.combat == true end,
        C_Timer = { NewTimer = function(delay, callback)
            local timer = { at = world.now + delay, callback = callback }
            function timer:Cancel() self.cancelled = true end
            world.timers[#world.timers + 1] = timer
            return timer
        end },
    }, { __index = _G })
    env._G = env
    loadModule("Libs/LibStub/LibStub.lua", addon, env)
    loadModule("Libs/LibDeflate/LibDeflate.lua", addon, env)
    loadModule("Crypto.lua", addon, env)
    loadModule("RestedXPCodec.lua", addon, env)
    function addon:HasGroup() return self.fingerprint ~= nil end
    function addon:IsGroupSwitching() return self.switching == true end
    function addon:GetGroupFingerprint() return self.fingerprint end
    function addon:IsDataConnected() return self.connected end
    function addon:GetDataSenderIdentity(sender)
        local identity = sender:find("-", 1, true) and sender:lower() or sender:lower() .. "-testrealm"
        return identity, identity == name:lower() .. "-testrealm"
    end
    function addon:SignGroupMessage(feature, body)
        return self.Crypto.Hex(self.Crypto.HMACSHA256(self.fingerprint .. feature, body))
    end
    function addon:VerifyGroupMessage(feature, body, signature)
        return type(signature) == "string" and self.Crypto.Equal(self:SignGroupMessage(feature, body), signature)
    end
    function addon:Print(message) world.output[#world.output + 1] = message end
    function addon:Notify(event)
        world.notifications = world.notifications + 1
        for _, callback in ipairs(world.listeners[event] or {}) do callback() end
    end
    function addon:RegisterNotification(event, callback)
        world.listeners[event] = world.listeners[event] or {}
        table.insert(world.listeners[event], callback)
    end
    function addon:RegisterGameEvents(events, callback)
        for _, event in ipairs(events) do world.events[event] = callback end
    end
    function addon:RegisterDataFeature(feature, receive, connected)
        assert(feature == "guides")
        world.receive, world.connection = receive, connected
        connected(self.connected)
    end
    function addon:SendData(feature, wire)
        assert(feature == "guides" and #("1|guides|" .. wire) <= 255 and not wire:find("\0", 1, true))
        if world.rejectSends then return false end
        world.sent[#world.sent + 1] = wire
        return true
    end
    function addon:GetRestedXPInstallation()
        return { installed = not world.missing, loaded = not world.missing, compatible = not world.missing,
            version = "test", guides = {}, problem = world.missing and "RestedXP is not installed." or nil }
    end
    function addon:InstallRestedXPPack(pack, callback, options)
        if world.busy then return false, "Native import running", "busy" end
        world.installs[#world.installs + 1] = pack.hash
        world.installPayloads[#world.installPayloads + 1] = pack
        world.installOptions[#world.installs] = options or false
        world.installTimer = env.C_Timer.NewTimer(0.5, function()
            if not world.failInstall and world.afterInstall then world.afterInstall(pack) end
            callback(not world.failInstall, world.failInstall and "Synthetic import failure" or nil)
        end)
        return true
    end
    function addon:CancelRestedXPInstallation()
        if world.installTimer then world.installTimer:Cancel() end
    end
    if automatic or metadata then
        world.installedPacks = {}
        function addon:CollectRestedXPInstalledPacks()
            world.scans = (world.scans or 0) + 1
            for _ = 1, world.scanYields or 0 do coroutine.yield() end
            if world.scanBusy then return nil, { busy = true, complete = false } end
            if world.scanProblem then return nil, { complete = false, problem = world.scanProblem } end
            local metrics = world.memoWarm and { cacheHits = #world.installedPacks, decodedSources = 0,
                groupsBuilt = 0, groupsReused = #world.installedPacks }
                or { cacheHits = 0, decodedSources = #world.installedPacks, groupsBuilt = #world.installedPacks, groupsReused = 0 }
            world.memoWarm = true
            return world.installedPacks, { complete = world.scanComplete ~= false, skipped = world.skipped or 0, metrics = metrics }
        end
        function addon:ResetRestedXPSourceMemo()
            world.memoResets, world.memoWarm = (world.memoResets or 0) + 1, false
        end
        function addon:WatchRestedXPInstalledGuides(callback)
            world.watchStarts = (world.watchStarts or 0) + 1
            world.installedChanged = callback
            return true
        end
        function addon:StopWatchingRestedXPInstalledGuides()
            world.watchStops = (world.watchStops or 0) + 1
            world.installedChanged = nil
        end
        function addon:MatchesRestedXPInstalledPack(pack)
            return world.matches and world.matches[pack.hash] == true
        end
    end
    if metadata then
        world.inventory, world.preparedPacks, world.prepares = {}, {}, {}
        function addon:CollectRestedXPInstalledInventory()
            world.inventoryScans = (world.inventoryScans or 0) + 1
            for _ = 1, world.inventoryYields or 0 do coroutine.yield() end
            return world.inventory, { complete = true, skipped = 0 }
        end
        function addon:ResetRestedXPInventoryMemo()
            world.inventoryResets = (world.inventoryResets or 0) + 1
        end
        function addon:PrepareRestedXPInstalledPack(id, revision)
            world.prepares[#world.prepares + 1] = { id = id, revision = revision }
            for _ = 1, world.prepareYields or 0 do coroutine.yield() end
            local entry = world.preparedPacks[id]
            if not entry or entry.revision ~= revision then return nil, "The requested installed guide version is no longer available." end
            return entry.pack
        end
        function world:enableCachedMatching()
            self.cachedMatches = {}
            function addon:MatchesRestedXPCachedPack(pack)
                if not world.cachedMatches[pack.revision] then return false end
                world.cachedMatchCalls = (world.cachedMatchCalls or 0) + 1
                if not pack.cachedSources then world.persistedCachedMatchCalls = (world.persistedCachedMatchCalls or 0) + 1 end
                if world.validateCachedMatch then world.validateCachedMatch(pack) end
                return true
            end
        end
    end
    loadModule("RestedXP.lua", addon, env)
    addon:InitializeRestedXP()
    addon.testWorld = world
    function world:connect(value)
        addon.connected = value
        self.connection(value)
    end
    function world:advance(seconds)
        local target, iterations = self.now + seconds, 0
        while true do
            local first, index
            for i, timer in ipairs(self.timers) do
                if not timer.cancelled and timer.at <= target and (not first or timer.at < first.at) then first, index = timer, i end
            end
            if not first then break end
            table.remove(self.timers, index)
            self.now = first.at
            iterations = iterations + 1
            assert(iterations < 10000, "bounded guide timers")
            first.callback()
        end
        self.now = target
    end
    function world:deliver(other, filter)
        self.delivered = self.delivered or 0
        while self.delivered < #self.sent do
            self.delivered = self.delivered + 1
            local wire = self.sent[self.delivered]
            if not filter or filter(wire) then
                other.observed[#other.observed + 1] = wire
                other.receive(name .. "-TestRealm", wire)
            end
        end
    end
    return addon, world, env
end

local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64(raw)
    local result = {}
    for i = 1, #raw, 3 do
        local a, b, c = raw:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local function char(shift) local p = math.floor(n / 2 ^ shift) % 64; return alphabet:sub(p + 1, p + 1) end
        result[#result + 1] = char(18) .. char(12) .. (b and char(6) or "=") .. (c and char(0) or "=")
    end
    return table.concat(result)
end
local function packFor(addon, env, version, seed)
    local text = "#forever\n#group Synthetic Pack\n#name Test Route\n#version " .. version .. "\nstep\n"
    local lines = {}
    for i = 1, 400 do lines[i] = ".note " .. (i * (seed or 3)) .. " " .. (i * i) .. " " .. (i * i * 7 % 997) end
    text = text .. table.concat(lines, "\n")
    local deflate = env.LibStub("LITLibDeflate")
    local compressed = deflate:CompressZlib(text)
    local canonical = "1|" .. string.format("%.0f", deflate:Adler32(text)) .. ":" .. base64(compressed) .. "%|40000"
    return assert(addon.RestedXPCodec.DecodeCanonical(canonical))
end
local function publish(addon, pack, id)
    local export = assert(addon.RestedXPCodec.Encode(pack, "Source#1234"))
    assert(addon:ImportRestedXPPack(id or "leveling", export, "Source#1234"))
    for _ = 1, 10000 do
        if not addon.restedxpState.job then break end
        addon.testWorld:advance(0.02)
    end
    assert(not addon.restedxpState.job and addon.db.restedxp.groups[addon.fingerprint].packs[id or "leveling"],
        "asynchronous publishing completes with a verified pack")
end
local function exchange(a, b, seconds, filter)
    for _ = 1, math.ceil(seconds / 0.15) do
        a:advance(0.15); b:advance(0.15)
        a:deliver(b, filter); b:deliver(a)
    end
end
local function transferMessages(world)
    local count = 0
    for _, wire in ipairs(world.sent) do
        if wire:match("^1|[WD]|") then count = count + 1 end
    end
    return count
end
local function Traffic(wires)
    local result = { Q = 0, O = 0, V = 0, W = 0, D = 0, X = 0, messages = 0, bytes = 0 }
    for _, wire in ipairs(wires) do
        local kind = wire:match("^1|([QOVWDX])|")
        assert(kind, "recorded guide frames have a known type")
        result[kind], result.messages, result.bytes = result[kind] + 1, result.messages + 1, result.bytes + #wire + 9
    end
    return result
end
local function SameTraffic(actual, expected, description)
    for _, field in ipairs({ "Q", "O", "V", "W", "D", "X", "messages", "bytes" }) do
        assert(actual[field] == expected[field], description .. " (" .. field .. ")")
    end
end
local function Copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = Copy(item) end
    return result
end

-- A late joiner discovers an earlier publication, follows it explicitly, and
-- recovers a dropped data packet before reporting confirmed installation.
do
    local publisher, a, api = client("Alpha")
    local recipient, b = client("Beta")
    local pack = packFor(publisher, api, 1)
    assert(#pack.data > 1024, "the fixture exercises multiple transfer windows")
    a:connect(true)
    publish(publisher, pack)
    a:advance(3)
    a.delivered = #a.sent -- these announcements preceded the recipient
    b:connect(true)
    exchange(a, b, 4)
    local state = recipient:GetRestedXPState()
    assert(#state.packs == 1 and state.packs[1].hash == pack.hash and not state.packs[1].selected)
    assert(#b.installs == 0, "unsolicited announcements never install guides")
    assert(recipient:SelectRestedXPPack("leveling", "Alpha-TestRealm"))
    assert(recipient:UpdateRestedXPGuides())
    local dropped = false
    exchange(a, b, 70, function(wire)
        if not dropped and wire:match("^1|D|[^|]+|3|") then dropped = true; return false end
        return true
    end)
    assert(dropped and #b.installs == 1, "missing chunks are requested again without duplicate installation")
    local chunks = {}
    for _, wire in ipairs(a.sent) do
        local sequence = wire:match("^1|D|" .. pack.hash:sub(1, 16) .. "|(%d+)|")
        if sequence then sequence = tonumber(sequence); chunks[sequence] = (chunks[sequence] or 0) + 1 end
    end
    for sequence = 1, math.ceil(#pack.data / 128) do
        assert(chunks[sequence] == (sequence == 3 and 2 or 1),
            "loss recovery retransmits only the missing chunk, preserving already received data")
    end
    local measured = recipient:GetRestedXPPerformance()
    SameTraffic(measured.tx, Traffic(b.sent), "passive transmit counts match successful native guide frames")
    SameTraffic(measured.rx, Traffic(b.observed), "passive receive counts match authenticated guide frames observed on the channel")
    assert(measured.duplicateChunks == 0 and measured.retryWindows >= 1,
        "loss recovery records retries without delivering duplicate guide chunks")
    local installed = recipient:GetRestedXPState()
    assert(installed.packs[1].installed and installed.packs[1].hash == pack.hash)

    local sent, requested = transferMessages(a), transferMessages(b)
    assert(recipient:UpdateRestedXPGuides())
    exchange(a, b, 5)
    assert(#b.installs == 1 and transferMessages(a) == sent and transferMessages(b) == requested,
        "rechecking an identical followed pack neither transfers nor reinstalls it")
    assert(not recipient:GetRestedXPState().busy
        and recipient:GetRestedXPState().status:find("up to date", 1, true),
        "an unchanged online followed pack finishes with an explicit up-to-date result")

    -- Content changes with the same guide #version still propagate automatically.
    local updated = packFor(publisher, api, 1, 5)
    assert(updated.hash ~= pack.hash)
    publish(publisher, updated)
    exchange(a, b, 70)
    assert(#b.installs == 2 and b.installs[2] == updated.hash)
    local group = recipient.db.restedxp.groups[recipient.fingerprint]
    assert(group.packs.leveling.previous.hash == pack.hash, "keep previous verified package for recovery")
    assert(not recipient.restedxpState.incoming)
end

-- A failed install is not marked successful or retried forever. A manual
-- update can retry it; busy native imports are deferred without discarding it.
do
    local publisher, a, api = client("Alpha")
    local recipient, b = client("Beta")
    local pack = packFor(publisher, api, 2)
    a:connect(true); b:connect(true); publish(publisher, pack)
    exchange(a, b, 4)
    assert(recipient:SelectRestedXPPack("leveling", "alpha-testrealm"))
    b.failInstall = true
    assert(recipient:UpdateRestedXPGuides())
    exchange(a, b, 70)
    assert(#b.installs == 1 and not recipient:GetRestedXPState().packs[1].installed)
    b.failInstall, b.busy = false, true
    assert(recipient:UpdateRestedXPGuides())
    exchange(a, b, 5)
    assert(#b.installs == 1 and recipient.restedxpState.pending.leveling)
    b.busy = false
    exchange(a, b, 5)
    assert(#b.installs == 2 and recipient:GetRestedXPState().packs[1].installed)
end

-- Updates span all followed packs, not only the first one in the catalog.
do
    local publisher, a, api = client("Alpha")
    local recipient, b = client("Beta")
    a:connect(true); b:connect(true)
    publish(publisher, packFor(publisher, api, 1), "first")
    publish(publisher, packFor(publisher, api, 2, 4), "second")
    exchange(a, b, 5)
    local state = recipient:GetRestedXPState()
    assert(#state.packs == 2 and #state.publishers == 1 and state.publishers[1].packCount == 2
        and state.publishers[1].canFollow and not state.publishers[1].selected,
        "several guide packs from one player produce one available publisher")
    assert(recipient:SelectRestedXPPublisher("Alpha-TestRealm"))
    assert(recipient:GetRestedXPState().publishers[1].selected,
        "following a publisher selects all of their currently advertised guide packs")
    assert(recipient:UpdateRestedXPGuides())
    exchange(a, b, 100)
    state = recipient:GetRestedXPState()
    assert(#b.installs == 2 and state.guideStatus == "Up to date" and state.publishers[1].status == "Up to date",
        "one publisher choice installs both packs and reports their confirmed current revisions")
end

-- A player remains one publisher across local inventory, cached content and
-- live offers. Following a player applies only to the offers visible now.
do
    local addon, world = client("Viewer", nil, nil, nil, true)
    local first, second, third = string.rep("a", 64), string.rep("b", 64), string.rep("c", 64)
    world.inventory = {
        { id = "own-one", label = "Own One", revision = first, guideCount = 1 },
        { id = "own-two", label = "Own Two", revision = second, guideCount = 2 },
    }
    world:connect(true); world:advance(4)
    local group = addon.db.restedxp.groups[addon.fingerprint]
    local function offer(source, id, hash)
        local body = "1|V|" .. id .. "|" .. hash .. "|1"
        assert(world.receive(source, body .. "|" .. addon:SignGroupMessage("restedxp", body)))
    end
    offer("Alpha-TestRealm", "remote-one", first)
    offer("ALPHA-TESTREALM", "remote-two", second)
    offer("Zeta-TestRealm", "remote-one", third)
    group.sources["not-downloaded"] = "offline-testrealm"
    local state = addon:GetRestedXPState()
    assert(#state.publishers == 4 and state.publishers[1].source == "alpha-testrealm"
        and state.publishers[2].source == "offline-testrealm" and state.publishers[3].source == "viewer-testrealm"
        and state.publishers[4].source == "zeta-testrealm", "publisher rows normalize names and sort once per player")
    assert(state.publishers[3].localPack and state.publishers[3].packCount == 2
        and not state.publishers[3].canFollow and state.publishers[3].status == "Shared",
        "all locally shared guide groups appear as one player who cannot follow themselves")
    assert(state.publishers[2].selected and not state.publishers[2].canFollow
        and state.publishers[2].status == "Publisher offline", "an offline subscription stays visible without cached guides")
    assert(addon:SelectRestedXPPack("remote-one", "alpha-testrealm"))
    group.installed["viewer-testrealm"]["remote-one"] = first
    state = addon:GetRestedXPState()
    assert(not state.publishers[1].selected and state.publishers[1].canFollow
        and state.publishers[1].status == "Partly followed", "partially followed publishers can still follow their remaining packs")
    assert(addon:SelectRestedXPPublisher("ALPHA-TESTREALM"))
    assert(group.sources["remote-one"] == "alpha-testrealm" and group.sources["remote-two"] == "alpha-testrealm"
        and group.sources["not-downloaded"] == "offline-testrealm", "the publisher choice preserves unrelated subscriptions")
    offer("Alpha-TestRealm", "remote-three", third)
    state = addon:GetRestedXPState()
    assert(group.sources["remote-three"] == nil and not state.publishers[1].selected and state.publishers[1].canFollow,
        "a newly advertised pack requires another explicit publisher choice")
    assert(state.guideStatus == "Publisher offline", "a missing followed offer cannot be reported as current")
    group.sources["not-downloaded"] = nil
    assert(addon:GetRestedXPState().guideStatus == "Updates available")
    addon.restedxpState.failed["remote-two"] = second
    assert(addon:GetRestedXPState().guideStatus == "Update failed", "a failed current followed revision takes priority over available updates")
    addon.restedxpState.failed["remote-two"] = third
    assert(addon:GetRestedXPState().guideStatus == "Updates available", "an obsolete failure cannot hide a new publisher revision")
    group.installed["viewer-testrealm"]["remote-two"] = second
    assert(addon:GetRestedXPState().guideStatus == "Up to date", "only followed current revisions determine the update result")
    addon.restedxpState.failed["remote-two"] = nil
    assert(addon:ImportRestedXPPack("invalid", "bad", "Source#1234"))
    world:advance(0.1)
    assert(addon:GetRestedXPState().guideStatus == "Needs attention",
        "a failed manual export remains visible even when followed guides already match")
    world:advance(4)
    assert(addon:GetRestedXPState().guideStatus == "Needs attention", "background inventory work does not clear an import error")
    addon.restedxpState.incoming = { source = "alpha-testrealm", size = 200, bytes = 50 }
    assert(addon:GetRestedXPState().guideStatus == "Updating (25%)", "the single guide status includes current transfer progress")
    addon.restedxpState.incoming = nil
end

-- Cached updates and local inventory can share a group ID without sharing a
-- publisher. Attribute failures to the source of that particular revision.
do
    local addon, world = client("Attribution", nil, nil, nil, true)
    local older, newer = string.rep("a", 64), string.rep("b", 64)
    world.inventory = { { id = "same-group", label = "Own Guides", revision = older, guideCount = 1 } }
    world:connect(true); world:advance(4)
    local group = addon.db.restedxp.groups[addon.fingerprint]
    group.packs["same-group"] = { hash = newer, revision = newer, data = "verified cached transfer", source = "alpha-testrealm" }
    group.sources["same-group"], addon.restedxpState.failed["same-group"] = "alpha-testrealm", newer
    local body = "1|V|same-group|" .. newer .. "|1"
    assert(world.receive("Alpha-TestRealm", body .. "|" .. addon:SignGroupMessage("restedxp", body)))
    local state = addon:GetRestedXPState()
    assert(#state.publishers == 2 and state.publishers[1].packCount == 1 and state.publishers[1].status == "Update failed"
        and state.publishers[2].localPack and state.publishers[2].status == "Shared",
        "a failed remote cached revision cannot label the player's own successfully shared inventory as failed")
    group.installed["attribution-testrealm"]["same-group"] = newer
    state = addon:GetRestedXPState()
    assert(state.guideStatus == "Up to date" and state.publishers[1].status == "Up to date",
        "a later verified native match supersedes an earlier failure for the same revision")
end

-- Bulk subscriptions enforce the same cap before changing any existing source,
-- and stale offers or lifecycle boundaries cannot save a partial selection.
do
    local addon, world = client("Limits")
    world:connect(true); world:advance(4)
    local group = addon.db.restedxp.groups[addon.fingerprint]
    for index = 1, 7 do group.sources["existing-" .. index] = "other-testrealm" end
    local hash = string.rep("a", 64)
    for _, id in ipairs({ "existing-1", "new-one", "new-two" }) do
        local body = "1|V|" .. id .. "|" .. hash .. "|1"
        assert(world.receive("Alpha-TestRealm", body .. "|" .. addon:SignGroupMessage("restedxp", body)))
    end
    assert(not addon:SelectRestedXPPublisher("Alpha-TestRealm"))
    assert(group.sources["existing-1"] == "other-testrealm" and not group.sources["new-one"] and not group.sources["new-two"],
        "exceeding the subscription limit changes none of a publisher's sources")
    group.sources["existing-7"] = nil
    assert(addon:SelectRestedXPPublisher("Alpha-TestRealm") and group.sources["existing-1"] == "alpha-testrealm"
        and group.sources["new-one"] == "alpha-testrealm" and group.sources["new-two"] == "alpha-testrealm",
        "replacing existing subscriptions consumes no additional slots")
    local expected = Copy(group.sources)
    local function Unchanged()
        for id, source in pairs(expected) do assert(group.sources[id] == source) end
        for id, source in pairs(group.sources) do assert(expected[id] == source) end
    end
    assert(not addon:SelectRestedXPPublisher("Limits-TestRealm")); Unchanged()
    addon.savedDataReadOnly = true
    assert(not addon:SelectRestedXPPublisher("Alpha-TestRealm")); Unchanged()
    addon.savedDataReadOnly = nil
    addon.restedxpState.incoming = {}
    assert(not addon:SelectRestedXPPublisher("Alpha-TestRealm")); Unchanged()
    addon.restedxpState.incoming = nil
    addon.restedxpState.peerTest = {}
    assert(not addon:SelectRestedXPPublisher("Alpha-TestRealm")); Unchanged()
    addon.restedxpState.peerTest = nil
    addon.switching = true
    assert(not addon:SelectRestedXPPublisher("Alpha-TestRealm")); Unchanged()
    addon.switching, addon.fingerprint = nil, "changed-before-notification"
    assert(not addon:SelectRestedXPPublisher("Alpha-TestRealm") and not addon.db.restedxp.groups[addon.fingerprint]); Unchanged()
    addon.fingerprint = "test-group"
    world:advance(200)
    assert(not addon:SelectRestedXPPublisher("Alpha-TestRealm")); Unchanged()
end

-- The main status distinguishes installation and connection problems from a
-- usable local library; automatic sharing alone does not certify an update.
do
    local addon, world = client("Summary", nil, nil, nil, true)
    world.missing = true
    assert(addon:GetRestedXPState().guideStatus == "Not installed")
    world.missing = false
    local installation = addon.GetRestedXPInstallation
    function addon:GetRestedXPInstallation()
        local result = installation(self)
        result.loaded, result.compatible = false, false
        return result
    end
    assert(addon:GetRestedXPState().guideStatus == "Not loaded")
    function addon:GetRestedXPInstallation()
        local result = installation(self)
        result.compatible = false
        return result
    end
    assert(addon:GetRestedXPState().guideStatus == "Unavailable")
    addon.GetRestedXPInstallation = installation
    addon.savedDataReadOnly = true
    assert(addon:GetRestedXPState().guideStatus == "Read-only")
    addon.savedDataReadOnly = nil
    assert(addon:GetRestedXPState().guideStatus == "Disconnected")
    world:connect(true)
    assert(addon:GetRestedXPState().guideStatus == "Checking")
    world:advance(4)
    assert(addon:GetRestedXPState().guideStatus == "No guides")
    world.inventory = { { id = "own-guides", label = "Own Guides", revision = string.rep("a", 64), guideCount = 5 } }
    world.installedChanged(); world:advance(2)
    assert(addon:GetRestedXPState().guideStatus == "Ready", "shared local guides do not claim an online update comparison")
    local body = "1|V|remote-guides|" .. string.rep("b", 64) .. "|1"
    assert(world.receive("Other-TestRealm", body .. "|" .. addon:SignGroupMessage("restedxp", body)))
    assert(addon:GetRestedXPState().guideStatus == "Choose a publisher")
end

-- Authentication, bounded packets, disconnects and read-only data protect the
-- group lifecycle. Accepted native sends alone are never delivery confirmation.
do
    local addon, world, env = client("Beta")
    world:connect(true)
    local function sign(body) return body .. "|" .. addon:SignGroupMessage("restedxp", body) end
    local hash = string.rep("a", 64)
    assert(not world.receive("Alpha-TestRealm", "1|O|leveling|" .. hash .. "|100|" .. string.rep("0", 64)))
    assert(not world.receive("Alpha-TestRealm", sign("1|O|bad id|" .. hash .. "|100")))
    assert(not world.receive("Alpha-TestRealm", sign("1|O|leveling|" .. hash .. "|99999999")))
    assert(not world.receive("Beta-TestRealm", sign("1|O|leveling|" .. hash .. "|100")))
    assert(world.receive("Alpha-TestRealm", sign("1|O|leveling|" .. hash .. "|100")))
    assert(addon:SelectRestedXPPack("leveling", "alpha-testrealm"))
    assert(addon:UpdateRestedXPGuides())
    world:advance(3)
    assert(addon.restedxpState.incoming)
    world:connect(false)
    local count = #world.sent
    world:advance(50)
    assert(#world.sent == count and not addon.restedxpState.incoming)
    addon.fingerprint = "other-group"
    addon:Notify("GROUP_CHANGED")
    assert(addon.db.restedxp.groups["test-group"] == nil and #addon:GetRestedXPState().packs == 0)
    world:connect(true)
    assert(not world.receive("Alpha-TestRealm", sign("1|D|" .. hash:sub(1, 16) .. "|1|abc")))

    local future = { untouched = true }
    local readonly, readWorld = client("ReadOnly", future, true)
    readWorld:connect(true)
    readWorld:advance(5)
    assert(not readonly:UpdateRestedXPGuides() and not readonly:ImportRestedXPPack("test", "bad", "Source#1234"))
    assert(future.untouched and future.restedxp == nil and #readWorld.sent == 0)
end

-- Empty inventories still complete discovery and restore the update control.
do
    local addon, world = client("Solo")
    world:connect(true)
    assert(addon:GetRestedXPState().busy, "login starts bounded discovery without a manual update")
    world:advance(4)
    assert(not addon:GetRestedXPState().busy and addon:GetRestedXPState().canUpdate
        and addon:GetRestedXPState().status:find("No LIT-shared packs found.", 1, true),
        "login discovery completes even when no member has published an export")
    assert(addon:UpdateRestedXPGuides())
    assert(addon:GetRestedXPState().busy)
    world:advance(4)
    assert(not addon:GetRestedXPState().busy and addon:GetRestedXPState().canUpdate)
    assert(addon:GetRestedXPState().status:find("No LIT-shared packs found.", 1, true))
end

-- Local publications install once, and an unchanged manual update has the same
-- no-op behavior as an unchanged followed pack. Failed installations remain retryable.
do
    local addon, world, api = client("Publisher")
    world:connect(true)
    publish(addon, packFor(addon, api, 1))
    world.failInstall = true
    assert(addon:UpdateRestedXPGuides())
    world:advance(4)
    assert(#world.installs == 1 and not addon:GetRestedXPState().packs[1].installed,
        "a failed local publication install is not recorded as installed")
    world.failInstall = false
    assert(addon:UpdateRestedXPGuides())
    world:advance(4)
    assert(#world.installs == 2 and addon:GetRestedXPState().packs[1].installed,
        "a manual update can retry a failed local publication install")
    local transferred = transferMessages(world)
    assert(addon:UpdateRestedXPGuides())
    world:advance(4)
    local state = addon:GetRestedXPState()
    assert(#world.installs == 2 and transferMessages(world) == transferred,
        "rechecking an identical local publication neither transfers nor reinstalls it")
    assert(not state.busy and state.status:find("up to date", 1, true),
        "an already installed local publication finishes with an explicit up-to-date result")
end

-- Explicit import results must not be overwritten by an earlier login check.
do
    local addon, world = client("Importer")
    world:connect(true)
    assert(addon:ImportRestedXPPack("invalid", "bad", "Source#1234"))
    world:advance(0.1)
    assert(not addon.restedxpState.job, "malformed exports finish validation without a long-running job")
    local failure = addon:GetRestedXPState().status
    assert(failure ~= "Checking available group guides..." and failure ~= "Validating invalid...",
        "an invalid export reports its validation failure")
    world:advance(4)
    assert(addon:GetRestedXPState().status == failure and not addon:GetRestedXPState().busy,
        "a login discovery timeout cannot replace the result of an explicitly started import")
end

-- Stale senders cannot permanently exhaust the peer slots, and selecting a new
-- source must not install an unrelated old cached package while that source is offline.
do
    local addon, world, api = client("Beta")
    world:connect(true)
    local function signed(body) return body .. "|" .. addon:SignGroupMessage("restedxp", body) end
    for index = 1, 32 do assert(world.receive("Peer" .. index .. "-TestRealm", signed("1|Q|hello"))) end
    assert(not world.receive("Peer33-TestRealm", signed("1|Q|hello")))
    world:advance(76)
    assert(world.receive("Peer33-TestRealm", signed("1|Q|hello")))
    local original = packFor(addon, api, 1)
    publish(addon, original)
    local group = addon.db.restedxp.groups[addon.fingerprint]
    group.packs.leveling.source = "alpha-testrealm"
    local hash = string.rep("a", 64)
    assert(world.receive("Other-TestRealm", signed("1|O|leveling|" .. hash .. "|100")))
    assert(addon:SelectRestedXPPack("leveling", "other-testrealm"))
    world:advance(200)
    assert(addon:UpdateRestedXPGuides())
    world:advance(3)
    assert(#world.installs == 0, "an unavailable newly selected publisher does not authorize the previous publisher's cache")
    assert(addon:GetRestedXPState().status:find("offline", 1, true),
        "a completed discovery distinguishes offline publishers from confirmed current content")
end

-- Cooperative checkpoints must not each impose a separate frame's delay.
do
    local addon, world, api = client("FastPreparation", nil, nil, true)
    world.scanYields = 80
    world.installedPacks = { { id = "prepared-quickly", label = "Quick Pack", pack = packFor(addon, api, 1) } }
    world:connect(true)
    world:advance(0.5)
    local group = addon.db.restedxp.groups[addon.fingerprint]
    assert(group.packs["prepared-quickly"] and not addon:GetRestedXPState().refreshingInstalled,
        "many inexpensive preparation checkpoints finish promptly instead of waiting one timer per checkpoint")
end

-- Discovery and publisher selection remain responsive while a large installed
-- library is being prepared, without scheduling that library a second time.
do
    local addon, world, api = client("BackgroundPreparation", nil, nil, true)
    local pack = packFor(addon, api, 1)
    world.scanYields = 5000
    world.installedPacks = { { id = "installed-background", label = "Background Pack", pack = pack } }
    world:connect(true)
    world:advance(2.5)
    local state = addon:GetRestedXPState()
    assert(state.refreshingInstalled and addon.restedxpState.job and not state.busy and state.canUpdate,
        "login discovery finishes and enables Update even while background preparation is still active")
    local offer = "1|O|installed-background|" .. pack.hash .. "|" .. #pack.data
    assert(world.receive("Other-TestRealm", offer .. "|" .. addon:SignGroupMessage("restedxp", offer)))
    assert(#addon:GetRestedXPState().packs == 1
        and addon:SelectRestedXPPack("installed-background", "other-testrealm"),
        "online publishers appear and can be followed while local preparation continues")
    world.installedChanged(); world.installedChanged()
    assert(addon:UpdateRestedXPGuides(), "Update can request discovery during background preparation")
    world:advance(2.5)
    state = addon:GetRestedXPState()
    assert(world.scans == 1 and state.refreshingInstalled and not state.busy and state.canUpdate,
        "duplicate observer and update requests neither restart the library nor prolong discovery")
    for _ = 1, 1500 do
        if not addon:GetRestedXPState().refreshingInstalled then break end
        world:advance(0.01)
    end
    state = addon:GetRestedXPState()
    assert(not state.refreshingInstalled and state.canUpdate and world.scans == 1
        and #world.installs == 0 and transferMessages(world) == 0,
        "preparation completes once without an extra discovery delay or an identical-content import")
end

-- A user import may interrupt preparation, while a resumed background scan
-- must preserve the import's actionable validation result.
do
    local addon, world = client("PriorityImport", nil, nil, true)
    world.scanYields = 1000
    world:connect(true)
    world:advance(0.2)
    assert(addon.restedxpState.job and addon:GetRestedXPState().refreshingInstalled)
    assert(addon:ImportRestedXPPack("invalid", "bad", "Source#1234"),
        "manual imports take priority over source preparation")
    world:advance(0.1)
    local failure = addon:GetRestedXPState().status
    assert(failure:find("Unsupported or invalid", 1, true), "the explicit import reports its validation failure")
    world:advance(4)
    assert(addon:GetRestedXPState().status == failure and not addon:GetRestedXPState().refreshingInstalled,
        "resuming background preparation preserves the foreground error and completes normally")
end

-- Production discovery reads native IDs and versions, without preparing source
-- until a followed publisher receives a request for a missing guide version.
do
    local publisher, a, api = client("MetadataAlpha", nil, nil, nil, true)
    local recipient, b = client("MetadataBeta", nil, nil, nil, true)
    local id, otherID = "metadata-route", "metadata-unrequested"
    local revision, updatedRevision = string.rep("a", 64), string.rep("b", 64)
    local initial = packFor(publisher, api, 1)
    a.inventory = {
        { id = id, label = "Metadata Route", revision = revision, guideCount = 1 },
        { id = otherID, label = "Unrequested Route", revision = string.rep("c", 64), guideCount = 1 },
    }
    b.inventory = { { id = id, label = "Metadata Route", revision = revision, guideCount = 1 } }
    a.preparedPacks[id] = { revision = revision, pack = initial }
    a:connect(true); b:connect(true)
    exchange(a, b, 4)
    assert(a.inventoryScans and b.inventoryScans and not a.scans and not b.scans
        and #a.prepares == 0 and #b.prepares == 0,
        "login publishes installed guide IDs and versions without collecting or preparing full sources")
    assert(recipient:SelectRestedXPPack(id, "metadataalpha-testrealm"))
    assert(recipient:UpdateRestedXPGuides())
    exchange(a, b, 4)
    assert(transferMessages(a) == 0 and transferMessages(b) == 0 and #a.prepares == 0
        and #b.prepares == 0 and #b.installs == 0,
        "matching native guide IDs and versions need no requests, source preparation, data or native import")

    local sameVersion = packFor(publisher, api, 1, 23)
    a.preparedPacks[id] = { revision = revision, pack = sameVersion }
    local lastAnnouncement = #a.sent
    a.installedChanged()
    exchange(a, b, 4)
    for index = lastAnnouncement + 1, #a.sent do
        assert(not a.sent[index]:match("^1|[VQ]|"),
            "raw source changes retaining guide IDs and versions do not announce a metadata update")
    end
    assert(#a.prepares == 0 and #b.installs == 0,
        "unchanged versions do not cause source inspection or an automatic content update")

    local changed = packFor(publisher, api, 2, 29)
    a.inventory[1].revision = updatedRevision
    a.preparedPacks[id] = { revision = updatedRevision, pack = changed }
    b.afterInstall = function(pack)
        assert(type(pack.guides) == "table", "on-demand downloads are fully decoded before native import")
        b.inventory[1].revision = updatedRevision
    end
    a.installedChanged()
    exchange(a, b, 70)
    assert(#a.prepares == 1 and a.prepares[1].id == id and a.prepares[1].revision == updatedRevision
        and #b.prepares == 0 and not a.scans and not b.scans,
        "a changed version prepares only the selected publisher group when its follower requests it")
    assert(#b.installs == 1 and b.installs[1] == changed.hash,
        "ready-size announcement and canonical transfer install the newly advertised native guide version")
    local saved = recipient.db.restedxp.groups[recipient.fingerprint].packs[id]
    assert(saved and saved.hash == changed.hash and saved.revision == updatedRevision,
        "download integrity retains its canonical content hash separately from update-detection metadata")
    local followed
    for _, entry in ipairs(recipient:GetRestedXPState().packs) do
        if entry.id == id and entry.source == "metadataalpha-testrealm" then followed = entry end
    end
    assert(followed and followed.installed and followed.hash == updatedRevision,
        "the publisher's ID-and-version revision is recognized as installed after the native import")
    local counts = recipient:GetRestedXPPerformance()
    SameTraffic(counts.tx, Traffic(b.sent), "metadata guide requests retain exact transmit accounting")
    SameTraffic(counts.rx, Traffic(b.observed), "inventory and ready-size announcements retain exact observed accounting")

    local newestRevision = string.rep("f", 64)
    a.inventory[1].revision = newestRevision
    a.installedChanged()
    assert(publisher:UpdateRestedXPGuides())
    a:advance(4) -- the recipient does not request the new version during this local check
    local current = publisher:GetRestedXPState()
    local native
    for _, entry in ipairs(current.packs) do
        if entry.id == id and entry.localPack then native = entry end
    end
    assert(native and native.installed and native.hash == newestRevision and #a.installs == 0,
        "a newer native version stays installed even while the publisher caches an older prepared export")
    assert(not current.busy and not current.status:find("Use Update guides to install", 1, true)
        and (current.status:find("shared with your group", 1, true) or current.status:find("up to date", 1, true)),
        "a completed publisher check reports its current shared inventory instead of offering to reinstall stale cached content")
end

-- Automatically shared exports carry native compressed cache entries intact.
-- The transport never opens their guide contents; native import owns validation.
do
    local publisher, a, api = client("CachedAlpha", nil, nil, nil, true)
    local recipient, b, recipientAPI = client("CachedBeta", nil, nil, nil, true)
    local id = "cached-compressed-route"
    local firstRevision, nextRevision, failedRevision = string.rep("1", 64), string.rep("2", 64), string.rep("3", 64)
    local bytes = {}
    for index = 0, 255 do bytes[#bytes + 1] = string.char(index) end
    local opaque = string.rep(table.concat(bytes), 8)
    local function Cached(revision, sources)
        local pack = assert(publisher.RestedXPCodec.FromCachedSources(sources))
        pack.hash, pack.id, pack.revision = revision, id, revision
        return pack
    end
    local function Metadata(revision)
        return { { id = id, label = "Cached Compressed Route", revision = revision, guideCount = 2 } }
    end
    local initial = Cached(firstRevision, { opaque, "initial native cache bytes\0\255" })
    a.inventory, b.inventory = Metadata(firstRevision), Metadata(firstRevision)
    a.preparedPacks[id] = { revision = firstRevision, pack = initial }
    local function ForbidContentProcessing(addon, environment)
        local function Forbidden() error("Cached transport must not decompress, normalize or hash guide contents") end
        addon.RestedXPCodec.DecodeCanonical, addon.RestedXPCodec.DecodeCachedSource = Forbidden, Forbidden
        local deflate = environment.LibStub("LITLibDeflate")
        deflate.DecompressZlib, deflate.DecompressZlibBounded, deflate.DecompressDeflate = Forbidden, Forbidden, Forbidden
        deflate.CompressZlib, deflate.CompressDeflate = Forbidden, Forbidden
        local hash = addon.Crypto.SHA256
        addon.Crypto.SHA256 = function(message, progress)
            assert(#message <= 512, "Cached transport must not compute a whole-guide content hash")
            return hash(message, progress)
        end
    end
    ForbidContentProcessing(publisher, api)
    ForbidContentProcessing(recipient, recipientAPI)
    a:connect(true); b:connect(true)
    exchange(a, b, 4)
    assert(recipient:SelectRestedXPPack(id, "cachedalpha-testrealm"))
    assert(recipient:UpdateRestedXPGuides())
    exchange(a, b, 4)
    assert(not a.scans and not b.scans and #a.prepares == 0 and #b.prepares == 0
        and transferMessages(a) == 0 and transferMessages(b) == 0,
        "matching cache metadata never reads compressed guide contents or starts preparation")

    local sources = { opaque .. "updated", "second opaque native cache entry\0\254" }
    local changed = Cached(nextRevision, sources)
    a.inventory, a.preparedPacks[id] = Metadata(nextRevision), { revision = nextRevision, pack = changed }
    b.afterInstall = function(pack)
        assert(pack.cacheFormat and pack.id == id and pack.revision == nextRevision and pack.hash == nextRevision,
            "native installation receives the cached envelope and its metadata identity")
        assert(pack.cachedSources[1] == sources[1] and pack.cachedSources[2] == sources[2],
            "binary native cache bytes and source ordering survive the complete packet transfer")
        b.inventory = Metadata(nextRevision)
    end
    a.installedChanged()
    exchange(a, b, 70)
    assert(#a.prepares == 1 and #b.installs == 1 and b.installs[1] == nextRevision
        and b.installPayloads[1].cacheFormat and not b.installPayloads[1].guides,
        "cached transfers prepare once and reach native import without decoding guide source")
    local installed = recipient.db.restedxp.groups[recipient.fingerprint].installed["cachedbeta-testrealm"]
    assert(installed[id] == nextRevision, "cached content becomes installed only after native completion succeeds")

    b.failInstall, b.afterInstall = true, nil
    local rejected = Cached(failedRevision, { opaque .. "rejected", "native validation will reject this entry" })
    a.inventory, a.preparedPacks[id] = Metadata(failedRevision), { revision = failedRevision, pack = rejected }
    a.installedChanged()
    exchange(a, b, 70)
    assert(#b.installs == 2 and b.installs[2] == failedRevision
        and recipient.restedxpState.failed[id] == failedRevision and installed[id] == nextRevision,
        "native rejection is propagated without marking the newly transferred cached bytes as installed")

    local malformedRevision = string.rep("4", 64)
    local truncated = Cached(malformedRevision, { opaque, "truncated cached envelope" })
    truncated.data = truncated.data:sub(1, -2)
    a.inventory, a.preparedPacks[id] = Metadata(malformedRevision), { revision = malformedRevision, pack = truncated }
    a.installedChanged()
    exchange(a, b, 70)
    assert(#b.installs == 2 and recipient.restedxpState.failed[id] == malformedRevision and installed[id] == nextRevision,
        "a truncated cached envelope fails before native installation (imports=" .. #b.installs
            .. ", rejected=" .. tostring(recipient.restedxpState.failed[id]) .. ")")
end

-- A recipient's native group can contain extra guide IDs. The transferred
-- subset's explicit ID/version manifest must survive metadata refresh and reload.
do
    local publisher, a = client("SubsetAlpha", nil, nil, nil, true)
    local recipient, b = client("SubsetBeta", nil, nil, nil, true)
    local id = "cached-subset-route"
    local sourceRevision, localRevision = string.rep("5", 64), string.rep("6", 64)
    local expected = { { id = "expected-one", version = 1 }, { id = "expected-two", version = 2 } }
    local pack = assert(publisher.RestedXPCodec.FromCachedSources({ "opaque native cache one", "opaque native cache two" }, expected))
    pack.id, pack.revision, pack.hash = id, sourceRevision, sourceRevision
    assert(pack.data:sub(1, 6) == "LITC2|", "the fixture includes its expected guide ID/version manifest")
    a.inventory = { { id = id, label = "Shared Subset", revision = sourceRevision, guideCount = 2 } }
    a.preparedPacks[id] = { revision = sourceRevision, pack = pack }
    b.inventory = { { id = id, label = "Own Group With Extra Guide", revision = localRevision, guideCount = 3 } }
    local function EnableSubsetMatch(world)
        world:enableCachedMatching()
        world.validateCachedMatch = function(candidate)
            assert(candidate.id == id and candidate.expectedGuides and #candidate.expectedGuides == 2
                and candidate.expectedGuides[1].id == "expected-one" and candidate.expectedGuides[1].version == 1
                and candidate.expectedGuides[2].id == "expected-two" and candidate.expectedGuides[2].version == 2,
                "native matching receives the persisted subset identity and expected versions without reading source")
        end
    end
    EnableSubsetMatch(b)
    b.afterInstall = function(received)
        assert(received.cacheFormat and received.expectedGuides and received.revision == sourceRevision,
            "native installation receives the transferred subset manifest")
        b.cachedMatches[sourceRevision] = true
    end
    a:connect(true); b:connect(true)
    exchange(a, b, 4)
    assert(recipient:SelectRestedXPPack(id, "subsetalpha-testrealm"))
    assert(recipient:UpdateRestedXPGuides())
    exchange(a, b, 40)
    assert(#b.installs == 1 and b.installs[1] == sourceRevision,
        "the missing guide subset is installed once despite the recipient's different aggregate group revision")
    local group = recipient.db.restedxp.groups[recipient.fingerprint]
    local saved = assert(group.packs[id])
    assert(saved.id == id and saved.expectedGuides and #saved.expectedGuides == 2,
        "the cached transfer persists the metadata needed to recognize its installed subset")
    local requests, prepares = transferMessages(b), #a.prepares
    recipient.restedxpState.decoded = {}
    b.installedChanged()
    exchange(a, b, 4)
    assert(recipient:UpdateRestedXPGuides())
    exchange(a, b, 5)
    assert(group.installed["subsetbeta-testrealm"][id] == sourceRevision
        and b.persistedCachedMatchCalls and b.persistedCachedMatchCalls > 0
        and transferMessages(b) == requests and #a.prepares == prepares and #b.installs == 1,
        "extra local guide IDs cannot erase the installed subset marker or trigger repeated downloads and imports")

    local reloaded, c = client("SubsetBeta", Copy(recipient.db), nil, nil, true)
    c.inventory = Copy(b.inventory)
    EnableSubsetMatch(c)
    c.cachedMatches[sourceRevision] = true
    c:connect(true)
    exchange(a, c, 5)
    assert(reloaded:UpdateRestedXPGuides())
    exchange(a, c, 5)
    local persisted = reloaded.db.restedxp.groups[reloaded.fingerprint]
    assert(persisted.installed["subsetbeta-testrealm"][id] == sourceRevision
        and c.persistedCachedMatchCalls and c.persistedCachedMatchCalls > 0
        and transferMessages(c) == 0 and #c.prepares == 0 and #c.installs == 0,
        "reloading restores installed subset recognition from saved expected metadata with no source transfer or native import")
end

-- Even a delayed native metadata API must replace discovery's temporary
-- preparation message with its completed inventory result.
do
    local addon, world = client("SlowInventory", nil, nil, nil, true)
    world.inventoryYields = 3000
    world.inventory = { { id = "slow-inventory", label = "Slow Inventory", revision = string.rep("a", 64), guideCount = 1 } }
    world:connect(true)
    world:advance(2.5)
    assert(addon:GetRestedXPState().refreshingInstalled,
        "the metadata fixture remains active beyond the initial discovery window")
    world:advance(5.5)
    local complete = addon:GetRestedXPState()
    assert(not complete.refreshingInstalled and not complete.busy and complete.sharedInstalledGuides == 1
        and not complete.status:find("still being", 1, true) and complete.status:find("shared", 1, true),
        "delayed metadata completion finalizes the header rather than leaving temporary preparation guidance")
end

-- Source preparation happens only on request and can legitimately outlast a
-- normal data-transfer idle timeout before the publisher knows the export size.
do
    local publisher, a, api = client("SlowPrepareAlpha", nil, nil, nil, true)
    local recipient, b = client("SlowPrepareBeta", nil, nil, nil, true)
    local id, revision = "slow-prepared-route", string.rep("b", 64)
    local pack = packFor(publisher, api, 4)
    a.inventory = { { id = id, label = "Slow Prepared Route", revision = revision, guideCount = 1 } }
    a.preparedPacks[id] = { revision = revision, pack = pack }
    a.prepareYields = 30000
    a:connect(true); b:connect(true)
    exchange(a, b, 4)
    assert(recipient:SelectRestedXPPack(id, "slowpreparealpha-testrealm"))
    assert(recipient:UpdateRestedXPGuides())
    local beforeReady = 0
    exchange(a, b, 70, function(wire)
        if wire:find("1|O|" .. id .. "|", 1, true) == 1 and beforeReady == 0 then beforeReady = #b.sent end
        return true
    end)
    assert(#a.prepares == 1 and #b.installs == 1 and b.installs[1] == pack.hash,
        "on-demand preparation beyond thirty seconds completes with one export job and one native installation")
    local requests = 0
    assert(beforeReady > 0, "the publisher announces the prepared size after its long export job")
    for index = 1, beforeReady do
        if b.sent[index]:match("^1|W|") then requests = requests + 1 end
    end
    assert(requests <= 5, "waiting for a prepared size sends only sparse bounded requests")
end

-- Preparing an older requested revision can finish after a publisher has
-- announced a newer revision; readiness must not roll availability backward.
do
    local addon, world = client("StaleReadiness")
    world:connect(true)
    world:advance(3)
    local id, older, newer = "metadata-readiness", string.rep("d", 64), string.rep("e", 64)
    local function Signed(body) return body .. "|" .. addon:SignGroupMessage("restedxp", body) end
    assert(world.receive("Publisher-TestRealm", Signed("1|V|" .. id .. "|" .. older .. "|1|Route")))
    assert(addon:SelectRestedXPPack(id, "publisher-testrealm"))
    assert(addon:UpdateRestedXPGuides())
    world:advance(3)
    local incoming = assert(addon.restedxpState.incoming)
    assert(incoming.hash == older and not incoming.size, "metadata-only requests wait for a publisher's prepared size")
    assert(world.receive("Publisher-TestRealm", Signed("1|V|" .. id .. "|" .. newer .. "|2|Newer Route")))
    assert(world.receive("Publisher-TestRealm", Signed("1|O|" .. id .. "|" .. older .. "|321|Route")))
    local advertised = addon.restedxpState.offers[id]["publisher-testrealm"]
    assert(advertised.hash == newer and advertised.guideCount == 2 and advertised.versioned,
        "readiness for a previously requested revision cannot replace a newer ID/version announcement")
    assert(addon.restedxpState.incoming == incoming and incoming.size == 321 and incoming.count == 3,
        "matching readiness can still supply the old in-flight download size without changing current availability")
end

-- A missing publisher cannot keep the larger preparation grace period open
-- indefinitely when no ready-size response ever arrives.
do
    local addon, world = client("OfflinePreparation", nil, nil, nil, true)
    local id, revision = "offline-preparation", string.rep("c", 64)
    world:connect(true)
    world:advance(3)
    local body = "1|V|" .. id .. "|" .. revision .. "|1|Offline Route"
    assert(world.receive("Offline-TestRealm", body .. "|" .. addon:SignGroupMessage("restedxp", body)))
    assert(addon:SelectRestedXPPack(id, "offline-testrealm"))
    assert(addon:UpdateRestedXPGuides())
    world:advance(35)
    assert(addon.restedxpState.incoming and not addon.restedxpState.incoming.size,
        "unknown-size preparation is allowed more than the ordinary transfer timeout")
    world:advance(90)
    assert(not addon.restedxpState.incoming and not addon:GetRestedXPState().busy
        and addon.restedxpState.failed[id] == revision,
        "an offline publisher without readiness still reaches a bounded preparation timeout")
end

-- Legacy adapters without metadata access retain complete-export sharing.
-- Existing native imports become publications on login without an export form;
-- a later native import refreshes the same publication even without a new version.
do
    local publisher, a, api = client("AutoAlpha", nil, nil, true)
    local recipient, b = client("AutoBeta")
    local original = packFor(publisher, api, 7)
    a.installedPacks = { { id = "installed-route", label = "Synthetic Pack", pack = original } }
    a:connect(true)
    a:advance(4)
    local state = publisher:GetRestedXPState()
    local group = publisher.db.restedxp.groups[publisher.fingerprint]
    assert(group.packs["installed-route"] and group.packs["installed-route"].hash == original.hash
        and group.packs["installed-route"].localInstalled and state.sharedInstalledGuides == 1,
        "login collects a complete installed guide into a stable automatically shared pack")
    assert(state.packs[1].installed and #a.installs == 0,
        "a recovered installed guide is already installed and never needs a native self-import")
    assert(type(a.installedChanged) == "function", "native import observation starts automatically")
    a.delivered = #a.sent -- the later login must actively discover the existing holder
    b:connect(true)
    exchange(a, b, 4)
    assert(#recipient:GetRestedXPState().packs == 1 and #b.installs == 0,
        "a later group member discovers automatic publications without unsolicited installation")
    assert(recipient:SelectRestedXPPack("installed-route", "autoalpha-testrealm"))
    assert(recipient:UpdateRestedXPGuides())
    exchange(a, b, 70)
    assert(#b.installs == 1 and b.installs[1] == original.hash,
        "following an automatic publication installs the recovered source")
    local updated = packFor(publisher, api, 7, 11)
    a.installedPacks = { { id = "installed-route", label = "Synthetic Pack", pack = updated } }
    a.installedChanged()
    exchange(a, b, 70)
    assert(group.packs["installed-route"].hash == updated.hash and #a.installs == 0,
        "a direct RestedXP import refreshes its existing local publication without self-import")
    assert(#b.installs == 2 and b.installs[2] == updated.hash,
        "native content changes with unchanged versions announce and update followers automatically")
    local announced = #a.sent
    a.installedChanged()
    exchange(a, b, 4)
    for index = announced + 1, #a.sent do
        assert(not a.sent[index]:match("^1|[OQ]|"),
            "an unchanged native-source callback sends neither another offer nor a discovery query")
    end
    assert(#b.installs == 2, "an unchanged native-source callback does not reinstall its follower's guides")
end

-- Native recovery can finish after a recipient's short discovery window; the
-- later offer must replace the completed empty result with the next action.
do
    local publisher, a, api = client("LateAlpha", nil, nil, true)
    local recipient, b = client("LateBeta")
    a:connect(true); b:connect(true)
    exchange(a, b, 4)
    local empty = recipient:GetRestedXPState()
    assert(#empty.packs == 0 and not empty.busy and empty.status:find("No LIT-shared packs found.", 1, true),
        "initial empty discovery finishes before a publisher recovers a guide")
    a.installedPacks = { { id = "installed-later", label = "Later Pack", pack = packFor(publisher, api, 1) } }
    a.installedChanged()
    exchange(a, b, 4)
    local available = recipient:GetRestedXPState()
    assert(#available.packs == 1 and available.packs[1].id == "installed-later"
        and available.status:find("Choose Follow", 1, true)
        and not available.status:find("No LIT-shared packs found.", 1, true),
        "a publication recovered after discovery replaces the stale empty result with follow guidance")
    assert(#b.installs == 0 and transferMessages(b) == 0,
        "late automatic availability updates guidance without an unsolicited transfer")
end

-- Two native installations with identical source use their recovered hashes to
-- finish discovery without sending guide contents or importing them again.
do
    local alpha, a, api = client("SameAlpha", nil, nil, true)
    local beta, b = client("SameBeta", nil, nil, true)
    local pack = packFor(alpha, api, 3)
    a.installedPacks = { { id = "installed-same", label = "Same Pack", pack = pack } }
    b.installedPacks = { { id = "installed-same", label = "Same Pack", pack = pack } }
    a:connect(true); b:connect(true)
    exchange(a, b, 5)
    assert(alpha:SelectRestedXPPack("installed-same", "samebeta-testrealm"))
    assert(beta:SelectRestedXPPack("installed-same", "samealpha-testrealm"))
    assert(alpha:UpdateRestedXPGuides() and beta:UpdateRestedXPGuides())
    exchange(a, b, 5)
    assert(#a.installs == 0 and #b.installs == 0 and transferMessages(a) == 0 and transferMessages(b) == 0,
        "matching recovered hashes on both players avoid all guide requests, data and imports")
    assert(not alpha:GetRestedXPState().busy and not beta:GetRestedXPState().busy,
        "same-content checks finish for both players")
end

-- A native-cache notification during a download must wait until that download
-- has been installed, then recover the newly imported source rather than the old cache.
do
    local publisher, a, api = client("RaceAlpha", nil, nil, true)
    local recipient, b = client("RaceBeta", nil, nil, true)
    local original = packFor(publisher, api, 6)
    local id = "installed-race"
    a.installedPacks = { { id = id, label = "Racing Pack", pack = original } }
    b.installedPacks = { { id = id, label = "Racing Pack", pack = original } }
    b.afterInstall = function(pack)
        b.installedPacks = { { id = id, label = "Racing Pack", pack = pack } }
    end
    a:connect(true); b:connect(true)
    exchange(a, b, 5)
    assert(recipient:SelectRestedXPPack(id, "racealpha-testrealm"))
    local updated = packFor(publisher, api, 6, 13)
    a.installedPacks = { { id = id, label = "Racing Pack", pack = updated } }
    a.installedChanged()
    for _ = 1, 100 do
        exchange(a, b, 0.15)
        if recipient.restedxpState.incoming then break end
    end
    assert(recipient.restedxpState.incoming and #b.installs == 0,
        "the native notification occurs while the changed shared pack is still downloading")
    b.installedChanged()
    exchange(a, b, 70)
    local dataPackets = 0
    for _, wire in ipairs(a.sent) do
        if wire:find("1|D|" .. updated.hash:sub(1, 16) .. "|", 1, true) == 1 then dataPackets = dataPackets + 1 end
    end
    assert(#b.installs == 1 and b.installs[1] == updated.hash
        and dataPackets == math.ceil(#updated.data / 128),
        "deferred native recovery installs the changed pack once without downloading its chunks again")
    local saved = recipient.db.restedxp.groups[recipient.fingerprint].packs[id]
    assert(saved and saved.hash == updated.hash and not recipient:GetRestedXPState().refreshingInstalled,
        "post-import recovery publishes the new native source and finishes the deferred refresh")

    local rejected = packFor(publisher, api, 6, 19)
    a.installedPacks = { { id = id, label = "Racing Pack", pack = rejected } }
    b.failInstall = true
    a.installedChanged()
    for _ = 1, 100 do
        exchange(a, b, 0.15)
        if recipient.restedxpState.incoming then break end
    end
    assert(recipient.restedxpState.incoming)
    b.installedChanged()
    exchange(a, b, 70)
    assert(#b.installs == 2 and recipient.restedxpState.failed[id] == rejected.hash,
        "failed native import followed by old-source recovery retains the rejected remote hash")
    local requests, responses = transferMessages(b), transferMessages(a)
    b.installedChanged()
    a.installedChanged()
    exchange(a, b, 10)
    assert(#b.installs == 2 and transferMessages(b) == requests and transferMessages(a) == responses
        and recipient.restedxpState.failed[id] == rejected.hash,
        "unchanged old native source and repeated announcements cannot trigger a failed-update retry loop")
    b.failInstall = false
    assert(recipient:UpdateRestedXPGuides())
    exchange(a, b, 70)
    assert(#b.installs == 3 and b.installs[3] == rejected.hash,
        "an explicit update still retries the previously rejected newer content")
end

-- A downloaded pack can match a native installation recovered through another
-- grouping, so exact native-source verification can avoid the redundant import.
do
    local publisher, a, api = client("MatchAlpha", nil, nil, true)
    local recipient, b = client("MatchBeta", nil, nil, true)
    local pack = packFor(publisher, api, 4)
    a.installedPacks = { { id = "installed-match", label = "Matching Pack", pack = pack } }
    b.matches = { [pack.hash] = true }
    a:connect(true); b:connect(true)
    exchange(a, b, 5)
    assert(recipient:SelectRestedXPPack("installed-match", "matchalpha-testrealm"))
    assert(recipient:UpdateRestedXPGuides())
    exchange(a, b, 70)
    assert(transferMessages(b) > 0 and #b.installs == 0,
        "verified matching native source suppresses import after a first download")
    local found
    for _, available in ipairs(recipient:GetRestedXPState().packs) do
        if available.id == "installed-match" and available.source == "matchalpha-testrealm" then found = available end
    end
    assert(found and found.installed, "a native content match is recorded as installed")
end

-- Removal withdraws only local automatic publications; explicit fallback exports
-- retain their independent lifetime and remain available to the group.
do
    local addon, world, api = client("Removal", nil, nil, true)
    local pack = packFor(addon, api, 2)
    world.installedPacks = { { id = "installed-remove", label = "Removed Pack", pack = pack } }
    world:connect(true)
    world:advance(4)
    publish(addon, packFor(addon, api, 5, 9), "manual-fallback")
    local group = addon.db.restedxp.groups[addon.fingerprint]
    assert(group.packs["installed-remove"] and group.packs["manual-fallback"])
    world.installedPacks = {}
    world.installedChanged()
    world:advance(4)
    assert(group.packs["installed-remove"] == nil and group.packs["manual-fallback"] ~= nil,
        "a complete source scan withdraws removed automatic packs and preserves explicit exports")
    assert(addon:GetRestedXPState().sharedInstalledGuides == 0,
        "sharing counts refresh when all native source guides are removed")
end

-- The group cache is account-wide, while recoverable native source can change
-- between characters or RestedXP profiles on that account.
do
    local previous, a, api = client("PreviousCharacter", nil, nil, true)
    a.installedPacks = { { id = "installed-previous", label = "Previous Profile", pack = packFor(previous, api, 2) } }
    a:connect(true)
    a:advance(4)
    publish(previous, packFor(previous, api, 3, 17), "profile-fallback")
    local current, b = client("CurrentCharacter", Copy(previous.db), nil, true)
    b:connect(true)
    b:advance(4)
    local group = current.db.restedxp.groups[current.fingerprint]
    assert(group.packs["installed-previous"] == nil and group.packs["profile-fallback"] ~= nil,
        "an empty current profile withdraws earlier-character automatic packs and preserves explicit exports")
    for _, wire in ipairs(b.sent) do
        assert(not wire:find("1|O|installed-previous|", 1, true),
            "a restored automatic pack from another character is never advertised before current source validation")
    end
end

-- Busy imports defer source recovery; unavailable source finishes cleanly and
-- gives sharing guidance rather than leaving the tab indefinitely busy.
do
    local addon, world, api = client("Deferred", nil, nil, true)
    world.installedPacks = { { id = "installed-deferred", label = "Deferred Pack", pack = packFor(addon, api, 1) } }
    world.scanBusy = true
    world:connect(true)
    world:advance(3)
    assert(world.scans and world.scans > 0 and addon.db.restedxp.groups[addon.fingerprint].packs["installed-deferred"] == nil,
        "an active native import defers source collection without publishing partial data")
    world.scanBusy = false
    world:advance(5)
    assert(addon.db.restedxp.groups[addon.fingerprint].packs["installed-deferred"],
        "source collection retries after the native importer becomes available")
    world.scanProblem = "RestedXP's complete source cache is unavailable."
    world.installedChanged()
    world:advance(5)
    local state = addon:GetRestedXPState()
    assert(not state.refreshingInstalled and not state.busy and state.sharingStatus:find("unavailable", 1, true),
        "unavailable source recovery terminates and reports the compatibility problem")
    assert(addon.db.restedxp.groups[addon.fingerprint].packs["installed-deferred"],
        "an unavailable or incomplete scan does not withdraw the last complete publication")
end

-- Passive statistics distinguish native send failures and unsigned input from
-- transmitted frames and authenticated channel occupancy, including rejected bodies.
do
    local addon, world = client("CountedTraffic")
    world.rejectSends = true
    world:connect(true)
    world:advance(1)
    local report = addon:GetRestedXPPerformance()
    assert(report.rejectedSends >= 1 and report.tx.messages == 0,
        "rejected native sends are measured separately from successful transmitted frames")
    world.rejectSends = false
    world:advance(4)
    local function Signed(body) return body .. "|" .. addon:SignGroupMessage("restedxp", body) end
    assert(not world.receive("Peer-TestRealm", "1|Q|invalid|" .. string.rep("0", 64)))
    assert(addon:GetRestedXPPerformance().rx.messages == 0,
        "unsigned traffic does not inflate authenticated channel occupancy counts")
    local malformed = Signed("1|O|bad id|" .. string.rep("a", 64) .. "|100")
    assert(not world.receive("Peer-TestRealm", malformed))
    local query = Signed("1|Q|counted-peer")
    assert(world.receive("Peer-TestRealm", query))
    report = addon:GetRestedXPPerformance()
    SameTraffic(report.tx, Traffic(world.sent), "successful retry traffic is counted once")
    SameTraffic(report.rx, Traffic({ malformed, query }),
        "authenticated queries and rejected authenticated bodies count their complete observed channel sizes")
end

local function peerFixture()
    local publisher, a = client("PeerAlpha", nil, nil, nil, true)
    local recipient, b = client("PeerBeta", nil, nil, nil, true)
    local id, revision = "rxpi-" .. string.rep("a", 24), string.rep("9", 64)
    local bytes = {}
    for index = 0, 255 do bytes[#bytes + 1] = string.char(index) end
    local sources = { string.rep(table.concat(bytes), 4), "opaque second native guide cache" }
    local expected = { { id = "peer-first", version = 7 }, { id = "peer-second", version = 9 } }
    local pack = assert(publisher.RestedXPCodec.FromCachedSources(sources, expected))
    pack.id, pack.hash, pack.revision = id, revision, revision
    a.inventory = { { id = id, label = "Peer Test Guides", revision = revision, guideCount = 2 } }
    b.inventory = Copy(a.inventory)
    a.preparedPacks[id] = { revision = revision, pack = pack }
    b:enableCachedMatching()
    b.cachedMatches[revision] = true
    a:connect(true); b:connect(true)
    exchange(a, b, 4)
    return publisher, a, recipient, b, id, revision, pack
end
local function trafficSince(wires, first)
    local recent = {}
    for index = first + 1, #wires do recent[#recent + 1] = wires[index] end
    return Traffic(recent)
end
local function finishPeerTest(recipient, a, b, filter, limit)
    for _ = 1, math.ceil((limit or 80) / 0.15) do
        exchange(a, b, 0.15, filter)
        local report = recipient:GetRestedXPPerformance().peerTest
        if report and report.status ~= "running" then return report end
    end
    error("peer test did not reach a bounded terminal state")
end
local function checkPeerPhases(report)
    local totalTx, totalRx = Traffic({}), Traffic({})
    for _, name in ipairs({ "discovery", "transfer", "import" }) do
        local phase = assert(report.phases[name], "peer test reports the " .. name .. " phase")
        assert(type(phase.wall) == "number" and phase.wall >= 0, "peer phase timing is nonnegative")
        for field in pairs(totalTx) do
            totalTx[field], totalRx[field] = totalTx[field] + phase.tx[field], totalRx[field] + phase.rx[field]
        end
    end
    SameTraffic(report.tx, totalTx, "peer phase transmit counters account for the entire test")
    SameTraffic(report.rx, totalRx, "peer phase receive counters account for the entire test")
end

-- A peer test forces one ordinary discovery, download and native import even
-- when both the installed metadata and cached package already match exactly.
do
    local publisher, a, recipient, b, id, revision, pack = peerFixture()
    assert(recipient:SelectRestedXPPack(id, "peeralpha-testrealm"))
    local group = recipient.db.restedxp.groups[recipient.fingerprint]
    group.packs[id] = { id = id, data = pack.data, hash = revision, revision = revision,
        cacheFormat = true, guideCount = pack.guideCount, expectedGuides = Copy(pack.expectedGuides),
        source = "peeralpha-testrealm", label = "Already cached" }
    recipient.restedxpState.decoded[id] = Copy(pack)
    assert(group.installed["peerbeta-testrealm"][id] == revision)
    local sourcesBefore = Copy(group.sources)
    local sentBefore, receivedBefore = #b.sent, #b.observed
    assert(recipient:StartRestedXPPeerTest())
    local running = recipient:GetRestedXPPerformance().peerTest
    assert(running and running.status == "running", "the complete peer test starts with an observable running report")
    local duplicate, problem = recipient:StartRestedXPPeerTest()
    assert(not duplicate and type(problem) == "string", "a second peer test cannot replace the active test")
    local report = finishPeerTest(recipient, a, b)
    assert(report.status == "complete" and report.id == id and report.source == "peeralpha-testrealm"
        and report.wall >= 0 and #a.prepares == 1,
        "default peer testing selects the followed publisher and completes a real requested transfer")
    assert(#b.installs == 1 and b.installs[1] == revision and b.installOptions[1].test == true
        and b.installPayloads[1].cacheFormat and b.installPayloads[1].expectedGuides,
        "the test bypasses installed/cached matches and requests a forced native import of the same version")
    assert(report.tx.Q == 1 and report.tx.W >= 1 and report.rx.D == math.ceil(#pack.data / 128),
        "testing sends one normal discovery query and the complete normal guide download")
    SameTraffic(report.tx, trafficSince(b.sent, sentBefore), "peer test transmit counts match ordinary native frames")
    SameTraffic(report.rx, trafficSince(b.observed, receivedBefore), "peer test receive counts match ordinary observed frames")
    checkPeerPhases(report)
    assert(group.sources[id] == sourcesBefore[id],
        "the peer test preserves the followed publisher")
    for key, source in pairs(group.sources) do assert(sourcesBefore[key] == source, "peer testing adds no subscriptions") end
    for key, source in pairs(sourcesBefore) do assert(group.sources[key] == source, "peer testing removes no subscriptions") end
    local sent, observed, imported = #b.sent, #b.observed, #b.installs
    recipient:ShowRestedXPPerformance()
    assert(#b.sent == sent and #b.observed == observed and #b.installs == imported,
        "printing the peer report adds no diagnostic traffic or native imports")
    report.phases.discovery.tx.Q = 999
    assert(recipient:GetRestedXPPerformance().peerTest.phases.discovery.tx.Q ~= 999,
        "peer timing reports are detached snapshots")
end

-- Explicit targets require no saved subscription. Missing-chunk recovery uses
-- ordinary windows and repeats only the deliberately lost chunk.
do
    local _, a, recipient, b, id, _, pack = peerFixture()
    local group = recipient.db.restedxp.groups[recipient.fingerprint]
    assert(next(group.sources) == nil)
    assert(recipient:StartRestedXPPeerTest("peeralpha-testrealm", id))
    local sentBefore, dropped, chunks = #a.sent, false, {}
    local report = finishPeerTest(recipient, a, b, function(wire)
        local sequence = wire:match("^1|D|[^|]+|(%d+)|")
        if sequence then
            chunks[sequence] = (chunks[sequence] or 0) + 1
            if sequence == "3" and not dropped then dropped = true; return false end
        end
        return true
    end)
    assert(report.status == "complete" and dropped and #b.installs == 1 and next(group.sources) == nil,
        "an explicit one-off target recovers the lost chunk without saving a publisher selection")
    local packets = 0
    for sequence, count in pairs(chunks) do
        assert(count == (sequence == "3" and 2 or 1), "peer testing retransmits only a missing data sequence")
        packets = packets + count
    end
    assert(packets == math.ceil(#pack.data / 128) + 1 and #a.sent > sentBefore,
        "the peer test adds no diagnostic frames or redundant data beyond normal loss recovery")
end

do
    local _, a, recipient, b, id = peerFixture()
    assert(recipient:StartRestedXPPeerTest())
    local report = finishPeerTest(recipient, a, b)
    assert(report.status == "complete" and report.id == id and report.source == "peeralpha-testrealm"
        and next(recipient.db.restedxp.groups[recipient.fingerprint].sources) == nil,
        "with no followed publisher the default test uses an available peer without persisting a source")
end

-- Partial transfers expose useful counters before completion and retain those
-- counters when cancellation or the normal no-progress timeout ends the test.
do
    local _, a, recipient, b, id, _, pack = peerFixture()
    local function LoseAfterTwo(wire)
        local sequence = tonumber(wire:match("^1|D|[^|]+|(%d+)|"))
        return not sequence or sequence <= 2
    end
    assert(recipient:StartRestedXPPeerTest("peeralpha-testrealm", id))
    local partial
    for _ = 1, 100 do
        exchange(a, b, 0.15, LoseAfterTwo)
        local snapshot = recipient:GetRestedXPPerformance()
        if snapshot.peerTest and snapshot.peerTest.phase == "transfer"
            and snapshot.peerTest.bytes == 256 and snapshot.peerTest.retries > 0 then
            partial = snapshot.peerTest
            assert(snapshot.receiving and snapshot.receiving.bytes == partial.bytes)
            break
        end
    end
    assert(partial and partial.status == "running" and partial.expectedBytes == #pack.data,
        "active peer snapshots expose received bytes, expected bytes and missing-window retries")
    assert(recipient:CancelRestedXPPeerTest())
    local cancelled = recipient:GetRestedXPPerformance().peerTest
    assert(cancelled.status == "cancelled" and cancelled.bytes == 256 and cancelled.retries == partial.retries
        and cancelled.expectedBytes == #pack.data and #b.installs == 0,
        "cancelling a partial transfer preserves its last received-byte and retry counters")
    checkPeerPhases(cancelled)

    local _, timeoutA, timeoutRecipient, timeoutB, timeoutID, _, timeoutPack = peerFixture()
    assert(timeoutRecipient:StartRestedXPPeerTest("peeralpha-testrealm", timeoutID))
    local timedOut = finishPeerTest(timeoutRecipient, timeoutA, timeoutB, LoseAfterTwo)
    assert(timedOut.status == "failed" and timedOut.bytes == 256 and timedOut.retries > 0
        and timedOut.expectedBytes == #timeoutPack.data and #timeoutB.installs == 0,
        "transfer timeout retains partial bytes and retry windows instead of reporting zero completed work")
end

-- Native throttling can postpone the sole discovery query. Its response window
-- starts when that query is actually accepted, so a later normal reply remains
-- eligible without another query or any diagnostic protocol frames.
do
    local _, a, recipient, b, id = peerFixture()
    local before = #b.sent
    b.rejectSends = true
    assert(recipient:StartRestedXPPeerTest("peeralpha-testrealm", id))
    local delayed = {}
    local function HoldDiscovery(wire)
        if wire:match("^1|[VO]|") then delayed[#delayed + 1] = wire; return false end
        return true
    end
    exchange(a, b, 8, HoldDiscovery)
    local waiting = recipient:GetRestedXPPerformance().peerTest
    assert(waiting.status == "running" and waiting.tx.Q == 0,
        "rejected native discovery sends do not count as a successful query or prematurely finish the test")
    b.rejectSends = false
    for _ = 1, 20 do
        exchange(a, b, 0.15, HoldDiscovery)
        waiting = recipient:GetRestedXPPerformance().peerTest
        if waiting.tx.Q == 1 then break end
    end
    assert(waiting.status == "running" and waiting.tx.Q == 1 and waiting.queryWaitWall >= 8,
        "the accepted normal query records its real send delay")
    exchange(a, b, 8, HoldDiscovery)
    assert(recipient:GetRestedXPPerformance().peerTest.status == "running" and #delayed > 0,
        "discovery keeps its full response window after a delayed successful native send")
    for _, wire in ipairs(delayed) do
        b.observed[#b.observed + 1] = wire
        assert(b.receive("PeerAlpha-TestRealm", wire))
    end
    local report = finishPeerTest(recipient, a, b)
    assert(report.status == "complete" and report.tx.Q == 1 and trafficSince(b.sent, before).Q == 1 and #b.installs == 1,
        "a delayed ordinary publisher reply completes the test with exactly one successful discovery query")
    checkPeerPhases(report)
end

-- Failure and cancellation leave source preferences intact and stop the test
-- even when no publisher answers or a native import rejects its package.
do
    local addon, world = client("PeerOffline", nil, nil, nil, true)
    local accepted, problem = addon:StartRestedXPPeerTest()
    assert(not accepted and type(problem) == "string", "peer testing requires a connected group")
    world:connect(true); world:advance(4)
    assert(addon:StartRestedXPPeerTest())
    world:advance(16)
    local report = addon:GetRestedXPPerformance().peerTest
    assert(report and report.status == "failed" and #world.installs == 0,
        "empty discovery terminates with a failed peer report")

    local _, a, recipient, b, id = peerFixture()
    b.failInstall = true
    assert(recipient:StartRestedXPPeerTest("peeralpha-testrealm", id))
    report = finishPeerTest(recipient, a, b)
    assert(report.status == "failed" and #b.installs == 1
        and next(recipient.db.restedxp.groups[recipient.fingerprint].sources) == nil,
        "native import failure terminates the one-off test without a saved subscription")

    local _, lostA, lostRecipient, lostB, lostID = peerFixture()
    assert(lostRecipient:StartRestedXPPeerTest("peeralpha-testrealm", lostID))
    local lost = finishPeerTest(lostRecipient, lostA, lostB, function(wire) return not wire:match("^1|D|") end)
    assert(lost.status == "failed" and #lostB.installs == 0
        and next(lostRecipient.db.restedxp.groups[lostRecipient.fingerprint].sources) == nil,
        "a failed normal transfer leaves a terminal peer report and does not start native import")

    local _, c, cancelled, d, cancelledID = peerFixture()
    assert(cancelled:StartRestedXPPeerTest("peeralpha-testrealm", cancelledID))
    assert(cancelled:CancelRestedXPPeerTest())
    local traffic = #d.sent
    exchange(c, d, 5)
    assert(cancelled:GetRestedXPPerformance().peerTest.status == "cancelled" and #d.installs == 0 and #d.sent == traffic,
        "explicit cancellation removes pending discovery and prevents later native imports")

    local selected, selectionProblem = cancelled:StartRestedXPPeerTest("peeralpha-testrealm", "missing-pack")
    local missingPack = selected and finishPeerTest(cancelled, c, d)
    assert((missingPack and missingPack.status == "failed" or not selected and type(selectionProblem) == "string") and #d.installs == 0,
        "an explicit pack filter cannot silently choose a different advertised package")
    selected, selectionProblem = cancelled:StartRestedXPPeerTest("absent-testrealm", cancelledID)
    local missingSource = selected and finishPeerTest(cancelled, c, d)
    assert((missingSource and missingSource.status == "failed" or not selected and type(selectionProblem) == "string") and #d.installs == 0,
        "an explicit publisher filter cannot silently choose another online source")

    local _, importA, importRecipient, importB, importID = peerFixture()
    assert(importRecipient:StartRestedXPPeerTest("peeralpha-testrealm", importID))
    for _ = 1, 1000 do
        exchange(importA, importB, 0.15)
        if #importB.installs > 0 then break end
    end
    assert(#importB.installs == 1 and importRecipient:GetRestedXPPerformance().peerTest.status == "running")
    assert(importRecipient:CancelRestedXPPeerTest())
    exchange(importA, importB, 2)
    assert(importRecipient:GetRestedXPPerformance().peerTest.status == "cancelled" and importB.installTimer.cancelled,
        "cancelling the import phase stops the owned native installation and preserves the terminal report")

    assert(cancelled:StartRestedXPPeerTest("peeralpha-testrealm", cancelledID))
    d:connect(false)
    d:advance(5)
    report = cancelled:GetRestedXPPerformance().peerTest
    assert(report and report.status == "cancelled" and #d.installs == 0,
        "connection loss finalizes the peer test instead of leaving a running report")

    local readonly, readWorld = client("PeerReadOnly", { marker = true }, true, nil, true)
    readWorld:connect(true)
    accepted, problem = readonly:StartRestedXPPeerTest()
    assert(not accepted and type(problem) == "string" and readWorld.output and #readWorld.sent == 0,
        "read-only saved data cannot begin peer traffic or native test installation")
end

-- Production timing exercises only the same ID/version inventory used on login,
-- while preserving source caches and requiring no canonical exports at all.
do
    local addon, world = client("InventoryBenchmark", nil, nil, nil, true)
    world.inventory = {
        { id = "inventory-two", label = "Two Guides", revision = string.rep("d", 64), guideCount = 2 },
        { id = "inventory-three", label = "Three Guides", revision = string.rep("e", 64), guideCount = 3 },
    }
    assert(addon:StartRestedXPBenchmark())
    world:advance(1)
    local result = addon:GetRestedXPPerformance().benchmark
    assert(result and result.metadataOnly and result.cold.metadataOnly and result.warm.metadataOnly,
        "the production benchmark identifies both measured runs as metadata-only checks")
    assert(world.inventoryScans == 2 and world.inventoryResets == 1
        and not world.scans and not world.memoResets and #world.prepares == 0,
        "fresh and repeat metadata timing never invoke source collection, source-cache resets or export preparation")
    for _, run in ipairs({ result.cold, result.warm }) do
        assert(run.guides == 5 and run.packs == 2 and run.bytes == 0,
            "metadata timing sums native guide counts without measuring or preparing compressed source bytes")
    end
    assert(#world.sent == 0 and #world.installs == 0 and next(addon.db.restedxp.groups) == nil,
        "metadata benchmarks remain local without publishing source or changing native installation")
end

-- Legacy adapters without inventory APIs can still measure complete local
-- preparation without changing publications or calling the native importer.
do
    local addon, world, api = client("Benchmark", nil, nil, true)
    local pack = packFor(addon, api, 8)
    world.installedPacks = { { id = "benchmark-only", label = "Local Fixture", pack = pack } }
    world.scanYields = 17
    local group = addon.db.restedxp.groups
    assert(next(group) == nil)
    assert(addon:StartRestedXPBenchmark())
    local acceptedAgain, problem = addon:StartRestedXPBenchmark()
    assert(not acceptedAgain and type(problem) == "string", "a second benchmark cannot interrupt active local preparation")
    world:advance(4)
    local report = addon:GetRestedXPPerformance()
    assert(report.benchmark and report.benchmark.cold and report.benchmark.warm and world.memoResets == 1,
        "one local benchmark clears memoization for its cold scan and then measures a warm repeat")
    assert(report.benchmark.cold.guides == 1 and report.benchmark.cold.packs == 1
        and report.benchmark.cold.bytes == #pack.data and report.benchmark.warm.bytes == #pack.data,
        "benchmark output measures the locally recovered guide count and compressed source size")
    assert(report.benchmark.cold.metrics.decodedSources == 1 and report.benchmark.warm.metrics.cacheHits == 1,
        "cold and warm source metrics preserve their distinct recovery paths")
    for _, run in ipairs({ report.benchmark.cold, report.benchmark.warm }) do
        assert(run.wall >= 0 and run.cpu == nil and run.slices >= 1 and run.resumes >= 1,
            "local timings include cooperative work and omit unavailable high-resolution CPU measurements")
    end
    assert(#world.sent == 0 and #world.installs == 0 and next(group) == nil,
        "local benchmarking neither joins guide traffic nor creates published cache entries or native imports")
    report.tx.messages = 999
    report.benchmark.cold.metrics.decodedSources = 999
    local copied = addon:GetRestedXPPerformance()
    assert(copied.tx.messages == 0 and copied.benchmark.cold.metrics.decodedSources == 1,
        "performance snapshots cannot mutate internal traffic or nested benchmark metrics")
    local before = #world.output
    addon:ShowRestedXPPerformance()
    assert(#world.output > before and #world.sent == 0 and #world.installs == 0 and next(group) == nil,
        "printing passive diagnostics reports locally without initiating discovery or guide changes")
    for _, line in ipairs(world.output) do
        assert(not line:find(pack.data, 1, true), "diagnostics never print recovered guide contents")
    end
end

-- Benchmarking must not replace a real automatic scan already preparing guides.
do
    local addon, world = client("BusyBenchmark", nil, nil, true)
    world.scanYields = 10000
    world:connect(true)
    world:advance(0.2)
    local active = assert(addon.restedxpState.job)
    local accepted, problem = addon:StartRestedXPBenchmark()
    assert(not accepted and type(problem) == "string" and addon.restedxpState.job == active and not world.memoResets,
        "a rejected benchmark leaves the active automatic scan and its source memo intact")
    world:connect(false)
end

-- Native observers and pending collection work respect read-only, logout and
-- group boundaries, including callbacks already queued before cancellation.
do
    local addon, world, api = client("Lifecycle", nil, nil, true)
    world.installedPacks = { { id = "installed-lifecycle", label = "Lifecycle Pack", pack = packFor(addon, api, 1) } }
    world:connect(true)
    world:advance(4)
    local lateCallback = assert(world.installedChanged)
    world:connect(false)
    addon.fingerprint = nil
    addon:Notify("GROUP_CHANGED")
    lateCallback()
    local scans, sent = world.scans, #world.sent
    world:advance(5)
    assert(world.installedChanged == nil and world.scans == scans and #world.sent == sent
        and addon.db.restedxp.groups["test-group"] == nil,
        "group leave stops observation, ignores late callbacks and clears old automatic publications")
    addon.fingerprint = "new-group"
    addon:Notify("GROUP_CHANGED")
    world:connect(true)
    world:advance(4)
    assert(world.installedChanged and addon.db.restedxp.groups["new-group"].packs["installed-lifecycle"],
        "joining a new group recovers installed guides into only the new group")
    lateCallback = world.installedChanged
    assert(world.events.PLAYER_LOGOUT)(addon, "PLAYER_LOGOUT")
    lateCallback()
    scans, sent = world.scans, #world.sent
    world:advance(5)
    assert(world.installedChanged == nil and world.scans == scans and #world.sent == sent,
        "logout cancels source observation and pending callbacks without later traffic or scans")

    local untouched = { sentinel = true }
    local readonly, readWorld = client("ReadOnlyAuto", untouched, true, true)
    readWorld:connect(true)
    readWorld:advance(5)
    assert(untouched.sentinel and untouched.restedxp == nil and readWorld.installedChanged == nil
        and not readWorld.scans and #readWorld.sent == 0,
        "newer-schema profiles never scan, publish, observe or write automatic guide state")
end

print("PASS: RestedXP pack sharing, content updates, transfer recovery and lifecycle")
