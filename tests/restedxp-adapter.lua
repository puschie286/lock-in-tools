-- Forwarding leaves validation and import lifecycle entirely with RestedXP.
local function newAddon()
    local world = { installed = true, loaded = true, tag = "Player#1234", calls = 0, accepted = true }
    local addon = {}
    local importer = {}
    local rxp = { version = 40000, release = "4.9.0", guideImporter = importer }
    function importer:ImportString(raw)
        assert(self == importer, "native import retains its method receiver")
        world.calls, world.raw = world.calls + 1, raw
        if world.throw then error("native failure: " .. raw) end
        if world.onImport then world.onImport(self) end
        return world.accepted
    end
    local library = {}
    function library:GetAddon(name, silent)
        assert(name == "RXPGuides" and silent == true)
        if world.lookupError then error("native addon lookup unavailable") end
        return world.loaded and rxp or nil
    end
    local env = setmetatable({
        C_AddOns = {
            GetAddOnMetadata = function(name, field)
                assert(name == "RXPGuides" and field == "Version")
                if world.metadataError then error("native metadata unavailable") end
                return world.installed and rxp.release or nil
            end,
            IsAddOnLoaded = function(name) assert(name == "RXPGuides"); return world.loaded end,
        },
        LibStub = function(name, silent)
            assert(name == "AceAddon-3.0" and silent == true)
            if world.aceError then error("AceAddon unavailable") end
            return not world.noAce and library or nil
        end,
        BNGetInfo = function()
            if world.tagError then error("Battle.net unavailable") end
            return 42, world.tag
        end,
        InCombatLockdown = function() return world.combat == true end,
        hooksecurefunc = function() error("local forwarding must not attach native hooks") end,
        C_Timer = {
            NewTimer = function() error("local forwarding must not schedule work") end,
            NewTicker = function() error("local forwarding must not monitor native imports") end,
        },
    }, { __index = _G })
    env._G = env
    local chunk = assert(loadfile("RestedXPAdapter.lua"))
    setfenv(chunk, env)
    chunk("LockInTools", addon)
    return addon, world, rxp, importer, env
end

local function enableTracking(world, rxp, importer, env)
    world.timers, world.events, world.hooks = {}, {}, 0
    rxp.locale = { Get = function(text) return (world.language or "") .. text end }
    importer.gui = { importStatusHistory = { rxp.locale.Get("Guides Loaded Successfully") } }
    function importer:UpdateImportStatusHistory(data, isError)
        self.gui.progressError = isError == true
        world.statusCalls = (world.statusCalls or 0) + 1
    end
    function importer:AbortImport()
        world.aborts = (world.aborts or 0) + 1
        self.importCoroutine, self.importBufferSize, self.importReady = nil, 0, false
    end
    function env.hooksecurefunc(owner, method, callback)
        world.hooks = world.hooks + 1
        local original = assert(owner[method])
        owner[method] = function(...)
            local function packed(...) return { n = select("#", ...), ... } end
            local result = packed(original(...))
            callback(...)
            return unpack(result, 1, result.n)
        end
    end
    function env.C_Timer.NewTimer(delay, callback)
        assert(delay == 0, "native observation uses only next-tick coalescing")
        local timer = { callback = callback }
        function timer:Cancel() self.cancelled = true end
        world.timers[#world.timers + 1] = timer
        return timer
    end
    function world:tick()
        local timers = self.timers
        self.timers = {}
        for _, timer in ipairs(timers) do if not timer.cancelled then timer.callback() end end
    end
    function world:callback(phase, current, total, message)
        self.events[#self.events + 1] = { phase = phase, current = current, total = total, message = message }
    end
    return function(...) world:callback(...) end
end

do
    local addon, world, rxp, _, env = newAddon()
    local status = addon:GetRestedXPInstallation()
    assert(status.installed and status.loaded and status.compatible and not status.problem)
    assert(status.guides == nil, "installation status never scans native guides")
    world.loaded = false
    status = addon:GetRestedXPInstallation()
    assert(status.installed and not status.loaded and not status.compatible and status.problem:find("Enable", 1, true))
    local accepted = addon:ForwardRestedXPImport("export")
    assert(not accepted and world.calls == 0)
    world.installed = false
    status = addon:GetRestedXPInstallation()
    assert(not status.installed and status.problem:find("Install", 1, true))
    world.loaded, world.installed, world.noAce = true, true, true
    status = addon:GetRestedXPInstallation()
    assert(status.installed and status.loaded and not status.compatible)
    world.noAce, world.aceError = false, true
    assert(not addon:GetRestedXPInstallation().compatible)
    world.aceError, world.lookupError = false, true
    assert(not addon:GetRestedXPInstallation().compatible)
    world.lookupError, world.metadataError = false, true
    assert(addon:GetRestedXPInstallation().compatible, "the actual loaded importer remains authoritative if metadata lookup fails")
    env.GetAddOnMetadata, env.IsAddOnLoaded = env.C_AddOns.GetAddOnMetadata, env.C_AddOns.IsAddOnLoaded
    env.C_AddOns = nil
    assert(addon:GetRestedXPInstallation().compatible, "legacy addon metadata APIs remain supported")
end

do
    local addon, world, rxp, importer = newAddon()
    rxp.version = 39999
    local accepted, problem = addon:ForwardRestedXPImport("export")
    assert(not accepted and problem:find("unavailable", 1, true) and world.calls == 0)
    rxp.version, importer.ImportString = 40000, nil
    assert(not addon:GetRestedXPInstallation().compatible)
    assert(not addon:ForwardRestedXPImport("export") and world.calls == 0)
    rxp.guideImporter = nil
    assert(not addon:ForwardRestedXPImport("export") and world.calls == 0)
end

do
    local addon, world = newAddon()
    assert(addon:GetRestedXPBattleTag() == world.tag)
    for _, invalid in ipairs({ "", "Player", "Player#abc" }) do
        world.tag = invalid
        local tag, problem = addon:GetRestedXPBattleTag()
        assert(tag == nil and problem:find("Battle.net", 1, true))
    end
    world.tag, world.tagError = "Player#1234", true
    assert(addon:GetRestedXPBattleTag() == nil)
end

do
    local addon, world, rxp, importer = newAddon()
    local native = coroutine.create(function() end)
    local cache = { retained = {} }
    rxp.db = { profile = { guides = cache } }
    world.combat = true
    assert(not addon:ForwardRestedXPImport("export") and world.calls == 0)
    world.combat = false
    for key, value in pairs({ importCoroutine = native, importBufferSize = 1, importReady = true, cachedState = {} }) do
        importer[key] = value
        local accepted, problem = addon:ForwardRestedXPImport("export")
        assert(not accepted and problem:find("Wait", 1, true) and importer[key] == value and world.calls == 0,
            "an active native import is neither replaced nor modified")
        importer[key] = nil
    end
    local onUpdate = function() end
    rxp.workerFrame = { GetScript = function(_, script) assert(script == "OnUpdate"); return onUpdate end }
    assert(not addon:ForwardRestedXPImport("export") and world.calls == 0)
    assert(rxp.db.profile.guides == cache and cache.retained, "busy checks leave native guide storage untouched")
    rxp.workerFrame = nil
    local raw = "native export bytes\nleft unchanged"
    assert(addon:ForwardRestedXPImport(raw) and world.calls == 1 and world.raw == raw)
end

do
    local addon, world = newAddon()
    assert(not addon:ForwardRestedXPImport(nil) and not addon:ForwardRestedXPImport(123)
        and not addon:ForwardRestedXPImport("") and world.calls == 0)
    world.throw = true
    local raw = "private export bytes"
    local accepted, problem = addon:ForwardRestedXPImport(raw)
    assert(not accepted and world.calls == 1 and not problem:find(raw, 1, true), "native exceptions do not expose exports")
    world.throw, world.accepted = false, false
    assert(not addon:ForwardRestedXPImport(raw) and world.calls == 2)
    world.accepted = nil
    assert(not addon:ForwardRestedXPImport(raw) and world.calls == 3, "only an explicit native true means acceptance")
end

do
    local addon, world, rxp, importer = newAddon()
    local untouched = { retained = {} }
    local native = coroutine.create(function() end)
    rxp.db = { profile = { guides = untouched } }
    local importString = importer.ImportString
    world.onImport = function(owner) owner.importCoroutine = native end
    assert(addon:ForwardRestedXPImport("native decides whether these bytes are valid"))
    assert(world.calls == 1 and importer.ImportString == importString and importer.importCoroutine == native,
        "acceptance leaves native validation and asynchronous work in control")
    assert(rxp.db.profile.guides == untouched and untouched.retained,
        "forwarding never mutates, reconstructs or replaces native guide storage")
    assert(addon.WatchRestedXPInstalledGuides == nil and addon.CollectRestedXPInstalledInventory == nil
        and addon.InstallRestedXPPack == nil, "the local adapter retains no sharing or monitored-install APIs")
end

do
    local addon, world, rxp = newAddon()
    assert(addon:GetRestedXPInstallation().compatible)
    world.loaded = false
    assert(not addon:ForwardRestedXPImport("converted export") and world.calls == 0,
        "forwarding rechecks an addon unloaded after conversion started")
    world.loaded, rxp.version = true, 50000
    assert(not addon:ForwardRestedXPImport("converted export") and world.calls == 0,
        "forwarding rechecks a format changed after conversion started")
    rxp.version, world.combat = 40000, true
    assert(not addon:ForwardRestedXPImport("converted export") and world.calls == 0,
        "forwarding rechecks combat after conversion started")
end

do
    local addon, world, rxp, importer, env = newAddon()
    local callback = enableTracking(world, rxp, importer, env)
    world.language = "Localized: "
    world.onImport = function(owner) owner:UpdateImportStatusHistory("Loading (%d/%d)", false, 0, 3) end
    local accepted, problem, monitored = addon:ForwardRestedXPImport("export", callback)
    assert(accepted and not problem and monitored and #world.events == 0 and world.hooks == 3,
        "accepted imports arm native observation without dispatching unconfirmed synchronous status")
    world:tick()
    assert(#world.events == 1 and world.events[1].phase == "importing" and world.events[1].current == 0
        and world.events[1].total == 3, "an old history success is not completion for the current import")
    importer:UpdateImportStatusHistory("Loading (%d/%d)", false, 1, 3)
    importer:UpdateImportStatusHistory("Loading (%d/%d)", false, 1, 3)
    world:tick()
    assert(#world.events == 2 and world.events[2].current == 1, "repeated native progress is coalesced")
    importer:UpdateImportStatusHistory("Loading (%d/%d)", false, 1, 3)
    world:tick()
    assert(#world.events == 2, "unchanged progress does not render again on later ticks")
    importer:UpdateImportStatusHistory("Loading (%d/%d)", false, 3, 3)
    world:tick()
    assert(world.events[3].phase == "importing", "the final guide count is not a completion signal")
    importer:UpdateImportStatusHistory(rxp.locale.Get("Guides Loaded Successfully"), false)
    world:tick()
    assert(#world.events == 4 and world.events[4].phase == "completed", "only the current localized success status completes")
    importer:UpdateImportStatusHistory(rxp.locale.Get("Guides Loaded Successfully"), false)
    world:tick()
    assert(#world.events == 4, "completed observations are detached and cannot report a duplicate success")
    assert(addon:ForwardRestedXPImport("again", callback))
    world:tick()
    importer:UpdateImportStatusHistory(rxp.locale.Get("Guides Loaded Successfully"), false)
    world:tick()
    assert(world.hooks == 3 and #world.events == 6 and world.events[6].phase == "completed",
        "the same native owner is hooked once while a later import can emit the same success message")
end

do
    local addon, world, rxp, importer, env = newAddon()
    local callback = enableTracking(world, rxp, importer, env)
    assert(addon:ForwardRestedXPImport("export", callback))
    world:tick()
    importer:AbortImport()
    assert(#world.events == 1, "native abort cancellation waits one tick")
    importer:UpdateImportStatusHistory("private native parse detail", true)
    importer:UpdateImportStatusHistory(rxp.locale.Get("Guides Loaded Successfully"), false)
    world:tick()
    assert(#world.events == 2 and world.events[2].phase == "failed"
        and not world.events[2].message:find("private", 1, true), "native errors following abort take priority without exposing payload details")
    assert(world.aborts == 1, "tracking never invokes or repeats the native abort")
    assert(addon:ForwardRestedXPImport("next export", callback))
    world:tick()
    importer:AbortImport()
    world:tick()
    assert(world.events[#world.events].phase == "cancelled", "a bare native abort is reported as cancellation")
end

do
    local addon, world, rxp, importer, env = newAddon()
    local callback = enableTracking(world, rxp, importer, env)
    world.onImport = function(owner) owner:UpdateImportStatusHistory("Loading (%d/%d)", false, 0, 2) end
    assert(addon:ForwardRestedXPImport("own export", callback))
    world:tick()
    assert(importer:ImportString("replacement export"))
    assert(#world.events == 2 and world.events[2].phase == "cancelled", "a replacement native import retires the original observation")
    importer:UpdateImportStatusHistory(rxp.locale.Get("Guides Loaded Successfully"), false)
    world:tick()
    assert(#world.events == 2, "queued replacement status and later success are never attributed to the old import")
    assert(addon:ForwardRestedXPImport("detached export", callback))
    addon:StopRestedXPImportTracking()
    world:tick()
    importer:UpdateImportStatusHistory(rxp.locale.Get("Guides Loaded Successfully"), false)
    world:tick()
    assert(#world.events == 2 and world.calls == 3 and not world.aborts,
        "logout detachment cancels pending callbacks and leaves all native work untouched")
end

do
    local addon, world, rxp, importer, env = newAddon()
    local callback = enableTracking(world, rxp, importer, env)
    world.accepted = false
    world.onImport = function(owner) owner:UpdateImportStatusHistory("Invalid export", true) end
    local accepted, _, monitored = addon:ForwardRestedXPImport("export", callback)
    world:tick()
    assert(not accepted and not monitored and #world.events == 0, "rejected native calls never arm tracked callbacks")
    world.accepted, world.onImport = true, nil
    assert(addon:ForwardRestedXPImport("accepted", callback))
    world.loaded = false
    world:tick()
    assert(#world.events == 1 and world.events[1].phase == "unknown", "loss of the native owner cannot be reported as completion")
end

do
    local addon, world, rxp, importer, env = newAddon()
    local callback = enableTracking(world, rxp, importer, env)
    local nativeStatus = importer.UpdateImportStatusHistory
    importer.UpdateImportStatusHistory = nil
    local accepted, problem, monitored = addon:ForwardRestedXPImport("export", callback)
    assert(accepted and not problem and monitored == false and world.calls == 1 and world.hooks == 0,
        "unsupported monitoring still forwards to RestedXP without a false completion callback")
    importer.UpdateImportStatusHistory, rxp.locale = nativeStatus, "unsupported locale API"
    accepted, problem, monitored = addon:ForwardRestedXPImport("export", callback)
    assert(accepted and not problem and monitored == false and world.calls == 2 and world.hooks == 0,
        "unsupported locale APIs preserve native forwarding without observation")
    local other, otherWorld = newAddon()
    accepted, problem, monitored = other:ForwardRestedXPImport("export", function() error("no callback expected") end)
    assert(accepted and not problem and monitored == false and otherWorld.calls == 1,
        "missing native status methods or hooks leave simple forwarding available")
end

print("PASS: local RestedXP availability, native handoff and observed native import progress")
