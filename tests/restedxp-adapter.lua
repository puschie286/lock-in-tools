-- Forwarding leaves validation and import lifecycle entirely with RestedXP.
local helpers = dofile("tests/support/helpers.lua")

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
        return world.loaded and rxp or nil
    end
    local env = setmetatable({
        C_AddOns = {
            GetAddOnMetadata = function(name, field)
                assert(name == "RXPGuides" and field == "Version")
                return world.installed and rxp.release or nil
            end,
            IsAddOnLoaded = function(name) assert(name == "RXPGuides"); return world.loaded end,
        },
        LibStub = function(name, silent)
            assert(name == "AceAddon-3.0" and silent == true)
            return library
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
    helpers.loadModule("RestedXPAdapter.lua", addon, env)
    return addon, world, rxp, importer, env
end

local function enableTracking(world, rxp, importer, env)
    world.timers, world.events, world.hooks = {}, {}, 0
    rxp.locale = { Get = function(text) return (world.language or "") .. text end }
    importer.gui = { importStatusHistory = { rxp.locale.Get("Guides Loaded Successfully") } }
    function importer:UpdateImportStatusHistory(data, isError)
        self.gui.progressError = isError == true
    end
    function importer:AbortImport()
        world.aborts = (world.aborts or 0) + 1
        self.importCoroutine, self.importBufferSize, self.importReady = nil, 0, false
    end
    env.hooksecurefunc = helpers.hooksecurefunc(env, function() world.hooks = world.hooks + 1 end)
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
    world.loaded = false
    status = addon:GetRestedXPInstallation()
    assert(status.installed and not status.loaded and not status.compatible and type(status.problem) == "string")
    local accepted = addon:ForwardRestedXPImport("export")
    assert(not accepted and world.calls == 0)
    world.installed = false
    status = addon:GetRestedXPInstallation()
    assert(not status.installed and type(status.problem) == "string")
    world.loaded, world.installed = true, true
    env.GetAddOnMetadata, env.IsAddOnLoaded = env.C_AddOns.GetAddOnMetadata, env.C_AddOns.IsAddOnLoaded
    env.C_AddOns = nil
    assert(addon:GetRestedXPInstallation().compatible, "legacy addon metadata APIs remain supported")
end

do
    local addon, world, rxp, importer = newAddon()
    rxp.version = 39999
    local accepted, problem = addon:ForwardRestedXPImport("export")
    assert(not accepted and type(problem) == "string" and world.calls == 0)
    rxp.version, importer.ImportString = 40000, nil
    assert(not addon:GetRestedXPInstallation().compatible)
    assert(not addon:ForwardRestedXPImport("export") and world.calls == 0)
    rxp.guideImporter = nil
    assert(not addon:ForwardRestedXPImport("export") and world.calls == 0)
end

do
    local addon, world = newAddon()
    assert(addon:GetRestedXPBattleTag() == world.tag)
    for _, invalid in ipairs({ "", "Player#abc" }) do
        world.tag = invalid
        local tag, problem = addon:GetRestedXPBattleTag()
        assert(tag == nil and problem:find("Battle.net", 1, true))
    end
    world.tag, world.tagError = "Player#1234", true
    assert(addon:GetRestedXPBattleTag() == nil)
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
    world.combat = true
    assert(not addon:ForwardRestedXPImport("export") and world.calls == 0)
    world.combat, importer.importCoroutine = false, native
    assert(not addon:ForwardRestedXPImport("export") and importer.importCoroutine == native and world.calls == 0,
        "an active native import cannot be replaced")
    importer.importCoroutine = nil
    world.onImport = function(owner) owner.importCoroutine = native end
    assert(addon:ForwardRestedXPImport("native decides whether these bytes are valid"))
    assert(world.calls == 1 and importer.ImportString == importString and importer.importCoroutine == native,
        "acceptance leaves native validation and asynchronous work in control")
    assert(rxp.db.profile.guides == untouched and untouched.retained,
        "forwarding never mutates, reconstructs or replaces native guide storage")
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
    importer:UpdateImportStatusHistory("Loading (%d/%d)", false, 3, 3)
    world:tick()
    assert(world.events[3].phase == "importing", "the final guide count is not a completion signal")
    importer:UpdateImportStatusHistory(rxp.locale.Get("Guides Loaded Successfully"), false)
    world:tick()
    assert(#world.events == 4 and world.events[4].phase == "completed", "only the current localized success status completes")
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
    importer.UpdateImportStatusHistory = nil
    local accepted, problem, monitored = addon:ForwardRestedXPImport("export", callback)
    assert(accepted and not problem and monitored == false and world.calls == 1 and world.hooks == 0,
        "unsupported monitoring still forwards to RestedXP without a false completion callback")
end

print("PASS: local RestedXP availability, native handoff and observed native import progress")
