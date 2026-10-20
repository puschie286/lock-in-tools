-- Overview presence and native party-action checks without the WoW UI or a live channel.
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

local function newAddon(saved, readOnly, name, configure)
    local world = {
        now = 0, epoch = 2000000000, name = name or "Self", level = 24, xp = 420, xpMax = 1000, maxLevel = 60,
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
        UnitXP = function(unit) assert(unit == "player"); return world.xp end,
        UnitXPMax = function(unit) assert(unit == "player"); return world.xpMax end,
        GetMaxPlayerLevel = function() return world.maxLevel end,
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
    world.notificationErrors = loadNotifications(addon, environment)
    addon:RegisterNotification("ROSTER_CHANGED", function() addon:RefreshOverview() end)
    function addon:RefreshOptions() end
    function addon:GetSharedPositions()
        return self.db.position.sharing and world.positions or {}
    end
    function addon:RegisterDataFeature(feature, receive, connected)
        error("Roster must not register separate feature messages")
    end
    function addon:RegisterDataStatusProvider(name, collect, receive, connected)
        assert(name == "player", "All player metadata must share the generic status transport")
        world.collectStatus, world.receiveStatus, world.statusConnected = collect, receive, connected
        return true
    end
    function addon:RegisterDataRequest(feature, request, response)
        error("Roster must not register separate discovery requests")
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
    if configure then configure(environment) end
    loadModule("Roster.lua", addon, environment)
    addon:InitializeRoster()
    function world:connect()
        self.connected = true
        self.statusConnected(true)
    end
    function world:disconnect()
        self.connected = false
        self.statusConnected(false)
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
    function world:peer(name, level, grouped, canInvite, full, sharing, stamp, sequence)
        return self:status(name, { level = level or 25, xpState = "unavailable", inParty = grouped == true,
            canInvite = canInvite == true, partyFull = full == true, sharing = sharing == true }, stamp, sequence)
    end
    function world:status(name, fields, stamp, sequence, metadata)
        local decoded = {}
        for key, value in pairs(fields) do
            decoded[key] = type(value) == "number" and tostring(value) or value
        end
        return self.receiveStatus(name, decoded, stamp or self.epoch + math.floor(self.now), sequence or 1, metadata)
    end
    function world:find(id)
        for _, row in ipairs(addon:GetOverviewPlayers()) do if row.id == id then return row end end
    end
    return addon, world
end

-- All local metadata is collected together; native changes never bypass the shared scheduler.
do
    local addon, world = newAddon()
    world:advance(10)
    assert(world.collectStatus() == nil, "Status collection waits for login")
    world:login()
    world:connect()
    local self = world:find("self-testrealm")
    assert(self and self.isSelf and self.level == 24 and self.online)
    assert(self.map == nil and addon.db.position.sharing == false)
    local fields = world.collectStatus()
    assert(fields.level == 24 and fields.xp == 420 and fields.xpMax == 1000 and fields.xpState == "known")
    assert(fields.inParty == false and fields.canInvite == true and fields.partyFull == false and fields.sharing == false)
    assert(fields.map == nil and fields.x == nil and fields.y == nil, "Roster collection never duplicates coordinates")
    world.grouped, world.leader, world.members = true, true, 5
    addon.db.position.sharing = true
    world:event("GROUP_ROSTER_UPDATE")
    world:event("PARTY_LEADER_CHANGED")
    fields = world.collectStatus()
    assert(fields.inParty == true and fields.canInvite == true and fields.partyFull == true and fields.sharing == true)
    world.leader, world.members = false, 2
    world:event("PARTY_LEADER_CHANGED")
    fields = world.collectStatus()
    assert(fields.inParty and not fields.canInvite and not fields.partyFull,
        "Party metadata samples the latest native state for the next shared tick")
    world.level = 25
    world:event("PLAYER_LEVEL_UP", 25)
    assert(world:find("self-testrealm").level == 25, "Local level changes appear immediately")
    world:advance(100)
    assert(#world.sent == 0 and #world.requests == 0 and #world.timers == 0,
        "Roster owns no timer, broadcasts or requests; shared status owns scheduling and discovery")
    assert(addon.RequestRosterSnapshot == nil and addon.RosterTick == nil and addon.ReceiveRoster == nil)
    world:peer("Remote-TestRealm", 30, false, true, false, false)
    assert(world:find("remote-testrealm").online)
    world:disconnect()
    assert(not world:find("remote-testrealm").online,
        "Losing the data connection cannot continue presenting remote players as active")
    world:connect()
    assert(not world:find("remote-testrealm").online, "Reconnection waits for current contact")
    assert(#world.sent == 0 and #world.requests == 0, "Reconnect discovery belongs to shared status")
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
    for _, malformed in ipairs({ -1, 2.5, "x", true, 1001 }) do
        assert(not world:status("Malformed-TestRealm", { level = malformed, xpState = "unavailable" }),
            "Malformed player metadata must be rejected")
    end
    for _, name in ipairs({ "", false, "Friend|TestRealm", "Friend\nTestRealm", string.rep("x", 129) }) do
        assert(not world:peer(name, 20, false, true, false, false), "Malformed senders must be rejected")
    end
    assert(equal(before, addon.db), "Rejected packets must preserve saved roster state")
    world:advance(30)
    assert(not world:peer("Friend-TestRealm", 99, true, true, false, true, world.epoch, 1))
    assert(world:find("friend-testrealm").level == 27, "Duplicate metadata cannot overwrite the peer")
    assert(world:find("friend-testrealm").seenAt == world.epoch, "Duplicate metadata cannot refresh last seen")
    assert(world:peer("Friend-TestRealm", 28, true, true, false, true, world.epoch, 2))
    assert(world:find("friend-testrealm").level == 28, "Sequence orders updates within one server second")
    assert(not world:peer("Friend-TestRealm", 99, true, true, false, true, world.epoch - 1, 100))
    world:advance(91)
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
    assert(stored.xpState == "unavailable" and stored.xpUpdatedAt == world.epoch
        and stored.inParty == true and stored.canInvite == true and stored.partyFull == false and stored.sharing == true,
        "Roster history retains the complete last known player snapshot")
    assert(stored.map == nil and stored.x == nil and stored.y == nil,
        "Roster history leaves retained coordinates to the position feature")
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
    assert(next(restored.db.roster.peers) == nil, "Switching groups clears the old local history")
    assert(clock:find("friend-testrealm") == nil and restored.db.roster.peers["friend-testrealm"] == nil,
        "A group switch cannot retain members from the old key")
    assert(restored.db.roster.groupFingerprint == "second-group")
    local mismatched = copy(addon.db)
    mismatched.roster.groupFingerprint = "other-group"
    local _, mismatchClock = newAddon(mismatched)
    assert(mismatchClock:find("friend-testrealm") == nil, "Saved metadata is scoped to its group")
end

-- Legacy bare names restore from their saved realm even before login APIs are ready.
do
    local source, clock = newAddon()
    clock:login(); clock:connect()
    assert(clock:peer("Friend", 31, true, true, false, false))
    assert(source.db.roster.peers["friend-testrealm"].name == "Friend-testrealm",
        "New roster history must save a realm-qualified name")
    local legacy = copy(source.db)
    legacy.roster.peers["friend-testrealm"].name = "Friend"
    legacy.roster.peers["qualified-testrealm"] = { name = "Qualified-Test Realm", level = 19, seenAt = clock.epoch }
    for _, realm in ipairs({ false, "", "OtherRealm" }) do
        local profile = copy(legacy)
        local restored, world = newAddon(profile, false, nil, function(environment)
            environment.GetNormalizedRealmName = function() return realm or nil end
        end)
        assert(restored.rosterState.peers["friend-testrealm"], "Startup must not discard bare saved names")
        world.environment.GetNormalizedRealmName = function() return "TestRealm" end
        world:login(); world:connect(); world:advance(120)
        local friend = assert(world:find("friend-testrealm"))
        assert(not friend.online and friend.level == 31 and friend.seenAt == clock.epoch
            and friend.name == "Friend-testrealm" and friend.xpState == "unavailable",
            "Restored offline players retain their identity and metadata without fresh reports")
        assert(world:find("qualified-testrealm").name == "Qualified-Test Realm",
            "Already qualified names retain their spelling")
        assert(profile.roster.peers["friend-testrealm"].name == "Friend-testrealm",
            "Writable legacy history is upgraded to a realm-qualified name")
        local _, again = newAddon(copy(profile))
        again:login()
        assert(again:find("friend-testrealm") and not again:find("friend-testrealm").online,
            "Upgraded history survives another reload")
    end
end

-- A saved realm cannot legitimize a mismatched or malformed player identity.
do
    local profile = { group = { secret = "otter-4827" }, roster = { groupFingerprint = "first-group", peers = {
        ["friend-testrealm"] = { name = "Other", seenAt = 2000000000 },
        ["qualified-testrealm"] = { name = "Qualified-OtherRealm", seenAt = 2000000000 },
        ["bad|name-testrealm"] = { name = "Bad|Name", seenAt = 2000000000 },
        ["missingrealm"] = { name = "Missingrealm", seenAt = 2000000000 },
        [1] = { name = "Numeric", seenAt = 2000000000 },
        ["invalid-testrealm"] = { name = "Invalid", seenAt = "yesterday" },
    } } }
    local restored = newAddon(profile, false, nil, function(environment)
        environment.GetNormalizedRealmName = function() error("Restore must use the saved realm") end
    end)
    assert(next(restored.rosterState.peers) == nil and next(profile.roster.peers) == nil,
        "Invalid identities and metadata must still be rejected without consulting the current realm")
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
    world:advance(91)
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
    world:advance(100)
    assert(world.collectStatus() == nil and not world:peer("Friend-TestRealm", 31, true, true, false, false))
    assert(#world.sent == sent and #world.requests == requests, "Logout stops presence and discovery")
    local saved = copy(addon.db)
    saved.schemaVersion = 999
    local before = copy(saved)
    local guarded, clock = newAddon(saved, true)
    clock:login(); clock:connect()
    clock:peer("Other-TestRealm", 99, true, true, false, true)
    guarded:OnRosterGroupChanged()
    clock:advance(100)
    assert(equal(before, saved), "Newer-schema data must remain byte-for-byte unchanged")
    assert(#clock.sent == 0 and #clock.requests == 0)
    assert(not guarded:PerformOverviewAction("other-testrealm", "invite"))
end

-- XP survives reload and reconnect as stale until a current report arrives.
do
    local addon, world = newAddon()
    assert(world.collectStatus() == nil, "Status collection waits for an active player lifecycle")
    world:login(); world:connect()
    local own = world:find("self-testrealm")
    assert(own.xpState == "known" and own.xp == 420 and own.xpMax == 1000 and not own.xpStale)
    local collected = world.collectStatus()
    assert(collected.level == 24 and collected.xp == 420 and collected.xpMax == 1000 and collected.xpState == "known")
    local sent, requests, refreshes = #world.sent, #world.requests, world.refreshes
    world.xp = 0
    world:event("PLAYER_XP_UPDATE", "player")
    own = world:find("self-testrealm")
    assert(own.xp == 0 and own.xpState == "known" and world.refreshes > refreshes,
        "Real zero XP refreshes the local overview immediately")
    assert(#world.sent == sent and #world.requests == requests,
        "XP events must not bypass the shared status scheduler with feature broadcasts or requests")
    assert(world:status("Friend-TestRealm", { level = 31, xp = 125, xpMax = 500, xpState = "known", future = "ignored" }))
    local friend = world:find("friend-testrealm")
    assert(friend and friend.online and friend.level == 31 and friend.xp == 125 and friend.xpMax == 500)
    assert(friend.xpUpdatedAt == world.epoch and friend.xpState == "known" and not friend.xpStale)
    assert(friend.inParty == nil and friend.canInvite == nil and friend.sharing == nil,
        "A status-only peer has no invented party or sharing metadata")
    assert(not addon:GetOverviewActionState("friend-testrealm").invite
        and not addon:GetOverviewActionState("friend-testrealm").request,
        "Missing party flags from an older status snapshot cannot invent eligibility")
    for index = 1, 5 do
        world:advance(30)
        assert(world:status("Friend-TestRealm", { level = 31, xp = 125, xpMax = 500, xpState = "known" }))
        friend = world:find("friend-testrealm")
        assert(friend.xp == 125 and friend.xpUpdatedAt == world.epoch and not friend.xpStale,
            "Unchanged XP stays valid while presence continues, regardless of sample age")
    end
    local saved = addon.db.roster.peers["friend-testrealm"]
    assert(saved.xp == 125 and saved.xpMax == 500 and saved.xpState == "known"
        and saved.xpUpdatedAt == friend.xpUpdatedAt, "Exact progress and its sample age enter SavedVariables")
    local restoredAddon, restored = newAddon(copy(addon.db))
    restored:login()
    local retained = restored:find("friend-testrealm")
    assert(retained.xp == 125 and retained.xpMax == 500 and retained.xpState == "known"
        and retained.xpUpdatedAt == friend.xpUpdatedAt and not retained.online and retained.xpStale
        and retained.statusSynchronized == false, "Reload preserves progress without claiming current contact")
    restored:connect()
    assert(restored:find("friend-testrealm").xp == 125 and restored:find("friend-testrealm").xpStale,
        "A new transport connection cannot erase or certify retained XP")
    assert(not restoredAddon:GetOverviewActionState("friend-testrealm").invite)
    world:advance(91)
    friend = world:find("friend-testrealm")
    assert(not friend.online and friend.xpStale and friend.xp == 125, "Inactive XP is retained with a stale marker")
    world:disconnect()
    assert(world:find("friend-testrealm").xpStale and world:find("friend-testrealm").xp == 125)
    world:connect()
    assert(world:find("friend-testrealm").xp == 125 and world:find("friend-testrealm").xpStale,
        "Reconnect retains the last progress while waiting for a current status snapshot")
    assert(world:status("Friend-TestRealm", { level = 31, xpState = "max" }))
    assert(world:find("friend-testrealm").xpState == "max" and not world:find("friend-testrealm").xpStale)
    world.fingerprint = "second-group"
    addon:OnRosterGroupChanged()
    assert(world:find("friend-testrealm") == nil and addon.rosterState.progress["friend-testrealm"] == nil
        and addon.db.roster.peers["friend-testrealm"] == nil,
        "Group changes clear retained player progress")
end

-- All restored fields remain historical; transient ordering and action eligibility never survive reload.
do
    local addon, world = newAddon()
    world:login(); world:connect()
    local fields = { level = 31, xp = 125, xpMax = 500, xpState = "known", inParty = true,
        canInvite = false, partyFull = false, sharing = true }
    assert(world:status("Friend-TestRealm", fields, nil, 99, { session = "old", kind = "full", coherent = true }))
    local saved = copy(addon.db)
    local snapshot = saved.roster.peers["friend-testrealm"]
    assert(snapshot.name == "Friend-TestRealm" and snapshot.level == 31 and snapshot.seenAt == world.epoch)
    assert(snapshot.xp == 125 and snapshot.xpMax == 500 and snapshot.xpState == "known"
        and snapshot.xpUpdatedAt == world.epoch)
    assert(snapshot.inParty == true and snapshot.canInvite == false and snapshot.partyFull == false and snapshot.sharing == true,
        "False party values must survive serialization as well as true values")
    for _, key in ipairs({ "stamp", "sequence", "session", "lastReceived", "disconnected", "statusSynchronized" }) do
        assert(snapshot[key] == nil, "Saved history must not contain transient currentness or ordering fields")
    end
    -- Even an old profile containing live-only fields cannot restore currentness or block a fresh sender.
    snapshot.stamp, snapshot.sequence, snapshot.session = world.epoch + 100, 999, "old"
    snapshot.lastReceived, snapshot.disconnected, snapshot.statusSynchronized = 0, false, true
    local restored, clock = newAddon(saved)
    clock:login(); clock:connect()
    local row = clock:find("friend-testrealm")
    assert(row and not row.online and row.xpStale and row.statusSynchronized == false)
    assert(row.inParty == true and row.canInvite == false and row.partyFull == false and row.sharing == true)
    assert(not restored:GetOverviewActionState("friend-testrealm").request,
        "Saved party information cannot authorize a native party action")
    assert(clock:status("Friend-TestRealm", fields, clock.epoch, 1),
        "Saved ordering cannot reject the first current snapshot from a fresh session")
    row = clock:find("friend-testrealm")
    assert(row.online and not row.xpStale and row.statusSynchronized and restored:GetOverviewActionState("friend-testrealm").request)
    clock:disconnect(); clock:connect()
    assert(clock:find("friend-testrealm").xp == 125 and clock:find("friend-testrealm").xpStale)
    assert(clock:status("Friend-TestRealm", fields, clock.epoch, 1),
        "Reconnect resets direct-call ordering while keeping the historical progress")
    assert(not clock:find("friend-testrealm").xpStale)
end

-- Legacy and malformed optional snapshots keep valid identity/presence without exposing invalid fields.
do
    local profile = { group = { secret = "otter-4827" }, position = { sharing = false },
        roster = { groupFingerprint = "first-group", peers = {
            ["legacy-testrealm"] = { name = "Legacy", level = 20, seenAt = 2000000000 },
            ["max-testrealm"] = { name = "Max-TestRealm", level = 60, seenAt = 2000000000,
                xpState = "max", xpUpdatedAt = 1999999990, inParty = false, sharing = false },
            ["unavailable-testrealm"] = { name = "Unavailable-TestRealm", level = 22, seenAt = 2000000000,
                xpState = "unavailable", xpUpdatedAt = 1999999991, canInvite = false },
            ["badxp-testrealm"] = { name = "Badxp-TestRealm", level = 30, seenAt = 2000000000,
                xpState = "known", xp = 501, xpMax = 500, xpUpdatedAt = 1999999992,
                inParty = false, canInvite = "true", partyFull = {}, sharing = true },
            ["badage-testrealm"] = { name = "Badage-TestRealm", level = 30, seenAt = 2000000000,
                xpState = "known", xp = 50, xpMax = 500, xpUpdatedAt = "yesterday" },
            ["badstate-testrealm"] = { name = "Badstate-TestRealm", level = 30, seenAt = 2000000000,
                xpState = "future", xp = 50, xpMax = 500, xpUpdatedAt = 1999999992 },
        } } }
    local _, world = newAddon(profile)
    world:login(); world:connect()
    local legacy = assert(world:find("legacy-testrealm"))
    assert(legacy.name == "Legacy-testrealm" and legacy.level == 20 and legacy.seenAt == world.epoch
        and legacy.xpState == "unavailable" and not legacy.online)
    local maximum, unavailable = world:find("max-testrealm"), world:find("unavailable-testrealm")
    assert(maximum.xpState == "max" and maximum.xpUpdatedAt == 1999999990 and maximum.xpStale
        and maximum.inParty == false and maximum.sharing == false)
    assert(unavailable.xpState == "unavailable" and unavailable.xpUpdatedAt == 1999999991
        and unavailable.canInvite == false and unavailable.xpStale)
    for _, id in ipairs({ "badxp-testrealm", "badage-testrealm", "badstate-testrealm" }) do
        local row = assert(world:find(id), "Bad optional progress must not discard an otherwise valid retained player")
        assert(row.level == 30 and row.seenAt == world.epoch and not row.online and row.statusSynchronized == false)
        assert(row.xp == nil and row.xpMax == nil and row.xpState == "unavailable",
            "Malformed retained progress cannot reach the visible player row")
    end
    local bad = world:find("badxp-testrealm")
    assert(bad.inParty == false and bad.sharing == true and bad.canInvite == nil and bad.partyFull == nil,
        "Invalid optional booleans are discarded without losing other valid saved values")
end

-- Our own snapshot is saved without an open Overview, then retained as an offline character after switching.
do
    local addon, world = newAddon()
    world:login(); world:connect()
    world:advance(12)
    world.level, world.xp, world.xpMax, world.grouped, world.leader, world.members = 25, 81, 1200, true, true, 3
    addon.db.position.sharing = true
    world:event("PLAYER_XP_UPDATE", "player")
    world:event("GROUP_ROSTER_UPDATE")
    addon:OnRosterLogout()
    local snapshot = assert(addon.db.roster.peers["self-testrealm"], "Local events and logout save the current character")
    assert(snapshot.level == 25 and snapshot.xp == 81 and snapshot.xpMax == 1200 and snapshot.xpState == "known")
    assert(snapshot.xpUpdatedAt == world.epoch + 12 and snapshot.seenAt == world.epoch + 12
        and snapshot.inParty == true and snapshot.canInvite == true and snapshot.partyFull == false and snapshot.sharing == true)
    local _, other = newAddon(copy(addon.db), false, "Other")
    other:login(); other:connect()
    local previous = assert(other:find("self-testrealm"))
    assert(not previous.isSelf and not previous.online and previous.xpStale and previous.statusSynchronized == false)
    assert(previous.level == 25 and previous.xp == 81 and previous.xpMax == 1200 and previous.xpUpdatedAt == snapshot.xpUpdatedAt,
        "Account-wide history retains the previous character's exact progress")
    assert(other:find("other-testrealm").isSelf and other:find("other-testrealm").online)
    local sameAddon, same = newAddon(copy(addon.db))
    same:login(); same:connect()
    local own, count = same:find("self-testrealm"), 0
    for _, row in ipairs(sameAddon:GetOverviewPlayers()) do
        if row.id == "self-testrealm" then count = count + 1 end
    end
    assert(own.isSelf and own.online and own.xp == 420 and not own.xpStale,
        "The current character uses live native XP instead of its retained snapshot")
    assert(count == 1, "Restoring the current character cannot duplicate its live Overview row")
end

-- Full refreshes preserve XP age until progress changes, the sender restarts or contact resumes.
do
    local addon, world = newAddon()
    world:login(); world:connect()
    local fields = { level = 31, xp = 10, xpMax = 500, xpState = "known", inParty = false,
        canInvite = true, partyFull = false, sharing = false }
    assert(world:status("Friend-TestRealm", fields, nil, 1, { kind = "full", session = "first", coherent = true }))
    world:advance(5)
    fields.inParty, fields.sharing = true, true
    assert(world:status("Friend-TestRealm", fields, nil, 2, { kind = "full", session = "first", coherent = true }))
    local friend = world:find("friend-testrealm")
    assert(friend.level == 31 and friend.xp == 10 and friend.inParty and friend.sharing)
    assert(friend.xpUpdatedAt == world.epoch and friend.seenAt == world.epoch + 5,
        "A party-only change updates presence without renewing the XP sample timestamp")
    world:advance(25)
    assert(world:status("Friend-TestRealm", fields, nil, 3, { kind = "full", session = "first", coherent = true }))
    friend = world:find("friend-testrealm")
    assert(friend.online and not friend.xpStale and friend.xpUpdatedAt == world.epoch)
    world:advance(5)
    fields.xp = 15
    assert(world:status("Friend-TestRealm", fields, nil, 4, { kind = "full", session = "first", coherent = true }))
    assert(world:find("friend-testrealm").xpUpdatedAt == world.epoch + 35)
    world:advance(5)
    assert(world:status("Friend-TestRealm", fields, nil, 5, { kind = "full", session = "first", coherent = true }))
    assert(world:find("friend-testrealm").xpUpdatedAt == world.epoch + 35,
        "A full refresh of unchanged XP preserves the existing sample age")
    assert(world:status("Friend-TestRealm", fields, nil, 1, { kind = "full", session = "second", coherent = true }),
        "A new sender session can reset its revision in the same server second")
    assert(world:find("friend-testrealm").xpUpdatedAt == world.epoch + 40,
        "A new sender session establishes a fresh sample even when XP is unchanged")
    world:advance(5)
    fields.level, fields.xp, fields.xpMax = 32, 0, 600
    assert(world:status("Friend-TestRealm", fields, nil, 2, { kind = "full", session = "second", coherent = true }))
    friend = world:find("friend-testrealm")
    assert(friend.level == 32 and friend.xp == 0 and friend.inParty and friend.sharing)
    assert(friend.seenAt == world.epoch + 45 and friend.xpUpdatedAt == world.epoch + 45)
    world:advance(91)
    friend = world:find("friend-testrealm")
    assert(not friend.online and friend.xpStale and friend.xp == 0,
        "Loss of contact retains the last progress visibly stale")
    assert(not addon:GetOverviewActionState("friend-testrealm").request,
        "Expired presence cannot authorize actions from old party metadata")
    assert(world:status("Friend-TestRealm", fields, nil, 3, { kind = "full", session = "second", coherent = true }))
    assert(not world:find("friend-testrealm").xpStale and addon:GetOverviewActionState("friend-testrealm").request)
    assert(world:find("friend-testrealm").xpUpdatedAt == world.epoch + 136,
        "Returning after contact expires refreshes unchanged XP and clears the stale marker")
    local before = copy(addon.db)
    for _, malformed in ipairs({
        { level = 34, xp = -1, xpMax = 700, xpState = "known" },
        { level = 34, xp = 701, xpMax = 700, xpState = "known" },
        { level = 34, xp = 0, xpMax = 0, xpState = "known" },
        { level = 34, xpMax = 700, xpState = "known" },
        { level = 34, xpState = "future" }, { level = 0, xpState = "max" },
        { level = 34, xpState = "unavailable", inParty = "maybe" },
        { level = 34, xpState = "unavailable", inParty = "true" },
        { level = 34, xpState = "unavailable", canInvite = "false" },
        { level = 34, xpState = "unavailable", partyFull = 0 },
        { level = 34, xpState = "unavailable", sharing = "1" },
        { level = 34, xpState = "unavailable", sharing = "false" },
        { level = 34 }, { unrelated = "future provider" },
    }) do
        assert(not world:status("Malformed-TestRealm", malformed), "Malformed player status is ignored")
    end
    assert(not world:status("SELF-TestRealm", { level = 99, xpState = "max" }))
    assert(equal(before, addon.db), "Rejected progress cannot alter saved roster data")
    assert(world:status("Friend-TestRealm", { level = 33, xpState = "unavailable" }, nil, 4))
    friend = world:find("friend-testrealm")
    assert(friend.xp == nil and friend.xpMax == nil and friend.xpState == "unavailable",
        "Unavailable snapshots replace previously known progress")
    assert(world:status("UnknownFlags-TestRealm", { level = 33, xpState = "unavailable", inParty = true }))
    assert(not addon:GetOverviewActionState("unknownflags-testrealm").request,
        "Unknown party capacity must not be treated as available space")
end

-- A structurally valid status frame can still fail player-data validation.
-- Invalid full refreshes cannot certify the retained sample.
do
    local addon, world = newAddon()
    world:login(); world:connect()
    local fields = { level = 31, xp = 42, xpMax = 1000, xpState = "known",
        inParty = true, canInvite = true, partyFull = false, sharing = false }
    assert(world:status("Friend-TestRealm", fields, nil, 1, { kind = "full", coherent = true }))
    assert(addon:GetOverviewActionState("friend-testrealm").request)
    local saved = copy(addon.db.roster.peers["friend-testrealm"])
    world:advance(5)
    fields.level, fields.xp = 32, 1001
    assert(not world:status("Friend-TestRealm", fields, nil, 2, { kind = "full", coherent = true }))
    local friend = world:find("friend-testrealm")
    assert(friend.level == 31 and friend.xp == 42 and friend.xpStale and friend.statusSynchronized == false,
        "Rejected newer player data leaves the previous sample visibly stale")
    assert(friend.xpUpdatedAt == world.epoch and equal(saved, addon.db.roster.peers["friend-testrealm"]),
        "Invalid player fields cannot reach saved metadata")
    assert(not addon:GetOverviewActionState("friend-testrealm").request)
    world:advance(30)
    assert(not world:status("Friend-TestRealm", fields, nil, 3, { kind = "full", coherent = true }))
    friend = world:find("friend-testrealm")
    assert(friend.online and friend.xpStale and not addon:GetOverviewActionState("friend-testrealm").request,
        "An invalid full refresh cannot make rejected player data current")
    fields.level, fields.xp = 32, 45
    assert(world:status("Friend-TestRealm", fields, nil, 4, { kind = "full", coherent = true }))
    friend = world:find("friend-testrealm")
    assert(friend.level == 32 and friend.xp == 45 and not friend.xpStale and friend.statusSynchronized,
        "A valid full refresh restores the current player state")
    assert(addon:GetOverviewActionState("friend-testrealm").request)
end

-- Local level-up events may precede native API updates; secret/invalid/unsupported XP remains unavailable.
do
    local addon, world = newAddon()
    world:login(); world:connect()
    assert(world:find("self-testrealm").xp == 420)
    world:event("PLAYER_LEVEL_UP", 25)
    local own, collected = world:find("self-testrealm"), world.collectStatus()
    assert(own.level == 25 and own.xpState == "unavailable" and own.xp == nil)
    assert(collected.level == 25 and collected.xp == nil, "Lagging native APIs cannot pair old XP with the event's new level")
    world.level = 25
    assert(world:find("self-testrealm").xp == nil, "Updating UnitLevel alone does not make the old XP coherent")
    world.xp, world.xpMax = 20, 1200
    world:event("PLAYER_XP_UPDATE", "target")
    assert(world:find("self-testrealm").xp == nil, "Only the player's XP update releases the level transition")
    world:event("PLAYER_XP_UPDATE", "player")
    own = world:find("self-testrealm")
    assert(own.level == 25 and own.xp == 20 and own.xpMax == 1200)
    world:event("PLAYER_LEVEL_UP", 26)
    world.xp, world.xpMax = 10, 1300
    world:event("PLAYER_XP_UPDATE", "player")
    assert(world:find("self-testrealm").xp == nil, "An XP event still cannot combine a lagging level with new-level progress")
    world.level = 26
    own = world:find("self-testrealm")
    assert(own.level == 26 and own.xp == 10 and own.xpMax == 1300,
        "A previously observed XP event releases progress when the native level catches up")
    world.level, world.xp, world.xpMax = 27, 12, 1400
    world:event("PLAYER_XP_UPDATE", "player")
    world:event("PLAYER_LEVEL_UP", 27)
    collected = world.collectStatus()
    assert(collected.level == 27 and collected.xp == 12 and collected.xpMax == 1400 and collected.xpState == "known",
        "An XP event before the level event caches coherent progress even while Overview is hidden")
    world.xpMax = 0
    assert(world:find("self-testrealm").xpState == "unavailable", "Zero XP maximum alone never proves max level")
    world.level = 60
    assert(world:find("self-testrealm").xpState == "max", "Maximum level comes from the runtime client cap")
    world.environment.GetMaxPlayerLevel = nil
    assert(world:find("self-testrealm").xpState == "unavailable", "An absent cap API does not invent a maximum")
    world.level, world.xpMax = 25, 1200
    world.environment.UnitXP = function() error("unavailable native API") end
    assert(world:find("self-testrealm").xpState == "unavailable", "Throwing XP APIs are guarded")
    world.environment.UnitXP = nil
    assert(world.collectStatus().xpState == "unavailable", "Unsupported XP APIs stay unavailable")
    local secret = {}
    world.environment.issecretvalue = function(value) return value == secret end
    world.environment.UnitXP = function() return secret end
    assert(world.collectStatus().xpState == "unavailable", "Secret XP is never inspected or sent")
    world.environment.UnitLevel = function() return secret end
    assert(world.collectStatus().level == 0, "Secret level is never compared or sent")
    world.environment.UnitLevel = function() error("unavailable level") end
    assert(world:find("self-testrealm").level == nil, "Throwing level APIs cannot escape overview rendering")
end

print("PASS: overview presence and native party actions")
