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
    local profile = settings(nil, false)
    profile.position = { sharing = false }
    local connected, connectedEnvironment, connectedMessages, connectedEvent, connectedWorld =
        loadAddon(profile, false)
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

-- Native routes connect the complete addon before its additional global channel.
-- Overlapping deliveries keep one roster entry, position and Burned report per player.
do
    local aliceProfile, bobProfile = settings(nil, false), settings(OTHER_SECRET, false)
    aliceProfile.burned, bobProfile.burned = { status = 20 }, { status = 80 }
    local alice, aliceEnvironment, _, aliceEvent, aliceWorld = loadAddon(aliceProfile, false)
    local bob, bobEnvironment, _, bobEvent, bobWorld = loadAddon(bobProfile, false)
    aliceEnvironment.UnitFullName = function() return "Alice", "Test Realm" end
    bobEnvironment.UnitFullName = function() return "Bob", "Test Realm" end
    aliceEnvironment.UnitClass = function() return "Mage", "MAGE" end
    bobEnvironment.UnitClass = function() return "Hunter", "HUNTER" end
    aliceWorld.grouped, aliceWorld.guild, aliceWorld.xp = true, true, 125
    bobWorld.grouped, bobWorld.guild, bobWorld.xp = true, true, 750
    aliceEvent("ADDON_LOADED", "LockInTools")
    bobEvent("ADDON_LOADED", "LockInTools")
    assert(not alice:IsDataConnected() and not bob:IsDataConnected()
        and #aliceWorld.statusSends == 0 and #bobWorld.statusSends == 0)
    aliceEvent("PLAYER_LOGIN")
    bobEvent("PLAYER_LOGIN")
    assert(alice:IsDataConnected() and bob:IsDataConnected()
        and not alice.dataState.channelConnected and not bob.dataState.channelConnected
        and #aliceWorld.dataJoinCalls == 1 and #bobWorld.dataJoinCalls == 1,
        "Party and guild start all status providers without waiting for global membership")
    assert(alice:GetGroupFingerprint() ~= bob:GetGroupFingerprint(),
        "Native routes deliberately have no LockInTools group identification")
    local function deliver(sends, first, last, receive, sender)
        for index = first, last do
            local sent = assert(sends[index])
            receive("CHAT_MSG_ADDON", sent.prefix, sent.message, sent.distribution, sender)
        end
    end
    local function player(current, id)
        local found, count = nil, 0
        for _, row in ipairs(current:GetOverviewPlayers()) do
            count = count + 1
            if row.id == id then found = row end
        end
        return found, count
    end
    assert(#aliceWorld.statusSends == 2 and #bobWorld.statusSends == 2
        and aliceWorld.statusSends[1].distribution == "PARTY"
        and aliceWorld.statusSends[2].distribution == "GUILD"
        and aliceWorld.statusSends[1].message == aliceWorld.statusSends[2].message,
        "Every native route carries the same initial request ID and snapshot")
    deliver(aliceWorld.statusSends, 1, 2, bobEvent, "Alice")
    deliver(bobWorld.statusSends, 1, 2, aliceEvent, "Bob")
    assert(#aliceWorld.statusSends == 4 and #bobWorld.statusSends == 4,
        "A request arriving on party and guild produces one reply fanned out over both routes")
    deliver(aliceWorld.statusSends, 3, 4, bobEvent, "Alice")
    deliver(bobWorld.statusSends, 3, 4, aliceEvent, "Bob")
    local bobRow, aliceCount = player(alice, "bob-testrealm")
    local aliceRow, bobCount = player(bob, "alice-testrealm")
    assert(aliceCount == 2 and bobCount == 2 and bobRow.online and aliceRow.online
        and bobRow.xp == 750 and aliceRow.xp == 125
        and alice:GetGroupBurnedStatus().count == 2 and alice:GetGroupBurnedStatus().average == 50
        and bob:GetGroupBurnedStatus().count == 2 and bob:GetGroupBurnedStatus().average == 50
        and alice:GetSharedPositions()["bob-testrealm"].class == "HUNTER",
        "Different keys still exchange XP, class, positions and Burned without double-counting")

    local rosterChanges, burnedChanges, positionChanges = 0, 0, 0
    alice:RegisterNotification("ROSTER_CHANGED", function() rosterChanges = rosterChanges + 1 end)
    alice:RegisterNotification("BURNED_CHANGED", function() burnedChanges = burnedChanges + 1 end)
    alice:RegisterNotification("POSITIONS_CHANGED", function() positionChanges = positionChanges + 1 end)
    bobWorld.xp = 925
    assert(bob:SetBurnedStatus(90))
    bobWorld:advance(5)
    deliver(bobWorld.statusSends, 5, 6, aliceEvent, "Bob")
    bobRow, aliceCount = player(alice, "bob-testrealm")
    assert(bobRow.xp == 925 and aliceCount == 2
        and alice:GetGroupBurnedStatus().count == 2 and alice:GetGroupBurnedStatus().average == 55
        and rosterChanges == 1 and burnedChanges == 1 and positionChanges == 1,
        "Duplicate broadcasts update the complete status and its embedded position once")
    bobEnvironment.C_Map.GetPlayerMapPosition = function()
        return { GetXY = function() return 0.6, 0.2 end }
    end
    bobWorld:advance(1)
    assert(#bobWorld.dataSends == 2 and bobWorld.dataSends[1].message == bobWorld.dataSends[2].message)
    deliver(bobWorld.dataSends, 1, 2, aliceEvent, "Bob")
    assert(alice:GetSharedPositions()["bob-testrealm"].x == 0.6 and positionChanges == 2
        and alice:GetGroupBurnedStatus().count == 2,
        "Duplicate movement reports retain one position and do not affect status counts")

    assert(alice:RegisterDataRequest("probe", function() return "own" end, function() end))
    local accepted, requestID = alice:RequestData("probe", "pending")
    assert(accepted)
    local state = alice.dataState
    local session, received, pending = state.status.session, state.status.received, state.pendingRequests[requestID]
    local peer, position = alice.burnedState.peers["bob-testrealm"], alice:GetSharedPositions()["bob-testrealm"]
    aliceWorld:completeJoin(alice:GetGroupDataChannelName(), 7)
    assert(alice:IsDataConnected() and state.routes.CHANNEL == "7"
        and state.status.session == session and state.status.received == received
        and state.pendingRequests[requestID] == pending and alice.burnedState.peers["bob-testrealm"] == peer
        and alice:GetSharedPositions()["bob-testrealm"] == position,
        "Adding global membership preserves live providers, wire ordering and pending requests")
    aliceWorld:notice("WRONG_PASSWORD", alice:GetGroupDataChannelName())
    assert(alice:IsDataConnected() and not state.routes.CHANNEL and state.phase == "error"
        and state.status.session == session and state.status.received == received
        and state.pendingRequests[requestID] == pending and alice.burnedState.peers["bob-testrealm"] == peer
        and alice:GetGroupBurnedStatus().average == 55,
        "A global-channel failure leaves native delivery, pending requests and live Burned intact")

    aliceWorld.grouped, aliceWorld.raid = false, true
    bobWorld.grouped, bobWorld.raid = false, true
    aliceEvent("GROUP_ROSTER_UPDATE")
    bobEvent("GROUP_ROSTER_UPDATE")
    assert(state.routes.RAID and state.routes.GUILD and not state.routes.PARTY
        and state.status.session == session and state.pendingRequests[requestID] == pending)
    bobWorld.xp = 975
    local firstRaid = #bobWorld.statusSends + 1
    bobWorld:advance(4)
    assert(bobWorld.statusSends[firstRaid].distribution == "RAID")
    deliver(bobWorld.statusSends, firstRaid, #bobWorld.statusSends, aliceEvent, "Bob")
    assert(player(alice, "bob-testrealm").xp == 975 and alice:GetGroupBurnedStatus().count == 2,
        "Party-to-raid changes send and receive status without resetting other routes")
    aliceWorld.guild = false
    aliceEvent("PLAYER_GUILD_UPDATE", "player")
    assert(state.routes.RAID and not state.routes.GUILD and alice:IsDataConnected())
    aliceWorld.raid = false
    aliceEvent("GROUP_ROSTER_UPDATE")
    assert(not alice:IsDataConnected() and next(state.pendingRequests) == nil
        and alice:GetGroupBurnedStatus().count == 0,
        "Losing every native route during global failure disconnects and retires live state")
    aliceWorld.guild = true
    aliceEvent("PLAYER_GUILD_UPDATE", "player")
    assert(alice:IsDataConnected() and state.routes.GUILD and not state.routes.RAID
        and state.status.session ~= session and alice:GetGroupBurnedStatus().count == 1)
    local fresh = bobWorld.statusSends[firstRaid]
    aliceEvent("CHAT_MSG_ADDON", fresh.prefix, fresh.message, "GUILD", "Bob")
    assert(player(alice, "bob-testrealm").xp == 975 and alice:GetGroupBurnedStatus().count == 2,
        "Guild membership restores full native status reception while global recovery continues")
    assert(#aliceWorld.notificationErrors == 0 and #bobWorld.notificationErrors == 0)
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


-- Burned status is account-wide, editable without a connection, and protected
-- by the same newer-schema rules as the other saved preferences.
do
    local current, _, _, event, clock = loadAddon(settings("", false), false)
    assert(current:GetBurnedStatus() == 0 and not current:SetBurnedStatus(20))
    event("ADDON_LOADED", "LockInTools")
    local changes = 0
    current:RegisterNotification("BURNED_CHANGED", function() changes = changes + 1 end)
    assert(current:GetBurnedStatus() == 0 and current.db.burned.status == 0)
    assert(current:SetBurnedStatus(64.6) and current:GetBurnedStatus() == 65)
    assert(current:SetBurnedStatus(65) and changes == 1,
        "Rounding a drag to the saved integer must not cause duplicate updates")
    for _, invalid in ipairs({ -1, 101, 0 / 0, math.huge, "50", false, {} }) do
        assert(not current:SetBurnedStatus(invalid) and current:GetBurnedStatus() == 65)
    end
    assert(current:SetBurnedStatus(0) and current:SetBurnedStatus(100))
    event("PLAYER_LOGIN")
    clock:advance(30)
    assert(current.db.burned.status == 100 and #clock.dataJoinCalls == 0 and #clock.statusSends == 0
        and current:GetGroupBurnedStatus().count == 0,
        "A personal preference without a group must not initiate traffic or invent a group average")
    local reloaded, _, _, _, reloadClock = loadAddon(current.db, false)
    reloadClock:initialize()
    assert(reloaded:GetBurnedStatus() == 100, "The personal burned status survives account-wide reloads")
    local malformed = settings("", false)
    malformed.burned = { status = 150, future = "preserved" }
    local repaired, _, _, _, repairClock = loadAddon(malformed, false)
    repairClock:initialize()
    assert(repaired:GetBurnedStatus() == 0 and malformed.burned.status == 0
        and malformed.burned.future == "preserved")
    local newer = settings()
    newer.schemaVersion, newer.burned = 4, { status = 73, future = "untouched" }
    local future, _, _, _, futureClock = loadAddon(newer, false)
    futureClock:initialize()
    assert(future:GetBurnedStatus() == 73 and not future:SetBurnedStatus(25)
        and newer.burned.status == 73 and newer.burned.future == "untouched"
        and future:GetGroupBurnedStatus().average == nil and future:GetGroupBurnedStatus().count == 0)
    futureClock:advance(30)
    assert(#futureClock.statusSends == 0 and #futureClock.dataJoinCalls == 0,
        "Newer-schema status stays readable without modifying or transmitting the original preferences")
end

assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep test environments isolated")
print("PASS: production data startup, preferences, routing and recovery")
