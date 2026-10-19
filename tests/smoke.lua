-- This harness is never loaded by the addon.
-- Server membership changes are asynchronous, as they are in the client.
local function isRosterMessage(message)
    return message:match("^1|roster|") or message:match("^1|[QR]|roster|")
end

local function isStatusMessage(message)
    return message:match("^1|status|") or message:match("^1|[QR]|status|")
end

local function loadAddon(savedVariables, loggedIn)
    local messages, frames, timers = {}, {}, {}
    local world = {
        now = 0, channels = {}, joinCalls = {}, leaveCalls = {},
        addCalls = {}, passwordCalls = {}, roster = {}, openedChat = {},
        dataJoinCalls = {}, dataLeaveCalls = {}, dataSends = {}, rosterSends = {}, statusSends = {}, prefixes = {},
        resolverCalls = {}, callbacks = {}, hookCalls = {}, chatFrames = {}, removeCalls = {},
        optionsOpened = 0, contentOpened = 0, overviewOpened = 0, welcomeOpened = 0, minimapButtonCreations = 0,
        cursorX = 1000, cursorY = 600, cursorReads = 0,
        level = 12, xp = 0, xpMax = 1000, maxLevel = 60,
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
    local minimap = { width = 140, height = 140, scale = 1, x = 1000, y = 600, hooks = {} }
    function minimap:GetWidth() return self.width end
    function minimap:GetHeight() return self.height end
    function minimap:GetEffectiveScale() return self.scale end
    function minimap:GetCenter() return self.x, self.y end
    function minimap:GetFrameLevel() return 10 end
    function minimap:HookScript(script, callback)
        assert(script == "OnSizeChanged", "minimap only hooks size changes")
        self.hooks[#self.hooks + 1] = callback
    end
    function minimap:SetSize(width, height)
        self.width, self.height = width, height
        for _, callback in ipairs(self.hooks) do callback(self, width, height) end
    end
    local tooltip = { lines = {}, shown = false }
    function tooltip:SetOwner(owner, anchor) self.owner, self.anchor = owner, anchor end
    function tooltip:IsOwned(owner) return self.owner == owner end
    function tooltip:SetText(text) self.text, self.lines = text, {} end
    function tooltip:AddLine(text) self.lines[#self.lines + 1] = text end
    function tooltip:Show() self.shown = true end
    function tooltip:Hide() self.shown = false end
    function tooltip:IsShown() return self.shown end
    local function newMinimapButton(name, parent)
        assert(name == "LockInToolsMinimapButton" and parent == minimap,
            "the addon button uses a named native minimap child")
        world.minimapButtonCreations = world.minimapButtonCreations + 1
        local button = { name = name, parent = parent, scripts = {}, shown = true, textures = {} }
        function button:SetSize(width, height) self.width, self.height = width, height end
        function button:SetFrameStrata(strata) self.strata = strata end
        function button:SetFrameLevel(level) self.level = level end
        function button:RegisterForClicks(...) self.clicks = { ... } end
        function button:RegisterForDrag(...) self.drags = { ... } end
        function button:ClearAllPoints() self.point = nil end
        function button:SetPoint(...) self.point = { ... } end
        function button:SetHighlightTexture(texture) self.highlight = texture end
        function button:SetScript(script, callback) self.scripts[script] = callback end
        function button:GetScript(script) return self.scripts[script] end
        function button:CreateTexture()
            local texture = {}
            function texture:SetSize(width, height) self.width, self.height = width, height end
            function texture:SetPoint(...) self.point = { ... } end
            function texture:SetAllPoints() self.allPoints = true end
            function texture:SetTexture(path) self.path = path end
            function texture:SetTexCoord(...) self.texCoord = { ... } end
            button.textures[#button.textures + 1] = texture
            return texture
        end
        function button:Click(mouseButton) self.scripts.OnClick(self, mouseButton) end
        function button:Hide()
            self.shown = false
            if self.scripts.OnHide then self.scripts.OnHide(self) end
        end
        environment[name] = button
        return button
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
        Minimap = minimap,
        GameTooltip = tooltip,
        GetCursorPosition = function()
            world.cursorReads = world.cursorReads + 1
            return world.cursorX, world.cursorY
        end,
        GetMinimapShape = function() return world.minimapShape or "ROUND" end,
        GetServerTime = function() return 2000000000 + math.floor(world.now) end,
        GetNormalizedRealmName = function() return "TestRealm" end,
        UnitFullName = function(unit) assert(unit == "player"); return "Self", "Test Realm" end,
        UnitLevel = function(unit) assert(unit == "player"); return world.level end,
        UnitXP = function(unit) assert(unit == "player"); return world.xp end,
        UnitXPMax = function(unit) assert(unit == "player"); return world.xpMax end,
        GetMaxPlayerLevel = function() return world.maxLevel end,
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
                -- Keep feature assertions separate from independent presence and status traffic.
                local sends = isStatusMessage(message) and world.statusSends
                    or isRosterMessage(message) and world.rosterSends or world.dataSends
                sends[#sends + 1] = {
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
        CreateFrame = function(frameType, name, parent)
            if frameType == "Button" then return newMinimapButton(name, parent) end
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
    for _, file in ipairs({ "Core.lua", "Crypto.lua", "Group.lua", "Chat.lua", "Data.lua", "Position.lua", "Roster.lua", "Minimap.lua", "Commands.lua" }) do
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
    addon.OpenContent = function() world.contentOpened = world.contentOpened + 1 end
    addon.OpenOverview = function(self)
        world.overviewOpened = world.overviewOpened + 1
        self:OpenContent()
    end
    addon.OpenWelcome = function(self)
        world.welcomeOpened = world.welcomeOpened + 1
        self:OpenContent()
    end
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

-- Native minimap entry point, account-wide placement and saved-data safety.
do
    local function near(actual, expected)
        return type(actual) == "number" and math.abs(actual - expected) < 0.000001
    end
    local function at(button, parent, x, y)
        return button.point[1] == "CENTER" and button.point[2] == parent and button.point[3] == "CENTER"
            and near(button.point[4], x) and near(button.point[5], y)
    end
    local entry, api, entryMessages, entryEvent, entryWorld = loadAddon(settings(nil, false), false)
    entry:InitializeMinimapButton()
    assert(not entry.minimapButton and entryWorld.minimapButtonCreations == 0,
        "the minimap button waits until login")
    entryEvent("ADDON_LOADED", "LockInTools")
    assert(not entry.minimapButton and not entry.db.minimap,
        "saved-variable initialization does not create a button or minimap settings")
    entryEvent("PLAYER_LOGIN")
    local button = entry.minimapButton
    local diagonal = 78 / math.sqrt(2)
    assert(button and entryWorld.minimapButtonCreations == 1
        and api.LockInToolsMinimapButton == button and button.parent == api.Minimap
        and at(button, api.Minimap, -diagonal, -diagonal),
        "login creates one native button at the default minimap position")
    assert(button.width == 31 and button.height == 31 and button.strata == "MEDIUM" and button.level == 18
        and button.clicks[1] == "LeftButtonUp" and button.clicks[2] == "RightButtonUp"
        and button.drags[1] == "LeftButton" and not button.drags[2],
        "the native button registers both click actions and left-button dragging")
    entryEvent("PLAYER_LOGIN")
    entry:InitializeMinimapButton()
    assert(entryWorld.minimapButtonCreations == 1 and #api.Minimap.hooks == 1
        and not entry.optionsPanel and not entry.contentPanel and not entry.welcomePanel and not entry.db.minimap,
        "repeated login and initialization reuse the button without building windows or saving defaults")
    button:Click("LeftButton")
    button:Click("RightButton")
    button:Click("MiddleButton")
    assert(entryWorld.contentOpened == 1 and entryWorld.optionsOpened == 1
        and entryWorld.overviewOpened == 0 and entryWorld.welcomeOpened == 0,
        "left-click opens Content and right-click opens Settings while other clicks do nothing")
    button.scripts.OnEnter(button)
    assert(api.GameTooltip.shown and api.GameTooltip.owner == button and api.GameTooltip.anchor == "ANCHOR_LEFT"
        and api.GameTooltip.text == "LockInTools" and #api.GameTooltip.lines == 2
        and api.GameTooltip.lines[1] == "Left-click: Content" and api.GameTooltip.lines[2] == "Right-click: Settings",
        "hover labels the two screen shortcuts without a drag note")
    button.scripts.OnLeave(button)
    assert(not api.GameTooltip.shown)

    api.Minimap.scale = 2
    api.Minimap:SetSize(140, 100)
    entryWorld.cursorX, entryWorld.cursorY = (1000 + 78) * 2, (600 + 58) * 2
    button.scripts.OnDragStart(button)
    button.scripts.OnEnter(button)
    assert(button.scripts.OnUpdate and not api.GameTooltip.shown,
        "dragging installs cursor updates and suppresses the tooltip")
    button.scripts.OnUpdate(button)
    assert(at(button, api.Minimap, 78 / math.sqrt(2), 58 / math.sqrt(2)) and not entry.db.minimap,
        "dragging accounts for minimap scale and unequal radii without saving intermediate positions")
    local cursorReads = entryWorld.cursorReads
    entryWorld.cursorX, entryWorld.cursorY = 0, 0
    button.scripts.OnDragStop(button)
    assert(not button.scripts.OnUpdate and near(entry.db.minimap.angle, 45)
        and entryWorld.cursorReads == cursorReads
        and entryWorld.contentOpened == 1 and entryWorld.optionsOpened == 1 and entryWorld.welcomeOpened == 0,
        "drag stop saves the last displayed angle without a cursor resample or opening a window")
    api.Minimap:SetSize(200, 160)
    assert(at(button, api.Minimap, 108 / math.sqrt(2), 88 / math.sqrt(2)),
        "minimap resizing refreshes the saved angular placement")
    local resumed, resumedApi, _, resumedEvent, resumedWorld = loadAddon(entry.db, true)
    resumedEvent("ADDON_LOADED", "LockInTools")
    assert(resumed.ready and resumedWorld.minimapButtonCreations == 1
        and at(resumed.minimapButton, resumedApi.Minimap, diagonal, diagonal),
        "late loading restores account-wide placement during login initialization")

    entryWorld.cursorX, entryWorld.cursorY = (1000 - 108) * 2, 600 * 2
    button.scripts.OnDragStart(button)
    button.scripts.OnUpdate(button)
    cursorReads = entryWorld.cursorReads
    entryWorld.cursorX, entryWorld.cursorY = 0, 0
    button:Hide()
    assert(not button.scripts.OnUpdate and near(entry.db.minimap.angle, 180)
        and entryWorld.cursorReads == cursorReads and not api.GameTooltip.shown,
        "hiding mid-drag saves the displayed position and stops updates without sampling a hidden cursor")
    assert(not contains(entryMessages, SECRET), "minimap interaction never prints the group key")

    for _, invalid in ipairs({ false, "bad", { angle = "45" }, { angle = 0 / 0 },
        { angle = math.huge }, { angle = -math.huge } }) do
        local saved = settings(nil, false)
        saved.minimap = invalid
        local originalAngle = type(invalid) == "table" and invalid.angle
        local repaired, repairedApi, _, _, repairedWorld = loadAddon(saved, false)
        repairedWorld:initialize()
        assert(at(repaired.minimapButton, repairedApi.Minimap, -diagonal, -diagonal)
            and saved.minimap == invalid,
            "invalid and non-finite saved positions fall back without replacing their saved field")
        if type(invalid) == "table" then
            assert(invalid.angle == originalAngle or (invalid.angle ~= invalid.angle and originalAngle ~= originalAngle),
                "reading an invalid angle does not rewrite it")
        end
    end
    local normalizedSettings = settings(nil, false)
    normalizedSettings.minimap = { angle = -450, futureField = "keep" }
    local normalized, normalizedApi, _, _, normalizedWorld = loadAddon(normalizedSettings, false)
    normalizedWorld:initialize()
    assert(at(normalized.minimapButton, normalizedApi.Minimap, 0, -78)
        and normalizedSettings.minimap.angle == -450 and normalizedSettings.minimap.futureField == "keep",
        "finite saved angles normalize for placement while preserving saved data")

    local squareSettings = settings(nil, false)
    squareSettings.minimap = { angle = 45 }
    local square, squareApi, _, _, squareWorld = loadAddon(squareSettings, false)
    squareWorld.minimapShape = "SQUARE"
    squareWorld:initialize()
    assert(at(square.minimapButton, squareApi.Minimap, 78, 78),
        "square minimaps project diagonal placement onto their rim")
    squareWorld.minimapShape = "CORNER-TOPLEFT"
    squareApi.Minimap:SetSize(140, 140)
    assert(at(square.minimapButton, squareApi.Minimap, diagonal, diagonal),
        "other minimap shapes retain the circular placement fallback")

    local futureSettings = settings(nil, false)
    futureSettings.schemaVersion = 4
    futureSettings.minimap = { angle = 120, futureField = "keep" }
    local originalMinimap = futureSettings.minimap
    local readOnly, readOnlyApi, _, _, readOnlyWorld = loadAddon(futureSettings, false)
    readOnlyWorld:initialize()
    local readOnlyButton = readOnly.minimapButton
    readOnlyButton:Click("LeftButton")
    readOnlyButton:Click("RightButton")
    readOnlyWorld.cursorX, readOnlyWorld.cursorY = 1078, 600
    readOnlyButton.scripts.OnDragStart(readOnlyButton)
    readOnlyButton.scripts.OnUpdate(readOnlyButton)
    readOnlyButton.scripts.OnDragStop(readOnlyButton)
    assert(readOnlyWorld.contentOpened == 1 and readOnlyWorld.optionsOpened == 1 and readOnlyWorld.welcomeOpened == 0
        and at(readOnlyButton, readOnlyApi.Minimap, 78, 0)
        and readOnlyApi.LockInToolsDB == futureSettings and futureSettings.minimap == originalMinimap
        and originalMinimap.angle == 120 and originalMinimap.futureField == "keep"
        and futureSettings.schemaVersion == 4 and not readOnly.db.minimap,
        "read-only profiles permit button access and temporary dragging without writing any minimap settings")
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
assert(world.contentOpened == 1 and world.welcomeOpened == 0,
    "show Content after login when initial setup is enabled and no group is configured")
fire("PLAYER_LOGIN")
assert(#messages == 1 and world.contentOpened == 1, "do not repeat Content on duplicate login events")
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
    assert(not future:SetPositionTrailSettings(false, 5))
    local futureTrails, futureTrailLength = future:GetPositionTrailSettings()
    assert(futureTrails == true and futureTrailLength == 10
        and futureSettings.position.showTrails == "future-trails"
        and futureSettings.position.trailLength == "future-length",
        "Read-only startup uses safe trail defaults without repairing the original newer-schema data")
    futureWorld:advance(30)
    assert(not futureSettings.position.sharing and #futureWorld.dataJoinCalls == 0
        and #futureWorld.dataSends == 0, "read-only preferences cannot enable sharing or reconnect data")
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
    for _, name in ipairs({ "SetAllPoints", "SetFrameStrata", "SetClampedToScreen",
        "SetMovable", "EnableMouse", "RegisterForDrag",
        "SetJustifyH", "SetAutoFocus", "SetTextInsets", "SetMotionScriptsWhileDisabled", "Raise" }) do
        methods[name] = function() end
    end
    function methods:SetPoint(...) self.point = { ... } end
    function methods:GetPoint()
        local point = self.point
        if not point then return end
        if type(point[2]) == "number" then
            return point[1], self.parent, point[1], point[2], point[3] or 0
        end
        return point[1], point[2] or self.parent, point[3] or point[1], point[4] or 0, point[5] or 0
    end
    function methods:ClearAllPoints() self.point = nil end
    function methods:SetUserPlaced(placed) self.userPlaced = placed end
    function methods:StartMoving() self.moving, self.userPlaced = true, true end
    function methods:StopMovingOrSizing() self.moving = false end
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
    function methods:GetFrameLevel() return self.frameLevel or 0 end
    function methods:SetFrameLevel(level) self.frameLevel = level end
    function methods:EnableMouseWheel(enabled) self.mouseWheel = enabled end
    function methods:SetOrientation(orientation) self.orientation = orientation end
    function methods:SetMinMaxValues(minimum, maximum)
        self.minimum, self.maximum = minimum, maximum
    end
    function methods:GetMinMaxValues() return self.minimum, self.maximum end
    function methods:SetValue(value)
        value = math.max(self.minimum or value, math.min(self.maximum or value, value))
        local changed = self.value ~= value
        self.value = value
        if changed and self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, value) end
    end
    function methods:GetValue() return self.value or 0 end
    function methods:SetValueStep(step) self.valueStep = step end
    function methods:SetThumbTexture(texture)
        if type(texture) ~= "table" then
            local path = texture
            texture = makeWidget()
            texture:SetTexture(path)
        end
        self.thumbTexture = texture
    end
    function methods:GetThumbTexture() return self.thumbTexture end
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
    function methods:SetNumeric(numeric) self.numeric = numeric end
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
    function methods:CreateFontString()
        local fontString = makeWidget()
        fontString.parent = self
        return fontString
    end
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
        if not self.enabled then return end
        if self.frameType == "CheckButton" then self:SetChecked(not self:GetChecked()) end
        if self.scripts.OnClick then self.scripts.OnClick(self) end
    end
    function methods:UserInput(text)
        assert(self.enabled, "disabled fields do not accept user input")
        assert(self:IsVisible(), "hidden fields do not accept user input")
        self.text = text
        if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self, true) end
    end
    uiEnvironment.CreateFrame = function(frameType, name, parent, template)
        if frameType == "Button" and name == "LockInToolsMinimapButton" then
            return createEventFrame(frameType, name, parent, template)
        end
        if frameType == "Frame" and not name and not template and not parent then
            return createEventFrame(frameType)
        end
        assert(frameType == "Frame" or frameType == "EditBox"
            or frameType == "CheckButton" or frameType == "Button" or frameType == "Slider", "use supported native widgets")
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
    for _, file in ipairs({ "Theme.lua", "Overview.lua", "Options.lua" }) do
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

-- Group help supplements readable key fields without exposing keys or interrupting confirmation.
do
    local groupAddon, api, _, _, groupWorld = loadAddon(settings(SECRET, false), false)
    groupWorld:initialize()
    loadOptions(groupAddon, api)
    groupAddon:OpenOptions()
    local options, tooltip = groupAddon.optionsPanel, api.GameTooltip
    local function hover(widget)
        widget.scripts.OnEnter(widget)
        assert(tooltip.shown and tooltip.owner == widget, "group controls show their own help on hover")
        local text = tooltip.text .. "\n" .. table.concat(tooltip.lines, "\n")
        assert(not text:find(SECRET, 1, true) and not text:find(OTHER_SECRET, 1, true),
            "group tooltips never include a saved or entered key")
        return text
    end
    local info = hover(options.groupInfo)
    assert(info:find("characters", 1, true) and info:find("every LockInTools feature", 1, true)
        and info:find("same realm and faction", 1, true)
        and info:find("Group ID: " .. groupAddon:GetGroupFingerprint(), 1, true),
        "Group info explains scope and sharing limits with a public identifier instead of the key")
    options.groupInfo.scripts.OnLeave(options.groupInfo)
    assert(not tooltip.shown, "leaving a help control dismisses its tooltip")
    options.secret:UserInput(" \t ")
    assert(not options.applyGroup:IsEnabled(), "whitespace drafts cannot be applied")
    options.secret:UserInput(OTHER_SECRET)
    assert(options.applyGroup:IsEnabled() and options.secret:GetText() == OTHER_SECRET
        and not options.toggleSecret, "entered keys stay readable without a reveal control")
    for _, widget in ipairs({ options.ownSecret, options.selectKey, options.secret,
        options.applyGroup, options.createGroup, options.leaveGroup }) do
        hover(widget)
        widget.scripts.OnHide(widget)
        assert(not tooltip.shown, "hiding a group control dismisses its tooltip")
    end
    options.applyGroup:Click()
    local confirmation = options.feedback:GetText()
    options.selectKey:Click()
    hover(options.applyGroup)
    assert(options.applyGroup:GetText() == "Confirm switch" and options.feedback:GetText() == confirmation
        and options.secret:GetText() == OTHER_SECRET and groupAddon:GetGroupSecret() == SECRET,
        "copying the saved key and reading help preserve the draft and pending switch warning")
    options.tabs.chat:Click()
    assert(not tooltip.shown and options.secret:GetText() == "" and options.ownSecret:GetText() == ""
        and options.applyGroup:GetText() == "Use key", "leaving Group clears keys, confirmation and owned help")
    options.tabs.group:Click()
    hover(options.groupInfo)
    options.content:Click()
    assert(not tooltip.shown, "switching to Content dismisses Group help")
    groupAddon:OpenOptions("group")
    hover(options.selectKey)
    options.CloseButton:Click()
    assert(not tooltip.shown and options.ownSecret:GetText() == "", "closing Settings clears keys and help")
    groupAddon:OpenOptions("group")
    tooltip:SetOwner(options.tabs.chat, "ANCHOR_RIGHT")
    tooltip:Show()
    options.groupInfo.scripts.OnLeave(options.groupInfo)
    options:Hide()
    assert(tooltip.shown, "group cleanup preserves a tooltip owned by another control")
    tooltip:Hide()
    groupAddon:OpenOptions("group")
    assert(groupAddon:LeaveGroup())
    assert(not hover(options.groupInfo):find("Group ID:", 1, true),
        "Group info reflects leaving the group without retaining its identifier")
    options:Hide()
end

-- Chat and position labels are usable click targets; help preserves preferences and drafts.
do
    local preferences, api, _, _, preferenceWorld = loadAddon(settings(SECRET, false), false)
    preferenceWorld:initialize()
    loadOptions(preferences, api)
    preferences:OpenOptions("chat")
    local options, tooltip = preferences.optionsPanel, api.GameTooltip
    local function hover(widget)
        widget.scripts.OnEnter(widget)
        assert(tooltip.shown and tooltip.owner == widget, "option help belongs to the hovered control")
        return table.concat(tooltip.lines, "\n")
    end
    assert(hover(options.autoJoin.labelButton):find("disabling it keeps an existing chat connection", 1, true))
    options.autoJoin.labelButton:Click()
    assert(options.autoJoin:GetChecked() and preferences.db.chat.autoJoin and #preferenceWorld.joinCalls == 1,
        "clicking the autojoin label applies once and connects immediately")
    local room = preferences:GetGroupChannelName()
    preferenceWorld:completeJoin(room, 9)
    assert(options.status:GetText():find("Joined", 1, true)
        and not options.status:GetText():find("/lit chat", 1, true)
        and hover(options.chatStatusHelp):find("/lit chat", 1, true),
        "chat keeps concise status on the page and complete details in its tooltip")
    options.autoJoin.labelButton:Click()
    assert(not options.autoJoin:GetChecked() and not preferences.db.chat.autoJoin
        and preferences.chatState.phase == "joined" and #preferenceWorld.leaveCalls == 0,
        "disabling autojoin through its label retains current membership")
    assert(hover(options.leave):find("pause reconnection for this session", 1, true))
    options.tabs.position:Click()
    assert(not tooltip.shown, "leaving Shared chat dismisses its help")
    preferenceWorld:completeJoin(preferences:GetGroupDataChannelName(), 7)
    options.positionSharing.labelButton:Click()
    assert(options.positionSharing:GetChecked() and preferences.db.position.sharing
        and preferences.db.position.keepLastKnown and preferences.db.position.showTrails
        and not preferences.db.chat.autoJoin, "sharing's label changes only its own preference")
    assert(options.positionStatus:GetText() == "Sharing: On."
        and hover(options.positionStatusHelp):find("every 2 seconds", 1, true)
        and tooltip.lines[1]:find("world map's LockInTools filter", 1, true),
        "healthy position status is concise while timing and map-filter help remain available")
    options.positionRetention.labelButton:Click()
    options.positionTrails.labelButton:Click()
    assert(not options.positionRetention:GetChecked() and not preferences.db.position.keepLastKnown
        and not options.positionTrails:GetChecked() and not preferences.db.position.showTrails
        and preferences.db.position.sharing and preferences.db.position.trailLength == 10,
        "retention and trails labels apply independent settings")
    options.positionTrailLength:UserInput("19")
    assert(preferences.db.position.trailLength == 19 and options.positionTrailLength:IsEnabled(),
        "trail length remains editable while trails are off")
    options.positionTrailLength:SetFocus()
    options.positionTrailLength:UserInput("31")
    local feedback = options.feedback:GetText()
    assert(hover(options.positionTrailLength):find("whole number from 1 to 30", 1, true)
        and options.positionTrailLength:GetText() == "31" and options.feedback:GetText() == feedback,
        "reading help preserves an invalid trail draft and validation feedback")
    options.tabs.chat:Click()
    assert(not tooltip.shown and options.positionTrailLength:GetText() == "19"
        and preferences.db.position.trailLength == 19, "leaving Shared positions clears help and recovers its draft")
    hover(options.join)
    options.content:Click()
    assert(not tooltip.shown, "switching windows dismisses Shared chat help")
    preferences:OpenOptions("position")
    preferences.savedDataReadOnly = true
    preferences:RefreshOptions()
    for _, checkbox in ipairs({ options.autoJoin, options.positionSharing,
        options.positionRetention, options.positionTrails }) do
        local checked = checkbox:GetChecked()
        assert(not checkbox:IsEnabled() and not checkbox.labelButton:IsEnabled(),
            "read-only settings disable the checkbox and its label together")
        checkbox.labelButton:Click()
        assert(checkbox:GetChecked() == checked, "disabled label clicks cannot change read-only preferences")
    end
    hover(options.positionSharing.labelButton)
    assert(options.feedback:GetText():find("Update LockInTools", 1, true),
        "help stays accessible without replacing the read-only notice")
    options.CloseButton:Click()
    assert(not tooltip.shown, "closing Settings dismisses Shared positions help")
end

local uiAddon, uiEnvironment, uiMessages, _, uiWorld = loadAddon(settings("", false), false)
uiWorld:initialize()
loadOptions(uiAddon, uiEnvironment)
assert(uiAddon.optionsPanel == nil, "build options only when requested")
uiEnvironment.SlashCmdList.LOCKINTOOLS("options")
local panel = uiAddon.optionsPanel
assert(panel and panel:IsShown(), "/lit options opens the actual options panel")
assert(panel.secret:GetText() == "" and not panel.toggleSecret and panel.autoJoin:GetChecked() == false)
assert(panel.positionSharing:GetChecked() == false and panel.positionRetention:GetChecked() == true,
    "position sharing starts off with last-known retention enabled")
assert(panel.positionTrails:GetChecked() == true and panel.positionTrailLength:GetText() == "10"
    and panel.positionTrailLength.numeric == true, "trail controls show default-on trails and a numeric ten-second length")
assert(panel.save == nil and panel.savePosition == nil, "feature preferences need no Save settings buttons")
assert(not panel.join:IsEnabled() and not panel.leave:IsEnabled(), "no group means no join/leave buttons")
assert(uiEnvironment.UISpecialFrames[1] == "LockInToolsOptions", "Escape can close the native panel")
panel.createGroup:Click()
local generatedDraft = panel.secret:GetText()
assert(generatedDraft:match("^[a-z]+%-%d%d%d%d$")
    and panel.secret.focused and panel.secret.highlighted, "Generate key fills a readable draft ready to copy")
assert(not uiAddon:HasGroup() and uiAddon.db.group.secret == "" and #uiWorld.joinCalls == 0,
    "generating a key does not join or replace a group before Use key")
assert(panel.applyGroup:GetText() == "Use key" and panel.applyGroup:IsEnabled())
panel.secret:SetText("  " .. SECRET:lower() .. "  ")
panel.applyGroup:Click()
assert(uiAddon:GetGroupSecret() == SECRET and uiAddon.db.chat.autoJoin == false,
    "import saves shared identity independently from feature settings")
assert(panel.secret:GetText() == "" and panel.secret.focusCleared)
assert(#uiWorld.joinCalls == 0 and panel.join:IsEnabled() and panel.leave:IsEnabled())
assert(panel.secret:GetText() == "" and not panel.applyGroup:IsEnabled()
    and panel.ownSecret:GetText() == SECRET, "the saved key stays in its copy field instead of refilling an empty draft")
panel.tabs.position:Click()
panel.positionSharing:Click()
assert(uiAddon.db.position.sharing and uiAddon.db.position.keepLastKnown
    and uiAddon.db.position.showTrails and uiAddon.db.position.trailLength == 10,
    "sharing applies immediately without changing other position preferences")
panel.positionRetention:Click()
assert(uiAddon.db.position.sharing and not uiAddon.db.position.keepLastKnown,
    "retention applies immediately")
panel.positionTrails:Click()
assert(not uiAddon.db.position.showTrails and uiAddon.db.position.trailLength == 10,
    "trail visibility applies immediately without changing trail length")
panel.positionTrailLength:UserInput("17")
assert(uiAddon.db.position.trailLength == 17, "valid trail length applies while typing")
panel.tabs.chat:Click()
panel.autoJoin:Click()
assert(uiAddon.db.chat.autoJoin and #uiWorld.joinCalls == 1,
    "chat autojoin applies immediately and requests a join")
assert(uiAddon.db.position.sharing and not uiAddon.db.position.keepLastKnown
    and not uiAddon.db.position.showTrails and uiAddon.db.position.trailLength == 17,
    "chat changes preserve saved position preferences")
panel.tabs.position:Click()
for _, invalid in ipairs({ "", "0", "31", "1.5", "many", "1e309" }) do
    panel.positionTrailLength:UserInput(invalid)
    assert(uiAddon.db.position.sharing and not uiAddon.db.position.keepLastKnown
        and not uiAddon.db.position.showTrails and uiAddon.db.position.trailLength == 17
        and panel.positionTrailLength:GetText() == invalid and panel.feedback.color[1] == 1,
        "invalid trail lengths preserve saved preferences and show feedback without interrupting the draft")
end
panel.positionSharing:Click()
assert(not uiAddon.db.position.sharing and uiAddon.db.position.trailLength == 17
    and panel.positionTrailLength:GetText() == "1e309", "invalid trail text does not block sharing changes")
panel.positionRetention:Click()
assert(uiAddon.db.position.keepLastKnown and uiAddon.db.position.trailLength == 17
    and panel.positionTrailLength:GetText() == "1e309", "invalid trail text does not block retention changes")
panel.positionTrails:Click()
assert(uiAddon.db.position.showTrails and uiAddon.db.position.trailLength == 17
    and panel.positionTrailLength:GetText() == "1e309", "invalid trail text does not block trail visibility changes")
panel.positionSharing:Click()
panel.positionRetention:Click()
panel.positionTrails:Click()
panel.positionTrailLength:SetText("22")
assert(uiAddon.db.position.trailLength == 17, "programmatic text changes never save trail length")
panel.positionTrailLength:SetFocus()
panel.positionTrailLength:UserInput("")
panel.positionTrailLength:ClearFocus()
assert(panel.positionTrailLength:GetText() == "17" and uiAddon.db.position.trailLength == 17
    and panel.feedback.color[1] == 1 and panel.feedback:GetText() ~= "",
    "leaving an empty draft restores the saved length with validation feedback")
panel.positionTrailLength:SetFocus()
panel.positionTrailLength:UserInput("31")
panel.positionTrailLength.scripts.OnEnterPressed(panel.positionTrailLength)
assert(panel.positionTrailLength:GetText() == "17" and uiAddon.db.position.trailLength == 17
    and panel.feedback.color[1] == 1 and panel.feedback:GetText() ~= "",
    "Enter restores an invalid draft with validation feedback")
panel.positionTrailLength:UserInput("17")
assert(uiAddon.db.position.sharing and not uiAddon.db.position.keepLastKnown
    and not uiAddon.db.position.showTrails and uiAddon.db.position.trailLength == 17
    and uiAddon.db.chat.autoJoin and #uiWorld.joinCalls == 1,
    "position changes apply independently of chat and do not request a chat join")
do
    local state = uiAddon.positionState
    local timer, generation = state.timer, state.generation
    local sample, stamp, succeeded = state.lastSentSample, state.lastSentAt, state.lastSendSucceeded
    local discovery, attempts = state.classRequestPending, state.classRequestAttempts
    local joins, sends = #uiWorld.dataJoinCalls, #uiWorld.dataSends
    panel.positionTrails:Click()
    panel.positionTrailLength:SetFocus()
    panel.positionTrailLength:UserInput("01")
    assert(uiAddon.db.position.trailLength == 1, "valid numeric drafts apply before Enter")
    panel.positionTrailLength.scripts.OnEnterPressed(panel.positionTrailLength)
    assert(uiAddon.db.position.showTrails and uiAddon.db.position.trailLength == 1
        and panel.positionTrailLength:GetText() == "1"
        and state.timer == timer and state.generation == generation and state.lastSentSample == sample
        and state.lastSentAt == stamp and state.lastSendSucceeded == succeeded
        and state.classRequestPending == discovery and state.classRequestAttempts == attempts
        and #uiWorld.dataJoinCalls == joins and #uiWorld.dataSends == sends,
        "applying and normalizing trail-only changes preserves sampling, suppression, discovery and transport")
    panel.positionTrails:Click()
    panel.positionTrailLength:UserInput("17")
end
panel.tabs.chat:Click()
panel.autoJoin:Click()
assert(not uiAddon.db.chat.autoJoin, "chat autojoin can be disabled immediately")
panel.tabs.position:Click()
panel.positionSharing:Click()
panel.positionRetention:Click()
panel.positionTrails:Click()
panel.positionTrailLength:UserInput("30")
assert(uiAddon.db.position.trailLength == 30, "the maximum trail length applies immediately")
panel.tabs.group:Click()
panel.secret:SetText(OTHER_SECRET)
uiWorld:completeJoin(room, 9)
assert(panel.secret:GetText() == OTHER_SECRET and panel.autoJoin:GetChecked() == false,
    "asynchronous status updates preserve key drafts and immediately applied preferences")
assert(panel.positionSharing:GetChecked() == false and panel.positionRetention:GetChecked() == true
    and panel.positionTrails:GetChecked() == true and panel.positionTrailLength:GetText() == "30"
    and uiAddon.db.position.showTrails and uiAddon.db.position.trailLength == 30
    and not uiAddon.db.position.sharing and uiAddon.db.position.keepLastKnown,
    "asynchronous status updates retain applied position preferences")
assert(panel.positionStatus:GetText() == "Sharing: " .. uiAddon:GetPositionStatusText(true),
    "position status reflects the current sharing state")
assert(panel.status:GetText():find("Joined", 1, true), "status reflects confirmed membership")
panel.secret:SetText("invalid--key")
panel.applyGroup:Click()
panel.applyGroup:Click()
assert(uiAddon:GetGroupSecret() == SECRET and not uiAddon.db.chat.autoJoin,
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
assert(uiAddon:GetGroupSecret() == OTHER_SECRET and panel.secret:GetText() == "",
    "switch confirms before changing every feature's group")
assert(panel.ownSecret:GetText() == OTHER_SECRET)
panel.secret:UserInput(SECRET)
panel.secret:SetFocus()
panel:Hide()
assert(panel.secret:GetText() == "" and panel.ownSecret:GetText() == "" and not panel.secret.focused,
    "closing clears readable keys and draft focus")
uiAddon:OpenOptions()
assert(uiAddon.optionsPanel == panel and panel.secret:GetText() == "")
assert(panel.positionSharing:GetChecked() == false and panel.positionRetention:GetChecked() == true
    and panel.positionTrails:GetChecked() == true and panel.positionTrailLength:GetText() == "30"
    and not panel.autoJoin:GetChecked(), "closing and reopening retains immediately applied preferences")
panel.tabs.chat:Click()
panel.tabs.group:Click()
panel.secret:SetText(SECRET)
panel.secret.scripts.OnEnterPressed(panel.secret)
assert(uiAddon:GetGroupSecret() == OTHER_SECRET, "Enter also requires switch confirmation")
panel.secret:SetText(OTHER_SECRET)
panel.secret.scripts.OnTextChanged(panel.secret, true)
panel.applyGroup:Click()
assert(uiAddon:GetGroupSecret() == OTHER_SECRET and not uiAddon.db.chat.autoJoin,
    "using a secret preserves the independently applied feature preference")
panel.createGroup:Click()
local replacementDraft = panel.secret:GetText()
assert(replacementDraft:match("^[a-z]+%-%d%d%d%d$") and uiAddon:GetGroupSecret() == OTHER_SECRET,
    "Create leaves the configured group intact while drafting a replacement")
panel.applyGroup:Click()
assert(uiAddon:GetGroupSecret() == OTHER_SECRET and panel.applyGroup:GetText() == "Confirm switch")
panel.applyGroup:Click()
assert(uiAddon:GetGroupSecret() == replacementDraft and panel.secret:GetText() == "",
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
    and not readOnly.optionsPanel.positionSharing:IsEnabled()
    and not readOnly.optionsPanel.positionRetention:IsEnabled()
    and not readOnly.optionsPanel.positionTrails:IsEnabled()
    and not readOnly.optionsPanel.positionTrailLength:IsEnabled()
    and not readOnly.optionsPanel.save and not readOnly.optionsPanel.savePosition,
    "read-only settings disable every immediately applied preference")
assert(readOnly.optionsPanel.feedback:GetText():find("Update LockInTools", 1, true))
readOnly.optionsPanel.tabs.chat:Click()
assert(readOnly.optionsPanel.feedback:GetText():find("Update LockInTools", 1, true)
    and not readOnly.optionsPanel.autoJoin:IsEnabled(), "category changes retain the read-only notice and disabled edits")
readOnly.optionsPanel.content:Click()
assert(readOnly.contentPanel.pages.overview:IsVisible() and not readOnly.optionsPanel:IsShown()
    and readOnly.contentPanel.feedback:GetText():find("Update LockInTools", 1, true),
    "Content retains the newer-schema read-only notice")
readOnly.contentPanel.options:Click()
assert(readOnly.optionsPanel.selectedTab == "chat" and not readOnly.optionsPanel.autoJoin:IsEnabled()
    and readOnly.optionsPanel.feedback:GetText():find("Update LockInTools", 1, true),
    "returning to Settings restores its page without enabling read-only edits")

-- Programmatic refreshes never save preferences or recursively apply normalized trail text.
do
    local direct, directEnvironment, _, _, directWorld = loadAddon(settings(SECRET, false), false)
    directWorld:initialize()
    local trailCalls, setTrails = 0, direct.SetPositionTrailSettings
    direct.SetPositionTrailSettings = function(self, ...)
        trailCalls = trailCalls + 1
        return setTrails(self, ...)
    end
    loadOptions(direct, directEnvironment)
    direct:OpenOptions()
    local options = direct.optionsPanel
    options.tabs.position:Click()
    options.positionTrailLength:SetText("7")
    options.positionSharing:SetChecked(true)
    options.positionRetention:SetChecked(false)
    options.positionTrails:SetChecked(false)
    options.autoJoin:SetChecked(true)
    direct:RefreshOptions()
    assert(trailCalls == 0 and direct.db.position.trailLength == 10
        and not direct.db.position.sharing and direct.db.position.keepLastKnown
        and direct.db.position.showTrails and not direct.db.chat.autoJoin,
        "loading and programmatically updating controls never applies preferences")
    options:Hide()
    direct:OpenOptions()
    assert(trailCalls == 0 and options.positionTrailLength:GetText() == "10"
        and not options.positionSharing:GetChecked() and options.positionRetention:GetChecked()
        and options.positionTrails:GetChecked() and not options.autoJoin:GetChecked(),
        "reopening restores saved values without invoking setters")
    options.positionTrailLength:SetFocus()
    options.positionTrailLength:UserInput("08")
    assert(trailCalls == 1 and direct.db.position.trailLength == 8,
        "a valid trail edit applies exactly once")
    options.positionTrailLength.scripts.OnEnterPressed(options.positionTrailLength)
    assert(trailCalls == 1 and options.positionTrailLength:GetText() == "8"
        and options.positionTrailLength.focusCleared,
        "normalizing text and clearing focus do not recursively apply its programmatic text callback")
    options.positionTrailLength:SetFocus()
    options.positionTrailLength:UserInput("")
    local attempts = trailCalls
    direct:RefreshOptions()
    assert(trailCalls == attempts and direct.db.position.trailLength == 8
        and options.positionTrailLength:GetText() == "" and options.feedback.color[1] == 1,
        "unrelated status refresh preserves an incomplete draft and its validation feedback")
    options.tabs.chat:Click()
    assert(options.positionTrailLength:GetText() == "8" and direct.db.position.trailLength == 8
        and options.positionTrailLength.focusCleared,
        "leaving the position category finalizes and restores an invalid draft")
    options.tabs.position:Click()
    options.positionTrailLength:SetFocus()
    options.positionTrailLength:UserInput("0")
    options:Hide()
    direct:OpenOptions()
    assert(options.positionTrailLength:GetText() == "8" and direct.db.position.trailLength == 8,
        "closing with an invalid draft retains the latest valid length on reopening")

    direct.savedDataReadOnly = true
    direct:RefreshOptions()
    for _, preference in ipairs({ { options.autoJoin, direct.db.chat, "autoJoin" },
        { options.positionSharing, direct.db.position, "sharing" },
        { options.positionRetention, direct.db.position, "keepLastKnown" },
        { options.positionTrails, direct.db.position, "showTrails" } }) do
        local control, saved, name = unpack(preference)
        local previous = saved[name]
        control:SetChecked(not previous)
        control.scripts.OnClick(control)
        assert(saved[name] == previous and control:GetChecked() == previous
            and options.feedback.color[1] == 1,
            "rejected immediate changes restore the saved checkbox and report the read-only error")
    end
    options.positionTrailLength:SetText("12")
    options.positionTrailLength.scripts.OnTextChanged(options.positionTrailLength, true)
    options.positionTrailLength.scripts.OnEnterPressed(options.positionTrailLength)
    assert(direct.db.position.trailLength == 8 and options.positionTrailLength:GetText() == "8"
        and options.feedback.color[1] == 1, "read-only rejection also preserves the saved trail length")
end

-- Content and Settings are separate lazy windows with settings-only key management.
do
    local navigation, api, _, _, navigationWorld = loadAddon(settings(SECRET, false), false)
    navigationWorld:initialize()
    loadOptions(navigation, api)
    local command = api.SlashCmdList.LOCKINTOOLS
    local function positioned(window, x, y)
        local point = window.point
        return point and point[1] == "TOPLEFT" and point[2] == api.UIParent
            and point[3] == "TOPLEFT" and point[4] == x and point[5] == y
    end
    command("options")
    local options = navigation.optionsPanel
    assert(options and options:IsVisible() and not navigation.contentPanel and not navigation.welcomePanel,
        "opening Settings lazily creates only its own window")
    assert(options.selectedTab == "group" and options.tabs.group.themeTab.selected
        and not options.tabs.chat.themeTab.selected and options.pages.group:IsVisible()
        and not options.pages.chat:IsVisible() and not options.pages.position:IsVisible()
        and not options.tabs.overview and not options.pages.overview
        and not options.screenTabs and not options.selectedScreen and not options.SelectScreen,
        "Settings contains Group, Shared chat and Shared positions without Content navigation tabs")
    local settingsPages = 0
    for _, page in pairs(options.pages) do
        settingsPages = settingsPages + 1
        assert(page.point[1] == "TOPLEFT" and page.point[3] == -116
            and -page.point[3] + page:GetHeight() == options:GetHeight() - 20,
            "every Settings page fills the available height with a small bottom margin")
    end
    assert(settingsPages == 3 and options.content:GetText() == "Content"
        and options.content.point[1] == "TOPRIGHT" and options.content.point[3] == -12
        and options.content:GetHeight() == 32 and options.feedback.parent == options.pages.group
        and options.feedback.point[1] == "BOTTOMLEFT",
        "Settings has exactly three pages and its Content switch in the header")
    options.secret:UserInput(OTHER_SECRET)
    options.secret:SetFocus()
    options.applyGroup:Click()
    command("options")
    options.tabs.group:Click()
    options.SelectTab("unknown")
    navigation:OpenOptions("unknown")
    assert(navigation.optionsPanel == options and options.secret:GetText() == OTHER_SECRET
        and options.applyGroup:GetText() == "Confirm switch" and options.secret.focused,
        "reopening Settings and current or invalid page selections preserve pending group edits")
    options.selectKey:Click()
    options:SetPoint("TOPLEFT", api.UIParent, "TOPLEFT", 42, -70)
    options.content:Click()
    local content = navigation.contentPanel
    assert(content and content ~= options and content:IsVisible() and not options:IsVisible()
        and content.selectedTab == "overview" and content.tabs.overview.themeTab.selected
        and content.pages.overview:IsVisible() and content.options:GetText() == "Settings"
        and content.options.point[1] == "TOPRIGHT" and content.options.point[3] == -12
        and content.options:GetHeight() == 32 and content.TitleText:GetText() == "LockInTools"
        and positioned(content, 42, -70),
        "Content opens its own Overview window with a header Settings switch and closes Settings")
    local contentPages = 0
    for _ in pairs(content.pages) do contentPages = contentPages + 1 end
    assert(contentPages == 1 and not content.secret and not content.ownSecret and not content.friendSecret
        and not content.createGroup and not content.joinGroup and not content.selectKey,
        "Content contains only Overview and no group-key form")
    assert(options.secret:GetText() == "" and not options.secret.focused
        and options.ownSecret:GetText() == "" and not options.ownSecret.focused
        and options.applyGroup:GetText() == "Use key" and navigation:GetGroupSecret() == SECRET,
        "opening Content clears hidden Settings key fields, focus and switch confirmation")
    navigation:RefreshOptions()
    assert(options.ownSecret:GetText() == "", "background status refresh cannot restore a hidden copy field")
    content.options:Click()
    assert(options:IsVisible() and not content:IsVisible() and options.selectedTab == "group"
        and options.ownSecret:GetText() == SECRET,
        "the Settings button restores the remembered Group page and its saved copy field")
    options.leaveGroup:Click()
    options.content:Click()
    content.options:Click()
    assert(options.leaveGroup:GetText() == "Leave group" and navigation:GetGroupSecret() == SECRET,
        "changing windows cancels a pending leave-group confirmation")
    options.secret:UserInput(OTHER_SECRET)
    options.secret:SetFocus()
    options.applyGroup:Click()
    options.tabs.chat:Click()
    assert(options.selectedTab == "chat" and options.pages.chat:IsVisible()
        and not options.pages.group:IsVisible() and not options.pages.position:IsVisible()
        and options.secret:GetText() == "" and not options.secret.focused
        and options.ownSecret:GetText() == "" and options.applyGroup:GetText() == "Use key"
        and options.feedback:GetText() == "",
        "leaving Group clears copying, drafts, focus and confirmation")
    navigation:RefreshOptions()
    assert(options.ownSecret:GetText() == "", "refreshing another settings page cannot reveal the saved key")
    options.autoJoin:Click()
    navigationWorld:completeJoin(navigation:GetGroupChannelName(), 9)
    assert(options.autoJoin:GetChecked() and navigation.db.chat.autoJoin and options.secret:GetText() == "",
        "status updates retain applied chat preferences without restoring keys")
    options.tabs.position:Click()
    options.positionSharing:Click()
    options.positionRetention:Click()
    options.positionTrails:Click()
    options.positionTrailLength:UserInput("1")
    options.positionTrailLength:SetFocus()
    options.positionTrailLength:UserInput("0")
    options.content:Click()
    assert(options.positionTrailLength:GetText() == "1" and not options.positionTrailLength.focused
        and navigation.db.position.trailLength == 1,
        "changing windows restores an invalid trail draft and clears its focus")
    content.options:Click()
    assert(options.selectedTab == "position" and options.pages.position:IsVisible()
        and options.positionSharing:GetChecked() and not options.positionRetention:GetChecked()
        and not options.positionTrails:GetChecked() and options.positionTrailLength:GetText() == "1"
        and navigation.db.position.sharing and not navigation.db.position.keepLastKnown
        and not navigation.db.position.showTrails and navigation.db.position.trailLength == 1
        and options.feedback.parent == options.pages.position,
        "Settings remembers its page and all immediately applied preferences")
    for _, entry in ipairs({ "", "content", "overview", "welcome" }) do
        command(entry)
        assert(content:IsVisible() and not options:IsVisible() and content.pages.overview:IsVisible(),
            "Content commands and the old welcome alias reuse the Content window")
        command("options")
        assert(options:IsVisible() and not content:IsVisible() and options.selectedTab == "position",
            "the options command returns to the remembered Settings page")
    end
    navigation:OpenOptions("overview")
    assert(content:IsVisible() and not options:IsVisible(), "the old Overview options route opens Content")
    navigation.minimapButton:Click("RightButton")
    assert(options:IsVisible() and not content:IsVisible() and options.selectedTab == "position",
        "minimap right-click opens Settings at its remembered page")
    navigation.minimapButton:Click("LeftButton")
    assert(content:IsVisible() and not options:IsVisible() and content.selectedTab == "overview",
        "minimap left-click opens Content with Overview")
    content.scripts.OnDragStart(content)
    content:SetPoint("TOPLEFT", api.UIParent, "TOPLEFT", 85, -45)
    content.options:Click()
    assert(positioned(options, 85, -45) and not content.moving,
        "the header switch follows Content's dragged position and stops its movement")
    options.scripts.OnDragStart(options)
    options:SetPoint("TOPLEFT", api.UIParent, "TOPLEFT", -130, -90)
    options.CloseButton:Click()
    navigation.minimapButton:Click("LeftButton")
    assert(positioned(content, -130, -90) and not options.moving,
        "Content follows Settings' last position after dragging and closing Settings")
    content.scripts.OnDragStart(content)
    content:SetPoint("TOPLEFT", api.UIParent, "TOPLEFT", 180, -65)
    content.CloseButton:Click()
    navigation.minimapButton:Click("RightButton")
    assert(positioned(options, 180, -65) and not content.moving,
        "Settings follows Content's last position after dragging and closing Content")
    options.scripts.OnDragStart(options)
    options:SetPoint("TOPLEFT", api.UIParent, "TOPLEFT", 260, -110)
    options.scripts.OnDragStop(options)
    command("options")
    assert(positioned(options, 260, -110), "reopening the current Settings view does not restore an older position")
    options.content:Click()
    command("content")
    assert(positioned(content, 260, -110), "reopening Content preserves the shared position")
    assert(api.namedFrameCreations.LockInToolsContent == 1 and api.namedFrameCreations.LockInToolsOptions == 1
        and not api.namedFrameCreations.LockInToolsWelcome and not navigation.welcomePanel
        and #api.UISpecialFrames == 3 and contains(api.UISpecialFrames, "LockInToolsContent")
        and contains(api.UISpecialFrames, "LockInToolsOptions")
        and contains(api.UISpecialFrames, "LockInToolsOverviewActions"),
        "all navigation paths reuse two windows and one Escape-closeable action menu without an old welcome window")
end

-- Both windows persist one account-wide position without native per-character placement.
do
    local persisted = settings(SECRET, false)
    local positioning, api, _, _, positionWorld = loadAddon(persisted, false)
    positionWorld:initialize()
    loadOptions(positioning, api)
    positioning:OpenContent()
    local content = positioning.contentPanel
    local function placed(window, owner, point, relativePoint, x, y)
        local actualPoint, relativeTo, actualRelativePoint, actualX, actualY = window:GetPoint()
        return actualPoint == point and relativeTo == owner and actualRelativePoint == relativePoint
            and actualX == x and actualY == y
    end
    assert(not persisted.windowPosition and content.userPlaced == false
        and placed(content, api.UIParent, "CENTER", "CENTER", 0, 0),
        "opening the first window centers it without saving a default position")
    content.scripts.OnDragStart(content)
    content:SetPoint("TOPLEFT", api.UIParent, "TOPLEFT", 140, -90)
    content.scripts.OnDragStop(content)
    local saved = persisted.windowPosition
    assert(saved and saved.point == "TOPLEFT" and saved.relativePoint == "TOPLEFT"
        and saved.x == 140 and saved.y == -90 and not saved.relativeTo
        and not content.moving and content.userPlaced == false,
        "drag stop saves only an anchor and offsets and disables native per-character placement")
    saved.futureField = "keep"
    content.options:Click()
    local options = positioning.optionsPanel
    assert(placed(options, api.UIParent, "TOPLEFT", "TOPLEFT", 140, -90)
        and persisted.windowPosition == saved and saved.futureField == "keep",
        "window switching shares the saved position while preserving unknown position fields")
    options.scripts.OnDragStart(options)
    options:SetPoint("BOTTOMRIGHT", api.UIParent, "BOTTOMRIGHT", -160, 75)
    options.CloseButton:Click()
    assert(saved.point == "BOTTOMRIGHT" and saved.relativePoint == "BOTTOMRIGHT"
        and saved.x == -160 and saved.y == 75 and not options.moving and options.userPlaced == false,
        "closing Settings during a drag saves its latest shared position")
    positioning:OpenContent()
    assert(placed(content, api.UIParent, "BOTTOMRIGHT", "BOTTOMRIGHT", -160, 75),
        "Content follows the position saved when Settings closed")
    content.scripts.OnDragStart(content)
    content:SetPoint("TOPRIGHT", api.UIParent, "TOPRIGHT", -85, -130)
    positionWorld.fire("PLAYER_LOGOUT")
    assert(saved.point == "TOPRIGHT" and saved.relativePoint == "TOPRIGHT"
        and saved.x == -85 and saved.y == -130 and saved.futureField == "keep"
        and not content.moving and content.userPlaced == false and persisted.schemaVersion == 3,
        "logout saves a visible mid-drag position without changing the saved-data schema")
    options:SetPoint("CENTER", api.UIParent, "CENTER", 999, 999)
    positioning:SaveWindowPosition(options)
    content:SetPoint("TOPLEFT", options, "TOPLEFT", 10, 10)
    positioning:SaveWindowPosition(content)
    assert(saved.point == "TOPRIGHT" and saved.x == -85 and saved.y == -130,
        "inactive windows and anchors relative to another frame cannot overwrite the shared position")

    for _, firstWindow in ipairs({ "content", "settings" }) do
        local restored, restoredApi, _, _, restoredWorld = loadAddon(persisted, false)
        if firstWindow == "settings" then
            restoredApi.UnitFullName = function(unit) assert(unit == "player"); return "Alt", "Test Realm" end
            restoredApi.UnitGUID = function(unit) assert(unit == "player"); return "Player-Test-Alt" end
        end
        restoredWorld:initialize()
        loadOptions(restored, restoredApi)
        if firstWindow == "content" then restored:OpenContent() else restored:OpenOptions() end
        local first = firstWindow == "content" and restored.contentPanel or restored.optionsPanel
        assert(placed(first, restoredApi.UIParent, "TOPRIGHT", "TOPRIGHT", -85, -130)
            and persisted.windowPosition == saved and saved.futureField == "keep",
            "reload and a different character restore the account-wide position with either window opening first")
        if firstWindow == "content" then first.options:Click() else first.content:Click() end
        local second = firstWindow == "content" and restored.optionsPanel or restored.contentPanel
        assert(placed(second, restoredApi.UIParent, "TOPRIGHT", "TOPRIGHT", -85, -130),
            "switching windows after reload retains the restored position")
    end

    for _, invalid in ipairs({ false, "bad", {},
        { point = "INVALID", relativePoint = "CENTER", x = 0, y = 0 },
        { point = "CENTER", relativePoint = "INVALID", x = 0, y = 0 },
        { point = "CENTER", relativePoint = "CENTER", x = "40", y = 0 },
        { point = "CENTER", relativePoint = "CENTER", x = 100001, y = 0 },
        { point = "CENTER", relativePoint = "CENTER", x = 0 / 0, y = 0 },
        { point = "CENTER", relativePoint = "CENTER", x = 0, y = math.huge },
        { point = "CENTER", relativePoint = "CENTER", x = -math.huge, y = 0 } }) do
        local damaged = settings(SECRET, false)
        damaged.windowPosition = invalid
        local original = {}
        if type(invalid) == "table" then
            for key, value in pairs(invalid) do original[key] = value end
        end
        local fallback, fallbackApi, _, _, fallbackWorld = loadAddon(damaged, false)
        fallbackWorld:initialize()
        loadOptions(fallback, fallbackApi)
        fallback:OpenContent()
        assert(placed(fallback.contentPanel, fallbackApi.UIParent, "CENTER", "CENTER", 0, 0)
            and damaged.windowPosition == invalid,
            "malformed saved window positions center the first window without replacing saved data")
        for key, value in pairs(original) do
            local actual = invalid[key]
            assert(actual == value or (actual ~= actual and value ~= value),
                "reading a malformed position does not rewrite any existing field")
        end
    end

    local future = settings(SECRET, false)
    future.schemaVersion = 4
    future.windowPosition = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 80, y = -60, futureField = "keep" }
    local original = future.windowPosition
    local readOnly, readOnlyApi, _, _, readOnlyWorld = loadAddon(future, false)
    readOnlyWorld:initialize()
    loadOptions(readOnly, readOnlyApi)
    readOnly:OpenContent()
    local readOnlyContent = readOnly.contentPanel
    readOnlyContent.scripts.OnDragStart(readOnlyContent)
    readOnlyContent:SetPoint("CENTER", readOnlyApi.UIParent, "CENTER", 30, 40)
    readOnlyContent.scripts.OnDragStop(readOnlyContent)
    readOnlyContent.CloseButton:Click()
    readOnlyWorld.fire("PLAYER_LOGOUT")
    assert(readOnlyApi.LockInToolsDB == future and future.schemaVersion == 4
        and future.windowPosition == original and original.point == "TOPLEFT" and original.relativePoint == "TOPLEFT"
        and original.x == 80 and original.y == -60 and original.futureField == "keep",
        "drag, hide and logout preserve newer-schema account-wide window data unchanged")
end

-- Overview scrolls and sorts the Content roster, with guarded native actions in a dropdown.
do
    local overview, api, _, overviewEvent, overviewWorld = loadAddon(settings(SECRET, false), false)
    local invites, requests, grouped, mayInvite = {}, {}, false, true
    api.IsInGroup = function() return grouped end
    api.C_PartyInfo = {
        CanInvite = function() return mayInvite end,
        IsPartyFull = function() return false end,
        InviteUnit = function(name) invites[#invites + 1] = name end,
        RequestInviteFromUnit = function(name) requests[#requests + 1] = name end,
    }
    api.C_Map.GetMapInfo = function(map)
        assert(map == 37 or map == 38)
        return { name = map == 37 and "Elwynn Forest" or "Westfall" }
    end
    overviewWorld:initialize()
    overviewWorld:completeJoin(overview:GetGroupDataChannelName(), 7)
    local now = api.GetServerTime()
    for index, name in ipairs({ "Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India", "Juliet" }) do
        overviewEvent("CHAT_MSG_ADDON", overview:GetDataPrefix(),
            "1|status|3|F|peer-" .. name:lower() .. "|" .. now .. "|1|1="
            .. (name == "Bravo" and 0 or 20 + index) .. "|4=unavailable|5="
            .. (name == "Bravo" and "true" or "false") .. "|6=true|7=false|8="
            .. (name == "Alpha" and "true" or "false"),
            "CHANNEL", name .. "-TestRealm", nil, 0, 7, overview:GetGroupDataChannelName())
    end
    overviewEvent("CHAT_MSG_ADDON", overview:GetDataPrefix(),
        "1|status|3|D|peer-alpha|" .. now .. "|2|1|65000=value|2=420|3=1000|4=known",
        "CHANNEL", "Alpha-TestRealm", nil, 0, 7, overview:GetGroupDataChannelName())
    local positions = {
        ["alpha-testrealm"] = { name = "Alpha-TestRealm", map = 37, x = 0.25, y = 0.75,
            stamp = now, positionStamp = now - 120, positionAvailable = true, online = true },
        ["charlie-testrealm"] = { name = "Charlie-TestRealm", map = 38,
            stamp = now, positionStamp = now - 180, positionAvailable = false, online = true },
    }
    overview.GetSharedPositions = function() return positions end
    local snapshotCalls, originalRequest = 0, overview.RequestData
    overview.RequestData = function(self, feature, ...)
        if feature == "status" then snapshotCalls = snapshotCalls + 1 end
        return originalRequest(self, feature, ...)
    end
    loadOptions(overview, api)
    local command = api.SlashCmdList.LOCKINTOOLS
    command("options")
    local options = overview.optionsPanel
    assert(options.selectedTab == "group" and not overview.contentPanel and snapshotCalls == 0,
        "opening Settings does not activate Content or request an Overview snapshot")
    options.secret:UserInput(OTHER_SECRET)
    options.secret:SetFocus()
    options.applyGroup:Click()
    command("overview")
    local content = overview.contentPanel
    local page = content.overviewPage
    assert(content.selectedTab == "overview" and not options:IsVisible()
        and page:IsVisible() and page.active and snapshotCalls == 0
        and options.secret:GetText() == "" and not options.secret.focused
        and options.applyGroup:GetText() == "Use key" and overview:GetGroupSecret() == SECRET,
        "overview command opens Content and clears group-key drafts and confirmation")
    command("overview")
    command("content")
    content.tabs.overview:Click()
    overview:OpenOptions("overview")
    assert(page.active and page.scripts.OnUpdate and snapshotCalls == 0,
        "reopening Content or selecting its current Overview page does not request status")
    assert(not page.summary and not page.previous and not page.next and not page.pagination and not page.pageNumber
        and #page.rows == 8 and page.offset == 0 and not page.sortKey
        and page.rows[1].name:GetText():find("(you)", 1, true)
        and page.rows[8].playerID == "golf-testrealm" and not page.empty:IsShown(),
        "overview has eight reusable rows without the summary line or paging controls")
    local minimum, maximum = page.scrollbar:GetMinMaxValues()
    assert(page.scrollbar:IsShown() and minimum == 0 and maximum == 3 and page.scrollbar:GetValue() == 0,
        "the native scrollbar exposes all eleven players through a bounded row offset")
    assert(page.rows[2].name:GetText() == "Alpha-TestRealm" and page.rows[2].level:GetText() == "21"
        and page.rows[2].progress:GetText() == "· 42%" and page.rows[2].progressFill:IsShown()
        and page.rows[2].position:GetText() == "Elwynn Forest" and page.rows[2].seen:GetText() == "Active"
        and page.rows[3].level:GetText() == "—" and page.rows[5].position:GetText() == "Not sharing"
        and page.rows[4].position:GetText() == "Last: Westfall" and page.rows[4].seen:GetText() == "Active",
        "status reaches level progress, and region labels omit ages while active players show only Active")
    for _, row in ipairs(page.rows) do
        assert(row.actions:IsEnabled() and not row.invite and not row.request,
            "each row has one dropdown trigger instead of individual action buttons")
    end
    local function openMenu(index)
        local row = page.rows[index]
        row.actions:Click()
        assert(page.actionMenu:IsShown() and page.actionMenu.playerID == row.playerID
            and page.actionMenu.anchor == row,
            "the actions dropdown is anchored to its selected player")
        return page.actionMenu
    end
    local menu = openMenu(1)
    assert(not menu.invite:IsEnabled() and not menu.request:IsEnabled(),
        "the local player's menu explains unavailable actions")
    menu.invite.scripts.OnEnter(menu.invite)
    assert(api.GameTooltip.shown and api.GameTooltip.text == "This is your character.",
        "disabled actions explain their reason on hover")
    menu.invite.scripts.OnLeave(menu.invite)
    assert(not api.GameTooltip.shown)
    menu:Click()
    assert(not menu:IsShown(), "clicking outside the dropdown dismisses it")
    menu = openMenu(2)
    assert(menu.invite:IsEnabled() and not menu.request:IsEnabled(),
        "an ungrouped peer offers an invite but explains the unavailable join request")
    menu.invite:Click()
    menu = openMenu(3)
    assert(not menu.invite:IsEnabled() and menu.request:IsEnabled(),
        "a grouped peer offers a join request instead of an invite")
    menu.request:Click()
    assert(#invites == 1 and invites[1] == "Alpha-TestRealm" and #requests == 1 and requests[1] == "Bravo-TestRealm"
        and content.feedback:GetText():find("invitation notices", 1, true),
        "overview clicks invoke the real guarded native actions with complete names")
    -- Open while allowed, then change native eligibility before clicking.
    mayInvite = true
    menu = openMenu(2)
    mayInvite = false
    menu.invite:Click()
    assert(#invites == 1
        and content.feedback:GetText() == "You cannot invite players right now.",
        "an enabled stale dropdown item cannot bypass the action-time permission check")
    menu = openMenu(2)
    assert(not menu.invite:IsEnabled() and menu.invite.reason == "You cannot invite players right now.",
        "reopening a menu refreshes disabled action state and its explanation")
    mayInvite = true
    overview:RefreshOverview()
    assert(menu:IsShown() and menu.playerID == "alpha-testrealm" and menu.invite:IsEnabled(),
        "a refresh preserves the selected player and updates an open menu's eligibility")
    page:SetOffset(1)
    assert(not menu:IsShown() and page.offset == 1 and page.rows[1].playerID == "alpha-testrealm"
        and page.scrollbar:GetValue() == 1,
        "moving the scroll offset dismisses the menu and keeps the native scrollbar synchronized")
    page.scripts.OnMouseWheel(page, -1)
    assert(page.offset > 1, "mouse wheel down moves through the roster")
    page:SetOffset(999)
    assert(page.offset == 3 and page.rows[1].playerID == "charlie-testrealm"
        and page.rows[8].playerID == "juliet-testrealm",
        "scrolling to the end reveals the last player without an extra page")
    page.scrollbar:SetValue(0)
    assert(page.offset == 0 and page.rows[1].playerID == "self-testrealm",
        "dragging the scrollbar updates visible row targets")
    page.scripts.OnMouseWheel(page, 1)
    assert(page.offset == 0, "mouse wheel up clamps at the first player")

    openMenu(2)
    page.headers.name:Click()
    assert(not menu:IsShown() and page.sortKey == "name" and not page.sortDescending
        and page.offset == 0 and page.rows[1].playerID == "alpha-testrealm",
        "clicking a column sorts ascending and dismisses the selected player's menu")
    page:SetOffset(3)
    assert(page.rows[8].playerID == "self-testrealm", "explicit name sorting includes self in normal name order")
    page.headers.name:Click()
    assert(page.sortDescending and page.offset == 0 and page.rows[1].playerID == "self-testrealm"
        and page.rows[2].playerID == "juliet-testrealm", "clicking the same column reverses sorting and resets scrolling")
    page.headers.level:Click()
    assert(not page.sortDescending and page.rows[1].playerID == "self-testrealm"
        and page.rows[2].playerID == "alpha-testrealm", "levels sort numerically ascending")
    page:SetOffset(3)
    assert(page.rows[8].playerID == "bravo-testrealm", "unknown levels follow known levels when sorting ascending")
    page.headers.level:Click()
    assert(page.sortDescending and page.rows[1].playerID == "juliet-testrealm", "levels sort numerically descending")
    page:SetOffset(3)
    assert(page.rows[8].playerID == "bravo-testrealm", "unknown levels remain last when sorting descending")
    page.headers.region:Click()
    assert(not page.sortDescending and page.rows[1].playerID == "alpha-testrealm"
        and page.rows[2].playerID == "charlie-testrealm" and page.rows[3].playerID == "bravo-testrealm",
        "regions sort by name with missing regions after known values and stable player-ID ties")
    page.headers.region:Click()
    assert(page.sortDescending and page.rows[1].playerID == "charlie-testrealm"
        and page.rows[2].playerID == "alpha-testrealm" and page.rows[3].playerID == "bravo-testrealm",
        "reverse region sorting keeps missing regions last and preserves deterministic ties")
    -- Vary contact ages without changing transport eligibility or position freshness.
    overview.rosterState.peers["alpha-testrealm"].seenAt = now - 20
    overview.rosterState.peers["bravo-testrealm"].seenAt = now - 10
    overview.rosterState.peers["charlie-testrealm"].seenAt = nil
    page.headers.seen:Click()
    assert(page.sortDescending and page.rows[1].playerID == "delta-testrealm"
        and page.rows[2].playerID == "echo-testrealm", "last seen starts with the most recent contacts and stable ties")
    page:SetOffset(3)
    assert(page.rows[8].playerID == "charlie-testrealm", "unknown contact ages sort after known recent contacts")
    page.headers.seen:Click()
    assert(not page.sortDescending and page.rows[1].playerID == "alpha-testrealm"
        and page.rows[2].playerID == "bravo-testrealm", "last seen can be reversed to oldest contacts first")
    page:SetOffset(3)
    assert(page.rows[8].playerID == "charlie-testrealm", "unknown contact ages stay last in either sort direction")
    page.headers.name:Click()
    -- Ascending names put Alpha first and provide a stable anchor for live age updates.
    menu = openMenu(1)
    assert(page.rows[1].seen:GetText() == "Active" and page.rows[1].position:GetText() == "Elwynn Forest",
        "an active contact with an older seen timestamp still shows only Active and the region name")
    overviewWorld:advance(90)
    assert(page.scripts.OnUpdate, "only the active overview page installs an age refresh")
    page.scripts.OnUpdate(page, 1)
    assert(page.rows[1].position:GetText() == "Last: Elwynn Forest"
        and page.rows[1].seen:GetText() == "1m ago" and snapshotCalls == 0
        and menu:IsShown() and menu.playerID == "alpha-testrealm" and not menu.invite:IsEnabled()
        and menu.invite.reason == "No recent contact with this player.",
        "offline rows show only elapsed contact age, retain the region without age and do not request status")
    content.CloseButton:Click()
    assert(not page.active and not page.scripts.OnUpdate and not menu:IsShown(),
        "closing Content stops live overview work and dismisses its action menu")
    command("options")
    assert(options.selectedTab == "group"
        and options.pages.group:IsVisible() and not page.active and not page.scripts.OnUpdate
        and snapshotCalls == 0,
        "opening Settings does not reactivate the hidden Content page")
    options.content:Click()
    assert(content.selectedTab == "overview" and page.active and snapshotCalls == 0,
        "returning to Content reactivates Overview without requesting another status snapshot")
    content.options:Click()
    options.tabs.chat:Click()
    assert(options.selectedTab == "chat"
        and not page.active and not page.scripts.OnUpdate,
        "opening Settings deactivates Overview and stops its age updates")
    overview:OpenOptions("unknown")
    assert(options.selectedTab == "chat" and options.pages.chat:IsVisible() and snapshotCalls == 0,
        "invalid settings page names preserve the selected page without activating Content")
    command("overview")
    assert(snapshotCalls == 0 and content.selectedTab == "overview" and content:IsVisible()
        and not options:IsVisible())
    page:SetOffset(999)
    openMenu(1)
    positions, overview.rosterState.peers = {}, {}
    overview:RefreshOverview()
    assert(page.offset == 0 and page.rows[1].playerID == "self-testrealm"
        and not page.rows[2]:IsShown() and not page.rows[2].playerID and not page.scrollbar:IsShown()
        and not menu:IsShown() and not page.empty:IsShown(),
        "live roster removal clamps scrolling, removes old row targets and closes obsolete menus")
    assert(overview:LeaveGroup())
    assert(page.empty:IsShown() and page.empty:GetText():find("Choose a group key", 1, true)
        and not page.rows[1]:IsShown() and not page.rows[1].playerID,
        "leaving the global group clears the overview while it remains open")
end

-- The local player's progress is read directly and has no remote-report age.
do
    local localAddon, api, _, _, localWorld = loadAddon(settings(SECRET, false), false)
    localWorld:initialize()
    loadOptions(localAddon, api)
    localAddon:OpenContent()
    local page, tooltip = localAddon.contentPanel.overviewPage, api.GameTooltip
    local row = page.rows[1]
    row.levelCell.scripts.OnEnter(row.levelCell)
    assert(row.levelCell.player.isSelf and tooltip.lines[1] == "XP: 0 / 1000"
        and tooltip.lines[2] == "To next level: 1000 XP" and #tooltip.lines == 2,
        "local progress details show exact live XP without a Last reported label")
    localWorld:advance(1.2)
    localWorld.xp = 250
    localWorld.fire("PLAYER_XP_UPDATE", "player")
    page.scripts.OnUpdate(page, 1)
    assert(tooltip.lines[1] == "XP: 250 / 1000" and tooltip.lines[2] == "To next level: 750 XP"
        and #tooltip.lines == 2,
        "refreshing live local progress updates XP without adding a flickering report age")
end

-- Level progress fits the pooled Overview rows and explains exact values without requesting on each refresh.
do
    local progressAddon, api, _, _, progressWorld = loadAddon(settings(SECRET, false), false)
    progressWorld:initialize()
    local now, snapshots = api.GetServerTime(), 0
    local players = {
        { id = "alpha", name = "Alpha", level = 24, xp = 420, xpMax = 1000, xpState = "known", online = true },
        { id = "bravo", name = "Bravo", level = 24, xp = 0, xpMax = 1000, xpState = "known", online = true },
        { id = "charlie", name = "Charlie", level = 24, xp = 999, xpMax = 1000, xpState = "known", online = true },
        { id = "delta", name = "Delta", level = 60, xpState = "max", online = true },
        { id = "echo", name = "Echo", level = 24, xpState = "unavailable", online = true },
        { id = "foxtrot", name = "Foxtrot", xpState = "unavailable", online = true },
        { id = "golf", name = "Golf", level = 24, xp = 500, xpMax = 1000, xpState = "known", online = true, xpStale = true },
        { id = "hotel", name = "Hotel", level = 24, xp = 750, xpMax = 1000, xpState = "known", online = false },
        { id = "india", name = "India", level = 24, xp = 200, xpMax = 1000, xpState = "known", online = true },
        { id = "juliet", name = "Juliet", level = 25, xp = 800, xpMax = 1000, xpState = "known", online = true },
    }
    for _, player in ipairs(players) do player.xpUpdatedAt = now end
    players[9].xpUpdatedAt = now - 50000
    progressAddon.GetOverviewPlayers = function()
        local copy = {}
        for _, player in ipairs(players) do copy[#copy + 1] = player end
        return copy
    end
    progressAddon.RequestData = function() snapshots = snapshots + 1 end
    loadOptions(progressAddon, api)
    progressAddon:OpenContent()
    local content, tooltip = progressAddon.contentPanel, api.GameTooltip
    local page = content.overviewPage
    local row = page.rows[1]
    assert(#page.rows == 8 and page:GetWidth() == 680 and row:GetHeight() == 40
        and page.headers.level:GetWidth() == 80 and page.headers.region:GetWidth() == 156
        and row.position:GetWidth() == 156 and row.position.point[2] == 260
        and row.seen.point[2] == 424 and row.actions.point[2] == 520,
        "level progress widens Level and moves Region while preserving row count, panel size and later columns")
    assert(row.level:GetText() == "24" and row.progress:GetText() == "· 42%"
        and row.progressTrack:IsShown() and row.progressFill:IsShown()
        and math.abs(row.progressFill:GetWidth() - 76 * 0.42) < 0.000001,
        "known XP displays the numeric level, floored percentage and proportional thin fill")
    assert(page.rows[2].progress:GetText() == "· 0%" and page.rows[2].progressTrack:IsShown()
        and not page.rows[2].progressFill:IsShown() and page.rows[3].progress:GetText() == "· 99%",
        "zero XP shows an empty track and near-level XP never rounds up to 100 percent")
    assert(page.rows[4].progress:GetText() == "· MAX" and not page.rows[4].progressTrack:IsShown()
        and not page.rows[4].progressFill:IsShown()
        and page.rows[5].progress:GetText() == "· —" and not page.rows[5].progressTrack:IsShown()
        and page.rows[6].level:GetText() == "—" and page.rows[6].progress:GetText() == "",
        "maximum level, unavailable XP and unknown level have distinct states without an ordinary XP bar")
    assert(page.rows[7].progress:GetText() == "· ~50%" and page.rows[7].progress.alpha == 0.55
        and page.rows[7].progressFill.textureColor[4] == 0.35
        and page.rows[8].progress:GetText() == "· ~75%",
        "explicit stale progress and inactive players have a visible marker and subdued fill")
    progressAddon.Theme.skin = { GetAccentColor = function() return 0.8, 0.2, 0.4 end }
    progressAddon:RefreshOverview()
    assert(row.progressFill.textureColor[1] == 0.8 and row.progressFill.textureColor[3] == 0.4,
        "visible progress uses the current optional skin accent")
    progressAddon.Theme.skin.GetAccentColor = function() return 0 / 0, 0.2, 0.4 end
    progressAddon:RefreshOverview()
    assert(row.progressFill.textureColor[1] == 0.27, "nonfinite skin accents safely fall back to native colors")
    progressWorld.secretValue = 0.8
    progressAddon.Theme.skin.GetAccentColor = function() return 0.8, 0.2, 0.4 end
    progressAddon:RefreshOverview()
    assert(row.progressFill.textureColor[1] == 0.27, "secret skin colors do not enter progress arithmetic")
    progressAddon.Theme.skin, progressWorld.secretValue = nil, nil
    row.levelCell.scripts.OnEnter(row.levelCell)
    assert(tooltip.shown and tooltip.owner == row.levelCell and tooltip.text == "Alpha — level 24"
        and tooltip.lines[1] == "XP: 420 / 1000" and tooltip.lines[2] == "To next level: 580 XP"
        and #tooltip.lines == 2, "the whole Level cell explains exact XP and remaining XP without report details")
    progressWorld:advance(13)
    page.scripts.OnUpdate(page, 1)
    assert(#tooltip.lines == 2 and tooltip.lines[1] == "XP: 420 / 1000"
        and row.progress:GetText() == "· 42%" and snapshots == 0,
        "refreshing remote progress does not add report details, mark unchanged XP stale or request status")
    row.levelCell.scripts.OnLeave(row.levelCell)
    assert(not tooltip.shown, "leaving the Level cell dismisses progress details")
    page.rows[4].levelCell.scripts.OnEnter(page.rows[4].levelCell)
    assert(tooltip.lines[1] == "Maximum level" and #tooltip.lines == 1,
        "maximum-level details do not invent zero required XP or add report details")
    page.rows[5].levelCell.scripts.OnEnter(page.rows[5].levelCell)
    assert(tooltip.lines[1] == "Level progress unavailable" and #tooltip.lines == 1,
        "unknown XP is explained without report details")
    page.rows[7].levelCell.scripts.OnEnter(page.rows[7].levelCell)
    assert(tooltip.lines[1] == "XP: 500 / 1000" and tooltip.lines[2] == "To next level: 500 XP"
        and #tooltip.lines == 2, "stale progress tooltips show only XP and remaining XP")
    page:SetOffset(2)
    assert(not tooltip.shown and page.rows[1].playerID == "charlie" and page.rows[1].progress:GetText() == "· 99%"
        and page.rows[7].playerID == "india" and page.rows[7].progress:GetText() == "· 20%"
        and page.rows[7].progressFill.textureColor[4] == 1,
        "scrolling dismisses old tooltips, resets pooled progress styling and keeps old unchanged online reports current")
    page.rows[1].levelCell.scripts.OnEnter(page.rows[1].levelCell)
    page.headers.level:Click()
    assert(not tooltip.shown and page.rows[1].playerID == "alpha", "sorting dismisses progress tooltips and keeps numeric level ordering")
    page:SetOffset(2)
    assert(page.rows[8].playerID == "foxtrot", "unknown levels remain after known levels when sorting ascending")
    page.headers.level:Click()
    page:SetOffset(2)
    assert(page.rows[8].playerID == "foxtrot", "unknown levels remain last when sorting descending")
    page:SetOffset(0)
    page.rows[1].levelCell.scripts.OnEnter(page.rows[1].levelCell)
    content.options:Click()
    assert(not tooltip.shown and not page.active, "leaving Content dismisses progress details and stops live work")
    progressAddon.optionsPanel.content:Click()
    assert(snapshots == 0, "returning to Content reuses status instead of requesting another snapshot")
    row = page.rows[1]
    row.levelCell.scripts.OnEnter(row.levelCell)
    players = {}
    progressAddon:RefreshOverview()
    assert(not tooltip.shown and not row:IsShown() and not row.levelCell.player and row.progress:GetText() == ""
        and not row.progressTrack:IsShown() and not row.progressFill:IsShown(),
        "removing a player clears the pooled cell, progress textures and any owned tooltip")
end

-- Initial Content setup creates one saved key; copying and friend import live only in Settings > Group.
do
    local initial, api, initialMessages, _, initialWorld = loadAddon(nil, false)
    local generatedCalls = 0
    api.math = setmetatable({ random = function(_, maximum)
        generatedCalls = generatedCalls + 1
        return maximum == 64 and 48 or 4827
    end }, { __index = math })
    loadOptions(initial, api)
    initialWorld:initialize()
    local content = initial.contentPanel
    local initialKey = "otter-4827"
    local initialRoom = initial:GetGroupChannelName()
    assert(content and content:IsShown() and not initial.optionsPanel and not initial.welcomePanel
        and not content.ownSecret and not content.friendSecret,
        "first login opens only Content with no key-sharing form")
    assert(initial:GetGroupSecret() == initialKey and initial.db.group.secret == initialKey
        and generatedCalls == 2, "initial Content setup generates and saves one group key")
    assert(#initialWorld.joinCalls == 1 and initialWorld.joinCalls[1] == initialRoom,
        "initial group creation uses normal chat autojoin once")
    initialWorld.fire("PLAYER_LOGIN")
    assert(generatedCalls == 2 and #initialWorld.joinCalls == 1,
        "duplicate login does not regenerate the key or request another join")
    content.options:Click()
    local options = initial.optionsPanel
    assert(options:IsShown() and not content:IsShown() and options.selectedTab == "group"
        and options.ownSecret:GetText() == initialKey,
        "Settings > Group displays the saved key for sharing")
    local unfocusedPaints = options.ownSecret.texturePaints
    options.ownSecret:SetFocus()
    assert(options.ownSecret.highlighted and options.ownSecret.texturePaints > unfocusedPaints,
        "focusing the saved key keeps copy highlighting and the native focus outline")
    options.ownSecret:ClearFocus()
    options.selectKey:Click()
    assert(options.ownSecret.focused and options.ownSecret.highlighted,
        "Select key focuses and highlights the saved key for copying")
    options.ownSecret:UserInput("accidental-edit")
    assert(options.ownSecret:GetText() == initialKey and initial:GetGroupSecret() == initialKey,
        "typing into the copy field cannot change the saved key")

    local restored, restoredApi, _, restoredEvent, restoredWorld = loadAddon(initial.db, true)
    restoredApi.math = setmetatable({ random = function()
        error("a persisted key must not be regenerated")
    end }, { __index = math })
    loadOptions(restored, restoredApi)
    restoredEvent("ADDON_LOADED", "LockInTools")
    assert(restored.ready and not restored.contentPanel and not restored.optionsPanel
        and restored:GetGroupSecret() == initialKey,
        "loading after login preserves the key without reopening completed setup")
    restoredApi.SlashCmdList.LOCKINTOOLS("welcome")
    restored.contentPanel.options:Click()
    assert(restored.optionsPanel.ownSecret:GetText() == initialKey and not restored.welcomePanel,
        "the legacy welcome command reaches the same saved key through Content and Settings")
    restored.optionsPanel.CloseButton:Click()
    restoredWorld:advance(1)
    assert(restoredWorld.joinCalls[1] == initialRoom, "the saved setup key restores the same channel")

    options.secret:UserInput("   ")
    options.applyGroup:Click()
    assert(initial:GetGroupSecret() == initialKey and not options.applyGroup:IsEnabled(),
        "blank friend input disables applying without changing groups")
    options.secret.scripts.OnEnterPressed(options.secret)
    assert(options.feedback:GetText() ~= "" and options.feedback.color[1] == 1,
        "submitting blank friend input with Enter reports an error")
    options.secret:UserInput("invalid--key")
    options.applyGroup:Click()
    options.applyGroup:Click()
    assert(initial:GetGroupSecret() == initialKey and #initialWorld.leaveCalls == 0,
        "an invalid friend's key preserves the group and its transport")
    options.secret:UserInput("  OTTER-4827  ")
    options.applyGroup:Click()
    assert(initial:GetGroupSecret() == initialKey and options.applyGroup:GetText() == "Use key"
        and options.secret:GetText() == "" and #initialWorld.leaveCalls == 0 and #initialWorld.joinCalls == 1,
        "the same canonical friendly key succeeds without confirmation or transport switching")
    options.secret:UserInput("first-friend")
    options.applyGroup:Click()
    assert(initial:GetGroupSecret() == initialKey and options.applyGroup:GetText() == "Confirm switch",
        "importing a friend's key requires confirmation before changing every feature's group")
    options.secret:UserInput("other-friend")
    assert(options.applyGroup:GetText() == "Use key", "editing the friend key resets switch confirmation")
    options.applyGroup:Click()
    initialWorld:completeJoin(initialRoom, 7)
    assert(options.secret:GetText() == "other-friend" and options.applyGroup:GetText() == "Confirm switch"
        and options.ownSecret:GetText() == initialKey,
        "asynchronous chat updates preserve the friend's draft, confirmation and saved copy field")
    options.applyGroup:Click()
    assert(initial:GetGroupSecret() == "other-friend" and initial.db.group.secret == "other-friend"
        and options.ownSecret:GetText() == "other-friend" and options.secret:GetText() == "",
        "a confirmed friend key becomes the saved copy field and clears the import draft")
    assert(initialWorld.leaveCalls[1] == initialRoom
        and initialWorld.joinCalls[2] == initial:GetGroupChannelName(),
        "Group friend import uses the existing channel lifecycle")
    assert(initial:SetGroupSecret(SECRET))
    assert(options.ownSecret:GetText() == SECRET, "the saved copy field follows external group changes")
    local previousLeaves = #initialWorld.leaveCalls
    options.secret:UserInput("  " .. SECRET:lower() .. "  ")
    options.applyGroup:Click()
    assert(initial:GetGroupSecret() == SECRET and #initialWorld.leaveCalls == previousLeaves
        and options.applyGroup:GetText() == "Use key" and options.secret:GetText() == "",
        "legacy keys retain canonical same-group behavior without confirmation")
    options.secret:UserInput(OTHER_SECRET)
    options.applyGroup:Click()
    options.selectKey:Click()
    options.secret:SetFocus()
    options.CloseButton:Click()
    assert(not options:IsShown() and options.ownSecret:GetText() == "" and options.secret:GetText() == ""
        and not options.ownSecret.focused and not options.secret.focused,
        "closing Settings clears plaintext keys, drafts and focus")
    initial:OpenOptions()
    assert(initial.optionsPanel == options and options.ownSecret:GetText() == SECRET
        and options.secret:GetText() == "" and options.applyGroup:GetText() == "Use key"
        and generatedCalls == 2, "reopening Group restores only the saved key without regenerating it")
    -- Hiding UIParent fires OnHide while the child's own IsShown flag stays true.
    options.secret:UserInput(OTHER_SECRET)
    options.applyGroup:Click()
    options.scripts.OnHide(options)
    initial:RefreshOptions()
    assert(options:IsShown() and options.ownSecret:GetText() == "" and options.secret:GetText() == ""
        and options.applyGroup:GetText() == "Use key",
        "hiding the whole interface clears keys and prevents background refresh from restoring them")
    options.scripts.OnShow(options)
    assert(options.ownSecret:GetText() == SECRET, "showing the interface restores Group's saved copy field")
    options.tabs.chat:Click()
    initial:RefreshOptions()
    assert(options.ownSecret:GetText() == "" and options.secret:GetText() == "",
        "hidden Group fields stay empty while another settings page is active")
    assert(not contains(initialMessages, initialKey) and not contains(initialMessages, "other-friend")
        and not contains(initialMessages, SECRET) and not contains(initialMessages, OTHER_SECRET),
        "Content and Group never print either person's key to chat")
end

-- Manual Content setup respects autojoin; Group import remains available after generation failure.
do
    local manual, api, _, _, manualWorld = loadAddon(settings("", false), false)
    loadOptions(manual, api)
    manualWorld:initialize()
    assert(not manual.contentPanel and not manual.optionsPanel, "welcome off suppresses automatic Content setup")
    api.SlashCmdList.LOCKINTOOLS("")
    assert(manual:HasGroup() and #manualWorld.joinCalls == 0,
        "manually opening Content saves a key while respecting disabled autojoin")
    manual.contentPanel.options:Click()
    local options = manual.optionsPanel
    options.secret:UserInput("manual-friend")
    options.applyGroup:Click()
    options.applyGroup:Click()
    assert(manual:GetGroupSecret() == "manual-friend" and options.ownSecret:GetText() == "manual-friend"
        and #manualWorld.joinCalls == 0 and not manual.db.chat.autoJoin,
        "Group friend import preserves disabled autojoin")

    local failed, failedApi, failedMessages, _, failedWorld = loadAddon(nil, false)
    local attempts = 0
    failedApi.math = setmetatable({ random = function()
        attempts = attempts + 1
        error("private generator failure")
    end }, { __index = math })
    loadOptions(failed, failedApi)
    failedWorld:initialize()
    assert(failed.contentPanel and failed.contentPanel:IsShown() and not failed:HasGroup()
        and failed.db.group.secret == "" and failed.contentPanel.feedback:GetText() ~= "",
        "initial generation failure leaves Content usable and saved group data empty")
    failed:RefreshOptions()
    assert(attempts == 1, "status refresh does not retry failed key generation")
    failed.contentPanel.options:Click()
    local failedOptions = failed.optionsPanel
    assert(failedOptions.secret:IsEnabled() and not failedOptions.applyGroup:IsEnabled()
        and failedOptions.ownSecret:GetText() == "", "Group import remains available after generation failure")
    failedOptions.createGroup:Click()
    assert(not failed:HasGroup() and failedOptions.secret:GetText() == "" and failedOptions.feedback:GetText() ~= "",
        "a failed Group create action preserves saved data and reports a useful error")
    failedOptions.secret:UserInput("friend-4827")
    failedOptions.applyGroup:Click()
    assert(failed:GetGroupSecret() == "friend-4827" and failedOptions.ownSecret:GetText() == "friend-4827"
        and #failedWorld.joinCalls == 1, "a friend's key saves immediately when no group exists")
    assert(not contains(failedMessages, "private generator failure") and not contains(failedMessages, "friend-4827"))
end

-- Content and Group preserve damaged and newer-schema saved data.
do
    local invalidSettings = settings("damaged secret", false)
    invalidSettings.showWelcome = true
    local invalid, api, _, _, invalidWorld = loadAddon(invalidSettings, false)
    api.math = setmetatable({ random = function()
        error("damaged stored keys must not be replaced")
    end }, { __index = math })
    loadOptions(invalid, api)
    invalidWorld:initialize()
    assert(invalid.invalidGroupSecret and invalid.db.group.secret == "damaged secret"
        and invalid.contentPanel:IsShown() and not invalid.optionsPanel and #invalidWorld.joinCalls == 0,
        "initial Content preserves an invalid saved key for explicit repair")
    invalid.contentPanel.options:Click()
    assert(invalid.optionsPanel.ownSecret:GetText() == "" and invalid.optionsPanel.secret:IsEnabled(),
        "Group permits explicit repair without exposing the invalid saved key")
    invalid.optionsPanel.content:Click()
    invalid:OpenWelcome()
    assert(invalid.db.group.secret == "damaged secret" and not invalid.welcomePanel,
        "the compatibility alias does not replace damaged settings or create another window")

    local futureSettings = { schemaVersion = 4, showWelcome = true, important = "keep",
        group = { secret = SECRET }, chat = { autoJoin = false } }
    local future, futureApi, _, _, futureWorld = loadAddon(futureSettings, false)
    futureApi.math = setmetatable({ random = function()
        error("read-only preferences must not generate a key")
    end }, { __index = math })
    loadOptions(future, futureApi)
    futureWorld:initialize()
    assert(future.savedDataReadOnly and not future.contentPanel and not future.optionsPanel,
        "newer schemas do not automatically start Content setup")
    future:OpenWelcome()
    future.contentPanel.options:Click()
    local options = future.optionsPanel
    assert(not options.secret:IsEnabled() and not options.applyGroup:IsEnabled()
        and not options.createGroup:IsEnabled() and options.ownSecret:GetText() == "",
        "read-only Group disables saved edits and leaves the copy field empty")
    options.applyGroup:Click()
    assert(futureApi.LockInToolsDB == futureSettings and futureSettings.schemaVersion == 4
        and futureSettings.group.secret == SECRET and futureSettings.important == "keep"
        and futureSettings.showWelcome and not futureSettings.chat.autoJoin and #futureWorld.joinCalls == 0,
        "opening read-only Content and Group leaves the original saved data untouched")
end

-- Optional skins must preserve lazy Content/Settings creation and Group privacy.
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
        and not disabled.optionsPanel and not disabled.contentPanel,
        "registering an installed but disabled skin does not construct windows")
    registration(nil)
    registration("unsupported")
    disabledEnvironment.UIParent:SetSize(640, 480)
    disabled:OpenOptions()
    disabled:OpenContent()
    assert(not disabled.optionsPanel.skinApplied and not disabled.contentPanel.skinApplied
        and disabled.optionsPanel.TitleText.font[1] == "Fonts\\FRIZQT__.TTF"
        and disabled:GetGroupSecret() == SECRET and registrations == 1,
        "disabled or invalid optional skins retain usable native windows and the saved key")
    assert(disabled.optionsPanel.scale > 0 and disabled.optionsPanel.scale < 1
        and disabled.optionsPanel:GetWidth() * disabled.optionsPanel.scale <= disabledEnvironment.UIParent:GetWidth()
        and disabled.optionsPanel:GetHeight() * disabled.optionsPanel.scale <= disabledEnvironment.UIParent:GetHeight()
        and disabled.contentPanel:GetHeight() * disabled.contentPanel.scale <= disabledEnvironment.UIParent:GetHeight(),
        "both native windows fit a viewport smaller than their preferred size")
    disabled:OpenOptions()
    disabled.optionsPanel.secret:UserInput(OTHER_SECRET)
    disabled.optionsPanel.applyGroup:Click()
    disabled.optionsPanel.CloseButton:Click()
    assert(not disabled.optionsPanel:IsShown() and disabled.optionsPanel.secret:GetText() == ""
        and disabled:GetGroupSecret() == SECRET,
        "the native title-bar close button clears drafts without confirming a group switch")
    disabledEnvironment.UIParent:SetSize(1920, 1080)
    disabled:OpenOptions()
    assert(disabled.optionsPanel.scale == 1 and disabled.optionsPanel.applyGroup:GetText() == "Use key",
        "reopening on a larger viewport restores normal scale and resets confirmation")
end

do
    local skin, appearance = skinFixture()
    local early, _, earlyMessages = loadSkinnedOptions(function(_, callback) callback(skin) end)
    assert(not early.optionsPanel and not early.contentPanel and appearance.shells == 0,
        "an enabled skin callback before first use preserves both lazy windows")
    early:OpenContent()
    local content = early.contentPanel
    assert(content.skinApplied and content.TitleText.font[1] == appearance.font
        and content.TitleText.font[2] == 16 and not content.ownSecret,
        "Content receives the optional font while keeping its heading size and key-free UI")
    appearance.font = "SkinFont-B.ttf"
    appearance.accent = { 0.9, 0.3, 0.6 }
    for _, callback in ipairs(appearance.looks) do callback() end
    early:RefreshOverview()
    assert(content.TitleText.font[1] == appearance.font and not early.optionsPanel
        and content.overviewPage.rows[1].progressFill.textureColor[1] == appearance.accent[1]
        and content.overviewPage.rows[1].progressFill.textureColor[3] == appearance.accent[3],
        "live Content font and progress accent updates preserve lazy Settings creation")
    content.options:Click()
    local options = early.optionsPanel
    assert(options.skinApplied and options.TitleText.font[1] == appearance.font
        and options.positionSharing:GetCheckedTexture().vertexColor[1] == appearance.accent[1]
        and appearance.shells == 2,
        "later-created Settings uses the current font and accent")
    options.secret:UserInput(OTHER_SECRET)
    options.applyGroup:Click()
    options.secret:SetFocus()
    appearance.font = "SkinFont-C.ttf"
    appearance.accent = { 0.4, 0.6, 1 }
    for _, callback in ipairs(appearance.looks) do callback() end
    assert(options.TitleText.font[1] == appearance.font and options.secret.focused
        and options.secret:GetText() == OTHER_SECRET and options.applyGroup:GetText() == "Confirm switch"
        and options.ownSecret:GetText() == SECRET and early:GetGroupSecret() == SECRET,
        "live Settings appearance changes preserve Group focus, saved copy key and pending confirmation")
    options.tabs.position:Click()
    assert(options.tabs.position.skinTabApplied and options.tabs.position.skinTabSelected
        and not options.tabs.group.skinTabSelected and not options.tabs.chat.skinTabSelected,
        "the optional skin selects exactly the active Settings category")
    options.tabs.position.scripts.OnEnter(options.tabs.position)
    options.tabs.position.scripts.OnLeave(options.tabs.position)
    assert(options.tabs.position:GetFontString().alpha == 0,
        "selecting and hovering a skinned tab keeps its replaced native label hidden")
    for _, callback in ipairs(appearance.looks) do callback() end
    assert(options.positionSharing:GetCheckedTexture().vertexColor[1] == appearance.accent[1]
        and options.positionSharing:GetCheckedTexture().vertexColor[3] == appearance.accent[3]
        and options.selectedTab == "position" and options.pages.position:IsVisible()
        and options.tabs.position.skinTabSelected and not options.tabs.group.skinTabSelected
        and options.tabs.position:GetFontString().alpha == 0,
        "appearance updates retain the Settings page and its skin selection")
    options.content:Click()
    for _, callback in ipairs(appearance.looks) do callback() end
    assert(content:IsVisible() and not options:IsVisible() and content.pages.overview:IsVisible()
        and content.tabs.overview.skinTabApplied and content.tabs.overview.skinTabSelected
        and content.tabs.overview:GetFontString().alpha == 0 and options.ownSecret:GetText() == "",
        "restyling Content keeps Overview selected and hidden Group keys empty")
    early:OpenOptions("group")
    options.secret:UserInput(OTHER_SECRET)
    options.applyGroup:Click()
    options.CloseButton:Click()
    assert(not options:IsShown() and options.ownSecret:GetText() == "" and options.secret:GetText() == "",
        "the styled Settings close button preserves hidden-key cleanup")
    for _, callback in ipairs(appearance.looks) do callback() end
    assert(options.ownSecret:GetText() == "" and options.secret:GetText() == "",
        "restyling hidden Settings never restores cleared keys")
    early:OpenOptions()
    assert(options.ownSecret:GetText() == SECRET and options.applyGroup:GetText() == "Use key"
        and appearance.shells == 2 and #appearance.looks == 1,
        "reopening reuses both styled windows and resets confirmation without registering the skin again")
    assert(not contains(earlyMessages, SECRET) and not contains(earlyMessages, OTHER_SECRET),
        "skin refresh never prints key fields")
end
do
    local registration
    local late, _, _, lateWorld = loadSkinnedOptions(function(_, callback) registration = callback end)
    late:OpenOptions()
    local options = late.optionsPanel
    options.tabs.chat:Click()
    options.autoJoin:Click()
    options.tabs.group:Click()
    options.secret:UserInput(OTHER_SECRET)
    options.applyGroup:Click()
    local skin, appearance = skinFixture()
    registration(skin)
    assert(options.skinApplied and options.TitleText.font[1] == appearance.font
        and options.secret:GetText() == OTHER_SECRET and options.applyGroup:GetText() == "Confirm switch"
        and options.autoJoin:GetChecked() and late.db.chat.autoJoin,
        "a late skin callback preserves group confirmation and applied feature preferences")
    options.applyGroup:Click()
    assert(late:GetGroupSecret() == OTHER_SECRET and options.secret:GetText() == ""
        and #lateWorld.joinCalls >= 1,
        "confirmation and key cleanup still work after skinning an open form")
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
        "a skin without tab-selection support leaves native Settings categories usable")
    options.content:Click()
    local content = partial.contentPanel
    for _, callback in ipairs(appearance.looks) do callback() end
    assert(not content.tabs.overview.skinTabApplied and content.tabs.overview.themeTab.selected
        and content.tabs.overview:GetFontString().alpha ~= 0 and content.pages.overview:IsVisible(),
        "a skin without tab-selection support also leaves Content navigation usable")
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
    resilient:OpenOptions()
    resilient.optionsPanel.secret:UserInput(OTHER_SECRET)
    resilient.optionsPanel.applyGroup:Click()
    resilient.optionsPanel.applyGroup:Click()
    resilient.optionsPanel.CloseButton:Click()
    assert(resilient:GetGroupSecret() == OTHER_SECRET and not resilient.optionsPanel:IsShown()
        and resilient.optionsPanel.ownSecret:GetText() == "" and resilient.optionsPanel.secret:GetText() == "",
        "throwing skin methods cannot block group confirmation or hidden-key cleanup")
    assert(resilient.optionsPanel.CloseButton:GetFontString().alpha ~= 0,
        "failed close-button skinning keeps the native close symbol visible")
    assert(not contains(resilientMessages, "optional appearance failure") and not contains(resilientMessages, OTHER_SECRET),
        "optional skin errors do not expose internal errors or key contents")
end

assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep test environments isolated")
print("PASS: startup, migration, minimap button, shared identity, chat/data connections, positions, retries, group lifecycle, themed Content and Settings")

