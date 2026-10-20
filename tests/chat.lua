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

-- Readable labels change presentation while native credentials and routing remain stable.
do
    local display, displayEnvironment, _, _, displayWorld = loadAddon(settings(), false)
    local nativeResolver = displayEnvironment.ChatFrameUtil.ResolvePrefixedChannelName
    displayWorld:initialize()
    local chatName, dataName = display:GetGroupChannelName(), display:GetGroupDataChannelName()
    local resolve = displayEnvironment.ChatFrameUtil.ResolvePrefixedChannelName
    assert(resolve ~= nativeResolver, "install readable labels during initialization")
    assert(display:GetChannelDisplayName(chatName:lower()) == "LockInTools")
    assert(display:GetChannelDisplayName(dataName:lower()) == "LockInTools Data")
    assert(resolve("5. " .. chatName) == "5. LockInTools")
    assert(resolve("12.  " .. dataName:lower()) == "12.  LockInTools Data",
        "preserve native channel numbers and spacing")
    assert(display:GetChannelDisplayName("Unrelated") == "Unrelated")
    assert(display:GetChannelDisplayName(chatName .. "suffix") == chatName .. "suffix",
        "only complete owned channel names receive labels")
    local function capture(...) return { n = select("#", ...), ... } end
    local marker, unrelated = {}, "7. Unrelated"
    local result = capture(resolve(unrelated, marker, nil, "last-argument"))
    local forwarded = displayWorld.resolverCalls[#displayWorld.resolverCalls]
    assert(result.n == 4 and result[1] == unrelated and result[2] == "native-result"
        and result[3] == nil and result[4] == "native-tail",
        "unrelated channels retain all native resolver returns")
    assert(forwarded.n == 4 and forwarded[1] == unrelated and forwarded[2] == marker
        and forwarded[3] == nil and forwarded[4] == "last-argument",
        "unrelated channels retain all native resolver arguments")
    for _, value in ipairs({ false, 17, {} }) do
        assert(display:GetChannelDisplayName(value) == value)
        assert(resolve(value) == value, "nonstring values pass through the native resolver")
    end
    assert(display:GetChannelDisplayName(nil) == nil and resolve(nil) == nil)
    displayWorld.secretValue = chatName
    assert(display:GetChannelDisplayName(chatName) == chatName)
    displayWorld.secretValue = "5. " .. chatName
    assert(resolve(displayWorld.secretValue) == displayWorld.secretValue,
        "secret channel values pass through unchanged")
    displayWorld.secretValue = nil

    displayWorld:advance(2)
    assert(displayWorld.joinCalls[1] == chatName
        and displayWorld.lastJoinPassword == display:GetGroupChannelPassword())
    assert(display:GetChatStatusText():find("LockInTools", 1, true)
        and not display:GetChatStatusText():find(chatName, 1, true))
    displayWorld:completeJoin(chatName, 5)
    displayWorld:completeJoin(dataName, 9)
    assert(display:GetChatStatusText():find("Joined LockInTools", 1, true))
    assert(display:GetDataStatusText():find("Joined LockInTools Data", 1, true)
        and not display:GetDataStatusText():find(dataName, 1, true))
    display:OpenChatInput()
    displayWorld:advance(0)
    assert(displayWorld.editBox.channelTarget == chatName and displayWorld.editBox.chatType == "CHANNEL",
        "the composer still targets the real native channel")
    local header = displayWorld.editBox.header
    assert(header.text == "5. LockInTools: " and displayWorld.editBox.measuredHeaderWidth == #header.text,
        "native header layout measures the readable label")
    assert(displayWorld.hookCalls[header] == 1, "hook an existing composer header once")
    local body = "Keep this normal message unchanged: " .. chatName
    assert(displayWorld:renderChannelMessage(5, chatName, body)
        == "|Hchannel:CHANNEL:5|h[5. LockInTools]|h " .. body,
        "readable channel links retain their clickable target and normal message text")
    assert(displayWorld:renderChannelMessage(7, "Unrelated", body)
        == "|Hchannel:CHANNEL:7|h[7. Unrelated]|h " .. body)
    displayWorld:restore(chatName, 8)
    displayWorld.editBox:UpdateHeader()
    assert(header.text == "8. LockInTools: " and displayWorld.editBox.channelTarget == chatName,
        "renumbering changes the displayed number without changing native targeting")

    local newBox = displayWorld.newEditBox()
    newBox:SetChatType("CHANNEL")
    newBox:SetChannelTarget(dataName)
    displayWorld:showEditBox(newBox)
    displayWorld:showEditBox(newBox)
    newBox:UpdateHeader()
    assert(newBox.header.text == "9. LockInTools Data: "
        and newBox.measuredHeaderWidth == #newBox.header.text)
    assert(displayWorld.hookCalls[newBox.header] == 1, "repeated show events must not duplicate header hooks")
    newBox.header:SetFormattedText("Whisper to %s", chatName)
    assert(newBox.header.text == "Whisper to " .. chatName, "other composer formats remain unchanged")
    displayWorld.secretValue = dataName
    newBox:UpdateHeader()
    assert(newBox.header.text == "9. " .. dataName .. ": ", "secret header names remain native")
    displayWorld.secretValue = nil
    displayWorld:restore("Unrelated", 7)
    newBox:SetChannelTarget("Unrelated")
    newBox:UpdateHeader()
    assert(newBox.header.text == "7. Unrelated: ", "other composer channel names remain unchanged")

    assert(display:SetGroupSecret(OTHER_SECRET))
    displayWorld:advance(0)
    local nextChat, nextData = display:GetGroupChannelName(), display:GetGroupDataChannelName()
    assert(nextChat ~= chatName and nextData ~= dataName)
    assert(resolve("3. " .. nextChat) == "3. LockInTools"
        and resolve("4. " .. nextData) == "4. LockInTools Data")
    assert(resolve("8. " .. chatName) == "8. LockInTools"
        and resolve("9. " .. dataName) == "9. LockInTools Data",
        "delayed leave notices keep readable labels for the previous group")
    local reloadedDisplay, reloadedEnvironment, _, _, reloadedDisplayWorld = loadAddon(display.db, false)
    reloadedDisplayWorld:initialize()
    assert(reloadedDisplay:GetGroupChannelName() == nextChat
        and reloadedEnvironment.ChatFrameUtil.ResolvePrefixedChannelName("3. " .. nextChat) == "3. LockInTools",
        "reload preserves credentials and restores readable labels")
    assert(display:LeaveGroup())
    displayWorld:advance(0)
    assert(resolve("3. " .. nextChat) == "3. LockInTools"
        and resolve("4. " .. nextData) == "4. LockInTools Data",
        "delayed notices remain readable after leaving the group")
    assert(resolve("7. Unrelated") == "7. Unrelated")
end

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

-- Changing/removing group leaves old transport, including client-restored rooms.
for _, restoreFirst in ipairs({ false, true }) do
    local switcher, _, _, _, switchWorld = loadAddon(settings(), false)
    if restoreFirst then switchWorld:restore(room, 2) end
    switchWorld:restore("Unrelated", 9)
    switchWorld:initialize()
    switchWorld:advance(2)
    if not restoreFirst then switchWorld:completeJoin(room, 4) end
    assert(switcher:SetGroupSecret(OTHER_SECRET))
    switchWorld:advance(0)
    local nextRoom = switcher:GetGroupChannelName()
    assert(nextRoom ~= room and switchWorld.leaveCalls[1] == room)
    assert(switchWorld.joinCalls[#switchWorld.joinCalls] == nextRoom)
    switchWorld:completeJoin(nextRoom, 3)
    assert(switcher:LeaveGroup())
    switchWorld:advance(0)
    switchWorld.fire("PLAYER_ENTERING_WORLD", false, false)
    switchWorld:advance(120)
    assert(switchWorld.leaveCalls[2] == nextRoom and not switcher:HasGroup())
    assert(switchWorld.channels.unrelated, "leave unrelated channels alone")
end
local pendingSwitch, _, _, _, pendingSwitchWorld = loadAddon(settings(), false)
pendingSwitchWorld:initialize()
pendingSwitchWorld:advance(2)
assert(pendingSwitch:SetGroupSecret(OTHER_SECRET))
pendingSwitchWorld:advance(0)
local nextRoom = pendingSwitch:GetGroupChannelName()
pendingSwitchWorld:completeJoin(nextRoom, 3)
pendingSwitchWorld:advance(120)
assert(#pendingSwitchWorld.joinCalls == 2 and pendingSwitchWorld.joinCalls[1] == room
    and pendingSwitchWorld.joinCalls[2] == nextRoom, "cancel pending retries on group switch")

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

local _, _, _, _, unanswered = loadAddon(settings(), false)
unanswered:initialize()
unanswered:advance(300)
assert(#unanswered.joinCalls > 1 and #unanswered.joinCalls <= 10)
local finalAttemptCount = #unanswered.joinCalls
unanswered:advance(300)
assert(#unanswered.joinCalls == finalAttemptCount, "retry exhaustion stops timers")

-- Friendly group keys identify the same group across players, logins and chat.
local friendly, _, friendlyMessages, _, friendlyWorld = loadAddon(settings("", true), false)
friendlyWorld:initialize()
assert(friendly:SetGroupSecret("  OTTER-4827  "))
assert(friendly:GetGroupSecret() == "otter-4827" and #friendlyWorld.joinCalls == 1)
local friendlyRoom, friendlyPassword = friendly:GetGroupChannelName(), friendly:GetGroupChannelPassword()
assert(friendlyRoom ~= room and friendlyWorld.joinCalls[1] == friendlyRoom)
assert(friendlyWorld.lastJoinPassword == friendlyPassword)
friendlyWorld:completeJoin(friendlyRoom, 7)
local peer, _, _, _, peerWorld = loadAddon(settings("otter-4827"), false)
peerWorld:initialize()
peerWorld:advance(2)
assert(peer:GetGroupFingerprint() == friendly:GetGroupFingerprint()
    and peer:GetGroupChannelName() == friendlyRoom and peerWorld.lastJoinPassword == friendlyPassword,
    "the same readable key selects the same room and password for friends")
local friendlyReload, _, _, friendlyReloadEvent, friendlyReloadWorld = loadAddon(friendly.db, true)
friendlyReloadEvent("ADDON_LOADED", "LockInTools")
friendlyReloadWorld:advance(2)
assert(friendlyReload:GetGroupSecret() == "otter-4827"
    and friendlyReloadWorld.joinCalls[1] == friendlyRoom
    and friendlyReloadWorld.lastJoinPassword == friendlyPassword, "readable keys persist and autojoin on reload")
assert(not friendly:SetGroupSecret("otter--4827") and friendly:GetGroupSecret() == "otter-4827")
assert(not contains(friendlyMessages, "otter-4827") and not contains(friendlyMessages, friendlyPassword))


assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep test environments isolated")
print("PASS: native chat membership, labels, retries and group cleanup")
