-- Synthetic native-importer contract checks; no guide content is downloaded.
local function loadModule(addon, environment)
    local chunk = assert(loadfile("RestedXPAdapter.lua"))
    setfenv(chunk, environment)
    chunk("LockInTools", addon)
end

local function newAddon()
    local world = { now = 0, installed = true, loaded = true, tag = "Player#1234", timers = {}, mode = "success" }
    local addon = { RestedXPCodec = {} }
    local rxp = { version = 40000, release = "4.9.0", game = "FOREVER", guides = {}, db = { profile = { guides = {} } } }
    local worker = { scripts = {} }
    function worker:GetScript(script) assert(script == "OnUpdate"); return self.scripts[script] end
    function worker:SetScript(script, callback) assert(script == "OnUpdate"); self.scripts[script] = callback end
    rxp.workerFrame = worker
    local importer = { gui = { progressError = false }, importBufferSize = 0, importReady = false }
    rxp.guideImporter = importer
    function importer:AbortImport()
        world.aborts = (world.aborts or 0) + 1
        self.importCoroutine, self.importBufferSize, self.importReady = nil, 0, false
        worker:SetScript("OnUpdate", nil)
    end
    local public = {}
    rxp.RXPGuides = public
    function public.ImportGuide(raw)
        assert(type(raw) == "string")
        if world.mode == "skip" then return end
        local expected = world.expected or { key = "Test||Guide", name = "Guide", group = "Test", version = 1 }
        local entry = {
            key = expected.key, version = expected.version,
            metadata = { key = expected.key, name = expected.name, group = expected.group, subgroup = expected.subgroup,
                version = expected.version, guideId = expected.guideId },
            groupOrContent = world.cachedImport and "native cached source" or nil,
        }
        rxp.db.profile.guides[expected.key .. "|new"] = entry
    end
    function importer.ProcessInputBuffer()
        world.step = world.step + 1
        if world.mode == "stuck" then return end
        if world.step == 1 then
            importer.importCoroutine = nil
            importer.importBufferSize = 1
        elseif world.step == 2 then
            if world.mode == "error" then
                importer:AbortImport()
                importer.gui.progressError = true
                return
            end
            if world.mode ~= "missing" then
                public.ImportGuide(world.rawGuide or "synthetic raw guide")
            end
        else
            worker:SetScript("OnUpdate", nil)
            importer.importBufferSize, importer.importReady = 0, false
        end
    end
    function importer:ImportString(text)
        assert(type(text) == "string" and text == "personalized export")
        world.imports = (world.imports or 0) + 1
        world.step = 0
        self.gui.progressError = false
        if world.mode == "reject" then return false, "bad package" end
        if world.mode == "throw" then error("bad package") end
        self.importCoroutine = coroutine.create(function() end)
        worker:SetScript("OnUpdate", importer.ProcessInputBuffer)
        return true
    end
    function addon.RestedXPCodec.Encode(pack, tag)
        assert(type(pack) == "table" and tag == world.tag)
        if world.encodeFailure then return nil, "bad canonical bytes" end
        return "personalized export"
    end
    function addon.RestedXPCodec.EncodeCached(pack, tag)
        world.cachedEncodes = (world.cachedEncodes or 0) + 1
        assert(pack.cacheFormat and tag == world.tag)
        if world.encodeFailure then return nil, "bad cached bytes" end
        return "personalized export"
    end
    local library = {}
    function library:GetAddon(name, silent)
        assert(name == "RXPGuides" and silent == true)
        return world.loaded and rxp or nil
    end
    local environment = setmetatable({
        C_AddOns = {
            GetAddOnMetadata = function(name, field)
                assert(name == "RXPGuides" and field == "Version")
                if world.metadataError then error("metadata unavailable") end
                return world.installed and rxp.release or nil
            end,
            IsAddOnLoaded = function(name) assert(name == "RXPGuides"); return world.loaded end,
        },
        LibStub = function(name, silent)
            assert(name == "AceAddon-3.0" and silent == true)
            return world.noAce and nil or library
        end,
        BNGetInfo = function() return 42, world.tag end,
        GetTime = function() return world.now end,
        InCombatLockdown = function() return world.combat == true end,
        hooksecurefunc = function(owner, method, callback)
            assert(owner == importer and method == "ImportString" or owner == public and method == "ImportGuide"
                or owner == rxp and (method == "CacheGuide" or method == "LoadCachedGuides"))
            world.hooks = (world.hooks or 0) + 1
            local original = owner[method]
            owner[method] = function(...)
                local function collect(...) return { n = select("#", ...), ... } end
                local result = collect(original(...))
                callback(...)
                return unpack(result, 1, result.n)
            end
        end,
        C_Timer = { NewTicker = function(delay, callback)
            assert(delay == 0.01 or delay == 0.5)
            local timer = { callback = callback }
            function timer:Cancel() self.cancelled = true end
            world.timers[#world.timers + 1] = timer
            return timer
        end },
    }, { __index = _G })
    environment._G = environment
    environment.RXPGuides = public
    world.environment, world.rxp, world.importer, world.worker = environment, rxp, importer, worker
    function world:Step(count)
        for _ = 1, count or 1 do
            self.now = self.now + 0.25
            local onUpdate = worker:GetScript("OnUpdate")
            if onUpdate then onUpdate(worker) end
            for _, timer in ipairs(self.timers) do if not timer.cancelled then timer.callback() end end
        end
    end
    local crypto = assert(loadfile("Crypto.lua"))
    setfenv(crypto, environment)
    crypto("LockInTools", addon)
    loadModule(addon, environment)
    return addon, world
end

local function useSourceCache(addon, world)
    local environment = world.environment
    local libraries = setmetatable({}, { __index = _G })
    for _, path in ipairs({ "Libs/LibStub/LibStub.lua", "Libs/LibDeflate/LibDeflate.lua" }) do
        local chunk = assert(loadfile(path))
        setfenv(chunk, libraries)
        chunk()
    end
    local nativeStub = environment.LibStub
    environment.LibStub = function(name, silent)
        if name == "LITLibDeflate" then return libraries.LibStub(name, silent) end
        return nativeStub(name, silent)
    end
    local codec = assert(loadfile("RestedXPCodec.lua"))
    setfenv(codec, environment)
    codec("LockInTools", addon)
    local deflate = libraries.LibStub("LITLibDeflate")
    world.deflate = deflate
    function world:Cache(raw, key)
        self.cacheSerial = (self.cacheSerial or 0) + 1
        local metadata = assert(addon.RestedXPCodec.SourceMetadata(raw))
        local storageKey = (key or metadata.key) .. "|" .. self.cacheSerial
        self.rxp.db.profile.guides[storageKey] = {
            key = key or metadata.key, version = metadata.version, metadata = metadata,
            groupOrContent = deflate:CompressDeflate("--123456\n" .. raw),
        }
        return storageKey
    end
    function world.rxp.CacheGuide(key, raw)
        world:Cache(raw, key)
    end
    function world.rxp.LoadCachedGuides() end
    return addon.RestedXPCodec
end

local function source(group, name, version, content, condition, game)
    return "#" .. (game or "classic") .. "\n#group " .. group .. "\n#name " .. name
        .. "\n#version " .. version .. "\n" .. (condition and "<< " .. condition .. "\n" or "")
        .. "step\n+" .. (content or "Fictional guide") .. "\n"
end

local function collectInstalled(addon)
    local thread = coroutine.create(function() return addon:CollectRestedXPInstalledPacks() end)
    local yields = 0
    while true do
        local okay, packs, info = coroutine.resume(thread)
        assert(okay, packs)
        if coroutine.status(thread) == "dead" then return packs, info, yields end
        yields = yields + 1
        assert(yields < 10000, "source collection did not finish")
    end
end

local function pack(guides)
    return { hash = "synthetic", format = 40000, data = "synthetic canonical bytes", guides = guides or {
        { key = "Test||Guide", name = "Guide", group = "Test", version = 1 },
    } }
end

local function cachedPack(addon, world, retain)
    local expected = world.expected or { key = "Test||Guide", name = "Guide", group = "Test", version = 1, guideId = 100 }
    world.expected = expected
    local cache = world.rxp.db.profile.guides
    cache.blueprint = { key = expected.key, version = expected.version, groupOrContent = "opaque native cache",
        metadata = { key = expected.key, name = expected.name, group = expected.group,
            subgroup = expected.subgroup, version = expected.version, guideId = expected.guideId } }
    local inventory = assert(addon:CollectRestedXPInstalledInventory())
    local item = assert(inventory[1])
    if not retain then cache.blueprint = nil end
    world.cachedImport = true
    return { cacheFormat = true, data = "opaque cached package", format = 40000, guideCount = 1,
        id = item.id, revision = item.revision, hash = item.revision }
end

do
    local addon, world = newAddon()
    local cached = cachedPack(addon, world)
    function addon.RestedXPCodec.Encode() error("cached imports must use cached conversion") end
    function addon.RestedXPCodec.SourceMetadata() error("cached imports must use native metadata") end
    local result, problem
    assert(addon:InstallRestedXPPack(cached, function(success, failure) result, problem = success, failure end))
    world:Step(4)
    assert(result == true and not problem and world.cachedEncodes == 1 and world.imports == 1 and world.hooks == 1,
        "cached packages without source metadata use native completion plus fresh ID/version confirmation")
end

do
    local addon, world = newAddon()
    local cached = cachedPack(addon, world)
    cached.expectedGuides = { { id = "100", version = 1 } }
    world.rxp.db.profile.guides.extra = { key = "Test||Extra", groupOrContent = "unrelated native source",
        metadata = { key = "Test||Extra", name = "Extra", group = "Test", version = 7, guideId = 200 } }
    function addon.RestedXPCodec.SourceMetadata() error("cached confirmation must not parse source") end
    assert(not addon:MatchesRestedXPCachedPack(cached))
    local result
    assert(addon:InstallRestedXPPack(cached, function(success) result = success end))
    world:Step(4)
    assert(result == true and addon:MatchesRestedXPCachedPack(cached),
        "the expected guide subset confirms installation while preserving additional guides in the same group")
    cached.expectedGuides[1].version = 2
    assert(not addon:MatchesRestedXPCachedPack(cached), "expected versions must match exactly")
    cached.expectedGuides = { { id = "missing", version = 1 } }
    assert(not addon:MatchesRestedXPCachedPack(cached), "a missing expected guide must not match a local superset")
    cached.expectedGuides = {}
    assert(not addon:MatchesRestedXPCachedPack(cached), "an empty metadata manifest cannot confirm installation")
    cached.expectedGuides = { { id = "100", version = "1" } }
    assert(not addon:MatchesRestedXPCachedPack(cached), "metadata manifest versions must be finite numbers")
    local imports = world.imports
    assert(not addon:InstallRestedXPPack(cached) and world.imports == imports,
        "invalid manifest metadata is refused before native import")
end

for _, expected in ipairs({ { id = "missing", version = 1 }, { id = "100", version = 2 } }) do
    local addon, world = newAddon()
    local cached = cachedPack(addon, world)
    cached.expectedGuides = { expected }
    local result, problem
    assert(addon:InstallRestedXPPack(cached, function(success, failure) result, problem = success, failure end))
    world:Step(4)
    assert(result == false and problem:find("expected guide IDs and versions", 1, true))
end

do
    local addon, world = newAddon()
    local cached = cachedPack(addon, world, true)
    cached.expectedGuides = { { id = "100", version = 1 } }
    world.expected = { key = "Test||Other", name = "Other", group = "Test", version = 1, guideId = 200 }
    local result, problem
    assert(addon:InstallRestedXPPack(cached, function(success, failure) result, problem = success, failure end))
    world:Step(4)
    assert(result == false and problem:find("for this group", 1, true),
        "a fresh write for an unrequested guide must not confirm the expected subset")
end

for _, mode in ipairs({ "missing", "skip", "error", "reject", "throw" }) do
    local addon, world = newAddon()
    local cached = cachedPack(addon, world)
    world.mode = mode
    local result, problem
    assert(addon:InstallRestedXPPack(cached, function(success, failure) result, problem = success, failure end))
    world:Step(4)
    assert(result == false and type(problem) == "string", "native rejection or absent fresh guides must fail cached installation")
end

do
    local addon, world = newAddon()
    local cached = cachedPack(addon, world)
    world.expected.version = 2
    local result, problem
    assert(addon:InstallRestedXPPack(cached, function(success, failure) result, problem = success, failure end))
    world:Step(4)
    assert(result == false and problem:find("expected guide IDs and versions", 1, true),
        "fresh native writes with different versions cannot confirm a cached package")
end

do
    local addon, world = newAddon()
    local cached = cachedPack(addon, world, true)
    world.expected = { key = "Other||Foreign", name = "Foreign", group = "Other", version = 1 }
    local result, problem
    assert(addon:InstallRestedXPPack(cached, function(success, failure) result, problem = success, failure end))
    world:Step(4)
    assert(result == false and problem:find("for this group", 1, true),
        "preexisting matching metadata plus an unrelated fresh cache write must not confirm installation")
end

do
    local addon, world = newAddon()
    local cached = cachedPack(addon, world)
    world.encodeFailure = true
    local result, problem
    assert(addon:InstallRestedXPPack(cached, function(success, failure) result, problem = success, failure end))
    world:Step()
    assert(result == false and problem == "bad cached bytes" and not world.imports and not world.aborts)
end

do
    local addon, world = newAddon()
    world.installed, world.loaded = false, false
    local status = addon:GetRestedXPInstallation()
    assert(not status.installed and not status.loaded and not status.compatible and #status.guides == 0)
    local accepted, _, reason = addon:InstallRestedXPPack(pack())
    assert(not accepted and reason == "unavailable")
    world.installed = true
    status = addon:GetRestedXPInstallation()
    assert(status.installed and not status.loaded and not status.compatible)
    world.loaded, world.metadataError = true, true
    status = addon:GetRestedXPInstallation()
    assert(status.installed and status.loaded and status.compatible and status.version == "4.9.0")
    world.rxp.version = 50000
    assert(not addon:GetRestedXPInstallation().compatible)
end

do
    local addon, world = newAddon()
    world.rxp.db.profile.guides["Group||Unknown|1"] = { key = "Group||Unknown", version = nil }
    world.rxp.db.profile.guides["Group||Chapter|2"] = { key = "Group||Chapter", version = 2 }
    world.rxp.guides["Group||Chapter"] = { key = "Group||Chapter", group = "Group", name = "Chapter", version = 3 }
    local status = addon:GetRestedXPInstallation()
    assert(#status.guides == 2 and status.guides[1].name == "Chapter" and status.guides[1].version == 3)
    assert(status.guides[2].name == "Unknown" and status.guides[2].version == 0)
    status.guides[1].version = 99
    assert(world.rxp.guides["Group||Chapter"].version == 3, "status must not expose mutable RestedXP metadata")
    assert(addon:GetRestedXPBattleTag() == "Player#1234")
    world.tag = nil
    assert(addon:GetRestedXPBattleTag() == nil)
    assert(not addon:InstallRestedXPPack(pack()))
end

do
    local addon, world = newAddon()
    world.combat = true
    local accepted, _, reason = addon:InstallRestedXPPack(pack())
    assert(not accepted and reason == "combat")
    world.combat = false
    world.importer.importReady = true
    accepted, _, reason = addon:InstallRestedXPPack(pack())
    assert(not accepted and reason == "busy")
    world.importer.importReady = false
    world.worker:SetScript("OnUpdate", function() end)
    assert(not addon:InstallRestedXPPack(pack()))
    world.worker:SetScript("OnUpdate", nil)
    world.encodeFailure = true
    local result, problem
    assert(addon:InstallRestedXPPack(pack(), function(success, failure) result, problem = success, failure end))
    world:Step()
    assert(result == false and problem == "bad canonical bytes" and not world.imports)
    assert(not addon:InstallRestedXPPack({ format = 50000, guides = pack().guides }))
end

do
    local addon, world = newAddon()
    local calls, outcome = 0
    assert(addon:InstallRestedXPPack(pack(), function(success) calls, outcome = calls + 1, success end))
    assert(not addon:InstallRestedXPPack(pack()), "simultaneous LIT imports must be refused")
    world:Step(3)
    assert(calls == 0, "guide presence before worker completion must not confirm installation")
    world:Step()
    assert(calls == 1 and outcome == true and world.timers[1].cancelled)
    world:Step(4)
    assert(calls == 1)
    assert(addon:InstallRestedXPPack(pack(), function(success) assert(success); calls = calls + 1 end))
    world:Step(4)
    assert(calls == 2 and world.hooks == 1, "repeated installs must reuse the observer")
end

for _, mode in ipairs({ "error", "missing" }) do
    local addon, world = newAddon()
    world.mode = mode
    world.rxp.db.profile.guides["Test||Guide|old"] = { key = "Test||Guide", version = 1 }
    local calls, outcome, problem = 0
    assert(addon:InstallRestedXPPack(pack(), function(success, failure) calls, outcome, problem = calls + 1, success, failure end))
    world:Step(4)
    assert(calls == 1 and outcome == false and type(problem) == "string", "old guide versions must not masquerade as successful import")
end

for _, mode in ipairs({ "reject", "throw" }) do
    local addon, world = newAddon()
    world.mode = mode
    local calls, result = 0
    assert(addon:InstallRestedXPPack(pack(), function(success) calls, result = calls + 1, success end))
    world:Step(3)
    assert(calls == 1 and result == false, "native rejection is reported after asynchronous preparation")
end

do
    local addon, world = newAddon()
    local expected = { key = "Test||Unknown", name = "Unknown", group = "Test", version = 0, classic = "" }
    world.expected = expected
    local result
    assert(addon:InstallRestedXPPack(pack({ expected, { key = "Retail||Other", name = "Other", group = "Retail", version = 20, retail = "" } }), function(success) result = success end))
    world:Step(4)
    assert(result == true, "version zero is supported and guides for another game are not expected locally")
end

do
    local addon, world = newAddon()
    world.expected = { key = "Test||01-06 Start", name = "01-06 Start", group = "Test", version = 2 }
    local result
    assert(addon:InstallRestedXPPack(pack({ { key = "Test||1-6 Start", name = "1-6 Start", group = "Test", version = 2 } }), function(success) result = success end))
    world:Step(4)
    assert(result == true, "native normalization of level-range names must be recognized")
end

do
    local addon, world = newAddon()
    local calls = 0
    assert(addon:InstallRestedXPPack(pack(), function() calls = calls + 1 end))
    assert(addon:CancelRestedXPInstallation())
    world:Step(5)
    assert(calls == 0 and not world.aborts and not addon:CancelRestedXPInstallation())
    assert(addon:InstallRestedXPPack(pack(), function() calls = calls + 1 end))
    world:Step(2)
    addon:CancelRestedXPInstallation()
    assert(world.aborts == 1, "cancellation also stops the owned guide-parsing phase")
end

do
    local addon, world = newAddon()
    local result, failure
    assert(addon:InstallRestedXPPack(pack(), function(success, problem) result, failure = success, problem end))
    world:Step()
    world.importer:ImportString("personalized export")
    world:Step()
    assert(result == false and failure:find("Another RestedXP import", 1, true))
    assert(not world.aborts and world.worker:GetScript("OnUpdate"), "a foreign import must never be aborted")
end

do
    local addon, world = newAddon()
    world.mode = "stuck"
    local result
    assert(addon:InstallRestedXPPack(pack(), function(success) result = success end))
    world:Step()
    world.now = 301
    world:Step()
    assert(result == false and world.aborts == 1)
end

do
    local addon, world = newAddon()
    local raw = "#group Alliance << Alliance\n#group Horde << Horde\n#name One << Alliance\n#name Two << Horde\n#version 5\nstep\n+Synthetic\n"
    world.rawGuide = raw
    world.expected = { key = "Horde|Conditional|Two", name = "Two", group = "Horde", subgroup = "Conditional", version = 5 }
    local expected = { key = "Alliance||One", name = "One", group = "Alliance", version = 0,
        contentHash = addon.Crypto.Hex(addon.Crypto.SHA256(raw)), classic = "" }
    local result
    assert(addon:InstallRestedXPPack(pack({ expected }), function(success) result = success end))
    world:Step(4)
    assert(result == true, "exact source content plus a fresh native cache write confirms conditional metadata")
end

do
    local addon, world = newAddon()
    local expected = pack().guides[1]
    expected.contentHash = addon.Crypto.Hex(addon.Crypto.SHA256("intended guide content"))
    world.rawGuide = "different guide content"
    local result
    assert(addon:InstallRestedXPPack(pack({ expected }), function(success) result = success end))
    world:Step(4)
    assert(result == false, "matching guide versions cannot replace exact source confirmation")
end

do
    local addon, world = newAddon()
    world.mode = "skip"
    local expected = pack().guides[1]
    expected.contentHash = addon.Crypto.Hex(addon.Crypto.SHA256("synthetic raw guide"))
    world.rxp.db.profile.guides["Test||Guide|old"] = { key = expected.key, version = 1 }
    local result
    assert(addon:InstallRestedXPPack(pack({ expected }), function(success) result = success end))
    world:Step(4)
    assert(result == false, "observing a skipped guide input must not confirm installation without a fresh cache write")
end

do
    local addon, world = newAddon()
    function addon.RestedXPCodec.Encode()
        coroutine.yield()
        coroutine.yield()
        return "personalized export"
    end
    local result
    assert(addon:InstallRestedXPPack(pack(), function(success) result = success end))
    world:Step(2)
    assert(not world.imports and result == nil, "personalization yields cooperatively before the native importer starts")
    world.combat = true
    world:Step(2)
    assert(not world.imports, "combat beginning during preparation must postpone native installation")
    world.combat = false
    world:Step(4)
    assert(world.imports == 1 and result == true)
end

do
    local addon, world = newAddon()
    local calls = 0
    assert(addon:InstallRestedXPPack(pack(), function() calls = calls + 1 end))
    world.importer:ImportString("personalized export")
    world:Step()
    assert(world.imports == 1, "a user import starting during preparation must not be replaced")
    assert(addon:CancelRestedXPInstallation())
    assert(not world.aborts and world.worker:GetScript("OnUpdate"), "canceling preparation must preserve an unrelated native import")
    world:Step(3)
    assert(calls == 0 and world.imports == 1)
end

do
    local addon, world = newAddon()
    function addon.RestedXPCodec.Encode() coroutine.yield(); error("synthetic preparation failure") end
    local result
    assert(addon:InstallRestedXPPack(pack(), function(success) result = success end))
    world:Step(2)
    assert(result == false and not world.imports and not world.aborts)
end

do
    local addon, world = newAddon()
    local codec = useSourceCache(addon, world)
    local old = source("Test", "Chapter", 1, "Old")
    local current = source("Test", "Chapter", 2, "Current")
    local variant = source("Test", "Chapter", 2, "Class-specific", "Druid")
    local other = source("Other", "Next", 0)
    world:Cache(old)
    world:Cache(current)
    world:Cache(current)
    world:Cache(variant)
    world:Cache(other)
    local packs, info, yields = collectInstalled(addon)
    assert(info.complete and info.skipped == 0 and #packs == 2 and yields > 0)
    assert(packs[1].label == "Other" and packs[2].label == "Test")
    assert(packs[2].id:match("^rxpi%-%x+$") and #packs[2].id <= 40)
    assert(packs[2].pack.guideCount == 2, "newest complete sources retain class variants and deduplicate repeated cache entries")
    assert(packs[2].pack.hash == assert(codec.FromSources({ current, variant })).hash)
    local reversed = {}
    for key, value in pairs(world.rxp.db.profile.guides) do reversed[key] = value end
    world.rxp.db.profile.guides = reversed
    local repeated = assert(collectInstalled(addon))
    assert(repeated[2].id == packs[2].id and repeated[2].pack.hash == packs[2].pack.hash)
    assert(addon:MatchesRestedXPInstalledPack(packs[2].pack))
    assert(not addon:MatchesRestedXPInstalledPack(assert(codec.FromSources({ source("Test", "Chapter", 2, "Different") }))),
        "equal versions cannot establish that externally imported source content matches")
    assert(addon:MatchesRestedXPInstalledPack(assert(codec.FromSources({ current, source("Retail", "Elsewhere", 4, nil, nil, "retail") }))),
        "only guides for the local game need to be present")
    world.rxp.db.profile.guides["Metadata||Only|9"] = { key = "Metadata||Only", version = 1 }
    packs, info = collectInstalled(addon)
    assert(#packs == 2 and not info.complete and info.skipped == 1 and info.problem)
    world.importer.importReady = true
    packs, info = collectInstalled(addon)
    assert(not packs and info.busy and not info.complete)
end

do
    local addon, world = newAddon()
    local codec = useSourceCache(addon, world)
    local old = source("Test", "Chapter", 2, "Old content at the same version")
    local current = source("Test", "Chapter", 2, "Updated content at the same version")
    world:Cache(old)
    world:Cache(current)
    local packs, info = collectInstalled(addon)
    assert(#packs == 0 and not info.complete and info.skipped == 1 and info.problem:find("Conflicting", 1, true),
        "an ambiguous retained cache must not publish a stale equal-version source")
    local callbacks = 0
    assert(addon:WatchRestedXPInstalledGuides(function() callbacks = callbacks + 1 end))
    world:Step(3)
    assert(callbacks == 1, "watching requests one initial scan after RestedXP is ready")
    world.rxp.CacheGuide("Test||Chapter", current)
    world:Step(2)
    assert(callbacks == 2)
    packs, info = collectInstalled(addon)
    assert(info.complete and #packs == 1 and packs[1].pack.hash == assert(codec.FromSources({ current })).hash,
        "an observed native overwrite resolves equal-version source ambiguity")
    world.importer.importReady = true
    world.rxp.CacheGuide("Test||Chapter", source("Test", "Chapter", 3, "Third"))
    world.rxp.CacheGuide("Other||Next", source("Other", "Next", 1))
    world:Step(8)
    assert(callbacks == 2, "native imports are never scanned while the importer is busy")
    world.importer.importReady = false
    world:Step()
    assert(callbacks == 3, "multiple cache writes coalesce into one completed-import notification")
    world:Step(24)
    assert(callbacks == 3, "unchanged native storage must not cause repeated scans")
    world.rxp.db.profile.guides = {}
    world:Cache(source("New profile", "Only", 1))
    world:Step(24)
    assert(callbacks == 4, "the fallback detects profile switches and unhooked cache changes")
    assert(addon:StopWatchingRestedXPInstalledGuides())
    world.rxp.CacheGuide("Stopped||Later", source("Stopped", "Later", 1))
    world:Step(24)
    assert(callbacks == 4 and not addon:StopWatchingRestedXPInstalledGuides())
end

do
    local addon, world = newAddon()
    useSourceCache(addon, world)
    world:Cache(source("Test", "Chapter", 1))
    local thread = coroutine.create(function() return addon:CollectRestedXPInstalledPacks() end)
    assert(coroutine.resume(thread))
    assert(coroutine.status(thread) ~= "dead")
    world.rxp.db.profile.guides = {}
    local packs, info
    repeat
        local okay
        okay, packs, info = coroutine.resume(thread)
        assert(okay, packs)
    until coroutine.status(thread) == "dead"
    assert(not packs and info.busy, "a profile change during cooperative collection invalidates the entire snapshot")
end

do
    local addon, world = newAddon()
    local codec = useSourceCache(addon, world)
    world:Cache(source("First", "Chapter", 2, "First original"))
    world:Cache(source("Second", "Chapter", 2, "Second original"))
    local calls = { decode = 0, metadata = 0, pack = 0 }
    local decode, metadata, fromSources = codec.DecodeCachedSource, codec.SourceMetadata, codec.FromSources
    function codec.DecodeCachedSource(...)
        calls.decode = calls.decode + 1
        return decode(...)
    end
    function codec.SourceMetadata(...)
        calls.metadata = calls.metadata + 1
        return metadata(...)
    end
    function codec.FromSources(...)
        calls.pack = calls.pack + 1
        return fromSources(...)
    end
    local notifications = 0
    assert(addon:WatchRestedXPInstalledGuides(function() notifications = notifications + 1 end))
    local first, firstInfo = collectInstalled(addon)
    assert(first and firstInfo.metrics.decodedSources == 2 and firstInfo.metrics.cacheHits == 0
        and firstInfo.metrics.groupsBuilt == 2 and firstInfo.metrics.groupsReused == 0)
    assert(calls.decode == 2 and calls.metadata == 2 and calls.pack == 2)
    assert(addon:AcknowledgeRestedXPInstalledGuides())
    world:Step(24)
    assert(notifications == 0, "acknowledging the explicit login scan suppresses the duplicate initial watcher scan")
    local repeated, repeatedInfo = collectInstalled(addon)
    assert(repeated and repeatedInfo.metrics.decodedSources == 0 and repeatedInfo.metrics.cacheHits == 2
        and repeatedInfo.metrics.groupsBuilt == 0 and repeatedInfo.metrics.groupsReused == 2)
    assert(repeated[1].pack == first[1].pack and repeated[2].pack == first[2].pack)
    assert(addon:MatchesRestedXPInstalledPack(first[1].pack))
    assert(calls.decode == 2 and calls.metadata == 2 and calls.pack == 2,
        "unchanged rescans and installed-content checks reuse recovery, metadata and prepared packs")
    world.rxp.CacheGuide("First||Chapter", source("First", "Chapter", 2, "First replaced at same version"))
    local metadataBefore = calls.metadata
    assert(not addon:AcknowledgeRestedXPInstalledGuides(), "a scan acknowledgement must not clear a newer native change")
    local updated = assert(collectInstalled(addon))
    assert(updated[1].id == first[1].id and updated[1].pack.hash ~= first[1].pack.hash)
    assert(updated[2].pack == first[2].pack and calls.decode == 3 and calls.pack == 3)
    assert(calls.metadata == metadataBefore + 1, "a changed source is parsed once while the unchanged group is not recompressed")
    assert(addon:AcknowledgeRestedXPInstalledGuides())
    world:Step(24)
    assert(notifications == 0)
    world.importer.importReady = true
    assert(not collectInstalled(addon))
    assert(not addon:AcknowledgeRestedXPInstalledGuides(), "a busy native snapshot cannot be acknowledged")
    world.importer.importReady = false
    assert(collectInstalled(addon))
    assert(calls.decode == 3 and calls.pack == 3, "immutable recovery and group work remain reusable after native busy state")
    world.rxp.db.profile = { guides = {} }
    world:Cache(source("Second", "Chapter", 2, "Second original"))
    local before = calls.decode
    local switched = assert(collectInstalled(addon))
    assert(#switched == 1 and switched[1].label == "Second" and calls.decode == before + 1,
        "changing profiles discards the old profile's recovered source memo")
    assert(addon:AcknowledgeRestedXPInstalledGuides())
    world:Step(24)
    assert(notifications == 0, "an acknowledged profile scan also updates the watcher's profile baseline")
end

do
    local addon, world = newAddon()
    local codec = useSourceCache(addon, world)
    world:Cache(source("Reset test", "Chapter", 4, "Old same-version source"))
    local nativeProfile, nativeCache = world.rxp.db.profile, world.rxp.db.profile.guides
    assert(addon:WatchRestedXPInstalledGuides(function() error("unexpected watcher reset") end))
    local current = source("Reset test", "Chapter", 4, "Observed current source")
    world.rxp.CacheGuide("Reset test||Chapter", current)
    local first, firstInfo = collectInstalled(addon)
    assert(first and firstInfo.complete and #first == 1 and firstInfo.metrics.decodedSources == 2)
    assert(first[1].pack.hash == assert(codec.FromSources({ current })).hash)
    local hooks = world.hooks
    local entries = {}
    for key, entry in pairs(nativeCache) do entries[key] = entry end
    assert(addon:ResetRestedXPSourceMemo())
    assert(world.rxp.db.profile == nativeProfile and world.rxp.db.profile.guides == nativeCache and world.hooks == hooks)
    for key, entry in pairs(entries) do assert(nativeCache[key] == entry) end
    assert(not world.imports and not addon:AcknowledgeRestedXPInstalledGuides(), "resetting preparation must not import or acknowledge native data")
    local cold, coldInfo = collectInstalled(addon)
    assert(cold and coldInfo.complete and cold[1].pack.hash == first[1].pack.hash,
        "reset preserves the observed equal-version overwrite authority")
    assert(cold[1].pack ~= first[1].pack and coldInfo.metrics.decodedSources == 2
        and coldInfo.metrics.groupsBuilt == 1 and coldInfo.metrics.groupsReused == 0)
    local warm, warmInfo = collectInstalled(addon)
    assert(warm and warm[1].pack == cold[1].pack and warmInfo.metrics.decodedSources == 0
        and warmInfo.metrics.groupsBuilt == 0 and warmInfo.metrics.groupsReused == 1)
    warmInfo.metrics.decodedSources = 999
    local _, cleanInfo = collectInstalled(addon)
    assert(cleanInfo.metrics.decodedSources == 0, "returned metrics are separate for each preparation run")
    assert(addon:AcknowledgeRestedXPInstalledGuides())
    world:Step(24)
end

do
    local addon, world = newAddon()
    local codec = useSourceCache(addon, world)
    local oldKey = world:Cache(source("First inventory", "Chapter", 1, "Old"))
    local firstKey = world:Cache(source("First inventory", "Chapter", 2, "Current"))
    local variantKey = world:Cache(source("First inventory", "Class variant", 2, "Variant", "Druid"))
    local secondKey = world:Cache(source("Second inventory", "Other", 7))
    for _, key in ipairs({ oldKey, firstKey, variantKey }) do world.rxp.db.profile.guides[key].metadata.guideId = 100 end
    world.rxp.db.profile.guides.duplicate = world.rxp.db.profile.guides[firstKey]
    local function run(callback)
        local thread = coroutine.create(callback)
        repeat
            local okay, result, info = coroutine.resume(thread)
            assert(okay, result)
            if coroutine.status(thread) == "dead" then return result, info end
        until false
    end
    local storedSource = world.rxp.db.profile.guides[firstKey].groupOrContent
    local calls = { decode = 0, metadata = 0, pack = 0, bundle = 0 }
    for _, name in ipairs({ "DecodeCachedSource", "SourceMetadata", "FromSources", "SourceHash", "NormalizeSource", "Encode", "EncodeCached" }) do
        codec[name] = function() error("publisher attempted content processing: " .. name) end
    end
    for name, callback in pairs(world.deflate) do
        if type(callback) == "function" and (name:find("Compress") or name:find("Decompress") or name == "Adler32") then
            world.deflate[name] = function() error("publisher attempted guide compression or validation") end
        end
    end
    local fromCached = assert(codec.FromCachedSources)
    function codec.FromCachedSources(...)
        calls.bundle = calls.bundle + 1
        return fromCached(...)
    end
    local opaque = "Opaque compressed source must not be hashed"
    world.rxp.db.profile.guides[firstKey].groupOrContent = opaque
    local sha = addon.Crypto.SHA256
    function addon.Crypto.SHA256(message, ...)
        assert(not message:find(opaque, 1, true), "inventory must never hash native source bytes")
        return sha(message, ...)
    end
    local inventory, info = run(function() return addon:CollectRestedXPInstalledInventory() end)
    assert(info.complete and #inventory == 2 and inventory[1].guideCount == 1 and inventory[2].guideCount == 1)
    assert(calls.decode == 0 and calls.metadata == 0 and calls.pack == 0,
        "startup inventory uses native identity/version metadata without opening guide sources")
    local first = inventory[1]
    assert(#first.revision == 64 and first.id:match("^rxpi%-%x+$"))
    world.rxp.db.profile.guides[firstKey].groupOrContent = storedSource
    world.rxp.db.profile.guides[firstKey].metadata.key = "First inventory||Renamed display"
    inventory = assert(run(function() return addon:CollectRestedXPInstalledInventory() end))
    assert(inventory[1].revision == first.revision, "native guideId is stable when character-specific display keys change")
    local prepared = assert(run(function() return addon:PrepareRestedXPInstalledPack(first.id, first.revision) end))
    assert(calls.decode == 0 and calls.pack == 0 and calls.bundle == 1 and prepared.guideCount == 2
        and prepared.cacheFormat and prepared.hash == first.revision and prepared.revision == first.revision and prepared.id == first.id,
        "requested preparation deduplicates identical cache strings while retaining distinct conditional variants")
    assert(#prepared.expectedGuides == 1 and prepared.expectedGuides[1].id == "100"
        and prepared.expectedGuides[1].version == 2 and addon:MatchesRestedXPCachedPack(prepared),
        "publishers carry deduplicated ID/version metadata without source processing")
    local sourceHash = prepared.hash
    world.rxp.db.profile.guides[firstKey].groupOrContent = opaque
    local unchanged = assert(run(function() return addon:CollectRestedXPInstalledInventory() end))
    assert(unchanged[1].revision == first.revision)
    local repeated = assert(run(function() return addon:PrepareRestedXPInstalledPack(first.id, first.revision) end))
    assert(repeated == prepared and calls.decode == 0 and calls.pack == 0 and calls.bundle == 1,
        "unchanged native guide ids and versions deliberately reuse preparation despite changed source bytes")
    local metadataCalls, nativeCache = calls.metadata, world.rxp.db.profile.guides
    assert(addon:ResetRestedXPInventoryMemo())
    local fresh = assert(run(function() return addon:CollectRestedXPInstalledInventory() end))
    local stillPrepared = assert(run(function() return addon:PrepareRestedXPInstalledPack(first.id, first.revision) end))
    assert(fresh[1].revision == first.revision and stillPrepared == prepared and world.rxp.db.profile.guides == nativeCache
        and calls.decode == 0 and calls.metadata == metadataCalls and calls.pack == 0 and calls.bundle == 1,
        "resetting the inventory memo rereads metadata without clearing prepared sources or changing native guides")
    world.rxp.db.profile.guides[firstKey].metadata.version = 3
    local changed = assert(run(function() return addon:CollectRestedXPInstalledInventory() end))
    assert(changed[1].id == first.id and changed[1].revision ~= first.revision)
    local rejected, problem = run(function() return addon:PrepareRestedXPInstalledPack(first.id, first.revision) end)
    assert(not rejected and problem:find("versions changed", 1, true))
    local updated = assert(run(function() return addon:PrepareRestedXPInstalledPack(changed[1].id, changed[1].revision) end))
    assert(updated.hash ~= sourceHash and calls.decode == 0 and calls.pack == 0 and calls.bundle == 2
        and updated.cachedSources[1] == opaque,
        "an opaque invalid compressed source remains shareable without publisher-side content validation")
    world.rxp.db.profile.guides[secondKey].metadata.version = 8
    local secondChanged = assert(run(function() return addon:CollectRestedXPInstalledInventory() end))
    assert(secondChanged[1].revision == changed[1].revision and secondChanged[2].revision ~= changed[2].revision,
        "guides without native guideId use their metadata key and version")
    world.rxp.db.profile.guides[secondKey].metadata.guideId = 200
    local identityChanged = assert(run(function() return addon:CollectRestedXPInstalledInventory() end))
    assert(identityChanged[2].revision ~= secondChanged[2].revision, "a changed native guide id changes the inventory revision")
    world.importer.importReady = true
    inventory, info = run(function() return addon:CollectRestedXPInstalledInventory() end)
    assert(not inventory and info.busy)
end

print("PASS: RestedXP metadata inventory, on-demand preparation, memoized sharing and verified asynchronous imports")
