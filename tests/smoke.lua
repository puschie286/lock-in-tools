local fixtures = dofile("tests/support/addon.lua")
local loadAddon, settings, contains = fixtures.loadAddon, fixtures.settings, fixtures.contains
local SECRET = fixtures.SECRET

-- Fixtures load modules explicitly; also check the native client's load order.
local manifestFile = assert(io.open("LockInTools.toc", "r"))
local manifest = manifestFile:read("*a"):gsub("\r\n", "\n")
manifestFile:close()
local channelEntry = manifest:find("\nDataChannel.lua\n", 1, true)
local dataEntry = manifest:find("\nData.lua\n", 1, true)
local friendCodecEntry = manifest:find("\nFriendStatusCodec.lua\n", 1, true)
local statusEntry = manifest:find("\nDataStatus.lua\n", 1, true)
local burnedEntry = manifest:find("\nBurned.lua\n", 1, true)
local positionEntry = manifest:find("\nPosition.lua\n", 1, true)
local rosterEntry = manifest:find("\nRoster.lua\n", 1, true)
local friendsEntry = manifest:find("\nFriends.lua\n", 1, true)
local rankingEntry = manifest:find("\nRanking.lua\n", 1, true)
local themeEntry = manifest:find("\nTheme.lua\n", 1, true)
local skinEntry = manifest:find("\nRestedXPSkin.lua\n", 1, true)
local overlayEntry = manifest:find("\nRankingOverlay.lua\n", 1, true)
local optionsEntry = manifest:find("\nOptions.lua\n", 1, true)
assert(channelEntry and dataEntry and channelEntry < dataEntry,
    "the native addon manifest must load channel management before the data transport")
assert(friendCodecEntry and statusEntry and rosterEntry and dataEntry < friendCodecEntry and friendCodecEntry < statusEntry
    and statusEntry < rosterEntry and not positionEntry,
    "the native addon manifest loads status synchronization without the retired position module")
assert(burnedEntry and statusEntry < burnedEntry and burnedEntry < overlayEntry,
    "the native manifest must load burned status after synchronization and before the ranking overlay")
assert(friendsEntry and rankingEntry and themeEntry and overlayEntry and optionsEntry
    and rosterEntry < friendsEntry and friendsEntry < rankingEntry and rankingEntry < themeEntry
    and themeEntry < overlayEntry and overlayEntry < optionsEntry,
    "the native manifest must load the ranking model after its data and the overlay after its theme")
assert(skinEntry and themeEntry < skinEntry and skinEntry < optionsEntry,
    "the optional RestedXP skin loads after its palette and before Settings")

-- Fire primitives must load natively and keep soft edges. Integer overloads in
-- the texture generator once turned every alpha into a hard zero or 255.
for _, asset in ipairs({ { "BurningGlow.tga", 64, 64 }, { "BurningFlame.tga", 32, 64 } }) do
    local file = assert(io.open("Media/" .. asset[1], "rb"))
    local data = file:read("*a")
    file:close()
    assert(data:byte(3) == 2 and data:byte(17) == 32 and data:byte(18) == 40
        and data:byte(13) + data:byte(14) * 256 == asset[2]
        and data:byte(15) + data:byte(16) * 256 == asset[3]
        and #data == 18 + asset[2] * asset[3] * 4,
        "Burning textures use complete, uncompressed RGBA TGA images")
    local transparent, soft = false, false
    for offset = 22, #data, 4 do
        local alpha = data:byte(offset)
        if alpha == 0 then transparent = true end
        if alpha > 0 and alpha < 255 then soft = true end
    end
    assert(transparent and soft, "Burning textures retain transparent backgrounds and smooth alpha edges")
end

-- Startup, native sharing, commands, reload and saved-variable preservation.
local addon, environment, messages, fire, world = loadAddon(nil, false)
assert(environment.SLASH_LOCKINTOOLS1 == "/lit", "slash command must be /lit")
assert(environment.LockInToolsDB == nil, "initialize only after ADDON_LOADED")
fire("PLAYER_LOGIN")
assert(not addon.ready and environment.LockInToolsDB == nil)
fire("ADDON_LOADED", "AnotherAddon")
assert(not addon.initialized)
fire("ADDON_LOADED", "LockInTools")
assert(addon.initialized and not addon.ready)
assert(addon.db.schemaVersion == 4 and addon.db.showWelcome == true)
assert(addon.db.position.sharing == false, "An older build must keep coordinate sharing off after a rollback")
assert(addon.db.chat == nil and addon.db.group == nil and addon.db.data.channels.global == nil)
fire("PLAYER_LOGIN")
assert(addon.ready and #messages == 1 and world.contentOpened == 1)
fire("PLAYER_LOGIN")
assert(#messages == 1 and world.contentOpened == 1, "duplicate login events cannot reopen Content")
local originalData, originalRoster, originalStartup = addon.dataState, addon.rosterState, addon.startupEvents
fire("ADDON_LOADED", "LockInTools")
assert(addon.dataState == originalData and addon.rosterState == originalRoster
    and addon.startupEvents == originalStartup and world.minimapButtonCreations == 1)
world:advance(30)
assert(#world.joinCalls == 0 and #world.dataJoinCalls == 0, "startup never joins custom channels")
local command = environment.SlashCmdList.LOCKINTOOLS
command("")
command("welcome")
command("content")
command("overview")
assert(world.contentOpened == 5 and world.welcomeOpened == 1 and world.overviewOpened == 1)
command("options")
assert(world.optionsOpened == 1)
local messageStart = #messages + 1
command("help")
assert(contains(messages, "/lit welcome", messageStart)
    and not contains(messages, "/lit chat", messageStart)
    and not contains(messages, "/lit join", messageStart)
    and not contains(messages, "/lit data", messageStart))
command("status")
assert(contains(messages, "16001", messageStart) and not contains(messages, "Shared positions:", messageStart))
for _, removed in ipairs({ "chat", "join", "leave", "data join", "data leave" }) do
    command(removed)
    assert(messages[#messages]:find("Unknown command", 1, true), "retired chat/channel commands are unavailable")
end
command("  WeLcOmE OFF  ")
assert(addon.db.showWelcome == false)
command("welcome maybe")
assert(addon.db.showWelcome == false and messages[#messages]:find("/lit help", 1, true))
command("status unexpected")
assert(messages[#messages]:find("Unknown command", 1, true))
addon.db.futureField = { keep = true }
local persisted = addon.db
local reloaded, reloadedEnvironment, reloadedMessages, reloadEvent, reloadWorld = loadAddon(persisted, true)
reloadEvent("ADDON_LOADED", "LockInTools")
assert(reloaded.ready and reloadedEnvironment.LockInToolsDB == persisted)
assert(not reloaded.db.showWelcome and #reloadedMessages == 0 and reloaded.db.futureField.keep)
assert(reloadWorld.contentOpened == 0)
reloadEvent("PLAYER_LOGIN")
reloadEvent("ADDON_LOADED", "LockInTools")
assert(reloadWorld.minimapButtonCreations == 1 and #reloadedMessages == 0)
for _, legacy in ipairs({
    { schemaVersion = 1, showWelcome = false },
    { schemaVersion = 2, showWelcome = false, chat = { channelName = "LegacyRoom", autoJoin = false } },
    { schemaVersion = 3, showWelcome = false, setupComplete = true, group = { secret = SECRET },
        data = { channels = { party = false, guild = true, global = true }, future = "preserved" },
        position = { keepLastKnown = true, groupFingerprint = "old-group", peers = {} },
        roster = { groupFingerprint = "old-group", peers = {} } },
}) do
    local migrated, _, output, _, migrationWorld = loadAddon(legacy, true)
    migrationWorld:initialize()
    migrationWorld:advance(30)
    assert(migrated.db.schemaVersion == 4 and migrated.db.showWelcome == false)
    assert(migrated.db.group == nil and migrated.db.chat == nil and migrated.db.data.channels.global == nil
        and migrated.db.data.channels.party == nil
        and migrated.db.roster.groupFingerprint == nil and migrated.db.position.groupFingerprint == nil)
    assert(migrationWorld.contentOpened == 0 and #migrationWorld.joinCalls == 0 and #migrationWorld.dataJoinCalls == 0)
    assert(not contains(output, SECRET), "migration never prints a retired group key")
end
local helpers = dofile("tests/support/helpers.lua")
local newer = { schemaVersion = 5, showWelcome = false, important = "keep",
    group = { secret = SECRET }, chat = { autoJoin = false }, data = { channels = { global = true } } }
local original = helpers.copy(newer)
local olderAddon, olderEnvironment, _, _, olderWorld = loadAddon(newer, true)
olderWorld.guild = true
olderWorld:initialize()
olderEnvironment.SlashCmdList.LOCKINTOOLS("welcome on")
assert(not olderAddon:SetDataChannelEnabled("guild", false) and olderAddon.savedDataReadOnly)
assert(olderEnvironment.LockInToolsDB == newer and helpers.equal(newer, original))
assert(olderWorld.contentOpened == 0 and not olderAddon:IsDataConnected())
for _, damaged in ipairs({ false, "invalid", { schemaVersion = "bad", showWelcome = "bad", chat = "bad" } }) do
    local repaired, _, _, _, repairedWorld = loadAddon(damaged, true)
    repairedWorld:initialize()
    assert(repaired.ready and repaired.db.schemaVersion == 4 and repaired.db.showWelcome == true)
    assert(repaired.db.chat == nil and repaired.db.group == nil)
end
assert(not manifest:find("\nGroup.lua\n", 1, true) and not manifest:find("\nChat.lua\n", 1, true)
    and not manifest:find("\nCrypto.lua\n", 1, true), "retired modules are absent from the native manifest")

-- Upgrade cleanup leaves only generated legacy rooms, including restored subscriptions
-- and asynchronous joins. User channels and newer saved profiles remain untouched.
do
    local current, _, _, event, clock = loadAddon(settings(), false)
    local oldChat, oldData = "LIT" .. string.rep("a", 28), "LITDATA" .. string.rep("b", 24)
    local unrelated = { "General", "LITFriends", "LIT" .. string.rep("c", 27), "LIT" .. string.rep("z", 28) }
    clock:restore(oldChat, 3)
    clock.chatFrames[1]:AddChannel(oldChat)
    local otherFrame = clock:newChatFrame()
    otherFrame:AddChannel(oldData)
    for index, name in ipairs(unrelated) do clock:restore(name, 10 + index); otherFrame:AddChannel(name) end
    clock:initialize()
    assert(not clock.channels[oldChat:lower()] and #clock.chatFrames[1].channelList == 0
        and #otherFrame.channelList == #unrelated and clock.dataLeaveCalls[1] == oldData)
    for _, name in ipairs(unrelated) do assert(clock.channels[name:lower()]) end
    clock:completeJoin(oldData, 7)
    assert(not clock.channels[oldData:lower()], "a late restored join is removed")
    local leaves = #clock.dataLeaveCalls
    clock:notice("YOU_JOINED", oldData, 7)
    assert(#clock.dataLeaveCalls == leaves + 1, "join notices are cleaned before the native channel cache catches up")
    clock:restore(oldChat:lower(), 4)
    event("PLAYER_ENTERING_WORLD")
    assert(not clock.channels[oldChat:lower()] and #clock.passwordCalls == 0
        and #clock.joinCalls == 0 and #clock.dataJoinCalls == 0)
    local readonly, _, _, _, futureClock = loadAddon({ schemaVersion = 5, showWelcome = false }, false)
    futureClock:restore(oldChat, 3)
    futureClock.chatFrames[1]:AddChannel(oldChat)
    futureClock:initialize()
    futureClock:completeJoin(oldData, 7)
    assert(readonly.savedDataReadOnly and futureClock.channels[oldChat:lower()]
        and futureClock.channels[oldData:lower()] and #futureClock.leaveCalls == 0
        and #futureClock.dataLeaveCalls == 0, "a newer schema cannot trigger legacy cleanup")
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
    assert(not helper:HasDataGroup(), "the import command fixture has no native membership")
    local dataSends, statusSends = #helperWorld.dataSends, #helperWorld.statusSends
    for _, valid in ipairs({ "rxp", "  RXp IMPORT  ", "restedxp", "restedxp import" }) do invoke(valid) end
    assert(#opened == 4, "both command names open the helper with an optional import verb")
    for _, category in ipairs(opened) do assert(category == "restedxp", "the command selects the RestedXP settings tab") end
    helper.db.restedxp = { groups = { old = { data = "old export" } } }
    invoke("  RESTEDXP CLEANUP  ")
    assert(helper.db.restedxp == nil and #opened == 4 and output[#output]:find("/reload", 1, true),
        "cleanup removes obsolete saved data without opening the form and explains when the file is saved")
    for _, invalid in ipairs({ "rxp import extra", "rxp share", "rxp cleanup extra" }) do
        invoke(invalid)
        assert(output[#output]:find("Unknown command", 1, true), "removed sharing and diagnostics commands remain unavailable")
    end
    assert(#opened == 4 and #helperWorld.dataSends == dataSends and #helperWorld.statusSends == statusSends,
        "helper navigation and rejected commands do not import or initiate group traffic")
end


assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep test environments isolated")
print("PASS: startup, migrations, commands and saved-data compatibility")
