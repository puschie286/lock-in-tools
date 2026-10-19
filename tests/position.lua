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
        now = 0, epoch = 2000000000, timers = {}, messages = {}, name = "Self",
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
        UnitFullName = function(unit) assert(unit == "player"); return world.name, "Test Realm" end,
        UnitName = function(unit) assert(unit == "player"); return world.name, "Test Realm" end,
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
            local payload = wire:match("^1|position|(.*)$")
            self.sent[#self.sent + 1] = { at = self.now, wire = wire, payload = payload }
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

-- Existing profiles gain disabled sharing, retention and visible icons without changing group/schema data.
local addon, world = newAddon()
local fingerprint = addon:GetGroupFingerprint()
assert(addon.db.schemaVersion == 3 and addon.db.group.secret == "otter-4827")
assert(addon.db.position.sharing == false and addon.db.position.keepLastKnown == true)
assert(addon:GetShowPlayerIcons() == true and addon.db.position.showPlayerIcons == true)
local defaultTrails, defaultTrailLength = addon:GetPositionTrailSettings()
assert(defaultTrails == true and defaultTrailLength == 10
    and addon.db.position.showTrails == true and addon.db.position.trailLength == 10)
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

-- Trail settings are account-wide display preferences with bounded whole-second lengths.
do
    local getter = addon.GetPositionTrailSettings
    for _, uninitialized in ipairs({ {}, { db = false }, { db = {} }, { db = { position = "invalid" } } }) do
        local enabled, length = getter(uninitialized)
        assert(enabled == true and length == 10, "Trail defaults are available before saved settings initialize")
    end
    for _, invalid in ipairs({ "false", 0, {} }) do
        local profile = copy(addon.db)
        profile.position.showTrails = invalid
        local enabled, length = getter({ db = profile })
        assert(enabled == true and length == 10, "Malformed trail visibility reads safely without mutation")
        assert(profile.position.showTrails == invalid)
        local repaired = newAddon(profile)
        assert(repaired.db.position.showTrails == true, "Writable profiles repair malformed trail visibility")
    end
    for _, invalid in ipairs({ 0, 31, 1.5, "10", math.huge, -math.huge, 0 / 0, true, {} }) do
        local profile = copy(addon.db)
        profile.position.trailLength = invalid
        local enabled, length = getter({ db = profile })
        assert(enabled == true and length == 10, "Malformed trail lengths read as the default")
        local repaired = newAddon(profile)
        assert(repaired.db.position.trailLength == 10, "Writable profiles repair malformed trail lengths")
    end
    local trails, clock = newAddon()
    clock:login()
    clock:connect()
    assert(trails:SetPositionSharing(true))
    clock:advance(2)
    local state, timer = trails.positionState, trails.positionState.timer
    local stateBefore, databaseBefore = copy(state), copy(trails.db)
    local sent, samples, refreshes, optionsRefreshes = #clock.sent, clock.samples, clock.refreshes, 0
    function trails:RefreshOptions() optionsRefreshes = optionsRefreshes + 1 end
    assert(trails:SetPositionTrailSettings(false, 17))
    local enabled, length = trails:GetPositionTrailSettings()
    assert(enabled == false and length == 17 and clock.refreshes == refreshes + 1 and optionsRefreshes == 1)
    databaseBefore.position.showTrails, databaseBefore.position.trailLength = false, 17
    assert(equal(trails.db, databaseBefore) and equal(state, stateBefore) and state.timer == timer
        and #clock.sent == sent and clock.samples == samples and trails:IsDataConnected(),
        "Trail preferences only refresh visuals, preserving peers, sampling, sends and discovery")
    clock:advance(2)
    assert(clock.samples == samples + 1 and #clock.sent == sent,
        "Changing trails preserves two-second sampling and unchanged-position suppression")
    local restored = newAddon(copy(trails.db))
    enabled, length = restored:GetPositionTrailSettings()
    assert(enabled == false and length == 17, "Trail preferences survive a reload or another character")
    assert(trails:SetPositionTrailSettings(true, 1))
    assert(trails:SetPositionTrailSettings(true, 30), "Both trail length bounds are accepted")

    local before, stateSnapshot = copy(trails.db), copy(state)
    refreshes, optionsRefreshes = clock.refreshes, 0
    local function rejected(value, seconds)
        local changed, problem = trails:SetPositionTrailSettings(value, seconds)
        assert(changed == false and type(problem) == "string")
        assert(equal(trails.db, before) and equal(state, stateSnapshot)
            and clock.refreshes == refreshes and optionsRefreshes == 0,
            "Rejected trail settings do not mutate preferences, state or UI")
    end
    for _, invalid in ipairs({ 0, 31, 1.5, "10", math.huge, -math.huge, 0 / 0, true, {} }) do
        rejected(false, invalid)
    end
    rejected(false, nil)
    rejected("false", 10)
    rejected(nil, 10)
    trails.initialized = false
    rejected(false, 10)
    trails.initialized = true
    trails.positionState = nil
    local changed, problem = trails:SetPositionTrailSettings(false, 10)
    assert(changed == false and type(problem) == "string" and equal(trails.db, before))
    trails.positionState, trails.savedDataReadOnly = state, true
    rejected(false, 10)
    trails.savedDataReadOnly, trails.RefreshPositionPins, trails.RefreshOptions = nil, nil, nil
    assert(trails:SetPositionTrailSettings(false, 10), "Trail preferences work before the map UI loads")
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

local function classPacket(clock, class, stamp)
    return "1|C|" .. tostring(stamp or clock.epoch + math.floor(clock.now)) .. "|" .. class
end

local function classRequest(wire)
    local id, payload = wire:match("^1|Q|position%-class|([^|]+)|(.*)$")
    return payload, id
end

-- Hiding icons keeps sampling, discovery state, incoming updates and retention running.
do
    local display, clock = newAddon()
    clock.environment.UnitClass = function() return "Localized mage", "MAGE" end
    clock:login()
    clock:connect()
    display:SetPositionSharing(true)
    clock:advance(2)
    assert(#clock.sent == 2 and classRequest(clock.sent[1].wire))
    assert(display:ReceivePosition("Friend", classPacket(clock, "DRUID")))
    assert(display:ReceivePosition("Friend", clock:position(37, 0.3, 0.7)))
    local state, timer = display.positionState, display.positionState.timer
    local sentSample, sentAt = state.lastSentSample, state.lastSentAt
    local generation, optionsRefreshes = state.generation, 0
    function display:RefreshOptions() optionsRefreshes = optionsRefreshes + 1 end
    local refreshes = clock.refreshes
    assert(display:SetShowPlayerIcons(false))
    assert(display:GetShowPlayerIcons() == false and clock.refreshes == refreshes + 1 and optionsRefreshes == 0)
    assert(display.db.position.sharing == true and display.db.position.keepLastKnown == true
        and display:IsDataConnected() and state.timer == timer and state.generation == generation
        and state.lastSentSample == sentSample and state.lastSentAt == sentAt and state.lastSendSucceeded == true
        and state.classRequestPending == false and state.classRequestAttempts == 1,
        "Hiding icons must only refresh map pins, preserving transport, timers and send/discovery state")
    clock:advance(2)
    assert(#clock.sent == 2 and clock.samples == 2,
        "Hidden icons still sample without restarting position suppression or class discovery")
    clock.x = 0.6
    clock:advance(2)
    assert(#clock.sent == 3 and tonumber(fields(clock.sent[3].payload)[5]) == 0.6,
        "Movement continues to broadcast while icons are hidden")
    assert(display:ReceivePosition("Friend", clock:position(37, 0.4, 0.6)))
    assert(display:ReceivePosition("Friend", classPacket(clock, "PRIEST")))
    local peer = assert(display:GetSharedPositions()["friend-testrealm"])
    assert(peer.x == 0.4 and peer.class == "PRIEST"
        and display.db.position.peers["friend-testrealm"].x == 0.4
        and display.db.position.peers["friend-testrealm"].class == "PRIEST",
        "Hidden updates still replace runtime and retained positions and classes")
    clock:advance(60)
    assert(peer.online == false and display.db.position.peers["friend-testrealm"].x == 0.4,
        "Hidden retained peers still time out without losing their last-known location")
    local requests = 0
    for _, packet in ipairs(clock.sent) do if classRequest(packet.wire) then requests = requests + 1 end end
    assert(requests == 1)
    local sent, samples = #clock.sent, clock.samples
    timer, generation = state.timer, state.generation
    sentSample, sentAt = state.lastSentSample, state.lastSentAt
    assert(display:SetShowPlayerIcons(true))
    assert(state.timer == timer and state.generation == generation and state.lastSentSample == sentSample
        and state.lastSentAt == sentAt and state.classRequestPending == false and state.classRequestAttempts == 1
        and display:GetSharedPositions()["friend-testrealm"] == peer,
        "Showing icons preserves the latest peer and sampling/discovery state")
    clock:advance(2)
    assert(#clock.sent == sent and clock.samples == samples + 1,
        "Showing icons does not resend an unchanged position or request classes again")
    display:SetPositionRetention(false)
    assert(display:ReceivePosition("Friend", clock:position(37, 0.5, 0.5)))
    assert(display:SetShowPlayerIcons(false))
    clock:advance(60)
    assert(next(display:GetSharedPositions()) == nil and next(display.db.position.peers) == nil,
        "Hidden non-retained peers expire normally")
end

-- Class discovery requests run once per connection or sharing session, without a heartbeat.
do
    local classes, clock = newAddon()
    clock.environment.UnitClass = function(unit) assert(unit == "player"); return "Localized mage", "MAGE" end
    clock:login()
    clock:connect()
    classes:SetPositionSharing(true)
    local class = fields(assert(classRequest(clock.sent[1].wire)))
    assert(#clock.sent == 1 and #class == 4 and class[1] == "1" and class[2] == "C"
        and class[4] == "MAGE", "Enabling sharing immediately requests classes and supplies our own class")
    clock:advance(2)
    local position = fields(clock.sent[2].payload)
    assert(#clock.sent == 2 and #position == 6 and position[2] == "P",
        "Class requests leave the legacy position packet unchanged")
    clock:advance(15)
    assert(#clock.sent == 2)
    clock:advance(1)
    assert(#clock.sent == 3 and clock.sent[3].at - clock.sent[2].at == 16
        and fields(clock.sent[3].payload)[2] == "P", "Only position data has an idle heartbeat")
    for _ = 1, 8 do
        clock.x = clock.x + 0.01
        clock:advance(2)
    end
    local requests = 0
    for _, sent in ipairs(clock.sent) do
        if classRequest(sent.wire) then requests = requests + 1
        else assert(fields(sent.payload)[2] ~= "C", "No periodic standalone class broadcasts") end
    end
    assert(requests == 1, "Movement and idle time never repeat an accepted class request")
    for _, reset in ipairs({
        function() clock:connect() end,
        function() classes:SetPositionSharing(false); classes:SetPositionSharing(true) end,
        function() classes:SetGroupSecret("class-tests-next-group"); clock:connect() end,
    }) do
        local before = #clock.sent
        reset()
        assert(#clock.sent == before + 1 and classRequest(clock.sent[#clock.sent].wire),
            "Connection, sharing and group resets immediately begin a fresh discovery")
        clock:advance(2)
        assert(#clock.sent == before + 2 and fields(clock.sent[#clock.sent].payload)[2] == "P")
    end
    local savedClasses = copy(classes.db)
    local reloaded, reloadClock = newAddon(savedClasses)
    reloadClock.environment.UnitClass = function() return "Localized mage", "MAGE" end
    reloadClock:connect()
    assert(#reloadClock.sent == 0, "A connected transport cannot request classes before login")
    reloadClock:login()
    assert(#reloadClock.sent == 1 and classRequest(reloadClock.sent[1].wire),
        "Login requests classes when sharing and a connection were already restored")
end

-- Failed native requests retry briefly and independently of successful position delivery.
do
    local classes, clock = newAddon()
    local acceptClass, attempts = false, {}
    clock.environment.UnitClass = function() return "Localized class", "MAGE" end
    classes:SetDataTransport(function(_, wire)
        attempts[#attempts + 1] = wire
        return not classRequest(wire) or acceptClass
    end)
    clock:login()
    classes:SetPositionSharing(true)
    assert(#attempts == 1 and classRequest(attempts[1]))
    acceptClass = true
    clock:advance(2)
    assert(#attempts == 3 and attempts[2]:match("^1|position|1|P|")
        and classRequest(attempts[3]), "Failed requests retry on the next two-second tick")
    assert(not classes:GetPositionStatusText():find("unavailable", 1, true),
        "An optional class request failure does not report position delivery as failed")
    clock:advance(14)
    assert(#attempts == 3, "An accepted request stops retrying")
    clock:advance(2)
    assert(#attempts == 4 and attempts[4]:match("^1|position|1|P|"))

    acceptClass = false
    classes:SetPositionSharing(false)
    classes:SetPositionSharing(true)
    local before = #attempts
    clock:advance(4)
    local requestCount = 1
    for index = before + 1, #attempts do
        if classRequest(attempts[index]) then requestCount = requestCount + 1 end
    end
    assert(requestCount == 3, "A rejected class request gets at most three native attempts per session")
    before = #attempts
    clock:advance(12)
    assert(#attempts == before, "Exhausted class requests do not retry periodically")
end

-- Unknown, missing or unreadable classes preserve ordinary unavailable-position updates.
do
    for _, token in ipairs({ false, "UNKNOWN", "mage", "DEATHKNIGHT" }) do
        local classes, clock = newAddon()
        clock.environment.UnitClass = token and function() return "Localized", token end or false
        clock.map = nil
        clock:login()
        clock:connect()
        classes:SetPositionSharing(true)
        clock:advance(2)
        assert(#clock.sent == 1 and fields(clock.sent[1].payload)[2] == "U")
    end
    local classes, clock = newAddon()
    local secret = setmetatable({}, { __tostring = function() error("Do not inspect secret classes") end })
    clock.environment.UnitClass = function() return "Localized", secret end
    clock.environment.issecretvalue = function(value) return value == secret end
    clock:login()
    clock:connect()
    classes:SetPositionSharing(true)
    clock:advance(2)
    assert(#clock.sent == 1, "Secret class tokens must not be formatted or sent")
    clock.environment.UnitClass = function() return "Localized", "WARRIOR" end
    clock.map = nil
    clock:advance(2)
    assert(#clock.sent == 3 and fields(clock.sent[2].payload)[2] == "U"
        and fields(assert(classRequest(clock.sent[3].wire)))[4] == "WARRIOR",
        "Unavailable coordinates can still request classes once our class becomes readable")
end

-- Real data frames exchange every peer's immutable class, including simultaneous timestamps.
do
    local bus = { now = 0, peers = {}, queue = {}, sent = {} }
    function bus:flush()
        local delivered = 0
        while #self.queue > 0 do
            local packet = table.remove(self.queue, 1)
            delivered = delivered + 1
            assert(delivered < 100, "Class requests and responses must not form a loop")
            for _, peer in ipairs(self.peers) do
                if peer.addon:IsDataConnected() then peer.addon:ReceiveData(packet.sender, packet.wire) end
            end
        end
    end
    function bus:peer(name, class, sharing)
        local instance, clock = newAddon()
        clock.name, clock.now = name, self.now
        clock.environment.UnitClass = function() return "Localized class", class end
        clock:login()
        instance:SetPositionSharing(sharing ~= false)
        local peer = { addon = instance, clock = clock }
        self.peers[#self.peers + 1] = peer
        instance:SetDataTransport(function(prefix, wire)
            assert(prefix == instance:GetDataPrefix())
            local packet = { sender = name .. "-Test Realm", wire = wire, at = clock.now }
            self.sent[#self.sent + 1], self.queue[#self.queue + 1] = packet, packet
            return true
        end)
        self:flush()
        return instance, clock
    end
    function bus:advance(seconds)
        for _, peer in ipairs(self.peers) do peer.clock:advance(seconds) end
        self.now = self.now + seconds
        self:flush()
    end
    function bus:metadataCount()
        local count = 0
        for _, packet in ipairs(self.sent) do
            if packet.wire:match("^1|[QR]|position%-class|") then count = count + 1
            else
                local payload = assert(packet.wire:match("^1|position|(.*)$"))
                assert(fields(payload)[2] ~= "C", "Class discovery never adds a standalone metadata heartbeat")
            end
        end
        return count
    end

    local alice, aliceClock = bus:peer("Alice", "MAGE")
    bus:advance(2)
    local bob, bobClock = bus:peer("Bob", "DRUID")
    assert(alice.positionState.classes["bob-testrealm"].class == "DRUID"
        and bob.positionState.classes["alice-testrealm"].class == "MAGE",
        "The incumbent learns a newcomer from the request and the newcomer learns the incumbent from its reply")
    assert(next(bob:GetSharedPositions()) == nil,
        "Class replies do not invent positions for a client who joined after the last coordinates")
    assert(alice:SendData("position", aliceClock:position(37, 0.3, 0.7)))
    bus:flush()
    assert(bob:GetSharedPositions()["alice-testrealm"].class == "MAGE",
        "A position with the class reply's timestamp remains accepted and keeps its class")

    local cara = bus:peer("Cara", "PRIEST")
    assert(cara.positionState.classes["alice-testrealm"].class == "MAGE"
        and cara.positionState.classes["bob-testrealm"].class == "DRUID"
        and alice.positionState.classes["cara-testrealm"].class == "PRIEST"
        and bob.positionState.classes["cara-testrealm"].class == "PRIEST",
        "One late-join request collects replies from all connected sharing peers")
    for _, peer in ipairs(bus.peers) do
        local own = peer.clock.name:lower() .. "-testrealm"
        assert(peer.addon.positionState.classes[own] == nil, "Channel echoes never cache our own class")
    end

    local before = #bus.sent
    assert(bob:RequestData("position-class", classPacket(bobClock, "DRUID")))
    bus:flush()
    assert(#bus.sent == before + 3,
        "A fresh request gets every reply even when its class timestamp was already cached")

    local disabled = bus:peer("Disabled", "ROGUE", false)
    before = #bus.sent
    assert(alice:RequestData("position-class", classPacket(aliceClock, "MAGE")))
    bus:flush()
    assert(#bus.sent == before + 3 and next(disabled.positionState.classes) == nil
        and alice.positionState.classes["disabled-testrealm"] == nil,
        "Disabled sharing neither consumes discovery requests nor reveals a class in a response")

    before = #bus.sent
    local accepted, invalidRequest = alice:RequestData("position-class", aliceClock:position(37, 0.9, 0.1))
    assert(accepted)
    bus:flush()
    assert(#bus.sent == before + 1 and bob:GetSharedPositions()["alice-testrealm"].x == 0.3,
        "The class request handler rejects coordinate payloads instead of changing map positions")
    assert(not alice:ReceiveData("Bob-Test Realm", "1|R|position-class|" .. invalidRequest
        .. "|alice-testrealm|" .. bobClock:position(37, 0.9, 0.1))
        and alice:GetSharedPositions()["bob-testrealm"] == nil,
        "The class response handler also rejects coordinate payloads")

    local metadata = bus:metadataCount()
    bus:advance(2)
    assert(alice:GetSharedPositions()["bob-testrealm"].class == "DRUID"
        and alice:GetSharedPositions()["cara-testrealm"].class == "PRIEST")
    for _ = 1, 8 do
        for _, peer in ipairs(bus.peers) do peer.clock.x = peer.clock.x + 0.01 end
        bus:advance(2)
    end
    bus:advance(16)
    assert(bus:metadataCount() == metadata,
        "Actual multi-client movement and idle heartbeats never repeat accepted class discovery")
end

-- Metadata accepts either packet order without changing position freshness or presence.
do
    local classes, clock = newAddon()
    clock:login()
    clock:connect()
    classes:SetPositionSharing(true)
    local refreshed = clock.refreshes
    assert(classes:ReceiveData("Friend", "1|position|" .. classPacket(clock, "MAGE")))
    assert(next(classes:GetSharedPositions()) == nil and next(classes.db.position.peers) == nil
        and clock.refreshes == refreshed, "Metadata alone must not create a location or refresh pins")
    assert(classes:ReceivePosition("Friend", clock:position(37, 0.3, 0.7)))
    local peer = assert(classes:GetSharedPositions()["friend-testrealm"])
    assert(peer.class == "MAGE", "Metadata can arrive before a position with the same timestamp")
    assert(classes:ReceivePosition("Friend", clock:position(37, 0.4, 0.6, clock.epoch + 1)))
    peer = classes:GetSharedPositions()["friend-testrealm"]
    assert(peer.class == "MAGE", "Legacy position replacements retain known class metadata")
    local latestPosition, received = peer.stamp, peer.lastReceived
    refreshed = clock.refreshes
    for _, malformed in ipairs({
        classPacket(clock, "DRUID"), classPacket(clock, "DRUID", clock.epoch - 1),
        "1|C|bad|DRUID", "1|C|2000000002|UNKNOWN", "1|C|2000000002|mage",
        "1|C|2000000002|DEATHKNIGHT", "1|C|2000000002", "1|C|2000000002|DRUID|extra",
        "2|C|2000000002|DRUID",
    }) do
        assert(not classes:ReceivePosition("Friend", malformed))
    end
    assert(peer.class == "MAGE" and clock.refreshes == refreshed)
    assert(classes:ReceivePosition("Friend", classPacket(clock, "MAGE", clock.epoch + 1)))
    assert(clock.refreshes == refreshed, "Newer unchanged class metadata needs no map refresh")
    assert(classes:ReceivePosition("Friend", classPacket(clock, "DRUID", clock.epoch + 2)))
    assert(peer.class == "DRUID" and peer.stamp == latestPosition and peer.lastReceived == received
        and peer.online == true and clock.refreshes == refreshed + 1,
        "Changed metadata refreshes only the icon and preserves position timing and presence")
    assert(classes:ReceivePosition("Friend", clock:unavailable(clock.epoch + 2)))
    assert(peer.class == "DRUID", "Metadata cannot block a same-timestamp unavailable heartbeat")
    assert(classes:ReceivePosition("After", clock:position(37, 0.5, 0.5)))
    assert(classes:ReceivePosition("After", classPacket(clock, "PRIEST")))
    assert(classes:GetSharedPositions()["after-testrealm"].class == "PRIEST",
        "Metadata can also arrive after a position with the same timestamp")
    for _, sender in ipairs({ "Self", "Self-Test Realm" }) do
        assert(not classes:ReceivePosition(sender, classPacket(clock, "ROGUE")))
    end
    classes:SetPositionSharing(false)
    assert(not classes:ReceivePosition("Ignored", classPacket(clock, "ROGUE")))
    classes:SetPositionSharing(true)
    classes:SetGroupSecret("class-isolation-group")
    assert(next(classes.positionState.classes) == nil and next(classes.db.position.peers) == nil)
    assert(classes:ReceivePosition("Friend", clock:position(37, 0.2, 0.8)))
    assert(classes:GetSharedPositions()["friend-testrealm"].class == nil,
        "A group switch cannot reuse the previous group's class metadata")
end

-- Retained class is optional saved data, and metadata never extends position lifetime.
do
    local classes, clock = newAddon()
    clock:login()
    classes:SetPositionSharing(true)
    assert(classes:ReceivePosition("Friend", clock:position(37, 0.3, 0.7)))
    clock:advance(30)
    assert(classes:ReceivePosition("Friend", classPacket(clock, "SHAMAN")))
    clock:advance(30)
    local peer = classes:GetSharedPositions()["friend-testrealm"]
    assert(peer.online == false, "Class metadata does not delay the 60-second offline timeout")
    assert(classes:ReceivePosition("Friend", classPacket(clock, "HUNTER")))
    assert(peer.online == false and peer.lastReceived == 0 and peer.stamp == clock.epoch,
        "Class metadata cannot revive an offline retained position")
    local snapshot = copy(classes.db)
    local restored, restoredClock = newAddon(copy(snapshot))
    restoredClock:login()
    peer = restored:GetSharedPositions()["friend-testrealm"]
    assert(peer.class == "HUNTER" and peer.online == false and restored.db.schemaVersion == snapshot.schemaVersion,
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
    local readOnly, readOnlyClock = newAddon(copy(snapshot), true)
    readOnlyClock:login()
    assert(not readOnly:ReceivePosition("Friend", classPacket(readOnlyClock, "MAGE", clock.epoch + 61)))
    assert(equal(readOnly.db, snapshot), "Class metadata preserves newer-schema read-only settings")
    classes:SetPositionRetention(false)
    assert(next(classes:GetSharedPositions()) == nil)
    assert(classes:ReceivePosition("Friend", clock:position(37, 0.4, 0.6)))
    clock:advance(30)
    assert(classes:ReceivePosition("Friend", classPacket(clock, "MAGE")))
    clock:advance(30)
    assert(next(classes:GetSharedPositions()) == nil,
        "Class-only updates cannot keep live-only coordinates past their expiry")
end

print("Position tests passed.")
