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

-- Display preferences are saved independently, with invalid data defaulting to visible icons.
do
    for _, invalid in ipairs({ "false", 0, {} }) do
        local profile = copy(addon.db)
        profile.position.showPlayerIcons = invalid
        local normalized = newAddon(profile)
        assert(normalized:GetShowPlayerIcons() == true and normalized.db.position.showPlayerIcons == true)
    end
    local display, clock = newAddon()
    assert(display:SetShowPlayerIcons(false))
    local restored = newAddon(copy(display.db))
    assert(restored:GetShowPlayerIcons() == false and restored.db.position.showPlayerIcons == false,
        "An explicitly hidden icon preference must survive a reload")
    local before, refreshes = copy(display.db), clock.refreshes
    local changed, problem = display:SetShowPlayerIcons("false")
    assert(changed == false and type(problem) == "string")
    display.initialized = false
    changed, problem = display:SetShowPlayerIcons(true)
    assert(changed == false and type(problem) == "string")
    display.initialized = true
    local state = display.positionState
    display.positionState = nil
    changed, problem = display:SetShowPlayerIcons(true)
    assert(changed == false and type(problem) == "string")
    display.positionState, display.savedDataReadOnly = state, true
    changed, problem = display:SetShowPlayerIcons(true)
    assert(changed == false and type(problem) == "string")
    assert(equal(display.db, before) and clock.refreshes == refreshes,
        "Invalid, uninitialized and read-only changes cannot save preferences or refresh pins")
    display.savedDataReadOnly, display.RefreshPositionPins = nil, nil
    assert(display:SetShowPlayerIcons(true) and display:GetShowPlayerIcons() == true,
        "The display setting remains available before the map provider is loaded")
end

-- Retired movement-trail preferences stay untouched in existing saved data.
do
    for _, legacy in ipairs({
        { showTrails = true, trailLength = 10 },
        { showTrails = false, trailLength = 30 },
        { showTrails = "false", trailLength = "10" },
        { showTrails = {}, trailLength = {} },
    }) do
        for _, readOnly in ipairs({ false, true }) do
            local profile = copy(addon.db)
            profile.position.showTrails, profile.position.trailLength = legacy.showTrails, legacy.trailLength
            local restored = newAddon(profile, readOnly)
            assert(restored:SetPositionSharing(true) == not readOnly)
            assert(restored:SetShowPlayerIcons(false) == not readOnly)
            assert(restored:SetPositionRetention(false) == not readOnly)
            assert(profile.position.showTrails == legacy.showTrails
                and profile.position.trailLength == legacy.trailLength,
                "Initialization and active preferences preserve retired values, including malformed/read-only data")
        end
    end
end

-- Incoming updates use the actual sender and replace only an older valid position.
assert(addon:ReceiveData("Friend-Test Realm", "1|position|" .. world:position(37, 0.4, 0.6)),
    "The shared data router delivers position messages to the registered receiver")
local friend = assert(addon:GetSharedPositions()["friend-testrealm"])
assert(friend.name == "Friend-Test Realm" and friend.map == 37 and friend.x == 0.4 and friend.y == 0.6)
addon:ReceivePosition("Self", world:position(37, 0.2, 0.3))
assert(addon:GetSharedPositions()["self-testrealm"] == nil)
local incomingStamp = world.epoch + world.now
for _, malformed in ipairs({
    "1|P|2000000031|37|0.9|0.1", "1|U|2000000031",
    "2|P|2000000031|37|90000|10000|extra", "2|P|2000000031|37|90000",
    "2|P|2000000031|37|100001|10000", "2|P|2000000031|37|-1|10000",
    "2|P|2000000031|0|90000|10000", "2|P|2000000031|37|unknown|10000",
    "2|U|not-a-time", "2|X|2000000031", "2|C|2000000031|MAGE",
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
world:disconnect()
assert(addon:GetPositionStatusText():find("Waiting", 1, true), "An unwired feature must report that it is waiting for a connection")
world:advance(20)
assert(#world.sent == 2)
world.x = 0.65
world:connect()
world:advance(2)
assert(#world.sent == 3 and fields(world.sent[3].payload)[5] == "65000",
    "Reconnect sends only the next current sample")
local attempts = #world.sendAttempts
world.sendResult = 1
world.x = 0.7
world:advance(4)
assert(#world.sendAttempts == attempts + 2 and #world.sent == 3)
assert(addon:GetPositionStatusText():find("unavailable", 1, true))
world.sendResult = nil
world:advance(2)
assert(#world.sent == 4, "Failed sends must not be replayed after transport recovery")

-- Unavailable coordinates produce an explicit unavailable sample, never a fake position.
world.map = nil
world:advance(2)
packet = fields(world.sent[#world.sent].payload)
assert(#packet == 3 and packet[1] == "2" and packet[2] == "U")
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

-- Saved identities restore independently of login realm information and remain qualified on future reloads.
do
    local retained, clock = newAddon()
    clock:login()
    retained:SetPositionSharing(true)
    assert(retained:ReceivePosition("Friend", clock:position(37, 0.3, 0.7)))
    clock:class("Friend", "MAGE")
    assert(retained:GetSharedPositions()["friend-testrealm"].name == "Friend"
        and retained.db.position.peers["friend-testrealm"].name == "Friend-testrealm",
        "New retained saves qualify bare senders without changing live display names")
    local legacy = copy(retained.db)
    legacy.position.peers["friend-testrealm"].name = "Friend"
    legacy.position.peers["self-otherrealm"] = {
        name = "Self", map = 38, x = 0.1, y = 0.2, stamp = clock.epoch + 10,
        class = "DRUID", positionStamp = clock.epoch + 5,
    }
    legacy.position.peers["qualified-otherrealm"] = {
        name = "Qualified-Other Realm", map = 39, x = 0.4, y = 0.6,
        stamp = clock.epoch + 20, positionStamp = clock.epoch + 15,
    }
    for _, startupRealm in ipairs({ false, "", "DifferentRealm" }) do
        local restored, restoredClock = newAddon(copy(legacy), false, function(_, _, environment)
            environment.GetNormalizedRealmName = function() return startupRealm or nil end
        end)
        local restoredPeer = assert(restored.positionState.peers["friend-testrealm"])
        assert(restoredPeer.name == "Friend-testrealm" and restoredPeer.map == 37
            and restoredPeer.x == 0.3 and restoredPeer.y == 0.7 and restoredPeer.stamp == clock.epoch
            and restoredPeer.positionStamp == clock.epoch and restoredPeer.class == "MAGE"
            and restoredPeer.online == false and restoredPeer.positionAvailable == false,
            "Legacy positions restore with their saved identity, coordinates, ages and class before login")
        assert(restored.positionState.latest["friend-testrealm"] == clock.epoch
            and restored.positionState.classes["friend-testrealm"] == "MAGE"
            and restored.positionState.peers["self-otherrealm"].name == "Self-otherrealm"
            and restored.positionState.peers["qualified-otherrealm"].name == "Qualified-Other Realm",
            "Saved realms disambiguate names across realms while preserving qualified display spelling")
        assert(restored.db.position.peers["friend-testrealm"].name == "Friend-testrealm"
            and restored.db.position.peers["self-otherrealm"].name == "Self-otherrealm",
            "Writable legacy saves gain qualified names without changing their canonical keys")
        restoredClock.environment.GetNormalizedRealmName = function() return "TestRealm" end
        restoredClock:login()
        restoredClock:advance(120)
        assert(restored:GetSharedPositions()["friend-testrealm"] == restoredPeer
            and restored:GetSharedPositions()["self-otherrealm"].online == false,
            "Restored offline players remain available after login and expiry checks")
        local again, againClock = newAddon(copy(restored.db), false, function(_, _, environment)
            environment.GetNormalizedRealmName = function() return nil end
        end)
        againClock.environment.GetNormalizedRealmName = function() return "AnotherRealm" end
        againClock:login()
        assert(again:GetSharedPositions()["friend-testrealm"].name == "Friend-testrealm"
            and again:GetSharedPositions()["self-otherrealm"].name == "Self-otherrealm"
            and again:GetSharedPositions()["qualified-otherrealm"].x == 0.4,
            "A second reload keeps all qualified retained identities even on another realm")
    end

    for _, invalid in ipairs({
        { "friend-testrealm", "Other" }, { "friend-testrealm", "Friend-OtherRealm" },
        { "Friend-testrealm", "Friend" }, { "friend-TestRealm", "Friend" },
        { "friend-test realm", "Friend" }, { "friend", "Friend" },
        { "friend-", "Friend" }, { "friend-testrealm", "Friend-" },
        { "friend-testrealm", false }, { "friend-testrealm", 12 },
        { 12, "Friend" },
    }) do
        local profile = copy(legacy)
        local peer = copy(profile.position.peers["friend-testrealm"])
        peer.name = invalid[2]
        profile.position.peers = { [invalid[1]] = peer }
        local rejected = newAddon(profile)
        assert(next(rejected.positionState.peers) == nil and next(profile.position.peers) == nil,
            "Malformed or mismatching saved names and canonical IDs cannot invent a retained identity")
    end

    local readOnlyProfile = copy(legacy)
    local before = copy(readOnlyProfile)
    local readOnly, readOnlyClock = newAddon(readOnlyProfile, true, function(_, _, environment)
        environment.GetNormalizedRealmName = function() return nil end
    end)
    readOnlyClock.environment.GetNormalizedRealmName = function() return "TestRealm" end
    readOnlyClock:login()
    assert(equal(readOnlyProfile, before) and next(readOnly:GetSharedPositions()) == nil,
        "Legacy restoration never rewrites newer-schema read-only data or bypasses its sharing gate")
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
    assert(#attempts == 2 and retrying:GetPositionStatusText():find("unavailable", 1, true))
    clock.sendResult, clock.x = nil, 0.25
    clock:advance(2)
    assert(#attempts == 3 and fields(attempts[3].payload)[5] == "25000",
        "Retry current data even when movement returns to the last accepted position")
    clock.sendThrows, clock.x = true, 0.8
    clock:advance(2)
    assert(#attempts == 4 and retrying:GetPositionStatusText():find("unavailable", 1, true))
    clock.sendThrows, clock.x = false, 0.9
    clock:advance(2)
    assert(#attempts == 5 and fields(attempts[5].payload)[5] == "90000")
    assert(not retrying:GetPositionStatusText():find("unavailable", 1, true))
    clock:advance(60)
    assert(#attempts == 5, "A successful retry suppresses further unchanged samples")
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

-- Hiding icons keeps sampling, incoming class metadata and retention running.
do
    local display, clock = newAddon()
    clock:login()
    clock:connect()
    display:SetPositionSharing(true)
    clock:advance(2)
    assert(#clock.sent == 1)
    clock:class("Friend", "DRUID")
    assert(display:ReceivePosition("Friend", clock:position(37, 0.3, 0.7)))
    local state, timer = display.positionState, display.positionState.timer
    local sentSample, sample = state.lastSentSample, state.sample
    local generation, optionsRefreshes = state.generation, 0
    function display:RefreshOptions() optionsRefreshes = optionsRefreshes + 1 end
    local refreshes = clock.refreshes
    assert(display:SetShowPlayerIcons(false))
    assert(display:GetShowPlayerIcons() == false and clock.refreshes == refreshes + 1 and optionsRefreshes == 0)
    assert(display.db.position.sharing == true and display.db.position.keepLastKnown == true
        and display:IsDataConnected() and state.timer == timer and state.generation == generation
        and state.lastSentSample == sentSample and state.sample == sample and state.lastSendSucceeded == true,
        "Hiding icons only refreshes pins, preserving transport, timers and send state")
    clock:advance(2)
    assert(#clock.sent == 1 and clock.samples == 2,
        "Hidden icons still sample without restarting position suppression")
    clock.x = 0.6
    clock:advance(2)
    assert(#clock.sent == 2 and fields(clock.sent[2].payload)[5] == "60000",
        "Movement continues to broadcast while icons are hidden")
    assert(display:ReceivePosition("Friend", clock:position(37, 0.4, 0.6)))
    clock:class("Friend", "PRIEST")
    local peer = assert(display:GetSharedPositions()["friend-testrealm"])
    assert(peer.x == 0.4 and peer.class == "PRIEST"
        and display.db.position.peers["friend-testrealm"].x == 0.4
        and display.db.position.peers["friend-testrealm"].class == "PRIEST",
        "Hidden updates still replace runtime and retained positions and classes")
    clock:advance(60)
    assert(peer.online == false and display.db.position.peers["friend-testrealm"].x == 0.4,
        "Hidden retained peers still time out without losing their last-known location")
    local sent, samples = #clock.sent, clock.samples
    timer, generation = state.timer, state.generation
    sentSample, sample = state.lastSentSample, state.sample
    assert(display:SetShowPlayerIcons(true))
    assert(state.timer == timer and state.generation == generation and state.lastSentSample == sentSample
        and state.sample == sample and display:GetSharedPositions()["friend-testrealm"] == peer,
        "Showing icons preserves the latest peer and sampling state")
    clock:advance(2)
    assert(#clock.sent == sent and clock.samples == samples + 1,
        "Showing icons does not resend an unchanged position")
    display:SetPositionRetention(false)
    assert(display:ReceivePosition("Friend", clock:position(37, 0.5, 0.5)))
    assert(display:SetShowPlayerIcons(false))
    clock:advance(60)
    assert(next(display:GetSharedPositions()) == nil and next(display.db.position.peers) == nil,
        "Hidden non-retained peers expire normally")
end

-- Class belongs to group status even with coordinate sharing disabled or unavailable.
do
    local classes, clock = newAddon()
    clock.environment.UnitClass = function(unit)
        assert(unit == "player")
        return "Localized mage", "MAGE"
    end
    assert(clock.classProvider.collect().class == "MAGE"
        and not classes.db.position.sharing and clock.samples == 0,
        "Class collection does not depend on coordinate opt-in or sample the map")
    clock:login()
    clock:connect()
    clock.map = nil
    assert(clock.classProvider.collect().class == "MAGE")
    classes:SetPositionSharing(true)
    assert(clock.classProvider.collect().class == "MAGE")
    clock:advance(2)
    assert(#clock.sent == 1 and fields(clock.sent[1].payload)[2] == "U",
        "Unavailable coordinates use the existing position packet without a class exchange")
    clock:advance(30)
    assert(#clock.sent == 1, "Class collection adds no separate request, retry or heartbeat")
    classes:SetPositionSharing(false)
    assert(clock.classProvider.collect().class == "MAGE")
    for _, token in ipairs({ false, "UNKNOWN", "mage", "DEATHKNIGHT", 4 }) do
        clock.environment.UnitClass = token and function() return "Localized", token end or false
        assert(clock.classProvider.collect() == nil, "Unavailable or unrecognized native class is omitted")
    end
    local secret = setmetatable({}, { __tostring = function() error("Do not inspect secret classes") end })
    clock.environment.UnitClass = function() return "Localized", secret end
    clock.environment.issecretvalue = function(value) return value == secret end
    assert(clock.classProvider.collect() == nil, "Secret native class tokens are never inspected or formatted")
end

-- Accepted class snapshots update metadata without changing location freshness or presence.
do
    local classes, clock = newAddon()
    clock:login()
    clock:connect()
    local refreshed = clock.refreshes
    clock:class("Friend", "MAGE")
    assert(classes.positionState.classes["friend-testrealm"] == "MAGE"
        and next(classes.positionState.peers) == nil and next(classes.db.position.peers) == nil
        and clock.refreshes == refreshed,
        "Class received while sharing is off is cached without inventing a location")
    classes:SetPositionSharing(true)
    assert(classes:ReceivePosition("Friend", clock:position(37, 0.3, 0.7)))
    local peer = assert(classes:GetSharedPositions()["friend-testrealm"])
    assert(peer.class == "MAGE", "Later opt-in coordinates use the already known class")
    assert(classes:ReceivePosition("Friend", clock:position(37, 0.4, 0.6, clock.epoch + 1)))
    peer = classes:GetSharedPositions()["friend-testrealm"]
    local latestPosition, received = peer.stamp, peer.lastReceived
    refreshed = clock.refreshes
    for _, class in ipairs({ "MAGE", "unknown", "DEATHKNIGHT", "mage", false, 4 }) do
        clock:class("Friend", class)
    end
    clock.classProvider.receive("Friend", {})
    assert(peer.class == "MAGE" and clock.refreshes == refreshed,
        "Unchanged, unknown or missing class metadata preserves a known icon without refreshing")
    clock:class("Friend", "DRUID")
    assert(peer.class == "DRUID" and peer.stamp == latestPosition and peer.lastReceived == received
        and peer.online == true and clock.refreshes == refreshed + 1,
        "Accepted class metadata changes only the icon, never location timing or presence")
    assert(classes:ReceivePosition("Friend", clock:unavailable(clock.epoch + 2)))
    assert(peer.class == "DRUID", "Class metadata does not advance position ordering")
    latestPosition = peer.stamp
    assert(classes:ReceivePosition("After", clock:position(37, 0.5, 0.5)))
    clock:class("After", "PRIEST")
    assert(classes:GetSharedPositions()["after-testrealm"].class == "PRIEST",
        "Class snapshots can also arrive after a position")
    assert(not classes:ReceivePosition("After", "1|C|2000000001|MAGE"),
        "The retired class-only position packet is no longer accepted")
    classes:SetPositionSharing(false)
    clock:class("Friend", "SHAMAN")
    assert(peer.class == "SHAMAN" and classes.db.position.peers["friend-testrealm"].class == "SHAMAN"
        and peer.stamp == latestPosition and peer.lastReceived == received,
        "Coordinate opt-out does not disable independent class metadata or renew retained locations")
    classes:SetPositionSharing(true)
    classes:SetGroupSecret("class-isolation-group")
    clock:advance(0)
    assert(next(classes.positionState.classes) == nil and next(classes.db.position.peers) == nil)
    assert(classes:ReceivePosition("Friend", clock:position(37, 0.2, 0.8)))
    assert(classes:GetSharedPositions()["friend-testrealm"].class == nil,
        "A group switch cannot reuse the previous group's class metadata")
end

-- Retained class is optional saved data; class snapshots never extend location lifetime.
do
    local classes, clock = newAddon()
    clock:login()
    classes:SetPositionSharing(true)
    assert(classes:ReceivePosition("Friend", clock:position(37, 0.3, 0.7)))
    clock:advance(30)
    clock:class("Friend", "SHAMAN")
    clock:advance(30)
    local peer = classes:GetSharedPositions()["friend-testrealm"]
    assert(peer.online == false, "Class metadata does not delay the 60-second position timeout")
    clock:class("Friend", "HUNTER")
    assert(peer.online == false and peer.lastReceived == 0 and peer.stamp == clock.epoch,
        "Class metadata cannot revive an offline retained position")
    local snapshot = copy(classes.db)
    local restored, restoredClock = newAddon(copy(snapshot))
    restoredClock:login()
    peer = restored:GetSharedPositions()["friend-testrealm"]
    assert(peer.class == "HUNTER" and peer.online == false
        and restored.positionState.classes["friend-testrealm"] == "HUNTER"
        and restored.db.schemaVersion == snapshot.schemaVersion,
        "Class icons survive reload without a schema migration or stale online state")
    for _, invalidClass in ipairs({ false, "UNKNOWN", 4 }) do
        local old = copy(snapshot)
        old.position.peers["friend-testrealm"].class = invalidClass or nil
        local legacy, legacyClock = newAddon(old)
        legacyClock:login()
        peer = legacy:GetSharedPositions()["friend-testrealm"]
        assert(peer.x == 0.3 and peer.class == nil,
            "Missing or invalid optional saved classes never discard valid legacy coordinates")
    end
    classes:SetPositionRetention(false)
    assert(next(classes:GetSharedPositions()) == nil)
    assert(classes:ReceivePosition("Friend", clock:position(37, 0.4, 0.6)))
    clock:advance(30)
    clock:class("Friend", "MAGE")
    clock:advance(30)
    assert(next(classes:GetSharedPositions()) == nil,
        "Class-only updates cannot keep live-only coordinates past their expiry")
end

-- Overview location age follows coordinate samples, independently of peer activity.
do
    local locations, clock = newAddon()
    clock:login()
    locations:SetPositionSharing(true)
    local overviewRefreshes = 0
    function locations:RefreshOverview() overviewRefreshes = overviewRefreshes + 1 end
    assert(locations:ReceivePosition("Friend", clock:position(37, 0.3, 0.7)))
    local peer = assert(locations:GetSharedPositions()["friend-testrealm"])
    assert(peer.positionStamp == clock.epoch and peer.positionAvailable == true)
    assert(overviewRefreshes == 1, "A coordinate sample refreshes the overview")
    clock:advance(10)
    local mapRefreshes, overviewBefore = clock.refreshes, overviewRefreshes
    assert(locations:ReceivePosition("Friend", clock:unavailable()))
    assert(peer.stamp == clock.epoch + 10 and peer.positionStamp == clock.epoch
        and peer.positionAvailable == false and peer.online == true and peer.x == 0.3,
        "Unavailable activity preserves the actual coordinate age and marks its location as last known")
    assert(clock.refreshes == mapRefreshes and overviewRefreshes == overviewBefore + 1,
        "An unavailable update refreshes overview labels without changing map behavior")
    assert(not locations:ReceivePosition("Friend", clock:unavailable()))
    assert(overviewRefreshes == overviewBefore + 1, "Duplicate activity does not refresh the overview")
    clock:advance(1)
    assert(locations:ReceivePosition("Friend", clock:unavailable()))
    assert(overviewRefreshes == overviewBefore + 2 and peer.positionStamp == clock.epoch,
        "Further unavailable activity refreshes last-seen labels without renewing the coordinate age")
    clock:class("Friend", "MAGE")
    assert(peer.positionStamp == clock.epoch and peer.positionAvailable == false,
        "Class metadata cannot renew a last-known location")
    local snapshot = copy(locations.db)
    local savedPeer = assert(snapshot.position.peers["friend-testrealm"])
    assert(savedPeer.positionStamp == clock.epoch and savedPeer.stamp == clock.epoch + 11
        and savedPeer.positionAvailable == nil,
        "Persistence records coordinate age without claiming a saved location is currently available")
    local restored, restoredClock = newAddon(copy(snapshot))
    restoredClock:login()
    local restoredPeer = assert(restored:GetSharedPositions()["friend-testrealm"])
    assert(restoredPeer.positionStamp == clock.epoch and restoredPeer.positionAvailable == false
        and restoredPeer.online == false, "Reload restores a last-known location with its actual coordinate age")
    for _, invalidStamp in ipairs({ false, "2000000000", -1, clock.epoch + 12, 0 / 0, math.huge }) do
        local invalid = copy(snapshot)
        invalid.position.peers["friend-testrealm"].positionStamp = invalidStamp
        local legacy, legacyClock = newAddon(invalid)
        legacyClock:login()
        local legacyPeer = assert(legacy:GetSharedPositions()["friend-testrealm"])
        assert(legacyPeer.x == 0.3 and legacyPeer.positionStamp == nil and legacyPeer.positionAvailable == false,
            "Malformed optional coordinate ages preserve valid retained locations without guessing an age")
    end
    local oldSaved = copy(snapshot)
    oldSaved.position.peers["friend-testrealm"].positionStamp = nil
    local legacy, legacyClock = newAddon(oldSaved)
    legacyClock:login()
    local legacyPeer = assert(legacy:GetSharedPositions()["friend-testrealm"])
    assert(legacyPeer.positionStamp == nil and legacyPeer.stamp == clock.epoch + 11,
        "Legacy activity stamps cannot be used as coordinate acquisition times")
    locations:SetPositionSharing(false)
    assert(next(locations:GetSharedPositions()) == nil
        and locations.db.position.peers["friend-testrealm"].positionStamp == clock.epoch,
        "Overview location access retains the existing opt-in gate")
    locations:SetPositionSharing(true)
    clock:advance(1)
    assert(locations:ReceivePosition("Friend", clock:position(37, 0.4, 0.6)))
    peer = assert(locations:GetSharedPositions()["friend-testrealm"])
    assert(peer.positionStamp == clock.epoch + 12 and peer.positionAvailable == true,
        "A new coordinate sample restores availability and replaces its acquisition time")
    locations:SetPositionRetention(false)
    assert(next(locations.db.position.peers) == nil)
    clock:advance(1)
    assert(locations:ReceivePosition("Friend", clock:unavailable()))
    assert(next(locations:GetSharedPositions()) == nil,
        "Unavailable live-only locations are still removed immediately")
end

-- Status attachments and movement share one fresh sample per timestamp.
do
    local shared, clock = newAddon()
    clock:login()
    clock:connect()
    assert(shared:GetPositionSnapshot() == nil and clock.samples == 0,
        "Status never samples coordinates before sharing is enabled")
    shared:SetPositionSharing(true)
    local snapshot = shared:GetPositionSnapshot()
    assert(snapshot == "P,2000000000,37,0.25000,0.75000" and clock.samples == 1)
    clock.x = 0.6
    assert(shared:GetPositionSnapshot() == snapshot and clock.samples == 1,
        "Two packets with the same timestamp must contain the same coordinate sample")
    shared:PositionTick()
    assert(#clock.sent == 1 and clock.samples == 1
        and clock.sent[1].payload == "1|" .. snapshot:gsub(",", "|"),
        "The movement path reuses a status sample from the same server second")
    clock:advance(1)
    local fresh = shared:GetPositionSnapshot()
    assert(fresh == "P,2000000001,37,0.60000,0.75000" and clock.samples == 2,
        "The next server second samples current coordinates instead of repeating an old stamp")
    shared:PositionSnapshotSent(fresh)
    clock:advance(1)
    assert(#clock.sent == 1, "An accepted public status snapshot suppresses a redundant movement packet")
    clock:advance(28)
    local idle = shared:GetPositionSnapshot()
    assert(idle == "P,2000000030,37,0.60000,0.75000" and #clock.sent == 1,
        "An idle status refresh has fresh coordinates and time without a separate position heartbeat")
    clock.map = nil
    clock:advance(1)
    local unavailable = shared:GetPositionSnapshot()
    assert(unavailable == "U,2000000031")
    shared:PositionSnapshotSent(unavailable)
    clock:advance(1)
    assert(#clock.sent == 1, "A public unavailable attachment also suppresses duplicate movement data")
    shared:SetPositionSharing(false)
    assert(shared:GetPositionSnapshot() == nil)
    shared:SetPositionSharing(true)
    clock.map = 38
    assert(shared:GetPositionSnapshot() == "P,2000000032,38,0.60000,0.75000",
        "Sharing lifecycle resets discard the cached sample even within the same server second")

    local replyOnly, replyClock = newAddon()
    replyClock:login()
    replyClock:connect()
    replyOnly:SetPositionSharing(true)
    assert(replyOnly:GetPositionSnapshot())
    replyClock:advance(2)
    assert(#replyClock.sent == 1,
        "Collecting a targeted or failed snapshot does not mark its position as publicly sent")
end

-- Compact status positions use the existing movement ordering, availability and opt-in rules.
do
    local shared, clock = newAddon()
    clock:login()
    shared:SetPositionSharing(true)
    assert(shared:ReceivePositionSnapshot("Friend", "P,2000000000,37,0.30000,0.70000"))
    assert(shared:ReceivePosition("Friend", clock:position(37, 0.4, 0.6, clock.epoch + 2)))
    local peer = assert(shared:GetSharedPositions()["friend-testrealm"])
    assert(not shared:ReceivePositionSnapshot("Friend", "P,2000000001,37,0.10000,0.90000")
        and not shared:ReceivePositionSnapshot("Friend", "P,2000000002,37,0.10000,0.90000")
        and peer.x == 0.4, "A delayed or duplicate status attachment cannot overwrite newer movement")
    assert(shared:ReceivePositionSnapshot("Friend", "U,2000000003"))
    assert(peer.x == 0.4 and peer.positionStamp == clock.epoch + 2 and not peer.positionAvailable,
        "An unavailable attachment preserves the last known coordinates and their acquisition time")
    assert(not shared:ReceivePosition("Friend", clock:position(37, 0.8, 0.2, clock.epoch + 2)),
        "A status attachment also advances the ordering used by separate movement packets")
    for _, malformed in ipairs({
        "C,2000000004,MAGE", "P,2000000004,37,0.3", "P,2000000004,37,1.1,0.7",
        "P,2000000004|37|0.3|0.7", "P,2000000004,37,0.3,0.7,extra", "U,2000000004,extra", "U,bad",
    }) do
        assert(not shared:ReceivePositionSnapshot("Friend", malformed))
    end
    assert(not shared:ReceivePositionSnapshot("Friend", nil))
    assert(not shared:ReceivePositionSnapshot("Self", "P,2000000004,37,0.3,0.7"))
    shared:SetPositionSharing(false)
    assert(not shared:ReceivePositionSnapshot("Friend", "P,2000000004,37,0.3,0.7")
        and shared.positionState.peers["friend-testrealm"] == peer,
        "Status attachments cannot bypass opt-in reception")
    shared:SetPositionSharing(true)
    shared.savedDataReadOnly = true
    assert(shared:GetPositionSnapshot() == nil
        and not shared:ReceivePositionSnapshot("Friend", "P,2000000004,37,0.3,0.7"),
        "Status attachments preserve newer-schema read-only behavior")
end

print("Position tests passed.")
