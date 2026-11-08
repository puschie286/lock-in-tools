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

local function Character(record, nameKey, guidKey)
    local name = Text(record, nameKey)
    if not name or #name > 128 then return nil end
    local first, surname = name:match("^([^%s%-]+)[%s%-]+([^%s%-]+)$")
    if first then
        local canonical, display = first .. "-" .. surname, first .. " " .. surname
        -- The existing roster can also hold a space-separated full name with
        -- its fallback realm appended. Match that complete name as an alias.
        return canonical:lower(), canonical, display, Native(addon.GetDataSenderIdentity, addon, display)
    end
    local guid = Text(record, guidKey)
    if guid and not name:find("[%s%-]") then return "friend:" .. guid, name, name end
end

local function Row(record, nativeGame, online, previous, now)
    local nameKey = nativeGame and "characterName" or "name"
    local id, name, displayName, aliasID = Character(record, nameKey, nativeGame and "playerGuid" or "guid")
    if not id then return nil end
    local last = previous[id] or {}
    return {
        id = id, name = name, displayName = displayName, aliasID = aliasID, online = online,
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
            if appearOffline == false then
                local gameCount = Integer(Native(C_BattleNet.GetFriendNumGameAccounts, index), 0)
                available = gameCount ~= nil
                for gameIndex = 1, gameCount or 0 do
                    local game = Native(C_BattleNet.GetFriendGameAccountInfo, index, gameIndex)
                    local online = ForeverPresence(game)
                    if online then
                        local row = Row(game, true, true, last, now)
                        if row then rows[row.id] = row else available = false end
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

local function RefreshFriends(self, event)
    local state = self.friendsState
    local now = GetServerTime()
    local battleNet = ReadBattleNet(state.battleNet, now, event)
    if battleNet then state.battleNet = battleNet end
    state.characters = ReadCharacterFriends(state.characters, now)
    local rows, players = {}, {}
    for id, row in pairs(state.characters) do rows[id] = row end
    for _, friends in pairs(state.battleNet) do
        if not battleNet then friends = WithPresence(friends, nil) end
        for id, row in pairs(friends) do
            if not rows[id] or row.online then rows[id] = row end
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
    state.rows, state.players = rows, players
    if changed then self:Notify("FRIENDS_CHANGED") end
end

function addon:GetFriendsPlayers()
    return self.friendsState and self.friendsState.players or {}
end

function addon:GetRankingPlayerKey(id)
    if WOW_PROJECT_CAMELOT and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT and not IsSecret(id) and type(id) == "string" then
        -- A shared name can include a fallback realm after the surname. The
        -- preference must still match the friend's region-unique full name.
        local first, surname = id:match("^([^%s%-]+)%s+([^%s%-]+)%-[^%s]+$")
        if first then return first .. "-" .. surname end
    end
    return id
end

function addon:OnFriendsLogin()
    if self.friendsState then return end
    self.friendsState = { battleNet = {}, characters = {}, rows = {}, players = {} }
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
