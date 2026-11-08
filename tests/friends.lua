local loadAddon = dofile("tests/support/addon.lua").loadAddon

local function game(name, project, level)
    return {
        characterName = name, wowProjectID = project or 18, characterLevel = level or 20,
        clientProgram = "WoW", isInCurrentRegion = true, isOnline = true, isAppearOffline = false,
        areaName = "Elwynn Forest",
    }
end

local function account(id, games)
    return { bnetAccountID = id, appearOffline = false, games = games }
end

local function find(addon, id)
    for _, row in ipairs(addon:GetFriendsPlayers()) do
        if row.id == id then return row end
    end
end

local addon, environment, _, fire, world = loadAddon({ showWelcome = false }, false)
local secret = {}
environment.issecretvalue = function(value) return value == secret end
local online, sameFirst, retail, foreign, hidden, incomplete = game("Ari Stone"), game("Ari Flint"),
    game("Other Game", 1), game("Other Region"), game("Hidden Friend"), game("No Surname")
foreign.isInCurrentRegion = false
hidden.isAppearOffline = true
incomplete.characterName = "Ari"
incomplete.playerGuid = "Player-7-0001"
local secretName = game(secret)
local primary = account(1, { retail, online, sameFirst, foreign, hidden, incomplete, secretName })
local accounts, connected, legacyEnabled = { primary, account(2, { game("Other Classic", 2) }) }, true, true
local characterFriends = {
    { name = "Ari-Stone", connected = false, level = 19 },
    { name = "Offline Friend", connected = false, level = 15 },
    { name = "Unknown Friend", connected = secret, level = secret },
}
environment.WOW_PROJECT_CAMELOT, environment.BNET_CLIENT_WOW = 18, "WoW"
environment.BNConnected = function() return connected end
environment.BNGetNumFriends = function() return #accounts end
environment.C_BattleNet = {
    GetFriendAccountInfo = function(index) return accounts[index] end,
    GetFriendNumGameAccounts = function(index) return #accounts[index].games end,
    GetFriendGameAccountInfo = function(index, gameIndex) return accounts[index].games[gameIndex] end,
}
environment.C_FriendList = {
    IsLegacyFriendSystemEnabled = function() return legacyEnabled end,
    GetNumFriends = function() return #characterFriends end,
    GetFriendInfoByIndex = function(index) return characterFriends[index] end,
}
assert(#addon:GetFriendsPlayers() == 0, "Do not read native friends before login")
local changes = 0
addon:RegisterNotification("FRIENDS_CHANGED", function() changes = changes + 1 end)
world:initialize()

assert(#addon:GetFriendsPlayers() == 5 and changes == 1,
    "Keep same-region Forever characters, deduplicate both native friend systems, and skip unrelated game accounts")
local row = assert(find(addon, "ari-stone"))
assert(row.name == "Ari-Stone" and row.displayName == "Ari Stone" and row.aliasID == "ari stone-testrealm"
    and row.level == 20 and row.zone == "Elwynn Forest" and row.online == true and row.seenAt == 2000000000,
    "Render the full surname and expose the roster alias, current level, zone, and presence")
assert(find(addon, "ari-flint").displayName == "Ari Flint", "Surnames distinguish characters with the same first name")
assert(find(addon, "friend:Player-7-0001").name == "Ari",
    "An incomplete name with a GUID stays separate from canonical full names")
assert(find(addon, "offline-friend").online == false and find(addon, "offline-friend").level == 15)
assert(find(addon, "unknown-friend").online == nil and find(addon, "unknown-friend").level == nil,
    "Secret presence and level are unknown")

world:advance(10)
fire("BN_FRIEND_INFO_CHANGED", 1)
assert(changes == 1 and find(addon, "ari-stone").seenAt == 2000000010,
    "Repeated sightings update last observed time without refreshing unchanged visible rows")
world:advance(10)
online.characterLevel, online.areaName = 21, "Westfall"
fire("BN_FRIEND_INFO_CHANGED", 1)
assert(changes == 2 and find(addon, "ari-stone").level == 21 and find(addon, "ari-stone").zone == "Westfall",
    "Native updates refresh a friend's level and area automatically")

connected = false
fire("BN_DISCONNECTED")
row = assert(find(addon, "ari-flint"))
assert(changes == 3 and row.online == nil and row.level == 20 and row.seenAt == 2000000020,
    "A Battle.net disconnect retains sightings with unknown presence")
connected, accounts = true, {}
fire("BN_CONNECTED")
assert(changes == 3 and find(addon, "ari-flint").online == nil,
    "A reconnect can announce a temporarily empty list without removing cached characters")
accounts = { primary }
fire("BN_FRIEND_LIST_SIZE_CHANGED")
assert(changes == 4 and find(addon, "ari-flint").online == true)

primary.games = { retail }
fire("BN_FRIEND_ACCOUNT_OFFLINE", 1)
row = assert(find(addon, "ari-flint"))
assert(changes == 5 and row.online == false and row.seenAt == 2000000020,
    "A friend with no visible Forever session retains the last character observation")
primary.games = { game("New Character", 18, 10) }
fire("BN_FRIEND_ACCOUNT_ONLINE", 1)
assert(changes == 6 and #addon:GetFriendsPlayers() == 4 and find(addon, "new-character").level == 10
    and not find(addon, "ari-flint"), "A visible character switch replaces the previous Battle.net characters")
accounts = {}
fire("BN_FRIEND_LIST_SIZE_CHANGED")
assert(changes == 7 and not find(addon, "new-character"), "A removed friend drops out of the snapshot")
legacyEnabled = false
fire("LEGACY_FRIEND_SYSTEM_STATUS_UPDATED")
assert(changes == 8 and #addon:GetFriendsPlayers() == 0)

fire("PLAYER_LOGOUT")
accounts = { primary }
fire("BN_FRIEND_LIST_SIZE_CHANGED")
assert(changes == 8 and #addon:GetFriendsPlayers() == 0 and environment.LockInToolsDB.friends == nil,
    "Friend observations are session-local and stop updating at logout")

print("PASS: automatic Forever friends, identity, presence, and session observations")
