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
            assert(owner == importer and method == "ImportString" or owner == public and method == "ImportGuide")
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
            assert(delay == 0.25)
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
    local success, problem = addon:InstallRestedXPPack(pack())
    assert(not success and problem == "bad canonical bytes" and not world.imports)
    assert(not addon:InstallRestedXPPack({ format = 50000, guides = pack().guides }))
end

do
    local addon, world = newAddon()
    local calls, outcome = 0
    assert(addon:InstallRestedXPPack(pack(), function(success) calls, outcome = calls + 1, success end))
    assert(not addon:InstallRestedXPPack(pack()), "simultaneous LIT imports must be refused")
    world:Step(2)
    assert(calls == 0, "guide presence before worker completion must not confirm installation")
    world:Step()
    assert(calls == 1 and outcome == true and world.timers[1].cancelled)
    world:Step(3)
    assert(calls == 1)
    assert(addon:InstallRestedXPPack(pack(), function(success) assert(success); calls = calls + 1 end))
    world:Step(3)
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
    local calls = 0
    assert(not addon:InstallRestedXPPack(pack(), function() calls = calls + 1 end))
    world:Step(3)
    assert(calls == 0, "synchronous rejection returns an error without also invoking the completion callback")
end

do
    local addon, world = newAddon()
    local expected = { key = "Test||Unknown", name = "Unknown", group = "Test", version = 0, classic = "" }
    world.expected = expected
    local result
    assert(addon:InstallRestedXPPack(pack({ expected, { key = "Retail||Other", name = "Other", group = "Retail", version = 20, retail = "" } }), function(success) result = success end))
    world:Step(3)
    assert(result == true, "version zero is supported and guides for another game are not expected locally")
end

do
    local addon, world = newAddon()
    world.expected = { key = "Test||01-06 Start", name = "01-06 Start", group = "Test", version = 2 }
    local result
    assert(addon:InstallRestedXPPack(pack({ { key = "Test||1-6 Start", name = "1-6 Start", group = "Test", version = 2 } }), function(success) result = success end))
    world:Step(3)
    assert(result == true, "native normalization of level-range names must be recognized")
end

do
    local addon, world = newAddon()
    local calls = 0
    assert(addon:InstallRestedXPPack(pack(), function() calls = calls + 1 end))
    assert(addon:CancelRestedXPInstallation())
    world:Step(5)
    assert(calls == 0 and world.aborts == 1 and not addon:CancelRestedXPInstallation())
    assert(addon:InstallRestedXPPack(pack(), function() calls = calls + 1 end))
    world:Step()
    addon:CancelRestedXPInstallation()
    assert(world.aborts == 2, "cancellation also stops the owned guide-parsing phase")
end

do
    local addon, world = newAddon()
    local result, failure
    assert(addon:InstallRestedXPPack(pack(), function(success, problem) result, failure = success, problem end))
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
    world:Step(3)
    assert(result == true, "exact source content plus a fresh native cache write confirms conditional metadata")
end

do
    local addon, world = newAddon()
    local expected = pack().guides[1]
    expected.contentHash = addon.Crypto.Hex(addon.Crypto.SHA256("intended guide content"))
    world.rawGuide = "different guide content"
    local result
    assert(addon:InstallRestedXPPack(pack({ expected }), function(success) result = success end))
    world:Step(3)
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
    world:Step(3)
    assert(result == false, "observing a skipped guide input must not confirm installation without a fresh cache write")
end

print("PASS: RestedXP installation detection, guide versions, local identity and verified asynchronous imports")
