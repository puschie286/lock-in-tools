-- Shared feature routing and the native channel lifecycle run against mocked WoW APIs.
local function loadModule(file, addon, environment)
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

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function equal(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, item in pairs(left) do if not equal(item, right[key]) then return false end end
    for key in pairs(right) do if left[key] == nil then return false end end
    return true
end

local function newAddon(saved, readOnly, withPositions, native)
    local world = {
        now = 0, epoch = 2000000000, timers = {}, sent = {}, messages = {}, frames = {},
        x = 0.25, y = 0.75, map = 37, joins = {}, leaves = {}, channels = {}, nativeSends = {}, prefixCalls = {},
        sendResult = 0, sendCalls = 0, restrictionChecks = 0,
    }
    local environment = setmetatable({
        bit = false, bit32 = false, C_ChatInfo = false,
        GetTime = function() return world.now end,
        GetServerTime = function() return world.epoch + math.floor(world.now) end,
        GetNormalizedRealmName = function() return "TestRealm" end,
        UnitFullName = function(unit) assert(unit == "player"); return native and native.playerName or "Self", "Test Realm" end,
        CreateFrame = function(kind)
            assert(kind == "Frame")
            local frame = { events = {} }
            function frame:RegisterEvent(event) self.events[event] = true end
            function frame:UnregisterEvent(event) self.events[event] = nil end
            function frame:SetScript(script, callback) assert(script == "OnEvent"); self.callback = callback end
            world.frames[#world.frames + 1] = frame
            return frame
        end,
        C_Timer = { NewTimer = function(delay, callback)
            local timer = { at = world.now + delay, callback = callback }
            function timer:Cancel() self.cancelled = true end
            world.timers[#world.timers + 1] = timer
            return timer
        end },
        C_Map = {
            GetBestMapForUnit = function(unit) assert(unit == "player"); return world.map end,
            GetPlayerMapPosition = function(map, unit)
                assert(map == world.map and unit == "player")
                return { GetXY = function() return world.x, world.y end }
            end,
        },
    }, { __index = _G })
    environment._G = environment
    if native then
        environment.Enum = {
            RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1, InvalidPrefix = 2 },
            SendAddonMessageResult = { Success = 0, AddOnMessageLockdown = 11 },
        }
        environment.GetChannelName = function(identifier)
            if type(identifier) == "string" then
                local channel = world.channels[identifier:lower()]
                if channel then return channel.id, channel.name end
            else
                for _, channel in pairs(world.channels) do if channel.id == identifier then return channel.id, channel.name end end
            end
            return 0, nil
        end
        environment.JoinTemporaryChannel = function(name, password)
            world.joins[#world.joins + 1] = { name = name, password = password, at = world.now }
            if world.joinThrows then error("Native join unavailable") end
            return 0, name
        end
        environment.LeaveChannelByName = function(name)
            world.leaves[#world.leaves + 1] = name
            world.channels[name:lower()] = nil
        end
        environment.C_ChatInfo = {
            RegisterAddonMessagePrefix = function(prefix)
                world.prefixCalls[#world.prefixCalls + 1] = prefix
                if world.prefixThrows then error("Prefix registration unavailable") end
                return world.prefixResult or 0
            end,
            SendAddonMessage = function(prefix, message, distribution, target)
                world.sendCalls = world.sendCalls + 1
                assert(distribution == "CHANNEL", "Shared data uses one native channel broadcast, never whispers")
                if world.sendThrows then error("Native send unavailable") end
                world.nativeSends[#world.nativeSends + 1] = {
                    prefix = prefix, message = message, distribution = distribution, target = target, at = world.now,
                }
                return world.sendResult
            end,
            AreOutgoingAddonChatMessagesRestricted = function()
                world.restrictionChecks = world.restrictionChecks + 1
                error("The native result, not a realm restriction precheck, decides acceptance")
            end,
        }
        environment.DEFAULT_CHAT_FRAME = {
            channelList = { "General" },
            AddChannel = function() error("Shared data must not appear in native chat") end,
            AddMessage = function(_, message) world.messages[#world.messages + 1] = message end,
        }
    end
    local addon = {
        db = saved or { schemaVersion = 3, group = { secret = "otter-4827" } },
        initialized = true, ready = false, savedDataReadOnly = readOnly,
    }
    function addon:Print(message) world.messages[#world.messages + 1] = message end
    function addon:RefreshOptions() end
    function addon:RefreshPositionPins() end
    for _, file in ipairs({ "Crypto.lua", "Group.lua", "Data.lua" }) do
        loadModule(file, addon, environment)
    end
    addon:InitializeGroup()
    addon:InitializeData()
    if withPositions then
        loadModule("Position.lua", addon, environment)
        addon:InitializePositions()
    end
    world.environment, world.addon = environment, addon
    function world:fire(event, ...)
        for _, frame in ipairs(self.frames) do
            if frame.events[event] then frame.callback(frame, event, ...) end
        end
    end
    function world:login()
        addon.ready = true
        addon:OnDataLogin()
        if withPositions then addon:OnPositionLogin() end
    end
    function world:member(id, name)
        name = name or addon:GetGroupDataChannelName()
        self.channels[name:lower()] = { id = id, name = name }
        self:fire("CHANNEL_UI_UPDATE")
    end
    function world:notice(reason, name)
        name = name or addon:GetGroupDataChannelName()
        self:fire("CHAT_MSG_CHANNEL_NOTICE", reason, "", "", "", "", "", 0, 0, name)
    end
    function world:incoming(message, sender, metadata)
        metadata = metadata or {}
        self:fire("CHAT_MSG_ADDON", metadata.prefix or addon:GetDataPrefix(), message,
            metadata.distribution or "CHANNEL", sender, nil, 0, metadata.id, metadata.name)
    end
    function world:connect(accepted)
        addon:SetDataTransport(function(prefix, message)
            self.sent[#self.sent + 1] = { at = self.now, prefix = prefix, message = message }
            if accepted == "throw" then error("Transport unavailable") end
            return accepted ~= false
        end)
    end
    function world:advance(seconds)
        local target, callbacks = self.now + seconds, 0
        while true do
            local nextIndex, nextTimer
            for index, entry in ipairs(self.timers) do
                if not entry.cancelled and entry.at <= target
                    and (not nextTimer or entry.at < nextTimer.at) then
                    nextIndex, nextTimer = index, entry
                end
            end
            if not nextTimer then break end
            table.remove(self.timers, nextIndex)
            self.now, callbacks = nextTimer.at, callbacks + 1
            assert(callbacks < 200, "Shared data must not create an unbounded timer loop")
            nextTimer.callback(nextTimer)
        end
        self.now = target
    end
    return addon, world
end

-- Features share one envelope and prefix while keeping their handlers independent.
local addon, world = newAddon()
local database = copy(addon.db)
local incoming, connectionChanges = {}, {}
assert(addon:GetDataPrefix() == "LockInToolsData")
assert(addon:RegisterDataFeature("echo", function(sender, payload)
    incoming[#incoming + 1] = { sender = sender, payload = payload }
end, function(connected) connectionChanges[#connectionChanges + 1] = connected end))
assert(#connectionChanges == 1 and connectionChanges[1] == false)
assert(not addon:IsDataConnected() and not addon:SendData("echo", "before login"))
addon.ready = true
assert(not addon:SendData("echo", "without a backend"))
assert(not addon:ReceiveData("Friend", "1|echo|before connection"))
world:connect()
assert(addon:IsDataConnected() and connectionChanges[#connectionChanges] == true)
assert(addon:SendData("echo", "a|b||c"))
assert(#world.sent == 1 and world.sent[1].prefix == "LockInToolsData" and world.sent[1].message == "1|echo|a|b||c")
assert(addon:ReceiveData("Friend-Test Realm", world.sent[1].message))
assert(#incoming == 1 and incoming[1].sender == "Friend-Test Realm" and incoming[1].payload == "a|b||c",
    "Route only the envelope and preserve the actual sender and complete feature payload")
local other = 0
assert(addon:RegisterDataFeature("other-feature_1", function(sender, payload)
    assert(sender == "Other" and payload == "separate")
    other = other + 1
    return true
end))
assert(addon:ReceiveData("Other", "1|other-feature_1|separate"))
assert(other == 1 and #incoming == 1)
assert(not addon:RegisterDataFeature("echo", function() error("Duplicate replaced the original") end))
assert(addon:ReceiveData("Friend", "1|echo|original handler"))
assert(#incoming == 2)

-- Validate routing identifiers and the native 255-byte message budget.
for _, feature in ipairs({ "", "Upper", "with.dot", "bad|name", "_start", string.rep("a", 33) }) do
    assert(not addon:RegisterDataFeature(feature, function() end))
end
assert(not addon:RegisterDataFeature("missing_handler", nil))
assert(not addon:RegisterDataFeature("invalid_notice", function() end, false))
assert(addon:RegisterDataFeature(string.rep("a", 32), function() end))
local maximumPayload = string.rep("x", 255 - #"1|echo|")
assert(addon:SendData("echo", maximumPayload) and #world.sent[#world.sent].message == 255)
assert(not addon:SendData("echo", maximumPayload .. "x"))
assert(addon:ReceiveData("Friend", "1|echo|" .. maximumPayload))
local receivedBefore = #incoming
for _, message in ipairs({
    "2|echo|wrong version", "1|unknown|missing handler", "1|echo", "1||missing feature",
    "1|Upper|bad identifier", "1|echo|" .. maximumPayload .. "x",
}) do
    assert(not addon:ReceiveData("Friend", message))
end
assert(#incoming == receivedBefore)
assert(not addon:SendData("unregistered", "payload") and not addon:SendData("echo", false))
assert(not addon:SendData("echo", "native\000separator"))
assert(not addon:ReceiveData("Friend", "1|echo|native\000separator"))
assert(not addon:ReceiveData("", "1|echo|no sender") and not addon:ReceiveData(nil, "1|echo|no sender"))
assert(not addon:ReceiveData("Friend", false))
addon.ready = false
assert(not addon:IsDataConnected() and not addon:SendData("echo", "not ready")
    and not addon:ReceiveData("Friend", "1|echo|not ready"))
addon.ready = true

-- Feature acceptance and connection callbacks cannot break neighboring features.
assert(addon:RegisterDataFeature("declined", function() return false end))
assert(addon:RegisterDataFeature("broken", function() error("Feature error") end))
assert(not addon:ReceiveData("Friend", "1|declined|payload"))
assert(not addon:ReceiveData("Friend", "1|broken|payload"))
assert(addon:ReceiveData("Friend", "1|echo|still working"))
local notified = {}
assert(addon:RegisterDataFeature("bad_notice", function() end, function() error("Notice error") end))
assert(addon:RegisterDataFeature("good_notice", function() end, function(connected)
    notified[#notified + 1] = connected
end))
assert(notified[#notified] == true, "A late subscriber receives the current connection state")
local previousNotices = #connectionChanges
world:connect()
assert(#connectionChanges == previousNotices + 1 and notified[#notified] == true,
    "Replacing a backend notifies features even when it stays connected")
addon:SetDataTransport(nil)
assert(not addon:IsDataConnected() and notified[#notified] == false)
assert(not addon:SendData("echo", "disconnected") and not addon:ReceiveData("Friend", "1|echo|disconnected"))

-- Failed backend calls never queue payloads for a later connection.
world:connect(false)
assert(not addon:SendData("echo", "failed payload"))
world:connect("throw")
assert(not addon:SendData("echo", "raised payload"))
local attempts = #world.sent
world:connect()
assert(#world.sent == attempts, "Binding a backend must not flush failed or disconnected messages")
assert(addon:SendData("echo", "current payload") and #world.sent == attempts + 1)
assert(world.sent[#world.sent].message == "1|echo|current payload")
assert(equal(addon.db, database), "The communication helper must not persist its runtime state")

-- Shared data credentials are group-derived without changing established chat credentials.
local same = newAddon()
local channel, password = addon:GetGroupDataChannelName(), addon:GetGroupDataChannelPassword()
assert(type(channel) == "string" and #channel == 31 and channel:sub(1, 7) == "LITDATA")
assert(type(password) == "string" and #password == 31)
assert(same:GetGroupDataChannelName() == channel and same:GetGroupDataChannelPassword() == password)
assert(channel ~= addon:GetGroupChannelName() and password ~= addon:GetGroupChannelPassword())
local oldFingerprint = addon:GetGroupFingerprint()
local lifecycle = {}
addon.OnGroupChanged = function(self)
    assert(not self:IsDataConnected(), "Disconnect before chat observes the new group")
    lifecycle[#lifecycle + 1] = "chat"
end
addon.OnPositionGroupChanged = function(self)
    assert(not self:IsDataConnected(), "Disconnect before features observe the new group")
    lifecycle[#lifecycle + 1] = "position"
end
assert(addon:SetGroupSecret("different-group"))
assert(#lifecycle == 2 and not addon:IsDataConnected() and notified[#notified] == false)
assert(addon:GetGroupFingerprint() ~= oldFingerprint and addon:GetGroupDataChannelName() ~= channel)
assert(not addon:SendData("echo", "old connection"))
world:connect()
assert(addon:ReceiveData("Friend", "1|echo|handler retained"), "Features survive a group change and can use the new connection")
addon:LeaveGroup()
assert(not addon:IsDataConnected() and addon:GetGroupDataChannelName() == nil and addon:GetGroupDataChannelPassword() == nil)
world:connect()
assert(not addon:IsDataConnected() and not addon:SendData("echo", "no group"))

-- Read-only profiles preserve all saved data and cannot connect or dispatch.
local saved = { schemaVersion = 99, group = { secret = "otter-4827" }, custom = { untouched = true } }
local original = copy(saved)
local readOnly, readOnlyWorld = newAddon(saved, true)
readOnly.ready = true
readOnly:RegisterDataFeature("echo", function() error("Read-only dispatch") end)
readOnlyWorld:connect()
assert(not readOnly:IsDataConnected() and not readOnly:SendData("echo", "payload")
    and not readOnly:ReceiveData("Friend", "1|echo|payload"))
assert(equal(saved, original))
assert(type(readOnly:GetDataStatusText()) == "string")

-- Position sharing uses the shared feature route and keeps its movement/heartbeat behavior.
addon, world = newAddon(nil, false, true)
addon.ready = true
addon:OnPositionLogin()
addon:SetPositionSharing(true)
world:advance(2)
assert(#world.sent == 0 and addon:GetPositionStatusText():find("Waiting", 1, true))
world:connect()
world:advance(2)
assert(#world.sent == 1 and world.sent[1].prefix == "LockInToolsData"
    and world.sent[1].message:match("^1|position|1|P|"))
world:advance(14)
assert(#world.sent == 1)
world:advance(2)
assert(#world.sent == 2, "An unchanged position still reaches the helper on its heartbeat")
world.x = 0.4
world:advance(2)
assert(#world.sent == 3 and world.sent[3].message:find("|0.40000|", 1, true))
assert(addon:ReceiveData("Friend-TestRealm", "1|position|1|P|2000000022|37|0.3|0.7"))
assert(addon:GetSharedPositions()["friend-testrealm"].x == 0.3)
local positionSends = #world.sent
addon:SetGroupSecret("new-position-group")
world:advance(2)
assert(#world.sent == positionSends and next(addon:GetSharedPositions()) == nil,
    "A group switch disconnects the shared path and clears the previous group's pins")
world:connect()
world:advance(2)
assert(#world.sent == positionSends + 1, "The new connection announces current data without inherited suppression")

-- An explicitly supplied transport owns delivery across native login and channel events.
do
    local alternate, clock = newAddon(nil, false, false, {})
    alternate:RegisterDataFeature("echo", function() end)
    clock:connect()
    clock:login()
    clock:member(7)
    clock:fire("PLAYER_ENTERING_WORLD")
    clock:notice("YOU_JOINED")
    clock:notice("YOU_LEFT")
    clock:advance(10)
    assert(alternate:IsDataConnected() and #clock.joins == 0 and #clock.prefixCalls == 0,
        "Native lifecycle events must not start or replace an explicit transport")
    assert(alternate:SendData("echo", "alternate") and #clock.sent == 1 and #clock.nativeSends == 0)
    clock:fire("PLAYER_LOGOUT")
    assert(not alternate:IsDataConnected(), "Logout still disconnects an explicit transport")
end
do
    local replacement, clock = newAddon(nil, false, false, {})
    replacement:RegisterDataFeature("echo", function() end)
    clock:login()
    assert(#clock.joins == 1)
    clock:connect()
    clock:member(7)
    clock:advance(2)
    assert(replacement:IsDataConnected() and #clock.joins == 1,
        "An already scheduled native retry cannot reclaim a replacement transport")
    assert(replacement:SendData("echo", "replacement") and #clock.sent == 1 and #clock.nativeSends == 0)
end

-- Login joins a separate data channel even when chat autojoin and position sharing are off.
do
    local profile = { schemaVersion = 3, group = { secret = "otter-4827" }, chat = { autoJoin = false } }
    local left, first = newAddon(copy(profile), false, true, { playerName = "Left" })
    local right, second = newAddon(copy(profile), false, true, { playerName = "Right" })
    local received = {}
    left:RegisterDataFeature("echo", function() end)
    right:RegisterDataFeature("echo", function(sender, payload) received[#received + 1] = { sender, payload } end)
    assert(#first.joins == 0 and #second.joins == 0 and #first.prefixCalls == 0,
        "Initialization registers local event handlers without network activity")
    first:login()
    second:login()
    for _, side in ipairs({ first, second }) do
        assert(#side.prefixCalls == 1 and side.prefixCalls[1] == "LockInToolsData" and #side.joins == 1)
        assert(side.joins[1].name == side.addon:GetGroupDataChannelName()
            and side.joins[1].password == side.addon:GetGroupDataChannelPassword())
        assert(not side.addon:IsDataConnected() and side.addon.db.position.sharing == false
            and side.addon.db.chat.autoJoin == false, "A pending native join is not an established connection")
    end
    second:incoming("1|echo|before membership", "Left", { id = 19 })
    assert(#received == 0)
    first:member(7)
    second:member(19)
    assert(left:IsDataConnected() and right:IsDataConnected())
    assert(left:SendData("echo", "a|b"))
    local sent = first.nativeSends[1]
    assert(sent.prefix == "LockInToolsData" and sent.message == "1|echo|a|b" and sent.target == "7")
    second:incoming(sent.message, "Left-TestRealm", { id = 19 })
    assert(#received == 1 and received[1][1] == "Left-TestRealm" and received[1][2] == "a|b")
    second:incoming(sent.message, "Left", { id = 19, prefix = "OTHER" })
    second:incoming(sent.message, "Left", { id = 19, distribution = "WHISPER" })
    second:incoming(sent.message, "Left", { id = 99, name = right:GetGroupDataChannelName() })
    assert(#received == 1, "Unrelated prefixes, distributions and channel IDs never enter feature routing")
    second:incoming(sent.message, "Left", { name = right:GetGroupDataChannelName():lower() })
    assert(#received == 2, "Use the channel base name only when a native local ID is unavailable")
    first.channels[left:GetGroupDataChannelName():lower()].id = 9
    assert(left:SendData("echo", "renumbered") and first.nativeSends[#first.nativeSends].target == "9")
    first.sendResult = 11
    assert(not left:SendData("echo", "rejected"))
    first.sendThrows = true
    assert(not left:SendData("echo", "API error") and left:IsDataConnected())
    first.sendThrows, first.sendResult = false, 0

    left:SetPositionSharing(true)
    right:SetPositionSharing(true)
    first.x, second.x = 0.4, 0.6
    first:advance(2)
    second:advance(2)
    local fromLeft, fromRight = first.nativeSends[#first.nativeSends], second.nativeSends[#second.nativeSends]
    assert(fromLeft.message:match("^1|position|1|P|") and fromRight.message:match("^1|position|1|P|"))
    second:incoming(fromLeft.message, "Left-TestRealm", { id = 19 })
    first:incoming(fromRight.message, "Right-TestRealm", { id = 9 })
    assert(left:GetSharedPositions()["right-testrealm"].x == 0.6 and right:GetSharedPositions()["left-testrealm"].x == 0.4,
        "Native channel events carry positions through the shared feature envelope")
    assert(first.restrictionChecks == 0 and second.restrictionChecks == 0)
end

-- Join retries are asynchronous, bounded and unaffected by UI-event storms.
do
    local joining, clock = newAddon(nil, false, false, {})
    clock:login()
    for _ = 1, 20 do clock:fire("CHANNEL_UI_UPDATE") end
    assert(#clock.joins == 1)
    clock:advance(2)
    assert(#clock.joins == 2 and clock.joins[2].at == 2)
    clock:advance(4)
    assert(#clock.joins == 3 and clock.joins[3].at == 6)
    clock:advance(8)
    assert(#clock.joins == 4 and clock.joins[4].at == 14)
    clock:advance(8)
    assert(joining.dataState.phase == "error" and not joining:IsDataConnected())
    clock:advance(60)
    assert(#clock.joins == 4)
end

-- A group switch cancels the old pending check; logout also cancels pending recovery.
do
    local pending, clock = newAddon(nil, false, false, {})
    clock:login()
    pending:SetGroupSecret("changed-while-joining")
    clock:advance(2)
    assert(#clock.joins == 2 and clock.joins[2].at == 1
        and clock.joins[2].name == pending:GetGroupDataChannelName(), "The old group's two-second check must not survive its replacement")
    clock:fire("PLAYER_LOGOUT")
    clock:advance(60)
    assert(#clock.joins == 2)
end

-- Deliberate leaves pause while a stale native membership record still exists.
for _, event in ipairs({ "YOU_LEFT", "CHANNEL_LEFT" }) do
    local paused, clock = newAddon(nil, false, false, {})
    clock:login()
    clock:member(7)
    local name = paused:GetGroupDataChannelName()
    if event == "CHANNEL_LEFT" then clock:fire(event, 7, name) else clock:notice(event) end
    assert(not paused:IsDataConnected() and paused.dataState.phase == "paused")
    clock:fire("CHANNEL_UI_UPDATE")
    clock:advance(30)
    assert(#clock.joins == 1 and not paused:IsDataConnected(), "Native membership restoration cannot undo an intentional leave")
    clock.channels[name:lower()] = nil
    paused:JoinDataChannel(true)
    assert(#clock.joins == 2)
    clock:member(11)
    assert(paused:IsDataConnected())
end

-- Missing membership disconnects immediately and recovers through the bounded join path.
do
    local recovering, clock = newAddon(nil, false, false, {})
    recovering:RegisterDataFeature("echo", function() end)
    clock:login()
    clock:member(7)
    local name = recovering:GetGroupDataChannelName()
    clock.channels[name:lower()] = nil
    clock:fire("PLAYER_ENTERING_WORLD")
    assert(not recovering:IsDataConnected())
    clock:advance(1)
    assert(#clock.joins == 2)
    clock:member(9)
    assert(recovering:SendData("echo", "reconnected") and clock.nativeSends[#clock.nativeSends].target == "9")
    clock.channels[name:lower()] = nil
    local calls = clock.sendCalls
    assert(not recovering:SendData("echo", "missing membership") and not recovering:IsDataConnected() and clock.sendCalls == calls)
    clock:advance(1)
    assert(#clock.joins == 3)
end

-- Group switching disconnects first and removes restored membership only from the old data channel.
do
    local switching, clock = newAddon(nil, false, false, {})
    local deliveries = 0
    switching:RegisterDataFeature("echo", function() deliveries = deliveries + 1 end)
    local oldName = switching:GetGroupDataChannelName()
    clock:member(4)
    clock:login()
    assert(switching:IsDataConnected() and #clock.joins == 0, "Login accepts confirmed restored membership")
    local oldSend = switching.dataState.send
    clock.channels.unrelated = { id = 50, name = "Unrelated" }
    switching:SetGroupSecret("different-native-group")
    assert(not switching:IsDataConnected() and #clock.leaves == 1 and clock.leaves[1] == oldName and clock.channels.unrelated)
    clock.channels[oldName:lower()] = { id = 4, name = oldName }
    local calls = clock.sendCalls
    assert(not oldSend("LockInToolsData", "1|echo|stale") and clock.sendCalls == calls,
        "A saved sender closure cannot use restored membership from the previous group")
    clock:advance(1)
    assert(#clock.joins == 1 and clock.joins[1].name == switching:GetGroupDataChannelName())
    clock:member(12)
    clock:incoming("1|echo|old route", "Oldfriend", { id = 4, name = oldName })
    assert(switching:IsDataConnected() and deliveries == 0)
    clock:incoming("1|echo|new route", "Newfriend", { id = 12 })
    assert(deliveries == 1, "Only the new group's confirmed route dispatches after switching")
    clock:fire("PLAYER_LOGOUT")
    calls = #clock.joins
    clock:advance(60)
    clock:fire("CHANNEL_UI_UPDATE")
    clock:incoming("1|echo|after logout", "Newfriend", { id = 12 })
    assert(#clock.joins == calls and not switching:IsDataConnected(), "Logout cancels recovery and closes feature delivery")
    assert(deliveries == 1)
end

-- Terminal notices and native API failures stop requests until a deliberate retry.
for _, reason in ipairs({ "WRONG_PASSWORD", "BANNED", "YOU_KICKED", "CHANNEL_PASSWORD_REQUEST" }) do
    local stopped, clock = newAddon(nil, false, false, {})
    clock:login()
    if reason == "CHANNEL_PASSWORD_REQUEST" then clock:fire(reason, stopped:GetGroupDataChannelName()) else clock:notice(reason) end
    clock:advance(40)
    assert(stopped.dataState.phase == "error" and #clock.joins == 1)
    stopped:JoinDataChannel(true)
    assert(#clock.joins == 2)
end
for _, failure in ipairs({ "prefixResult", "prefixThrows", "joinThrows" }) do
    local failed, clock = newAddon(nil, false, false, {})
    clock[failure] = failure == "prefixResult" and 2 or true
    clock:login()
    clock:advance(40)
    assert(not failed:IsDataConnected() and failed.dataState.phase == "error")
    assert(#clock.joins == (failure == "joinThrows" and 1 or 0))
end
do
    local duplicate, clock = newAddon(nil, false, false, {})
    clock.prefixResult = 1
    clock:login()
    clock:member(7)
    assert(duplicate:IsDataConnected(), "An already registered native prefix is reusable")
    local preserved = { schemaVersion = 99, group = { secret = "otter-4827" } }
    local readOnly, readClock = newAddon(preserved, true, false, {})
    readClock:login()
    readClock:advance(40)
    assert(#readClock.joins == 0 and #readClock.prefixCalls == 0 and not readOnly:IsDataConnected())
    assert(equal(preserved, { schemaVersion = 99, group = { secret = "otter-4827" } }))
end

print("Data tests passed.")
