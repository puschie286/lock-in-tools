-- Shared feature routing and the native channel lifecycle run against mocked WoW APIs.
local loadNotifications = dofile("tests/support/notifications.lua")
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
    native = native or {}
    local world = {
        now = 0, epoch = 2000000000, timers = {}, sent = {}, messages = {}, frames = {},
        x = 0.25, y = 0.75, map = 37, joins = {}, leaves = {}, channels = {}, nativeSends = {}, prefixCalls = {},
        sendResult = 0, sendCalls = 0,
    }
    world.sent = world.nativeSends
    local environment = setmetatable({
        bit = false, bit32 = false, C_ChatInfo = false,
        GetTime = function() return world.now end,
        GetServerTime = function() return world.epoch + math.floor(world.now) end,
        GetChannelName = function() return 0, nil end,
        GetNormalizedRealmName = function() return "TestRealm" end,
        UnitFullName = function(unit) assert(unit == "player"); return native.playerName or "Self", "Test Realm" end,
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
    environment.C_Timer.After = environment.C_Timer.NewTimer
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
        if world.leaveThrows then error("Native leave unavailable") end
        if not world.holdLeaves then world.channels[name:lower()] = nil end
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
            error("The native result, not a realm restriction precheck, decides acceptance")
        end,
    }
    environment.DEFAULT_CHAT_FRAME = {
        channelList = { "General" },
        AddChannel = function() error("Shared data must not appear in native chat") end,
        AddMessage = function(_, message) world.messages[#world.messages + 1] = message end,
    }
    local addon = {
        db = saved or { schemaVersion = 3, group = { secret = "otter-4827" } },
        initialized = true, ready = false, savedDataReadOnly = readOnly,
    }
    function addon:Print(message) world.messages[#world.messages + 1] = message end
    world.notificationErrors = loadNotifications(addon, environment)
    function addon:RefreshOptions() end
    function addon:RefreshPositionPins() end
    for _, file in ipairs({ "Crypto.lua", "Group.lua", "DataChannel.lua", "Data.lua", "DataStatus.lua" }) do
        loadModule(file, addon, environment)
    end
    addon:InitializeGroup()
    if native.configure then native.configure(environment, world) end
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
        self.sendResult, self.sendThrows = accepted == false and 11 or 0, accepted == "throw"
        if not addon.dataState.nativeStarted then self:login() end
        if addon.dataState.awaitingLeave then self:advance(1) end
        if addon:HasGroup() then self:member(7) end
    end
    function world:disconnect()
        addon:LeaveDataChannel()
    end
    -- Test convenience only: every receive uses the actual native event path.
    function addon:ReceiveData(sender, message)
        return self:OnDataEvent("CHAT_MSG_ADDON", self:GetDataPrefix(), message, "CHANNEL", sender)
    end
    function world:activeTimers()
        local count = 0
        for _, timer in ipairs(self.timers) do
            if not timer.cancelled then count = count + 1 end
        end
        return count
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
assert(not addon:SendData("echo", "without membership"))
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
    "1|Upper|bad identifier", "echo|missing version", "1|Q", "1|Q|", "1|R", "1|R|",
    "1|Q|echo|request|streaming feature", "1|R|echo|request|self-testrealm|streaming feature",
}) do
    assert(not addon:ReceiveData("Friend", message))
end
world:incoming("1|echo|unrelated", "Friend", { prefix = "OTHER" })
world:incoming("1|echo|unrelated", "Friend", { distribution = "WHISPER" })
assert(#incoming == receivedBefore)
assert(not addon:SendData("unregistered", "payload") and not addon:SendData("echo", false))
assert(not addon:SendData("echo", "native\000separator"))
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
world:disconnect()
world:connect()
assert(#connectionChanges == previousNotices + 2 and notified[#notified] == true,
    "A native reconnect notifies features of departure and connection")
world:disconnect()
assert(not addon:IsDataConnected() and notified[#notified] == false)
assert(not addon:SendData("echo", "disconnected") and not addon:ReceiveData("Friend", "1|echo|disconnected"))

-- Failed native sends never queue payloads for a later connection.
world:connect(false)
assert(not addon:SendData("echo", "failed payload"))
world:connect("throw")
assert(not addon:SendData("echo", "raised payload"))
local attempts = #world.sent
world:connect()
assert(#world.sent == attempts, "Reconnecting must not flush failed or disconnected messages")
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
assert(addon:IsGroupSwitching() and not addon:IsDataConnected()
    and addon:GetGroupFingerprint() == oldFingerprint, "Block traffic before the current callback returns")
world:advance(0)
assert(#lifecycle == 2 and not addon:IsDataConnected() and notified[#notified] == false)
assert(addon:GetGroupFingerprint() ~= oldFingerprint and addon:GetGroupDataChannelName() ~= channel)
assert(not addon:SendData("echo", "old connection"))
world:connect()
assert(addon:ReceiveData("Friend", "1|echo|handler retained"), "Features survive a group change and can use the new connection")
addon:LeaveGroup()
world:advance(0)
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

-- Missing joins retry indefinitely with capped delays and a single timer despite UI-event storms.
do
    local joining, clock = newAddon(nil, false, false, {})
    clock:login()
    for _ = 1, 20 do clock:fire("CHANNEL_UI_UPDATE") end
    assert(#clock.joins == 1 and clock:activeTimers() == 1)
    clock:advance(2)
    assert(#clock.joins == 2 and clock.joins[2].at == 2)
    clock:advance(4)
    assert(#clock.joins == 3 and clock.joins[3].at == 6)
    clock:advance(8)
    assert(#clock.joins == 4 and clock.joins[4].at == 14)
    clock:advance(8)
    assert(#clock.joins == 5 and clock.joins[5].at == 22 and not joining:IsDataConnected())
    for _ = 1, 20 do clock:fire("CHANNEL_UI_UPDATE"); clock:fire("PLAYER_ENTERING_WORLD") end
    clock:advance(29)
    assert(#clock.joins == 5 and clock:activeTimers() == 1,
        "UI events must neither accelerate nor postpone the capped retry")
    clock:advance(91)
    assert(#clock.joins == 9 and clock.joins[6].at == 52 and clock.joins[9].at == 142
        and clock:activeTimers() == 1, "A configured data connection retries without a finite attempt limit")
    clock:member(7)
    assert(joining:IsDataConnected() and clock:activeTimers() == 1,
        "Confirmed membership replaces the pending join timer with one membership watchdog")
    clock:advance(60)
    assert(#clock.joins == 9 and clock:activeTimers() == 1, "Healthy membership does not issue join requests")
end

-- Departure is confirmed before activation; failed leaves stay disconnected and retry.
do
    local switching, clock = newAddon(nil, false, false, {})
    switching:RegisterDataFeature("echo", function() end)
    switching:RegisterDataRequest("snapshot", function() return "own" end, function() end)
    clock:login()
    clock:member(7)
    local oldName, oldFingerprint = switching:GetGroupDataChannelName(), switching:GetGroupFingerprint()
    local _, oldID = switching:RequestData("snapshot", "old")
    clock.holdLeaves = true
    assert(switching:SetGroupSecret("switch-target"))
    assert(not switching:IsDataConnected() and not switching:SendData("echo", "between groups"))
    clock:advance(0)
    assert(switching:IsGroupSwitching() and switching:GetGroupFingerprint() == oldFingerprint
        and clock.channels[oldName:lower()] and #clock.joins == 1
        and next(switching.dataState.pendingRequests) == nil,
        "Keep old membership separate from the destination while clearing outstanding requests")
    assert(switching:SetGroupSecret("latest-switch-target"))
    clock.leaveThrows, clock.holdLeaves = true, false
    clock:advance(6)
    assert(switching:IsGroupSwitching() and #clock.joins == 1 and not switching:IsDataConnected(),
        "A failed departure cannot fall through to joining the destination")
    clock.leaveThrows = false
    clock:advance(5)
    assert(not switching:IsGroupSwitching() and not clock.channels[oldName:lower()] and #clock.joins == 2
        and clock.joins[2].name == switching:GetGroupDataChannelName()
        and switching:GetGroupSecret() == "latest-switch-target", "The latest destination is the only new join")
    clock:member(12)
    assert(switching:IsDataConnected() and switching:SendData("echo", "new group")
        and clock.nativeSends[#clock.nativeSends].target == "12")
    assert(not switching:ReceiveData("Friend", "1|R|snapshot|" .. oldID .. "|self-testrealm|stale"),
        "The new connection has no request target for an old reply")
end

-- Native leave notices recover automatically and coalesce duplicate events before retrying.
for _, event in ipairs({ "YOU_LEFT", "CHANNEL_LEFT" }) do
    local recovering, clock = newAddon(nil, false, false, {})
    clock:login()
    clock:member(7)
    local name = recovering:GetGroupDataChannelName()
    if event == "CHANNEL_LEFT" then clock:fire(event, 7, name) else clock:notice(event) end
    assert(not recovering:IsDataConnected() and recovering.dataState.phase == "joining")
    clock:fire("CHANNEL_UI_UPDATE")
    assert(not recovering:IsDataConnected(), "A leave notice invalidates a still-cached native membership record")
    clock.channels[name:lower()] = nil
    clock:advance(0.5)
    for _ = 1, 20 do
        if event == "CHANNEL_LEFT" then clock:fire(event, 7, name) else clock:notice(event) end
        clock:fire("CHANNEL_UI_UPDATE")
    end
    clock:advance(0.5)
    assert(#clock.joins == 2 and clock.joins[2].at == 1 and clock:activeTimers() == 1,
        "Repeated leave notices must not postpone the automatic reconnect or multiply requests")
    clock:member(11)
    assert(recovering:IsDataConnected())
end

-- Manual departure waits for native cleanup, then reconnects without false success.
do
    local recovering, clock = newAddon()
    clock:connect()
    clock.leaveThrows = true
    assert(recovering:LeaveDataChannel())
    clock:advance(4)
    assert(not recovering:IsDataConnected() and #clock.joins == 1)
    clock.leaveThrows = false
    clock:advance(1)
    assert(#clock.leaves == 2 and #clock.joins == 2)
    clock:member(11)
    assert(recovering:IsDataConnected())
end
-- The watchdog recovers silent membership loss even when UI events are busy and features are off.
do
    local recovering, clock = newAddon()
    clock:connect()
    clock:advance(14)
    for _ = 1, 20 do clock:fire("CHANNEL_UI_UPDATE"); clock:fire("PLAYER_ENTERING_WORLD") end
    clock.channels[recovering:GetGroupDataChannelName():lower()] = nil
    clock:advance(1)
    assert(not recovering:IsDataConnected() and #clock.joins == 2 and clock.joins[2].at == 15)
    clock:member(13)
    assert(recovering:IsDataConnected())
end
-- A send detects lost membership before calling the native transport, then uses the recovered channel number.
do
    local recovering, clock = newAddon()
    recovering:RegisterDataFeature("echo", function() end)
    clock:connect()
    clock.channels[recovering:GetGroupDataChannelName():lower()] = nil
    local calls = clock.sendCalls
    assert(not recovering:SendData("echo", "lost") and not recovering:IsDataConnected() and clock.sendCalls == calls)
    clock:advance(1)
    clock:member(9)
    assert(recovering:SendData("echo", "reconnected") and clock.sent[#clock.sent].target == "9")
end
-- Restored membership and late old-channel joins preserve the active group and unrelated channels.
do
    local switching, clock = newAddon()
    local oldName = switching:GetGroupDataChannelName()
    clock:member(4)
    clock:login()
    assert(switching:IsDataConnected() and #clock.joins == 0)
    clock.channels.unrelated = { id = 50, name = "Unrelated" }
    assert(switching:SetGroupSecret("different-native-group"))
    clock:advance(0)
    clock:member(12)
    clock:member(4, oldName)
    clock:notice("YOU_JOINED", oldName)
    assert(switching:IsDataConnected() and not clock.channels[oldName:lower()] and clock.channels.unrelated)
    clock:fire("PLAYER_LOGOUT")
    local joins = #clock.joins
    clock:notice("YOU_LEFT")
    clock:advance(60)
    assert(not switching:IsDataConnected() and #clock.joins == joins and clock:activeTimers() == 0)
end
-- Native rejection notices back off, retain automatic recovery and accept a late successful join.
for _, reason in ipairs({ "WRONG_PASSWORD", "CHANNEL_PASSWORD_REQUEST", "THROTTLED" }) do
    local recovering, clock = newAddon(nil, false, false, {})
    clock:login()
    local function fail()
        if reason == "CHANNEL_PASSWORD_REQUEST" then clock:fire(reason, recovering:GetGroupDataChannelName())
        else clock:notice(reason) end
    end
    fail()
    assert(recovering.dataState.phase == "error" and not recovering:IsDataConnected())
    clock:advance(10)
    for _ = 1, 20 do fail(); clock:fire("CHANNEL_UI_UPDATE"); clock:fire("PLAYER_ENTERING_WORLD") end
    clock:advance(19)
    assert(#clock.joins == 1 and clock:activeTimers() == 1, "Rejections must not create immediate request storms")
    clock:advance(1)
    assert(#clock.joins == 2 and clock.joins[2].at == 30,
        "Repeated notices must not postpone the next retry")
    fail()
    clock:advance(30)
    assert(#clock.joins == 3 and clock.joins[3].at == 60)
    fail()
    clock:member(7)
    clock:notice("YOU_JOINED")
    assert(recovering:IsDataConnected(), "A confirmed late membership recovers from a rejected join")
    clock:advance(30)
    assert(#clock.joins == 3 and clock:activeTimers() == 1)
end
-- Prefix registration and thrown join requests retry, then recover when calls succeed.
for _, failure in ipairs({ "prefixResult", "prefixThrows", "joinThrows" }) do
    local failed, clock = newAddon(nil, false, false, {})
    clock[failure] = failure == "prefixResult" and 2 or true
    clock:login()
    clock:advance(29)
    assert(not failed:IsDataConnected() and failed.dataState.phase == "error")
    assert(#clock.joins == (failure == "joinThrows" and 1 or 0))
    clock:advance(31)
    assert(#clock.joins == (failure == "joinThrows" and 3 or 0) and clock:activeTimers() == 1)
    assert(#clock.prefixCalls == (failure == "joinThrows" and 1 or 3))
    clock[failure] = nil
    clock:advance(30)
    assert(#clock.joins == (failure == "joinThrows" and 4 or 1))
    clock:member(7)
    assert(failed:IsDataConnected())
end

-- Native capabilities are captured at initialization and cannot appear midway through a session.
do
    local restore
    local missing, clock = newAddon(nil, false, false, { configure = function(environment)
        local join = environment.JoinTemporaryChannel
        environment.JoinTemporaryChannel = false
        restore = function() environment.JoinTemporaryChannel = join end
    end })
    clock:login()
    restore()
    missing:JoinDataChannel(true)
    clock:advance(90)
    assert(not missing:IsDataConnected() and #clock.joins == 0 and #clock.prefixCalls == 0)
end
-- Removing the configured group cancels both retry and healthy membership timers.
for _, connected in ipairs({ false, true }) do
    local leaving, clock = newAddon(nil, false, false, {})
    clock:login()
    if connected then clock:member(7) end
    leaving:LeaveGroup()
    local requests = #clock.joins
    clock:advance(120)
    clock:fire("CHANNEL_UI_UPDATE")
    clock:fire("PLAYER_ENTERING_WORLD")
    assert(not leaving:IsDataConnected() and #clock.joins == requests and clock:activeTimers() == 0,
        "A removed group never reconnects")
end
do
    local duplicate, clock = newAddon(nil, false, false, {})
    clock.prefixResult = 1
    clock:login()
    clock:member(7)
    assert(duplicate:IsDataConnected(), "An already registered native prefix is reusable")

end

-- Real channel fan-out: every client sees the request and response broadcasts, including its own echoes.
local function newRequestBus(withPositions, beforeConnect)
    local bus = { clients = {}, queue = {}, delivered = 0 }
    function bus:add(name, now)
        local profile = withPositions and {
            schemaVersion = 3, group = { secret = "otter-4827" }, position = { sharing = true },
        } or nil
        local current, clock = newAddon(profile, false, withPositions, { playerName = name })
        local client = { addon = current, world = clock, name = name, requests = {}, responses = {} }
        bus.clients[#bus.clients + 1] = client
        assert(current:RegisterDataRequest("snapshot", function(sender, payload)
            client.requests[#client.requests + 1] = { sender = sender, payload = payload }
            return name .. "|" .. payload
        end, function(sender, payload)
            client.responses[#client.responses + 1] = { sender = sender, payload = payload }
        end))
        local nativeSend = clock.environment.C_ChatInfo.SendAddonMessage
        clock.environment.C_ChatInfo.SendAddonMessage = function(prefix, message, distribution, target)
            local result = nativeSend(prefix, message, distribution, target)
            if result == 0 then
                bus.queue[#bus.queue + 1] = { sender = name .. "-TestRealm", message = message,
                    channel = current:GetGroupDataChannelName() }
            end
            return result
        end
        if beforeConnect then beforeConnect(client) end
        clock:login()
        clock:member(7)
        return client
    end
    function bus:pump()
        while #self.queue > 0 do
            local packet = table.remove(self.queue, 1)
            self.delivered = self.delivered + 1
            assert(self.delivered < 100, "A snapshot must not trigger response/request loops")
            for _, client in ipairs(self.clients) do
                local channel = client.world.channels[packet.channel:lower()]
                if channel then
                    client.world:incoming(packet.message, packet.sender, { id = channel.id, name = packet.channel })
                end
            end
        end
    end
    for _, name in ipairs({ "Alice", "Bob", "Carol" }) do bus:add(name) end
    return bus
end

do
    local bus = newRequestBus()
    local alice, bob, carol = unpack(bus.clients)
    local accepted, aliceID = alice.addon:RequestData("snapshot", "a|b||c")
    local bobAccepted, bobID = bob.addon:RequestData("snapshot", "bob")
    assert(accepted and bobAccepted and aliceID == bobID,
        "Different clients may independently generate the same request identifier")
    bus:pump()
    assert(#alice.requests == 1 and #bob.requests == 1 and #carol.requests == 2,
        "Each peer answers each request once and ignores its own echo")
    assert(#alice.responses == 2 and #bob.responses == 2 and #carol.responses == 0,
        "Only the original requester receives answers, even when another pending request has the same ID")
    assert(alice.responses[1].payload == "Bob|a|b||c" and alice.responses[2].payload == "Carol|a|b||c",
        "Snapshot framing preserves the whole payload, including pipes")
    local sent = #alice.world.nativeSends + #bob.world.nativeSends + #carol.world.nativeSends
    assert(sent == 6, "Two requests produce exactly four peer responses without extra announcements")
    local request = alice.world.nativeSends[1].message
    bob.world:incoming(request, "ALICE-Test Realm", { id = 7 })
    local response = bob.world.nativeSends[2].message
    alice.world:incoming(response, "BOB-Test Realm", { id = 7 })
    bus:pump()
    assert(#bob.requests == 1 and #alice.responses == 2,
        "Requester and responder duplicate detection normalizes names and realm whitespace")
    for _, client in ipairs(bus.clients) do client.world:advance(35) end
    assert(#alice.world.nativeSends + #bob.world.nativeSends + #carol.world.nativeSends == sent,
        "Snapshot requests and replies do not schedule periodic rebroadcasts")
end

local function requestFixture(onRequest, onResponse, native)
    local current, clock = newAddon(nil, false, false, native or { playerName = "Self" })
    clock:login()
    clock:member(7)
    assert(current:RegisterDataRequest("snapshot", onRequest or function() return "own" end, onResponse or function() end))
    return current, clock
end

-- Request and response handlers receive the complete body after their own headers.
do
    local requests, responses = {}, {}
    local current, clock = requestFixture(function(_, payload)
        requests[#requests + 1] = payload
        return payload
    end, function(_, payload) responses[#responses + 1] = payload end)
    for index, payload in ipairs({ "", "|a||b|1|Q|snapshot|nested|" }) do
        local accepted, id = current:RequestData("snapshot", payload)
        assert(accepted and clock.sent[#clock.sent].message == "1|Q|snapshot|" .. id .. "|" .. payload)
        local peerID = "opaque-" .. index
        assert(current:ReceiveData("Friend", "1|Q|snapshot|" .. peerID .. "|" .. payload))
        assert(requests[index] == payload)
        assert(clock.sent[#clock.sent].message == "1|R|snapshot|" .. peerID .. "|friend-testrealm|" .. payload)
        assert(current:ReceiveData("Friend", "1|R|snapshot|" .. id .. "|self-testrealm|" .. payload))
        assert(responses[index] == payload, "An empty or nested response body must survive request correlation")
    end
end

do
    local requests, responses = 0, {}
    local current, clock = requestFixture(function(_, payload) requests = requests + 1; return payload end,
        function(sender, payload) responses[#responses + 1] = { sender = sender, payload = payload } end,
        { configure = function(environment)
            environment.NameUtil = { GetUnmodifiedUnitFullName = function() return "Native-Test Realm" end }
        end })
    assert(not current:RegisterDataRequest("snapshot", function() error("Duplicate replacement") end, function() end))
    for _, name in ipairs({ "", "Upper", "bad|name", string.rep("a", 33) }) do
        assert(not current:RegisterDataRequest(name, function() end, function() end))
    end
    assert(not current:RegisterDataRequest("missing", nil, function() end))
    assert(not current:RegisterDataRequest("missing", function() end, false))
    assert(not current:RequestData("missing", "") and not current:RequestData("snapshot", nil))
    assert(current:IsDataSelf("SELF-TestRealm") and current:IsDataSelf("Native-TestRealm"))
    local accepted, id = current:RequestData("snapshot", "")
    assert(accepted)
    local prefix = "1|R|snapshot|" .. id .. "|"
    for _, frame in ipairs({
        prefix .. "other-testrealm|wrong target", "1|R|other|" .. id .. "|self-testrealm|wrong feature",
        "1|R|snapshot|unrelated-session-1|self-testrealm|old session", "1|R|snapshot|not-issued|self-testrealm|unsolicited",
    }) do
        assert(not current:ReceiveData("Friend-TestRealm", frame))
    end
    assert(not current:ReceiveData("Self-Test Realm", prefix .. "self-testrealm|self"))
    assert(not current:ReceiveData("Native-TestRealm", prefix .. "self-testrealm|native self"))
    assert(not current:ReceiveData("Self-TestRealm", "1|Q|snapshot|self-request|echo"))
    assert(not current:ReceiveData("Native-Test Realm", "1|Q|snapshot|native-request|echo"))
    assert(requests == 0 and #responses == 0)
    assert(current:ReceiveData("Friend", prefix .. "native-testrealm|a|b||c"))
    assert(not current:ReceiveData("FRIEND-Test Realm", prefix .. "native-testrealm|duplicate"))
    assert(#responses == 1 and responses[1].sender == "Friend" and responses[1].payload == "a|b||c")
    clock:advance(10)
    assert(not current:ReceiveData("LateFriend", prefix .. "self-testrealm|expired"),
        "The response window is closed at ten seconds even without another request")
    assert(#responses == 1)
end

-- Both kinds of frames obey the same NUL and byte limits as streaming data.
do
    local response, requests, responses = "", 0, 0
    local current, clock = requestFixture(function() requests = requests + 1; return response end,
        function() responses = responses + 1 end)
    local accepted, id = current:RequestData("snapshot", "")
    assert(accepted and #id <= 32)
    local requestHeader = "1|Q|snapshot|" .. id .. "|"
    local maximumPayload = string.rep("x", 255 - #requestHeader)
    assert(current:RequestData("snapshot", maximumPayload) and #clock.nativeSends[#clock.nativeSends].message == 255)
    local sent = #clock.nativeSends
    assert(not current:RequestData("snapshot", maximumPayload .. "x") and not current:RequestData("snapshot", "bad\000data"))
    assert(#clock.nativeSends == sent)
    for _, frame in ipairs({
        "1|Q|snapshot||payload", "1|Q|snapshot|bad.id|payload", "1|Q|snapshot|" .. string.rep("x", 33) .. "|payload",
        "1|Q|Upper|id|payload", "1|Q|" .. string.rep("a", 33) .. "|id|payload", "1|Q|missing|id|payload",
        "1|Q|snapshot|id",
        "1|R|snapshot||self-testrealm|payload", "1|R|snapshot|bad.id|self-testrealm|payload",
        "1|R|snapshot|id||payload", "1|R|snapshot|id|self-testrealm", "2|Q|snapshot|id|payload",
    }) do
        assert(not current:ReceiveData("Friend", frame), frame)
    end
    assert(requests == 0 and responses == 0 and #clock.nativeSends == sent)
    local header = "1|R|snapshot|maximum|friend-testrealm|"
    response = string.rep("x", 255 - #header)
    assert(current:ReceiveData("Friend", "1|Q|snapshot|maximum|"))
    assert(#clock.nativeSends[#clock.nativeSends].message == 255)
    sent = #clock.nativeSends
    response = response .. "xx"
    assert(not current:ReceiveData("Friend", "1|Q|snapshot|oversized|"))
    response = "bad\000data"
    assert(not current:ReceiveData("Friend", "1|Q|snapshot|nul|"))
    assert(#clock.nativeSends == sent, "Invalid replies are rejected before the native send")
    local marker = {}
    clock.environment.issecretvalue = function(value) return rawequal(value, marker) end
    assert(not current:RegisterDataRequest(marker, function() end, function() end))
    assert(not current:RequestData("snapshot", marker))
    clock.environment.UnitFullName = function() return marker, marker end
    clock.environment.NameUtil = { GetUnmodifiedUnitFullName = function() return marker end }
    assert(not current:IsDataSelf("Self") and not current:RequestData("snapshot", ""),
        "Secret names and payloads never enter comparisons, concatenation or transport")
end

-- Native rejection/exception does not leave a live request or retry queue behind.
for _, failure in ipairs({ "reject", "throw" }) do
    local responses = 0
    local current, clock = requestFixture(nil, function() responses = responses + 1 end)
    clock.sendResult, clock.sendThrows = failure == "reject" and 11 or 0, failure == "throw"
    assert(not current:RequestData("snapshot", "failed"))
    assert(next(current.dataState.pendingRequests) == nil)
    local attempted = clock.sendCalls
    clock.sendResult, clock.sendThrows = 0, false
    clock:advance(30)
    assert(clock.sendCalls == attempted and responses == 0, "Failed snapshots are retried only by the requesting feature")
    if failure == "reject" then
        local id = clock.nativeSends[1].message:match("^1|Q|snapshot|([^|]+)|")
        assert(not current:ReceiveData("Friend", "1|R|snapshot|" .. id .. "|self-testrealm|late failed reply"))
    end
    assert(current:RequestData("snapshot", "current"))
end

-- A broken or declining snapshot handler cannot interrupt other requests or streaming features.
do
    local current, clock = requestFixture(function() error("Request callback failed") end,
        function() error("Response callback failed") end)
    assert(current:RegisterDataRequest("decline", function() return nil end, function() return false end))
    assert(current:RegisterDataRequest("other", function() return "working" end, function() end))
    assert(current:RegisterDataFeature("echo", function() end))
    assert(not current:ReceiveData("Friend", "1|Q|snapshot|broken|"))
    assert(not current:ReceiveData("Friend", "1|Q|decline|declined|"))
    local accepted, id = current:RequestData("snapshot", "")
    assert(accepted and not current:ReceiveData("Friend", "1|R|snapshot|" .. id .. "|self-testrealm|broken"))
    accepted, id = current:RequestData("decline", "")
    assert(accepted and not current:ReceiveData("Friend", "1|R|decline|" .. id .. "|self-testrealm|declined"))
    assert(current:ReceiveData("Friend", "1|Q|other|healthy|"))
    assert(current:ReceiveData("Friend", "1|echo|still working"))
    assert(clock.nativeSends[#clock.nativeSends].message == "1|R|other|healthy|friend-testrealm|working")
end

-- Native reconnects, group changes and logout invalidate request correlation.
for _, action in ipairs({ "disconnect", "switch", "logout" }) do
    local calls, responses = 0, 0
    local current, clock = requestFixture(function() calls = calls + 1; return "own" end,
        function() responses = responses + 1 end)
    local accepted, oldID = current:RequestData("snapshot", "old")
    assert(accepted and current:ReceiveData("Friend", "1|Q|snapshot|peer-request|"))
    if action == "disconnect" then clock:disconnect()
    elseif action == "switch" then current:SetGroupSecret("snapshot-other-group"); clock:advance(0)
    else clock:fire("PLAYER_LOGOUT") end
    assert(next(current.dataState.pendingRequests) == nil and next(current.dataState.repliedRequests) == nil, action)
    if action ~= "logout" then
        clock:connect()
        assert(not current:ReceiveData("Friend", "1|R|snapshot|" .. oldID .. "|self-testrealm|stale"), action)
        local fresh, id = current:RequestData("snapshot", "fresh")
        assert(fresh and id ~= oldID and current:ReceiveData("Friend", "1|R|snapshot|" .. id .. "|self-testrealm|current"), action)
        assert(current:ReceiveData("Friend", "1|Q|snapshot|peer-request|"), "Reply caches belong to one native connection")
        assert(calls == 2 and responses == 1)
    else
        assert(not current:ReceiveData("Friend", "1|Q|snapshot|after-logout|"))
        assert(not current:RequestData("snapshot", "after logout"))
    end
end

-- Connection callbacks can request a new snapshot after native cleanup.
do
    local responses = 0
    local current, clock = requestFixture(nil, function() responses = responses + 1 end)
    local _, oldID = current:RequestData("snapshot", "old")
    local freshID
    current:RegisterDataFeature("connection_snapshot", function() end, function(connected)
        if connected then local accepted; accepted, freshID = current:RequestData("snapshot", "new"); assert(accepted) end
    end)
    clock:disconnect()
    clock:connect()
    assert(current.dataState.pendingRequests[freshID] and not current.dataState.pendingRequests[oldID])
    assert(current:ReceiveData("Friend", "1|R|snapshot|" .. freshID .. "|self-testrealm|fresh") and responses == 1)
end

local function statusFixture(values, accepted, native)
    local current, clock = newAddon(nil, false, false, native)
    local samples, connections, contacts = {}, {}, {}
    assert(current:RegisterDataStatusProvider("player", function() return values end,
        function(sender, fields, stamp, sequence, metadata)
            samples[#samples + 1] = { sender = sender, fields = fields, stamp = stamp, sequence = sequence, metadata = metadata }
        end, function(connected) connections[#connections + 1] = connected end,
        function(sender, stamp, metadata)
            contacts[#contacts + 1] = { sender = sender, stamp = stamp, metadata = metadata }
        end))
    clock:connect(accepted)
    return current, clock, samples, connections, contacts
end

local function full(session, stamp, revision, body)
    return "5|F|" .. session .. "|" .. stamp .. "|" .. revision .. "|" .. body
end

local function receive(current, sender, payload)
    return current:ReceiveData(sender, "1|status|" .. payload)
end

local function positionStatusFixture(values, sharing)
    local profile = { schemaVersion = 3, group = { secret = "otter-4827" }, position = { sharing = sharing ~= false } }
    local current, clock = newAddon(profile, false, true)
    local samples = {}
    assert(current:RegisterDataStatusProvider("player", function() return values end,
        function(sender, fields) samples[#samples + 1] = { sender = sender, fields = fields } end))
    clock:connect()
    return current, clock, samples
end

-- Class uses a compact status enum; future numeric codes preserve compatible
-- snapshot decoding without inventing a supported player class.
do
    for code, class in pairs({ [0] = "unknown", [1] = "WARRIOR", [7] = "MAGE" }) do
        local current, clock, samples = statusFixture({ class = class })
        assert(clock.sent[1].message:match("|11=" .. code .. "$"), "Class is encoded as its permanent numeric ID")
        assert(receive(current, "Friend", full("peer", 2000000000, 1, "11=" .. code)))
        assert(samples[1].fields.class == class)
    end
    local current, _, samples = statusFixture({ class = "UNSUPPORTED" })
    assert(receive(current, "Friend", full("peer", 2000000000, 1, "11=65535")))
    assert(samples[1].fields.class == "unknown", "Future class IDs decode to unknown")
end

-- Status carries a fresh optional position without making movement dirty the
-- player-status revision or adding another idle position broadcast.
do
    local values = { level = 24 }
    local current, clock = positionStatusFixture(values)
    assert(#clock.sent == 1 and clock.sent[1].message:match("^1|Q|status|")
        and clock.sent[1].message:find("1=24|9=P,37,25000,75000", 1, true))
    clock:advance(2)
    assert(#clock.sent == 1, "The public initial snapshot also supplies the first position")
    clock.x = 0.4
    clock:advance(2)
    assert(#clock.sent == 2 and clock.sent[2].message == "1|position|2|P|2000000004|37|40000|75000")
    clock:advance(1)
    assert(#clock.sent == 2, "Movement alone must not send a five-second full status report")
    values.level = 25
    clock:advance(4)
    clock.x = 0.65
    clock:advance(1)
    assert(#clock.sent == 3 and clock.sent[3].message:match("^1|status|5|F|[^|]+|2000000010|2|")
        and clock.sent[3].message:find("1=25|9=P,37,65000,75000", 1, true),
        "A due status report samples current coordinates and suppresses duplicate movement at that tick")
    clock:advance(30)
    assert(#clock.sent == 4 and clock.sent[4].message:match("^1|status|5|F|[^|]+|2000000040|2|")
        and clock.sent[4].message:find("9=P,37,65000,75000", 1, true))
end

-- Status captures server time once for both the envelope and the coordinate
-- sample. Integer wire values decode to normalized Lua coordinates.
do
    local values = { level = 24 }
    local current, clock = positionStatusFixture(values)
    clock:advance(4)
    clock.x, clock.y, values.level = 0.123456, 0.999996, 25
    local reads = 0
    clock.environment.GetServerTime = function()
        reads = reads + 1
        return 2000000004 + reads
    end
    clock:advance(1)
    local packet = clock.sent[#clock.sent].message
    assert(reads == 1 and packet:match("^1|status|5|F|[^|]+|2000000005|2|")
        and packet:find("9=P,37,12346,100000", 1, true),
        "A second clock read must not give the attachment a different timestamp")
    assert(receive(current, "Friend", full("peer", 2000000005, 1, "1=25|9=P,37,12346,100000")))
    local peer = assert(current:GetSharedPositions()["friend-testrealm"])
    assert(peer.x == 0.12346 and peer.y == 1 and peer.stamp == 2000000005
        and peer.positionStamp == 2000000005)
end

-- The status clock cannot move backwards. Omitting a sample rather than
-- assigning it a future timestamp also leaves movement broadcasting enabled.
do
    local values = { level = 24 }
    local current, clock = positionStatusFixture(values)
    clock:advance(4)
    clock.epoch, clock.x, values.level = clock.epoch - 10, 0.6, 25
    clock:advance(1)
    assert(#clock.sent == 2 and clock.sent[2].message:match("^1|status|5|F|[^|]+|2000000000|2|1=25$")
        and not clock.sent[2].message:find("|9=", 1, true),
        "A sample from before the clamped envelope time must be omitted")
    clock:advance(1)
    assert(#clock.sent == 3 and clock.sent[3].message == "1|position|2|P|1999999996|37|60000|75000",
        "An omitted attachment must not suppress the changed movement sample")
end

-- All idle peers remain online beyond the position timeout using only status
-- refreshes. A stationary late join discovers positions in its initial exchange.
do
    local function register(client)
        assert(client.addon:RegisterDataStatusProvider("player", function() return { level = 24 } end,
            function() end))
    end
    local bus = newRequestBus(true, register)
    bus:pump()
    for _ = 1, 35 do
        for _, client in ipairs(bus.clients) do client.world:advance(2) end
        bus:pump()
        for _, client in ipairs(bus.clients) do
            for _, other in ipairs(bus.clients) do
                if client ~= other then
                    local peer = assert(client.addon:GetSharedPositions()[other.name:lower() .. "-testrealm"])
                    assert(peer.online and peer.x == 0.25 and peer.y == 0.75)
                end
            end
        end
    end
    bus:add("Dave", 70)
    bus:pump()
    for _, client in ipairs(bus.clients) do
        for _, other in ipairs(bus.clients) do
            if client ~= other then assert(client.addon:GetSharedPositions()[other.name:lower() .. "-testrealm"].online) end
        end
        for _, packet in ipairs(client.world.sent) do
            assert(not packet.message:match("^1|position|"), "Stationary clients use no separate position heartbeat")
            assert(#packet.message <= 255)
        end
    end
end

-- Attachments inherit the envelope timestamp. They can change at the same core
-- revision, but delayed status cannot overwrite a newer standalone movement.
do
    local current, clock, samples = positionStatusFixture({ level = 24 })
    assert(receive(current, "Friend", full("peer", 2000000000, 1,
        "1=25|9=P,37,30000,70000")))
    assert(equal(samples[1].fields, { level = "25" }))
    assert(current:ReceiveData("Friend", "1|position|2|P|2000000010|37|80000|70000"))
    assert(receive(current, "Friend", full("peer", 2000000005, 1,
        "1=25|9=P,37,40000,70000")))
    assert(current:GetSharedPositions()["friend-testrealm"].x == 0.8,
        "A delayed envelope must not replace a later movement sample")
    assert(receive(current, "Friend", full("peer", 2000000012, 1,
        "1=25|9=P,37,60000,70000")))
    assert(current:GetSharedPositions()["friend-testrealm"].x == 0.6 and #samples == 3)
    assert(not receive(current, "Friend", full("peer", 2000000013, 1,
        "1=99|9=P,37,90000,70000")))
    assert(current:GetSharedPositions()["friend-testrealm"].x == 0.6,
        "Rejected status frames must not partially apply their position")
    assert(receive(current, "Friend", full("peer", 2000000014, 1, "1=25")))
    assert(current:GetSharedPositions()["friend-testrealm"].x == 0.6,
        "An omitted attachment is not an unavailable-position report")
end

-- A targeted reply supplies the latest position to its requester but cannot
-- suppress the movement broadcast still needed by everyone else.
do
    local current, clock = positionStatusFixture({ level = 24 })
    clock:advance(1)
    clock.x = 0.8
    assert(current:ReceiveData("Friend", "1|Q|status|initial|" .. full("peer", 2000000001, 1, "1=25")))
    assert(#clock.sent == 2 and clock.sent[2].message:match("^1|R|status|initial|friend%-testrealm|")
        and clock.sent[2].message:find("9=P,37,80000,75000", 1, true))
    clock:advance(1)
    assert(#clock.sent == 3 and clock.sent[3].message == "1|position|2|P|2000000002|37|80000|75000")
end

-- Attachments respect the full native envelope budget. A long targeted reply
-- preserves core status and omits position; the same core still fits publicly.
do
    local values = { xpMax = "x", class = "MAGE" }
    local current, clock = positionStatusFixture(values)
    local request = full("peer", 2000000000, 1, "1=25")
    local function requestSnapshot(id)
        return current:ReceiveData("Friend-TestRealm", "1|Q|status|" .. string.rep(id, 32) .. "|" .. request)
    end
    assert(requestSnapshot("a"))
    local combined = clock.sent[#clock.sent].message
    assert(combined:find("|9=P,", 1, true) and combined:find("|11=7", 1, true))
    values.xpMax = string.rep("x", 256 - #combined)
    assert(requestSnapshot("b"))
    local reply = clock.sent[#clock.sent].message
    assert(#reply == 255 and reply:find("|9=P,", 1, true), "A combined reply fitting exactly 255 bytes is accepted")
    values.xpMax = values.xpMax .. "x"
    assert(requestSnapshot("c"))
    reply = clock.sent[#clock.sent].message
    assert(#reply < 255 and not reply:find("|9=", 1, true) and reply:find("3=" .. values.xpMax, 1, true)
        and reply:find("|11=7", 1, true),
        "An attachment must not prevent a valid core response")
    clock:advance(5)
    local public = clock.sent[#clock.sent].message
    assert(public:match("^1|status|") and public:find("|9=P,", 1, true) and #public <= 255,
        "The public envelope has enough room for the same core and position")
end

-- Rejected sends never count as successful broadcasts. Retry the latest whole
-- sample, including when it has returned to the previously broadcast values.
for _, latest in ipairs({ 3, 1 }) do
    local values = { xp = 1 }
    local _, clock = statusFixture(values)
    values.xp, clock.sendResult = 2, 11
    clock:advance(5)
    assert(#clock.sent == 2 and clock.sent[2].message:match("|5|F|[^|]+|2000000005|2|2=2$"))
    values.xp, clock.sendResult = latest, 0
    clock:advance(5)
    local expected = "|5|F|[^|]+|2000000010|3|2=" .. latest .. "$"
    assert(#clock.sent == 3 and clock.sent[3].message:match(expected),
        "Retries publish current values without any dependency on earlier packets")
    clock:advance(25)
    assert(#clock.sent == 3, "A successfully retried sample clears unpublished state")
    clock:advance(5)
    assert(#clock.sent == 4 and clock.sent[4].message:match("^1|status|5|F|[^|]+|2000000040|3|2=" .. latest .. "$"))
end

-- These IDs are permanent protocol assignments. Collectors and consumers retain
-- readable names and typed values at the API boundary.
do
    local values = {
        level = 24, xp = 420, xpMax = 1000, xpState = "known",
        inParty = true, canInvite = false, partyFull = false, sharing = true,
    }
    local current, clock, samples = statusFixture(values)
    local body = "1=24|2=420|3=1000|4=1|8=1|10=1"
    assert(clock.sent[1].message:match("|5|F|[^|]+|2000000000|1|(.+)$") == body)
    assert(receive(current, "Friend", full("peer", 2000000000, 1, body)))
    for name, value in pairs(values) do
        local expected = type(value) == "number" and tostring(value) or value
        assert(samples[1].fields[name] == expected, name)
    end
    assert(samples[1].fields[1] == nil and samples[1].fields["1"] == nil,
        "Numeric field IDs are private to the codec")

    -- Unknown Lua names never acquire IDs automatically or fall back to named
    -- wire fields. An invalid provider cannot publish its partially valid data.
    assert(current:RegisterDataStatusProvider("unregistered", function()
        return { future = "new", sharing = "partial" }
    end, function() end))
    clock:advance(5)
    assert(#clock.sent == 1)
end

-- Party flags keep their readable booleans at the API boundary. In particular,
-- a zero mask means all false; omitting the mask means all three are unknown.
for _, mask in ipairs({ 0, 3, 7 }) do
    local values = {
        inParty = mask % 2 == 1,
        canInvite = math.floor(mask / 2) % 2 == 1,
        partyFull = math.floor(mask / 4) % 2 == 1,
    }
    local current, clock, samples = statusFixture(values)
    assert(clock.sent[1].message:match("|5|F|[^|]+|2000000000|1|(.+)$") == "10=" .. mask)
    assert(receive(current, "Friend", full("peer", 2000000000, 1, "10=" .. mask)))
    assert(equal(samples[1].fields, values), "Party mask round trip: " .. mask)
    assert(receive(current, "Friend", full("peer", 2000000001, 2, "")))
    assert(next(samples[2].fields) == nil, "An omitted mask must not invent false flags")
end

-- The registry performs field-specific value conversion, preserving ordinary
-- strings in other fields and keeping absent values distinct from false/zero.
do
    local values = { xpState = "unavailable", sharing = false, xpMax = "known" }
    local current, clock, samples = statusFixture(values)
    assert(clock.sent[1].message:match("|5|F|[^|]+|2000000000|1|(.+)$") == "3=known|4=0|8=0")
    local states = { "unavailable", "known", "max" }
    for code = 0, 2 do
        assert(receive(current, "Friend", full("peer", 2000000000 + code, code + 1,
            "3=known|4=" .. code .. "|8=" .. code % 2)))
        assert(equal(samples[#samples].fields,
            { xpMax = "known", xpState = states[code + 1], sharing = code % 2 == 1 }))
        values.xpState, values.sharing = states[code + 1], code % 2 == 1
        clock:advance(5)
        assert(clock.sent[#clock.sent].message:find("4=" .. code .. "|8=" .. code % 2, 1, true))
    end
    assert(receive(current, "Friend", full("peer", 2000000003, 4, "")))
    assert(next(samples[#samples].fields) == nil)
end

-- Future XP states fail closed to unavailable; future party bits have no
-- effect on today's flags. Raw values still protect same-revision consistency.
do
    local current, _, samples = statusFixture({ level = 24 })
    assert(receive(current, "Friend", full("peer", 2000000000, 1, "4=3|10=9")))
    assert(equal(samples[1].fields,
        { xpState = "unavailable", inParty = true, canInvite = false, partyFull = false }))
    assert(not receive(current, "Friend", full("peer", 2000000001, 1, "4=4|10=9")))
    assert(not receive(current, "Friend", full("peer", 2000000001, 1, "4=3|10=1")))
    assert(receive(current, "Friend", full("peer", 2000000001, 2, "4=65535|10=4294967295")))
    assert(equal(samples[2].fields,
        { xpState = "unavailable", inParty = true, canInvite = true, partyFull = true }))
    assert(receive(current, "Friend", full("peer", 2000000002, 3, "10=8|5=true|6=false|7=true")))
    assert(equal(samples[3].fields, { inParty = false, canInvite = false, partyFull = false }))
    assert(receive(current, "Friend", full("peer", 2000000003, 4, "5=true|6=false|7=true")))
    assert(next(samples[4].fields) == nil, "Retired party field IDs must not expose legacy values")
end

-- A provider cannot manufacture known flags from incomplete or untyped input.
-- Reject the whole provider sample while continuing to collect healthy peers.
do
    local current, clock = newAddon()
    local values
    assert(current:RegisterDataStatusProvider("invalid", function() return values end, function() end))
    assert(current:RegisterDataStatusProvider("healthy", function() return { level = 24 } end, function() end))
    clock:connect()
    assert(clock.sent[1].message:match("|5|F|[^|]+|2000000000|1|(.+)$") == "1=24")
    for _, invalid in ipairs({
        { xp = "discard", inParty = true },
        { xp = "discard", inParty = false, canInvite = false, partyFull = 0 },
        { xp = "discard", sharing = "false" },
        { xp = "discard", xpState = "future" }, { xp = "discard", partyFlags = 3 },
    }) do
        values = invalid
        clock:advance(5)
        assert(not clock.sent[#clock.sent].message:find("discard", 1, true),
            "An invalid typed field must not partially publish the provider")
        assert(clock.sent[#clock.sent].message:match("|1|1=24$"), "Healthy providers continue publishing")
    end
    values = { xp = "recovered", inParty = false, canInvite = true, partyFull = false, sharing = false, xpState = "known" }
    clock:advance(5)
    assert(clock.sent[#clock.sent].message:match("|2|1=24|2=recovered|4=1|8=0|10=2$"))
end

-- One provider owns the whole mask. Two complete groups collide atomically;
-- flags from partial providers must never be combined into a fabricated group.
do
    local current, clock = newAddon()
    local first = { inParty = false, canInvite = false, partyFull = false }
    local second = { inParty = true, canInvite = true, partyFull = true }
    assert(current:RegisterDataStatusProvider("first", function() return first end, function() end))
    assert(current:RegisterDataStatusProvider("second", function() return second end, function() end))
    clock:connect()
    assert(#clock.sent == 0, "Overlapping mask providers must not publish whichever happens to win")
    second = { canInvite = true, partyFull = true }
    clock:advance(5)
    assert(#clock.sent == 1 and clock.sent[1].message:match("|1|10=0$"))
    first = { inParty = true }
    clock:advance(5)
    assert(#clock.sent == 2 and clock.sent[2].message:match("|2|$"),
        "Partial groups in separate providers remain unavailable")
    second = { inParty = true, canInvite = true, partyFull = true }
    clock:advance(5)
    assert(#clock.sent == 3 and clock.sent[3].message:match("|3|10=7$"))
end

-- Unknown numeric IDs never leak to named consumers, but still participate in
-- same-revision consistency. Newer complete snapshots replace all prior fields.
do
    local current, clock, samples, _, contacts = statusFixture({ level = 24 })
    local function sample(revision, expected)
        local received = samples[#samples]
        assert(received.sequence == revision and equal(received.fields, expected))
        assert(contacts[#contacts].metadata.synchronized)
    end
    assert(receive(current, "Friend", full("peer", 2000000000, 1, "1=25|12=future|65535=edge")))
    sample(1, { level = "25" })
    assert(receive(current, "Friend", full("peer", 2000000001, 5, "1=25|12=changed|13=|65535=edge")))
    sample(5, { level = "25" })
    assert(not receive(current, "Friend", full("peer", 2000000002, 5, "1=25|12=conflict|13=|65535=edge")))
    assert(not receive(current, "Friend", full("peer", 2000000002, 5, "1=25")))
    assert(receive(current, "Friend", full("peer", 2000000002, 5, "1=25|12=changed|13=|65535=edge")))
    sample(5, { level = "25" })
    assert(receive(current, "Friend", full("peer", 2000000003, 8, "1=25|2=10")))
    sample(8, { level = "25", xp = "10" })
    assert(receive(current, "Friend", full("peer", 2000000004, 9, "2=10")))
    sample(9, { xp = "10" })
    clock:advance(5)
    assert(#clock.sent == 1, "Remote changes must not schedule recovery requests")
end

-- One shared five-second scheduler sends complete changes and periodic complete
-- refreshes. Targeted replies cannot mark an unpublished local change as public.
do
    local values = { xpState = "known", xpMax = 100, xp = 10, level = 24 }
    local current, clock, samples, connections = statusFixture(values)
    assert(#clock.sent == 1 and clock.sent[1].message:match("^1|Q|status|[^|]+|5|F|[^|]+|2000000000|1|"))
    assert(clock.sent[1].message:find("1=24|2=10|3=100|4=1", 1, true))
    current:JoinDataChannel(false)
    current:OnDataLogin()
    clock:advance(25)
    assert(#clock.sent == 1 and #connections == 2 and clock:activeTimers() == 2, "One membership check and one shared status timer")
    clock:advance(5)
    assert(#clock.sent == 2 and clock.sent[2].at == 30
        and clock.sent[2].message:match("^1|status|5|F|[^|]+|2000000030|1|1=24|2=10|3=100|4=1$"))
    values.xp = 20
    clock:advance(5)
    assert(#clock.sent == 3 and clock.sent[3].message:match("|5|F|[^|]+|2000000035|2|1=24|2=20|3=100|4=1$"),
        "A changed field sends the complete independently usable status")
    values.xp = 21
    clock:advance(1)
    assert(not current:DataStatusTick() and #clock.sent == 3)
    values.xp = 29
    clock:advance(4)
    assert(#clock.sent == 4 and clock.sent[4].at == 40
        and clock.sent[4].message:match("|5|F|[^|]+|2000000040|3|1=24|2=29|3=100|4=1$"))
    values.xp = 30
    assert(current:ReceiveData("Friend", "1|Q|status|joined|" .. full("friend-1", 2000000040, 1,
        "1=25|2=5|3=200|4=1")))
    assert(#samples == 1 and samples[1].fields.level == "25" and samples[1].fields.xp == "5"
        and samples[1].metadata.kind == "full")
    assert(#clock.sent == 5 and clock.sent[5].message:match("^1|R|status|joined|friend%-testrealm|5|F|"))
    assert(clock.sent[5].message:find("2=30", 1, true))
    clock:advance(5)
    assert(#clock.sent == 6 and clock.sent[6].message:match("^1|status|5|F|")
        and clock.sent[6].message:find("2=30", 1, true),
        "A targeted reply does not consume the public change")
    clock:advance(25)
    assert(#clock.sent == 6)
    clock:advance(5)
    assert(#clock.sent == 7 and clock.sent[7].message:match("^1|status|5|F|")
        and clock.sent[7].message:find("1=24|2=30|3=100|4=1", 1, true))
end

-- A temporary value shared in a requested reply must be corrected even if it
-- changes back to the previously published value before the next tick.
do
    local values = { xp = 1 }
    local current, clock = statusFixture(values)
    values.xp = 2
    assert(current:ReceiveData("Friend", "1|Q|status|temporary|" .. full("peer", 2000000000, 1, "1=25")))
    assert(clock.sent[2].message:find("2=2", 1, true))
    values.xp = 1
    clock:advance(5)
    assert(#clock.sent == 3 and clock.sent[3].message:match("^1|status|5|F|")
        and clock.sent[3].message:match("|3|2=1$"))
end

-- Complete snapshots dispatch independent tables. Omitted fields disappear;
-- an explicitly empty string remains a real value.
do
    local current, clock, samples, _, contacts = statusFixture({ level = 24 })
    local second = {}
    assert(current:RegisterDataStatusProvider("future", function() return { sharing = true, xp = "a|b=c%" } end,
        function(_, fields, _, _, metadata)
            second[#second + 1] = { level = fields.level, metadata = metadata }
            fields.level = "mutated"; metadata.kind = "mutated"
        end))
    assert(not current:RegisterDataStatusProvider("future", function() end, function() end))
    assert(not current:RegisterDataStatusProvider("Upper", function() end, function() end))
    clock:advance(5)
    assert(#clock.sent == 2 and clock.sent[2].message:match("^1|status|5|F|")
        and clock.sent[2].message:find("2=a%7Cb%3Dc%25|8=1", 1, true)
        and clock.sent[2].message:find("1=24", 1, true))
    assert(clock:activeTimers() == 2 and current.dataState.features.status and current.dataState.requests.status
        and not current.dataState.features.player and not current.dataState.features.future)
    local initial = full("friend-1", 2000000005, 10, "1=25|2=future%7Cvalue|3=|4=1|6=old")
    assert(receive(current, "Friend", initial))
    assert(#samples == 1 and samples[1].fields.level == "25" and samples[1].fields.xp == "future|value"
        and samples[1].fields.xpMax == "" and samples[1].fields.xpState == "known" and second[1].level == "25"
        and samples[1].metadata.kind == "full" and contacts[1].metadata.synchronized)
    assert(not receive(current, "FRIEND-Test Realm", initial))
    assert(not receive(current, "Friend", full("friend-1", 2000000004, 9, "1=26")))
    assert(not receive(current, "Self-TestRealm", initial))
    assert(receive(current, "Friend", full("friend-1", 2000000006, 11, "1=25|2=20|3=future%7Cvalue")))
    assert(#samples == 2 and samples[2].fields.level == "25" and samples[2].fields.xp == "20"
        and samples[2].fields.xpMax == "future|value" and samples[2].fields.canInvite == nil
        and samples[2].fields.xpState == nil and samples[2].metadata.kind == "full" and samples[2].metadata.coherent)
    assert(receive(current, "Friend", full("friend-1", 2000000036, 11, "1=25|2=20|3=future%7Cvalue")))
    assert(#samples == 3 and #contacts == 3 and contacts[3].metadata.kind == "full"
        and samples[3].metadata.hasBaseline and samples[3].metadata.synchronized,
        "A complete refresh delivers current values and refreshes presence")
    assert(not receive(current, "Friend", full("friend-1", 2000000036, 11, "1=25|2=20|3=future%7Cvalue")))
    local attempts, healthy = 0, 0
    assert(current:RegisterDataStatusProvider("declining", function() error("Collector failed") end,
        function() attempts = attempts + 1; return false end))
    assert(current:RegisterDataStatusProvider("broken", function() return nil end,
        function() error("Receiver failed") end, nil, function() error("Contact failed") end))
    assert(current:RegisterDataStatusProvider("healthy", function() return { xpMax = "healthy" } end,
        function() healthy = healthy + 1 end))
    assert(receive(current, "Other", full("other-1", 2000000005, 1, "1=99")))
    assert(receive(current, "Other", full("other-1", 2000000006, 2, "1=26")))
    assert(attempts == 2 and healthy == 2, "Failed and declining callbacks cannot stop other consumers")
    clock:advance(5)
    assert(clock.sent[#clock.sent].message:find("3=healthy", 1, true))
end

-- Every complete packet is usable across revision gaps. Revisions order one
-- session; timestamps also order its refreshes and changes of session.
do
    local values = { xp = 1 }
    local current, clock, samples, _, contacts = statusFixture(values)
    assert(receive(current, "Friend", full("friend-1", 2000000000, 1, "1=24|2=10")))
    assert(receive(current, "Friend", full("friend-1", 2000000005, 30, "1=24|2=30")))
    assert(#samples == 2 and #contacts == 2 and contacts[2].metadata.synchronized
        and samples[2].fields.xp == "30", "No earlier revision is needed for a complete snapshot")
    assert(not receive(current, "Friend", full("friend-1", 2000000006, 29, "1=24|2=29")))
    assert(not receive(current, "Friend", full("friend-1", 2000000004, 30, "1=24|2=30")))
    assert(not receive(current, "Friend", full("friend-1", 2000000006, 30, "1=24|2=99")))
    assert(not receive(current, "Friend", full("friend-1", 2000000005, 30, "1=24|2=30")))
    assert(#samples == 2 and #contacts == 2, "Rejected packets cannot refresh presence or alter current values")
    assert(receive(current, "Friend", full("friend-1", 2000000006, 30, "1=24|2=30")))
    assert(receive(current, "Friend", full("friend-1", 2000000005, 31, "1=24|2=31")),
        "A newer revision retains precedence over timestamp ordering within one session")
    assert(receive(current, "Friend", full("friend-2", 2000000006, 1, "1=25|2=0")),
        "A reconnect may restart revisions in the same server second under a fresh session")
    assert(not receive(current, "Friend", full("friend-1", 2000000040, 31, "1=99")),
        "A retired sender session cannot overwrite the replacement")
    assert(not receive(current, "Friend", full("old-session", 2000000005, 99, "1=99")))
    assert(samples[#samples].fields.xp == "0" and samples[#samples].metadata.session == "friend-2")
    assert(receive(current, "Unknown", full("unknown-1", 2000000006, 9999, "2=99")))
    assert(samples[#samples].fields.xp == "99" and samples[#samples].metadata.synchronized,
        "A new peer can start at any complete revision")
    clock:advance(5)
    assert(#clock.sent == 1, "Receiving status never schedules a standalone recovery request")
end

-- A group switch requested during delivery blocks new work immediately while
-- allowing the current callback set to finish before resetting its state.
do
    local current, clock, samples = statusFixture({ level = 24 })
    local switched, finished = false, false
    local oldName = current:GetGroupDataChannelName()
    assert(current:RegisterDataStatusProvider("alpha", function() return {} end,
        function(sender)
            if switched then return end
            switched = true
            assert(current:SetGroupSecret("switch-after-delivery"))
            assert(current:IsGroupSwitching() and current:GetGroupDataChannelName() == oldName)
            assert(not receive(current, sender, full("old-peer", 2000000001, 2, "1=stale")))
            assert(not current:RequestData("status", full("local", 2000000000, 1, "1=24")) and #clock.sent == 1)
            finished = true
        end))
    assert(receive(current, "Friend", full("old-peer", 2000000000, 1, "1=25")))
    assert(finished and #samples == 1 and samples[1].fields.level == "25"
        and current:GetGroupDataChannelName() == oldName and current:IsGroupSwitching(),
        "No new group is activated inside the old group's callback")
    clock:advance(0)
    assert(not current:IsGroupSwitching() and current:GetGroupDataChannelName() ~= oldName
        and next(current.dataState.status.received) == nil, "Deferred cleanup discards old peer snapshots")
end

-- Logically targeted replies do not postpone the public refresh needed by
-- other peers. Switching to read-only settings stops this scheduler as well.
do
    local current, clock = statusFixture({ level = 24 })
    clock:advance(10)
    assert(current:ReceiveData("Friend", "1|Q|status|first|" .. full("peer", 2000000010, 1, "1=25")))
    clock:advance(10)
    assert(current:ReceiveData("Friend", "1|Q|status|second|" .. full("peer", 2000000020, 1, "1=25")))
    clock:advance(10)
    assert(clock.sent[#clock.sent].message:match("^1|status|5|F|[^|]+|2000000030|1|1=24$"))
    current.savedDataReadOnly = true
    local sent = #clock.sent
    clock:advance(60)
    assert(#clock.sent == sent and clock:activeTimers() == 0 and not current.dataState.status.connected)
end

-- Initial responses may repeat the current sample in the same server second;
-- this exception never permits conflicting values at an existing revision.
do
    local current, clock, samples, _, contacts = statusFixture({ xp = 1 })
    local requestID = assert(clock.sent[1].message:match("^1|Q|status|([^|]+)|"))
    local snapshot = full("friend-1", 2000000000, 4, "2=40")
    assert(receive(current, "Friend", snapshot))
    assert(current:ReceiveData("Friend", "1|R|status|" .. requestID .. "|self-testrealm|" .. snapshot))
    assert(#samples == 2 and #contacts == 2 and samples[2].fields.xp == "40")
    assert(receive(current, "Other", full("other-1", 2000000000, 4, "2=40")))
    assert(not current:ReceiveData("Other", "1|R|status|" .. requestID .. "|self-testrealm|"
        .. full("other-1", 2000000000, 4, "2=99")),
        "A solicited response cannot change values at the same revision")
    assert(not receive(current, "Friend", full("friend-1", 2000000001, 4, "2=99")))
    assert(samples[2].fields.xp == "40")
end

-- Decode every field before dispatch. Invalid frames cannot partially merge or
-- consume a revision. Old status versions and named wire fields are rejected.
do
    local current, clock, samples = statusFixture({ level = 24 }, nil, {})
    local initialSends = #clock.nativeSends
    -- One representative per structural, numeric, typed-value and escaping failure.
    for index, payload in ipairs({
        "4|F|peer|2000000000|1|1=25", "5|D|peer|2000000000|2|1|1=25",
        "5|F||2000000000|1|1=25", "5|F|peer|10000000000|1|1=25",
        "5|F|peer|2000000000|0|1=25", "5|F|peer|2000000000|01|1=25",
        "5|F|peer|2000000000|1|1=25|1=26", "5|F|peer|2000000000|1|1=25|",
        "5|F|peer|2000000000|1|level=25", "5|F|peer|2000000000|1|1=25=26",
        "5|F|peer|2000000000|1|4=known", "5|F|peer|2000000000|1|8=2",
        "5|F|peer|2000000000|1|10=-1", "5|F|peer|2000000000|1|11=65536",
        "5|F|peer|2000000000|1|0=x", "5|F|peer|2000000000|1|65536=x",
        "5|F|peer|2000000000|1|1=%GG", "5|F|peer|2000000000|1|1=%0A",
    }) do
        assert(not receive(current, "Friend", payload), payload)
        assert(not current:ReceiveData("Friend", "1|Q|status|direct-" .. index .. "|" .. payload), payload)
        assert(#samples == 0 and #clock.nativeSends == initialSends,
            "Malformed status frames cannot dispatch or receive replies: " .. payload)
    end
    clock:incoming("1|status|" .. full("peer", 2000000000, 1, "1=25"), "Friend")
    assert(#samples == 1)
    for _, body in ipairs({ "2=20|10=%GG", "2=20|0=x", "2=20|65536=x", "2=20|10|10=bad" }) do
        assert(not receive(current, "Friend", full("malformed-session", 9999999999, 999999999, body)))
        clock:incoming("1|status|" .. full("malformed-session", 9999999999, 999999999, body), "Friend")
        assert(#samples == 1,
            "Malformed later IDs cannot partially dispatch or poison sender ordering")
    end
    clock:incoming("1|status|" .. full("peer", 2000000005, 2, "1=25|2=20"), "Friend")
    assert(#samples == 2 and samples[2].fields.level == "25" and samples[2].fields.xp == "20")
end

-- A provider with no initial sample stays quiet. Once it had a sample, becoming
-- unavailable sends an empty complete snapshot instead of retaining stale data.
do
    local current, clock = newAddon()
    local values, marker = nil, {}
    clock.environment.issecretvalue = function(value) return rawequal(value, marker) end
    assert(current:RegisterDataStatusProvider("unsafe", function() return values end, function() end))
    clock:login(); clock:connect()
    for _, invalid in ipairs({ marker, { xpState = marker }, { [marker] = "secret" },
        { xpState = 0 / 0 }, { xpState = "bad\nvalue" } }) do
        values = invalid
        clock:advance(5)
        assert(#clock.sent == 0)
    end
    values = { sharing = false }
    clock:advance(5)
    assert(#clock.sent == 1 and clock.sent[1].message:find("8=0", 1, true))
    values = nil
    clock:advance(5)
    assert(#clock.sent == 2 and clock.sent[2].message:match("|5|F|[^|]+|%d+|2|$"))
end

-- Initial failures retry at the five-second cadence; reconnecting resets peer
-- state and starts a fresh join request. Logout cancels all scheduled work.
do
    local values = { xp = 1 }
    local current, clock, _, connections = statusFixture(values, false)
    assert(#clock.sent == 1 and next(current.dataState.pendingRequests) == nil)
    for _ = 1, 10 do current:DataStatusTick() end
    assert(#clock.sent == 1)
    values.xp = 2
    clock:advance(5)
    assert(#clock.sent == 2 and clock.sent[2].message:find("2=2", 1, true))
    clock:disconnect()
    assert(not connections[#connections])
    clock:connect()
    assert(#clock.sent == 3 and clock.sent[3].message:match("^1|Q|status|") and connections[#connections])
    assert(receive(current, "Friend", full("peer", 2000000000, 1, "2=7")))
    clock:disconnect(); clock:connect()
    assert(receive(current, "Friend", full("peer", 2000000000, 1, "2=8")))
    clock:fire("PLAYER_LOGOUT")
    local sent = #clock.sent
    clock:advance(60)
    assert(#clock.sent == sent and clock:activeTimers() == 0)
end

-- Reconnecting after a coordinated switch starts a distinct full status session.
do
    local values = { level = 24, xp = 10 }
    local current, clock = statusFixture(values, nil, {})
    local oldSession = assert(clock.nativeSends[1].message:match("|5|F|([^|]+)|"))
    assert(receive(current, "Friend", full("old-peer", 2000000000, 1, "1=25")))
    values.xp = 20
    clock:advance(5)
    assert(clock.nativeSends[2].message:match("|5|F|"))
    assert(current:SetGroupSecret("fresh-status-group"))
    clock:advance(0)
    assert(next(current.dataState.status.received) == nil and not current:IsDataConnected())
    clock:member(12)
    local snapshot = clock.nativeSends[#clock.nativeSends].message
    local session = assert(snapshot:match("|5|F|([^|]+)|%d+|1|"))
    assert(session ~= oldSession and snapshot:find("1=24|2=20", 1, true),
        "New group revisions restart only under a fresh session and complete snapshot")
end

-- Real roster fields share complete native status snapshots; periodic refreshes
-- preserve presence without resetting the age of an unchanged XP sample.
do
    local bus = newRequestBus()
    for index, client in ipairs(bus.clients) do
        local clock, environment = client.world, client.world.environment
        clock.level, clock.xp, clock.xpMax = 24, 100 * index, 1000
        environment.UnitLevel = function(unit) assert(unit == "player"); return clock.level end
        environment.UnitXP = function(unit) assert(unit == "player"); return clock.xp end
        environment.UnitXPMax = function(unit) assert(unit == "player"); return clock.xpMax end
        environment.GetMaxPlayerLevel = function() return 60 end
        loadModule("Roster.lua", client.addon, environment)
        client.addon:InitializeRoster()
        client.addon:OnRosterLogin()
    end
    bus:pump()
    local alice, bob = bus.clients[1], bus.clients[2]
    local function player(client, name)
        for _, row in ipairs(client.addon:GetOverviewPlayers()) do
            if row.id == name:lower() .. "-testrealm" then return row end
        end
        error("Missing discovered player " .. name)
    end
    for _, client in ipairs(bus.clients) do
        assert(#client.addon:GetOverviewPlayers() == 3)
        for index, other in ipairs(bus.clients) do
            local row = player(client, other.name)
            assert(row.level == 24 and row.xp == 100 * index and row.xpMax == 1000
                and row.xpState == "known" and row.online and not row.xpStale)
        end
    end
    local function counts(client)
        local snapshots = 0
        for _, packet in ipairs(client.world.nativeSends) do
            assert(#packet.message <= 255 and not packet.message:match("^1|[QR]?|?roster|"))
            if packet.message:match("^1|status|5|F|") then snapshots = snapshots + 1 end
        end
        return snapshots
    end
    assert(counts(alice) == 0)
    assert(alice.addon:RegisterDataStatusProvider("activity", function() return {} end, function() end))
    alice.world.xp = 420
    alice.world:fire("PLAYER_XP_UPDATE", "player")
    assert(player(alice, "Alice").xp == 420 and player(bob, "Alice").xp == 100)
    alice.world:advance(4); bus:pump(); assert(counts(alice) == 0)
    alice.world:advance(1); bus:pump()
    assert(counts(alice) == 1 and player(bob, "Alice").xp == 420 and not alice.addon.dataState.features.activity)
    local xpStamp = player(bob, "Alice").xpUpdatedAt
    alice.world:advance(30); bus:pump()
    assert(counts(alice) == 2 and not player(bob, "Alice").xpStale
        and player(bob, "Alice").xpUpdatedAt == xpStamp)
    alice.world.level, alice.world.xp, alice.world.xpMax = 25, 0, 1200
    alice.world:fire("PLAYER_LEVEL_UP", 25)
    alice.world:fire("PLAYER_XP_UPDATE", "player")
    bus:pump()
    assert(player(bob, "Alice").level == 24 and player(bob, "Alice").xp == 420,
        "Level and XP wait for the same coherent shared status update")
    alice.world:advance(5); bus:pump()
    assert(player(bob, "Alice").level == 25 and player(bob, "Alice").xp == 0
        and player(bob, "Alice").xpMax == 1200 and counts(alice) == 3)
    alice.world:disconnect()
    assert(player(alice, "Bob").xpStale)
    alice.world:connect()
    assert(player(alice, "Bob").xp == 200 and player(alice, "Bob").xpStale,
        "Reconnect keeps the last reported XP stale until the shared status response arrives")
    bus:pump()
    assert(player(alice, "Bob").xp == 200 and not player(alice, "Bob").xpStale)
end

print("Data tests passed.")
