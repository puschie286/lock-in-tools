-- This harness is never loaded by the addon.
local fixtures = dofile("tests/support/addon.lua")
local loadAddon = fixtures.loadAddon
local settings = fixtures.settings
local contains = fixtures.contains
local SECRET = fixtures.SECRET
local OTHER_SECRET = fixtures.OTHER_SECRET

-- Saved roster and position identities merge before login without treating historical peers as live.
do
    local seed, _, _, seedEvent = loadAddon(settings(nil, false), false)
    seedEvent("ADDON_LOADED", "LockInTools")
    local fingerprint, stamp = seed:GetGroupFingerprint(), 1999999800
    local profile = settings(nil, false)
    profile.roster = { groupFingerprint = fingerprint, peers = {
        ["rosteronly-testrealm"] = { name = "RosterOnly", level = 21, seenAt = stamp },
        ["shared-testrealm"] = { name = "Shared", level = 32, seenAt = stamp },
    } }
    profile.position = { sharing = true, keepLastKnown = true, groupFingerprint = fingerprint, peers = {
        ["shared-testrealm"] = { name = "Shared", map = 37, x = 0.2, y = 0.3,
            stamp = stamp, positionStamp = stamp - 10, class = "HUNTER" },
        ["positiononly-remoterealm"] = { name = "PositionOnly-Remote Realm", map = 37, x = 0.4, y = 0.5,
            stamp = stamp, positionStamp = stamp - 20, class = "MAGE" },
    } }
    local restored, environment, _, event, world = loadAddon(profile, false)
    environment.GetNormalizedRealmName = function() return nil end
    event("ADDON_LOADED", "LockInTools")
    assert(restored.rosterState.peers["rosteronly-testrealm"]
        and restored.positionState.peers["shared-testrealm"])
    environment.GetNormalizedRealmName = function() return "TestRealm" end
    event("PLAYER_LOGIN")
    world:completeJoin(restored:GetGroupDataChannelName(), 7)
    local rows = {}
    for _, row in ipairs(restored:GetOverviewPlayers()) do rows[row.id] = row end
    assert(rows["self-testrealm"].isSelf and rows["rosteronly-testrealm"].level == 21)
    assert(rows["shared-testrealm"].level == 32 and rows["shared-testrealm"].x == 0.2
        and rows["shared-testrealm"].positionStamp == stamp - 10 and not rows["shared-testrealm"].online)
    assert(rows["positiononly-remoterealm"].x == 0.4 and not rows["positiononly-remoterealm"].online
        and rows["positiononly-remoterealm"].xpState == "unavailable")
end
-- Production startup connects shared data independently of human chat and position preferences.
do
    local connected, connectedEnvironment, connectedMessages, connectedEvent, connectedWorld =
        loadAddon(settings(nil, false), false)
    connectedEnvironment.UnitClass = function(unit)
        assert(unit == "player")
        return "Mage", "MAGE"
    end
    connectedEvent("ADDON_LOADED", "LockInTools")
    assert(#connectedWorld.dataJoinCalls == 0 and not connected:IsDataConnected(),
        "do not join data before login")
    connectedEvent("PLAYER_LOGIN")
    local dataRoom, chatRoom = connected:GetGroupDataChannelName(), connected:GetGroupChannelName()
    assert(#connectedWorld.dataJoinCalls == 1 and connectedWorld.dataJoinCalls[1] == dataRoom
        and #connectedWorld.joinCalls == 0 and not connected:IsDataConnected(),
        "data joins asynchronously even with chat autojoin and position sharing off")
    connectedWorld:completeJoin(dataRoom, 7)
    assert(connected:IsDataConnected() and #connectedWorld.dataSends == 0
        and #connectedWorld.addCalls == 0, "idle data connects without attaching to human chat")
    local presence = assert(connectedWorld.statusSends[1], "shared status broadcasts while position sharing is off")
    assert(presence.prefix == connected:GetDataPrefix() and presence.target == "7"
        and presence.message:match("^1|Q|status|")
        and presence.message:find("|11=7", 1, true) and not presence.message:find("|9=", 1, true),
        "Ordinary status shares class while coordinates remain disabled")
    connectedEvent("CHAT_MSG_ADDON", presence.prefix, presence.message, "CHANNEL", "RosterFriend", nil, 0, 7, dataRoom)
    local rosterFriend
    for _, player in ipairs(connected:GetOverviewPlayers()) do
        if player.id == "rosterfriend-testrealm" then rosterFriend = player end
    end
    assert(rosterFriend and rosterFriend.online and rosterFriend.level == 12 and not rosterFriend.map
        and connected.db.roster.peers["rosterfriend-testrealm"]
        and connected.positionState.classes["rosterfriend-testrealm"] == "MAGE"
        and next(connected:GetSharedPositions()) == nil,
        "production status shares class and roster presence while coordinates stay disabled")
    local connectedCommand = connectedEnvironment.SlashCmdList.LOCKINTOOLS
    connectedCommand("join")
    connectedWorld:completeJoin(chatRoom, 3)
    assert(#connectedWorld.addCalls == 1 and connectedWorld.addCalls[1] == chatRoom)
    assert(connected:SetPositionSharing(true))
    connectedWorld:advance(2)
    local sent = assert(connectedWorld.dataSends[1], "enabling positions starts native broadcasts")
    assert(sent.prefix == connected:GetDataPrefix() and sent.target == "7"
        and sent.message:match("^1|position|2|P|%d+|37|25000|75000$"),
        "production movement sends scaled integers rather than decimal coordinates")
    connectedEvent("CHAT_MSG_ADDON", sent.prefix, sent.message, "CHANNEL", "Self", nil, 0, 7, dataRoom)
    assert(next(connected:GetSharedPositions()) == nil, "production route excludes own position echoes")
    connectedEvent("CHAT_MSG_ADDON", sent.prefix, sent.message, "CHANNEL", "RosterFriend", nil, 0, 7, dataRoom)
    assert(connected:GetSharedPositions()["rosterfriend-testrealm"].class == "MAGE"
        and connected:GetSharedPositions()["rosterfriend-testrealm"].x == 0.25
        and connected:GetSharedPositions()["rosterfriend-testrealm"].y == 0.75,
        "the first location uses the class already learned from status with sharing disabled")
    connectedEvent("CHAT_MSG_ADDON", sent.prefix, sent.message, "CHANNEL", "Friend", nil, 0, 7, dataRoom)
    assert(connected:GetSharedPositions()["friend-testrealm"].online
        and connected.db.position.peers["friend-testrealm"], "production route delivers and retains peer positions")
    assert(connected:SetPositionSharing(false))
    connectedWorld:advance(2)
    assert(#connectedWorld.dataSends == 1 and connected:IsDataConnected()
        and next(connected:GetSharedPositions()) == nil, "position switch leaves the shared pipeline connected")
    connectedCommand("data leave")
    connectedWorld.fire("PLAYER_ENTERING_WORLD")
    connectedWorld:advance(0.9)
    assert(not connected:IsDataConnected() and #connectedWorld.dataJoinCalls == 1
        and connectedWorld.dataLeaveCalls[1] == dataRoom and connectedWorld.channels[chatRoom:lower()],
        "leaving data briefly disconnects without disrupting native human chat")
    connectedWorld:advance(0.1)
    assert(#connectedWorld.dataJoinCalls == 2 and not connected:IsDataConnected(),
        "shared data reconnects automatically while positions remain disabled")
    connectedWorld:completeJoin(dataRoom, 14)
    assert(connected:IsDataConnected())
    assert(connected:SetPositionSharing(true))
    connectedWorld:advance(2)
    assert(#connectedWorld.dataSends == 2 and connectedWorld.dataSends[2].target == "14",
        "reconnected positions use the current local channel number")
    assert(not contains(connectedMessages, SECRET) and not contains(connectedMessages, OTHER_SECRET))
end

-- A normal switch waits for both native channels and clears old feature/request state.
do
    local switching, _, _, event, clock = loadAddon(settings(), false)
    clock:initialize()
    local oldChat, oldData = switching:GetGroupChannelName(), switching:GetGroupDataChannelName()
    local oldFingerprint = switching:GetGroupFingerprint()
    clock:completeJoin(oldChat, 3)
    clock:completeJoin(oldData, 7)
    assert(switching:RegisterDataRequest("snapshot", function() return "own" end, function() end))
    local accepted, request = switching:RequestData("snapshot", "old")
    assert(accepted)
    local sample = assert(clock.statusSends[1]).message
    event("CHAT_MSG_ADDON", switching:GetDataPrefix(), sample, "CHANNEL", "OldFriend")
    assert(switching.db.roster.peers["oldfriend-testrealm"])
    clock:restore("Unrelated", 19)
    local chatJoins, dataJoins = #clock.joinCalls, #clock.dataJoinCalls
    clock.holdLeaves = true
    assert(switching:SetGroupSecret(OTHER_SECRET))
    assert(not switching:IsDataConnected() and not switching:OpenChatInput()
        and switching:GetGroupFingerprint() == oldFingerprint,
        "Both traffic paths stop before a new group becomes active")
    clock:advance(0)
    assert(switching:IsGroupSwitching(), "Activation must await native departure")
    assert(#clock.joinCalls == chatJoins and #clock.dataJoinCalls == dataJoins,
        "Deferred cleanup cannot start new join requests")
    assert(clock.channels[oldChat:lower()] and clock.channels[oldData:lower()],
        "The native mock retains both memberships until departure completes")
    assert(next(switching:GetSharedPositions()) == nil and #switching:GetOverviewPlayers() == 0,
        "Old peers are hidden while native leaves remain pending")
    assert(next(switching.dataState.pendingRequests) == nil,
        "Deferred cleanup retires old requests while native leaves remain pending")
    clock.channels[oldChat:lower()] = nil
    event("CHANNEL_LEFT", 3, oldChat)
    clock:advance(0)
    assert(switching:IsGroupSwitching() and #clock.joinCalls == chatJoins and #clock.dataJoinCalls == dataJoins,
        "Human chat departure alone cannot activate either new channel")
    clock:advance(2)
    assert(switching:IsGroupSwitching() and not switching:IsDataConnected()
        and #clock.joinCalls == chatJoins and #clock.dataJoinCalls == dataJoins,
        "Elapsed time does not replace native departure confirmation")
    clock.channels[oldData:lower()] = nil
    event("CHANNEL_LEFT", 7, oldData)
    clock:advance(0)
    assert(not switching:IsGroupSwitching() and #clock.joinCalls == chatJoins + 1 and #clock.dataJoinCalls == dataJoins + 1
        and clock.joinCalls[chatJoins + 1] == switching:GetGroupChannelName()
        and clock.dataJoinCalls[dataJoins + 1] == switching:GetGroupDataChannelName() and clock.channels.unrelated,
        "Both channels join the new group only after both old memberships disappear")
    local fingerprint = switching:GetGroupFingerprint()
    assert(fingerprint ~= oldFingerprint and switching.db.position.groupFingerprint == fingerprint
        and switching.db.roster.groupFingerprint == fingerprint and next(switching.db.position.peers) == nil
        and next(switching.db.roster.peers) == nil,
        "Persisted feature caches belong to the newly active group")
    clock:completeJoin(switching:GetGroupChannelName(), 8)
    clock:completeJoin(switching:GetGroupDataChannelName(), 12)
    assert(switching:IsDataConnected()
        and not switching:OnDataEvent("CHAT_MSG_ADDON", switching:GetDataPrefix(),
            "1|R|snapshot|" .. request .. "|self-testrealm|old", "CHANNEL", "OldFriend"))
    clock.holdLeaves = false
    clock:completeJoin(oldChat, 3)
    clock:completeJoin(oldData, 7)
    assert(not clock.channels[oldChat:lower()] and not clock.channels[oldData:lower()]
        and switching:IsDataConnected(), "Late obsolete joins are still removed without interrupting the active group")
end

-- Saving position preferences preserves joins and recovery checks already in progress.
do
    local pending, _, _, _, pendingWorld = loadAddon(settings(nil, false), false)
    pendingWorld:initialize()
    local state = pending.dataState
    local timer = state.timer
    assert(state.pending and state.attempts == 1 and timer)
    assert(pending:SetPositionSharing(true))
    assert(#pendingWorld.dataJoinCalls == 1 and state.attempts == 1
        and state.timer == timer and not timer:IsCancelled(),
        "enabling positions does not duplicate or reset an in-progress startup join")
    pendingWorld:advance(2)
    timer = state.timer
    assert(state.attempts == 2 and #pendingWorld.dataJoinCalls == 2)
    assert(pending:SetPositionSharing(true))
    assert(#pendingWorld.dataJoinCalls == 2 and state.attempts == 2
        and state.timer == timer and not timer:IsCancelled(),
        "re-saving enabled sharing preserves the current shared retry delay")
    pendingWorld:completeJoin(pending:GetGroupDataChannelName(), 7)
    local connectedTimer = state.timer
    assert(pending:SetPositionSharing(true))
    assert(#pendingWorld.dataJoinCalls == 2 and state.timer == connectedTimer and pending:IsDataConnected(),
        "saving enabled sharing leaves a connected data transport intact")
    assert(pending:SetGroupSecret(OTHER_SECRET))
    assert(pending:IsGroupSwitching() and not pending:IsDataConnected())
    assert(pending:SetPositionSharing(true))
    assert(#pendingWorld.dataJoinCalls == 2 and pending:IsGroupSwitching(),
        "saving enabled sharing does not bypass coordinated departure")
    pendingWorld:advance(0)
    assert(#pendingWorld.dataJoinCalls == 3
        and pendingWorld.dataJoinCalls[3] == pending:GetGroupDataChannelName(),
        "the deferred switch joins the newly selected group once")
end

-- Position preferences never bypass login, group setup or newer-schema protection.
do
    local loading, _, _, loadingEvent, loadingWorld = loadAddon(settings(nil, false), false)
    loadingEvent("ADDON_LOADED", "LockInTools")
    assert(loading:SetPositionSharing(true))
    loadingWorld:advance(30)
    assert(#loadingWorld.dataJoinCalls == 0 and #loadingWorld.dataSends == 0,
        "saving enabled sharing before login does not send network requests")
    loadingEvent("PLAYER_LOGIN")
    assert(#loadingWorld.dataJoinCalls == 1,
        "login starts the normal single data join after sharing was enabled during loading")
    local ungrouped, _, _, _, ungroupedWorld = loadAddon(settings("", false), false)
    ungroupedWorld:initialize()
    assert(ungrouped:SetPositionSharing(true))
    ungroupedWorld:advance(30)
    assert(#ungroupedWorld.dataJoinCalls == 0 and #ungroupedWorld.dataSends == 0,
        "saving enabled sharing without a group does not join or broadcast")
    local futureSettings = settings(nil, false)
    futureSettings.schemaVersion = 4
    futureSettings.position = { sharing = false, keepLastKnown = true, peers = {},
        showTrails = "future-trails", trailLength = "future-length" }
    local future, _, _, _, futureWorld = loadAddon(futureSettings, false)
    futureWorld:initialize()
    assert(not future:SetPositionSharing(true))
    assert(futureSettings.position.showTrails == "future-trails"
        and futureSettings.position.trailLength == "future-length",
        "Read-only startup preserves retired preferences in the original newer-schema data")
    futureWorld:advance(30)
    assert(not futureSettings.position.sharing and #futureWorld.dataJoinCalls == 0
        and #futureWorld.dataSends == 0, "read-only preferences cannot enable sharing or reconnect data")
end


assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep test environments isolated")
print("PASS: production data startup, preferences, routing and recovery")
