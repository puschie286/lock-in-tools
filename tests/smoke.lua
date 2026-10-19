-- This harness is never loaded by the addon.
-- Server membership changes are asynchronous, as they are in the client.
local function loadAddon(savedVariables, loggedIn)
    local messages, frames, timers = {}, {}, {}
    local world = {
        now = 0, channels = {}, joinCalls = {}, leaveCalls = {},
        addCalls = {}, passwordCalls = {}, roster = {}, openedChat = {},
        dataJoinCalls = {}, dataLeaveCalls = {}, dataSends = {}, prefixes = {},
        resolverCalls = {}, callbacks = {}, hookCalls = {}, chatFrames = {}, removeCalls = {},
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
    local environment
    local function capture(...) return { n = select("#", ...), ... } end
    local function newEditBox()
        local header = {}
        function header:SetText(text) self.text = text end
        function header:SetFormattedText(format, ...)
            self.formattedCalls = (self.formattedCalls or 0) + 1
            self:SetText(string.format(format, ...))
        end
        function header:GetWidth() return #(self.text or "") end
        local box = { header = header }
        function box:SetChatType(chatType) self.chatType = chatType end
        function box:SetChannelTarget(target) self.channelTarget = target end
        function box:GetHeader() return self.header end
        function box:UpdateHeader()
            if self.chatType ~= "CHANNEL" then return end
            local id, name = environment.GetChannelName(self.channelTarget)
            self.header:SetFormattedText(environment.CHAT_CHANNEL_SEND, id, name)
            self.measuredHeaderWidth = self.header:GetWidth()
        end
        return box
    end
    local function newChatFrame()
        local frame = { channelList = {}, zoneChannelList = {}, editBox = newEditBox(), id = #world.chatFrames + 1 }
        function frame:AddMessage(message) messages[#messages + 1] = message end
        function frame:GetID() return self.id end
        function frame:GetEditBox() return self.editBox end
        function frame:AddChannel(name)
            world.addCalls[#world.addCalls + 1] = name
            self.channelList[#self.channelList + 1] = name
            self.zoneChannelList[#self.zoneChannelList + 1] = 0
        end
        function frame:RemoveChannel(name)
            world.removeCalls[#world.removeCalls + 1] = { frame = self, name = name }
            for index = #self.channelList, 1, -1 do
                if self.channelList[index]:lower() == name:lower() then
                    table.remove(self.channelList, index)
                    table.remove(self.zoneChannelList, index)
                end
            end
        end
        world.chatFrames[#world.chatFrames + 1] = frame
        return frame
    end
    local chatFrame = newChatFrame()
    local editBox = chatFrame.editBox
    local function openChat(text, frame)
        world.openedChat[#world.openedChat + 1] = { text = text, frame = frame }
        return editBox
    end
    environment = setmetatable({
        LockInToolsDB = savedVariables,
        SlashCmdList = {},
        C_AddOns = {
            GetAddOnMetadata = function(name, field)
                assert(name == "LockInTools" and field == "Version")
                return "0.2.0"
            end,
        },
        C_Timer = { NewTimer = newTimer, After = newTimer },
        Enum = {
            RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1 },
            SendAddonMessageResult = { Success = 0 },
        },
        GetTime = function() return world.now end,
        GetServerTime = function() return 2000000000 + math.floor(world.now) end,
        GetNormalizedRealmName = function() return "TestRealm" end,
        UnitFullName = function(unit) assert(unit == "player"); return "Self", "Test Realm" end,
        C_Map = {
            GetBestMapForUnit = function() return 37 end,
            GetPlayerMapPosition = function()
                return { GetXY = function() return 0.25, 0.75 end }
            end,
        },
        DEFAULT_CHAT_FRAME = chatFrame,
        CHAT_CHANNEL_SEND = "%s. %s: ",
        ChatFrameUtil = {
            ChooseBoxForSend = function() return editBox end,
            OpenChat = openChat,
            ForEachChatFrame = function(callback)
                for _, frame in ipairs(world.chatFrames) do callback(frame) end
            end,
            ResolvePrefixedChannelName = function(...)
                local arguments = capture(...)
                world.resolverCalls[#world.resolverCalls + 1] = arguments
                return arguments[1], "native-result", nil, "native-tail"
            end,
        },
        EventRegistry = {
            RegisterCallback = function(_, event, callback, owner)
                local callbacks = world.callbacks[event] or {}
                world.callbacks[event] = callbacks
                callbacks[#callbacks + 1] = { callback = callback, owner = owner }
            end,
        },
        hooksecurefunc = function(object, methodName, callback)
            assert(type(object) == "table" and type(methodName) == "string" and type(callback) == "function",
                "chat display uses named object method hooks")
            local original = assert(object[methodName], "hooked methods must exist")
            world.hookCalls[object] = (world.hookCalls[object] or 0) + 1
            object[methodName] = function(...)
                local result = capture(original(...))
                callback(...)
                return unpack(result, 1, result.n)
            end
        end,
        issecretvalue = function(value) return world.secretValue ~= nil and value == world.secretValue end,
        GetChannelName = function(identifier)
            local channel = channelByName(identifier)
            if channel then return channel.id, channel.name end
            return 0, nil
        end,
        GetChannelList = function()
            local channels, result = {}, {}
            for _, channel in pairs(world.channels) do channels[#channels + 1] = channel end
            table.sort(channels, function(first, second) return first.id < second.id end)
            for _, channel in ipairs(channels) do
                result[#result + 1] = channel.id
                result[#result + 1] = channel.name
                result[#result + 1] = false
            end
            return unpack(result)
        end,
        JoinPermanentChannel = function(name, password, frameID)
            assert(type(password) == "string" and #password == 31, "every join uses a derived password")
            assert(frameID == 1, "join into the default native chat frame")
            world.joinCalls[#world.joinCalls + 1] = name
            world.lastJoinPassword = password
            return 0, name
        end,
        JoinTemporaryChannel = function(name, password)
            assert(name:match("^LITDATA") and type(password) == "string" and #password == 31,
                "group data uses its own derived credentials")
            world.dataJoinCalls[#world.dataJoinCalls + 1] = name
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
        C_ChatInfo = {
            GetChannelRosterInfo = function(displayIndex, rosterIndex)
                local member = world.roster[displayIndex].members[rosterIndex]
                return member.name, member.owner, member.moderator, member.guid
            end,
            RegisterAddonMessagePrefix = function(prefix)
                if world.prefixes[prefix] then return 1 end
                world.prefixes[prefix] = true
                return 0
            end,
            SendAddonMessage = function(prefix, message, distribution, target)
                assert(distribution == "CHANNEL", "production data does not send whispers")
                world.dataSends[#world.dataSends + 1] = {
                    prefix = prefix, message = message, target = target,
                }
                return 0
            end,
        },
        LeaveChannelByName = function(name)
            local calls = name:lower():match("^litdata") and world.dataLeaveCalls or world.leaveCalls
            calls[#calls + 1] = name
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
    environment._G = environment
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
    function world:showEditBox(box)
        for _, registration in ipairs(self.callbacks["ChatFrame.OnEditBoxShow"] or {}) do
            registration.callback(registration.owner, box)
        end
    end
    function world:renderChannelMessage(id, name, text)
        local label = environment.ChatFrameUtil.ResolvePrefixedChannelName(id .. ". " .. name)
        return "|Hchannel:CHANNEL:" .. id .. "|h[" .. label .. "]|h " .. text
    end
    world.newEditBox = newEditBox
    function world:newChatFrame() return newChatFrame() end
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
assert(#world.joinCalls == 0 and #world.dataJoinCalls == 0,
    "an unconfigured group must not join a channel")
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
assert(#olderWorld.joinCalls == 0 and #olderWorld.dataJoinCalls == 0,
    "read-only startup does not join either group channel")
for _, damaged in ipairs({ false, "invalid", { schemaVersion = "bad", showWelcome = "bad", chat = "bad" } }) do
    local repaired, _, _, _, repairedWorld = loadAddon(damaged, true)
    repairedWorld:initialize()
    assert(repaired.ready and repaired.db.schemaVersion == 3 and repaired.db.showWelcome == true)
    assert(type(repaired.db.chat) == "table" and not repaired:HasGroup())
end

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
    assert(connected:SetPositionSharing(false))
    connectedWorld:advance(2)
    assert(#connectedWorld.dataSends == 1 and connected:IsDataConnected()
        and next(connected:GetSharedPositions()) == nil, "position switch leaves the shared pipeline connected")
    connectedCommand("data leave")
    connectedWorld.fire("PLAYER_ENTERING_WORLD")
    connectedWorld:advance(30)
    assert(not connected:IsDataConnected() and #connectedWorld.dataJoinCalls == 1
        and connectedWorld.dataLeaveCalls[1] == dataRoom and connectedWorld.channels[chatRoom:lower()],
        "leaving data pauses retries and preserves native human chat")
    connectedCommand("data join")
    assert(#connectedWorld.dataJoinCalls == 2 and not connected:IsDataConnected())
    connectedWorld:completeJoin(dataRoom, 14)
    assert(connected:IsDataConnected())
    assert(connected:SetPositionSharing(true))
    connectedWorld:advance(2)
    assert(#connectedWorld.dataSends == 2 and connectedWorld.dataSends[2].target == "14",
        "reconnected positions use the current local channel number")
    connectedWorld:restore("Unrelated", 19)
    assert(connected:SetGroupSecret(OTHER_SECRET))
    assert(not connected:IsDataConnected() and next(connected.db.position.peers) == nil
        and next(connected:GetSharedPositions()) == nil and not connectedWorld.channels[dataRoom:lower()],
        "group switching disconnects old data before clearing feature caches")
    connectedWorld:advance(1)
    assert(connectedWorld.dataJoinCalls[3] == connected:GetGroupDataChannelName()
        and connectedWorld.channels.unrelated and not connected.db.chat.autoJoin,
        "group switching reconnects data without changing chat preferences or unrelated channels")
    assert(not contains(connectedMessages, SECRET) and not contains(connectedMessages, OTHER_SECRET))
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
    primary:AddChannel(newChat)
    secondary:AddChannel(newData)
    clock:completeJoin(newChat, 4)
    clock:completeJoin(newData, 5)
    assert(not clock.channels[newChat:lower()] and not clock.channels[newData:lower()]
        and #primary.channelList == 0 and #secondary.channelList == 0 and not switching:IsDataConnected(),
        "late native joins are still left when no group remains configured")
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

-- Exercise the real options callbacks against strict native-widget stubs.
local function loadOptions(uiAddon, uiEnvironment)
    local createEventFrame = uiEnvironment.CreateFrame
    uiEnvironment.namedFrameCreations = {}
    local methods = {}
    local function makeWidget()
        return setmetatable({ scripts = {}, handlers = {}, hooks = {}, enabled = true, shown = true }, { __index = methods })
    end
    local function updateScript(widget, script)
        if not widget.handlers[script] and not widget.hooks[script] then
            widget.scripts[script] = nil
            return
        end
        widget.scripts[script] = function(...)
            if widget.handlers[script] then widget.handlers[script](...) end
            for _, callback in ipairs(widget.hooks[script] or {}) do callback(...) end
        end
    end
    for _, name in ipairs({ "SetPoint", "SetAllPoints", "SetFrameStrata", "SetClampedToScreen",
        "SetMovable", "EnableMouse", "RegisterForDrag", "StartMoving", "StopMovingOrSizing",
        "SetJustifyH", "SetAutoFocus", "SetTextInsets", "Raise" }) do
        methods[name] = function() end
    end
    function methods:SetSize(width, height) self.width, self.height = width, height end
    function methods:SetWidth(width) self.width = width end
    function methods:SetHeight(height) self.height = height end
    function methods:GetWidth() return self.width or 0 end
    function methods:GetHeight() return self.height or 0 end
    function methods:SetColorTexture(...)
        self.textureColor = { ... }
        if self.parent then self.parent.texturePaints = (self.parent.texturePaints or 0) + 1 end
    end
    function methods:SetVertexColor(...) self.vertexColor = { ... } end
    function methods:SetTexture(texture) self.texture = texture end
    function methods:SetParent(parent) self.parent = parent end
    function methods:SetScale(scale) self.scale = scale end
    function methods:SetFont(path, size, flags) self.font = { path, size, flags }; return true end
    function methods:GetFont() return unpack(self.font or { "Fonts\\FRIZQT__.TTF", 12, "" }) end
    function methods:SetFontObject(fontObject) self.fontObject = fontObject end
    function methods:SetAlpha(alpha) self.alpha = alpha end
    function methods:SetText(text)
        self.text = text
        if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self, false) end
    end
    function methods:GetText() return self.text or "" end
    function methods:SetTextColor(red, green, blue) self.color = { red, green, blue } end
    function methods:SetEnabled(enabled)
        local changed = self.enabled ~= enabled
        self.enabled = enabled
        local callback = self.scripts[enabled and "OnEnable" or "OnDisable"]
        if changed and callback and (self.frameType == "Button" or self.frameType == "CheckButton") then
            callback(self)
        end
    end
    function methods:IsEnabled() return self.enabled end
    function methods:SetChecked(checked) self.checked = checked end
    function methods:GetChecked() return self.checked end
    function methods:ClearFocus()
        local wasFocused = self.focused
        self.focusCleared, self.focused = true, false
        if wasFocused and self.scripts.OnEditFocusLost then self.scripts.OnEditFocusLost(self) end
    end
    function methods:SetFocus()
        local wasFocused = self.focused
        self.focused, self.focusCleared = true, false
        if not wasFocused and self.scripts.OnEditFocusGained then self.scripts.OnEditFocusGained(self) end
    end
    function methods:HighlightText() self.highlighted = true end
    function methods:SetPassword(password) self.password = password end
    function methods:SetFontString(fontString) self.fontString = fontString end
    function methods:GetFontString() return self.fontString end
    function methods:SetCheckedTexture(texture)
        if type(texture) ~= "table" then
            local path = texture
            texture = makeWidget()
            texture:SetTexture(path)
        end
        self.checkedTexture = texture
    end
    function methods:GetCheckedTexture() return self.checkedTexture end
    function methods:SetDisabledCheckedTexture(texture) self.disabledCheckedTexture = texture end
    local function checkScript(widget, script)
        assert(widget.frameType ~= "EditBox" or (script ~= "OnEnable" and script ~= "OnDisable"),
            "native EditBoxes do not support button enable/disable scripts")
    end
    function methods:SetScript(script, callback)
        checkScript(self, script)
        self.handlers[script] = callback
        updateScript(self, script)
    end
    function methods:GetScript(script) return self.handlers[script] end
    function methods:HookScript(script, callback)
        checkScript(self, script)
        self.hooks[script] = self.hooks[script] or {}
        table.insert(self.hooks[script], callback)
        updateScript(self, script)
    end
    function methods:CreateFontString() return makeWidget() end
    function methods:CreateTexture()
        local texture = makeWidget()
        texture.parent = self
        return texture
    end
    function methods:IsShown() return self.shown end
    function methods:IsVisible()
        return self.shown and (not self.parent or not self.parent.IsVisible or self.parent:IsVisible())
    end
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
        assert(self:IsVisible(), "hidden fields do not accept user input")
        self.text = text
        if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self, true) end
    end
    uiEnvironment.CreateFrame = function(frameType, name, parent, template)
        if frameType == "Frame" and not name and not template and not parent then
            return createEventFrame(frameType)
        end
        assert(frameType == "Frame" or frameType == "EditBox"
            or frameType == "CheckButton" or frameType == "Button", "use supported native widgets")
        local widget = makeWidget()
        widget.frameType, widget.name, widget.parent, widget.template = frameType, name, parent, template
        if template == "BasicFrameTemplateWithInset" then widget.TitleText = makeWidget() end
        if name then
            uiEnvironment[name] = widget
            uiEnvironment.namedFrameCreations[name] = (uiEnvironment.namedFrameCreations[name] or 0) + 1
        end
        return widget
    end
    uiEnvironment.UIParent, uiEnvironment.UISpecialFrames = makeWidget(), {}
    uiEnvironment._G = uiEnvironment
    uiEnvironment.tinsert = table.insert
    uiEnvironment.hooksecurefunc = function(object, methodName, callback)
        assert(type(object) == "table" and type(methodName) == "string" and type(callback) == "function",
            "this harness supports named object method hooks")
        local original = assert(object[methodName], "hooked methods must exist")
        local function capture(...) return { n = select("#", ...), ... } end
        object[methodName] = function(...)
            local result = capture(original(...))
            callback(...)
            return unpack(result, 1, result.n)
        end
    end
    for _, file in ipairs({ "Theme.lua", "Options.lua" }) do
        local chunk, problem
        if setfenv then
            chunk, problem = loadfile(file)
            assert(chunk, problem)
            setfenv(chunk, uiEnvironment)
        else
            chunk, problem = loadfile(file, "t", uiEnvironment)
            assert(chunk, problem)
        end
        chunk("LockInTools", uiAddon)
    end
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
panel.tabs.position:Click()
panel.positionSharing:SetChecked(true)
panel.positionRetention:SetChecked(false)
panel.tabs.chat:Click()
panel.autoJoin:SetChecked(true)
panel.save:Click()
assert(uiAddon.db.chat.autoJoin and #uiWorld.joinCalls == 1)
assert(not uiAddon.db.position.sharing and uiAddon.db.position.keepLastKnown,
    "saving chat does not apply position preference drafts")
panel.tabs.position:Click()
panel.savePosition:Click()
assert(uiAddon.db.position.sharing and not uiAddon.db.position.keepLastKnown
    and uiAddon.db.chat.autoJoin and #uiWorld.joinCalls == 1,
    "position settings save independently of chat and do not request a chat join")
panel.tabs.chat:Click()
panel.autoJoin:SetChecked(false)
panel.tabs.position:Click()
panel.positionSharing:SetChecked(false)
panel.positionRetention:SetChecked(true)
panel.tabs.group:Click()
panel.secret:SetText(OTHER_SECRET)
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
panel.tabs.chat:Click()
panel.join:Click()
assert(uiWorld.joinCalls[#uiWorld.joinCalls] == room and panel.secret:GetText() == "",
    "Join uses the saved group after navigating away clears the key draft")
panel.leave:Click()
assert(uiWorld.leaveCalls[#uiWorld.leaveCalls] == room and uiAddon:HasGroup(), "chat leave retains group")
panel.tabs.group:Click()
panel.secret:SetText(OTHER_SECRET)
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
panel.tabs.chat:Click()
panel.autoJoin:SetChecked(false)
panel.tabs.group:Click()
panel.secret:SetText(SECRET)
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
readOnly.optionsPanel.tabs.chat:Click()
assert(readOnly.optionsPanel.feedback:GetText():find("Update LockInTools", 1, true)
    and not readOnly.optionsPanel.autoJoin:IsEnabled(), "category changes retain the read-only notice and disabled edits")

-- Options use one category window and navigate back to the same welcome window.
do
    local navigation, navigationEnvironment, _, _, navigationWorld = loadAddon(settings(SECRET, false), false)
    navigationWorld:initialize()
    loadOptions(navigation, navigationEnvironment)
    local command = navigationEnvironment.SlashCmdList.LOCKINTOOLS
    command("options")
    local options = navigation.optionsPanel
    assert(options.selectedTab == "group" and options.tabs.group.themeTab.selected
        and not options.tabs.chat.themeTab.selected and options.pages.group:IsVisible()
        and not options.pages.chat:IsVisible() and not options.pages.position:IsVisible(),
        "options initially show only the group category")
    assert(options.welcome:GetText() == "Back to welcome", "options provide an explicit return to welcome")
    options.secret:UserInput(OTHER_SECRET)
    options.secret:SetFocus()
    options.applyGroup:Click()
    command("options")
    options.tabs.group:Click()
    assert(navigation.optionsPanel == options and options.secret:GetText() == OTHER_SECRET
        and options.applyGroup:GetText() == "Confirm switch" and options.secret.focused,
        "reopening visible options or choosing the current category preserves pending group edits")
    options.tabs.chat:Click()
    assert(options.selectedTab == "chat" and options.pages.chat:IsVisible()
        and not options.pages.group:IsVisible() and not options.pages.position:IsVisible()
        and options.secret:GetText() == "" and options.secret.password and options.secret.focusCleared
        and options.applyGroup:GetText() == "Use key" and options.leaveGroup:GetText() == "Leave group"
        and options.feedback:GetText() == "",
        "leaving group hides its page and clears key drafts, focus and confirmation")
    options.autoJoin:SetChecked(true)
    navigationWorld:completeJoin(navigation:GetGroupChannelName(), 9)
    assert(options.secret:GetText() == "" and options.autoJoin:GetChecked() and not navigation.db.chat.autoJoin,
        "status updates on another category cannot restore keys or apply preference drafts")
    options.tabs.position:Click()
    options.positionSharing:SetChecked(true)
    options.positionRetention:SetChecked(false)
    options.tabs.chat:Click()
    assert(options.autoJoin:GetChecked() and not navigation.db.chat.autoJoin,
        "chat preferences remain drafts while visiting another category")
    options.tabs.position:Click()
    command("options")
    assert(options.selectedTab == "position" and options.pages.position:IsVisible()
        and not options.pages.group:IsVisible() and not options.pages.chat:IsVisible()
        and options.positionSharing:GetChecked() and not options.positionRetention:GetChecked()
        and not navigation.db.position.sharing and navigation.db.position.keepLastKnown
        and navigationEnvironment.namedFrameCreations.LockInToolsOptions == 1,
        "repeated options commands reuse the same category window and preserve its unsaved preferences")
    options.welcome:Click()
    local welcome = navigation.welcomePanel
    assert(welcome and welcome:IsVisible() and not options:IsVisible()
        and welcome.ownSecret:GetText() == SECRET and navigation:GetGroupSecret() == SECRET,
        "Back to welcome opens the saved key and closes options")
    welcome.friendSecret:UserInput(OTHER_SECRET)
    welcome.joinGroup:Click()
    welcome.options:Click()
    assert(options:IsVisible() and not welcome:IsVisible() and options.selectedTab == "position"
        and not options.positionSharing:GetChecked() and options.positionRetention:GetChecked()
        and welcome.ownSecret:GetText() == "" and welcome.friendSecret:GetText() == ""
        and welcome.joinGroup:GetText() == "Join friend",
        "welcome navigation closes and cleans its form while reusing the selected options category")
    options.tabs.group:Click()
    options.leaveGroup:Click()
    assert(options.leaveGroup:GetText() == "Confirm leave", "leaving a group still requires confirmation")
    options.toggleSecret:Click()
    command("welcome")
    assert(welcome:IsVisible() and not options:IsVisible() and options.secret:GetText() == ""
        and options.secret.password and options.leaveGroup:GetText() == "Leave group"
        and navigation:GetGroupSecret() == SECRET,
        "the welcome command clears options secrets and confirmations while enforcing window exclusivity")
    command("options")
    assert(options:IsVisible() and not welcome:IsVisible() and welcome.ownSecret:GetText() == "",
        "the options command also closes and cleans an existing welcome window")
    command("")
    assert(welcome:IsVisible() and not options:IsVisible()
        and navigationEnvironment.namedFrameCreations.LockInToolsOptions == 1
        and navigationEnvironment.namedFrameCreations.LockInToolsWelcome == 1,
        "all navigation paths keep one instance of each window")
end

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
    local unfocusedPaints = welcome.ownSecret.texturePaints
    welcome.ownSecret:SetFocus()
    assert(welcome.ownSecret.highlighted and welcome.ownSecret.texturePaints > unfocusedPaints,
        "focusing the saved key keeps both copy highlighting and the native focus outline")
    welcome.ownSecret:ClearFocus()
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

-- Optional skins must preserve lazy creation and the forms' existing behavior.
local function skinFixture()
    local state = { font = "SkinFont-A.ttf", accent = { 0.2, 0.8, 0.4 }, looks = {}, shells = 0, tabs = 0 }
    local skin = {}
    function skin.Shell(window)
        state.shells = state.shells + 1
        window.skinApplied = true
    end
    for _, name in ipairs({ "Panel", "Button", "CloseButton", "EditBox", "Checkbox", "StateButtonLabel" }) do
        skin[name] = function() end
    end
    function skin.Font(region)
        local _, size, flags = region:GetFont()
        region:SetFont(state.font, size, flags)
    end
    function skin.GetAccentColor() return unpack(state.accent) end
    function skin.Tab(button)
        state.tabs = state.tabs + 1
        button.skinTabApplied = true
    end
    function skin.SetTabSelection(button, selected) button.skinTabSelected = selected end
    function skin.OnLooksChanged(callback) state.looks[#state.looks + 1] = callback end
    return skin, state
end

local function loadSkinnedOptions(registerSkin)
    local skinned, skinEnvironment, skinMessages, _, skinWorld = loadAddon(settings(SECRET, false), false)
    skinEnvironment.EllesmereUI = { RegisterSkin = registerSkin }
    skinWorld:initialize()
    loadOptions(skinned, skinEnvironment)
    return skinned, skinEnvironment, skinMessages, skinWorld
end

do
    local registration, registrations = nil, 0
    local disabled, disabledEnvironment = loadSkinnedOptions(function(name, callback)
        assert(name == "LockInTools", "the optional skin uses the addon identity")
        registrations = registrations + 1
        registration = callback
    end)
    assert(registrations == 1 and type(registration) == "function"
        and not disabled.optionsPanel and not disabled.welcomePanel,
        "registering an installed but disabled skin does not construct windows")
    registration(nil)
    registration("unsupported")
    disabledEnvironment.UIParent:SetSize(640, 480)
    disabled:OpenOptions()
    disabled:OpenWelcome()
    assert(not disabled.optionsPanel.skinApplied and not disabled.welcomePanel.skinApplied
        and disabled.optionsPanel.TitleText.font[1] == "Fonts\\FRIZQT__.TTF"
        and disabled:GetGroupSecret() == SECRET and registrations == 1,
        "disabled or invalid optional skins retain usable native windows and the saved key")
    assert(disabled.optionsPanel.scale > 0 and disabled.optionsPanel.scale < 1
        and disabled.optionsPanel:GetWidth() * disabled.optionsPanel.scale <= disabledEnvironment.UIParent:GetWidth()
        and disabled.optionsPanel:GetHeight() * disabled.optionsPanel.scale <= disabledEnvironment.UIParent:GetHeight()
        and disabled.welcomePanel:GetHeight() * disabled.welcomePanel.scale <= disabledEnvironment.UIParent:GetHeight(),
        "both native windows fit a viewport smaller than their preferred size")
    disabled:OpenOptions()
    disabled.optionsPanel.secret:UserInput(OTHER_SECRET)
    disabled.optionsPanel.applyGroup:Click()
    disabled.optionsPanel.CloseButton:Click()
    assert(not disabled.optionsPanel:IsShown() and disabled.optionsPanel.secret:GetText() == ""
        and disabled.optionsPanel.secret.password and disabled:GetGroupSecret() == SECRET,
        "the native title-bar close button clears drafts without confirming a group switch")
    disabledEnvironment.UIParent:SetSize(1920, 1080)
    disabled:OpenOptions()
    assert(disabled.optionsPanel.scale == 1 and disabled.optionsPanel.applyGroup:GetText() == "Use key",
        "reopening on a larger viewport restores normal scale and resets confirmation")
end

do
    local skin, appearance = skinFixture()
    local early, _, earlyMessages = loadSkinnedOptions(function(_, callback) callback(skin) end)
    assert(not early.optionsPanel and not early.welcomePanel and appearance.shells == 0,
        "an enabled skin callback before first use preserves lazy windows")
    early:OpenWelcome()
    local welcome = early.welcomePanel
    assert(welcome.skinApplied and welcome.TitleText.font[1] == appearance.font
        and welcome.TitleText.font[2] == 16
        and welcome.ownSecret:GetText() == SECRET,
        "a window created after the skin callback receives its font while preserving heading size")
    welcome.friendSecret:UserInput(OTHER_SECRET)
    welcome.joinGroup:Click()
    welcome.friendSecret:SetFocus()
    appearance.font = "SkinFont-B.ttf"
    appearance.accent = { 0.9, 0.3, 0.6 }
    for _, callback in ipairs(appearance.looks) do callback() end
    assert(welcome.TitleText.font[1] == appearance.font and welcome.friendSecret.focused
        and welcome.friendSecret:GetText() == OTHER_SECRET and welcome.joinGroup:GetText() == "Confirm switch"
        and early:GetGroupSecret() == SECRET,
        "live appearance updates preserve focus, key drafts and pending confirmation")
    early:OpenOptions()
    local options = early.optionsPanel
    assert(options.skinApplied and options.TitleText.font[1] == appearance.font
        and options.positionSharing:GetCheckedTexture().vertexColor[1] == appearance.accent[1]
        and appearance.shells == 2,
        "a later-created settings window uses the current font and accent")
    options.tabs.position:Click()
    assert(options.tabs.position.skinTabApplied and options.tabs.position.skinTabSelected
        and not options.tabs.group.skinTabSelected and not options.tabs.chat.skinTabSelected,
        "the optional skin selects exactly the active category tab")
    options.tabs.position.scripts.OnEnter(options.tabs.position)
    options.tabs.position.scripts.OnLeave(options.tabs.position)
    assert(options.tabs.position:GetFontString().alpha == 0,
        "selecting and hovering a skinned tab keeps its replaced native label hidden")
    appearance.accent = { 0.4, 0.6, 1 }
    for _, callback in ipairs(appearance.looks) do callback() end
    assert(options.positionSharing:GetCheckedTexture().vertexColor[1] == appearance.accent[1]
        and options.positionSharing:GetCheckedTexture().vertexColor[3] == appearance.accent[3]
        and options.selectedTab == "position" and options.pages.position:IsVisible()
        and options.tabs.position.skinTabSelected and not options.tabs.group.skinTabSelected
        and options.tabs.position:GetFontString().alpha == 0,
        "appearance updates refresh accents while retaining the active category and its skin selection")
    early:OpenWelcome()
    welcome.friendSecret:UserInput(OTHER_SECRET)
    welcome.joinGroup:Click()
    welcome.CloseButton:Click()
    assert(not welcome:IsShown() and welcome.ownSecret:GetText() == "" and welcome.friendSecret:GetText() == "",
        "the styled title-bar close button keeps hidden-key cleanup")
    for _, callback in ipairs(appearance.looks) do callback() end
    assert(welcome.ownSecret:GetText() == "" and welcome.friendSecret:GetText() == "",
        "restyling a hidden window never restores cleared keys")
    early:OpenWelcome()
    assert(welcome.ownSecret:GetText() == SECRET and welcome.joinGroup:GetText() == "Join friend"
        and appearance.shells == 2 and #appearance.looks == 1,
        "reopening reuses styled windows and clears pending confirmation without repeating skin registration")
    assert(not contains(earlyMessages, SECRET) and not contains(earlyMessages, OTHER_SECRET),
        "skin refresh never prints key fields")
end

do
    local registration
    local late, _, _, lateWorld = loadSkinnedOptions(function(_, callback) registration = callback end)
    late:OpenOptions()
    local options = late.optionsPanel
    options.tabs.chat:Click()
    options.autoJoin:SetChecked(true)
    options.tabs.group:Click()
    options.secret:UserInput(OTHER_SECRET)
    options.applyGroup:Click()
    local skin, appearance = skinFixture()
    registration(skin)
    assert(options.skinApplied and options.TitleText.font[1] == appearance.font
        and options.secret:GetText() == OTHER_SECRET and options.applyGroup:GetText() == "Confirm switch"
        and options.autoJoin:GetChecked() and not late.db.chat.autoJoin,
        "a late skin callback styles existing windows without applying their unsaved drafts")
    options.applyGroup:Click()
    assert(late:GetGroupSecret() == OTHER_SECRET and options.secret:GetText() == ""
        and options.secret.password and #lateWorld.joinCalls == 0,
        "confirmation and hidden-key rules still work after skinning an open form")
end

do
    local skin, appearance = skinFixture()
    skin.SetTabSelection = nil
    local partial = loadSkinnedOptions(function(_, callback) callback(skin) end)
    partial:OpenOptions()
    local options = partial.optionsPanel
    options.tabs.chat:Click()
    for _, callback in ipairs(appearance.looks) do callback() end
    assert(appearance.tabs == 0 and not options.tabs.chat.skinTabApplied
        and options.selectedTab == "chat" and options.pages.chat:IsVisible()
        and not options.pages.group:IsVisible() and options.tabs.chat.themeTab.selected
        and options.tabs.chat:GetFontString().alpha ~= 0,
        "a skin without tab-selection support leaves native category navigation usable")
end

do
    local broken = loadSkinnedOptions(function() error("optional registration failure") end)
    broken:OpenOptions()
    assert(broken.optionsPanel:IsShown() and broken:GetGroupSecret() == SECRET,
        "optional registration failure cannot block native settings")
    local throwing = {}
    for _, name in ipairs({ "Shell", "Panel", "Button", "CloseButton", "EditBox", "Checkbox",
        "StateButtonLabel", "Font", "GetAccentColor", "OnLooksChanged" }) do
        throwing[name] = function() error("optional appearance failure") end
    end
    local resilient, _, resilientMessages = loadSkinnedOptions(function(_, callback) callback(throwing) end)
    resilient:OpenWelcome()
    resilient.welcomePanel.friendSecret:UserInput(OTHER_SECRET)
    resilient.welcomePanel.joinGroup:Click()
    resilient.welcomePanel.joinGroup:Click()
    resilient.welcomePanel.CloseButton:Click()
    assert(resilient:GetGroupSecret() == OTHER_SECRET and not resilient.welcomePanel:IsShown()
        and resilient.welcomePanel.ownSecret:GetText() == "" and resilient.welcomePanel.friendSecret:GetText() == "",
        "throwing skin methods cannot block group confirmation or hidden-key cleanup")
    assert(resilient.welcomePanel.CloseButton:GetFontString().alpha ~= 0,
        "failed close-button skinning keeps the native close symbol visible")
    assert(not contains(resilientMessages, "optional appearance failure") and not contains(resilientMessages, OTHER_SECRET),
        "optional skin errors do not expose internal errors or key contents")
end

assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep test environments isolated")
print("PASS: startup, migration, shared identity, chat/data connections, positions, retries, group lifecycle, themed options and welcome")

