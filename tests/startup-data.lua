-- This harness is never loaded by the addon.
local fixtures = dofile("tests/support/addon.lua")
local loadAddon = fixtures.loadAddon
local settings = fixtures.settings
local contains = fixtures.contains
local SECRET = fixtures.SECRET
local OTHER_SECRET = fixtures.OTHER_SECRET
local isRosterMessage = fixtures.isRosterMessage
local isStatusMessage = fixtures.isStatusMessage

-- Production startup connects shared data independently of human chat and position preferences.
do
    local connected, connectedEnvironment, connectedMessages, connectedEvent, connectedWorld =
        loadAddon(settings(nil, false), false)
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
        and presence.message:match("^1|Q|status|[^|]+|3|F|[^|]+|%d+|%d+|")
        and presence.message:find("|1=12", 1, true) and presence.message:find("|2=0", 1, true)
        and presence.message:find("|3=1000", 1, true) and presence.message:find("|4=known", 1, true)
        and presence.message:find("|5=false", 1, true) and presence.message:find("|6=false", 1, true)
        and presence.message:find("|7=false", 1, true) and presence.message:find("|8=false", 1, true)
        and not presence.message:match("|[%a_][%w_]*=")
        and #connectedWorld.rosterSends == 0,
        "production startup shares numeric v3 level, XP and party metadata once without named fields or roster packets")
    connectedEvent("CHAT_MSG_ADDON", presence.prefix, presence.message, "CHANNEL", "RosterFriend", nil, 0, 7, dataRoom)
    local rosterFriend
    for _, player in ipairs(connected:GetOverviewPlayers()) do
        if player.id == "rosterfriend-testrealm" then rosterFriend = player end
    end
    assert(rosterFriend and rosterFriend.online and rosterFriend.level == 12 and not rosterFriend.map
        and connected.db.roster.peers["rosterfriend-testrealm"],
        "production shared-status delivery discovers and retains peers while position sharing is off")
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
        and sent.message:find("1|position|1|P|", 1, true) == 1)
    connectedEvent("CHAT_MSG_ADDON", sent.prefix, sent.message, "CHANNEL", "Self", nil, 0, 7, dataRoom)
    assert(next(connected:GetSharedPositions()) == nil, "production route excludes own position echoes")
    connectedEvent("CHAT_MSG_ADDON", sent.prefix, sent.message, "CHANNEL", "Friend", nil, 0, 7, dataRoom)
    assert(connected:GetSharedPositions()["friend-testrealm"].online
        and connected.db.position.peers["friend-testrealm"], "production route delivers and retains peer positions")
    connectedEvent("CHAT_MSG_ADDON", sent.prefix, sent.message, "CHANNEL", "NameOnly", nil, 0, nil, dataRoom:lower())
    connectedEvent("CHAT_MSG_ADDON", sent.prefix, sent.message, "CHANNEL", "AliasOnly", nil, 0, nil, "LockInTools Data")
    assert(connected:GetSharedPositions()["nameonly-testrealm"]
        and not connected:GetSharedPositions()["aliasonly-testrealm"],
        "name-only position routing uses the actual channel name, never the display alias")
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
    local switchedSend = assert(connectedWorld.dataSends[3], "positions resume automatically after the new group joins")
    assert(switchedSend.target == "18"
        and connectedEnvironment.ChatFrameUtil.ResolvePrefixedChannelName("18. " .. newDataRoom)
            == "18. LockInTools Data", "positions use the new native number while the readable alias stays the same")
    connectedEvent("CHAT_MSG_ADDON", switchedSend.prefix, switchedSend.message, "CHANNEL", "OldRoute", nil, 0, 14, dataRoom)
    connectedEvent("CHAT_MSG_ADDON", switchedSend.prefix, switchedSend.message, "CHANNEL", "NewFriend", nil, 0, 18, newDataRoom)
    assert(not connected:GetSharedPositions()["oldroute-testrealm"]
        and connected:GetSharedPositions()["newfriend-testrealm"].online
        and connected.db.position.peers["newfriend-testrealm"],
        "alias-enabled group switching rejects old position packets and accepts the new group's updates")
    assert(not contains(connectedMessages, SECRET) and not contains(connectedMessages, OTHER_SECRET))
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
    assert(#received == 2 and received[1].sender == "NumberPeer" and received[2].sender == "NamePeer"
        and received[1].payload == "current-state",
        "feature-only delivery accepts the current number or native name and rejects aliases and old numbers")
    resumedWorld.channels[dataRoom:lower()] = nil
    resumedWorld:notice("YOU_LEFT", dataRoom, 14)
    resumedWorld:advance(1)
    assert(#resumedWorld.dataJoinCalls == 3 and not resumed:IsDataConnected(),
        "native data leave reconnects without any position sampling or settings save")
    resumedWorld:completeJoin(dataRoom, 18)
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
    local timer, generation = state.timer, state.generation
    assert(state.pending and state.attempts == 1 and timer)
    assert(pending:SetPositionSharing(true))
    assert(#pendingWorld.dataJoinCalls == 1 and state.attempts == 1
        and state.timer == timer and state.generation == generation and not timer:IsCancelled(),
        "enabling positions does not duplicate or reset an in-progress startup join")
    pendingWorld:advance(2)
    timer, generation = state.timer, state.generation
    assert(state.attempts == 2 and #pendingWorld.dataJoinCalls == 2)
    assert(pending:SetPositionSharing(true))
    assert(#pendingWorld.dataJoinCalls == 2 and state.attempts == 2
        and state.timer == timer and state.generation == generation and not timer:IsCancelled(),
        "re-saving enabled sharing preserves the current shared retry delay")
    pendingWorld:completeJoin(pending:GetGroupDataChannelName(), 7)
    local send = state.send
    assert(pending:SetPositionSharing(true))
    assert(#pendingWorld.dataJoinCalls == 2 and state.send == send and pending:IsDataConnected(),
        "saving enabled sharing leaves a connected data transport intact")
    assert(pending:SetGroupSecret(OTHER_SECRET))
    timer, generation = state.timer, state.generation
    assert(not state.pending and timer and not pending:IsDataConnected())
    assert(pending:SetPositionSharing(true))
    assert(#pendingWorld.dataJoinCalls == 2 and state.timer == timer
        and state.generation == generation and not timer:IsCancelled(),
        "saving enabled sharing preserves the delayed group-switch connection check")
    pendingWorld:advance(1)
    assert(#pendingWorld.dataJoinCalls == 3
        and pendingWorld.dataJoinCalls[3] == pending:GetGroupDataChannelName(),
        "the existing delayed check joins the newly selected group once")
    local alternateSends = 0
    local alternate = function(_, message)
        if not isRosterMessage(message) and not isStatusMessage(message) then alternateSends = alternateSends + 1 end
        return true
    end
    assert(pending:SetDataTransport(alternate))
    assert(pending:SetPositionSharing(true))
    pendingWorld:advance(2)
    assert(pending:IsDataConnected() and state.send == alternate and alternateSends == 1
        and #pendingWorld.dataJoinCalls == 3,
        "saving enabled sharing preserves an existing alternate transport and uses it for positions")
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

-- Recoverable native API failures recover on their own; leaving the group or logging out stops retries.
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
    assert(#apiWorld.dataJoinCalls == 1,
        "native API recovery retries automatically even with position sharing disabled")
    assert(unavailable:LeaveGroup())
    apiWorld:advance(90)
    assert(#apiWorld.dataJoinCalls == 1 and not unavailable:IsDataConnected(),
        "group leave cancels pending shared-data retries")

    local stopped, _, _, stoppedEvent, stoppedWorld = loadAddon(settings(nil, false), false)
    stoppedWorld:initialize()
    stoppedEvent("PLAYER_LOGOUT")
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
    assert(not future:SetShowPositionTrails(false))
    assert(future:GetShowPositionTrails() == true
        and futureSettings.position.showTrails == "future-trails"
        and futureSettings.position.trailLength == "future-length",
        "Read-only startup uses safe trail defaults without repairing the original newer-schema data")
    futureWorld:advance(30)
    assert(not futureSettings.position.sharing and #futureWorld.dataJoinCalls == 0
        and #futureWorld.dataSends == 0, "read-only preferences cannot enable sharing or reconnect data")
end


assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep test environments isolated")
print("PASS: production data startup, preferences, routing and recovery")
