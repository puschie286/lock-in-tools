local _, addon = ...

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function Native(callback, ...)
    if type(callback) ~= "function" then return nil end
    local ok, value = pcall(callback, ...)
    if ok and not IsSecret(value) then return value end
end

local function Field(record, key, kind)
    local value = record[key]
    if not IsSecret(value) and type(value) == kind then return value end
end

local function Text(record, key)
    local value = Field(record, key, "string")
    if value and value ~= "" and not value:find("[|%c]") then return value end
end

local function Integer(value, minimum)
    if type(value) == "number" and value >= minimum and value < math.huge
        and value == math.floor(value) then return value end
end

local function RealmName(realm)
    if type(realm) == "string" then
        local normalized = realm:gsub("[%s%-']", ""):lower()
        if normalized ~= "" then return normalized end
    end
end

local function InternalRealm(realm)
    local normalized = RealmName(realm)
    if normalized and normalized:match("^camwow%a+%d+realm%d+%a+$") then return normalized end
end

local function RealmPool(realm)
    return realm:gsub("realm%d+", "realm")
end

local function FullName(name)
    if IsSecret(name) or type(name) ~= "string" or #name > 128 or name:find("[|%c]") then return nil end
    local first, surname, realm = name:match("^([^%s%-]+)[%s%-]+([^%s%-]+)%-(.+)$")
    if not first then first, surname = name:match("^([^%s%-]+)[%s%-]+([^%s%-]+)$") end
    if first and not InternalRealm(surname) then return first, surname, realm end
end

local function Character(record, nameKey, guidKey)
    local name = Text(record, nameKey)
    if not name or #name > 128 then return nil end
    local first, surname, realm = FullName(name)
    local guid = Text(record, guidKey)
    if first then
        local canonical, display = first .. "-" .. surname, first .. " " .. surname
        -- The existing roster can also hold a space-separated full name with
        -- its fallback realm appended. Match that complete name as an alias.
        local alias = Native(addon.GetDataSenderIdentity, addon, realm and (display .. "-" .. realm) or display)
        return canonical:lower(), canonical, display, alias, guid, realm
    end
    if guid and not name:find("[%s%-]") then return "friend:" .. guid, name, name end
end

local function Row(record, nativeGame, online, previous, now)
    local nameKey = nativeGame and "characterName" or "name"
    local id, name, displayName, aliasID, guid, nameRealm = Character(record, nameKey, nativeGame and "playerGuid" or "guid")
    if not id then return nil end
    local last = previous[id] or {}
    return {
        id = id, name = name, displayName = displayName, aliasID = aliasID, online = online,
        guid = guid, legacy = not nativeGame,
        realm = nativeGame and Text(record, "realmName") or (not nativeGame and nameRealm or nil),
        displayRealm = nativeGame and RealmName(Text(record, "realmDisplayName")) or nil,
        gameAccountID = nativeGame and Integer(Field(record, "gameAccountID", "number"), 1) or nil,
        whisper = not nativeGame and displayName or nil,
        level = Integer(Field(record, nativeGame and "characterLevel" or "level", "number"), 1) or last.level,
        zone = online and Text(record, nativeGame and "areaName" or "area") or (not online and last.zone or nil),
        seenAt = online and now or last.seenAt,
    }
end

local function ForeverPresence(game)
    if type(game) ~= "table" or not WOW_PROJECT_CAMELOT or not BNET_CLIENT_WOW then return nil end
    local client = Field(game, "clientProgram", "string")
    local project = Field(game, "wowProjectID", "number")
    -- Forever's full names identify characters within a single region.
    local sameRegion = Field(game, "isInCurrentRegion", "boolean")
    local online = Field(game, "isOnline", "boolean")
    local hidden = Field(game, "isAppearOffline", "boolean")
    if (client and client ~= BNET_CLIENT_WOW) or (project and project ~= WOW_PROJECT_CAMELOT)
        or sameRegion == false or online == false or hidden == true then return false end
    if client and project and sameRegion and online and hidden == false then return true end
end

local function WithPresence(previous, online)
    local rows = {}
    for id, old in pairs(previous) do
        local row = old
        if old.online ~= online then
            row = {}
            for field, value in pairs(old) do row[field] = value end
            row.online = online
        end
        rows[id] = row
    end
    return rows
end

local function ReadBattleNet(previous, now, event)
    local accounts = {}
    if not C_BattleNet or (BNConnected and Native(BNConnected) ~= true) or event == "BN_DISCONNECTED"
        or Native(C_BattleNet.IsBattleNetFriendsListEnabled) == false then return nil end
    local count = Integer(Native(BNGetNumFriends), 0)
    -- A reconnect can announce presence before restoring the friends list.
    if not count or (count == 0 and event == "BN_CONNECTED") then return nil end
    local complete = true
    for index = 1, count do
        local info = Native(C_BattleNet.GetFriendAccountInfo, index)
        local accountID = type(info) == "table" and Integer(Field(info, "bnetAccountID", "number"), 1)
        if accountID then
            local last = previous[accountID] or {}
            local rows = {}
            local appearOffline = Field(info, "appearOffline", "boolean")
            local available = appearOffline ~= nil
            local levels = Enum and Enum.BattleNetFriendLevel
            local friendLevel = Field(info, "friendLevel", "number")
            local titleFriend = levels and levels.Title ~= nil and friendLevel == levels.Title
            local isFriend = Field(info, "isFriend", "boolean") == true or titleFriend
            if appearOffline == false then
                local gameCount = Integer(Native(C_BattleNet.GetFriendNumGameAccounts, index), 0)
                available = gameCount ~= nil
                for gameIndex = 1, gameCount or 0 do
                    local game = Native(C_BattleNet.GetFriendGameAccountInfo, index, gameIndex)
                    local online = ForeverPresence(game)
                    if online then
                        local row = Row(game, true, true, last, now)
                        if row then
                            if not isFriend then row.gameAccountID = nil end
                            -- WoW title friends are listed by Battle.net in Forever.
                            -- Their character name can also be used for addon whispers.
                            if titleFriend then row.whisper = row.displayName end
                            rows[row.id] = row
                        else
                            available = false
                        end
                    elseif online == nil then
                        available = false
                    end
                end
            end
            if not next(rows) then
                if available then rows = WithPresence(last, false) else rows = WithPresence(last, nil) end
            end
            accounts[accountID] = rows
        else
            complete = false
        end
    end
    if not complete then
        for accountID, rows in pairs(previous) do
            if not accounts[accountID] then accounts[accountID] = WithPresence(rows, nil) end
        end
    end
    return accounts
end

local function ReadCharacterFriends(previous, now)
    local rows = {}
    if not C_FriendList or Native(C_FriendList.IsLegacyFriendSystemEnabled) ~= true then return rows end
    local count = Integer(Native(C_FriendList.GetNumFriends), 0) or 0
    for index = 1, count do
        local info = Native(C_FriendList.GetFriendInfoByIndex, index)
        if type(info) == "table" then
            local online = Field(info, "connected", "boolean")
            local row = Row(info, false, online, previous, now)
            if row then rows[row.id] = row end
        end
    end
    return rows
end

local function AddDataFriend(friends, row, localRealm)
    if not localRealm or row.online ~= true or not row.displayName:find(" ", 1, true)
        or not (row.gameAccountID or row.whisper) then return end
    -- Legacy character friends without a realm suffix use the local realm.
    local realm = InternalRealm(row.realm) or (row.legacy and not row.realm and localRealm)
    if not realm or RealmPool(realm) ~= RealmPool(localRealm) then return end
    local previous = friends[row.id]
    local sameCharacter = previous and (not previous.guid or not row.guid or previous.guid == row.guid)
    friends[row.id] = {
        id = row.id, name = row.name, displayName = row.displayName, realm = realm, displayRealm = row.displayRealm,
        guid = row.guid or (sameCharacter and previous.guid or nil),
        gameAccountID = row.gameAccountID,
        whisper = row.whisper or (sameCharacter and previous.whisper or nil),
    }
end

local function DataFriendsChanged(previous, current)
    for id, row in pairs(current) do
        local old = previous[id]
        if not old or row.name ~= old.name or row.realm ~= old.realm or row.displayRealm ~= old.displayRealm
            or row.guid ~= old.guid
            or row.gameAccountID ~= old.gameAccountID or row.whisper ~= old.whisper then return true end
    end
    for id in pairs(previous) do
        if not current[id] then return true end
    end
    return false
end

local function RefreshFriends(self, event)
    local state = self.friendsState
    local now = GetServerTime()
    local battleNet = ReadBattleNet(state.battleNet, now, event)
    if battleNet then state.battleNet = battleNet end
    state.characters = ReadCharacterFriends(state.characters, now)
    local rows, players, data = {}, {}, {}
    local realm = InternalRealm(Native(GetNormalizedRealmName)) or InternalRealm(Native(GetRealmName))
    for id, row in pairs(state.characters) do
        rows[id] = row
        AddDataFriend(data, row, realm)
    end
    for _, friends in pairs(state.battleNet) do
        if not battleNet then friends = WithPresence(friends, nil) end
        for id, row in pairs(friends) do
            if not rows[id] or row.online then rows[id] = row end
            AddDataFriend(data, row, realm)
        end
    end
    local changed = false
    for id, row in pairs(rows) do
        players[#players + 1] = row
        local old = state.rows[id]
        if not old or old.name ~= row.name or old.aliasID ~= row.aliasID or old.online ~= row.online or old.level ~= row.level
            or old.zone ~= row.zone or (not row.online and old.seenAt ~= row.seenAt) then changed = true end
    end
    changed = changed or #players ~= #state.players
    table.sort(players, function(left, right) return left.id < right.id end)
    local dataChanged = DataFriendsChanged(state.data, data)
    state.rows, state.players, state.data = rows, players, data
    if dataChanged then self:Notify("FRIEND_DATA_CHANGED") end
    if changed then self:Notify("FRIENDS_CHANGED", players) end
end

function addon:GetFriendsPlayers()
    return self.friendsState and self.friendsState.players or {}
end

function addon:GetDataFriends()
    return self.friendsState and self.friendsState.data or {}
end

function addon:FindDataFriend(sender)
    local first, surname, realm = FullName(sender)
    if not first then return nil end
    local id = (first .. "-" .. surname):lower()
    local friend = self:GetDataFriends()[id]
    if friend and not realm then return friend, id end
    local normalized = RealmName(realm)
    if friend and normalized and (normalized == friend.realm or normalized == friend.displayRealm) then return friend, id end
end

function addon:GetRankingPlayerKey(id)
    if WOW_PROJECT_CAMELOT and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT and not IsSecret(id) and type(id) == "string" then
        -- A shared name can include a fallback realm after the surname. The
        -- preference must still match the friend's region-unique full name.
        local first, surname, realm = FullName(id)
        if first and realm then return (first .. "-" .. surname):lower() end
    end
    return id
end

function addon:OnFriendsLogin()
    if self.friendsState then return end
    self.friendsState = { battleNet = {}, characters = {}, rows = {}, players = {}, data = {} }
    self:RegisterGameEvents({
        "BN_CONNECTED", "BN_DISCONNECTED", "BN_FRIEND_ACCOUNT_ONLINE", "BN_FRIEND_ACCOUNT_OFFLINE",
        "BN_FRIEND_INFO_CHANGED", "BN_FRIEND_LIST_SIZE_CHANGED", "FRIENDLIST_UPDATE",
        "LEGACY_FRIEND_SYSTEM_STATUS_UPDATED", "SOCIAL_UI_FRIENDS_LIST_SYSTEM_STATUS_UPDATED",
        "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT",
    }, function(self, event)
        if event == "PLAYER_LOGOUT" then self.friendsState = nil end
        if self.friendsState then RefreshFriends(self, event) end
    end)
    RefreshFriends(self)
end
