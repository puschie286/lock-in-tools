-- Local import lifecycle only; no guide discovery, transport or saved payloads.
local function Fixture(readOnly, saved)
    local world = { timers = {}, handed = {}, tag = "Local#1234" }
    local addon = { ready = true, savedDataReadOnly = readOnly,
        db = saved or { group = { secret = "keep" }, restedxp = { groups = { old = "cached export" } } } }
    local env = setmetatable({ issecretvalue = function(value)
        return world.secretValue ~= nil and value == world.secretValue
    end, C_Timer = { NewTimer = function(_, callback)
        local timer = { callback = callback }
        function timer:Cancel() self.cancelled = true end
        world.timers[#world.timers + 1] = timer
        return timer
    end } }, { __index = _G })
    function addon:RegisterGameEvents(_, callback) world.event = callback end
    function addon:Notify() end
    function addon:GetRestedXPInstallation()
        return { installed = not world.missing, loaded = not world.missing, compatible = not world.missing,
            problem = world.missing and "RestedXP is missing." or nil }
    end
    function addon:GetRestedXPBattleTag() return world.tag, "BattleTag unavailable." end
    addon.RestedXPCodec = { MAX_DATA = 2097152, Reencrypt = function(raw, source, destination)
        assert(raw == "ExportCASE+Payload" and source == "Source#9876" and destination == "Local#1234")
        coroutine.yield()
        if world.crash then error("private export and tag must never be displayed") end
        if world.invalid then return nil, "Invalid export framing." end
        return "retargeted export"
    end }
    function addon:ForwardRestedXPImport(raw, callback)
        world.handed[#world.handed + 1] = raw
        if world.monitored and not world.rejected then
            world.progress = callback
            callback("importing", 0, 10)
            if world.immediate then callback(world.immediate) end
            return true, nil, true
        end
        return not world.rejected, "RestedXP rejected the export."
    end
    function addon:StopRestedXPImportTracking()
        world.progress = nil
    end
    function world:run()
        local iterations = 0
        while #self.timers > 0 do
            iterations = iterations + 1
            assert(iterations < 100, "bounded local conversion")
            local timer = table.remove(self.timers, 1)
            if not timer.cancelled then timer.callback() end
        end
    end
    local chunk = assert(loadfile("RestedXP.lua"))
    setfenv(chunk, env)("LockInTools", addon)
    addon:InitializeRestedXP()
    return addon, world
end

do
    local addon, world = Fixture()
    world.monitored = true
    assert(addon:ImportRestedXPString("ExportCASE+Payload", "Source#9876"))
    assert(addon:GetRestedXPState().phase == "preparing")
    world:run()
    local state = addon:GetRestedXPState()
    assert(state.busy and not state.canImport and state.phase == "importing"
        and state.current == 0 and state.total == 10,
        "native acceptance stays busy and shows initial import progress")
    assert(not addon:ImportRestedXPString("ExportCASE+Payload", "Source#9876"),
        "a second import cannot start while native processing is in progress")
    world.progress("importing", 10, 10)
    assert(addon:GetRestedXPState().busy and addon:GetRestedXPState().phase == "importing",
        "reaching the final guide count is not completion confirmation")
    world.progress("completed")
    state = addon:GetRestedXPState()
    assert(not state.busy and state.canImport and state.phase == "completed" and not state.error,
        "only explicit native success reports completion")
    local previous = world.progress
    assert(addon:ImportRestedXPString("ExportCASE+Payload", "Source#9876"))
    world:run()
    previous("failed")
    assert(addon:GetRestedXPState().busy and addon:GetRestedXPState().phase == "importing",
        "late callbacks from an earlier import cannot change a new import")
    world.progress("completed")
end

for _, phase in ipairs({ "failed", "cancelled", "unknown" }) do
    local addon, world = Fixture()
    world.monitored = true
    assert(addon:ImportRestedXPString("ExportCASE+Payload", "Source#9876"))
    world:run()
    world.progress(phase, nil, nil, "private guide source must not be displayed")
    local state = addon:GetRestedXPState()
    assert(not state.busy and state.canImport and state.phase == phase and state.error == (phase ~= "unknown")
        and not state.status:find("private", 1, true), "terminal native outcomes release the form without exposing guide content")
    world.progress("completed")
    assert(addon:GetRestedXPState().phase == phase, "late success cannot replace a terminal failure or cancellation")
end

do
    local addon, world = Fixture()
    world.monitored, world.immediate = true, "completed"
    assert(addon:ImportRestedXPString("ExportCASE+Payload", "Source#9876"))
    world:run()
    assert(addon:GetRestedXPState().phase == "completed" and not addon:GetRestedXPState().busy,
        "an immediate native completion callback is not overwritten by the handoff result")
end

do
    local addon, world = Fixture()
    assert(addon.db.restedxp == nil and addon.db.group.secret == "keep", "remove only obsolete LIT guide caches")
    assert(addon:GetRestedXPState().canImport, "local import needs no group or data connection")
    assert(addon:SetRestedXPSourceBattleTag("  Source#9876  "))
    assert(addon:ImportRestedXPString("ExportCASE+Payload", "  Source#9876  "))
    assert(addon:GetRestedXPState().busy and #world.handed == 0
        and addon.db.restedxp.sourceBattleTag == "  Source#9876  ",
        "starting asynchronous conversion preserves the entered source preference")
    world:run()
    assert(#world.handed == 1 and world.handed[1] == "retargeted export" and not addon:GetRestedXPState().busy)
    assert(addon.db.restedxp.sourceBattleTag == "  Source#9876  "
        and addon:GetRestedXPState().sourceBattleTag == "  Source#9876  ",
        "native acceptance preserves the exact input while conversion uses a trimmed source")
    local count = 0
    for _ in pairs(addon.db.restedxp) do count = count + 1 end
    assert(count == 1, "only the source preference is saved, never pasted or converted guide strings")
    addon.db.restedxp.groups = { late = "obsolete guide export" }
    world.event(nil, "PLAYER_LOGOUT")
    assert(addon.db.restedxp.sourceBattleTag == "  Source#9876  " and addon.db.restedxp.groups == nil,
        "logout cleanup retains the preference while removing any old cache")
    local reloaded = Fixture(false, addon.db)
    assert(reloaded:GetRestedXPState().sourceBattleTag == "  Source#9876  ",
        "the source preference survives initialization with existing SavedVariables")
end

for _, scenario in ipairs({ "invalid", "crash", "rejected" }) do
    local addon, world = Fixture()
    addon.db.restedxp = { sourceBattleTag = "Previous#1234" }
    assert(addon:SetRestedXPSourceBattleTag("Source#9876"))
    world[scenario] = true
    assert(addon:ImportRestedXPString("ExportCASE+Payload", "Source#9876"))
    world:run()
    local state = addon:GetRestedXPState()
    assert(not state.busy and state.status and not state.status:find("private", 1, true))
    assert(#world.handed == (scenario == "rejected" and 1 or 0), "failed conversions never reach native import")
    assert(addon:GetRestedXPState().sourceBattleTag == "Source#9876",
        "failed conversion or native rejection retains the latest entered source")
    world[scenario] = nil
    assert(addon:ImportRestedXPString("ExportCASE+Payload", "Source#9876"), "errors release the helper for retry")
end

do
    local addon, world = Fixture()
    addon.db.restedxp = { sourceBattleTag = "Previous#1234" }
    assert(addon:SetRestedXPSourceBattleTag("bad tag"))
    assert(not addon:ImportRestedXPString("", "Source#9876"))
    assert(not addon:ImportRestedXPString("ExportCASE+Payload", "bad tag"))
    world.missing = true
    assert(not addon:GetRestedXPState().canImport and not addon:ImportRestedXPString("ExportCASE+Payload", "Source#9876"))
    world.missing, world.tag = false, nil
    assert(not addon:GetRestedXPState().canImport and not addon:ImportRestedXPString("ExportCASE+Payload", "Source#9876"))
    assert(#world.timers == 0 and #world.handed == 0 and addon:GetRestedXPState().sourceBattleTag == "bad tag",
        "validation and availability failures retain even an unfinished source preference")
end

do
    local addon, world = Fixture()
    assert(addon:SetRestedXPSourceBattleTag("Source#9876"))
    assert(addon:ImportRestedXPString("ExportCASE+Payload", "Source#9876"))
    world.tag = "Changed#4567"
    world:run()
    assert(#world.handed == 0 and not addon:GetRestedXPState().busy, "changed destination cannot receive an old personalized export")
    world.tag = "Local#1234"
    assert(addon:ImportRestedXPString("ExportCASE+Payload", "Source#9876"))
    world.event(nil, "PLAYER_LOGOUT")
    world:run()
    assert(#world.handed == 0 and not addon:GetRestedXPState().busy, "logout drops transient conversion without a native abort")
    assert(addon.db.restedxp.sourceBattleTag == "Source#9876",
        "cancelled conversions retain the independently saved source preference")
end

for _, newer in ipairs({ "Newer#4567", "" }) do
    local addon, world = Fixture()
    assert(addon:SetRestedXPSourceBattleTag("Source#9876"))
    assert(addon:ImportRestedXPString("ExportCASE+Payload", "Source#9876"))
    assert(addon:SetRestedXPSourceBattleTag(newer))
    world:run()
    assert(#world.handed == 1 and addon:GetRestedXPState().sourceBattleTag == newer,
        "a completed import cannot overwrite newer saved input or undo a cleared preference")
    assert(newer ~= "" or addon.db.restedxp == nil, "clearing input removes the preference namespace")
end

do
    local addon, world = Fixture()
    assert(addon:SetRestedXPSourceBattleTag(string.rep("a", 128)), "the complete field limit is saved")
    local preference = addon.db.restedxp
    for _, invalid in ipairs({ false, 123, {}, string.rep("a", 129), "secret" }) do
        world.secretValue = "secret"
        assert(not addon:SetRestedXPSourceBattleTag(invalid) and addon.db.restedxp == preference
            and addon:GetRestedXPState().sourceBattleTag == string.rep("a", 128),
            "invalid, secret and oversized values cannot replace the saved preference")
    end
end

do
    local addon, world = Fixture(true)
    assert(addon.db.restedxp.groups.old == "cached export" and not addon:GetRestedXPState().canImport)
    assert(not addon:CleanupRestedXPData() and addon.db.restedxp.groups.old == "cached export",
        "explicit cleanup also respects newer-schema read-only data")
    assert(not addon:ImportRestedXPString("ExportCASE+Payload", "Source#9876") and #world.timers == 0,
        "newer-schema saved data remains untouched")
    assert(not addon:SetRestedXPSourceBattleTag("Source#9876") and not addon:SetRestedXPSourceBattleTag("")
        and addon.db.restedxp.groups.old == "cached export",
        "saving or clearing input respects newer-schema read-only settings")
end

local fixtures = dofile("tests/support/addon.lua")
do
    local profile = fixtures.settings(fixtures.SECRET, false)
    profile.restedxp = { groups = { old = { data = "obsolete guide data" } } }
    local addon, _, _, _, world = fixtures.loadAddon(profile, false)
    world:initialize()
    world:advance(8)
    assert(addon.ready and profile.restedxp == nil and profile.group.secret == fixtures.SECRET)
    assert(#world.guideSends == 0 and addon.dataState.features.guides == nil, "startup sends no guide data and registers no guide feature")
end

do
    local addon, environment, _, _, world = fixtures.loadAddon({ schemaVersion = 3, showWelcome = false }, false)
    world:initialize()
    local forwarded
    local importer = { gui = { importStatusHistory = { "Guides Loaded Successfully" } } }
    local rxp = { version = 40000, guideImporter = importer, locale = { Get = function(key) return key end } }
    function importer:UpdateImportStatusHistory(data, isError, ...)
        self.gui.progressMessage, self.gui.progressError = string.format(data, ...), isError == true
    end
    function importer:AbortImport() self.importCoroutine, self.importBufferSize = nil, 0 end
    function importer:ImportString(raw)
        forwarded = raw
        self.importCoroutine = coroutine.create(function() end)
        self:UpdateImportStatusHistory("Loading Guides... (0/%d)", false, 2)
        return true
    end
    local nativeLibStub = environment.LibStub
    environment.LibStub = function(name, ...)
        if name == "AceAddon-3.0" then return { GetAddon = function() return rxp end } end
        return nativeLibStub(name, ...)
    end
    function addon:GetRestedXPBattleTag() return "Local#1234" end
    dofile("tests/support/ui.lua")(addon, environment)
    addon:OpenOptions("restedxp")
    local panel = addon.optionsPanel
    panel.restedxpBattleTag:UserInput("Local#1234")
    -- Keep the payload opaque: the same source/destination makes conversion
    -- byte-preserving. RestedXP alone decides whether these bytes are guides.
    panel.restedxpExport:Paste("1||1:Zg==%||40000")
    panel.restedxpExport:AdvanceFrame(0.11)
    panel.restedxpImport:Click()
    world:advance(1)
    assert(forwarded == "1|1:Zg==%|40000" and addon:GetRestedXPState().phase == "importing"
        and not panel.restedxpImport:IsEnabled(),
        "escaped separators survive buffered paste, real conversion and native handoff")
    importer.importCoroutine, importer.importBufferSize = nil, 2
    importer:UpdateImportStatusHistory("Loading Guides... (%d/%d)", false, 2, 2)
    world:advance(0.01)
    assert(addon:GetRestedXPState().busy and not panel.restedxpImport:IsEnabled(),
        "even a previous success-history entry and a complete count cannot finish the current import")
    importer:UpdateImportStatusHistory("Guides Loaded Successfully", false)
    importer.importBufferSize = 0
    world:advance(0.01)
    assert(addon:GetRestedXPState().phase == "completed"
        and panel.restedxpImport:IsEnabled() and #world.guideSends == 0,
        "the native success event completes the helper and releases the form without guide traffic")
end
print("PASS: local RestedXP import lifecycle, cleanup, privacy and zero guide traffic")
