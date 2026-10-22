-- Overview presence and native party-action checks without the WoW UI or a live channel.
local loadNotifications = dofile("tests/support/notifications.lua")
local helpers = dofile("tests/support/helpers.lua")
local loadModule, copy, equal = helpers.loadModule, helpers.copy, helpers.equal

local function newAddon(saved, readOnly, name, configure)
    local world = {
        now = 0, epoch = 2000000000, name = name or "Self", level = 24, xp = 420, xpMax = 1000, maxLevel = 60,
        fingerprint = "first-group", connected = false, frames = {},
        invites = {}, joins = {}, positions = {},
        grouped = false, raid = false, leader = false, assistant = false,
        members = 0, sameParty = {}, refreshes = 0,
    }
    local function rejectTimer()
        error("Roster scheduling belongs to shared status")
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
            NewTimer = rejectTimer, NewTicker = rejectTimer, After = rejectTimer,
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
    function addon:SendData()
        error("Roster broadcasts belong to shared status")
    end
    function addon:RequestData()
        error("Roster discovery belongs to shared status")
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
        self.now = self.now + seconds
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
    world:peer("Remote-TestRealm", 30, false, true, false, false)
    assert(world:find("remote-testrealm").online)
    world:disconnect()
    assert(not world:find("remote-testrealm").online,
        "Losing the data connection cannot continue presenting remote players as active")
    world:connect()
    assert(not world:find("remote-testrealm").online, "Reconnection waits for current contact")
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
    for _, malformed in ipairs({ -1, "x", 1001 }) do
        assert(not world:status("Malformed-TestRealm", { level = malformed, xpState = "unavailable" }),
            "Malformed player metadata must be rejected")
    end
    for _, name in ipairs({ "", "Friend|TestRealm", string.rep("x", 129) }) do
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

-- Legacy bare names use the saved realm before login APIs are ready and remain qualified on later reloads.
do
    local source, clock = newAddon()
    clock:login(); clock:connect()
    assert(clock:peer("Friend", 31, true, true, false, false))
    assert(source.db.roster.peers["friend-testrealm"].name == "Friend-testrealm")
    local profile = copy(source.db)
    profile.roster.peers["friend-testrealm"].name = "Friend"
    profile.roster.peers["qualified-testrealm"] = { name = "Qualified-Test Realm", level = 19, seenAt = clock.epoch }
    local restored, world = newAddon(profile, false, nil, function(environment)
        environment.GetNormalizedRealmName = function() return nil end
    end)
    assert(restored.rosterState.peers["friend-testrealm"])
    world.environment.GetNormalizedRealmName = function() return "OtherRealm" end
    world:login(); world:connect(); world:advance(120)
    local friend = assert(world:find("friend-testrealm"))
    assert(not friend.online and friend.level == 31 and friend.name == "Friend-testrealm")
    assert(world:find("qualified-testrealm").name == "Qualified-Test Realm")
    local _, again = newAddon(copy(profile))
    again:login()
    assert(again:find("friend-testrealm") and not again:find("friend-testrealm").online)
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
    world:advance(100)
    assert(world.collectStatus() == nil and not world:peer("Friend-TestRealm", 31, true, true, false, false))
    local saved = copy(addon.db)
    saved.schemaVersion = 999
    local before = copy(saved)
    local guarded, clock = newAddon(saved, true)
    clock:login(); clock:connect()
    clock:peer("Other-TestRealm", 99, true, true, false, true)
    guarded:OnRosterGroupChanged()
    clock:advance(100)
    assert(equal(before, saved), "Newer-schema data must remain byte-for-byte unchanged")
    assert(not guarded:PerformOverviewAction("other-testrealm", "invite"))
end

-- Reload and reconnect preserve exact progress as stale until fresh contact arrives.
do
    local addon, world = newAddon()
    world:login(); world:connect()
    world.xp = 0
    world:event("PLAYER_XP_UPDATE", "player")
    assert(world:find("self-testrealm").xp == 0)
    assert(world:status("Friend-TestRealm", { level = 31, xp = 125, xpMax = 500, xpState = "known" }))
    local friend = world:find("friend-testrealm")
    assert(friend.xp == 125 and friend.xpMax == 500 and not friend.xpStale
        and friend.inParty == nil and friend.canInvite == nil)
    assert(not addon:GetOverviewActionState("friend-testrealm").invite,
        "Missing party flags cannot invent eligibility")
    local restoredAddon, clock = newAddon(copy(addon.db))
    clock:login(); clock:connect()
    local retained = clock:find("friend-testrealm")
    assert(retained.xp == 125 and retained.xpMax == 500 and retained.xpUpdatedAt == friend.xpUpdatedAt
        and not retained.online and retained.xpStale and not retained.statusSynchronized)
    assert(not restoredAddon:GetOverviewActionState("friend-testrealm").request)
    world:disconnect(); world:connect()
    assert(world:find("friend-testrealm").xp == 125 and world:find("friend-testrealm").xpStale)
    assert(world:status("Friend-TestRealm", { level = 31, xpState = "max" }, nil, 2))
    assert(world:find("friend-testrealm").xpState == "max" and not world:find("friend-testrealm").xpStale)
end
-- Saved party flags remain historical; transient ordering cannot authorize actions or reject a fresh sender.
do
    local addon, world = newAddon()
    world:login(); world:connect()
    local fields = { level = 31, xp = 125, xpMax = 500, xpState = "known", inParty = true,
        canInvite = false, partyFull = false, sharing = true }
    assert(world:status("Friend-TestRealm", fields, nil, 99, { session = "old", kind = "full", coherent = true }))
    local saved = copy(addon.db)
    local snapshot = saved.roster.peers["friend-testrealm"]
    assert(snapshot.inParty == true and snapshot.canInvite == false
        and snapshot.partyFull == false and snapshot.sharing == true)
    for _, key in ipairs({ "stamp", "sequence", "session", "lastReceived", "disconnected", "statusSynchronized" }) do
        assert(snapshot[key] == nil)
    end
    snapshot.stamp, snapshot.sequence, snapshot.session = world.epoch + 100, 999, "old"
    snapshot.lastReceived, snapshot.statusSynchronized = 0, true
    local restored, clock = newAddon(saved)
    clock:login(); clock:connect()
    assert(not clock:find("friend-testrealm").online and not restored:GetOverviewActionState("friend-testrealm").request)
    assert(clock:status("Friend-TestRealm", fields, clock.epoch, 1))
    assert(clock:find("friend-testrealm").online and not clock:find("friend-testrealm").xpStale
        and restored:GetOverviewActionState("friend-testrealm").request)
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

-- XP age changes with progress, sender sessions and resumed contact; ordinary presence refreshes preserve it.
do
    local addon, world = newAddon()
    world:login(); world:connect()
    local fields = { level = 31, xp = 10, xpMax = 500, xpState = "known", inParty = true,
        canInvite = true, partyFull = false, sharing = false }
    local function report(sequence, session)
        assert(world:status("Friend-TestRealm", fields, nil, sequence,
            { kind = "full", session = session or "first", coherent = true }))
    end
    report(1)
    world:advance(30)
    fields.sharing = true
    report(2)
    assert(world:find("friend-testrealm").xpUpdatedAt == world.epoch
        and not world:find("friend-testrealm").xpStale)
    world:advance(5)
    fields.xp = 15
    report(3)
    assert(world:find("friend-testrealm").xpUpdatedAt == world.epoch + 35)
    world:advance(5)
    report(1, "second")
    assert(world:find("friend-testrealm").xpUpdatedAt == world.epoch + 40)
    world:advance(91)
    assert(world:find("friend-testrealm").xpStale and not addon:GetOverviewActionState("friend-testrealm").request)
    report(2, "second")
    assert(world:find("friend-testrealm").xpUpdatedAt == world.epoch + 131
        and addon:GetOverviewActionState("friend-testrealm").request)
    local before = copy(addon.db)
    for _, malformed in ipairs({
        { level = 34, xp = 701, xpMax = 700, xpState = "known" },
        { level = 34, xp = 0, xpMax = 0, xpState = "known" },
        { level = 34, xpState = "future" }, { level = 0, xpState = "max" },
        { level = 34, xpState = "unavailable", partyFull = 0 }, { unrelated = "future provider" },
    }) do assert(not world:status("Malformed-TestRealm", malformed)) end
    assert(equal(before, addon.db))
    assert(world:status("Friend-TestRealm", { level = 33, xpState = "unavailable" }, nil, 3))
    assert(world:find("friend-testrealm").xp == nil and world:find("friend-testrealm").xpState == "unavailable")
    assert(world:status("UnknownFlags-TestRealm", { level = 33, xpState = "unavailable", inParty = true }))
    assert(not addon:GetOverviewActionState("unknownflags-testrealm").request)
end
-- Invalid newer player data cannot certify retained XP or enable actions; a valid refresh restores both.
do
    local addon, world = newAddon()
    world:login(); world:connect()
    local fields = { level = 31, xp = 42, xpMax = 1000, xpState = "known",
        inParty = true, canInvite = true, partyFull = false, sharing = false }
    assert(world:status("Friend-TestRealm", fields, nil, 1, { kind = "full", coherent = true }))
    local saved = copy(addon.db.roster.peers["friend-testrealm"])
    world:advance(5)
    fields.level, fields.xp = 32, 1001
    assert(not world:status("Friend-TestRealm", fields, nil, 2, { kind = "full", coherent = true }))
    local friend = world:find("friend-testrealm")
    assert(friend.level == 31 and friend.xp == 42 and friend.xpStale and not friend.statusSynchronized
        and equal(saved, addon.db.roster.peers["friend-testrealm"]))
    assert(not addon:GetOverviewActionState("friend-testrealm").request)
    fields.xp = 45
    assert(world:status("Friend-TestRealm", fields, nil, 3, { kind = "full", coherent = true }))
    assert(world:find("friend-testrealm").xp == 45 and not world:find("friend-testrealm").xpStale
        and addon:GetOverviewActionState("friend-testrealm").request)
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

-- Native membership is cached separately from shared party flags and survives without a LIT group.
do
    local native = { raid = false, partyCount = 0, raidCount = 0, units = {}, reads = 0, modeReads = 0 }
    local addon, world = newAddon(nil, false, nil, function(environment)
        environment.IsInRaid = function() native.modeReads = native.modeReads + 1; return native.raid end
        environment.GetNumGroupMembers = function() return native.raidCount end
        environment.GetNumSubgroupMembers = function() return native.partyCount end
        local unitFullName = environment.UnitFullName
        environment.UnitFullName = function(unit)
            if unit == "player" then return unitFullName(unit) end
            native.reads = native.reads + 1
            local member = native.units[unit]
            if member then return member[1], member[2] end
        end
    end)
    local changed = 0
    addon:RegisterNotification("NATIVE_GROUP_CHANGED", function() changed = changed + 1 end)
    assert(addon:GetNativeGroupUnit("Friend-TestRealm") == nil)
    addon:InitializeNativeGroupMembership()
    assert(native.modeReads == 1 and native.reads == 0 and changed == 0,
        "Initialization and repeated lookups cannot rescan the native roster")

    native.partyCount = 3
    native.units = { party1 = { "Friend", "Test Realm" }, party2 = { "Friend", "Other Realm" },
        party3 = { "Local", "" } }
    world:event("GROUP_ROSTER_UPDATE")
    assert(addon:GetNativeGroupUnit("FRIEND-testrealm") == "party1"
        and addon:GetNativeGroupUnit("Friend-Other Realm") == "party2"
        and addon:GetNativeGroupUnit("Friend") == "party1"
        and addon:GetNativeGroupUnit("Local-TestRealm") == "party3",
        "Full normalized realm identities distinguish matching cross-realm character names")
    local reads, modes = native.reads, native.modeReads
    for _ = 1, 10 do assert(addon:GetNativeGroupUnit("Friend-OtherRealm") == "party2") end
    assert(native.reads == reads and native.modeReads == modes and changed == 1,
        "A map render performs cached membership lookups only")
    addon.rosterState.peers["remote-testrealm"] = { name = "Remote-TestRealm", inParty = true }
    assert(addon:GetNativeGroupUnit("Remote-TestRealm") == nil,
        "A shared inParty flag does not identify membership in our own native group")

    native.units.party1 = { "Renamed", "TestRealm" }
    world:event("UNIT_NAME_UPDATE", "target")
    world:event("UNIT_NAME_UPDATE", "partypet1")
    world:event("UNIT_NAME_UPDATE", {})
    assert(addon:GetNativeGroupUnit("Friend-TestRealm") == "party1" and native.reads == reads and changed == 1)
    world:event("UNIT_NAME_UPDATE", "party1")
    assert(addon:GetNativeGroupUnit("Friend-TestRealm") == nil
        and addon:GetNativeGroupUnit("Renamed-TestRealm") == "party1" and changed == 2)

    native.raid, native.raidCount = true, 3
    native.units = { raid1 = { "Self", "TestRealm" }, raid2 = { "Friend", "OtherRealm" },
        raid3 = { "Raidmate", "TestRealm" } }
    world:event("GROUP_ROSTER_UPDATE")
    assert(addon:GetNativeGroupUnit("Renamed-TestRealm") == nil
        and addon:GetNativeGroupUnit("Friend-OtherRealm") == "raid2"
        and addon:GetNativeGroupUnit("Friend") == nil and changed == 3,
        "Converting to raid replaces party tokens without matching a short name to a foreign realm")
    native.units.raid2 = { "Fresh", "OtherRealm" }
    world:event("UNIT_NAME_UPDATE", "raid2")
    assert(addon:GetNativeGroupUnit("Friend-OtherRealm") == nil
        and addon:GetNativeGroupUnit("Fresh-OtherRealm") == "raid2" and changed == 4)

    -- The native roster remains useful with no writable/shared addon group.
    world.fingerprint, addon.savedDataReadOnly = nil, true
    native.units.raid3 = { "Reloaded", "TestRealm" }
    world:event("PLAYER_ENTERING_WORLD")
    assert(addon:GetNativeGroupUnit("Reloaded-TestRealm") == "raid3" and changed == 5)
    world:event("UNIT_NAME_UPDATE", "player")
    assert(changed == 6, "Player name updates may resolve a previously unavailable local realm")
    native.raid, native.partyCount, native.raidCount = false, 0, 0
    world:event("GROUP_ROSTER_UPDATE")
    assert(addon:GetNativeGroupUnit("Reloaded-TestRealm") == nil
        and next(addon.nativeGroupMembership.units) == nil and changed == 7,
        "Leaving the native group immediately discards every cached token")
end

-- Native full names and unmodified addon sender names can use different realm aliases.
do
    local secret = {}
    local native = { units = { party1 = { "Friend", "Internal Realm" }, party2 = { "Friend", "Other Realm" } },
        aliases = { party1 = "Friend", party2 = "Friend-Other Realm" }, aliasReads = 0 }
    local addon, world = newAddon(nil, false, nil, function(environment)
        environment.issecretvalue = function(value) return value == secret end
        environment.GetNumSubgroupMembers = function() return 2 end
        local fullName, unmodifiedName = environment.UnitFullName, environment.NameUtil.GetUnmodifiedUnitFullName
        environment.UnitFullName = function(unit)
            if unit == "player" then return fullName(unit) end
            local member = native.units[unit]
            if member then return member[1], member[2] end
        end
        environment.NameUtil.GetUnmodifiedUnitFullName = function(unit)
            if unit == "player" then return unmodifiedName(unit) end
            native.aliasReads = native.aliasReads + 1
            return native.aliases[unit]
        end
    end)
    local environment = world.environment
    local fullName, unmodifiedName = environment.UnitFullName, environment.NameUtil.GetUnmodifiedUnitFullName
    assert(addon:GetNativeGroupUnit("Friend-InternalRealm") == "party1"
        and addon:GetNativeGroupUnit("Friend-TestRealm") == "party1"
        and addon:GetNativeGroupUnit("Friend") == "party1"
        and addon:GetNativeGroupUnit("Friend-OtherRealm") == "party2",
        "Both native and wire identities resolve without matching a foreign realm by short name")
    local reads = native.aliasReads
    for _ = 1, 10 do assert(addon:GetNativeGroupUnit("Friend-TestRealm") == "party1") end
    assert(native.aliasReads == reads, "Unmodified name aliases are read only during roster refreshes")

    native.aliases.party1, native.aliases.party2 = "Shared-TestRealm", "Shared-TestRealm"
    world:event("GROUP_ROSTER_UPDATE")
    assert(addon:GetNativeGroupUnit("Shared-TestRealm") == nil
        and addon:GetNativeGroupUnit("Friend-TestRealm") == nil
        and addon:GetNativeGroupUnit("Friend-InternalRealm") == "party1"
        and addon:GetNativeGroupUnit("Friend-OtherRealm") == "party2",
        "Ambiguous aliases identify neither unit, while distinct complete identities remain usable")
    native.aliases.party1 = "Renamed-TestRealm"
    world:event("UNIT_NAME_UPDATE", "party1")
    assert(addon:GetNativeGroupUnit("Renamed-TestRealm") == "party1"
        and addon:GetNativeGroupUnit("Shared-TestRealm") == "party2",
        "Refreshing removes obsolete aliases and resolves former collisions from the current roster")

    for _, result in ipairs({ "missing", "error" }) do
        if result == "missing" then environment.UnitFullName = nil
        else environment.UnitFullName = function() error("full name unavailable") end end
        addon:RefreshNativeGroupMembership()
        assert(addon:GetNativeGroupUnit("Renamed-TestRealm") == "party1"
            and addon:GetNativeGroupUnit("Friend-InternalRealm") == nil,
            "Unmodified names remain usable when UnitFullName is " .. result)
    end
    environment.UnitFullName = fullName
    for _, result in ipairs({ "missing", "error", "secret", "malformed" }) do
        if result == "missing" then environment.NameUtil = nil
        elseif result == "error" then environment.NameUtil = { GetUnmodifiedUnitFullName = function() error("alias unavailable") end }
        else environment.NameUtil = { GetUnmodifiedUnitFullName = function() return result == "secret" and secret or {} end } end
        addon:RefreshNativeGroupMembership()
        assert(addon:GetNativeGroupUnit("Friend-InternalRealm") == "party1"
            and addon:GetNativeGroupUnit("Renamed-TestRealm") == nil,
            "An unavailable or invalid unmodified alias cannot erase a valid native full name")
    end
    environment.NameUtil = { GetUnmodifiedUnitFullName = unmodifiedName }
    native.aliases.party1 = "Friend"
    environment.GetNormalizedRealmName = nil
    addon:RefreshNativeGroupMembership()
    assert(addon:GetNativeGroupUnit("Friend-TestRealm") == nil
        and addon:GetNativeGroupUnit("Shared-TestRealm") == "party2",
        "An unresolved local realm rejects short aliases while retaining complete aliases")
end

-- Missing, secret, throwing and incomplete native APIs fail open instead of inventing membership.
do
    local secret = {}
    local addon, world = newAddon(nil, false, nil, function(environment)
        environment.issecretvalue = function(value) return value == secret end
        environment.IsInRaid = function() return false end
        environment.GetNumSubgroupMembers = function() return 1 end
        local unitFullName = environment.UnitFullName
        environment.UnitFullName = function(unit)
            if unit == "party1" then return "Friend", "TestRealm" end
            return unitFullName(unit)
        end
    end)
    local environment = world.environment
    local original = { IsInRaid = environment.IsInRaid, GetNumSubgroupMembers = environment.GetNumSubgroupMembers,
        UnitFullName = environment.UnitFullName, GetNormalizedRealmName = environment.GetNormalizedRealmName }
    assert(addon:GetNativeGroupUnit("Friend-TestRealm") == "party1")
    for _, api in ipairs({ "IsInRaid", "GetNumSubgroupMembers", "UnitFullName" }) do
        for _, result in ipairs({ "missing", "error", "secret", "unknown", "malformed" }) do
            if result == "missing" then environment[api] = nil
            elseif result == "error" then environment[api] = function() error("native roster unavailable") end
            elseif result == "secret" then environment[api] = function() return secret end
            elseif result == "malformed" then environment[api] = function() return {} end
            else environment[api] = function() return nil end end
            addon:RefreshNativeGroupMembership()
            assert(addon:GetNativeGroupUnit("Friend-TestRealm") == nil,
                api .. " " .. result .. " must clear old native membership")
            environment[api] = original[api]
            addon:RefreshNativeGroupMembership()
            assert(addon:GetNativeGroupUnit("Friend-TestRealm") == "party1")
        end
    end
    environment.IsInRaid = function() return true end
    for _, result in ipairs({ -1, 41, 1.5, secret, "2" }) do
        environment.GetNumGroupMembers = function() return result end
        addon:RefreshNativeGroupMembership()
        assert(addon:GetNativeGroupUnit("Friend-TestRealm") == nil)
    end
    environment.GetNumGroupMembers = function() error("raid roster unavailable") end
    addon:RefreshNativeGroupMembership()
    assert(addon:GetNativeGroupUnit("Friend-TestRealm") == nil)
    environment.GetNumGroupMembers = nil
    addon:RefreshNativeGroupMembership()
    assert(addon:GetNativeGroupUnit("Friend-TestRealm") == nil)
    environment.IsInRaid = original.IsInRaid

    for _, member in ipairs({ { secret, "TestRealm" }, { "Friend", secret }, { "Friend", {} },
        { "Bad|Name", "TestRealm" }, { "Friend", "Bad|Realm" }, { "Friend", " " } }) do
        environment.UnitFullName = function() return member[1], member[2] end
        addon:RefreshNativeGroupMembership()
        assert(addon:GetNativeGroupUnit("Friend-TestRealm") == nil)
    end
    assert(addon:GetNativeGroupUnit(secret) == nil and addon:GetNativeGroupUnit({}) == nil)

    environment.UnitFullName = function() return "Friend", "" end
    for _, result in ipairs({ "missing", "error", "secret", "unknown" }) do
        if result == "missing" then environment.GetNormalizedRealmName = nil
        elseif result == "error" then environment.GetNormalizedRealmName = function() error("realm unavailable") end
        elseif result == "secret" then environment.GetNormalizedRealmName = function() return secret end
        else environment.GetNormalizedRealmName = function() return nil end end
        addon:RefreshNativeGroupMembership()
        assert(addon:GetNativeGroupUnit("Friend-TestRealm") == nil
            and addon:GetNativeGroupUnit("Friend") == nil,
            "An unresolved native realm cannot turn a short name into a full identity")
    end
    environment.GetNormalizedRealmName = original.GetNormalizedRealmName
    world:event("UNIT_NAME_UPDATE", "player")
    assert(addon:GetNativeGroupUnit("Friend-TestRealm") == "party1")
    local reads = addon.nativeGroupMembership.units
    world:event("UNIT_NAME_UPDATE", secret)
    assert(addon.nativeGroupMembership.units == reads, "Secret unit events cannot be inspected")
end

print("PASS: overview presence, native party actions and membership cache")
