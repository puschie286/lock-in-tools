local fixtures = dofile("tests/support/addon.lua")
local loadAddon, settings, contains = fixtures.loadAddon, fixtures.settings, fixtures.contains
local SECRET, OTHER_SECRET = fixtures.SECRET, fixtures.OTHER_SECRET

-- Fixtures load modules explicitly; also check the native client's load order.
local manifestFile = assert(io.open("LockInTools.toc", "r"))
local manifest = manifestFile:read("*a"):gsub("\r\n", "\n")
manifestFile:close()
local channelEntry = manifest:find("\nDataChannel.lua\n", 1, true)
local dataEntry = manifest:find("\nData.lua\n", 1, true)
local statusEntry = manifest:find("\nDataStatus.lua\n", 1, true)
local positionEntry = manifest:find("\nPosition.lua\n", 1, true)
local rosterEntry = manifest:find("\nRoster.lua\n", 1, true)
local rankingEntry = manifest:find("\nRanking.lua\n", 1, true)
local themeEntry = manifest:find("\nTheme.lua\n", 1, true)
local overlayEntry = manifest:find("\nRankingOverlay.lua\n", 1, true)
local optionsEntry = manifest:find("\nOptions.lua\n", 1, true)
assert(channelEntry and dataEntry and channelEntry < dataEntry,
    "the native addon manifest must load channel management before the data transport")
assert(dataEntry and statusEntry and positionEntry and rosterEntry
    and dataEntry < statusEntry and statusEntry < positionEntry and statusEntry < rosterEntry,
    "the native addon manifest must load status synchronization after transport and before its consumers")
assert(rankingEntry and themeEntry and overlayEntry and optionsEntry
    and rosterEntry < rankingEntry and rankingEntry < themeEntry
    and themeEntry < overlayEntry and overlayEntry < optionsEntry,
    "the native manifest must load the ranking model after its data and the overlay after its theme")

-- Startup, migration, commands, reload and saved-variable preservation.
local addon, environment, messages, fire, world = loadAddon(nil, false)
assert(environment.SLASH_LOCKINTOOLS1 == "/lit", "slash command must be /lit")
assert(environment.LockInToolsDB == nil, "initialize only after ADDON_LOADED")
fire("PLAYER_LOGIN")
assert(not addon.ready and environment.LockInToolsDB == nil,
    "an early login event cannot initialize saved settings before addon loading completes")
fire("ADDON_LOADED", "AnotherAddon")
assert(not addon.initialized)
fire("ADDON_LOADED", "LockInTools")
assert(addon.initialized and not addon.ready)
assert(addon.db.schemaVersion == 3 and addon.db.showWelcome == true)
assert(addon.db.chat.autoJoin == true and not addon:HasGroup())
fire("PLAYER_LOGIN")
assert(addon.ready and #messages == 1, "announce once at login")
assert(messages[1]:find("Loaded version 0.2.0. Type /lit to open Content.", 1, true),
    "the initial loading message includes the version from addon metadata")
assert(world.contentOpened == 1 and world.welcomeOpened == 0,
    "show Content after login when initial setup is enabled and no group is configured")
fire("PLAYER_LOGIN")
assert(#messages == 1 and world.contentOpened == 1, "do not repeat Content on duplicate login events")
local originalData, originalRoster, originalStartup = addon.dataState, addon.rosterState, addon.startupEvents
fire("ADDON_LOADED", "LockInTools")
assert(addon.dataState == originalData and addon.rosterState == originalRoster
    and addon.startupEvents == originalStartup and world.minimapButtonCreations == 1,
    "repeated startup events preserve existing models, subscriptions and the singleton minimap button")
world:advance(30)
assert(#world.joinCalls == 0 and #world.dataJoinCalls == 0,
    "an unconfigured group must not join a channel")
local command = environment.SlashCmdList.LOCKINTOOLS
command("")
assert(world.contentOpened == 2, "bare /lit opens Content")
command("welcome")
assert(world.contentOpened == 3 and world.welcomeOpened == 1, "/lit welcome remains a Content compatibility alias")
command("content")
assert(world.contentOpened == 4, "/lit content opens Content")
command("overview")
assert(world.contentOpened == 5 and world.overviewOpened == 1, "/lit overview opens Content's Overview")
command("options")
assert(world.optionsOpened == 1, "/lit options opens feature settings")
local messageStart = #messages + 1
command("help")
assert(contains(messages, "/lit welcome", messageStart))
command("status")
assert(contains(messages, "16001", messageStart))
assert(contains(messages, "Shared positions:", messageStart), "status includes position sharing")
command("  WeLcOmE OFF  ")
assert(addon.db.showWelcome == false)
command("welcome maybe")
assert(addon.db.showWelcome == false and messages[#messages]:find("/lit help", 1, true))
command("status unexpected")
assert(messages[#messages]:find("Unknown command", 1, true))
addon.db.futureField = { keep = true }
assert(addon:SetGroupSecret(SECRET))
local persisted = addon.db
local reloaded, reloadedEnvironment, reloadedMessages, reloadEvent, reloadWorld = loadAddon(persisted, true)
reloadEvent("ADDON_LOADED", "LockInTools")
assert(reloaded.ready and reloadedEnvironment.LockInToolsDB == persisted)
assert(not reloaded.db.showWelcome and #reloadedMessages == 0 and reloaded.db.futureField.keep)
assert(reloadWorld.contentOpened == 0, "configured groups do not reopen Content at login")
assert(reloaded:GetGroupSecret() == SECRET, "retain group across reload")
assert(reloaded:GetGroupFingerprint() == addon:GetGroupFingerprint())
assert(reloaded:GetGroupChannelName() == addon:GetGroupChannelName())
assert(reloaded:GetGroupChannelPassword() == addon:GetGroupChannelPassword())
reloadEvent("PLAYER_LOGIN")
reloadEvent("ADDON_LOADED", "LockInTools")
assert(reloadWorld.minimapButtonCreations == 1 and #reloadedMessages == 0,
    "loading after login then receiving delayed startup events performs initialization only once")
reloadWorld:advance(1)
assert(reloadWorld.lastJoinPassword == reloaded:GetGroupChannelPassword())
assert(not contains(messages, SECRET) and not contains(reloadedMessages, SECRET), "never print the group secret")
for _, legacy in ipairs({
    { schemaVersion = 1, showWelcome = false },
    { schemaVersion = 2, showWelcome = false, chat = { channelName = "LegacyRoom", autoJoin = false } },
}) do
    local migrated, _, _, _, migrationWorld = loadAddon(legacy, true)
    migrationWorld:initialize()
    migrationWorld:advance(30)
    assert(migrated.db.schemaVersion == 3 and migrated.db.showWelcome == false)
    assert(migrationWorld.contentOpened == 0, "disabled initial Content stays disabled during migration")
    assert(not migrated:HasGroup() and #migrationWorld.joinCalls == 0,
        "migration does not reinterpret a legacy channel name as a group secret")
end
local newer = { schemaVersion = 4, showWelcome = false, important = "keep",
    group = { secret = SECRET }, chat = { autoJoin = false } }
local olderAddon, olderEnvironment, _, _, olderWorld = loadAddon(newer, true)
olderWorld:initialize()
olderEnvironment.SlashCmdList.LOCKINTOOLS("welcome on")
assert(not olderAddon:SetChatAutoJoin(true) and not olderAddon:SetGroupSecret(OTHER_SECRET))
assert(not olderAddon:LeaveGroup() and olderAddon.savedDataReadOnly)
assert(olderEnvironment.LockInToolsDB == newer and newer.schemaVersion == 4)
assert(not newer.showWelcome and newer.important == "keep" and newer.group.secret == SECRET)
assert(newer.chat.autoJoin == false)
assert(olderWorld.contentOpened == 0, "read-only saved data does not trigger initial setup")
assert(#olderWorld.joinCalls == 0 and #olderWorld.dataJoinCalls == 0,
    "read-only startup does not join either group channel")
for _, damaged in ipairs({ false, "invalid", { schemaVersion = "bad", showWelcome = "bad", chat = "bad" } }) do
    local repaired, _, _, _, repairedWorld = loadAddon(damaged, true)
    repairedWorld:initialize()
    assert(repaired.ready and repaired.db.schemaVersion == 3 and repaired.db.showWelcome == true)
    assert(type(repaired.db.chat) == "table" and not repaired:HasGroup())
end

-- RestedXP commands open only the local import helper and require no group.
do
    local helper, api, output, _, helperWorld = loadAddon(
        { schemaVersion = 3, showWelcome = false, chat = { autoJoin = false } }, false)
    local invoke, opened = api.SlashCmdList.LOCKINTOOLS, {}
    function helper:OpenOptions(category) opened[#opened + 1] = category end
    function helper:ImportRestedXPString() error("Opening the helper must not start an import") end
    invoke("rxp")
    assert(#opened == 0 and output[#output]:find("Still loading", 1, true), "the helper waits for addon loading")
    invoke("restedxp import")
    assert(#opened == 0 and output[#output]:find("Still loading", 1, true), "the import alias also waits for login")
    invoke("rxp cleanup")
    assert(output[#output]:find("Still loading", 1, true), "cleanup waits for saved data initialization")
    helperWorld:initialize()
    assert(not helper:HasGroup(), "the import command fixture has no group")
    local guideSends, dataSends, statusSends = #(helperWorld.guideSends or {}), #helperWorld.dataSends, #helperWorld.statusSends
    for _, valid in ipairs({ "rxp", "  RXp IMPORT  ", "restedxp", "restedxp import" }) do invoke(valid) end
    assert(#opened == 4, "both command names open the helper with an optional import verb")
    for _, category in ipairs(opened) do assert(category == "restedxp", "the command selects the RestedXP settings tab") end
    helper.db.restedxp = { groups = { old = { data = "old export" } } }
    invoke("  RESTEDXP CLEANUP  ")
    assert(helper.db.restedxp == nil and #opened == 4 and output[#output]:find("/reload", 1, true),
        "cleanup removes obsolete saved data without opening the form and explains when the file is saved")
    for _, invalid in ipairs({ "rxp import extra", "rxp test", "rxp test random", "rxp test local",
        "rxp stats", "rxp cancel", "restedxp update", "rxp share", "rxp cleanup extra" }) do
        invoke(invalid)
        assert(output[#output]:find("Unknown command", 1, true), "removed sharing and diagnostics commands remain unavailable")
    end
    assert(#opened == 4 and #(helperWorld.guideSends or {}) == guideSends
        and #helperWorld.dataSends == dataSends and #helperWorld.statusSends == statusSends,
        "helper navigation and rejected commands do not import or initiate group traffic")
    local first = #output + 1
    invoke("help")
    assert(contains(output, "/lit rxp [import]", first)
        and contains(output, "/lit rxp cleanup", first)
        and not contains(output, "/lit rxp test", first) and not contains(output, "/lit rxp stats", first)
        and not contains(output, "/lit rxp cancel", first), "help exposes only the local import entry point")
end


assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep test environments isolated")
print("PASS: startup, migrations, commands and saved-data compatibility")
