-- Position model checks run without a live transport or the WoW map UI.
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

local function newAddon(saved, readOnly)
    local world = {
        now = 0, epoch = 2000000000, timers = {}, messages = {},
        map = 37, x = 0.25, y = 0.75, samples = 0, refreshes = 0, sent = {},
    }
    local function timer(delay, callback, repeating)
        local result = { at = world.now + delay, callback = callback, interval = repeating and delay }
        function result:Cancel() self.cancelled = true end
        function result:IsCancelled() return self.cancelled == true end
        world.timers[#world.timers + 1] = result
        return result
    end
    local environment = setmetatable({
        bit = false, bit32 = false,
        C_Timer = {
            NewTimer = function(delay, callback) return timer(delay, callback) end,
            NewTicker = function(delay, callback) return timer(delay, callback, true) end,
            After = function(delay, callback) return timer(delay, callback) end,
        },
        GetTime = function() return world.now end,
        GetServerTime = function() return world.epoch + math.floor(world.now) end,
        UnitFullName = function(unit) assert(unit == "player"); return "Self", "Test Realm" end,
        UnitName = function(unit) assert(unit == "player"); return "Self", "Test Realm" end,
        GetNormalizedRealmName = function() return "TestRealm" end,
        GetRealmName = function() return "Test Realm" end,
        IsLoggedIn = function() return true end,
        C_Map = {
            GetBestMapForUnit = function(unit)
                assert(unit == "player")
                world.samples = world.samples + 1
                return world.map
            end,
            GetPlayerMapPosition = function(map, unit)
                assert(map == world.map and unit == "player")
                if world.x == nil or world.y == nil then return nil end
                return { GetXY = function() return world.x, world.y end }
            end,
        },
        CreateFrame = function(kind)
            assert(kind == "Frame")
            local frame = { events = {} }
            function frame:RegisterEvent(event) self.events[event] = true end
            function frame:UnregisterEvent(event) self.events[event] = nil end
            function frame:SetScript(script, callback) self[script] = callback end
            return frame
        end,
    }, { __index = _G })
    environment._G = environment
    world.environment = environment
    local addon = {
        db = saved or { schemaVersion = 3, group = { secret = "otter-4827" } },
        initialized = true, ready = false, savedDataReadOnly = readOnly,
    }
    function addon:Print(message) world.messages[#world.messages + 1] = message end
    function addon:RefreshOptions() end
    function addon:RefreshPositionPins() world.refreshes = world.refreshes + 1 end
    for _, file in ipairs({ "Crypto.lua", "Group.lua", "Data.lua", "Position.lua" }) do
        loadModule(file, addon, environment)
    end
    addon:InitializeGroup()
    addon:InitializeData()
    addon:InitializePositions()
    function world:login()
        addon.ready = true
        addon:OnDataLogin()
        addon:OnPositionLogin()
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
            assert(callbacks < 200, "Position timers must remain bounded")
            nextTimer.callback(nextTimer)
            if nextTimer.interval and not nextTimer.cancelled then
                nextTimer.at = self.now + nextTimer.interval
                self.timers[#self.timers + 1] = nextTimer
            end
        end
        self.now = target
    end
    function world:position(map, x, y, timestamp)
        return table.concat({ "1", "P", tostring(timestamp or self.epoch + math.floor(self.now)),
            tostring(map), tostring(x), tostring(y) }, "|")
    end
    function world:unavailable(timestamp)
        return "1|U|" .. tostring(timestamp or self.epoch + math.floor(self.now))
    end
    function world:connect()
        addon:SetDataTransport(function(prefix, wire)
            assert(prefix == addon:GetDataPrefix())
            local payload = assert(wire:match("^1|position|(.*)$"), "Positions use the shared data envelope")
            self.sent[#self.sent + 1] = { at = self.now, payload = payload }
            return true
        end)
    end
    return addon, world
end

local function fields(payload)
    local result = {}
    for value in (payload .. "|"):gmatch("([^|]*)|") do result[#result + 1] = value end
    return result
end

-- Existing profiles gain disabled sharing and retention without changing group/schema data.
local addon, world = newAddon()
local fingerprint = addon:GetGroupFingerprint()
assert(addon.db.schemaVersion == 3 and addon.db.group.secret == "otter-4827")
assert(addon.db.position.sharing == false and addon.db.position.keepLastKnown == true)
assert(next(addon:GetSharedPositions()) == nil)
world:connect()
world:advance(10)
assert(world.samples == 0 and #world.sent == 0, "Initialization must not start position sampling")
world:login()
world:advance(10)
assert(world.samples == 0 and #world.sent == 0, "Sharing starts only when explicitly enabled")
addon:SetPositionSharing(true)
world:advance(1)
assert(#world.sent == 0)
world:advance(1)
assert(#world.sent == 1 and world.samples == 1)
local packet = fields(world.sent[1].payload)
assert(#packet == 6 and packet[1] == "1" and packet[2] == "P"
    and tonumber(packet[3]) == world.epoch + 22 and tonumber(packet[4]) == 37
    and tonumber(packet[5]) == 0.25 and tonumber(packet[6]) == 0.75)
world.x = 0.5
world:advance(2)
assert(#world.sent == 2 and world.sent[2].at - world.sent[1].at == 2)
assert(tonumber(fields(world.sent[2].payload)[5]) == 0.5)

-- Incoming updates use the actual sender and replace only an older valid position.
assert(addon:ReceiveData("Friend-Test Realm", "1|position|" .. world:position(37, 0.4, 0.6)),
    "The shared data router delivers position messages to the registered receiver")
local friend = assert(addon:GetSharedPositions()["friend-testrealm"])
assert(friend.name == "Friend-Test Realm" and friend.map == 37 and friend.x == 0.4 and friend.y == 0.6)
addon:ReceivePosition("Self", world:position(37, 0.2, 0.3))
assert(addon:GetSharedPositions()["self-testrealm"] == nil)
local incomingStamp = world.epoch + world.now
for _, malformed in ipairs({
    "2|P|2000000031|37|0.9|0.1", "1|P|2000000031|37|0.9|0.1|extra",
    "1|P|2000000031|37|0.9", "1|P|2000000031|37|1.1|0.1",
    "1|P|2000000031|0|0.9|0.1", "1|P|2000000031|37|unknown|0.1",
    "1|U|not-a-time", "1|X|2000000031",
    world:position(37, 0.9, 0.1, incomingStamp),
    world:position(37, 0.9, 0.1, incomingStamp - 1),
}) do
    addon:ReceivePosition("Friend-Test Realm", malformed)
end
assert(addon:GetSharedPositions()["friend-testrealm"].x == 0.4,
    "Malformed, duplicate and older packets must not replace the latest coordinates")
addon:ReceivePosition("Friend-Test Realm", world:position(37, 0.41, 0.61, incomingStamp + 1))
assert(addon:GetSharedPositions()["friend-testrealm"].x == 0.41)
assert(world.refreshes > 0, "Accepted updates request a map refresh")

-- An absent or failing transport never builds a backlog of old samples.
addon:SetDataTransport(nil)
assert(addon:GetPositionStatusText():find("Waiting", 1, true), "An unwired feature must report that it is waiting for a connection")
world:advance(20)
assert(#world.sent == 2)
world.x = 0.65
world:connect()
world:advance(2)
assert(#world.sent == 3 and tonumber(fields(world.sent[3].payload)[5]) == 0.65,
    "Reconnect sends only the next current sample")
local attempts = 0
addon:SetDataTransport(function() attempts = attempts + 1; return false end)
world:advance(4)
assert(attempts == 2 and #world.sent == 3)
assert(addon:GetPositionStatusText():find("unavailable", 1, true))
world:connect()
world:advance(2)
assert(#world.sent == 4, "Failed sends must not be replayed after transport recovery")

-- Unavailable coordinates produce an explicit unavailable sample, never a fake position.
world.map = nil
world:advance(2)
packet = fields(world.sent[#world.sent].payload)
assert(#packet == 3 and packet[1] == "1" and packet[2] == "U")
world.map, world.x = 37, nil
world:advance(2)
assert(fields(world.sent[#world.sent].payload)[2] == "U")
world.x = 0.2
world:advance(2)
assert(fields(world.sent[#world.sent].payload)[2] == "P")

-- Retention keeps the latest location across missing/unavailable updates and reloads.
local retainedX = addon:GetSharedPositions()["friend-testrealm"].x
addon:ReceivePosition("Friend-Test Realm", world:unavailable())
world:advance(20)
assert(addon:GetSharedPositions()["friend-testrealm"].x == retainedX)
local stored = assert(addon.db.position.peers["friend-testrealm"])
assert(stored.x == retainedX and stored.lastReceived == nil,
    "Persist coordinates without persisting the local runtime clock")
local saved = copy(addon.db)
local reloaded, reloadWorld = newAddon(copy(saved))
reloadWorld:login()
assert(reloaded:GetSharedPositions()["friend-testrealm"].x == retainedX,
    "Retained locations survive a reload with the same group")
reloadWorld:advance(20)
assert(reloaded:GetSharedPositions()["friend-testrealm"].x == retainedX)
reloaded:SetPositionSharing(false)
local samplesBefore = reloadWorld.samples
reloadWorld:advance(20)
reloaded:ReceivePosition("Newfriend-TestRealm", reloadWorld:position(37, 0.2, 0.3))
assert(next(reloaded:GetSharedPositions()) == nil and reloadWorld.samples == samplesBefore)
assert(reloaded.db.position.peers["friend-testrealm"] and not reloaded.db.position.peers["newfriend-testrealm"],
    "Disabled sharing hides pins and ignores new packets while preserving retained locations")
reloaded:SetPositionSharing(true)
assert(reloaded:GetSharedPositions()["friend-testrealm"].x == retainedX)

-- Disabling retention clears persisted locations and removes runtime positions after 60 seconds.
addon, world = newAddon()
world:login()
addon:SetPositionSharing(true)
addon:ReceivePosition("Friend", world:position(37, 0.3, 0.7))
addon:SetPositionRetention(false)
assert(next(addon.db.position.peers) == nil and addon:GetSharedPositions()["friend-testrealm"])
world:advance(59)
assert(addon:GetSharedPositions()["friend-testrealm"])
world:advance(1)
assert(next(addon:GetSharedPositions()) == nil, "Remove stale positions when retention is disabled")
assert(world.samples == 0, "Expiry must work without sampling or sending when no transport is connected")
addon:ReceivePosition("Friend", world:position(37, 0.35, 0.75))
assert(addon:GetSharedPositions()["friend-testrealm"])
addon:ReceivePosition("Friend", world:unavailable(world.epoch + world.now + 1))
assert(next(addon:GetSharedPositions()) == nil, "Unavailable updates remove a non-retained pin immediately")
addon:ReceivePosition("Friend", world:position(37, 0.36, 0.76, world.epoch + world.now + 2))
addon:SetPositionSharing(false)
world:advance(60)
addon:SetPositionSharing(true)
assert(next(addon:GetSharedPositions()) == nil,
    "Re-enabling sharing must not briefly display a location that expired while sharing was disabled")
local ephemeralReload = newAddon(copy(addon.db))
assert(next(ephemeralReload:GetSharedPositions()) == nil)

-- Group changes and leaving cannot reveal the previous group's retained locations.
addon, world = newAddon(copy(saved))
world:login()
world:connect()
assert(addon:GetSharedPositions()["friend-testrealm"])
addon:SetGroupSecret("other-group")
assert(next(addon:GetSharedPositions()) == nil and next(addon.db.position.peers) == nil)
assert(addon.db.position.groupFingerprint ~= fingerprint)
world:advance(2)
assert(#world.sent == 0 and not addon:IsDataConnected(), "Changing groups disconnects the previous data backend")
world:connect()
world:advance(2)
assert(#world.sent == 1, "A new group connection sends current data without replaying old samples")
addon:ReceivePosition("Newfriend", world:position(37, 0.1, 0.9))
addon:LeaveGroup()
local sentBefore = #world.sent
world:advance(20)
assert(next(addon:GetSharedPositions()) == nil and next(addon.db.position.peers) == nil and #world.sent == sentBefore)

-- A mismatched persisted group is discarded before any old location is displayed.
local mismatched = copy(saved)
mismatched.position.groupFingerprint = "different-group"
addon = newAddon(mismatched)
assert(next(addon:GetSharedPositions()) == nil and next(addon.db.position.peers) == nil)

-- Read-only settings and an invalid group remain intact and cannot start sharing.
local readOnlySaved = copy(saved)
local original = copy(readOnlySaved)
addon, world = newAddon(readOnlySaved, true)
world:connect()
world:login()
addon:SetPositionSharing(true)
addon:SetPositionRetention(false)
addon:ReceivePosition("Friend", world:position(37, 0.9, 0.1))
world:advance(20)
assert(equal(readOnlySaved, original), "Position initialization and setters must preserve read-only data")
assert(#world.sent == 0 and next(addon:GetSharedPositions()) == nil)
local invalid = copy(saved)
invalid.group.secret = "invalid group!"
addon, world = newAddon(invalid)
world:connect()
world:login()
world:advance(20)
assert(invalid.group.secret == "invalid group!" and #world.sent == 0 and next(addon:GetSharedPositions()) == nil)

-- Unchanged serialized coordinates are suppressed; heartbeats carry fresh timestamps.
do
    local stationary, clock = newAddon()
    clock:login()
    clock:connect()
    stationary:SetPositionSharing(true)
    clock:advance(2)
    assert(#clock.sent == 1)
    clock:advance(15)
    assert(#clock.sent == 1, "Stationary players do not send every sample")
    clock:advance(1)
    assert(#clock.sent == 2 and clock.sent[2].at - clock.sent[1].at == 16)
    assert(tonumber(fields(clock.sent[2].payload)[3]) - tonumber(fields(clock.sent[1].payload)[3]) == 16,
        "The 15-second heartbeat is due on the next two-second tick and has a fresh timestamp")
    clock.x = 0.2500001
    clock:advance(2)
    assert(#clock.sent == 2, "Changes smaller than the transmitted precision remain suppressed")
    clock.x = 0.25002
    clock:advance(2)
    assert(#clock.sent == 3 and tonumber(fields(clock.sent[3].payload)[5]) == 0.25002)
    clock.map = 38
    clock:advance(2)
    assert(#clock.sent == 4 and tonumber(fields(clock.sent[4].payload)[4]) == 38,
        "Changing map must send even when coordinates match")
    clock:advance(14)
    assert(#clock.sent == 4, "Movement resets the heartbeat deadline")
    clock:advance(2)
    assert(#clock.sent == 5)
    clock.y = 0.6
    clock:advance(2)
    assert(#clock.sent == 6 and tonumber(fields(clock.sent[6].payload)[6]) == 0.6)

    stationary:SetPositionSharing(false)
    stationary:SetPositionSharing(true)
    clock:advance(2)
    assert(#clock.sent == 7, "Re-enabling sharing announces the current location without waiting for a heartbeat")
    clock:connect()
    clock:advance(2)
    assert(#clock.sent == 8, "A replacement connection must not inherit suppression from the old one")
end

-- Unavailable data is also deduplicated and heartbeated; recovery sends at the next sample.
do
    local unavailable, clock = newAddon()
    clock:login()
    clock:connect()
    unavailable:SetPositionSharing(true)
    clock:advance(2)
    clock.map = nil
    clock:advance(2)
    assert(#clock.sent == 2 and fields(clock.sent[2].payload)[2] == "U")
    clock:advance(14)
    assert(#clock.sent == 2, "Repeated unavailable samples are suppressed before the heartbeat")
    clock:advance(2)
    assert(#clock.sent == 3 and fields(clock.sent[3].payload)[2] == "U"
        and clock.sent[3].at - clock.sent[2].at == 16)
    clock.map = 37
    clock:advance(2)
    assert(#clock.sent == 4 and fields(clock.sent[4].payload)[2] == "P",
        "Valid coordinates resume immediately even when they match the last known position")
end

-- Acceptance alone advances suppression; failures retry current data without a queue.
do
    local retrying, clock = newAddon()
    local attempts, accept, throws = {}, true, false
    retrying:SetDataTransport(function(prefix, wire)
        assert(prefix == retrying:GetDataPrefix())
        local payload = assert(wire:match("^1|position|(.*)$"))
        attempts[#attempts + 1] = { at = clock.now, payload = payload }
        if throws then error("Disconnected") end
        return accept
    end)
    clock:login()
    retrying:SetPositionSharing(true)
    clock:advance(2)
    accept, clock.x = false, 0.6
    clock:advance(2)
    assert(#attempts == 2 and retrying:GetPositionStatusText():find("unavailable", 1, true))
    accept, clock.x = true, 0.25
    clock:advance(2)
    assert(#attempts == 3 and tonumber(fields(attempts[3].payload)[5]) == 0.25,
        "Retry current data even when movement returns to the last accepted position")
    throws, clock.x = true, 0.8
    clock:advance(2)
    assert(#attempts == 4 and retrying:GetPositionStatusText():find("unavailable", 1, true))
    throws, clock.x = false, 0.9
    clock:advance(2)
    assert(#attempts == 5 and tonumber(fields(attempts[5].payload)[5]) == 0.9)
    assert(not retrying:GetPositionStatusText():find("unavailable", 1, true))
    clock:advance(14)
    assert(#attempts == 5)
    clock:advance(2)
    assert(#attempts == 6 and attempts[6].at - attempts[5].at == 16,
        "Only the successful retry starts a new heartbeat interval")
end

-- Each player times out independently; retained coordinates survive offline classification.
do
    local presence, clock = newAddon()
    clock:login()
    presence:SetPositionSharing(true)
    assert(presence:ReceivePosition("Alice", clock:position(37, 0.3, 0.7)))
    assert(presence:GetSharedPositions()["alice-testrealm"].online == true)
    clock:advance(30)
    assert(presence:ReceivePosition("Bob", clock:position(37, 0.4, 0.6)))
    clock:advance(29)
    assert(presence:GetSharedPositions()["alice-testrealm"].online == true)
    clock:advance(1)
    assert(presence:GetSharedPositions()["alice-testrealm"].online == false
        and presence:GetSharedPositions()["bob-testrealm"].online == true,
        "Only the player with 60 seconds of silence becomes offline")
    local atTimeout = clock.refreshes
    clock:advance(5)
    assert(clock.refreshes == atTimeout, "Already offline peers do not trigger repeated refreshes")
    assert(not presence:ReceivePosition("Alice", clock:position(37, 0.9, 0.1, clock.epoch)))
    assert(presence:GetSharedPositions()["alice-testrealm"].online == false,
        "An old packet must not revive an offline player")
    assert(presence:ReceivePosition("Alice", clock:unavailable()))
    assert(presence:GetSharedPositions()["alice-testrealm"].online == true
        and presence:GetSharedPositions()["alice-testrealm"].x == 0.3
        and clock.refreshes == atTimeout + 1,
        "An unavailable-coordinate heartbeat confirms presence without replacing retained coordinates")
    clock:advance(25)
    assert(presence:GetSharedPositions()["bob-testrealm"].online == false
        and presence:GetSharedPositions()["alice-testrealm"].online == true)
    assert(presence:ReceivePosition("Bob", clock:position(37, 0.5, 0.5)))
    assert(presence:GetSharedPositions()["bob-testrealm"].online == true)
    local snapshot = copy(presence.db)
    assert(snapshot.position.peers["bob-testrealm"].online == nil
        and snapshot.position.peers["bob-testrealm"].lastReceived == nil,
        "Runtime presence must not be persisted as proof of online status")
    local restored, restoredClock = newAddon(snapshot)
    restoredClock:login()
    assert(restored:GetSharedPositions()["bob-testrealm"].online == false,
        "Restored players without fresh data start offline")
    restoredClock:advance(120)
    assert(restored:GetSharedPositions()["bob-testrealm"].x == 0.5,
        "Offline retained coordinates survive beyond the timeout")
end

-- Stationary heartbeats keep live-only pins alive beyond 60 seconds in total.
do
    local live, clock = newAddon()
    clock:login()
    live:SetPositionSharing(true)
    live:SetPositionRetention(false)
    assert(live:ReceivePosition("Friend", clock:position(37, 0.3, 0.7)))
    for _ = 1, 5 do
        clock:advance(16)
        assert(live:ReceivePosition("Friend", clock:position(37, 0.3, 0.7)))
        assert(live:GetSharedPositions()["friend-testrealm"].online == true)
    end
    clock:advance(59)
    assert(live:GetSharedPositions()["friend-testrealm"])
    clock:advance(1)
    assert(next(live:GetSharedPositions()) == nil, "Live-only pins disappear after 60 seconds without a heartbeat")
end

-- Native regional full names supplement legacy self detection without changing peer keys.
do
    local regional, clock = newAddon()
    clock.environment.UnitFullName = function(unit)
        assert(unit == "player")
        return "Dar", "Mara"
    end
    local nativeName = "Dar Mara"
    clock.environment.NameUtil = { GetUnmodifiedUnitFullName = function(unit)
        assert(unit == "player")
        return nativeName
    end }
    clock:login()
    regional:SetPositionSharing(true)
    for _, native in ipairs({ "Dar Mara", "Dar Mara-Test Realm" }) do
        nativeName = native
        for _, sender in ipairs({ "Dar Mara", "Dar Mara-Test Realm", "Dar Mara-TestRealm", "Dar-Mara" }) do
            assert(not regional:ReceivePosition(sender, clock:position(37, 0.3, 0.7)),
                "Exclude both native full-name echoes and the legacy self identity")
        end
    end
    assert(next(regional:GetSharedPositions()) == nil and next(regional.db.position.peers) == nil,
        "Self echoes must not create runtime or retained pins")
    assert(regional:ReceivePosition("Friend-Test Realm", clock:position(37, 0.4, 0.6)))
    local peer = assert(regional.db.position.peers["friend-testrealm"])
    assert(peer.name == "Friend-Test Realm" and peer.x == 0.4,
        "Native self detection must preserve existing peer names and canonical saved keys")
    local restored, restoredClock = newAddon(copy(regional.db))
    restoredClock:login()
    assert(restored:GetSharedPositions()["friend-testrealm"].x == 0.4,
        "Existing retained peer keys remain readable after a reload")

    clock.environment.NameUtil.GetUnmodifiedUnitFullName = function() error("Native name unavailable") end
    assert(regional:ReceivePosition("Other", clock:position(37, 0.5, 0.5)),
        "A failing native name helper must not interrupt real peer updates")
    assert(not regional:ReceivePosition("Dar-Mara", clock:position(37, 0.3, 0.7)),
        "Legacy self detection remains active when the native helper fails")
    local secretName = setmetatable({}, { __tostring = function() error("Secret name must not be inspected") end })
    clock.environment.issecretvalue = function(value) return value == secretName end
    clock.environment.NameUtil.GetUnmodifiedUnitFullName = function() return secretName end
    assert(regional:ReceivePosition("Another", clock:position(37, 0.6, 0.4)),
        "An unreadable native name must safely fall back to legacy self detection")
    assert(not regional:ReceivePosition("Dar-Mara", clock:position(37, 0.3, 0.7)))
end

print("Position tests passed.")
