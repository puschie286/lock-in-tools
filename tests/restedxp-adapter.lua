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
            metadata = { key = expected.key, name = expected.name, group = expected.group, subgroup = expected.subgroup, version = expected.version },
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

print("PASS: RestedXP detection, complete installed sources, automatic change watching and verified asynchronous imports")
