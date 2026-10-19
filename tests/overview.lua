-- Overview presence and native party-action checks without the WoW UI or a live channel.
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

local function newAddon(saved, readOnly, name)
    local world = {
        now = 0, epoch = 2000000000, name = name or "Self", level = 24,
        fingerprint = "first-group", connected = false, timers = {}, frames = {},
        sent = {}, requests = {}, invites = {}, joins = {}, positions = {},
        grouped = false, raid = false, leader = false, assistant = false,
        members = 0, sameParty = {}, refreshes = 0,
    }
    local function timer(delay, callback, repeating)
        local result = { at = world.now + delay, callback = callback, interval = repeating and delay }
        function result:Cancel() self.cancelled = true end
        function result:IsCancelled() return self.cancelled == true end
        world.timers[#world.timers + 1] = result
        return result
    end
    local environment = setmetatable({
        GetTime = function() return world.now end,
        GetServerTime = function() return world.epoch + math.floor(world.now) end,
        UnitFullName = function(unit)
            if unit == "player" then return world.name, "Test Realm" end
            return nil
        end,
        UnitName = function(unit)
            if unit == "player" then return world.name, "Test Realm" end
            return nil
        end,
        NameUtil = { GetUnmodifiedUnitFullName = function(unit)
            if unit == "player" then return world.name .. "-TestRealm" end
        end },
        GetRealmName = function() return "Test Realm" end,
        GetNormalizedRealmName = function() return "TestRealm" end,
        UnitLevel = function(unit) assert(unit == "player"); return world.level end,
        IsLoggedIn = function() return true end,
        IsInGroup = function() return world.grouped end,
        IsInRaid = function() return world.raid end,
        UnitIsGroupLeader = function() return world.leader end,
        UnitIsGroupAssistant = function() return world.assistant end,
        GetNumGroupMembers = function() return world.members end,
        GetNumSubgroupMembers = function() return math.max(0, world.members - 1) end,
        UnitInParty = function(name) return world.sameParty[name:lower()] == true end,
        UnitInRaid = function(name) return world.sameParty[name:lower()] and 1 or nil end,
        MAX_PARTY_MEMBERS = 4, MAX_RAID_MEMBERS = 40,
        C_PartyInfo = {
            CanInvite = function() return not world.grouped or world.leader or world.assistant end,
            IsPartyFull = function() return world.members >= (world.raid and 40 or 5) end,
            InviteUnit = function(name) world.invites[#world.invites + 1] = name end,
            RequestInviteFromUnit = function(name) world.joins[#world.joins + 1] = name end,
        },
        InviteUnit = function(name) world.invites[#world.invites + 1] = name end,
        C_Timer = {
            NewTimer = function(delay, callback) return timer(delay, callback) end,
            NewTicker = function(delay, callback) return timer(delay, callback, true) end,
            After = function(delay, callback) return timer(delay, callback) end,
        },
        CreateFrame = function(kind)
            assert(kind == "Frame")
            local frame = { events = {} }
            function frame:RegisterEvent(event) self.events[event] = true end
            function frame:UnregisterEvent(event) self.events[event] = nil end
            function frame:SetScript(script, callback) self[script] = callback end
            world.frames[#world.frames + 1] = frame
            return frame
        end,
    }, { __index = _G })
    environment._G = environment
    world.environment = environment
    local addon = {
        db = saved or { schemaVersion = 3, group = { secret = "otter-4827" }, position = { sharing = false } },
        initialized = true, ready = false, savedDataReadOnly = readOnly,
    }
    function addon:HasGroup() return world.fingerprint ~= nil end
    function addon:GetGroupFingerprint() return world.fingerprint end
    function addon:IsDataConnected() return world.connected end
    function addon:IsDataSelf(sender)
        if type(sender) ~= "string" then return false end
        local character, realm = sender:match("^([^%-]+)%-(.+)$")
        if not character then character, realm = sender, "TestRealm" end
        return (character .. "-" .. realm:gsub("%s", "")):lower() == (world.name .. "-TestRealm"):lower()
    end
    function addon:RefreshOverview() world.refreshes = world.refreshes + 1 end
    function addon:RefreshOptions() end
    function addon:GetSharedPositions()
        return self.db.position.sharing and world.positions or {}
    end
    function addon:RegisterDataFeature(feature, receive, connected)
        assert(feature == "roster")
        world.receive, world.onConnected = receive, connected
        return true
    end
    function addon:RegisterDataRequest(feature, request, response)
        assert(feature == "roster")
        world.onRequest, world.onResponse = request, response
        return true
    end
    function addon:SendData(feature, payload)
        assert(feature == "roster")
        world.sent[#world.sent + 1] = { at = world.now, payload = payload }
        return world.connected
    end
    function addon:RequestData(feature, payload)
        assert(feature == "roster")
        world.requests[#world.requests + 1] = { at = world.now, payload = payload }
        return world.connected
    end
    loadModule("Roster.lua", addon, environment)
    addon:InitializeRoster()
    function world:connect()
        self.connected = true
        self.onConnected(true)
    end
    function world:disconnect()
        self.connected = false
        self.onConnected(false)
    end
    function world:login()
        addon.ready = true
        addon:OnRosterLogin()
    end
    function world:event(event, ...)
        for _, frame in ipairs(self.frames) do
            if frame.events[event] and frame.OnEvent then frame.OnEvent(frame, event, ...) end
        end
    end
    function world:advance(seconds)
        local target, callbacks = self.now + seconds, 0
        while true do
            local nextIndex, nextTimer
            for index, entry in ipairs(self.timers) do
                if not entry.cancelled and entry.at <= target and (not nextTimer or entry.at < nextTimer.at) then
                    nextIndex, nextTimer = index, entry
                end
            end
            if not nextTimer then break end
            table.remove(self.timers, nextIndex)
            self.now, callbacks = nextTimer.at, callbacks + 1
            assert(callbacks < 200, "Roster timers must remain bounded")
            nextTimer.callback(nextTimer)
            if nextTimer.interval and not nextTimer.cancelled then
                nextTimer.at = self.now + nextTimer.interval
                self.timers[#self.timers + 1] = nextTimer
            end
        end
        self.now = target
    end
    function world:payload(level, grouped, canInvite, full, sharing, stamp, sequence)
        return table.concat({ "1", tostring(stamp or self.epoch + math.floor(self.now)),
            tostring(sequence or 1), tostring(level or 25), grouped and "1" or "0",
            canInvite and "1" or "0", full and "1" or "0", sharing and "1" or "0" }, "|")
    end
    function world:peer(name, level, grouped, canInvite, full, sharing, stamp, sequence)
        return self.receive(name, self:payload(level, grouped, canInvite, full, sharing, stamp, sequence))
    end
    function world:find(id)
        for _, row in ipairs(addon:GetOverviewPlayers()) do if row.id == id then return row end end
    end
    return addon, world
end

-- Presence works with location sharing disabled, is bounded, and identifies the local character.
do
    local addon, world = newAddon()
    world:advance(10)
    assert(#world.sent == 0 and #world.requests == 0, "Presence must wait for login")
    world:login()
    world:connect()
    addon:RosterTick()
    local self = world:find("self-testrealm")
    assert(self and self.isSelf and self.level == 24 and self.online)
    assert(self.map == nil and addon.db.position.sharing == false)
    assert(#world.sent > 0 or #world.requests > 0, "Roster discovery is independent of position sharing")
    local function validMetadata(payload)
        local values = {}
        for value in (payload .. "|"):gmatch("([^|]*)|") do values[#values + 1] = value end
        assert(#values == 8 and values[1] == "1" and tonumber(values[4]) == world.level)
        assert(values[8] == "0", "Presence packets must report sharing off without transmitting coordinates")
    end
    for _, packet in ipairs(world.sent) do validMetadata(packet.payload) end
    for _, packet in ipairs(world.requests) do validMetadata(packet.payload) end
    local sent = #world.sent
    addon:RosterTick()
    assert(#world.sent == sent, "Unchanged metadata must not be sent on every tick")
    world:advance(31)
    addon:RosterTick()
    assert(#world.sent > sent, "Connected clients must refresh their presence")
    local requests = #world.requests
    addon:RequestRosterSnapshot()
    addon:RequestRosterSnapshot()
    addon:RequestRosterSnapshot()
    assert(#world.requests - requests <= 1, "Opening Overview repeatedly must bound snapshot requests")
    sent = #world.sent
    world.level = 25
    world:event("PLAYER_LEVEL_UP", 25)
    assert(#world.sent == sent + 1 and world:find("self-testrealm").level == 25,
        "Level changes publish current metadata without waiting for the heartbeat")
    world:peer("Remote-TestRealm", 30, false, true, false, false)
    assert(world:find("remote-testrealm").online)
    world:disconnect()
    assert(not world:find("remote-testrealm").online,
        "Losing the data connection cannot continue presenting remote players as active")
    sent, requests = #world.sent, #world.requests
    addon:RosterTick(); addon:RequestRosterSnapshot()
    assert(#world.sent == sent and #world.requests == requests, "Disconnected clients cannot publish presence")
    world:connect()
    assert(#world.sent > sent and #world.requests > requests, "Reconnection publishes and rediscovers current presence")
end

-- Native senders define identity; malformed packets and old ordering cannot refresh presence.
do
    local addon, world = newAddon()
    world:login(); world:connect()
    assert(world:peer("Friend-Test Realm", 27, false, true, false, false))
    local friend = world:find("friend-testrealm")
    assert(friend and friend.name:gsub("%s", "") == "Friend-TestRealm" and friend.level == 27 and friend.online)
    assert(friend.map == nil and friend.sharing == false)
    assert(not world:peer("SELF-TestRealm", 99, false, true, false, true), "Self echoes cannot replace the local row")
    assert(world:find("self-testrealm").level == 24)
    local before = copy(addon.db)
    for _, malformed in ipairs({ "", "1|1|1|25|0|1|0", "2|1|1|25|0|1|0|0", "1|1|1|-1|0|1|0|0",
        "1|1|1|2.5|0|1|0|0", "1|1|1|x|0|1|0|0", "1|1|1|25|2|1|0|0",
        "1|1|1|25|0|2|0|0", "1|1|1|25|0|1|2|0", "1|1|1|25|0|1|0|2",
        "1|1|1|25|0|1|0|0|extra", string.rep("1", 256) }) do
        assert(not world.receive("Malformed-TestRealm", malformed), "Malformed metadata must be rejected")
    end
    assert(not world.receive("", world:payload()) and not world.receive(false, world:payload()))
    assert(equal(before, addon.db), "Rejected packets must preserve saved roster state")
    world:advance(30)
    assert(not world:peer("Friend-TestRealm", 99, true, true, false, true, world.epoch, 1))
    assert(world:find("friend-testrealm").level == 27, "Duplicate metadata cannot overwrite the peer")
    assert(world:find("friend-testrealm").seenAt == world.epoch, "Duplicate metadata cannot refresh last seen")
    assert(world:peer("Friend-TestRealm", 28, true, true, false, true, world.epoch, 2))
    assert(world:find("friend-testrealm").level == 28, "Sequence orders updates within one server second")
    assert(not world:peer("Friend-TestRealm", 99, true, true, false, true, world.epoch - 1, 100))
    world:advance(91)
    addon:RosterTick()
    friend = world:find("friend-testrealm")
    assert(friend and not friend.online and friend.level == 28, "Expired peers remain visible as last seen")
    assert(world:peer("New-TestRealm", 20, false, true, false, false))
    local staleSeen = false
    for _, row in ipairs(addon:GetOverviewPlayers()) do
        if not row.online then staleSeen = true else assert(not staleSeen, "Active players sort before retained peers") end
    end
    assert(world:peer("Friend-TestRealm", 29, false, true, false, false))
    assert(world:find("friend-testrealm").online, "Fresh presence restores activity")
end

-- Snapshot requests discover both directions; broadcasts never need coordinates.
do
    local first, a = newAddon()
    local second, b = newAddon(nil, nil, "Other")
    b.level = 36
    a:login(); b:login(); a:connect(); b:connect()
    local response = b.onRequest("Self-TestRealm", a:payload(24))
    assert(type(response) == "string", "A valid discovery request gets local presence")
    assert(b:find("self-testrealm") and b:find("self-testrealm").level == 24)
    assert(a.onResponse("Other-TestRealm", response))
    assert(a:find("other-testrealm") and a:find("other-testrealm").level == 36)
    assert(not b.onRequest("Malformed-TestRealm", "bad") and not a.onResponse("Malformed-TestRealm", "bad"))
    assert(b:peer("Self-TestRealm", 45, true, true, false, false, b.epoch, 10))
    local reordered = b.onRequest("Self-TestRealm", b:payload(24, false, false, false, false, b.epoch, 2))
    assert(type(reordered) == "string" and b:find("self-testrealm").level == 45,
        "A valid delayed snapshot still gets a reply without replacing newer metadata")
    assert(first.db.position.sharing == false and second.db.position.sharing == false)
end

-- Stored metadata survives reload without implying activity and never duplicates positions.
do
    local addon, world = newAddon()
    world:login(); world:connect()
    assert(world:peer("Friend-TestRealm", 31, true, true, false, true))
    addon.db.position.sharing = true
    world.positions["friend-testrealm"] = {
        name = "Friend-TestRealm", map = 37, x = 0.4, y = 0.6,
        stamp = world.epoch + 5, positionStamp = world.epoch, positionAvailable = false, online = true,
    }
    local row = world:find("friend-testrealm")
    assert(row.map == 37 and row.x == 0.4 and row.y == 0.6)
    assert(row.positionStamp == world.epoch and row.positionAvailable == false,
        "Location age must use the coordinate timestamp, not later activity")
    local stored = addon.db.roster.peers["friend-testrealm"]
    assert(stored and stored.name == "Friend-TestRealm" and stored.level == 31 and stored.seenAt)
    for key in pairs(stored) do
        assert(key == "name" or key == "level" or key == "seenAt", "Roster persistence contains only presence metadata")
    end
    world.positions["friend-testrealm"].positionAvailable = true
    assert(world:peer("Friend-TestRealm", 31, true, true, false, false, world.epoch, 2))
    assert(world:find("friend-testrealm").map == 37 and not world:find("friend-testrealm").positionAvailable,
        "A peer disabling sharing turns retained coordinates into a last position")
    addon.db.position.sharing = false
    assert(world:find("friend-testrealm").map == nil, "Turning sharing off hides positions through the existing accessor")
    local restored, clock = newAddon(copy(addon.db))
    clock:login()
    assert(clock:find("friend-testrealm") and not clock:find("friend-testrealm").online)
    clock.fingerprint = "second-group"
    restored:OnRosterGroupChanged()
    assert(clock:find("friend-testrealm") == nil and next(restored.db.roster.peers) == nil,
        "A group switch cannot retain members from the old key")
    assert(restored.db.roster.groupFingerprint == "second-group")
    local mismatched = copy(addon.db)
    mismatched.roster.groupFingerprint = "other-group"
    local _, mismatchClock = newAddon(mismatched)
    assert(mismatchClock:find("friend-testrealm") == nil, "Saved metadata is scoped to its group")
end

-- Party actions are explicit native requests and recheck eligibility at click time.
do
    local addon, world = newAddon()
    world:login(); world:connect()
    assert(world:peer("Solo-TestRealm", 20, false, true, false, false))
    local state = addon:GetOverviewActionState("solo-testrealm")
    assert(state.invite == true and not state.request)
    assert(addon:PerformOverviewAction("solo-testrealm", "invite"))
    assert(#world.invites == 1 and world.invites[1] == "Solo-TestRealm" and #world.joins == 0)
    assert(not addon:PerformOverviewAction("self-testrealm", "invite"))
    assert(not addon:PerformOverviewAction("missing-testrealm", "invite"))
    assert(not addon:PerformOverviewAction("solo-testrealm", "invalid"))
    world.grouped, world.members = true, 2
    assert(not addon:PerformOverviewAction("solo-testrealm", "invite"), "A former solo inviter must recheck party permission")
    world.leader = true
    assert(addon:GetOverviewActionState("solo-testrealm").invite)
    world.members = 5
    assert(not addon:PerformOverviewAction("solo-testrealm", "invite"), "A full party cannot invite")
    world.members, world.sameParty["solo-testrealm"] = 2, true
    assert(not addon:GetOverviewActionState("solo-testrealm").invite, "Existing party members need no invitation")
    world.sameParty, world.grouped, world.members, world.leader = {}, false, 0, false
    assert(world:peer("Leader-TestRealm", 30, true, true, false, false))
    assert(addon:GetOverviewActionState("leader-testrealm").request == true)
    assert(addon:PerformOverviewAction("leader-testrealm", "request"))
    assert(#world.joins == 1 and world.joins[1] == "Leader-TestRealm" and #world.invites == 1,
        "Request to join uses the native request API without accepting or inviting automatically")
    assert(world:peer("Member-TestRealm", 30, true, false, false, false))
    assert(addon:GetOverviewActionState("member-testrealm").request == true,
        "A native join request can be routed through an ordinary party member")
    world.grouped, world.members = true, 2
    assert(not addon:PerformOverviewAction("leader-testrealm", "request"), "Joining eligibility is rechecked after forming a party")
    world.grouped, world.members = false, 0
    assert(world:peer("Full-TestRealm", 40, true, true, true, false))
    assert(not addon:GetOverviewActionState("full-testrealm").request)
    world.environment.C_PartyInfo.RequestInviteFromUnit = function() error("native request failed") end
    local accepted, problem = addon:PerformOverviewAction("leader-testrealm", "request")
    assert(accepted == false and type(problem) == "string", "Native failures are reported without escaping the click callback")
    world:advance(91); addon:RosterTick()
    assert(not addon:PerformOverviewAction("leader-testrealm", "request")
        and not addon:PerformOverviewAction("solo-testrealm", "invite"), "Stale presence cannot authorize actions")
    assert(#world.joins == 1 and #world.invites == 1)
end

-- Unsupported APIs, read-only settings and logout cannot mutate or send on a dead lifecycle.
do
    local addon, world = newAddon()
    world:login(); world:connect()
    assert(world:peer("Friend-TestRealm", 31, true, true, false, false))
    world.environment.C_PartyInfo = nil
    world.environment.InviteUnit = nil
    assert(not addon:GetOverviewActionState("friend-testrealm").request)
    assert(not addon:PerformOverviewAction("friend-testrealm", "request"))
    addon:OnRosterLogout()
    local sent, requests = #world.sent, #world.requests
    world:advance(100); addon:RosterTick(); addon:RequestRosterSnapshot()
    assert(#world.sent == sent and #world.requests == requests, "Logout stops presence and discovery")
    local saved = copy(addon.db)
    saved.schemaVersion = 999
    local before = copy(saved)
    local guarded, clock = newAddon(saved, true)
    clock:login(); clock:connect(); guarded:RosterTick(); guarded:RequestRosterSnapshot()
    clock:peer("Other-TestRealm", 99, true, true, false, true)
    guarded:OnRosterGroupChanged()
    clock:advance(100)
    assert(equal(before, saved), "Newer-schema data must remain byte-for-byte unchanged")
    assert(#clock.sent == 0 and #clock.requests == 0)
    assert(not guarded:PerformOverviewAction("other-testrealm", "invite"))
end

print("PASS: overview presence and native party actions")
