-- Shared feature routing is exercised without native addon-channel delivery.
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

local function newAddon(saved, readOnly, withPositions)
    local world = { now = 0, epoch = 2000000000, timers = {}, sent = {}, messages = {}, x = 0.25, y = 0.75, map = 37 }
    local environment = setmetatable({
        bit = false, bit32 = false, C_ChatInfo = false,
        GetTime = function() return world.now end,
        GetServerTime = function() return world.epoch + math.floor(world.now) end,
        GetNormalizedRealmName = function() return "TestRealm" end,
        UnitFullName = function(unit) assert(unit == "player"); return "Self", "Test Realm" end,
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

-- A backend attached before login becomes usable when Core announces readiness.
local early, earlyWorld = newAddon()
local readyNotices = {}
early:RegisterDataFeature("echo", function() end, function(connected)
    readyNotices[#readyNotices + 1] = connected
end)
earlyWorld:connect()
assert(not early:IsDataConnected() and readyNotices[#readyNotices] == false)
early.ready = true
early:OnDataLogin()
assert(early:IsDataConnected() and readyNotices[#readyNotices] == true)
assert(early:SendData("echo", "after login"))

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

print("Data tests passed.")
