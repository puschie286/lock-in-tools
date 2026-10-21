-- Ranking checks use current and saved Overview reports without a native UI or transport.
local loadNotifications = dofile("tests/support/notifications.lua")

local function loadModule(file, addon, environment)
    local chunk = assert(loadfile(file))
    setfenv(chunk, environment)
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

local function newAddon(saved, readOnly, skipInitialization)
    local world = { players = {}, grouped = true, connected = true, switching = false, reads = 0 }
    local addon = {
        db = saved or { schemaVersion = 3 }, initialized = true, ready = true,
        savedDataReadOnly = readOnly == true,
    }
    function addon:HasGroup() return world.grouped end
    function addon:IsDataConnected() return world.connected end
    function addon:IsGroupSwitching() return world.switching end
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
    function addon:GetGroupFingerprint() return "first-group" end
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
    assert(ranking.connected and ranking.grouped and not ranking.switching)
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
    end
    assert(ranking.stale == 2, "Saved and current reports use the same exact ordering and shared ranks")
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
    assert(ranking.awaiting == 2 and ranking.stale == 3 and ranking.inactive == 2,
        "Stale counts describe ranked snapshots; missing XP stays awaiting")
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
    assert(#ranking.players == 0 and ranking.awaiting == #world.players,
        "Malformed or incomplete progress must remain unranked rather than looking like zero XP")
end

-- Disconnecting retains saved standings while marking every peer snapshot stale.
do
    local addon, world = newAddon()
    world.players = { player("friend", 30, 50, 100), player("self", 29, 25, 100, true) }
    assert(addon:GetPlayerRanking().own.rank == 2)
    world.connected = false
    local ranking = addon:GetPlayerRanking()
    assert(not ranking.connected and ranking.grouped and #ranking.players == 2 and ranking.stale == 1,
        "Connection loss retains standings using the peers' last saved progress")
    assert(ranking.players[1].stale and ranking.players[1].xpStale)
    assert(ranking.own and ranking.own.id == "self" and ranking.own.xp == 25 and ranking.own.rank == 2
        and ranking.own.stale == false and ranking.own.xpStale == false,
        "Live local progress remains current and comparable against the last peer reports")
    world.connected = true
    local recovered = addon:GetPlayerRanking()
    assert(#recovered.players == 2 and recovered.own.rank == 2 and recovered.stale == 0
        and recovered.players[1].stale == false)
    world.switching = true
    ranking = addon:GetPlayerRanking()
    assert(ranking.switching and #ranking.players == 0 and ranking.own == nil,
        "Switching groups must clear old group standings, including the own-rank row")
    world.switching, world.grouped = false, false
    ranking = addon:GetPlayerRanking()
    assert(not ranking.grouped and #ranking.players == 0 and ranking.own == nil,
        "Leaving the group must clear every ranking row")
end

-- Real Roster reports survive a SavedVariables reload and rank before peers reconnect.
do
    local saved = { schemaVersion = 3 }
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
    assert(not ranking.connected and ranking.awaiting == 1 and ranking.stale == 2 and ranking.inactive == 3)
    assert(ids(ranking.players) == "maximum-testrealm,friend-testrealm,self-testrealm"
        and ranking.own.rank == 3, "Saved XP and maximum-level records remain ranked before reconnection")
    assert(ranking.players[1].xpState == "max" and ranking.players[1].stale
        and ranking.players[2].xp == 700 and ranking.players[2].xpMax == 1000 and ranking.players[2].stale)
    restored.connected = true
    restored.statusConnected(true)
    ranking = reloaded:GetPlayerRanking()
    assert(ranking.stale == 2, "Reconnecting alone cannot make saved reports current")
    assert(reloaded:ReceivePlayerStatus("Friend-TestRealm", {
        level = 31, xp = 750, xpMax = 1000, xpState = "known",
    }, 2, 1))
    ranking = reloaded:GetPlayerRanking()
    assert(ranking.stale == 1 and ranking.players[2].xp == 750 and not ranking.players[2].stale,
        "A fresh status replaces saved XP and clears only that player's stale marker")
    restored.now = 91
    ranking = reloaded:GetPlayerRanking()
    assert(ranking.stale == 2 and ranking.players[2].xp == 750,
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

-- Visibility defaults off, locking and the burning effect on; preferences persist account-wide.
do
    local saved = { schemaVersion = 3, group = { secret = "preserved" }, futureField = "keep",
        ranking = { futureField = { preserved = true } } }
    local addon = newAddon(saved)
    local settings = addon:GetRankingSettings()
    assert(settings.enabled == false and settings.locked == true and settings.position == nil
        and settings.burningEffect == true)
    assert(addon:SetRankingEnabled(true) and addon:SetRankingLocked(false) and addon:SetRankingBurningEffect(false))
    local position = { point = "TOPRIGHT", relativePoint = "TOPRIGHT", x = -80, y = -160 }
    assert(addon:SetRankingPosition(position))
    assert(saved.ranking.enabled == true and saved.ranking.locked == false and saved.ranking.burningEffect == false
        and equal(saved.ranking.position, position))
    assert(saved.group.secret == "preserved" and saved.futureField == "keep" and saved.ranking.futureField.preserved)
    assert(not addon:SetRankingEnabled("true") and not addon:SetRankingLocked("true")
        and not addon:SetRankingBurningEffect("true"),
        "Saved overlay preferences accept booleans only")
    assert(not addon:SetRankingEnabled(nil) and not addon:SetRankingLocked(nil) and not addon:SetRankingBurningEffect(nil))
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
    assert(settings.enabled and not settings.locked and not settings.burningEffect and equal(settings.position, position),
        "Visibility, locking, burning effect and position must survive reload and character changes")
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
        { enabled = "yes", locked = 0, burningEffect = "no", position = { point = "INVALID", x = 1, y = 2 } } }) do
        local saved = { schemaVersion = 3, ranking = invalid, group = { secret = "preserved" } }
        local addon = newAddon(saved)
        local settings = addon:GetRankingSettings()
        assert(settings.enabled == false and settings.locked == true and settings.position == nil and settings.burningEffect)
        assert(saved.group.secret == "preserved")
    end
    for _, invalid in ipairs({ 0, 1, "false", {}, function() end }) do
        local saved = { schemaVersion = 3, ranking = { burningEffect = invalid, futureField = "keep" } }
        local addon = newAddon(saved)
        assert(addon:GetRankingSettings().burningEffect == true and saved.ranking.burningEffect == true
            and saved.ranking.futureField == "keep", "Only an explicit false disables the saved effect")
    end
end

-- Newer-schema profiles reject preference changes and keep all saved data untouched while moving temporarily.
do
    local position = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 40, y = -60 }
    local saved = { schemaVersion = 999, ranking = { enabled = true, locked = false, burningEffect = false,
        position = position, futureField = "keep" }, group = { secret = "preserved" } }
    local before = copy(saved)
    local addon = newAddon(saved, true)
    assert(not addon:SetRankingEnabled(false) and not addon:SetRankingLocked(true) and not addon:SetRankingBurningEffect(true))
    local moved = { point = "BOTTOMRIGHT", relativePoint = "BOTTOMRIGHT", x = -90, y = 120 }
    assert(addon:SetRankingPosition(moved), "Read-only profiles still permit temporary overlay movement")
    local settings = addon:GetRankingSettings()
    assert(settings.enabled and not settings.locked and not settings.burningEffect and equal(settings.position, moved))
    assert(equal(saved, before), "Temporary placement must never write into newer-schema saved settings")
    moved.x = 999
    assert(addon:GetRankingSettings().position.x == -90, "Temporary placement must detach caller-owned values")
    local reloaded = newAddon(saved, true)
    assert(equal(reloaded:GetRankingSettings().position, position), "Read-only movement must not survive reload")
    local malformed = { schemaVersion = 999, ranking = "future-format", group = { secret = "preserved" } }
    local malformedBefore = copy(malformed)
    local future = newAddon(malformed, true)
    assert(future:GetRankingSettings().enabled == false and future:GetRankingSettings().locked == true
        and future:GetRankingSettings().burningEffect == true)
    assert(equal(malformed, malformedBefore), "Read-only initialization must not normalize unknown settings")
    local invalid = { schemaVersion = 999, ranking = { burningEffect = "future-value", futureField = "keep" } }
    local invalidBefore = copy(invalid)
    local invalidAddon = newAddon(invalid, true)
    assert(invalidAddon:GetRankingSettings().burningEffect == true and equal(invalid, invalidBefore),
        "Read-only normalization uses detached effect settings and leaves future values untouched")
end

-- Before initialization no operation may create or change saved preferences.
do
    local saved = { schemaVersion = 3 }
    local addon = newAddon(saved, false, true)
    addon.initialized = false
    assert(not addon:SetRankingEnabled(true) and not addon:SetRankingLocked(false) and not addon:SetRankingBurningEffect(false))
    assert(not addon:SetRankingPosition({ point = "CENTER", relativePoint = "CENTER", x = 20, y = -20 }))
    assert(saved.ranking == nil)
    addon.initialized = true
    assert(not addon:SetRankingBurningEffect(false) and saved.ranking == nil,
        "Effect changes must wait for ranking initialization as well as addon initialization")
end

print("Ranking model checks passed")
