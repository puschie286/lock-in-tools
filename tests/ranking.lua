-- Ranking checks use current and saved Overview reports without a native UI or transport.
local loadNotifications = dofile("tests/support/notifications.lua")
local helpers = dofile("tests/support/helpers.lua")
local loadModule, copy, equal = helpers.loadModule, helpers.copy, helpers.equal

local function newAddon(saved, readOnly, skipInitialization)
    local world = { players = {}, guild = true, connected = true, reads = 0 }
    local addon = {
        db = saved or { schemaVersion = 4 }, initialized = true, ready = true,
        savedDataReadOnly = readOnly == true,
    }
    function addon:HasDataGroup() return world.guild end
    function addon:IsDataConnected() return world.connected end
    function addon:GetOverviewPlayers()
        world.reads = world.reads + 1
        return world.players
    end
    local environment = setmetatable({}, { __index = _G })
    environment._G = environment
    world.environment = environment
    world.errors = loadNotifications(addon, environment)
    loadModule("Ranking.lua", addon, environment)
    if not skipInitialization then addon:InitializeRanking() end
    return addon, world
end

local function player(id, level, xp, maximum, own)
    return {
        id = id, name = id, level = level, xp = xp, xpMax = maximum,
        xpState = "known", online = true, xpStale = false,
        statusSynchronized = true, isSelf = own == true,
    }
end

local function ids(players)
    local result = {}
    for _, row in ipairs(players) do result[#result + 1] = row.id end
    return table.concat(result, ",")
end

local function newRosterAddon(saved)
    local addon, world = newAddon(saved)
    local environment = world.environment
    world.now, world.connected = 0, false
    environment.GetTime = function() return world.now end
    environment.GetServerTime = function() return 2000000000 + math.floor(world.now) end
    environment.GetNormalizedRealmName = function() return "TestRealm" end
    environment.UnitFullName = function() return "Self", "TestRealm" end
    environment.UnitLevel = function() return 29 end
    environment.UnitXP = function() return 25 end
    environment.UnitXPMax = function() return 100 end
    environment.GetMaxPlayerLevel = function() return 60 end
    function addon:IsDataSelf(name) return name:lower() == "self-testrealm" end
    function addon:RegisterDataStatusProvider(name, collect, receive, connected)
        assert(name == "player")
        world.statusConnected = connected
    end
    loadModule("Roster.lua", addon, environment)
    addon:InitializeRoster()
    addon:OnRosterLogin()
    return addon, world
end

-- Levels take precedence over every XP value, and the model retains the full standings.
do
    local addon, world = newAddon()
    world.players = {
        player("lower-full", 24, 1000, 1000), player("higher-zero", 25, 0, 2000),
        player("third", 23, 900, 1000), player("fourth", 22, 900, 1000),
        player("fifth", 21, 900, 1000), player("sixth", 20, 900, 1000),
        player("self", 19, 1, 1000, true),
    }
    local ranking = addon:GetPlayerRanking()
    assert(ranking.connected and ranking.grouped)
    assert(ids(ranking.players) == "higher-zero,lower-full,third,fourth,fifth,sixth,self",
        "A higher level always outranks a lower level, including 0% against 100%")
    assert(#ranking.players == 7 and ranking.own.id == "self" and ranking.own.rank == 7,
        "The overlay must be able to show your actual rank beyond the top five")
end

-- Compare exact fractions; rounded display percentages cannot decide ordering or ties.
do
    local addon, world = newAddon()
    world.players = {
        player("a-lower", 30, 5001, 10000), player("z-higher", 30, 5002, 10000),
        player("z-third", 30, 1, 3), player("a-third", 30, 3, 9),
        player("last", 30, 0, 1000),
    }
    world.players[3].xpStale, world.players[4].online = true, false
    local ranking = addon:GetPlayerRanking()
    assert(ids(ranking.players) == "z-higher,a-lower,a-third,z-third,last",
        "Exact XP fractions sort independently of rounded display percentages and input order")
    local expected = { 1, 2, 3, 3, 5 }
    for index, row in ipairs(ranking.players) do
        assert(row.rank == expected[index], "Equal progress must use shared competition ranks")
        assert(row.stale == (index == 3 or index == 4) and row.xpStale == row.stale,
            "Saved and current reports use the same exact ordering and shared ranks")
    end
end

-- Protocol-sized integers can produce equal floating ratios and rounded cross-products.
do
    local addon, world = newAddon()
    world.players = {
        player("a-smaller", 30, 701408733, 1134903170),
        player("z-larger", 30, 1134903170, 1836311903),
    }
    local ranking = addon:GetPlayerRanking()
    assert(ids(ranking.players) == "z-larger,a-smaller"
        and ranking.players[1].rank == 1 and ranking.players[2].rank == 2,
        "Distinct rational progress must remain distinct near the ten-digit protocol limits")
end

-- Confirmed maximum-level characters tie even though no XP denominator is reported.
do
    local addon, world = newAddon()
    local first, second = player("z-max", 60), player("a-max", 60)
    first.xpState, second.xpState = "max", "max"
    world.players = { first, player("nearly-max", 59, 999, 1000), second }
    local ranking = addon:GetPlayerRanking()
    assert(ids(ranking.players) == "a-max,z-max,nearly-max")
    assert(ranking.players[1].rank == 1 and ranking.players[2].rank == 1
        and ranking.players[3].rank == 3, "Maximum-level ties must consume the shared ranks")
end

-- Saved complete progress remains ranked; discovery without XP cannot invent progress.
do
    local addon, world = newAddon()
    local missing = player("missing", 30)
    missing.xpState, missing.online, missing.xpStale = "unavailable", false, true
    local stale = player("stale", 30, 900, 1000)
    stale.xpStale = true
    local unsynchronized = player("contact-only", 30, 950, 1000)
    unsynchronized.statusSynchronized = false
    local inactive = player("inactive", 60)
    inactive.xpState, inactive.online, inactive.xpStale = "max", false, true
    local own = player("self", 29)
    own.isSelf, own.xpState = true, "unavailable"
    world.players = { missing, stale, unsynchronized, inactive, own, player("current", 28, 50, 100) }
    local before = copy(world.players)
    local ranking = addon:GetPlayerRanking()
    assert(ids(ranking.players) == "inactive,contact-only,stale,current",
        "Offline and unsynchronized players retain ranks from their last complete progress")
    for index, row in ipairs(ranking.players) do
        assert(row.stale == (index ~= 4) and row.xpStale == row.stale,
            "Each saved ranking row must explicitly identify its stale progress")
    end
    assert(ranking.own and ranking.own.id == "self" and ranking.own.rank == nil,
        "Your missing XP remains available for the Waiting for XP row without an invented rank")
    assert(equal(world.players, before), "Ranking must never annotate or reorder Overview's cached reports")
    ranking.players[1].rank, ranking.players[1].stale = 99, false
    assert(world.players[4].rank == nil and world.players[4].stale == nil,
        "Rank and stale annotations must belong to detached rows")
end

-- An apparently known report is incomplete unless level and XP form a valid complete value.
do
    local addon, world = newAddon()
    world.players = { player("no-level", nil, 10, 100), player("zero-maximum", 30, 0, 0),
        player("excess", 30, 101, 100), player("negative", 30, -1, 100) }
    local ranking = addon:GetPlayerRanking()
    assert(#ranking.players == 0,
        "Malformed or incomplete progress must remain unranked rather than looking like zero XP")
end

-- Disconnecting retains saved standings while marking every peer snapshot stale.
do
    local addon, world = newAddon()
    world.players = { player("friend", 30, 50, 100), player("self", 29, 25, 100, true) }
    assert(addon:GetPlayerRanking().own.rank == 2)
    world.connected = false
    local ranking = addon:GetPlayerRanking()
    assert(not ranking.connected and ranking.grouped and #ranking.players == 2,
        "Connection loss retains standings using the peers' last saved progress")
    assert(ranking.players[1].stale and ranking.players[1].xpStale)
    assert(ranking.own and ranking.own.id == "self" and ranking.own.xp == 25 and ranking.own.rank == 2
        and ranking.own.stale == false and ranking.own.xpStale == false,
        "Live local progress remains current and comparable against the last peer reports")
    world.connected = true
    local recovered = addon:GetPlayerRanking()
    assert(#recovered.players == 2 and recovered.own.rank == 2
        and recovered.players[1].stale == false and recovered.own.stale == false)
    world.guild = false
    ranking = addon:GetPlayerRanking()
    assert(not ranking.grouped and #ranking.players == 0 and ranking.own == nil,
        "Without native guild or group membership, ranking rows are hidden")
    world.guild = true
    ranking = addon:GetPlayerRanking()
    assert(#ranking.players == 2 and ranking.own.id == "self",
        "Native membership changes preserve retained standings")
end

-- Contact changes keep the exact progress order; returned rows stay
-- detached and fresh even when the input order or unranked discovery changes.
do
    local addon, world = newAddon()
    local sorts = 0
    world.environment.table = setmetatable({ sort = function(...)
        sorts = sorts + 1
        return table.sort(...)
    end }, { __index = table })
    local first, own = player("friend", 30, 50, 100), player("self", 29, 25, 100, true)
    world.players = { first, own }
    local initial = addon:GetPlayerRanking()
    assert(world.reads == 1 and sorts == 1, "The first ranking reads the Overview once and sorts progress")
    initial.players[1].rank, initial.players[1].level = 99, 1
    first.online, first.xpStale, first.seenAt = false, true, 2000000010
    local discovery = { id = "new-peer", name = "NewPeer", online = true }
    world.players = { own, discovery, first }
    local refreshed = addon:GetPlayerRanking()
    assert(world.reads == 2 and sorts == 1 and ids(refreshed.players) == "friend,self" and refreshed.players[1].rank == 1
        and refreshed.players[1].level == 30
        and refreshed.players[1].seenAt == 2000000010 and refreshed.players[1].stale
        and not refreshed.players[1].online,
        "Contact and unranked discovery refresh metadata without sorting progress again")
    first.xp = 75
    addon:GetPlayerRanking()
    assert(sorts == 2, "An XP change must recompute exact progress ordering")
    first.xpState = "unavailable"
    assert(#addon:GetPlayerRanking().players == 1 and sorts == 3,
        "Losing usable XP removes a ranked player immediately")
    world.players = { player("replacement", 29, 25, 100) }
    assert(addon:GetPlayerRanking().players[1].id == "replacement" and sorts == 4,
        "Replacing a ranked identity must invalidate ordering even when its progress and count match")
end

-- Real Roster reports survive a SavedVariables reload and rank before peers reconnect.
do
    local saved = { schemaVersion = 4 }
    local addon, world = newRosterAddon(saved)
    world.connected = true
    world.statusConnected(true)
    assert(addon:ReceivePlayerStatus("Friend-TestRealm", {
        level = 31, xp = 700, xpMax = 1000, xpState = "known",
    }, 1, 1))
    assert(addon:ReceivePlayerStatus("Maximum-TestRealm", { level = 60, xpState = "max" }, 1, 1))
    assert(saved.roster.peers["friend-testrealm"].xp == 700
        and saved.roster.peers["self-testrealm"].xp == 25,
        "Current local and peer progress must be saved by the real Roster implementation")
    saved.roster.peers["legacy-testrealm"] = { name = "Legacy-TestRealm", level = 32, seenAt = 1999999990 }
    local reloaded, restored = newRosterAddon(copy(saved))
    local ranking = reloaded:GetPlayerRanking()
    assert(not ranking.connected and ids(ranking.players) == "maximum-testrealm,friend-testrealm,self-testrealm"
        and ranking.own.rank == 3, "Saved XP and maximum-level records remain ranked before reconnection")
    assert(ranking.players[1].xpState == "max" and ranking.players[1].stale
        and ranking.players[2].xp == 700 and ranking.players[2].xpMax == 1000 and ranking.players[2].stale)
    restored.connected = true
    restored.statusConnected(true)
    ranking = reloaded:GetPlayerRanking()
    assert(ranking.players[1].stale and ranking.players[2].stale,
        "Reconnecting alone cannot make saved reports current")
    assert(reloaded:ReceivePlayerStatus("Friend-TestRealm", {
        level = 31, xp = 750, xpMax = 1000, xpState = "known",
    }, 2, 1))
    ranking = reloaded:GetPlayerRanking()
    assert(ranking.players[1].stale and ranking.players[2].xp == 750 and not ranking.players[2].stale,
        "A fresh status replaces saved XP and clears only that player's stale marker")
    restored.now = 91
    ranking = reloaded:GetPlayerRanking()
    assert(ranking.players[1].stale and ranking.players[2].stale and ranking.players[2].xp == 750,
        "Expired contact keeps the last valid XP ranked and marks it stale again")
end

-- Login guards prevent restored progress from claiming standings before native data is ready.
do
    local addon, world = newAddon()
    world.players = { player("friend", 30, 50, 100), player("self", 29, 25, 100, true) }
    addon.ready = false
    local ranking = addon:GetPlayerRanking()
    assert(#ranking.players == 0 and ranking.own == nil)
    addon.ready, addon.initialized = true, false
    ranking = addon:GetPlayerRanking()
    assert(#ranking.players == 0 and ranking.own == nil)
end

-- Native friends add level-only standings without altering a shared XP report for the same character.
do
    local addon, world = newAddon()
    world.environment.GetTime = function() return 0 end
    local discovered = { id = "alex wren-testrealm", name = "Alex Wren", online = false }
    local reporter = player("reporter-testrealm", 30, 80, 100)
    reporter.seenAt = 2000000000
    world.players = { player("self", 29, 25, 100, true), reporter, discovered }
    local friends = {
        { id = "alex-wren", aliasID = discovered.id, name = "Alex-Wren", displayName = "Alex Wren",
            level = 30, online = true, zone = "Elwynn Forest" },
        { id = "bea-ivy", name = "Bea-Ivy", level = 30, online = false },
        { id = "reporter-surname", aliasID = "reporter-testrealm", name = "Reporter-Surname",
            displayName = "Reporter Surname", level = 31, online = true, seenAt = 2000000010 },
        { id = "self-testrealm", aliasID = "self", name = "Self-TestRealm", level = 29, online = true },
        { id = "unavailable", name = "Unavailable", online = true },
    }
    local reads = 0
    function addon:GetFriendsPlayers()
        reads = reads + 1
        return friends
    end
    function addon:GetPlayerDisplayName(name) return name:match("^[^-]+") end
    assert(ids(addon:GetPlayerRanking().players) == "reporter-testrealm,self" and reads == 0,
        "Friend inclusion defaults off without reading native friend data")
    assert(addon:SetRankingPlayerShown(friends[1].id, true))
    assert(ids(addon:GetPlayerRanking().players) == "reporter-testrealm,alex-wren,self"
        and not addon:IsRankingPlayerShown(friends[2].id), "Selecting one friend does not add another")
    for index = 2, #friends do assert(addon:SetRankingPlayerShown(friends[index].id, true)) end
    local ranking = addon:GetPlayerRanking()
    assert(ranking.hasFriends and ids(ranking.players) == "reporter-testrealm,alex-wren,bea-ivy,self"
        and ranking.players[1].xp == 80 and ranking.players[1].level == 30 and not ranking.players[1].friendOnly
        and ranking.players[1].displayName == "Reporter Surname",
        "Native name aliases must not duplicate a shared progress report or add the local character twice")
    local alex, bea = ranking.players[2], ranking.players[3]
    assert(alex.friendOnly and alex.rank == 2 and bea.rank == 2 and ranking.own.rank == 4
        and alex.xpState == "unavailable" and alex.xp == nil and alex.xpMax == nil
        and alex.stale == false and bea.stale == true and not friends[1].rank,
        "Native friends at the same level share a rank after known XP without gaining fabricated XP")
    local lines = addon:GetCompactPlayerTooltipLines(alex)
    assert(lines[1] == "#2 - Alex Wren" and lines[2] == "Lv 30 - XP unavailable" and lines[3] == "Elwynn Forest")
    reporter.online = false
    local nativeLevel = addon:GetPlayerRanking().players[1]
    assert(nativeLevel.id == "reporter-surname" and nativeLevel.level == 31 and nativeLevel.friendOnly
        and nativeLevel.xpState == "unavailable" and nativeLevel.xp == nil and reporter.level == 30,
        "A newer online friend level supersedes stale XP from an earlier level")
    friends[3].seenAt = reporter.seenAt
    assert(addon:GetPlayerRanking().players[1].id == reporter.id,
        "An equally old native observation does not supersede the shared level")
    friends[3].level, friends[3].seenAt = 29, reporter.seenAt + 10
    assert(addon:GetPlayerRanking().players[1].id == reporter.id,
        "A lower level in the native cache does not downgrade an existing shared level")
    friends[3].level, friends[3].online = 31, false
    assert(addon:GetPlayerRanking().players[1].id == reporter.id,
        "An offline native friend does not supersede the shared level")
    friends[3].online, reporter.online = true, true
    assert(addon:SetRankingPlayerShown(friends[1].id, false))
    assert(ids(addon:GetPlayerRanking().players) == "reporter-testrealm,bea-ivy,self"
        and addon:IsRankingPlayerShown(friends[2].id), "Removing one friend leaves the other selected")
    assert(addon:SetRankingPlayerShown(friends[2].id, false)
        and addon:SetRankingPlayerShown(friends[3].id, false))
    assert(ids(addon:GetPlayerRanking().players) == "self",
        "A hidden friend cannot reappear through an aliased shared report")
end

-- A saved Shown choice applies to both sources and leaves discovery intact.
do
    local addon, world = newAddon()
    local friend = { id = "alex-wren", aliasID = "alex wren-testrealm", name = "Alex-Wren", level = 30, online = true }
    local own = player("self", 29, 25, 100, true)
    local shared = player("alex wren-otherrealm", 30, 50, 100)
    world.players = { own, shared }
    function addon:GetFriendsPlayers() return { friend } end
    function addon:GetRankingPlayerKey(id) return id:match("^alex wren%-") and friend.id or id end
    assert(addon:IsRankingPlayerShown(shared.id, true) and not addon:IsRankingPlayerShown(friend.id))
    assert(ids(addon:GetPlayerRanking().players) == shared.id .. ",self")

    assert(addon:SetRankingPlayerShown(friend.id, true))
    assert(addon:SetRankingPlayerShown(shared.id, false) and not addon:IsRankingPlayerShown(friend.id))
    assert(ids(addon:GetPlayerRanking().players) == "self" and #world.players == 2,
        "Hiding a shared row suppresses its native fallback and keeps the discovered row available")
    assert(addon:SetRankingPlayerShown(shared.id, true) and addon:IsRankingPlayerShown(friend.id))
    assert(ids(addon:GetPlayerRanking().players) == shared.id .. ",self")
    world.players = { own }
    assert(ids(addon:GetPlayerRanking().players) == "alex-wren,self",
        "The same explicit selection applies after the character appears only through Friends")
    assert(addon:SetRankingPlayerShown(own.id, false))
    local ranking = addon:GetPlayerRanking()
    assert(ids(ranking.players) == "alex-wren" and ranking.own == nil,
        "Hiding your character also removes the separate own row")
end

-- Solo standings reuse the current character without opening the scope of the shared Overview.
do
    local addon, world = newRosterAddon()
    world.guild = false
    local friends = { { id = "alex-wren", name = "Alex-Wren", level = 30, online = true } }
    function addon:GetFriendsPlayers() return friends end
    assert(addon:SetRankingPlayerShown(friends[1].id, true))
    local ranking = addon:GetPlayerRanking()
    assert(not ranking.grouped and not ranking.connected and ranking.hasFriends
        and ids(ranking.players) == "alex-wren,self-testrealm"
        and ranking.own.xp == 25 and ranking.own.rank == 2 and #addon:GetOverviewPlayers() == 0)
    friends[1].level = 28
    assert(addon:GetPlayerRanking().own.rank == 1, "A friend level change updates solo standings")
    friends[1].level = nil
    ranking = addon:GetPlayerRanking()
    assert(not ranking.hasFriends and not ranking.own and #ranking.players == 0,
        "Enabling the preference alone does not start solo standings without a usable friend level")
end

-- Visibility defaults off and the burning effect on; preferences persist account-wide.
do
    local saved = { schemaVersion = 4, otherSettings = { preserved = true }, futureField = "keep",
        ranking = { futureField = { preserved = true }, includeFriends = true,
            includedFriends = { ["legacy-wren"] = true, ["bea-ivy"] = true, ["ignored-friend"] = false },
            shownPlayers = { ["bea-ivy"] = false, ["invalid-value"] = "true" } } }
    local addon = newAddon(saved)
    local settings = addon:GetRankingSettings()
    assert(settings.enabled == false and settings.includedFriends == nil and settings.includeFriends == nil and settings.position == nil
        and settings.burningEffect == true and settings.backgroundTransparency == 0)
    assert(equal(settings.shownPlayers, { ["legacy-wren"] = true, ["bea-ivy"] = false }),
        "Previous friend opt-ins migrate without overriding explicit visibility choices or accepting damaged values")
    assert(addon:SetRankingEnabled(true) and addon:SetRankingPlayerShown("alex-wren", true) and addon:SetRankingBurningEffect(false))
    assert(addon:SetRankingBackgroundTransparency(50))
    local position = { point = "TOPRIGHT", relativePoint = "TOPRIGHT", x = -80, y = -160 }
    assert(addon:SetRankingPosition(position))
    assert(saved.ranking.enabled == true and saved.ranking.shownPlayers["alex-wren"] == true and saved.ranking.burningEffect == false
        and saved.ranking.backgroundTransparency == 50 and equal(saved.ranking.position, position))
    assert(saved.otherSettings.preserved == true and saved.futureField == "keep" and saved.ranking.futureField.preserved)
    assert(not addon:SetRankingEnabled("true") and not addon:SetRankingPlayerShown("alex-wren", "true")
        and not addon:SetRankingBurningEffect("true"),
        "Saved overlay preferences accept booleans only")
    for _, invalid in ipairs({ false, "", "bad\nname", "bad|name", string.rep("a", 129), {} }) do
        assert(not addon:SetRankingPlayerShown(invalid, true) and not addon:IsRankingPlayerShown(invalid))
    end
    assert(not addon:SetRankingPlayerShown(nil, true))
    assert(not addon:SetRankingEnabled(nil) and not addon:SetRankingBurningEffect(nil))
    for _, invalid in ipairs({ 0, 1, {}, function() end }) do
        assert(not addon:SetRankingBurningEffect(invalid) and saved.ranking.burningEffect == false,
            "Invalid effect values must leave the last preference intact")
    end
    for _, invalid in ipairs({
        {},
        { point = "INVALID", relativePoint = "CENTER", x = 0, y = 0 },
        { point = "CENTER", relativePoint = "INVALID", x = 0, y = 0 },
        { point = "CENTER", relativePoint = "CENTER", x = "10", y = 0 },
        { point = "CENTER", relativePoint = "CENTER", x = 0 / 0, y = 0 },
        { point = "CENTER", relativePoint = "CENTER", x = 0, y = math.huge },
    }) do
        assert(not addon:SetRankingPosition(invalid), "Invalid placement must leave the last saved placement intact")
        assert(equal(addon:GetRankingSettings().position, position))
    end
    local reloaded = newAddon(saved)
    settings = reloaded:GetRankingSettings()
    assert(settings.enabled and reloaded:IsRankingPlayerShown("alex-wren")
        and reloaded:IsRankingPlayerShown("legacy-wren") and not reloaded:IsRankingPlayerShown("bea-ivy", true)
        and not settings.burningEffect
        and settings.backgroundTransparency == 50 and equal(settings.position, position),
        "Visibility, selected friends, burning effect, transparency and position must survive reload and character changes")
end

-- Background edits are independent of visibility and player data; unchanged slider values do no work.
do
    local addon, world = newAddon()
    local changes = 0
    addon:RegisterNotification("RANKING_CHANGED", function() changes = changes + 1 end)
    addon.rankingOverlayDismissed = true
    assert(addon:SetRankingBackgroundTransparency(0) and changes == 0)
    assert(addon:SetRankingBackgroundTransparency(41.7) and addon:GetRankingSettings().backgroundTransparency == 42)
    assert(changes == 1 and addon:SetRankingBackgroundTransparency(42.1) and changes == 1,
        "Only a changed whole percentage should notify the overlay")
    assert(addon:SetRankingBackgroundTransparency(-25) and addon:GetRankingSettings().backgroundTransparency == 0)
    assert(addon:SetRankingBackgroundTransparency(125) and addon:GetRankingSettings().backgroundTransparency == 100)
    for _, invalid in ipairs({ "50", false, {}, function() end, math.huge, -math.huge, 0 / 0 }) do
        assert(not addon:SetRankingBackgroundTransparency(invalid)
            and addon:GetRankingSettings().backgroundTransparency == 100,
            "Invalid edits must leave the last saved transparency intact")
    end
    assert(not addon:SetRankingBackgroundTransparency(nil))
    assert(changes == 3 and not addon:GetRankingSettings().enabled and addon.rankingOverlayDismissed == true
        and addon:GetRankingSettings().burningEffect and world.reads == 0,
        "Transparency must not reactivate the overlay, change effects or read player status")
end

-- Changing the visual effect is independent of overlay visibility and status sharing.
do
    local addon, world = newAddon()
    local changes = 0
    addon:RegisterNotification("RANKING_CHANGED", function() changes = changes + 1 end)
    addon.rankingOverlayDismissed = true
    assert(addon:SetRankingBurningEffect(false))
    assert(not addon:GetRankingSettings().enabled and addon.rankingOverlayDismissed == true and changes == 1,
        "Disabling the effect must notify the UI without showing or reactivating the overlay")
    assert(addon:SetRankingBurningEffect(true))
    assert(addon:GetRankingSettings().burningEffect and not addon:GetRankingSettings().enabled
        and addon.rankingOverlayDismissed == true and changes == 2 and world.reads == 0,
        "Effect changes must not read player status or require a network transport")
end

-- Damaged settings fall back safely while preserving unrelated saved data.
do
    for _, invalid in ipairs({ false,
        { enabled = "yes", burningEffect = "no", position = { point = "INVALID", x = 1, y = 2 } } }) do
        local saved = { schemaVersion = 4, ranking = invalid, otherSettings = { preserved = true } }
        local addon = newAddon(saved)
        local settings = addon:GetRankingSettings()
        assert(settings.enabled == false and settings.position == nil
            and settings.burningEffect and settings.backgroundTransparency == 0)
        assert(saved.otherSettings.preserved == true)
    end
    for _, invalid in ipairs({ 0, 1, "false", {}, function() end }) do
        local saved = { schemaVersion = 4, ranking = { burningEffect = invalid, futureField = "keep" } }
        local addon = newAddon(saved)
        assert(addon:GetRankingSettings().burningEffect == true and saved.ranking.burningEffect == true
            and saved.ranking.futureField == "keep", "Only an explicit false disables the saved effect")
    end
    for _, invalid in ipairs({ "50", false, {}, math.huge, -math.huge, 0 / 0 }) do
        local saved = { schemaVersion = 4, ranking = { backgroundTransparency = invalid, futureField = "keep" } }
        local addon = newAddon(saved)
        assert(addon:GetRankingSettings().backgroundTransparency == 0 and saved.ranking.backgroundTransparency == 0
            and saved.ranking.futureField == "keep", "Invalid saved transparency defaults to zero without losing unknown fields")
    end
    for _, case in ipairs({ { -25, 0 }, { 41.7, 42 }, { 125, 100 } }) do
        local addon = newAddon({ ranking = { backgroundTransparency = case[1] } })
        assert(addon:GetRankingSettings().backgroundTransparency == case[2],
            "Restored transparency is clamped and rounded like slider edits")
    end
end

-- Newer-schema profiles reject preference changes and keep all saved data untouched while moving temporarily.
do
    local position = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 40, y = -60 }
    local saved = { schemaVersion = 999, ranking = { enabled = true, locked = false, burningEffect = false, backgroundTransparency = 65,
        includedFriends = { ["alex-wren"] = true },
        shownPlayers = { ["bea-ivy"] = false },
        position = position, futureField = "keep" }, otherSettings = { preserved = true } }
    local before = copy(saved)
    local addon = newAddon(saved, true)
    assert(not addon:SetRankingEnabled(false) and not addon:SetRankingPlayerShown("alex-wren", false)
        and not addon:SetRankingPlayerShown("bea-ivy", true) and addon:IsRankingPlayerShown("alex-wren")
        and not addon:IsRankingPlayerShown("bea-ivy", true)
        and not addon:SetRankingBurningEffect(true))
    assert(not addon:SetRankingBackgroundTransparency(50) and not addon:SetRankingBackgroundTransparency(65))
    local moved = { point = "BOTTOMRIGHT", relativePoint = "BOTTOMRIGHT", x = -90, y = 120 }
    assert(addon:SetRankingPosition(moved), "Read-only profiles still permit temporary overlay movement")
    local settings = addon:GetRankingSettings()
    assert(settings.enabled and not settings.burningEffect
        and settings.backgroundTransparency == 65 and equal(settings.position, moved))
    assert(equal(saved, before), "Temporary placement must never write into newer-schema saved settings")
    moved.x = 999
    assert(addon:GetRankingSettings().position.x == -90, "Temporary placement must detach caller-owned values")
    local reloaded = newAddon(saved, true)
    assert(equal(reloaded:GetRankingSettings().position, position), "Read-only movement must not survive reload")
    local malformed = { schemaVersion = 999, ranking = "future-format", otherSettings = { preserved = true } }
    local malformedBefore = copy(malformed)
    local future = newAddon(malformed, true)
    assert(future:GetRankingSettings().enabled == false
        and future:GetRankingSettings().burningEffect == true and future:GetRankingSettings().backgroundTransparency == 0)
    assert(equal(malformed, malformedBefore), "Read-only initialization must not normalize unknown settings")
    local invalid = { schemaVersion = 999, ranking = { burningEffect = "future-value", backgroundTransparency = "future-value", futureField = "keep" } }
    local invalidBefore = copy(invalid)
    local invalidAddon = newAddon(invalid, true)
    assert(invalidAddon:GetRankingSettings().burningEffect == true
        and invalidAddon:GetRankingSettings().backgroundTransparency == 0 and equal(invalid, invalidBefore),
        "Read-only normalization uses detached appearance settings and leaves future values untouched")
end

-- Before initialization no operation may create or change saved preferences.
do
    local saved = { schemaVersion = 4 }
    local addon = newAddon(saved, false, true)
    addon.initialized = false
    assert(not addon:SetRankingEnabled(true) and not addon:SetRankingBurningEffect(false))
    assert(not addon:SetRankingBackgroundTransparency(50))
    assert(not addon:SetRankingPosition({ point = "CENTER", relativePoint = "CENTER", x = 20, y = -20 }))
    assert(saved.ranking == nil)
    addon.initialized = true
    assert(not addon:SetRankingBurningEffect(false) and saved.ranking == nil,
        "Effect changes must wait for ranking initialization as well as addon initialization")
    assert(not addon:SetRankingBackgroundTransparency(50) and saved.ranking == nil,
        "Transparency changes must wait for ranking initialization as well as addon initialization")
end

print("Ranking model checks passed")
