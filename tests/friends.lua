local loadAddon = dofile("tests/support/addon.lua").loadAddon

local function game(name, project, level)
    return {
        characterName = name, wowProjectID = project or 18, characterLevel = level or 20,
        clientProgram = "WoW", isInCurrentRegion = true, isOnline = true, isAppearOffline = false,
        areaName = "Elwynn Forest",
    }
end

local function account(id, games)
    return { bnetAccountID = id, appearOffline = false, isFriend = true, games = games }
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

do
    local addon, environment, _, fire, world = loadAddon({ showWelcome = false }, false)
    local localRealm = "CAMWOW EU5 Realm 8 PvP"
    local otherRealm = "CAMWOW EU5 Realm 6 PvP"
    local function peer(name, id, realm, guid)
        local row = game(name)
        row.gameAccountID, row.realmName, row.playerGuid = id, realm, guid
        return row
    end
    local samePool = peer("Ari Stone", 71, otherRealm, "Player-7-0001")
    samePool.realmDisplayName = "Stone Realm"
    local otherPool = peer("Ari Flint", 72, "CAMWOW EU4 Realm 6 PvP")
    local otherRuleset = peer("Ari Cliff", 73, "CAMWOW EU5 Realm 6 PvE")
    local unknownRealm = peer("Ari Slate", 74)
    local incomplete = peer("Ari", 75, otherRealm, "Player-7-0002")
    local unknownAccount = peer("Ari Sands", nil, otherRealm)
    local games = { samePool, otherPool, otherRuleset, unknownRealm, incomplete, unknownAccount }
    local title = account(2, { peer("Title Friend", 77, otherRealm) })
    title.isFriend, title.friendLevel = false, 3
    local accounts, connected = { account(1, games), title }, true
    local characters = {
        { name = "Ari-Stone-CAMWOWEU5Realm6PvP", connected = true, guid = "Player-7-0001" },
        { name = "Local Friend", connected = true },
        { name = "Far-Friend-CAMWOWEU4Realm6PvP", connected = true },
    }
    environment.WOW_PROJECT_CAMELOT, environment.BNET_CLIENT_WOW = 18, "WoW"
    environment.Enum.BattleNetFriendLevel = { Title = 3 }
    environment.GetNormalizedRealmName = function() return "" end
    environment.GetRealmName = function() return localRealm end
    environment.BNConnected = function() return connected end
    environment.BNGetNumFriends = function() return #accounts end
    environment.C_BattleNet = {
        GetFriendAccountInfo = function(index) return accounts[index] end,
        GetFriendNumGameAccounts = function(index) return #accounts[index].games end,
        GetFriendGameAccountInfo = function(index, gameIndex) return accounts[index].games[gameIndex] end,
    }
    environment.C_FriendList = {
        IsLegacyFriendSystemEnabled = function() return true end,
        GetNumFriends = function() return #characters end,
        GetFriendInfoByIndex = function(index) return characters[index] end,
    }
    local dataChanges = 0
    addon:RegisterNotification("FRIEND_DATA_CHANGED", function() dataChanges = dataChanges + 1 end)
    assert(next(addon:GetDataFriends()) == nil and not addon:FindDataFriend("Ari Stone"))
    world:initialize()

    local friends = addon:GetDataFriends()
    local ari = assert(friends["ari-stone"])
    assert(dataChanges == 1 and ari.name == "Ari-Stone" and ari.displayName == "Ari Stone"
        and ari.gameAccountID == 71 and ari.guid == "Player-7-0001"
        and ari.whisper == "Ari Stone",
        "Realm 8 and Realm 6 in the same EU5 PvP pool share one peer with both native addresses")
    assert(friends["local-friend"].whisper == "Local Friend" and friends["local-friend"].gameAccountID == nil,
        "An unsuffixed legacy friend uses the local realm and the game-provided address")
    assert(friends["title-friend"].gameAccountID == 77 and friends["title-friend"].whisper == "Title Friend",
        "WoW title friends from the Battle.net list can use either native address")
    for _, id in ipairs({ "ari-flint", "ari-cliff", "ari-slate", "ari-sands", "friend:Player-7-0002", "far-friend" }) do
        assert(find(addon, id) and not friends[id], "Ineligible friends remain visible in the UI: " .. id)
    end
    local sender, id = addon:FindDataFriend("ari stone-CAMWOW EU5 Realm 6 PvP")
    assert(sender == ari and id == "ari-stone" and addon:FindDataFriend("Ari-Stone") == ari
        and addon:FindDataFriend("ARI STONE") == ari and addon:FindDataFriend("Ari-Stone-CAMWOWEU5Realm6PvP") == ari
        and addon:FindDataFriend("Ari Stone-StoneRealm") == ari
        and not addon:FindDataFriend("Ari") and not addon:FindDataFriend("Ari-CAMWOWEU5Realm6PvP")
        and not addon:FindDataFriend("Ari Stone-CAMWOWEU5Realm8PvP") and not addon:FindDataFriend("Ari Flint"),
        "Match full Forever names and verified realm aliases without using first names or broad pool matches")

    samePool.characterLevel, samePool.areaName = 21, "Westfall"
    fire("BN_FRIEND_INFO_CHANGED")
    assert(dataChanges == 1 and find(addon, "ari-stone").zone == "Westfall")
    samePool.gameAccountID = 76
    fire("BN_FRIEND_INFO_CHANGED")
    assert(dataChanges == 2 and addon:GetDataFriends()["ari-stone"].gameAccountID == 76,
        "A game-account address change refreshes transport even when the UI is unchanged")
    connected = false
    fire("BN_DISCONNECTED")
    assert(dataChanges == 3 and addon:GetDataFriends()["ari-stone"].gameAccountID == nil,
        "A Battle.net disconnect removes that address immediately and retains the live legacy friend")
    characters[1].connected = false
    fire("FRIENDLIST_UPDATE")
    assert(dataChanges == 4 and not addon:FindDataFriend("Ari Stone"))
    localRealm = "Unknown Realm"
    fire("PLAYER_ENTERING_WORLD")
    assert(next(addon:GetDataFriends()) == nil and find(addon, "local-friend").online,
        "An unknown local realm disables transport without hiding legacy friends")
    fire("PLAYER_LOGOUT")
    assert(next(addon:GetDataFriends()) == nil)
end

print("PASS: automatic Forever friends, identity, presence, and session observations")
