-- This harness is never loaded by the addon.
-- Server membership changes are asynchronous, as they are in the client.
local loadNotifications = dofile("tests/support/notifications.lua")
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
        dataJoinCalls = {}, dataLeaveCalls = {}, dataSends = {}, rosterSends = {}, statusSends = {}, guideSends = {}, prefixes = {},
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
        GameTooltip_SetDefaultAnchor = function(tooltip, parent)
            tooltip:SetOwner(parent, "ANCHOR_NONE")
            tooltip.default = 1
        end,
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
                    or isRosterMessage(message) and world.rosterSends
                    or message:match("^1|guides|") and world.guideSends or world.dataSends
                sends[#sends + 1] = {
                    prefix = prefix, message = message, target = target,
                }
                return 0
            end,
        },
        LeaveChannelByName = function(name)
            local calls = name:lower():match("^litdata") and world.dataLeaveCalls or world.leaveCalls
            calls[#calls + 1] = name
            if world.leaveThrows then error("Native leave unavailable") end
            if not world.holdLeaves then world.channels[name:lower()] = nil end
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
    local _, prepareMinimap = dofile("tests/support/ui.lua")
    prepareMinimap(environment, world)
    world.notificationErrors = loadNotifications(addon, environment)
    for _, file in ipairs({ "Libs/LibDataBroker-1.1/LibDataBroker-1.1.lua", "Libs/LibDBIcon-1.0/LibDBIcon-1.0.lua",
        "Core.lua", "Crypto.lua", "Group.lua", "Chat.lua", "DataChannel.lua", "Data.lua", "DataStatus.lua", "Position.lua", "Roster.lua", "Ranking.lua",
        "RestedXPCodec.lua", "RestedXPAdapter.lua", "RestedXP.lua", "Minimap.lua", "Commands.lua" }) do
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
            if frame.events[event] and frame.onEvent then frame.onEvent(frame, event, ...) end
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

return {
    loadAddon = loadAddon, settings = settings, contains = contains,
    SECRET = SECRET, OTHER_SECRET = OTHER_SECRET,
    isRosterMessage = isRosterMessage, isStatusMessage = isStatusMessage,
}
