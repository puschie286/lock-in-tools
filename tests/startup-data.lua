-- This harness is never loaded by the addon.
local fixtures = dofile("tests/support/addon.lua")
local loadAddon = fixtures.loadAddon
local settings = fixtures.settings
local contains = fixtures.contains
local SECRET = fixtures.SECRET
local OTHER_SECRET = fixtures.OTHER_SECRET

-- Saved peer identities remain usable before the realm APIs return login data.
do
    local seed, _, _, seedEvent = loadAddon(settings(nil, false), false)
    seedEvent("ADDON_LOADED", "LockInTools")
    local fingerprint = seed:GetGroupFingerprint()
    local stamp = 1999999800
    local expected = { "rosteronly-testrealm", "shared-testrealm", "qualified-remoterealm",
        "positiononly-testrealm", "self-pastrealm" }
    for _, scenario in ipairs({
        { realm = false, loginRealm = "TestRealm", label = "unavailable realm" },
        { realm = "", loginRealm = "TestRealm", label = "empty realm" },
        { realm = "OtherRealm", loginRealm = "OtherRealm", label = "another current realm" },
    }) do
        local profile = settings(nil, false)
        profile.roster = { groupFingerprint = fingerprint, peers = {
            ["rosteronly-testrealm"] = { name = "RosterOnly", level = 21, seenAt = stamp },
            ["shared-testrealm"] = { name = "Shared", level = 32, seenAt = stamp },
            ["qualified-remoterealm"] = { name = "Qualified-Remote Realm", level = 43, seenAt = stamp },
            ["self-pastrealm"] = { name = "Self", level = 54, seenAt = stamp },
        } }
        profile.position = { sharing = true, keepLastKnown = true, groupFingerprint = fingerprint, peers = {
            ["shared-testrealm"] = { name = "Shared", map = 37, x = 0.2, y = 0.3,
                stamp = stamp, positionStamp = stamp - 10, class = "HUNTER" },
            ["positiononly-testrealm"] = { name = "PositionOnly", map = 37, x = 0.4, y = 0.5,
                stamp = stamp, positionStamp = stamp - 20, class = "MAGE" },
            ["qualified-remoterealm"] = { name = "Qualified-Remote Realm", map = 37, x = 0.8, y = 0.9,
                stamp = stamp, positionStamp = stamp - 30, class = "PRIEST" },
            ["self-pastrealm"] = { name = "Self", map = 37, x = 0.6, y = 0.7, stamp = stamp },
        } }
        for reload = 1, 2 do
            local restored, environment, _, event, world = loadAddon(profile, false)
            local realm = scenario.realm or nil
            environment.GetNormalizedRealmName = function() return realm end
            environment.UnitFullName = function(unit)
                assert(unit == "player")
                return "Self", realm
            end
            event("ADDON_LOADED", "LockInTools")
            assert(restored.rosterState.peers["rosteronly-testrealm"]
                and restored.rosterState.peers["shared-testrealm"]
                and restored.rosterState.peers["qualified-remoterealm"]
                and restored.rosterState.peers["self-pastrealm"],
                scenario.label .. ": ADDON_LOADED retains roster history on reload " .. reload)
            assert(restored.positionState.peers["shared-testrealm"]
                and restored.positionState.peers["positiononly-testrealm"]
                and restored.positionState.peers["qualified-remoterealm"]
                and restored.positionState.peers["self-pastrealm"],
                scenario.label .. ": ADDON_LOADED retains saved positions on reload " .. reload)
            realm = scenario.loginRealm
            event("PLAYER_LOGIN")
            local function CheckOverview()
                local rows, byID = restored:GetOverviewPlayers(), {}
                for _, row in ipairs(rows) do byID[row.id] = row end
                assert(#rows == #expected + 1 and byID[("Self-" .. realm):lower()].isSelf,
                    scenario.label .. ": login restores every historical peer alongside the current character")
                for _, id in ipairs(expected) do
                    local row = assert(byID[id], scenario.label .. ": missing retained peer " .. id)
                    assert(not row.online and not row.isSelf and row.xpState == "unavailable",
                        "restored history stays offline without inventing live progress")
                    assert(row.name:lower():gsub("%s", "") == id,
                        "restored peer names retain their saved realm for self filtering")
                end
                assert(byID["rosteronly-testrealm"].level == 21 and not byID["rosteronly-testrealm"].map
                    and byID["qualified-remoterealm"].level == 43 and byID["qualified-remoterealm"].x == 0.8,
                    "bare and qualified roster-only history preserve levels")
                assert(byID["shared-testrealm"].level == 32 and byID["shared-testrealm"].x == 0.2
                    and byID["shared-testrealm"].positionStamp == stamp - 10
                    and byID["positiononly-testrealm"].x == 0.4
                    and byID["positiononly-testrealm"].positionStamp == stamp - 20
                    and not byID["positiononly-testrealm"].positionAvailable,
                    "merged and position-only history preserve coordinates and their actual age")
                assert(restored:GetSharedPositions()["shared-testrealm"].class == "HUNTER"
                    and restored:GetSharedPositions()["positiononly-testrealm"].class == "MAGE",
                    "restored positions retain saved classes")
            end
            CheckOverview()
            world:completeJoin(restored:GetGroupDataChannelName(), 7)
            CheckOverview()
            environment.SlashCmdList.LOCKINTOOLS("data leave")
            world:advance(1)
            world:completeJoin(restored:GetGroupDataChannelName(), 14)
            world:advance(90)
            CheckOverview()
            assert(#world.rosterSends == 0, "history restoration needs no roster discovery packets")
            event("PLAYER_LOGOUT")
            profile = restored.db
        end
    end
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
        and presence.message:match("^1|Q|status|[^|]+|5|F|[^|]+|%d+|%d+|")
        and presence.message:find("|1=12", 1, true) and presence.message:find("|2=0", 1, true)
        and presence.message:find("|3=1000", 1, true) and presence.message:find("|4=1", 1, true)
        and presence.message:find("|8=0", 1, true) and presence.message:find("|10=0", 1, true)
        and presence.message:find("|11=7", 1, true) and not presence.message:find("|9=", 1, true)
        and not presence.message:match("|[567]=")
        and not presence.message:match("|[%a_][%w_]*=")
        and #connectedWorld.rosterSends == 0,
        "production startup shares compact v5 player metadata once without retired fields or roster packets")
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
    assert(not connected.dataState.requests["position-class"], "production registers no separate class discovery")
    assert(connectedEnvironment.ChatFrameUtil.ResolvePrefixedChannelName("7. " .. dataRoom)
        == "7. LockInTools Data" and connected:GetGroupDataChannelName() == dataRoom,
        "the data alias changes its displayed label while retaining the native route")
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
    connectedEvent("CHAT_MSG_ADDON", sent.prefix, sent.message, "CHANNEL", "NameOnly", nil, 0, nil, dataRoom:lower())
    connectedEvent("CHAT_MSG_ADDON", sent.prefix, sent.message, "CHANNEL", "AliasOnly", nil, 0, nil, "LockInTools Data")
    assert(connected:GetSharedPositions()["nameonly-testrealm"]
        and connected:GetSharedPositions()["aliasonly-testrealm"],
        "valid position payloads are accepted independently of native or display channel names")
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
    assert(connectedEnvironment.ChatFrameUtil.ResolvePrefixedChannelName("14. " .. dataRoom)
        == "14. LockInTools Data", "renumbering preserves the readable data label")
    connectedWorld.fire("PLAYER_ENTERING_WORLD")
    connectedWorld.fire("UPDATE_CHAT_WINDOWS")
    connectedWorld:advance(0)
    assert(connected:IsDataConnected() and connectedWorld.channels[dataRoom:lower()],
        "automatic old-channel cleanup preserves the current aliased position transport")
    connectedWorld:restore("Unrelated", 19)
    assert(connected:SetGroupSecret(OTHER_SECRET))
    assert(connected:IsGroupSwitching() and not connected:IsDataConnected()
        and connected:GetGroupDataChannelName() == dataRoom, "group activation waits for the current callback")
    connectedWorld:advance(0)
    assert(not connected:IsDataConnected() and next(connected.db.position.peers) == nil
        and next(connected:GetSharedPositions()) == nil and not connectedWorld.channels[dataRoom:lower()],
        "group switching disconnects old data before clearing feature caches")
    connectedWorld:advance(1)
    assert(connectedWorld.dataJoinCalls[3] == connected:GetGroupDataChannelName()
        and connectedWorld.channels.unrelated and not connected.db.chat.autoJoin,
        "group switching reconnects data without changing chat preferences or unrelated channels")
    local newDataRoom = connected:GetGroupDataChannelName()
    connectedWorld:completeJoin(newDataRoom, 18)
    connectedWorld:completeJoin(dataRoom, 14)
    assert(connected:IsDataConnected() and not connectedWorld.channels[dataRoom:lower()],
        "a late old-channel join cannot disconnect the new position transport")
    connectedWorld:advance(1)
    local switchedSend = assert(connectedWorld.statusSends[#connectedWorld.statusSends],
        "the initial new-group status supplies the resumed position")
    assert(switchedSend.target == "18" and switchedSend.message:find("|9=P,37,25000,75000", 1, true)
        and #connectedWorld.dataSends == 2
        and connectedEnvironment.ChatFrameUtil.ResolvePrefixedChannelName("18. " .. newDataRoom)
            == "18. LockInTools Data",
        "the new-group snapshot uses the new route and suppresses a duplicate stationary position broadcast")
    connectedEvent("CHAT_MSG_ADDON", switchedSend.prefix, switchedSend.message, "CHANNEL", "OldRoute", nil, 0, 14, dataRoom)
    connectedEvent("CHAT_MSG_ADDON", switchedSend.prefix, switchedSend.message, "CHANNEL", "NewFriend", nil, 0, 18, newDataRoom)
    assert(connected:GetSharedPositions()["oldroute-testrealm"].online
        and connected:GetSharedPositions()["newfriend-testrealm"].online
        and connected.db.position.peers["newfriend-testrealm"],
        "after reconnection, valid position packets do not depend on current channel metadata")
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

-- Every shared feature recovers independently of human chat and position preferences.
do
    local resumed, resumedEnvironment, _, resumedEvent, resumedWorld = loadAddon(settings(nil, false), false)
    resumedWorld:initialize()
    local dataRoom = resumed:GetGroupDataChannelName()
    local received, connections = {}, {}
    assert(resumed:RegisterDataFeature("future", function(sender, payload)
        received[#received + 1] = { sender = sender, payload = payload }
        return true
    end, function(connected) connections[#connections + 1] = connected end))
    resumedWorld:completeJoin(dataRoom, 7)
    local resumedCommand = resumedEnvironment.SlashCmdList.LOCKINTOOLS
    resumedCommand("data leave")
    local timer = assert(resumed.dataState.timer)
    for _ = 1, 12 do
        resumedEvent("PLAYER_ENTERING_WORLD")
        resumedEvent("CHANNEL_UI_UPDATE")
        resumedWorld:notice("YOU_LEFT", dataRoom)
    end
    assert(not resumed:IsDataConnected() and not resumed.db.position.sharing
        and not resumed.db.chat.autoJoin and #resumedWorld.joinCalls == 0
        and resumed.dataState.timer == timer and not timer:IsCancelled(),
        "repeated leave and world events preserve one scheduled shared-data reconnect")
    resumedWorld:advance(1)
    assert(#resumedWorld.dataJoinCalls == 2)
    resumedWorld:completeJoin(dataRoom, 14)
    assert(resumed:IsDataConnected() and not resumed.db.position.sharing
        and #resumedWorld.dataSends == 0 and #resumedWorld.joinCalls == 0
        and connections[#connections] == true,
        "manual data leave reconnects every feature without enabling positions or human chat")
    timer = assert(resumed.dataState.timer)
    for _ = 1, 12 do
        resumedEvent("PLAYER_ENTERING_WORLD")
        resumedEvent("CHANNEL_UI_UPDATE")
    end
    assert(resumed.dataState.timer == timer and not timer:IsCancelled()
        and #resumedWorld.dataJoinCalls == 2,
        "healthy channel events preserve one watchdog without scheduling duplicate joins")
    assert(resumed:SendData("future", "current-state"))
    local sent = assert(resumedWorld.dataSends[1])
    assert(sent.target == "14" and sent.message == "1|future|current-state"
        and resumedEnvironment.ChatFrameUtil.ResolvePrefixedChannelName("14. " .. dataRoom)
            == "14. LockInTools Data", "future features send through the current aliased native route")
    resumedEvent("CHAT_MSG_ADDON", sent.prefix, sent.message, "CHANNEL", "NumberPeer", nil, 0, 14, dataRoom)
    resumedEvent("CHAT_MSG_ADDON", sent.prefix, sent.message, "CHANNEL", "NamePeer", nil, 0, nil, dataRoom:lower())
    resumedEvent("CHAT_MSG_ADDON", sent.prefix, sent.message, "CHANNEL", "AliasPeer", nil, 0, nil, "LockInTools Data")
    resumedEvent("CHAT_MSG_ADDON", sent.prefix, sent.message, "CHANNEL", "OldPeer", nil, 0, 7, dataRoom)
    assert(#received == 4 and received[1].sender == "NumberPeer" and received[2].sender == "NamePeer"
        and received[3].sender == "AliasPeer" and received[4].sender == "OldPeer"
        and received[1].payload == "current-state",
        "feature-only delivery validates payloads independently of channel names and numbers")
    resumedWorld.channels[dataRoom:lower()] = nil
    resumedWorld:notice("YOU_LEFT", dataRoom, 14)
    resumedWorld:advance(1)
    assert(#resumedWorld.dataJoinCalls == 3 and not resumed:IsDataConnected(),
        "native data leave reconnects without any position sampling or settings save")
    resumedWorld:completeJoin(dataRoom, 18)
    resumedWorld:advance(0.5) -- Finish initial guide discovery before testing an idle channel.
    assert(resumed:SendData("future", "new-state") and resumedWorld.dataSends[2].target == "18",
        "automatic reconnection refreshes the channel number for future features")
    resumedWorld.channels[dataRoom:lower()] = nil
    resumedWorld:advance(15)
    assert(not resumed:IsDataConnected() and #resumedWorld.dataJoinCalls == 4,
        "the shared watchdog reconnects a silent membership loss while all feature ticks are idle")
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

-- Failed shared joins retry indefinitely at a capped pace without feature involvement.
do
    local failed, _, _, failedEvent, failedWorld = loadAddon(settings(nil, false), false)
    failedWorld:initialize()
    local dataRoom = failed:GetGroupDataChannelName()
    failedWorld:notice("WRONG_PASSWORD", dataRoom)
    local timer = assert(failed.dataState.timer)
    assert(failed:SetPositionSharing(true))
    for _ = 1, 12 do
        failedEvent("PLAYER_ENTERING_WORLD")
        failedEvent("CHANNEL_UI_UPDATE")
        failedWorld:notice("WRONG_PASSWORD", dataRoom)
    end
    assert(#failedWorld.dataJoinCalls == 1 and failed.dataState.timer == timer and not timer:IsCancelled(),
        "settings saves and event storms do not bypass or restart the shared error delay")
    failedWorld:advance(29)
    assert(#failedWorld.dataJoinCalls == 1 and #failedWorld.dataSends == 0,
        "terminal join failures wait thirty seconds before reconnecting")
    failedWorld:advance(1)
    assert(#failedWorld.dataJoinCalls == 2,
        "terminal join failures retry automatically without an explicit data join")
    failedWorld:notice("BANNED", dataRoom)
    failedWorld:advance(30)
    assert(#failedWorld.dataJoinCalls == 3,
        "repeated terminal errors continue using the capped shared retry delay")
    assert(failed:SetPositionSharing(false))
    failedWorld:advance(150)
    assert(#failedWorld.dataJoinCalls >= 8 and #failedWorld.dataJoinCalls <= 12
        and #failedWorld.dataSends == 0 and not failed.db.position.sharing,
        "unanswered data joins continue at a bounded rate after the old attempt limit with positions off")
    failedWorld:completeJoin(dataRoom, 7)
    assert(failed:IsDataConnected(), "eventual membership succeeds after repeated shared-data failures")
end

-- Native API availability is fixed at initialization; group leave and logout stop retries.
do
    local unavailable, api, _, _, apiWorld = loadAddon(settings(nil, false), false)
    local join = api.JoinTemporaryChannel
    api.JoinTemporaryChannel = nil
    apiWorld:initialize()
    assert(not unavailable:IsDataConnected() and #apiWorld.dataJoinCalls == 0 and unavailable.dataState.timer)
    api.JoinTemporaryChannel = join
    apiWorld:advance(29)
    assert(#apiWorld.dataJoinCalls == 0)
    apiWorld:advance(1)
    assert(#apiWorld.dataJoinCalls == 0 and not unavailable:IsDataConnected(),
        "restoring an API does not change the capability captured at initialization")
    assert(unavailable:LeaveGroup())
    apiWorld:advance(90)
    assert(#apiWorld.dataJoinCalls == 0 and not unavailable:IsDataConnected(),
        "group leave cancels pending shared-data retries")

    local reloaded, _, _, _, reloadWorld = loadAddon(settings(nil, false), false)
    reloadWorld:initialize()
    assert(#reloadWorld.dataJoinCalls == 1, "fresh initialization discovers available native APIs")
    reloadWorld:completeJoin(reloaded:GetGroupDataChannelName(), 7)
    assert(reloaded:IsDataConnected())

    local stopped, _, _, stoppedEvent, stoppedWorld = loadAddon(settings(nil, false), false)
    stoppedWorld:initialize()
    stoppedEvent("PLAYER_LOGOUT")
    assert(stopped.dataState.stopped and stopped.rosterState.stopped,
        "independent data and roster logout owners both receive the shared native event")
    stoppedEvent("PLAYER_ENTERING_WORLD")
    stoppedWorld:advance(90)
    assert(#stoppedWorld.dataJoinCalls == 1 and not stopped:IsDataConnected(),
        "logout cancels pending retries and world events cannot restart them")
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
