-- This harness is never loaded by the addon.
-- Server membership changes are asynchronous, as they are in the client.
local function loadAddon(savedVariables, loggedIn)
    local messages, frames, timers = {}, {}, {}
    local world = {
        now = 0, channels = {}, joinCalls = {}, leaveCalls = {},
        addCalls = {}, passwordCalls = {}, roster = {}, openedChat = {},
        optionsOpened = 0, welcomeOpened = 0,
    }
    local function channelByName(name)
        if type(name) == "string" then return world.channels[name:lower()] end
        for _, channel in pairs(world.channels) do
            if channel.id == name then return channel end
        end
    end
    local function newTimer(delay, callback)
        local timer = { at = world.now + delay, callback = callback, cancelled = false }
        function timer:Cancel() self.cancelled = true end
        function timer:IsCancelled() return self.cancelled end
        timers[#timers + 1] = timer
        return timer
    end
    local editBox = {}
    function editBox:SetChatType(chatType) self.chatType = chatType end
    function editBox:SetChannelTarget(target) self.channelTarget = target end
    function editBox:UpdateHeader() end
    local chatFrame = { channelList = {} }
    function chatFrame:AddMessage(message) messages[#messages + 1] = message end
    function chatFrame:GetID() return 1 end
    function chatFrame:AddChannel(name)
        world.addCalls[#world.addCalls + 1] = name
        self.channelList[#self.channelList + 1] = name
    end
    local function openChat(text, frame)
        world.openedChat[#world.openedChat + 1] = { text = text, frame = frame }
        return editBox
    end
    local environment = setmetatable({
        LockInToolsDB = savedVariables,
        SlashCmdList = {},
        C_AddOns = {
            GetAddOnMetadata = function(name, field)
                assert(name == "LockInTools" and field == "Version")
                return "0.2.0"
            end,
        },
        C_Timer = { NewTimer = newTimer, After = newTimer },
        DEFAULT_CHAT_FRAME = chatFrame,
        ChatFrameUtil = { ChooseBoxForSend = function() return editBox end, OpenChat = openChat },
        GetChannelName = function(identifier)
            local channel = channelByName(identifier)
            if channel then return channel.id, channel.name end
            return 0, nil
        end,
        JoinPermanentChannel = function(name, password, frameID)
            assert(type(password) == "string" and #password == 31, "every join uses a derived password")
            assert(frameID == 1, "join into the default native chat frame")
            world.joinCalls[#world.joinCalls + 1] = name
            world.lastJoinPassword = password
            return 0, name
        end,
        SetChannelPassword = function(name, password)
            world.passwordCalls[#world.passwordCalls + 1] = { name = name, password = password }
        end,
        UnitGUID = function(unit) assert(unit == "player"); return "Player-Test-Self" end,
        GetNumDisplayChannels = function() return #world.roster end,
        GetChannelDisplayInfo = function(displayIndex)
            local entry = assert(world.roster[displayIndex], "display index is separate from channel number")
            return entry.name, entry.header, false, entry.id, #(entry.members or {}), true, "CHANNEL_CATEGORY_CUSTOM"
        end,
        C_ChatInfo = { GetChannelRosterInfo = function(displayIndex, rosterIndex)
            local member = world.roster[displayIndex].members[rosterIndex]
            return member.name, member.owner, member.moderator, member.guid
        end },
        LeaveChannelByName = function(name)
            world.leaveCalls[#world.leaveCalls + 1] = name
            world.channels[name:lower()] = nil
        end,
        strlenutf8 = function(text)
            -- Count UTF-8 leading bytes without requiring Lua 5.3's utf8 module.
            local _, count = text:gsub("[^\128-\191]", "")
            return count
        end,
        IsLoggedIn = function() return loggedIn end,
        GetBuildInfo = function() return "1.60.1", "70374", "Oct 2026", 16001 end,
        CreateFrame = function(frameType)
            assert(frameType == "Frame", "options are not loaded in this harness")
            local frame = { events = {} }
            function frame:RegisterEvent(event) self.events[event] = true end
            function frame:UnregisterEvent(event) self.events[event] = nil end
            function frame:SetScript(script, callback)
                assert(script == "OnEvent")
                self.onEvent = callback
            end
            frames[#frames + 1] = frame
            return frame
        end,
    }, { __index = _G })
    local addon = {}
    for _, file in ipairs({ "Core.lua", "Crypto.lua", "Group.lua", "Chat.lua", "Data.lua", "Position.lua", "Commands.lua" }) do
        local chunk, problem
        if setfenv then
            chunk, problem = loadfile(file)
            assert(chunk, problem)
            setfenv(chunk, environment)
        else
            chunk, problem = loadfile(file, "t", environment)
            assert(chunk, problem)
        end
        chunk("LockInTools", addon)
    end
    addon.OpenOptions = function() world.optionsOpened = world.optionsOpened + 1 end
    addon.OpenWelcome = function() world.welcomeOpened = world.welcomeOpened + 1 end
    addon.RefreshOptions = function() end
    local function fire(event, ...)
        local count = #frames
        for index = 1, count do
            local frame = frames[index]
            if frame.events[event] then frame.onEvent(frame, event, ...) end
        end
    end
    function world:advance(seconds)
        local target, callbacks = self.now + seconds, 0
        while true do
            local nextIndex, nextTimer
            for index, timer in ipairs(timers) do
                if not timer.cancelled and timer.at <= target
                    and (not nextTimer or timer.at < nextTimer.at) then
                    nextIndex, nextTimer = index, timer
                end
            end
            if not nextTimer then break end
            table.remove(timers, nextIndex)
            self.now = nextTimer.at
            callbacks = callbacks + 1
            assert(callbacks <= 100, "timer callbacks must remain bounded")
            nextTimer.callback(nextTimer)
        end
        self.now = target
    end
    function world:restore(name, id)
        self.channels[name:lower()] = { name = name, id = id }
    end
    function world:notice(notice, name, id)
        fire("CHAT_MSG_CHANNEL_NOTICE", notice, "", "", name, "", "", 0, id or 0, name)
    end
    function world:completeJoin(name, id)
        self:restore(name, id)
        self:notice("YOU_JOINED", name, id)
        fire("CHANNEL_UI_UPDATE")
    end
    function world:initialize()
        fire("ADDON_LOADED", "LockInTools")
        fire("PLAYER_LOGIN")
    end
    world.fire, world.editBox = fire, editBox
    return addon, environment, messages, fire, world
end

local SECRET = "LIT1-" .. string.rep("01", 32)
local OTHER_SECRET = "LIT1-" .. string.rep("ab", 32)
local function settings(secret, autoJoin)
    return { schemaVersion = 3, showWelcome = false,
        group = { secret = secret or SECRET }, chat = { autoJoin = autoJoin ~= false } }
end

local function contains(messages, needle, first)
    for index = first or 1, #messages do
        if messages[index]:find(needle, 1, true) then return true end
    end
    return false
end

-- Startup, migration, commands, reload and saved-variable preservation.
local addon, environment, messages, fire, world = loadAddon(nil, false)
assert(environment.SLASH_LOCKINTOOLS1 == "/lit", "slash command must be /lit")
assert(environment.LockInToolsDB == nil, "initialize only after ADDON_LOADED")
fire("ADDON_LOADED", "AnotherAddon")
assert(not addon.initialized)
fire("ADDON_LOADED", "LockInTools")
assert(addon.initialized and not addon.ready)
assert(addon.db.schemaVersion == 3 and addon.db.showWelcome == true)
assert(addon.db.chat.autoJoin == true and not addon:HasGroup())
fire("PLAYER_LOGIN")
assert(addon.ready and #messages == 1, "announce once at login")
assert(world.welcomeOpened == 1, "show initial welcome after login when no group is configured")
fire("PLAYER_LOGIN")
assert(#messages == 1 and world.welcomeOpened == 1, "do not repeat welcome on duplicate login events")
world:advance(30)
assert(#world.joinCalls == 0, "an unconfigured group must not join a channel")
local command = environment.SlashCmdList.LOCKINTOOLS
command("")
assert(world.welcomeOpened == 2, "bare /lit opens welcome")
command("welcome")
assert(world.welcomeOpened == 3, "/lit welcome reopens welcome")
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
assert(reloadWorld.welcomeOpened == 0, "configured groups do not reopen welcome at login")
assert(reloaded:GetGroupSecret() == SECRET, "retain group across reload")
assert(reloaded:GetGroupFingerprint() == addon:GetGroupFingerprint())
assert(reloaded:GetGroupChannelName() == addon:GetGroupChannelName())
assert(reloaded:GetGroupChannelPassword() == addon:GetGroupChannelPassword())
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
    assert(migrationWorld.welcomeOpened == 0, "disabled welcome stays disabled during migration")
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
assert(olderWorld.welcomeOpened == 0, "read-only saved data does not trigger initial setup")
for _, damaged in ipairs({ false, "invalid", { schemaVersion = "bad", showWelcome = "bad", chat = "bad" } }) do
    local repaired, _, _, _, repairedWorld = loadAddon(damaged, true)
    repairedWorld:initialize()
    assert(repaired.ready and repaired.db.schemaVersion == 3 and repaired.db.showWelcome == true)
    assert(type(repaired.db.chat) == "table" and not repaired:HasGroup())
end

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

-- Changing/removing group leaves old transport, including client-restored rooms.
for _, restoreFirst in ipairs({ false, true }) do
    local switcher, _, _, _, switchWorld = loadAddon(settings(), false)
    if restoreFirst then switchWorld:restore(room, 2) end
    switchWorld:restore("Unrelated", 9)
    switchWorld:initialize()
    switchWorld:advance(2)
    if not restoreFirst then switchWorld:completeJoin(room, 4) end
    assert(switcher:SetGroupSecret(OTHER_SECRET))
    local nextRoom = switcher:GetGroupChannelName()
    assert(nextRoom ~= room and switchWorld.leaveCalls[1] == room)
    assert(switchWorld.joinCalls[#switchWorld.joinCalls] == nextRoom)
    switchWorld:completeJoin(nextRoom, 3)
    assert(switcher:LeaveGroup())
    switchWorld.fire("PLAYER_ENTERING_WORLD", false, false)
    switchWorld:advance(120)
    assert(switchWorld.leaveCalls[2] == nextRoom and not switcher:HasGroup())
    assert(switchWorld.channels.unrelated, "leave unrelated channels alone")
end
local pendingSwitch, _, _, _, pendingSwitchWorld = loadAddon(settings(), false)
pendingSwitchWorld:initialize()
pendingSwitchWorld:advance(2)
assert(pendingSwitch:SetGroupSecret(OTHER_SECRET))
local nextRoom = pendingSwitch:GetGroupChannelName()
pendingSwitchWorld:completeJoin(nextRoom, 3)
pendingSwitchWorld:advance(120)
assert(#pendingSwitchWorld.joinCalls == 2 and pendingSwitchWorld.joinCalls[1] == room
    and pendingSwitchWorld.joinCalls[2] == nextRoom, "cancel pending retries on group switch")
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

-- Exercise the real options callbacks against strict native-widget stubs.
local function loadOptions(uiAddon, uiEnvironment)
    local createEventFrame = uiEnvironment.CreateFrame
    local methods = {}
    local function makeWidget()
        return setmetatable({ scripts = {}, enabled = true, shown = true }, { __index = methods })
    end
    for _, name in ipairs({ "SetSize", "SetPoint", "SetFrameStrata", "SetClampedToScreen",
        "SetMovable", "EnableMouse", "RegisterForDrag", "StartMoving", "StopMovingOrSizing",
        "SetWidth", "SetHeight", "SetJustifyH", "SetAutoFocus", "Raise" }) do
        methods[name] = function() end
    end
    function methods:SetText(text)
        self.text = text
        if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self, false) end
    end
    function methods:GetText() return self.text or "" end
    function methods:SetTextColor(red, green, blue) self.color = { red, green, blue } end
    function methods:SetEnabled(enabled) self.enabled = enabled end
    function methods:IsEnabled() return self.enabled end
    function methods:SetChecked(checked) self.checked = checked end
    function methods:GetChecked() return self.checked end
    function methods:ClearFocus() self.focusCleared = true; self.focused = false end
    function methods:SetFocus() self.focused = true; self.focusCleared = false end
    function methods:HighlightText() self.highlighted = true end
    function methods:SetPassword(password) self.password = password end
    function methods:SetScript(script, callback) self.scripts[script] = callback end
    function methods:CreateFontString() return makeWidget() end
    function methods:IsShown() return self.shown end
    function methods:Hide()
        local wasShown = self.shown
        self.shown = false
        if wasShown and self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    function methods:Show()
        local wasShown = self.shown
        self.shown = true
        if not wasShown and self.scripts.OnShow then self.scripts.OnShow(self) end
    end
    function methods:Click()
        if self.enabled and self.scripts.OnClick then self.scripts.OnClick(self) end
    end
    function methods:UserInput(text)
        assert(self.enabled, "disabled fields do not accept user input")
        self.text = text
        if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self, true) end
    end
    uiEnvironment.CreateFrame = function(frameType, name, parent, template)
        if frameType == "Frame" and not name and not template then
            return createEventFrame(frameType)
        end
        assert(frameType == "Frame" or frameType == "EditBox"
            or frameType == "CheckButton" or frameType == "Button", "use supported native widgets")
        local widget = makeWidget()
        widget.frameType, widget.parent, widget.template = frameType, parent, template
        if template == "BasicFrameTemplateWithInset" then widget.TitleText = makeWidget() end
        if name then uiEnvironment[name] = widget end
        return widget
    end
    uiEnvironment.UIParent, uiEnvironment.UISpecialFrames = {}, {}
    uiEnvironment.tinsert = table.insert
    local chunk, problem
    if setfenv then
        chunk, problem = loadfile("Options.lua")
        assert(chunk, problem)
        setfenv(chunk, uiEnvironment)
    else
        chunk, problem = loadfile("Options.lua", "t", uiEnvironment)
        assert(chunk, problem)
    end
    chunk("LockInTools", uiAddon)
end

local uiAddon, uiEnvironment, uiMessages, _, uiWorld = loadAddon(settings("", false), false)
uiWorld:initialize()
loadOptions(uiAddon, uiEnvironment)
assert(uiAddon.optionsPanel == nil, "build options only when requested")
uiEnvironment.SlashCmdList.LOCKINTOOLS("options")
local panel = uiAddon.optionsPanel
assert(panel and panel:IsShown(), "/lit options opens the actual options panel")
assert(panel.secret:GetText() == "" and panel.secret.password and panel.autoJoin:GetChecked() == false)
assert(panel.positionSharing:GetChecked() == false and panel.positionRetention:GetChecked() == true,
    "position sharing starts off with last-known retention enabled")
assert(not panel.join:IsEnabled() and not panel.leave:IsEnabled(), "no group means no join/leave buttons")
assert(uiEnvironment.UISpecialFrames[1] == "LockInToolsOptions", "Escape can close the native panel")
panel.createGroup:Click()
local generatedDraft = panel.secret:GetText()
assert(generatedDraft:match("^[a-z]+%-%d%d%d%d$") and not panel.secret.password
    and panel.secret.focused and panel.secret.highlighted, "Create fills a readable key ready to copy")
assert(not uiAddon:HasGroup() and uiAddon.db.group.secret == "" and #uiWorld.joinCalls == 0,
    "generating a key does not join or replace a group before Use key")
assert(panel.applyGroup:GetText() == "Use key" and panel.toggleSecret:GetText() == "Hide key")
panel.secret:SetText("  " .. SECRET:lower() .. "  ")
panel.applyGroup:Click()
assert(uiAddon:GetGroupSecret() == SECRET and uiAddon.db.chat.autoJoin == false,
    "import saves shared identity independently from feature settings")
assert(panel.secret:GetText() == "" and panel.secret.password and panel.secret.focusCleared)
assert(#uiWorld.joinCalls == 0 and panel.join:IsEnabled() and panel.leave:IsEnabled())
panel.toggleSecret:Click()
assert(panel.secret:GetText() == SECRET and not panel.secret.password
    and panel.secret.focused and panel.secret.highlighted, "reveal only after explicit click for copying")
panel.toggleSecret:Click()
assert(panel.secret.password, "hide masks the revealed secret")
panel.positionSharing:SetChecked(true)
panel.positionRetention:SetChecked(false)
panel.autoJoin:SetChecked(true)
panel.save:Click()
assert(uiAddon.db.chat.autoJoin and #uiWorld.joinCalls == 1)
assert(not uiAddon.db.position.sharing and uiAddon.db.position.keepLastKnown,
    "saving chat does not apply position preference drafts")
panel.savePosition:Click()
assert(uiAddon.db.position.sharing and not uiAddon.db.position.keepLastKnown
    and uiAddon.db.chat.autoJoin and #uiWorld.joinCalls == 1,
    "position settings save independently of chat and do not request a chat join")
panel.secret:SetText(OTHER_SECRET)
panel.autoJoin:SetChecked(false)
panel.positionSharing:SetChecked(false)
panel.positionRetention:SetChecked(true)
uiWorld:completeJoin(room, 9)
assert(panel.secret:GetText() == OTHER_SECRET and panel.autoJoin:GetChecked() == false,
    "asynchronous status updates preserve form edits")
assert(panel.positionSharing:GetChecked() == false and panel.positionRetention:GetChecked() == true
    and uiAddon.db.position.sharing and not uiAddon.db.position.keepLastKnown,
    "asynchronous status updates preserve position preference drafts")
assert(panel.positionStatus:GetText() == "Status: " .. uiAddon:GetPositionStatusText(),
    "position status reflects the current sharing state")
assert(panel.status:GetText():find("Joined", 1, true), "status reflects confirmed membership")
panel.secret:SetText("invalid--key")
panel.applyGroup:Click()
panel.applyGroup:Click()
assert(uiAddon:GetGroupSecret() == SECRET and uiAddon.db.chat.autoJoin,
    "invalid input preserves group and feature preferences")
assert(panel.feedback:GetText() ~= "" and panel.feedback.color[1] == 1)
panel.secret:SetText(OTHER_SECRET)
panel.join:Click()
assert(uiWorld.joinCalls[#uiWorld.joinCalls] == room, "Join uses saved group, ignoring draft secret")
panel.leave:Click()
assert(uiWorld.leaveCalls[#uiWorld.leaveCalls] == room and uiAddon:HasGroup(), "chat leave retains group")
panel.applyGroup:Click()
assert(uiAddon:GetGroupSecret() == SECRET and panel.applyGroup:GetText() == "Confirm switch")
panel.applyGroup:Click()
assert(uiAddon:GetGroupSecret() == OTHER_SECRET and panel.secret.password and panel.secret:GetText() == "",
    "switch confirms before changing every feature's group")
panel.toggleSecret:Click()
assert(panel.secret:GetText() == OTHER_SECRET and not panel.secret.password)
panel:Hide()
assert(panel.secret.password and panel.secret:GetText() == "", "closing clears and masks secrets")
uiAddon:OpenOptions()
assert(uiAddon.optionsPanel == panel and panel.secret:GetText() == "" and panel.secret.password)
assert(panel.positionSharing:GetChecked() == true and panel.positionRetention:GetChecked() == false,
    "reopening options restores saved position preferences")
panel.secret:SetText(SECRET)
panel.autoJoin:SetChecked(false)
panel.secret.scripts.OnEnterPressed(panel.secret)
assert(uiAddon:GetGroupSecret() == OTHER_SECRET, "Enter also requires switch confirmation")
panel.secret:SetText(OTHER_SECRET)
panel.secret.scripts.OnTextChanged(panel.secret, true)
panel.applyGroup:Click()
assert(uiAddon:GetGroupSecret() == OTHER_SECRET and uiAddon.db.chat.autoJoin,
    "using a secret does not apply an unsaved feature toggle")
panel.createGroup:Click()
local replacementDraft = panel.secret:GetText()
assert(replacementDraft:match("^[a-z]+%-%d%d%d%d$") and uiAddon:GetGroupSecret() == OTHER_SECRET,
    "Create leaves the configured group intact while drafting a replacement")
panel.applyGroup:Click()
assert(uiAddon:GetGroupSecret() == OTHER_SECRET and panel.applyGroup:GetText() == "Confirm switch")
panel.applyGroup:Click()
assert(uiAddon:GetGroupSecret() == replacementDraft and panel.secret:GetText() == "" and panel.secret.password,
    "generated key uses the same confirmation and clears after applying")
panel.leaveGroup:Click()
assert(uiAddon:HasGroup() and panel.leaveGroup:GetText() == "Confirm leave")
panel.leaveGroup:Click()
assert(not uiAddon:HasGroup() and not panel.join:IsEnabled() and not panel.leave:IsEnabled())
assert(not contains(uiMessages, SECRET) and not contains(uiMessages, OTHER_SECRET))
assert(not contains(uiMessages, generatedDraft) and not contains(uiMessages, replacementDraft))
local readOnly, readOnlyEnvironment, _, _, readOnlyWorld = loadAddon(newer, false)
readOnlyWorld:initialize()
loadOptions(readOnly, readOnlyEnvironment)
readOnly:OpenOptions()
assert(not readOnly.optionsPanel.secret:IsEnabled()
    and not readOnly.optionsPanel.applyGroup:IsEnabled()
    and not readOnly.optionsPanel.createGroup:IsEnabled()
    and not readOnly.optionsPanel.autoJoin:IsEnabled()
    and not readOnly.optionsPanel.save:IsEnabled()
    and not readOnly.optionsPanel.positionSharing:IsEnabled()
    and not readOnly.optionsPanel.positionRetention:IsEnabled()
    and not readOnly.optionsPanel.savePosition:IsEnabled(), "read-only settings disable editing and saving")
assert(readOnly.optionsPanel.feedback:GetText():find("Update LockInTools", 1, true))

-- Welcome creates one persisted key and keeps copying separate from joining a friend.
do
    local initial, initialEnvironment, initialMessages, _, initialWorld = loadAddon(nil, false)
    local generatedCalls = 0
    initialEnvironment.math = setmetatable({ random = function(_, maximum)
        generatedCalls = generatedCalls + 1
        return maximum == 64 and 48 or 4827
    end }, { __index = math })
    loadOptions(initial, initialEnvironment)
    initialWorld:initialize()
    local welcome = initial.welcomePanel
    local initialKey = "otter-4827"
    local initialRoom = initial:GetGroupChannelName()
    assert(welcome and welcome:IsShown() and initial.optionsPanel == nil,
        "first login opens welcome without constructing feature settings")
    assert(initial:GetGroupSecret() == initialKey and initial.db.group.secret == initialKey
        and generatedCalls == 2, "welcome generates and saves one copyable group key")
    assert(welcome.ownSecret:GetText() == initialKey and not welcome.ownSecret.password,
        "welcome visibly displays the persisted key")
    assert(#initialWorld.joinCalls == 1 and initialWorld.joinCalls[1] == initialRoom,
        "initial group creation uses normal chat autojoin once")
    initialWorld.fire("PLAYER_LOGIN")
    assert(generatedCalls == 2 and #initialWorld.joinCalls == 1,
        "duplicate login does not regenerate the key or request another join")
    assert(contains(initialEnvironment.UISpecialFrames, "LockInToolsWelcome"),
        "Escape can close the welcome screen")
    welcome.selectKey:Click()
    assert(welcome.ownSecret.focused and welcome.ownSecret.highlighted,
        "select key focuses and highlights the visible key for copying")
    welcome.ownSecret:UserInput("accidental-edit")
    assert(welcome.ownSecret:GetText() == initialKey and initial:GetGroupSecret() == initialKey,
        "typing into the copy field cannot change the saved key")

    local restored, restoredEnvironment, _, restoredEvent, restoredWorld = loadAddon(initial.db, true)
    restoredEnvironment.math = setmetatable({ random = function()
        error("a persisted key must not be regenerated")
    end }, { __index = math })
    loadOptions(restored, restoredEnvironment)
    restoredEvent("ADDON_LOADED", "LockInTools")
    assert(restored.ready and restored.welcomePanel == nil and restored:GetGroupSecret() == initialKey,
        "loading after login preserves the key without reopening completed setup")
    restoredEnvironment.SlashCmdList.LOCKINTOOLS("welcome")
    assert(restored.welcomePanel.ownSecret:GetText() == initialKey,
        "welcome reopens with the same key after reload")
    restored.welcomePanel.done:Click()
    restoredWorld:advance(1)
    assert(restoredWorld.joinCalls[1] == initialRoom, "the saved welcome key restores the same channel")

    welcome.friendSecret:UserInput("   ")
    welcome.joinGroup:Click()
    assert(initial:GetGroupSecret() == initialKey and welcome.feedback:GetText() ~= ""
        and welcome.feedback.color[1] == 1, "blank friend input reports an error without changing groups")
    welcome.friendSecret:UserInput("invalid--key")
    welcome.joinGroup:Click()
    welcome.joinGroup:Click()
    assert(initial:GetGroupSecret() == initialKey and #initialWorld.leaveCalls == 0,
        "an invalid friend's key preserves the current group and its transport")
    welcome.friendSecret:UserInput("  OTTER-4827  ")
    welcome.joinGroup:Click()
    assert(initial:GetGroupSecret() == initialKey and welcome.joinGroup:GetText() == "Join friend"
        and #initialWorld.leaveCalls == 0 and #initialWorld.joinCalls == 1,
        "the same canonical key succeeds immediately without switching transport")

    welcome.friendSecret:UserInput("first-friend")
    welcome.joinGroup:Click()
    assert(initial:GetGroupSecret() == initialKey and welcome.joinGroup:GetText() == "Confirm switch",
        "joining a friend requires confirmation before changing every feature's group")
    welcome.friendSecret:UserInput("other-friend")
    assert(welcome.joinGroup:GetText() == "Join friend", "editing the key resets switch confirmation")
    welcome.joinGroup:Click()
    assert(initial:GetGroupSecret() == initialKey and welcome.joinGroup:GetText() == "Confirm switch")
    initialWorld:completeJoin(initialRoom, 7)
    assert(welcome.friendSecret:GetText() == "other-friend"
        and welcome.joinGroup:GetText() == "Confirm switch" and welcome.ownSecret:GetText() == initialKey,
        "asynchronous chat updates preserve the friend's draft and confirmation")
    welcome.joinGroup:Click()
    assert(initial:GetGroupSecret() == "other-friend" and initial.db.group.secret == "other-friend"
        and welcome.ownSecret:GetText() == "other-friend", "confirmed friend key becomes the displayed saved key")
    assert(initialWorld.leaveCalls[1] == initialRoom
        and initialWorld.joinCalls[2] == initial:GetGroupChannelName(),
        "welcome switches groups through the existing channel lifecycle")
    assert(initial.optionsPanel == nil, "welcome refreshes without requiring an options panel")

    assert(initial:SetGroupSecret(SECRET))
    assert(welcome.ownSecret:GetText() == SECRET, "welcome follows group changes made outside its form")
    local previousLeaves = #initialWorld.leaveCalls
    welcome.friendSecret:UserInput("  " .. SECRET:lower() .. "  ")
    welcome.joinGroup:Click()
    assert(initial:GetGroupSecret() == SECRET and #initialWorld.leaveCalls == previousLeaves
        and welcome.joinGroup:GetText() == "Join friend", "legacy keys retain canonical same-group behavior")
    welcome.friendSecret:UserInput(OTHER_SECRET)
    welcome.joinGroup:Click()
    welcome.selectKey:Click()
    welcome.friendSecret:SetFocus()
    welcome.done:Click()
    assert(not welcome:IsShown() and welcome.ownSecret:GetText() == ""
        and welcome.friendSecret:GetText() == "" and welcome.ownSecret.focusCleared
        and welcome.friendSecret.focusCleared, "closing welcome clears plaintext, drafts and focus")
    initial:OpenWelcome()
    assert(initial.welcomePanel == welcome and welcome.ownSecret:GetText() == SECRET
        and welcome.friendSecret:GetText() == "" and welcome.joinGroup:GetText() == "Join friend"
        and generatedCalls == 2, "reopening restores the saved key and resets pending confirmation")
    -- Hiding UIParent fires OnHide while the child's own IsShown flag stays true.
    welcome.friendSecret:UserInput(OTHER_SECRET)
    welcome.joinGroup:Click()
    welcome.scripts.OnHide(welcome)
    initial:RefreshOptions()
    assert(welcome:IsShown() and welcome.ownSecret:GetText() == ""
        and welcome.friendSecret:GetText() == "" and welcome.joinGroup:GetText() == "Join friend",
        "hiding the whole interface clears keys and prevents background refresh from restoring them")
    welcome.scripts.OnShow(welcome)
    assert(welcome.ownSecret:GetText() == SECRET, "showing the interface restores the saved key")
    welcome.options:Click()
    assert(initial.optionsPanel and initial.optionsPanel:IsShown() and not welcome:IsShown(),
        "the welcome options button opens feature settings")
    assert(not contains(initialMessages, initialKey) and not contains(initialMessages, "other-friend")
        and not contains(initialMessages, SECRET) and not contains(initialMessages, OTHER_SECRET),
        "welcome never prints either person's key to chat")
end

-- Manual setup respects disabled autojoin; generation failures still allow friend import.
do
    local manualWelcome, manualEnvironment, _, _, manualWelcomeWorld = loadAddon(settings("", false), false)
    loadOptions(manualWelcome, manualEnvironment)
    manualWelcomeWorld:initialize()
    assert(manualWelcome.welcomePanel == nil, "welcome off suppresses automatic setup")
    manualEnvironment.SlashCmdList.LOCKINTOOLS("")
    assert(manualWelcome:HasGroup() and #manualWelcomeWorld.joinCalls == 0,
        "manually opening welcome saves a key while respecting disabled autojoin")
    local manualPanel = manualWelcome.welcomePanel
    manualPanel.friendSecret:UserInput("manual-friend")
    manualPanel.joinGroup:Click()
    manualPanel.joinGroup:Click()
    assert(manualWelcome:GetGroupSecret() == "manual-friend" and #manualWelcomeWorld.joinCalls == 0
        and not manualWelcome.db.chat.autoJoin, "friend import preserves feature preferences")

    local failed, failedEnvironment, failedMessages, _, failedWorld = loadAddon(nil, false)
    local attempts = 0
    failedEnvironment.math = setmetatable({ random = function()
        attempts = attempts + 1
        error("private generator failure")
    end }, { __index = math })
    loadOptions(failed, failedEnvironment)
    failedWorld:initialize()
    local failedPanel = failed.welcomePanel
    assert(failedPanel and failedPanel:IsShown() and not failed:HasGroup()
        and failed.db.group.secret == "" and failedPanel.ownSecret:GetText() == "",
        "generation failure leaves saved group data empty")
    assert(failedPanel.friendSecret:IsEnabled() and failedPanel.joinGroup:IsEnabled()
        and failedPanel.feedback:GetText() ~= "", "friend import remains available after generation failure")
    failed:RefreshOptions()
    assert(attempts == 1, "status refresh does not retry failed key generation")
    failedPanel.friendSecret:UserInput("friend-4827")
    failedPanel.joinGroup:Click()
    assert(failed:GetGroupSecret() == "friend-4827" and failedPanel.ownSecret:GetText() == "friend-4827"
        and #failedWorld.joinCalls == 1, "a friend's key can be saved immediately when no group exists")
    assert(not contains(failedMessages, "private generator failure") and not contains(failedMessages, "friend-4827"))
end

-- Do not replace damaged or newer-schema saved keys while opening welcome.
do
    local invalidSettings = settings("damaged secret", false)
    invalidSettings.showWelcome = true
    local invalid, invalidEnvironment, _, _, invalidWorld = loadAddon(invalidSettings, false)
    invalidEnvironment.math = setmetatable({ random = function()
        error("damaged stored keys must not be replaced")
    end }, { __index = math })
    loadOptions(invalid, invalidEnvironment)
    invalidWorld:initialize()
    assert(invalid.invalidGroupSecret and invalid.db.group.secret == "damaged secret"
        and invalid.welcomePanel.ownSecret:GetText() == "" and #invalidWorld.joinCalls == 0,
        "welcome preserves an invalid saved key for explicit repair")
    invalid.welcomePanel.done:Click()
    invalid:OpenWelcome()
    assert(invalid.db.group.secret == "damaged secret" and invalid.welcomePanel.friendSecret:IsEnabled(),
        "reopening does not silently replace damaged settings")

    local futureSettings = { schemaVersion = 4, showWelcome = true, important = "keep",
        group = { secret = SECRET }, chat = { autoJoin = false } }
    local future, futureEnvironment, _, _, futureWorld = loadAddon(futureSettings, false)
    futureEnvironment.math = setmetatable({ random = function()
        error("read-only preferences must not generate a key")
    end }, { __index = math })
    loadOptions(future, futureEnvironment)
    futureWorld:initialize()
    assert(future.savedDataReadOnly and future.welcomePanel == nil,
        "newer schemas do not automatically start setup")
    future:OpenWelcome()
    assert(not future.welcomePanel.friendSecret:IsEnabled() and not future.welcomePanel.joinGroup:IsEnabled()
        and future.welcomePanel.ownSecret:GetText() == "", "read-only welcome disables saved edits")
    future.welcomePanel.joinGroup:Click()
    assert(futureEnvironment.LockInToolsDB == futureSettings and futureSettings.schemaVersion == 4
        and futureSettings.group.secret == SECRET and futureSettings.important == "keep"
        and futureSettings.showWelcome and not futureSettings.chat.autoJoin and #futureWorld.joinCalls == 0,
        "opening read-only welcome leaves the original saved data untouched")
end

assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep test environments isolated")
print("PASS: startup, migration, shared identity, protected chat, retries, group lifecycle, options and welcome")

