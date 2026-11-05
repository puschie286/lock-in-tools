-- This harness is never loaded by the addon.
local fixtures = dofile("tests/support/addon.lua")
local loadAddon = fixtures.loadAddon
local settings = fixtures.settings
local OTHER_SECRET = fixtures.OTHER_SECRET

-- Channel preferences default old or malformed profiles on without losing
-- explicit opt-outs or unrelated saved fields.
for _, seed in ipairs({
    {}, { data = false }, { data = "invalid" },
    { data = { channels = 12, future = "preserved" } },
    { data = { channels = { party = false, guild = "false", global = false, future = "preserved" },
        future = "preserved" } },
}) do
    local profile = settings("", false)
    profile.data = seed.data
    local channels = type(seed.data) == "table" and type(seed.data.channels) == "table" and seed.data.channels
    local party, guild = not channels or channels.party ~= false,
        not channels or channels.guild ~= false
    local current, _, _, event = loadAddon(profile, false)
    event("ADDON_LOADED", "LockInTools")
    assert(current:GetDataChannelEnabled("party") == party and current:GetDataChannelEnabled("guild") == guild
        and not current:GetDataChannelEnabled("global")
        and profile.data.channels.party == party and profile.data.channels.guild == guild
        and profile.data.channels.global == nil,
        "Channel defaults repair malformed values while retaining saved false values")
    if type(seed.data) == "table" then
        assert(profile.data.future == "preserved")
        if channels then assert(profile.data.channels.future == "preserved") end
    end
    assert(profile.schemaVersion == 4, "Retired channel preferences migrate to the native-only schema")
end

-- Saving channel preferences before login changes only account-wide settings;
-- all-disabled profiles remain quiet across reloads despite native membership.
do
    local profile = settings(nil, false)
    profile.data = { channels = { party = false, guild = false, global = false } }
    local current, _, _, event, clock = loadAddon(profile, false)
    clock.grouped, clock.guild = true, true
    assert(not current:SetDataChannelEnabled("guild", true))
    event("ADDON_LOADED", "LockInTools")
    local changes = 0
    current:RegisterNotification("DATA_CHANGED", function() changes = changes + 1 end)
    assert(current:SetDataChannelEnabled("party", true) and current:SetDataChannelEnabled("guild", true)
        and not current:SetDataChannelEnabled("global", true) and changes == 2)
    clock:advance(30)
    assert(#clock.dataJoinCalls == 0 and #clock.statusSends == 0 and #clock.dataSends == 0,
        "Enabling routes during loading cannot send or join before login")
    assert(current:SetDataChannelEnabled("party", false) and current:SetDataChannelEnabled("guild", false)
        and not current:SetDataChannelEnabled("global", false) and changes == 4)
    assert(not current:SetDataChannelEnabled("raid", true)
        and not current:SetDataChannelEnabled("guild", "true")
        and not current:SetDataChannelEnabled(nil, false)
        and not current:GetDataChannelEnabled("guild") and changes == 4,
        "Invalid channel settings cannot accidentally enable a route")
    local restored, _, _, _, restoredClock = loadAddon(profile, false)
    restoredClock.grouped, restoredClock.guild = true, true
    restoredClock:initialize()
    restoredClock:advance(30)
    assert(not restored:GetDataChannelEnabled("party") and not restored:GetDataChannelEnabled("guild")
        and not restored:GetDataChannelEnabled("global") and not restored:IsDataConnected()
        and #restoredClock.dataJoinCalls == 0 and #restoredClock.statusSends == 0
        and #restoredClock.dataSends == 0,
        "Saved opt-outs keep native sharing disabled after reload")
end

-- Sharing changes refresh views once, after the final route status is available.
do
    local current, _, _, _, clock = loadAddon(settings(nil, false), false)
    clock.grouped, clock.guild = true, true
    clock:initialize()
    local statuses = {}
    current:RegisterNotification("DATA_CHANGED", function()
        statuses[#statuses + 1] = current:GetDataStatusText()
    end)
    assert(current:SetDataChannelEnabled("party", false) and #statuses == 1
        and statuses[1] == "Data routes: guild." and current:IsDataConnected())
    assert(current:SetDataChannelEnabled("guild", false) and #statuses == 2
        and statuses[2] == "All data channels are disabled." and not current:IsDataConnected())
    assert(current:SetDataChannelEnabled("party", true) and #statuses == 3
        and statuses[3] == "Data routes: party." and current:IsDataConnected())
    assert(current:SetDataChannelEnabled("guild", true) and #statuses == 4
        and statuses[4] == "Data routes: party, guild.")
    assert(current:SetDataChannelEnabled("guild", true) and #statuses == 4,
        "Unchanged sharing preferences do not refresh views")
end

-- Newer-schema profiles remain untouched and cannot enable data routes.
do
    local profile = settings(nil, false)
    profile.schemaVersion = 5
    local channels = { party = false, guild = "future-value", global = true, future = "preserved" }
    local data = { channels = channels, future = "preserved" }
    profile.data = data
    local current, environment, _, _, clock = loadAddon(profile, false)
    clock.grouped, clock.guild = true, true
    clock:initialize()
    assert(not current:SetDataChannelEnabled("party", true)
        and not current:SetDataChannelEnabled("global", false))
    clock:advance(30)
    assert(environment.LockInToolsDB == profile and profile.schemaVersion == 5
        and profile.data == data and profile.data.channels == channels
        and channels.party == false and channels.guild == "future-value" and channels.global == true
        and channels.future == "preserved" and data.future == "preserved"
        and not current:IsDataConnected() and #clock.dataJoinCalls == 0 and #clock.statusSends == 0,
        "Read-only channel preferences never normalize the source profile or start traffic")
end

-- Saved roster and position identities merge before login without treating historical peers as live.
do
    local fingerprint, stamp = "legacy-group", 1999999800
    local profile = settings(nil, false)
    profile.roster = { groupFingerprint = fingerprint, peers = {
        ["rosteronly-testrealm"] = { name = "RosterOnly", level = 21, seenAt = stamp },
        ["shared-testrealm"] = { name = "Shared", level = 32, seenAt = stamp },
    } }
    profile.position = { sharing = true, keepLastKnown = true, groupFingerprint = fingerprint, peers = {
        ["shared-testrealm"] = { name = "Shared", map = 37, x = 0.2, y = 0.3,
            stamp = stamp, positionStamp = stamp - 10, class = "HUNTER" },
        ["positiononly-remoterealm"] = { name = "PositionOnly-Remote Realm", map = 37, x = 0.4, y = 0.5,
            stamp = stamp, positionStamp = stamp - 20, class = "MAGE" },
    } }
    local restored, environment, _, event, world = loadAddon(profile, false)
    world.guild = true
    environment.GetNormalizedRealmName = function() return nil end
    event("ADDON_LOADED", "LockInTools")
    assert(restored.rosterState.peers["rosteronly-testrealm"]
        and restored.positionState.peers["shared-testrealm"])
    environment.GetNormalizedRealmName = function() return "TestRealm" end
    event("PLAYER_LOGIN")
    local rows = {}
    for _, row in ipairs(restored:GetOverviewPlayers()) do rows[row.id] = row end
    assert(rows["self-testrealm"].isSelf and rows["rosteronly-testrealm"].level == 21)
    assert(rows["shared-testrealm"].level == 32 and rows["shared-testrealm"].x == 0.2
        and rows["shared-testrealm"].positionStamp == stamp - 10 and not rows["shared-testrealm"].online)
    assert(rows["positiononly-remoterealm"].x == 0.4 and not rows["positiononly-remoterealm"].online
        and rows["positiononly-remoterealm"].xpState == "unavailable")
end
-- Native guild and party/raid routes connect the complete addon without setup.
-- Overlapping deliveries keep one roster entry, position and Burned report per player.
do
    local aliceProfile, bobProfile = settings(nil, false), settings(OTHER_SECRET, false)
    aliceProfile.burned, bobProfile.burned = { status = 20 }, { status = 80 }
    local alice, aliceEnvironment, _, aliceEvent, aliceWorld = loadAddon(aliceProfile, false)
    local bob, bobEnvironment, _, bobEvent, bobWorld = loadAddon(bobProfile, false)
    aliceEnvironment.UnitFullName = function() return "Alice", "Test Realm" end
    bobEnvironment.UnitFullName = function() return "Bob", "Test Realm" end
    aliceEnvironment.UnitClass = function() return "Mage", "MAGE" end
    bobEnvironment.UnitClass = function() return "Hunter", "HUNTER" end
    aliceWorld.grouped, aliceWorld.guild, aliceWorld.xp = true, true, 125
    bobWorld.grouped, bobWorld.guild, bobWorld.xp = true, true, 750
    aliceEvent("ADDON_LOADED", "LockInTools")
    bobEvent("ADDON_LOADED", "LockInTools")
    assert(not alice:IsDataConnected() and not bob:IsDataConnected()
        and #aliceWorld.statusSends == 0 and #bobWorld.statusSends == 0)
    aliceEvent("PLAYER_LOGIN")
    bobEvent("PLAYER_LOGIN")
    assert(alice:IsDataConnected() and bob:IsDataConnected()
        and not alice.dataState.routes.CHANNEL and not bob.dataState.routes.CHANNEL
        and #aliceWorld.dataJoinCalls == 0 and #bobWorld.dataJoinCalls == 0,
        "Party and guild start all status providers without custom channels")
    local function deliver(sends, first, last, receive, sender)
        for index = first, last do
            local sent = assert(sends[index])
            receive("CHAT_MSG_ADDON", sent.prefix, sent.message, sent.distribution, sender)
        end
    end
    local function player(current, id)
        local found, count = nil, 0
        for _, row in ipairs(current:GetOverviewPlayers()) do
            count = count + 1
            if row.id == id then found = row end
        end
        return found, count
    end
    assert(#aliceWorld.statusSends == 2 and #bobWorld.statusSends == 2
        and aliceWorld.statusSends[1].distribution == "PARTY"
        and aliceWorld.statusSends[2].distribution == "GUILD"
        and aliceWorld.statusSends[1].message == aliceWorld.statusSends[2].message,
        "Every native route carries the same initial request ID and snapshot")
    deliver(aliceWorld.statusSends, 1, 2, bobEvent, "Alice")
    deliver(bobWorld.statusSends, 1, 2, aliceEvent, "Bob")
    assert(#aliceWorld.statusSends == 4 and #bobWorld.statusSends == 4,
        "A request arriving on party and guild produces one reply fanned out over both routes")
    deliver(aliceWorld.statusSends, 3, 4, bobEvent, "Alice")
    deliver(bobWorld.statusSends, 3, 4, aliceEvent, "Bob")
    local bobRow, aliceCount = player(alice, "bob-testrealm")
    local aliceRow, bobCount = player(bob, "alice-testrealm")
    assert(aliceCount == 2 and bobCount == 2 and bobRow.online and aliceRow.online
        and bobRow.xp == 750 and aliceRow.xp == 125
        and alice:GetGroupBurnedStatus().count == 2 and alice:GetGroupBurnedStatus().average == 50
        and bob:GetGroupBurnedStatus().count == 2 and bob:GetGroupBurnedStatus().average == 50
        and alice:GetSharedPositions()["bob-testrealm"].class == "HUNTER",
        "Native routes exchange XP, class, positions and Burned without double-counting")

    local rosterChanges, burnedChanges, positionChanges = 0, 0, 0
    alice:RegisterNotification("ROSTER_CHANGED", function() rosterChanges = rosterChanges + 1 end)
    alice:RegisterNotification("BURNED_CHANGED", function() burnedChanges = burnedChanges + 1 end)
    alice:RegisterNotification("POSITIONS_CHANGED", function() positionChanges = positionChanges + 1 end)
    bobWorld.xp = 925
    assert(bob:SetBurnedStatus(90))
    bobWorld:advance(5)
    deliver(bobWorld.statusSends, 5, 5, aliceEvent, "Bob")
    aliceWorld:advance(1)
    deliver(bobWorld.statusSends, 6, 6, aliceEvent, "BOB-Test Realm")
    bobRow, aliceCount = player(alice, "bob-testrealm")
    assert(bobRow.xp == 925 and aliceCount == 2
        and alice:GetGroupBurnedStatus().count == 2 and alice:GetGroupBurnedStatus().average == 55
        and rosterChanges == 1 and burnedChanges == 1 and positionChanges == 1,
        "Duplicate broadcasts update the complete status and its embedded position once")
    bobEnvironment.C_Map.GetPlayerMapPosition = function()
        return { GetXY = function() return 0.6, 0.2 end }
    end
    bobWorld:advance(1)
    assert(#bobWorld.dataSends == 2 and bobWorld.dataSends[1].message == bobWorld.dataSends[2].message)
    deliver(bobWorld.dataSends, 1, 1, aliceEvent, "Bob")
    local position = assert(alice:GetSharedPositions()["bob-testrealm"])
    local receivedAt = position.lastReceived
    aliceWorld:advance(1)
    deliver(bobWorld.dataSends, 2, 2, aliceEvent, "BOB-Test Realm")
    assert(alice:GetSharedPositions()["bob-testrealm"].x == 0.6 and positionChanges == 2
        and alice:GetGroupBurnedStatus().count == 2,
        "Duplicate movement reports retain one position and do not affect status counts")

    assert(alice:RegisterDataRequest("probe", function() return "own" end, function() end))
    local accepted, requestID = alice:RequestData("probe", "pending")
    assert(accepted)
    local state = alice.dataState
    local session, received, pending = state.status.session, state.status.received, state.pendingRequests[requestID]
    local peer = alice.burnedState.peers["bob-testrealm"]
    aliceWorld.grouped, aliceWorld.raid = false, true
    bobWorld.grouped, bobWorld.raid = false, true
    aliceEvent("GROUP_ROSTER_UPDATE")
    bobEvent("GROUP_ROSTER_UPDATE")
    assert(state.routes.RAID and state.routes.GUILD and not state.routes.PARTY
        and state.status.session == session and state.pendingRequests[requestID] == pending)
    bobWorld.xp = 975
    local firstRaid = #bobWorld.statusSends + 1
    bobWorld:advance(4)
    assert(bobWorld.statusSends[firstRaid].distribution == "RAID")
    deliver(bobWorld.statusSends, firstRaid, #bobWorld.statusSends, aliceEvent, "Bob")
    assert(player(alice, "bob-testrealm").xp == 975 and alice:GetGroupBurnedStatus().count == 2,
        "Party-to-raid changes send and receive status without resetting other routes")
    aliceWorld.guild = false
    aliceEvent("PLAYER_GUILD_UPDATE", "player")
    assert(state.routes.RAID and not state.routes.GUILD and alice:IsDataConnected())
    aliceWorld.raid = false
    aliceEvent("GROUP_ROSTER_UPDATE")
    assert(not alice:IsDataConnected() and next(state.pendingRequests) == nil
        and alice:GetGroupBurnedStatus().count == 0,
        "Losing every native route disconnects and retires live state")
    aliceWorld.guild = true
    aliceEvent("PLAYER_GUILD_UPDATE", "player")
    assert(alice:IsDataConnected() and state.routes.GUILD and not state.routes.RAID
        and state.status.session ~= session and alice:GetGroupBurnedStatus().count == 1)
    local fresh = bobWorld.statusSends[firstRaid]
    aliceEvent("CHAT_MSG_ADDON", fresh.prefix, fresh.message, "GUILD", "Bob")
    assert(player(alice, "bob-testrealm").xp == 975 and alice:GetGroupBurnedStatus().count == 2,
        "Guild membership restores full native status reception")
    assert(#aliceWorld.notificationErrors == 0 and #bobWorld.notificationErrors == 0)
end

-- Position preferences never bypass login, native membership or newer-schema protection.
do
    local loading, _, _, loadingEvent, loadingWorld = loadAddon(settings(nil, false), false)
    loadingWorld.guild = true
    loadingEvent("ADDON_LOADED", "LockInTools")
    assert(loading:SetPositionSharing(true))
    loadingWorld:advance(30)
    assert(#loadingWorld.dataJoinCalls == 0 and #loadingWorld.dataSends == 0,
        "saving enabled sharing before login does not send network requests")
    loadingEvent("PLAYER_LOGIN")
    assert(#loadingWorld.dataJoinCalls == 0 and loading:IsDataConnected(),
        "login starts native sharing after preferences were saved during loading")
    local ungrouped, _, _, _, ungroupedWorld = loadAddon(settings("", false), false)
    ungroupedWorld:initialize()
    assert(ungrouped:SetPositionSharing(true))
    ungroupedWorld:advance(30)
    assert(#ungroupedWorld.dataJoinCalls == 0 and #ungroupedWorld.dataSends == 0,
        "saving enabled sharing without a group does not join or broadcast")
    local futureSettings = settings(nil, false)
    futureSettings.schemaVersion = 5
    futureSettings.position = { sharing = false, keepLastKnown = true, peers = {},
        showTrails = "future-trails", trailLength = "future-length" }
    local future, _, _, _, futureWorld = loadAddon(futureSettings, false)
    futureWorld:initialize()
    assert(not future:SetPositionSharing(true))
    assert(futureSettings.position.showTrails == "future-trails"
        and futureSettings.position.trailLength == "future-length",
        "Read-only startup preserves retired preferences in the original newer-schema data")
    futureWorld:advance(30)
    assert(not futureSettings.position.sharing and #futureWorld.dataJoinCalls == 0
        and #futureWorld.dataSends == 0, "read-only preferences cannot enable sharing or reconnect data")
end


-- Burned status is account-wide, editable without a connection, and protected
-- by the same newer-schema rules as the other saved preferences.
do
    local current, _, _, event, clock = loadAddon(settings("", false), false)
    assert(current:GetBurnedStatus() == 0 and not current:SetBurnedStatus(20))
    event("ADDON_LOADED", "LockInTools")
    local changes = 0
    current:RegisterNotification("BURNED_CHANGED", function() changes = changes + 1 end)
    assert(current:GetBurnedStatus() == 0 and current.db.burned.status == 0)
    assert(current:SetBurnedStatus(64.6) and current:GetBurnedStatus() == 65)
    assert(current:SetBurnedStatus(65) and changes == 1,
        "Rounding a drag to the saved integer must not cause duplicate updates")
    for _, invalid in ipairs({ -1, 101, 0 / 0, math.huge, "50", false, {} }) do
        assert(not current:SetBurnedStatus(invalid) and current:GetBurnedStatus() == 65)
    end
    clock:advance(300)
    assert(current:SetBurnedStatus(0))
    clock:advance(300)
    assert(current:SetBurnedStatus(100))
    event("PLAYER_LOGIN")
    clock:advance(30)
    assert(current.db.burned.status == 100 and #clock.dataJoinCalls == 0 and #clock.statusSends == 0
        and current:GetGroupBurnedStatus().count == 0,
        "A personal preference without a group must not initiate traffic or invent a group average")
    local reloaded, _, _, _, reloadClock = loadAddon(current.db, false)
    reloadClock:initialize()
    assert(reloaded:GetBurnedStatus() == 100, "The personal burned status survives account-wide reloads")
    local malformed = settings("", false)
    malformed.burned = { status = 150, future = "preserved" }
    local repaired, _, _, _, repairClock = loadAddon(malformed, false)
    repairClock:initialize()
    assert(repaired:GetBurnedStatus() == 0 and malformed.burned.status == 0
        and malformed.burned.future == "preserved")
    local newer = settings()
    newer.schemaVersion, newer.burned = 5,
        { status = 73, changeAvailableAt = 2000009000, future = "untouched" }
    local future, _, _, _, futureClock = loadAddon(newer, false)
    futureClock:initialize()
    assert(future:GetBurnedStatus() == 73 and not future:SetBurnedStatus(25)
        and newer.burned.status == 73 and newer.burned.changeAvailableAt == 2000009000
        and newer.burned.future == "untouched"
        and future:GetGroupBurnedStatus().average == nil and future:GetGroupBurnedStatus().count == 0)
    futureClock:advance(30)
    assert(#futureClock.statusSends == 0 and #futureClock.dataJoinCalls == 0,
        "Newer-schema status stays readable without modifying or transmitting the original preferences")
end

-- A successful personal edit starts one five-minute interval. Rejected edits,
-- including subsecond boundary attempts, cannot change its value or deadline.
do
    local current, _, _, _, clock = loadAddon(settings("", false), false)
    assert(current:GetBurnedStatusCooldown() == 0)
    clock:initialize()
    local changes, statusTicks = 0, 0
    current:RegisterNotification("BURNED_CHANGED", function() changes = changes + 1 end)
    current.DataStatusTick = function() statusTicks = statusTicks + 1 end
    assert(current:SetBurnedStatus(0) and current:GetBurnedStatusCooldown() == 0
        and current.db.burned.changeAvailableAt == nil and changes == 0 and statusTicks == 0,
        "A no-op before the first edit must not start a cooldown or emit status")
    for _, invalid in ipairs({ -1, 101, 0 / 0, math.huge, "50", false, {} }) do
        assert(not current:SetBurnedStatus(invalid) and current:GetBurnedStatusCooldown() == 0)
    end
    assert(current:SetBurnedStatus(40) and current:GetBurnedStatusCooldown() == 300
        and current.db.burned.changeAvailableAt == 2000000300 and changes == 1 and statusTicks == 1)
    local deadline = current.db.burned.changeAvailableAt
    clock:advance(60)
    assert(current:SetBurnedStatus(40.4) and current:GetBurnedStatusCooldown() == 240
        and current.db.burned.changeAvailableAt == deadline,
        "A rounded no-op during cooldown succeeds without extending the interval")
    clock:advance(239.9)
    local accepted, reason = current:SetBurnedStatus(80)
    assert(not accepted and reason:find("0:01", 1, true) and current:GetBurnedStatus() == 40
        and current:GetBurnedStatusCooldown() == 1 and current.db.burned.changeAvailableAt == deadline
        and changes == 1 and statusTicks == 1,
        "At 299.9 seconds a changed value is rejected without notifications or status sends")
    clock:advance(0.1)
    assert(current:GetBurnedStatusCooldown() == 0 and current:SetBurnedStatus(80)
        and current:GetBurnedStatusCooldown() == 300 and changes == 2 and statusTicks == 2,
        "At exactly 300 seconds the next changed value is accepted and starts a fresh interval")
end

-- The saved account-wide deadline follows reloads, characters and native membership changes.
do
    local profile = settings("", false)
    profile.burned = { status = 20, future = "preserved" }
    local current, _, _, _, clock = loadAddon(profile, false)
    clock:initialize()
    assert(current:GetBurnedStatusCooldown() == 0 and current:SetBurnedStatus(70),
        "A legacy saved status without a deadline permits its first changed value")
    clock:advance(120)
    local deadline = profile.burned.changeAvailableAt
    clock.guild = true
    clock.fire("PLAYER_GUILD_UPDATE")
    clock.guild = false
    clock.fire("PLAYER_GUILD_UPDATE")
    assert(current:GetBurnedStatus() == 70 and current:GetBurnedStatusCooldown() == 180
        and profile.burned.changeAvailableAt == deadline and not current:SetBurnedStatus(10))
    local restored, environment, _, _, reloadClock = loadAddon(profile, false)
    environment.GetServerTime = function() return 2000000120 + math.floor(reloadClock.now) end
    environment.UnitFullName = function() return "AnotherCharacter", "Test Realm" end
    reloadClock:initialize()
    assert(restored:GetBurnedStatus() == 70 and restored:GetBurnedStatusCooldown() == 180
        and profile.burned.future == "preserved" and not restored:SetBurnedStatus(10),
        "Reloading on another character retains the remaining account-wide interval")
    reloadClock:advance(180)
    assert(restored:GetBurnedStatusCooldown() == 0 and restored:SetBurnedStatus(10))
end

-- Restore only bounded, finite deadlines. Unknown fields and newer schemas
-- remain intact; server-clock corrections cannot shorten an active interval.
do
    for _, invalid in ipairs({ -1, 0 / 0, math.huge, "2000000300", false, {}, 2000000200.5 }) do
        local profile = settings("", false)
        profile.burned = { status = 50, changeAvailableAt = invalid, future = "preserved" }
        local current, _, _, _, clock = loadAddon(profile, false)
        clock:initialize()
        assert(current:GetBurnedStatusCooldown() == 0 and profile.burned.changeAvailableAt == nil
            and profile.burned.future == "preserved" and current:SetBurnedStatus(60),
            "Malformed saved deadlines cannot lock the control or damage unrelated preferences")
    end
    for _, deadline in ipairs({ 0, 1999999999, 2000000000 }) do
        local profile = settings("", false)
        profile.burned = { status = 50, changeAvailableAt = deadline }
        local current, _, _, _, clock = loadAddon(profile, false)
        clock:initialize()
        assert(current:GetBurnedStatusCooldown() == 0 and profile.burned.changeAvailableAt == nil
            and current:SetBurnedStatus(60), "Expired deadlines permit an immediate changed value")
    end
    local profile = settings("", false)
    profile.burned = { status = 50, changeAvailableAt = 2000010000, future = "preserved" }
    local current, environment, _, _, clock = loadAddon(profile, false)
    clock:initialize()
    assert(current:GetBurnedStatusCooldown() == 300 and profile.burned.changeAvailableAt == 2000000300
        and profile.burned.future == "preserved", "An excessive deadline is clamped to five minutes")
    clock:advance(100)
    environment.GetServerTime = function() return 1000000000 end
    assert(current:GetBurnedStatusCooldown() == 200 and not current:SetBurnedStatus(60))
    environment.GetServerTime = function() return 3000000000 end
    assert(current:GetBurnedStatusCooldown() == 200 and not current:SetBurnedStatus(60),
        "Server clock corrections cannot shorten or extend a live monotonic interval")
    clock:advance(200)
    assert(current:GetBurnedStatusCooldown() == 0 and current:SetBurnedStatus(60))
end

-- Player-history cleanup defaults on for existing profiles, while explicit
-- opt-outs and unrelated data settings survive normalization and reloads.
for _, saved in ipairs({ {}, { cleanupOldPlayers = false }, { cleanupOldPlayers = "false" } }) do
    local profile = settings("", false)
    profile.data = { cleanupOldPlayers = saved.cleanupOldPlayers, future = "preserved",
        channels = { party = false, guild = false, global = false } }
    local current, _, _, event = loadAddon(profile, false)
    local accepted, problem = current:SetPlayerDataCleanupEnabled(false)
    assert(not accepted and type(problem) == "string")
    assert(not current:ClearPlayerData(), "History cannot be cleared before saved data is loaded")
    event("ADDON_LOADED", "LockInTools")
    local expected = saved.cleanupOldPlayers ~= false
    assert(current:GetPlayerDataCleanupEnabled() == expected
        and profile.data.cleanupOldPlayers == expected and profile.data.future == "preserved")
    assert(not current:SetPlayerDataCleanupEnabled("true")
        and current:GetPlayerDataCleanupEnabled() == expected)
    assert(current:SetPlayerDataCleanupEnabled(false))
    local restored, _, _, restoredEvent = loadAddon(profile, false)
    restoredEvent("ADDON_LOADED", "LockInTools")
    assert(not restored:GetPlayerDataCleanupEnabled() and profile.data.future == "preserved",
        "The account-wide opt-out must remain off after a reload")
end

-- Cleanup removes an identity from every history cache only after its newest
-- roster or position activity reaches ten days, including the exact boundary.
do
    local fingerprint, cutoff = "legacy-group", 2000000000 - 10 * 86400
    local profile = settings(nil, false)
    profile.data = { channels = { party = false, guild = false, global = false } }
    profile.roster = { groupFingerprint = fingerprint, peers = {} }
    profile.position = { sharing = false, keepLastKnown = true, groupFingerprint = fingerprint, peers = {} }
    local function roster(name, stamp)
        profile.roster.peers[name:lower() .. "-testrealm"] = {
            name = name, level = 20, seenAt = stamp, xp = 50, xpMax = 100,
            xpState = "known", xpUpdatedAt = stamp,
        }
    end
    local function position(name, stamp, seenAt)
        profile.position.peers[name:lower() .. "-testrealm"] = {
            name = name, stamp = stamp, seenAt = seenAt, positionStamp = stamp - 5,
            map = 37, x = 0.2, y = 0.3, class = "MAGE",
        }
    end
    roster("Boundary", cutoff); position("Boundary", cutoff)
    roster("Older", cutoff - 1)
    position("PositionOnly", cutoff - 1)
    roster("NewPosition", cutoff - 10); position("NewPosition", cutoff + 1)
    roster("NewRoster", cutoff + 1); position("NewRoster", cutoff - 10)
    position("LocalReceipt", cutoff - 20, cutoff + 1)
    roster("Future", 2000000001)
    local current, _, _, event, clock = loadAddon(profile, false)
    event("ADDON_LOADED", "LockInTools")
    for _, id in ipairs({ "boundary-testrealm", "older-testrealm", "positiononly-testrealm" }) do
        assert(not profile.roster.peers[id] and not profile.position.peers[id]
            and not current.rosterState.peers[id] and not current.rosterState.progress[id]
            and not current.positionState.peers[id] and not current.positionState.latest[id]
            and not current.positionState.classes[id], "Expired identities must leave every restored cache")
    end
    for _, id in ipairs({ "newposition-testrealm", "newroster-testrealm" }) do
        assert(profile.roster.peers[id] and profile.position.peers[id]
            and current.rosterState.progress[id] and current.positionState.classes[id],
            "Activity from either source keeps that player's saved history")
    end
    assert(profile.roster.peers["future-testrealm"], "Clock rollback must not expire future activity")
    assert(profile.position.peers["localreceipt-testrealm"]
        and current.positionState.peers["localreceipt-testrealm"].seenAt == cutoff + 1,
        "A saved local receipt time takes precedence over the sender's older position clock")
    assert(current:SetPlayerDataCleanupEnabled(false))
    event("PLAYER_LOGIN")
    clock:advance(3600)
    assert(profile.roster.peers["newroster-testrealm"] and profile.position.peers["newposition-testrealm"],
        "Disabled cleanup must leave newly expired records in place")
    assert(current:SetPlayerDataCleanupEnabled(true))
    assert(not profile.roster.peers["newroster-testrealm"] and not profile.position.peers["newposition-testrealm"],
        "Enabling cleanup immediately removes records that expired while it was off")
    profile.roster.peers["hourly-testrealm"] = { name = "Hourly-TestRealm", level = 20,
        seenAt = 2000003600 - 10 * 86400 + 1 }
    current.rosterState.peers["hourly-testrealm"] = profile.roster.peers["hourly-testrealm"]
    clock:advance(3599)
    assert(profile.roster.peers["hourly-testrealm"], "Scheduled cleanup waits for its hourly interval")
    clock:advance(1)
    assert(not profile.roster.peers["hourly-testrealm"] and not current.rosterState.peers["hourly-testrealm"],
        "Hourly cleanup removes expired history even with all data routes and positions disabled")
    assert(current:SetPlayerDataCleanupEnabled(false))
    profile.roster.peers["disabled-testrealm"] = { name = "Disabled-TestRealm", seenAt = cutoff }
    current.rosterState.peers["disabled-testrealm"] = profile.roster.peers["disabled-testrealm"]
    clock:advance(3600)
    assert(profile.roster.peers["disabled-testrealm"], "Disabling cleanup cancels the active hourly job")
end

-- Clearing player data removes persisted and live peer reports without changing
-- group membership, account preferences or the personal burned cooldown.
do
    local profile = settings(nil, false)
    profile.data = { cleanupOldPlayers = false, channels = { party = false, guild = true, global = false } }
    profile.burned = { status = 40, changeAvailableAt = 2000000300, future = "preserved" }
    local current, environment, _, event, clock = loadAddon(profile, false)
    clock.guild = true
    clock:initialize()
    assert(current:ReceivePlayerStatus("Friend-TestRealm", { level = "24", xp = "25", xpMax = "100",
        xpState = "known", sharing = true }, 2000000000, 1))
    assert(current:ReceivePosition("Friend-TestRealm", "2|P|2000000000|37|20000|30000"))
    assert(current:ReceivePosition("OldClock-TestRealm", "2|P|1900000000|37|20000|30000"))
    assert(current.positionState.peers["oldclock-testrealm"].seenAt == 2000000000
        and profile.position.peers["oldclock-testrealm"].seenAt == 2000000000,
        "A live position records local activity independently of a peer's older clock")
    assert(current:SetPlayerDataCleanupEnabled(true))
    current:PrunePlayerData()
    assert(profile.position.peers["oldclock-testrealm"], "Fresh local contact must not be pruned for an old wire stamp")
    assert(current:SetPlayerDataCleanupEnabled(false))
    assert(current:ReceiveBurnedStatus("Friend-TestRealm", { burned = "80" }, 2000000000, 1))
    current.positionState.classes["friend-testrealm"] = "MAGE"
    current.dataState.status.received["friend-testrealm"] = { stamp = 2000000000 }
    local accepted, requestID = current:RequestData("status", "pending")
    assert(accepted and current.dataState.pendingRequests[requestID])
    current.dataState.repliedRequests["friend-testrealm|status|old-request"] = 10
    local expiry, cooldown = current.burnedState.timer, current:GetBurnedStatusCooldown()
    local notices = { roster = 0, position = 0, burned = 0 }
    current:RegisterNotification("ROSTER_CHANGED", function() notices.roster = notices.roster + 1 end)
    current:RegisterNotification("POSITIONS_CHANGED", function() notices.position = notices.position + 1 end)
    current:RegisterNotification("BURNED_CHANGED", function() notices.burned = notices.burned + 1 end)
    assert(current:ClearPlayerData())
    assert(next(profile.roster.peers) == nil and next(profile.position.peers) == nil
        and next(current.rosterState.peers) == nil and next(current.rosterState.progress) == nil
        and next(current.positionState.peers) == nil and next(current.positionState.latest) == nil
        and next(current.positionState.classes) == nil and next(current.burnedState.peers) == nil
        and next(current.dataState.status.received) == nil
        and next(current.dataState.pendingRequests) == nil and next(current.dataState.repliedRequests) == nil,
        "Clearing history must remove saved records, visible peers and protocol caches together")
    assert(expiry.cancelled and not current.burnedState.timer
        and notices.roster > 0 and notices.position > 0 and notices.burned > 0)
    assert(environment.LockInToolsDB == profile and profile.group == nil and profile.chat == nil and not current:GetPlayerDataCleanupEnabled()
        and profile.position.sharing and profile.position.keepLastKnown
        and profile.data.channels.guild and not profile.data.channels.global
        and current:IsDataConnected() and current:GetBurnedStatus() == 40
        and current:GetBurnedStatusCooldown() == cooldown and profile.burned.changeAvailableAt == 2000000300
        and profile.burned.future == "preserved", "Clearing peer data preserves settings and personal status")
    -- A fresh peer's normal startup request must be accepted after clearing.
    local other, otherEnvironment, _, _, otherClock = loadAddon(settings(nil, false), false)
    otherEnvironment.UnitFullName = function() return "Friend", "Test Realm" end
    otherClock.guild = true
    otherClock:initialize()
    local packet = assert(otherClock.statusSends[1])
    event("CHAT_MSG_ADDON", packet.prefix, packet.message, "GUILD", "Friend-TestRealm")
    assert(profile.roster.peers["friend-testrealm"] and profile.position.peers["friend-testrealm"]
        and current.dataState.status.received["friend-testrealm"],
        "Fresh shared status repopulates history after an explicit clear")
end

-- Newer saved schemas are preserved in full even when cleanup would otherwise
-- remove old player records or the user explicitly requests a clear.
do
    local helpers = dofile("tests/support/helpers.lua")
    local profile = settings(nil, false)
    profile.schemaVersion = 5
    profile.data = { cleanupOldPlayers = true, future = "preserved" }
    profile.roster = { groupFingerprint = "future-group", peers = {
        ["old-testrealm"] = { name = "Old-TestRealm", seenAt = 1 },
    } }
    profile.position = { peers = { ["old-testrealm"] = { name = "Old-TestRealm", stamp = 1 } } }
    local original = helpers.copy(profile)
    local current, _, _, _, clock = loadAddon(profile, false)
    clock:initialize()
    assert(not current:SetPlayerDataCleanupEnabled(false) and not current:ClearPlayerData())
    current:PrunePlayerData()
    clock:advance(3600)
    assert(helpers.equal(profile, original), "Cleanup and explicit clearing cannot modify a newer schema")
end

assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep test environments isolated")
print("PASS: production data startup, preferences, routing and recovery")
