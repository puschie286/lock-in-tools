-- This harness is never loaded by the addon.
local fixtures = dofile("tests/support/addon.lua")
local loadAddon = fixtures.loadAddon
local settings = fixtures.settings
local contains = fixtures.contains
local SECRET = fixtures.SECRET
local OTHER_SECRET = fixtures.OTHER_SECRET

-- Matching group secrets derive one room and password; membership is asynchronous.
local chatAddon, _, chatMessages, _, chatWorld = loadAddon(settings(), false)
chatWorld:initialize()
local room = chatAddon:GetGroupChannelName()
assert(#chatWorld.joinCalls == 0, "allow native membership restoration before joining")
chatWorld:advance(2)
assert(#chatWorld.joinCalls == 1 and chatWorld.joinCalls[1] == room)
assert(chatWorld.lastJoinPassword == chatAddon:GetGroupChannelPassword())
chatWorld:completeJoin(room, 5)
chatWorld.fire("CHANNEL_UI_UPDATE")
chatWorld:notice("YOU_JOINED", room, 5)
assert(#chatWorld.addCalls == 1, "attach native channel to chat once")
chatWorld:advance(120)
assert(#chatWorld.joinCalls == 1, "confirmed membership stops retries")
chatWorld:restore(room, 8)
chatAddon:OpenChatInput()
assert(#chatWorld.openedChat == 0, "defer composer until native slash handling finishes")
chatWorld:advance(0)
assert(#chatWorld.openedChat == 1 and chatWorld.editBox.channelTarget == room)
assert(chatWorld.editBox.chatType == "CHANNEL")
chatWorld.roster = {
    { name = "General", header = false, id = 1, members = {} },
    { name = room, header = false, id = 8, members = {
        { name = "Friend", owner = true, moderator = false, guid = "Player-Test-Friend" },
        { name = "Self", owner = false, moderator = false, guid = "Player-Test-Self" },
    } },
}
chatWorld.fire("CHANNEL_ROSTER_UPDATE", 2)
assert(#chatWorld.passwordCalls == 0, "ordinary member must not change passwords")
chatWorld.roster[2].members[2].owner = true
chatWorld.fire("CHANNEL_ROSTER_UPDATE", 2)
assert(#chatWorld.passwordCalls == 1 and chatWorld.passwordCalls[1].name == room)
assert(chatWorld.passwordCalls[1].password == chatAddon:GetGroupChannelPassword(),
    "owner installs derived password after asynchronous roster arrives")
chatWorld.fire("CHANNEL_ROSTER_UPDATE", 2)
assert(#chatWorld.passwordCalls == 1, "do not repeat password changes on roster updates")
assert(not contains(chatMessages, SECRET) and not contains(chatMessages, chatAddon:GetGroupChannelPassword()))
local restoredAddon, _, _, _, restoredWorld = loadAddon(settings(), false)
restoredWorld:restore(room:lower(), 4)
restoredWorld:initialize()
restoredWorld:advance(20)
assert(#restoredWorld.joinCalls == 0 and #restoredWorld.addCalls == 1)
assert(restoredAddon:GetChatStatusText():find("Joined", 1, true))

-- Feature settings and channel leaves retain shared group identity.
local manual, manualEnvironment, _, _, manualWorld = loadAddon(settings(nil, false), false)
manualWorld:initialize()
manualWorld:advance(30)
manualWorld.fire("PLAYER_ENTERING_WORLD", true, false)
manualWorld:advance(30)
assert(#manualWorld.joinCalls == 0)
manualEnvironment.SlashCmdList.LOCKINTOOLS("join")
assert(#manualWorld.joinCalls == 1)
manualWorld:completeJoin(room, 3)
manualEnvironment.SlashCmdList.LOCKINTOOLS("chat")
manualWorld:advance(0)
assert(#manualWorld.openedChat == 1)
manualEnvironment.SlashCmdList.LOCKINTOOLS("leave")
assert(#manualWorld.leaveCalls == 1 and manual:HasGroup() and manual:GetGroupSecret() == SECRET)
manualWorld.fire("PLAYER_ENTERING_WORLD", false, false)
manualWorld:advance(120)
assert(#manualWorld.joinCalls == 1, "explicit leave cancels retries without clearing group")
local configured, _, _, _, configuredWorld = loadAddon(settings("", false), false)
configuredWorld:initialize()
assert(configured:SetGroupSecret(SECRET) and #configuredWorld.joinCalls == 0,
    "group configuration respects disabled chat autojoin")
assert(configured:SetChatAutoJoin(true))
assert(#configuredWorld.joinCalls == 1, "enabling applies immediately")
assert(configured:SetChatAutoJoin(false))
configuredWorld.fire("PLAYER_ENTERING_WORLD", false, false)
configuredWorld:advance(120)
assert(#configuredWorld.joinCalls == 1)
configuredWorld:completeJoin(room, 7)
assert(configured:SetChatAutoJoin(false))
assert(#configuredWorld.leaveCalls == 0 and configured:HasGroup(), "disabling preserves membership and group")
local saved, problem = configured:SetChatAutoJoin("yes")
assert(not saved and type(problem) == "string" and configured.db.chat.autoJoin == false)
for _, notice in ipairs({ "WRONG_PASSWORD", "BANNED", "YOU_KICKED" }) do
    local rejected, _, _, _, rejectedWorld = loadAddon(settings(), false)
    rejectedWorld:initialize()
    rejectedWorld:advance(2)
    rejectedWorld:notice(notice, room, 0)
    rejectedWorld.fire("PLAYER_ENTERING_WORLD", false, false)
    rejectedWorld:advance(120)
    assert(#rejectedWorld.joinCalls == 1, notice .. " stops retries")
    assert(rejected:HasGroup() and type(rejected:GetChatStatusText()) == "string")
end
local pending, _, _, _, pendingWorld = loadAddon(settings(), false)
pendingWorld:initialize()
pendingWorld:advance(2)
pending:LeaveChatChannel()
pendingWorld.fire("PLAYER_ENTERING_WORLD", false, false)
pendingWorld:advance(120)
assert(#pendingWorld.joinCalls == 1, "leave cancels unconfirmed join")
local _, _, _, _, nativeWorld = loadAddon(settings(), false)
nativeWorld:initialize()
nativeWorld:advance(2)
nativeWorld:completeJoin(room, 6)
-- WoW emits CHANNEL_LEFT before GetChannelName stops reporting membership.
nativeWorld.fire("CHANNEL_LEFT", 6, room)
nativeWorld.fire("CHANNEL_UI_UPDATE")
nativeWorld.channels[room:lower()] = nil
nativeWorld.fire("PLAYER_ENTERING_WORLD", false, false)
nativeWorld:advance(120)
assert(#nativeWorld.joinCalls == 1, "respect native channel controls")

-- Remove accumulated native memberships and saved chat-window entries at login.
do
    local cleanup, _, _, startupFire, startup = loadAddon(settings(SECRET, false), false)
    startupFire("ADDON_LOADED", "LockInTools")
    local currentChat, currentData = cleanup:GetGroupChannelName(), cleanup:GetGroupDataChannelName()
    local obsoleteChat = "lIt" .. string.rep("A", 28)
    local obsoleteData = "litDATA" .. string.rep("b", 24)
    local frameOnly = "LIT" .. string.rep("c", 28)
    local unrelated = { "General", "LITFriends", "LIT" .. string.rep("d", 27),
        "LITDATA" .. string.rep("e", 25), "LIT" .. string.rep("g", 28) }
    startup:restore(currentChat:upper(), 2)
    startup:restore(currentData:lower(), 3)
    startup:restore(obsoleteChat, 4)
    startup:restore(obsoleteData, 5)
    for index, name in ipairs(unrelated) do startup:restore(name, 10 + index) end
    local primary, secondary = startup.chatFrames[1], startup:newChatFrame()
    primary:AddChannel(currentChat:upper())
    primary:AddChannel(obsoleteChat)
    primary:AddChannel(obsoleteData)
    secondary:AddChannel(obsoleteChat:lower())
    secondary:AddChannel(frameOnly)
    secondary:AddChannel("General")
    startupFire("PLAYER_LOGIN")
    assert(not startup.channels[obsoleteChat:lower()] and not startup.channels[obsoleteData:lower()],
        "login leaves accumulated addon channels, with case-insensitive native names")
    assert(#primary.channelList == 1 and primary.channelList[1] == currentChat:upper()
        and #primary.zoneChannelList == 1 and #secondary.channelList == 1
        and secondary.channelList[1] == "General" and #secondary.zoneChannelList == 1,
        "cleanup detaches obsolete and frame-only names from every chat window")
    assert(startup.channels[currentChat:lower()] and startup.channels[currentData:lower()]
        and #startup.joinCalls == 0 and #startup.dataJoinCalls == 0 and cleanup:IsDataConnected(),
        "restored current channels survive cleanup with chat autojoin disabled")
    for _, name in ipairs(unrelated) do
        assert(startup.channels[name:lower()], "cleanup preserves unrelated names and incomplete namespace lookalikes")
    end
    local oldLeaves = #startup.leaveCalls
    local restoredLater = "LIT" .. string.rep("f", 28)
    startup:restore(restoredLater, 30)
    secondary:AddChannel(restoredLater)
    startupFire("PLAYER_ENTERING_WORLD", false, false)
    assert(not startup.channels[restoredLater:lower()] and #secondary.channelList == 1
        and #startup.leaveCalls == oldLeaves + 1, "world entry cleans channels restored after login")
    startupFire("UPDATE_CHAT_WINDOWS")
    startupFire("UPDATE_CHAT_WINDOWS")
    secondary:AddChannel(frameOnly)
    secondary:AddChannel(currentData)
    startup:advance(0)
    assert(#secondary.channelList == 2 and secondary.channelList[1] == "General"
        and secondary.channelList[2] == currentData and #secondary.zoneChannelList == 2,
        "deferred window-update cleanup removes old subscriptions restored by native handlers")
    assert(startup.channels[currentChat:lower()] and startup.channels[currentData:lower()]
        and cleanup:IsDataConnected(), "window-update cleanup preserves current memberships")
end

-- Switching and leaving detach both transports from every native chat window.
do
    local switching, _, _, _, clock = loadAddon(settings(), false)
    clock:initialize()
    clock:advance(1)
    local oldChat, oldData = switching:GetGroupChannelName(), switching:GetGroupDataChannelName()
    clock:completeJoin(oldChat, 2)
    clock:completeJoin(oldData, 3)
    local primary, secondary = clock.chatFrames[1], clock:newChatFrame()
    primary:AddChannel(oldData)
    primary:AddChannel("General")
    secondary:AddChannel(oldChat:lower())
    secondary:AddChannel(oldData:upper())
    secondary:AddChannel("Unrelated")
    assert(switching:SetGroupSecret(OTHER_SECRET))
    clock:advance(0)
    assert(not clock.channels[oldChat:lower()] and not clock.channels[oldData:lower()]
        and #primary.channelList == 1 and primary.channelList[1] == "General"
        and #secondary.channelList == 1 and secondary.channelList[1] == "Unrelated",
        "a group switch leaves old memberships and detaches both channel names from every window")
    local newChat, newData = switching:GetGroupChannelName(), switching:GetGroupDataChannelName()
    clock:advance(1)
    clock:completeJoin(newChat, 4)
    clock:completeJoin(newData, 5)
    primary:AddChannel(newData)
    secondary:AddChannel(newChat)
    secondary:AddChannel(newData)
    assert(switching:LeaveGroup())
    clock:advance(0)
    assert(not clock.channels[newChat:lower()] and not clock.channels[newData:lower()]
        and #primary.channelList == 1 and #primary.zoneChannelList == 1
        and #secondary.channelList == 1 and #secondary.zoneChannelList == 1,
        "leaving the group removes both transport entries without damaging other frame channels")
end

-- A pending old join can finish after a switch or after the group is cleared.
do
    local switching, _, _, _, clock = loadAddon(settings(), false)
    clock:initialize()
    clock:advance(1)
    local oldChat, oldData = switching:GetGroupChannelName(), switching:GetGroupDataChannelName()
    assert(#clock.joinCalls == 1 and #clock.dataJoinCalls == 1)
    assert(switching:SetGroupSecret(OTHER_SECRET))
    clock:advance(0)
    local newChat, newData = switching:GetGroupChannelName(), switching:GetGroupDataChannelName()
    clock:advance(1)
    clock:completeJoin(newChat, 4)
    clock:completeJoin(newData, 5)
    local primary, secondary = clock.chatFrames[1], clock:newChatFrame()
    for _, notice in ipairs({ "YOU_JOINED", "YOU_CHANGED" }) do
        local chatLeaves, dataLeaves = #clock.leaveCalls, #clock.dataLeaveCalls
        primary:AddChannel(oldChat:upper())
        secondary:AddChannel(oldData:lower())
        clock:restore(oldChat:upper(), 6)
        clock:notice(notice, oldChat:upper(), 6)
        clock:restore(oldData:lower(), 7)
        clock:notice(notice, oldData:lower(), 7)
        assert(not clock.channels[oldChat:lower()] and not clock.channels[oldData:lower()]
            and #clock.leaveCalls == chatLeaves + 1 and #clock.dataLeaveCalls == dataLeaves + 1,
            "late and repeated old join notices leave the obsolete native memberships again")
        assert(#primary.channelList == 1 and primary.channelList[1]:lower() == newChat:lower()
            and #secondary.channelList == 0 and switching.chatState.phase == "joined"
            and switching:IsDataConnected() and clock.channels[newChat:lower()] and clock.channels[newData:lower()],
            "late old joins remove stale window entries without disrupting the current group")
    end
    assert(switching:LeaveGroup())
    clock:advance(0)
    primary:AddChannel(newChat)
    secondary:AddChannel(newData)
    clock:completeJoin(newChat, 4)
    clock:completeJoin(newData, 5)
    assert(not clock.channels[newChat:lower()] and not clock.channels[newData:lower()]
        and #primary.channelList == 0 and #secondary.channelList == 0 and not switching:IsDataConnected(),
        "late native joins are still left when no group remains configured")
    local dataAttempts = #clock.dataJoinCalls
    clock:advance(90)
    assert(#clock.dataJoinCalls == dataAttempts and not switching:IsDataConnected(),
        "leaving a switched group cancels all shared retries despite late old join notices")
end

-- Manual transport leaves remove their own entries and preserve the other route.
do
    local leaving, _, _, _, clock = loadAddon(settings(), false)
    clock:initialize()
    clock:advance(1)
    local chat, data = leaving:GetGroupChannelName(), leaving:GetGroupDataChannelName()
    clock:completeJoin(chat, 2)
    clock:completeJoin(data, 3)
    local primary, secondary = clock.chatFrames[1], clock:newChatFrame()
    primary:AddChannel(data)
    secondary:AddChannel(chat)
    secondary:AddChannel(data)
    leaving:LeaveChatChannel()
    assert(#primary.channelList == 1 and primary.channelList[1] == data and #secondary.channelList == 1
        and secondary.channelList[1] == data and leaving:IsDataConnected(),
        "manual chat leave removes saved chat-window entries while data stays connected")
    assert(leaving:LeaveDataChannel())
    assert(#primary.channelList == 0 and #secondary.channelList == 0,
        "manual data leave removes its native window entries too")
end

local retryProfile = settings()
retryProfile.position = { sharing = false }
local _, _, _, _, unanswered = loadAddon(retryProfile, false)
unanswered:initialize()
unanswered:advance(300)
assert(#unanswered.joinCalls > 1 and #unanswered.joinCalls <= 10)
local finalAttemptCount = #unanswered.joinCalls
unanswered:advance(300)
assert(#unanswered.joinCalls == finalAttemptCount, "retry exhaustion stops timers")

assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep test environments isolated")
print("PASS: native chat membership, retries and group cleanup")
