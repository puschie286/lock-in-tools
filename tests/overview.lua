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

local function newAddon(saved, readOnly, name)
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
    function addon:RegisterDataStatusProvider(name, collect, receive, connected, contact)
        assert(name == "player", "All player metadata must share the generic status transport")
        assert(type(contact) == "function", "Shared heartbeats drive roster contact")
        world.collectStatus, world.receiveStatus, world.statusConnected, world.contactStatus = collect, receive, connected, contact
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
        for key, value in pairs(fields) do decoded[key] = tostring(value) end
        return self.receiveStatus(name, decoded, stamp or self.epoch + math.floor(self.now), sequence or 1, metadata)
    end
    function world:contact(name, metadata)
        return self.contactStatus(name, self.epoch + math.floor(self.now), metadata or { kind = "heartbeat", coherent = true })
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
    assert(world.collectStatus() == nil and not world:contact("Friend-TestRealm"))
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

-- XP remains session-only and unchanged XP stays current while shared heartbeats continue.
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
        assert(world:contact("Friend-TestRealm"))
        friend = world:find("friend-testrealm")
        assert(friend.xp == 125 and friend.xpUpdatedAt == world.epoch and not friend.xpStale,
            "Unchanged XP stays valid while presence continues, regardless of sample age")
    end
    local saved = addon.db.roster.peers["friend-testrealm"]
    for key in pairs(saved) do
        assert(key == "name" or key == "level" or key == "seenAt", "XP must never enter SavedVariables")
    end
    local _, restored = newAddon(copy(addon.db))
    restored:login()
    assert(restored:find("friend-testrealm").xp == nil and restored:find("friend-testrealm").xpState == "unavailable")
    world:advance(91)
    friend = world:find("friend-testrealm")
    assert(not friend.online and friend.xpStale and friend.xp == 125, "Inactive XP is retained with a stale marker")
    world:disconnect()
    assert(world:find("friend-testrealm").xpStale)
    world:connect()
    assert(world:find("friend-testrealm").xp == nil, "Reconnect waits for a fresh requested status snapshot")
    assert(world:status("Friend-TestRealm", { level = 31, xpState = "max" }))
    assert(world:find("friend-testrealm").xpState == "max" and not world:find("friend-testrealm").xpStale)
    world.fingerprint = "second-group"
    addon:OnRosterGroupChanged()
    assert(world:find("friend-testrealm") == nil and next(addon.rosterState.progress) == nil,
        "Group changes clear all session progress")
end

-- Full snapshots establish a sample; merged deltas and heartbeats preserve its age until XP changes.
do
    local addon, world = newAddon()
    world:login(); world:connect()
    local fields = { level = 31, xp = 10, xpMax = 500, xpState = "known", inParty = false,
        canInvite = true, partyFull = false, sharing = false }
    assert(world:status("Friend-TestRealm", fields, nil, 1, { kind = "full", session = "first", coherent = true }))
    world:advance(5)
    fields.inParty, fields.sharing = true, true
    assert(world:status("Friend-TestRealm", fields, nil, 2, { kind = "delta", session = "first", coherent = true }))
    local friend = world:find("friend-testrealm")
    assert(friend.level == 31 and friend.xp == 10 and friend.inParty and friend.sharing)
    assert(friend.xpUpdatedAt == world.epoch and friend.seenAt == world.epoch + 5,
        "A party-only delta updates presence without renewing the XP sample timestamp")
    world:advance(25)
    assert(world:contact("Friend-TestRealm"))
    friend = world:find("friend-testrealm")
    assert(friend.online and not friend.xpStale and friend.xpUpdatedAt == world.epoch)
    world:advance(5)
    fields.xp = 15
    assert(world:status("Friend-TestRealm", fields, nil, 3, { kind = "delta", session = "first", coherent = true }))
    assert(world:find("friend-testrealm").xpUpdatedAt == world.epoch + 35)
    world:advance(5)
    assert(world:status("Friend-TestRealm", fields, nil, 4, { kind = "full", session = "first", coherent = true }))
    assert(world:find("friend-testrealm").xpUpdatedAt == world.epoch + 40,
        "A requested full snapshot confirms unchanged XP freshly")
    fields.level, fields.xp, fields.xpMax = 32, 0, 600
    assert(world:status("Friend-TestRealm", fields, nil, 1, { kind = "full", session = "second", coherent = true }),
        "A new sender session can reset its revision in the same server second")
    world:advance(5)
    assert(world:contact("Friend-TestRealm"))
    friend = world:find("friend-testrealm")
    assert(friend.level == 32 and friend.xp == 0 and friend.inParty and friend.sharing)
    assert(friend.seenAt == world.epoch + 45 and friend.xpUpdatedAt == world.epoch + 40)
    assert(world:contact("Friend-TestRealm", { kind = "heartbeat", coherent = false }))
    friend = world:find("friend-testrealm")
    assert(friend.online and friend.xpStale and friend.xp == 0,
        "A heartbeat exposing a missed delta confirms activity but leaves retained XP stale")
    assert(not addon:GetOverviewActionState("friend-testrealm").request,
        "A missed status update cannot authorize actions from stale party metadata")
    assert(world:contact("Friend-TestRealm"))
    assert(world:find("friend-testrealm").xpStale, "Contact alone cannot resynchronize stale XP")
    assert(world:status("Friend-TestRealm", fields, nil, 2, { kind = "full", session = "second", coherent = true }))
    assert(not world:find("friend-testrealm").xpStale and addon:GetOverviewActionState("friend-testrealm").request)
    assert(world:contact("Friend-TestRealm", { kind = "heartbeat", coherent = false }))
    assert(world:status("Friend-TestRealm", fields, nil, 2, { kind = "full", session = "second", coherent = true }),
        "A centrally accepted requested full snapshot can confirm an unchanged revision in the same second")
    assert(not world:find("friend-testrealm").xpStale)
    assert(not world:contact("Unknown-TestRealm"), "Heartbeats cannot discover a peer without a valid player snapshot")
    local before = copy(addon.db)
    for _, malformed in ipairs({
        { level = 34, xp = -1, xpMax = 700, xpState = "known" },
        { level = 34, xp = 701, xpMax = 700, xpState = "known" },
        { level = 34, xp = 0, xpMax = 0, xpState = "known" },
        { level = 34, xpMax = 700, xpState = "known" },
        { level = 34, xpState = "future" }, { level = 0, xpState = "max" },
        { level = 34, xpState = "unavailable", inParty = "maybe" },
        { level = 34, xpState = "unavailable", sharing = "1" },
        { level = 34 }, { unrelated = "future provider" },
    }) do
        assert(not world:status("Malformed-TestRealm", malformed), "Malformed player status is ignored")
    end
    assert(not world:status("SELF-TestRealm", { level = 99, xpState = "max" }))
    assert(equal(before, addon.db), "Rejected progress cannot alter saved roster data")
    assert(world:status("Friend-TestRealm", { level = 33, xpState = "unavailable" }, nil, 3))
    friend = world:find("friend-testrealm")
    assert(friend.xp == nil and friend.xpMax == nil and friend.xpState == "unavailable",
        "Unavailable snapshots replace previously known progress")
    assert(world:status("UnknownFlags-TestRealm", { level = 33, xpState = "unavailable", inParty = true }))
    assert(not addon:GetOverviewActionState("unknownflags-testrealm").request,
        "Unknown party capacity must not be treated as available space")
end

-- A structurally valid status frame can still fail player-data validation.
-- Subsequent coherent transport contact cannot certify the rejected sample.
do
    local addon, world = newAddon()
    world:login(); world:connect()
    local fields = { level = 31, xp = 42, xpMax = 1000, xpState = "known",
        inParty = true, canInvite = true, partyFull = false, sharing = false }
    assert(world:status("Friend-TestRealm", fields, nil, 1, { kind = "full", coherent = true }))
    assert(addon:GetOverviewActionState("friend-testrealm").request)
    local saved = copy(addon.db)
    world:advance(5)
    fields.level, fields.xp = 32, 1001
    assert(not world:status("Friend-TestRealm", fields, nil, 2, { kind = "delta", coherent = true }))
    local friend = world:find("friend-testrealm")
    assert(friend.level == 31 and friend.xp == 42 and friend.xpStale and friend.statusSynchronized == false,
        "Rejected newer player data leaves the previous sample visibly stale")
    assert(friend.xpUpdatedAt == world.epoch and equal(saved, addon.db), "Invalid player fields cannot reach saved metadata")
    assert(not addon:GetOverviewActionState("friend-testrealm").request)
    world:advance(30)
    assert(world:contact("Friend-TestRealm", { kind = "heartbeat", coherent = true }))
    friend = world:find("friend-testrealm")
    assert(friend.online and friend.xpStale and not addon:GetOverviewActionState("friend-testrealm").request,
        "Transport heartbeats cannot make a semantically rejected player sample current")
    fields.level, fields.xp = 32, 45
    assert(world:status("Friend-TestRealm", fields, nil, 3, { kind = "delta", coherent = true }))
    friend = world:find("friend-testrealm")
    assert(friend.level == 32 and friend.xp == 45 and not friend.xpStale and friend.statusSynchronized,
        "A valid merged delta restores the current player state")
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
