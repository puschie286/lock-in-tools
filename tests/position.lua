-- Position model checks use mocked native channels without the WoW map UI.
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

local function newAddon(saved, readOnly, prepare)
    local world = {
        now = 0, epoch = 2000000000, timers = {}, messages = {}, name = "Self",
        map = 37, x = 0.25, y = 0.75, samples = 0, refreshes = 0, sent = {},
        channels = {}, joinEnabled = false, sendAttempts = {},
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
        UnitFullName = function(unit) assert(unit == "player"); return world.name, "Test Realm" end,
        UnitName = function(unit) assert(unit == "player"); return world.name, "Test Realm" end,
        GetNormalizedRealmName = function() return "TestRealm" end,
        GetRealmName = function() return "Test Realm" end,
        IsLoggedIn = function() return true end,
        Enum = {
            RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1 },
            SendAddonMessageResult = { Success = 0, InvalidChatType = 1 },
        },
        JoinTemporaryChannel = function(name)
            if world.joinEnabled then world.channels[name] = 1 end
        end,
        LeaveChannelByName = function(name) world.channels[name] = nil end,
        GetChannelName = function(name) return world.channels[name] or 0 end,
        C_ChatInfo = {
            RegisterAddonMessagePrefix = function() return 0 end,
            SendAddonMessage = function(prefix, wire, distribution, target)
                assert(prefix == "LockInToolsData" and distribution == "CHANNEL" and target == "1")
                local packet = { at = world.now, wire = wire, payload = wire:match("^1|position|(.*)$") }
                world.sendAttempts[#world.sendAttempts + 1] = packet
                if world.sendThrows then error("Native send failed") end
                if world.sendResult == 1 then return 1 end
                world.sent[#world.sent + 1] = packet
                return 0
            end,
        },
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
    world.notificationErrors = loadNotifications(addon, environment)
    function addon:RefreshOptions() end
    function addon:RefreshPositionPins() world.refreshes = world.refreshes + 1 end
    addon:RegisterNotification("POSITIONS_CHANGED", function()
        if addon.RefreshPositionPins then addon:RefreshPositionPins() end
        if addon.RefreshOptions then addon:RefreshOptions() end
        if addon.RefreshOverview then addon:RefreshOverview() end
    end)
    addon:RegisterNotification("POSITION_VISIBILITY_CHANGED", function()
        if addon.RefreshPositionPins then addon:RefreshPositionPins() end
    end)
    addon:RegisterNotification("POSITION_CONTACT_CHANGED", function()
        if addon.RefreshOverview then addon:RefreshOverview() end
    end)
    for _, file in ipairs({ "Crypto.lua", "Group.lua", "DataChannel.lua", "Data.lua", "DataStatus.lua", "Position.lua" }) do
        loadModule(file, addon, environment)
    end
    if prepare then prepare(world, addon, environment) end
    addon:InitializeGroup()
    addon:InitializeData()
    -- Keep this suite focused on position behavior. Full native snapshot exchange
    -- is covered in data.lua; class callbacks are exercised directly below.
    function addon:RegisterDataStatusProvider(name, collect, receive)
        assert(name == "player-class")
        world.classProvider = { collect = collect, receive = receive }
        return true
    end
    addon:InitializePositions()
    function world:class(sender, class)
        self.classProvider.receive(sender, { class = class })
    end
    -- Test convenience adapter: all shared-data receives still enter through
    -- the native event path with WoW's prefix and distribution arguments.
    function addon:ReceiveData(sender, wire)
        return self:OnDataEvent("CHAT_MSG_ADDON", self:GetDataPrefix(), wire, "CHANNEL", sender)
    end
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
        return table.concat({ "2", "P", tostring(timestamp or self.epoch + math.floor(self.now)),
            tostring(map), tostring(math.floor(x * 100000 + 0.5)),
            tostring(math.floor(y * 100000 + 0.5)) }, "|")
    end
    function world:unavailable(timestamp)
        return "2|U|" .. tostring(timestamp or self.epoch + math.floor(self.now))
    end
    function world:disconnect()
        self.joinEnabled = false
        local name = addon:GetGroupDataChannelName()
        self.channels[name] = nil
        if addon.ready then addon:OnDataEvent("CHANNEL_LEFT", 1, name) end
    end
    function world:connect()
        if addon:IsDataConnected() then self:disconnect() end
        self.joinEnabled = true
        local name = addon:GetGroupDataChannelName()
        if addon.ready then addon:JoinDataChannel(true)
        elseif name then self.channels[name] = 1 end
    end
    return addon, world
end

local function fields(payload)
    local result = {}
    for value in (payload .. "|"):gmatch("([^|]*)|") do result[#result + 1] = value end
    return result
end

-- Existing profiles gain disabled sharing, retention and visible icons without changing group/schema data.
local addon, world = newAddon()
local fingerprint = addon:GetGroupFingerprint()
assert(addon.db.schemaVersion == 3 and addon.db.group.secret == "otter-4827")
assert(addon.db.position.sharing == false and addon.db.position.keepLastKnown == true)
assert(addon:GetShowPlayerIcons() == true and addon.db.position.showPlayerIcons == true)
assert(addon.db.position.showTrails == nil and addon.db.position.trailLength == nil,
    "New profiles do not create retired movement-trail preferences")
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
assert(#packet == 6 and packet[1] == "2" and packet[2] == "P"
    and tonumber(packet[3]) == world.epoch + 22 and tonumber(packet[4]) == 37
    and packet[5] == "25000" and packet[6] == "75000")
world.x = 0.5
world:advance(2)
assert(#world.sent == 2 and world.sent[2].at - world.sent[1].at == 2)
assert(fields(world.sent[2].payload)[5] == "50000")

-- Icon visibility persists independently and rejects invalid or read-only preference changes.
do
    local display, clock = newAddon()
    assert(display:SetShowPlayerIcons(false))
    local restored = newAddon(copy(display.db))
    assert(restored:GetShowPlayerIcons() == false)
    local before = copy(display.db)
    assert(not display:SetShowPlayerIcons("false"))
    display.savedDataReadOnly = true
    assert(not display:SetShowPlayerIcons(true) and equal(display.db, before))
    local invalid = copy(before)
    invalid.position.showPlayerIcons = "false"
    assert(newAddon(invalid):GetShowPlayerIcons() == true)
end
-- Active preferences preserve retired values in both writable and read-only saved data.
for _, readOnly in ipairs({ false, true }) do
    local profile = copy(addon.db)
    profile.position.showTrails, profile.position.trailLength = "legacy-trails", "legacy-length"
    local restored = newAddon(profile, readOnly)
    assert(restored:SetPositionSharing(true) == not readOnly)
    assert(restored:SetShowPlayerIcons(false) == not readOnly)
    assert(restored:SetPositionRetention(false) == not readOnly)
    assert(profile.position.showTrails == "legacy-trails" and profile.position.trailLength == "legacy-length")
end
-- Incoming updates use the actual sender and replace only an older valid position.
assert(addon:ReceiveData("Friend-Test Realm", "1|position|" .. world:position(37, 0.4, 0.6)),
    "The shared data router delivers position messages to the registered receiver")
local friend = assert(addon:GetSharedPositions()["friend-testrealm"])
assert(friend.name == "Friend-Test Realm" and friend.map == 37 and friend.x == 0.4 and friend.y == 0.6)
addon:ReceivePosition("Self", world:position(37, 0.2, 0.3))
assert(addon:GetSharedPositions()["self-testrealm"] == nil)
local incomingStamp = world.epoch + world.now
-- Exercise protocol version, shape, range and canonical-number rejection once each.
for _, malformed in ipairs({
    "1|P|2000000031|37|0.9|0.1", "2|P|2000000031|37|90000",
    "2|P|2000000031|37|100001|10000", "2|P|2000000031|0|90000|10000",
    "2|U|not-a-time", "2|U|2000000031|extra", "2|C|2000000031|MAGE",
    "2|P|02000000031|37|90000|10000", "2|P|2000000031|37|9e4|10000",
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

-- A disconnected feature sends only its current position after recovery.
world:disconnect()
world:advance(20)
assert(#world.sent == 2)
world.x = 0.65
world:connect()
world:advance(2)
assert(#world.sent == 3 and fields(world.sent[3].payload)[5] == "65000")
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

-- Legacy bare names are qualified from their saved IDs before login realm APIs are ready.
do
    local legacy = copy(saved)
    legacy.position.peers["friend-testrealm"].name = "Friend"
    legacy.position.peers["self-otherrealm"] = {
        name = "Self", map = 38, x = 0.1, y = 0.2, stamp = world.epoch,
        class = "DRUID", positionStamp = world.epoch - 5,
    }
    local restored, clock = newAddon(copy(legacy), false, function(_, _, environment)
        environment.GetNormalizedRealmName = function() return nil end
    end)
    local friend = assert(restored.positionState.peers["friend-testrealm"])
    assert(friend.name == "Friend-testrealm" and friend.x == retainedX and not friend.online)
    local other = assert(restored.positionState.peers["self-otherrealm"])
    assert(other.name == "Self-otherrealm" and other.class == "DRUID"
        and other.positionStamp == world.epoch - 5 and not other.positionAvailable)
    clock.environment.GetNormalizedRealmName = function() return "TestRealm" end
    clock:login()
    local again, againClock = newAddon(copy(restored.db))
    againClock:login()
    assert(again:GetSharedPositions()["friend-testrealm"].name == "Friend-testrealm"
        and again:GetSharedPositions()["self-otherrealm"].x == 0.1)
    for _, invalid in ipairs({ { "friend-testrealm", "Other" }, { "Friend-testrealm", "Friend" },
        { "friend", "Friend" }, { "friend-testrealm", "Friend-OtherRealm" } }) do
        local profile = copy(legacy)
        local peer = copy(profile.position.peers["friend-testrealm"])
        peer.name = invalid[2]
        profile.position.peers = { [invalid[1]] = peer }
        local rejected = newAddon(profile)
        assert(next(rejected.positionState.peers) == nil and next(profile.position.peers) == nil)
    end
end
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
world.joinEnabled = false
addon:SetGroupSecret("other-group")
assert(next(addon:GetSharedPositions()) == nil, "Switching immediately hides old locations")
world:advance(0)
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
assert(not addon:SetShowPlayerIcons(false))
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

-- Unchanged serialized coordinates stay suppressed; only movement sends separate packets.
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
    assert(#clock.sent == 1, "Position has no separate idle heartbeat")
    clock.x = 0.2500001
    clock:advance(2)
    assert(#clock.sent == 1, "Changes smaller than the transmitted precision remain suppressed")
    clock.x = 0.25002
    clock:advance(2)
    assert(#clock.sent == 2 and fields(clock.sent[2].payload)[5] == "25002")
    clock.map = 38
    clock:advance(2)
    assert(#clock.sent == 3 and tonumber(fields(clock.sent[3].payload)[4]) == 38,
        "Changing map must send even when coordinates match")
    clock:advance(60)
    assert(#clock.sent == 3, "Stationary samples remain suppressed beyond the peer timeout")
    clock.y = 0.6
    clock:advance(2)
    assert(#clock.sent == 4 and fields(clock.sent[4].payload)[6] == "60000")

    stationary:SetPositionSharing(false)
    stationary:SetPositionSharing(true)
    clock:advance(2)
    assert(#clock.sent == 5, "Re-enabling sharing announces the current location on the next sample")
    clock:connect()
    clock:advance(2)
    assert(#clock.sent == 6, "A replacement connection must not inherit suppression from the old one")
end

-- Integer wire coordinates retain normalized Lua/saved values at the scale boundaries.
do
    local scaled, clock = newAddon()
    clock:login()
    clock:connect()
    scaled:SetPositionSharing(true)
    clock.map, clock.x, clock.y = 1000000, 0, 1
    clock:advance(2)
    assert(clock.sent[1].payload == "2|P|2000000002|1000000|0|100000",
        "Coordinate endpoints and the largest supported map use canonical integer values")
    assert(scaled:ReceivePosition("Friend", clock.sent[1].payload))
    local peer = assert(scaled:GetSharedPositions()["friend-testrealm"])
    assert(peer.x == 0 and peer.y == 1 and scaled.db.position.peers["friend-testrealm"].y == 1,
        "Wire scaling never leaks into Lua consumers or persisted locations")
    clock.map, clock.x, clock.y = 1, 0.000005, 0.1234549
    clock:advance(2)
    assert(clock.sent[2].payload == "2|P|2000000004|1|1|12345",
        "Coordinates round to the nearest 1/100000, including a half-step upwards")
    assert(scaled:ReceivePosition("Friend", clock.sent[2].payload))
    peer = scaled:GetSharedPositions()["friend-testrealm"]
    local stored = scaled.db.position.peers["friend-testrealm"]
    assert(peer.x == 0.00001 and peer.y == 0.12345 and stored.x == peer.x and stored.y == peer.y)
    local restored, restoredClock = newAddon(copy(scaled.db))
    restoredClock:login()
    peer = restored:GetSharedPositions()["friend-testrealm"]
    assert(peer.x == 0.00001 and peer.y == 0.12345,
        "A reload preserves normalized values without scaling the saved data a second time")
    clock.x, clock.y = 0.0000051, 0.1234548
    clock:advance(2)
    assert(#clock.sent == 2, "Changes inside the same quantized coordinate remain suppressed")
end

-- Unavailable data is also deduplicated; recovery sends at the next sample.
do
    local unavailable, clock = newAddon()
    clock:login()
    clock:connect()
    unavailable:SetPositionSharing(true)
    clock:advance(2)
    clock.map = nil
    clock:advance(2)
    assert(#clock.sent == 2 and fields(clock.sent[2].payload)[2] == "U")
    clock:advance(60)
    assert(#clock.sent == 2, "Repeated unavailable samples have no separate heartbeat")
    clock.map = 37
    clock:advance(2)
    assert(#clock.sent == 3 and fields(clock.sent[3].payload)[2] == "P",
        "Valid coordinates resume immediately even when they match the last known position")
end

-- Acceptance alone advances suppression; failures retry current data without a queue.
do
    local retrying, clock = newAddon()
    local attempts = clock.sendAttempts
    clock:connect()
    clock:login()
    retrying:SetPositionSharing(true)
    clock:advance(2)
    clock.sendResult, clock.x = 1, 0.6
    clock:advance(2)
    assert(#attempts == 2 and #clock.sent == 1)
    clock.sendResult, clock.x = nil, 0.25
    clock:advance(2)
    assert(#attempts == 3 and fields(attempts[3].payload)[5] == "25000",
        "Retry current data even when movement returns to the last accepted position")
    clock.sendThrows, clock.x = true, 0.8
    clock:advance(2)
    assert(#attempts == 4 and #clock.sent == 2)
    clock.sendThrows, clock.x = false, 0.9
    clock:advance(2)
    assert(#attempts == 5 and fields(attempts[5].payload)[5] == "90000")
    clock:advance(60)
    assert(#attempts == 5, "A successful retry suppresses further unchanged samples")
end

-- Each peer expires independently; unavailable updates restore presence without replacing retained coordinates.
do
    local presence, clock = newAddon()
    clock:login()
    presence:SetPositionSharing(true)
    assert(presence:ReceivePosition("Alice", clock:position(37, 0.3, 0.7)))
    clock:advance(30)
    assert(presence:ReceivePosition("Bob", clock:position(37, 0.4, 0.6)))
    clock:advance(30)
    assert(not presence:GetSharedPositions()["alice-testrealm"].online
        and presence:GetSharedPositions()["bob-testrealm"].online)
    assert(not presence:ReceivePosition("Alice", clock:position(37, 0.9, 0.1, clock.epoch)))
    assert(presence:ReceivePosition("Alice", clock:unavailable()))
    local peer = presence:GetSharedPositions()["alice-testrealm"]
    assert(peer.online and peer.x == 0.3)
    local restored, reloadClock = newAddon(copy(presence.db))
    reloadClock:login()
    assert(not restored:GetSharedPositions()["alice-testrealm"].online)
    reloadClock:advance(120)
    assert(restored:GetSharedPositions()["alice-testrealm"].x == 0.3)
end
-- Status-position refreshes keep stationary live-only pins alive beyond 60 seconds in total.
do
    local live, clock = newAddon()
    clock:login()
    live:SetPositionSharing(true)
    live:SetPositionRetention(false)
    assert(live:ReceivePosition("Friend", clock:position(37, 0.3, 0.7)))
    for _ = 1, 3 do
        clock:advance(30)
        assert(live:ReceivePositionSnapshot("Friend", "P,37,30000,70000", clock.epoch + clock.now))
        assert(live:GetSharedPositions()["friend-testrealm"].online == true)
    end
    clock:advance(59)
    assert(live:GetSharedPositions()["friend-testrealm"])
    clock:advance(1)
    assert(next(live:GetSharedPositions()) == nil, "Live-only pins disappear after 60 seconds without movement or a status refresh")
end

-- Regional native full names supplement legacy self detection and safely fall back when unavailable.
do
    local regional, clock = newAddon()
    clock.environment.UnitFullName = function() return "Dar", "Mara" end
    clock.environment.NameUtil = { GetUnmodifiedUnitFullName = function() return "Dar Mara" end }
    clock:login()
    regional:SetPositionSharing(true)
    assert(not regional:ReceivePosition("Dar Mara-Test Realm", clock:position(37, 0.3, 0.7)))
    assert(not regional:ReceivePosition("Dar-Mara", clock:position(37, 0.3, 0.7)))
    assert(regional:ReceivePosition("Friend-Test Realm", clock:position(37, 0.4, 0.6)))
    assert(regional.db.position.peers["friend-testrealm"].name == "Friend-Test Realm")
    clock.environment.NameUtil.GetUnmodifiedUnitFullName = function() error("Native name unavailable") end
    assert(regional:ReceivePosition("Other", clock:position(37, 0.5, 0.5)))
    assert(not regional:ReceivePosition("Dar-Mara", clock:position(37, 0.3, 0.7)))
    local secretName = setmetatable({}, { __tostring = function() error("Secret name must not be inspected") end })
    clock.environment.issecretvalue = function(value) return value == secretName end
    clock.environment.NameUtil.GetUnmodifiedUnitFullName = function() return secretName end
    assert(regional:ReceivePosition("Another", clock:position(37, 0.6, 0.4)))
end
-- Hiding icons preserves sharing, movement broadcasts and incoming retained metadata.
do
    local display, clock = newAddon()
    clock:login()
    clock:connect()
    display:SetPositionSharing(true)
    clock:advance(2)
    assert(display:SetShowPlayerIcons(false) and display:IsDataConnected())
    clock.x = 0.6
    clock:advance(2)
    assert(#clock.sent == 2 and fields(clock.sent[2].payload)[5] == "60000")
    assert(display:ReceivePosition("Friend", clock:position(37, 0.4, 0.6)))
    clock:class("Friend", "PRIEST")
    local peer = assert(display:GetSharedPositions()["friend-testrealm"])
    assert(peer.class == "PRIEST" and display.db.position.peers["friend-testrealm"].x == 0.4)
    assert(display:SetShowPlayerIcons(true) and display:GetSharedPositions()["friend-testrealm"] == peer)
    clock:advance(2)
    assert(#clock.sent == 2, "Changing visibility must not resend stationary coordinates")
end
-- Class collection stays independent of coordinate opt-in and rejects unavailable/secret native values.
do
    local classes, clock = newAddon()
    clock.environment.UnitClass = function() return "Localized mage", "MAGE" end
    assert(clock.classProvider.collect().class == "MAGE" and clock.samples == 0
        and not classes.db.position.sharing)
    clock.environment.UnitClass = function() return "Localized", "UNKNOWN" end
    assert(clock.classProvider.collect() == nil)
    local secret = {}
    clock.environment.UnitClass = function() return "Localized", secret end
    clock.environment.issecretvalue = function(value) return value == secret end
    assert(clock.classProvider.collect() == nil)
end
-- Class metadata can precede positions, but never renews coordinate timestamps or survives a group change.
do
    local classes, clock = newAddon()
    clock:login()
    clock:class("Friend", "MAGE")
    assert(next(classes.positionState.peers) == nil and next(classes.db.position.peers) == nil)
    classes:SetPositionSharing(true)
    assert(classes:ReceivePosition("Friend", clock:position(37, 0.3, 0.7)))
    local peer = assert(classes:GetSharedPositions()["friend-testrealm"])
    assert(peer.class == "MAGE")
    local stamp, received = peer.stamp, peer.lastReceived
    clock:class("Friend", "unknown")
    assert(peer.class == "MAGE")
    clock:class("Friend", "DRUID")
    assert(peer.class == "DRUID" and peer.stamp == stamp and peer.lastReceived == received)
    classes:SetPositionSharing(false)
    clock:class("Friend", "SHAMAN")
    assert(classes.db.position.peers["friend-testrealm"].class == "SHAMAN" and peer.stamp == stamp)
    classes:SetPositionSharing(true)
    classes:SetGroupSecret("class-isolation-group")
    clock:advance(0)
    assert(next(classes.positionState.classes) == nil and next(classes.db.position.peers) == nil)
    assert(classes:ReceivePosition("Friend", clock:position(37, 0.2, 0.8)))
    assert(classes:GetSharedPositions()["friend-testrealm"].class == nil)
end
-- Optional saved classes survive reload without extending location lifetime or discarding legacy coordinates.
do
    local classes, clock = newAddon()
    clock:login()
    classes:SetPositionSharing(true)
    assert(classes:ReceivePosition("Friend", clock:position(37, 0.3, 0.7)))
    clock:advance(30)
    clock:class("Friend", "HUNTER")
    clock:advance(30)
    assert(not classes:GetSharedPositions()["friend-testrealm"].online)
    local snapshot = copy(classes.db)
    local restored, reloadClock = newAddon(copy(snapshot))
    reloadClock:login()
    assert(restored:GetSharedPositions()["friend-testrealm"].class == "HUNTER"
        and not restored:GetSharedPositions()["friend-testrealm"].online)
    snapshot.position.peers["friend-testrealm"].class = "UNKNOWN"
    local legacy, legacyClock = newAddon(snapshot)
    legacyClock:login()
    assert(legacy:GetSharedPositions()["friend-testrealm"].x == 0.3
        and legacy:GetSharedPositions()["friend-testrealm"].class == nil)
end
-- Unavailable updates preserve coordinate age across reloads; legacy optional ages never become invented timestamps.
do
    local locations, clock = newAddon()
    clock:login()
    locations:SetPositionSharing(true)
    assert(locations:ReceivePosition("Friend", clock:position(37, 0.3, 0.7)))
    clock:advance(10)
    assert(locations:ReceivePosition("Friend", clock:unavailable()))
    local peer = assert(locations:GetSharedPositions()["friend-testrealm"])
    assert(peer.stamp == clock.epoch + 10 and peer.positionStamp == clock.epoch
        and not peer.positionAvailable and peer.online and peer.x == 0.3)
    local snapshot = copy(locations.db)
    local restored, reloadClock = newAddon(copy(snapshot))
    reloadClock:login()
    local restoredPeer = assert(restored:GetSharedPositions()["friend-testrealm"])
    assert(restoredPeer.positionStamp == clock.epoch and not restoredPeer.positionAvailable and not restoredPeer.online)
    for _, invalidStamp in ipairs({ "2000000000", clock.epoch + 12 }) do
        local invalid = copy(snapshot)
        invalid.position.peers["friend-testrealm"].positionStamp = invalidStamp
        local legacy, legacyClock = newAddon(invalid)
        legacyClock:login()
        assert(legacy:GetSharedPositions()["friend-testrealm"].x == 0.3
            and legacy:GetSharedPositions()["friend-testrealm"].positionStamp == nil)
    end
    snapshot.position.peers["friend-testrealm"].positionStamp = nil
    local legacy, legacyClock = newAddon(snapshot)
    legacyClock:login()
    assert(legacy:GetSharedPositions()["friend-testrealm"].positionStamp == nil)
    clock:advance(1)
    assert(locations:ReceivePosition("Friend", clock:position(37, 0.4, 0.6)))
    assert(locations:GetSharedPositions()["friend-testrealm"].positionStamp == clock.epoch + 11
        and locations:GetSharedPositions()["friend-testrealm"].positionAvailable)
end
-- Status and movement share one fresh sample per timestamp; only an accepted public snapshot suppresses movement.
do
    local shared, clock = newAddon()
    clock:login()
    clock:connect()
    assert(shared:GetPositionSnapshot() == nil and clock.samples == 0)
    shared:SetPositionSharing(true)
    local snapshot, stamp = shared:GetPositionSnapshot(clock.epoch)
    assert(snapshot == "P,37,25000,75000" and stamp == clock.epoch and clock.samples == 1)
    clock.x = 0.6
    shared:PositionTick()
    assert(#clock.sent == 1 and clock.samples == 1
        and clock.sent[1].payload == "2|P|2000000000|37|25000|75000")
    clock:advance(1)
    local fresh = shared:GetPositionSnapshot()
    assert(fresh == "P,37,60000,75000" and clock.samples == 2)
    shared:PositionSnapshotSent(fresh)
    clock:advance(1)
    assert(#clock.sent == 1)
    clock.map = nil
    clock:advance(1)
    local unavailable = shared:GetPositionSnapshot()
    assert(unavailable == "U")
    shared:PositionSnapshotSent(unavailable)
    clock:advance(1)
    assert(#clock.sent == 1)
    shared:SetPositionSharing(false)
    shared:SetPositionSharing(true)
    clock.map = 38
    assert(shared:GetPositionSnapshot() == "P,38,60000,75000")
end
-- Timestamp reuse cannot freeze the sampling cache when the server clock moves backwards.
do
    local shared, clock = newAddon()
    clock:login()
    clock:connect()
    shared:SetPositionSharing(true)
    local first, stamp = shared:GetPositionSnapshot(clock.epoch)
    assert(first == "P,37,25000,75000" and stamp == clock.epoch)
    clock.epoch, clock.x = clock.epoch - 10, 0.6
    local rolledBack, rollbackStamp = shared:GetPositionSnapshot(clock.epoch)
    assert(rolledBack == "P,37,60000,75000" and rollbackStamp == clock.epoch and clock.samples == 2,
        "Sampling follows the actual raw server second rather than a clamped status timestamp")
    clock.x = 0.9
    shared:PositionTick()
    assert(clock.sent[1].payload == "2|P|1999999990|37|60000|75000" and clock.samples == 2,
        "Movement and an attachment reuse the identical sample even after clock rollback")
    clock:advance(1)
    local recovered, recoveredStamp = shared:GetPositionSnapshot()
    assert(recovered == "P,37,90000,75000" and recoveredStamp == clock.epoch + 1 and clock.samples == 3,
        "The next raw server second refreshes coordinates without waiting for the old clock value")
    local samples = clock.samples
    for _, invalid in ipairs({ -1, 10000000000, "1999999991" }) do
        local invalidSnapshot, invalidStamp = shared:GetPositionSnapshot(invalid)
        assert(invalidSnapshot == nil and invalidStamp == nil and clock.samples == samples,
            "Invalid inherited sample timestamps cannot be formatted or refresh the coordinate cache")
    end
end

-- Compact status positions use the existing movement ordering, availability and opt-in rules.
do
    local shared, clock = newAddon()
    clock:login()
    shared:SetPositionSharing(true)
    assert(shared:ReceivePositionSnapshot("Friend", "P,37,30000,70000", clock.epoch))
    assert(shared:ReceivePosition("Friend", clock:position(37, 0.4, 0.6, clock.epoch + 2)))
    local peer = assert(shared:GetSharedPositions()["friend-testrealm"])
    assert(not shared:ReceivePositionSnapshot("Friend", "P,37,10000,90000", clock.epoch + 1)
        and not shared:ReceivePositionSnapshot("Friend", "P,37,10000,90000", clock.epoch + 2)
        and peer.x == 0.4, "A delayed or duplicate status attachment cannot overwrite newer movement")
    assert(shared:ReceivePositionSnapshot("Friend", "U", clock.epoch + 3))
    assert(peer.x == 0.4 and peer.positionStamp == clock.epoch + 2 and not peer.positionAvailable,
        "An unavailable attachment preserves the last known coordinates and their acquisition time")
    assert(not shared:ReceivePosition("Friend", clock:position(37, 0.8, 0.2, clock.epoch + 2)),
        "A status attachment also advances the ordering used by separate movement packets")
    for _, malformed in ipairs({
        "C,MAGE", "P,37,30000", "P,37,100001,70000", "P,37,-1,70000",
        "P,37,0.3,0.7", "P,37,30000,70000,extra", "U,extra",
        "P|37|30000|70000", "P,2000000004,37,0.30000,0.70000", "U,2000000004",
        "P,037,30000,70000", "P,37,030000,70000", "P,37,+30000,70000",
        "P,37,3e4,70000", "P,37,30000,70000.0", "P,1000001,30000,70000",
    }) do
        assert(not shared:ReceivePositionSnapshot("Friend", malformed, clock.epoch + 4))
    end
    assert(not shared:ReceivePositionSnapshot("Friend", nil, clock.epoch + 4))
    for _, badStamp in ipairs({ -1, 1.5, "2000000004" }) do
        assert(not shared:ReceivePositionSnapshot("Friend", "P,37,30000,70000", badStamp),
            "An attachment cannot supply or coerce its own status timestamp")
    end
    assert(not shared:ReceivePositionSnapshot("Friend", "P,37,30000,70000"))
    assert(not shared:ReceivePositionSnapshot("Self", "P,37,30000,70000", clock.epoch + 4))
    shared:SetPositionSharing(false)
    assert(not shared:ReceivePositionSnapshot("Friend", "P,37,30000,70000", clock.epoch + 4)
        and shared.positionState.peers["friend-testrealm"] == peer,
        "Status attachments cannot bypass opt-in reception")
    shared:SetPositionSharing(true)
    shared.savedDataReadOnly = true
    assert(shared:GetPositionSnapshot() == nil
        and not shared:ReceivePositionSnapshot("Friend", "P,37,30000,70000", clock.epoch + 4),
        "Status attachments preserve newer-schema read-only behavior")
end

print("Position tests passed.")
