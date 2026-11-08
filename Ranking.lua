local _, addon = ...

local POINTS = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
    RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true }

local function Number(value, maximum)
    return not (issecretvalue and issecretvalue(value)) and type(value) == "number"
        and value == value and value >= 0 and value <= maximum and value == math.floor(value)
end

local function Transparency(value)
    if (issecretvalue and issecretvalue(value)) or type(value) ~= "number"
        or value ~= value or math.abs(value) == math.huge then return nil end
    return math.floor(math.max(0, math.min(100, value)) + 0.5)
end

local function Position(position)
    local function Offset(value)
        return type(value) == "number" and value == value and math.abs(value) <= 100000
    end
    if type(position) ~= "table" or not POINTS[position.point] or not POINTS[position.relativePoint]
        or not Offset(position.x) or not Offset(position.y) then return nil end
    return { point = position.point, relativePoint = position.relativePoint, x = position.x, y = position.y }
end

local function PlayerKey(self, id)
    if (issecretvalue and issecretvalue(id)) or type(id) ~= "string"
        or #id == 0 or #id > 128 or id:find("[|%c]") then return nil end
    return self.GetRankingPlayerKey and self:GetRankingPlayerKey(id) or id
end

local function PlayerVisibility(self, saved)
    local shown = {}
    if type(saved.shownPlayers) == "table" then
        for id, value in pairs(saved.shownPlayers) do
            local key = PlayerKey(self, id)
            if key and type(value) == "boolean" and (shown[key] == nil or id == key) then shown[key] = value end
        end
    end
    if type(saved.includedFriends) == "table" then
        for id, included in pairs(saved.includedFriends) do
            local key = PlayerKey(self, id)
            if key and included == true and shown[key] == nil then shown[key] = true end
        end
    end
    return shown
end

function addon:InitializeRanking()
    if self.rankingSettings then return end
    local database = self.savedDataReadOnly and type(LockInToolsDB) == "table" and LockInToolsDB or self.db
    local saved = type(database.ranking) == "table" and database.ranking or {}
    local settings = self.savedDataReadOnly and {} or saved
    settings.enabled = saved.enabled == true
    settings.shownPlayers = PlayerVisibility(self, saved)
    settings.includeFriends, settings.includedFriends = nil, nil
    settings.burningEffect = saved.burningEffect ~= false
    settings.backgroundTransparency = Transparency(saved.backgroundTransparency) or 0
    local savedPosition = saved.position
    settings.position = Position(savedPosition)
    if settings.position then
        if self.savedDataReadOnly then
            for key, value in pairs(savedPosition) do settings.position[key] = value end
        else settings.position = savedPosition end
    end
    self.rankingSettings = settings
    if not self.savedDataReadOnly then self.db.ranking = settings end
end

function addon:GetRankingSettings()
    return self.rankingSettings
end

local function Age(stamp)
    if type(stamp) ~= "number" then return "age unknown" end
    local seconds = math.max(0, math.floor(GetServerTime() - stamp))
    if seconds < 60 then return seconds .. "s ago" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m ago" end
    if seconds < 86400 then return math.floor(seconds / 3600) .. "h ago" end
    return math.floor(seconds / 86400) .. "d ago"
end

local function LocationName(self, player)
    if player.friendOnly then return player.zone or "Unknown location" end
    -- Cached coordinates stay private when either side has stopped sharing.
    if not self.db.position or not self.db.position.sharing then return "Position sharing is off" end
    if player.sharing == false then return "Not sharing" end
    if not player.map then return "Unknown location" end
    if C_Map and type(C_Map.GetMapInfo) == "function" then
        local ok, info = pcall(C_Map.GetMapInfo, player.map)
        if ok and type(info) == "table" and type(info.name) == "string" then return info.name end
    end
    return "Map " .. tostring(player.map)
end

function addon:GetCompactPlayerTooltipLines(player)
    local lines = { "#" .. (player.rank or "?") .. " - " .. (player.displayName or self:GetPlayerDisplayName(player.name)) }
    if player.xpState ~= "max" then
        local progress = player.friendOnly and "XP unavailable" or "Awaiting XP"
        if player.level and player.xpState == "known" and type(player.xp) == "number"
            and type(player.xpMax) == "number" and player.xpMax > 0 then
            local missing = math.max(0, player.xpMax - player.xp)
            -- Round missing progress up so a pending level never reads as 0% needed.
            local percent = string.format("%.1f", math.ceil(missing * 1000 / player.xpMax) / 10)
                :gsub("%.0$", "") .. "%"
            progress = percent .. " (" .. missing .. " XP)"
        end
        lines[#lines + 1] = "Lv " .. (player.level or "?") .. " - " .. progress
    end
    local location = LocationName(self, player)
    if not player.online and not player.isSelf then location = location .. " - " .. Age(player.seenAt) end
    lines[#lines + 1] = location
    return lines
end

function addon:ShowCompactPlayerTooltip(owner, entries, preserveAnchor)
    if not GameTooltip or not owner or type(entries) ~= "table" or #entries == 0 then return false end
    if preserveAnchor then
        -- A periodic refresh must not reclaim another widget's shared tooltip.
        if not GameTooltip:IsOwned(owner) or not GameTooltip:IsShown() then return false end
    else
        GameTooltip_SetDefaultAnchor(GameTooltip, owner)
    end
    if GameTooltip.ClearLines then GameTooltip:ClearLines() end
    for index, entry in ipairs(entries) do
        local lines = self:GetCompactPlayerTooltipLines(entry.player)
        if index == 1 then
            if entry.red then GameTooltip:SetText(lines[1], entry.red, entry.green, entry.blue)
            else GameTooltip:SetText(lines[1]) end
        else
            if entry.red then GameTooltip:AddLine(lines[1], entry.red, entry.green, entry.blue)
            else GameTooltip:AddLine(lines[1]) end
        end
        for line = 2, #lines do GameTooltip:AddLine(lines[line]) end
    end
    GameTooltip:Show()
    return true
end

local function Editable(self, value)
    if not self.initialized or not self.rankingSettings then return false, "Still loading. Please try again after login." end
    if (issecretvalue and issecretvalue(value)) or type(value) ~= "boolean" then return false, "Choose on or off." end
    if self.savedDataReadOnly then return false, "Update LockInTools before changing saved preferences." end
    return true
end

function addon:SetRankingEnabled(enabled)
    local success, message = Editable(self, enabled)
    if not success then return false, message end
    self.rankingSettings.enabled, self.rankingOverlayDismissed = enabled, nil
    self:Notify("RANKING_CHANGED")
    return true
end

function addon:IsRankingPlayerShown(id, defaultShown)
    local settings = self.rankingSettings
    local key = settings and PlayerKey(self, id)
    if not key then return false end
    local shown = settings.shownPlayers[key]
    if shown ~= nil then return shown end
    return defaultShown == true
end

function addon:SetRankingPlayerShown(id, shown)
    local success, message = Editable(self, shown)
    if not success then return false, message end
    local key = PlayerKey(self, id)
    if not key then return false, "Choose a player to show in rankings." end
    if self.rankingSettings.shownPlayers[key] ~= shown then
        self.rankingSettings.shownPlayers[key] = shown
        self:Notify("RANKING_CHANGED")
    end
    return true
end

function addon:SetRankingBurningEffect(enabled)
    local success, message = Editable(self, enabled)
    if not success then return false, message end
    self.rankingSettings.burningEffect = enabled
    self:Notify("RANKING_CHANGED")
    return true
end

function addon:SetRankingBackgroundTransparency(value)
    if not self.initialized or not self.rankingSettings then return false, "Still loading. Please try again after login." end
    local percent = Transparency(value)
    if not percent then return false, "Choose a background transparency percentage." end
    if self.savedDataReadOnly then return false, "Update LockInTools before changing saved preferences." end
    if self.rankingSettings.backgroundTransparency == percent then return true end
    self.rankingSettings.backgroundTransparency = percent
    self:Notify("RANKING_CHANGED")
    return true
end

function addon:SetRankingPosition(position)
    if not self.initialized or not self.rankingSettings then return false, "Still loading." end
    local valid = Position(position)
    if not valid then return false, "Invalid overlay position." end
    -- Newer-schema profiles use a detached settings table for temporary movement.
    if type(self.rankingSettings.position) ~= "table" then self.rankingSettings.position = {} end
    local saved = self.rankingSettings.position
    saved.point, saved.relativePoint, saved.x, saved.y = valid.point, valid.relativePoint, valid.x, valid.y
    return true
end

local function Complete(player)
    if not Number(player.level, 1000) or player.level == 0 then return false end
    if player.xpState == "max" then return true end
    return player.xpState == "known" and Number(player.xp, 9999999999)
        and Number(player.xpMax, 9999999999) and player.xpMax > 0 and player.xp <= player.xpMax
end

local function Fraction(player)
    if player.xpState == "max" then return 1, 1 end
    return player.xp, player.xpMax
end

local function CompareProgress(left, right)
    if left.level ~= right.level then return left.level < right.level and -1 or 1 end
    -- The relative XP of friends with only a level is unknown.
    if left.friendOnly then return right.friendOnly and 0 or -1 end
    if right.friendOnly then return 1 end
    local a, b = Fraction(left)
    local c, d = Fraction(right)
    -- Continued fractions compare the integers exactly without cross-products
    -- exceeding Lua's exact integer range for the protocol's ten-digit values.
    local direction = 1
    while true do
        local q, r = math.floor(a / b), math.floor(c / d)
        if q ~= r then return (q < r and -1 or 1) * direction end
        a, c = a % b, c % d
        if a == 0 or c == 0 then
            if a == c then return 0 end
            return (a == 0 and -1 or 1) * direction
        end
        a, b, c, d, direction = b, a, d, c, -direction
    end
end

local function Copy(player)
    local row = {}
    for key, value in pairs(player) do row[key] = value end
    row.rank = nil
    return row
end

local function SameProgress(player, previous)
    return previous and player.level == previous.level and player.xpState == previous.xpState
        and player.xp == previous.xp and player.xpMax == previous.xpMax
end

local function FriendLevel(friend)
    return Number(friend.level, 1000) and friend.level > 0
end

local function HasNewerFriendLevel(row, friend)
    return row.stale and friend and friend.online and FriendLevel(friend) and friend.level > row.level
        and Number(friend.seenAt, 9999999999) and Number(row.seenAt, 9999999999) and friend.seenAt > row.seenAt
end

function addon:GetPlayerRanking(overviewPlayers)
    local result = { players = {}, connected = false, grouped = false, hasFriends = false }
    if not self.initialized or not self.ready then return result end
    result.grouped = self:HasDataGroup()
    result.connected = self:IsDataConnected()
    local friends, friendsByID, hiddenFriendIDs = {}, {}, {}
    local shownPlayers = self.rankingSettings and self.rankingSettings.shownPlayers
    local hasPreferences = shownPlayers and next(shownPlayers) ~= nil
    if hasPreferences and self.GetFriendsPlayers then
        for _, friend in ipairs(self:GetFriendsPlayers()) do
            local key, aliasKey = PlayerKey(self, friend.id), PlayerKey(self, friend.aliasID)
            local shown, aliasShown = shownPlayers[key], shownPlayers[aliasKey]
            if key and (shown == false or aliasShown == false) then
                hiddenFriendIDs[key] = true
                if aliasKey then hiddenFriendIDs[aliasKey] = true end
            elseif key and (shown == true or aliasShown == true) then
                friends[#friends + 1] = friend
                friendsByID[key] = friend
                if aliasKey then friendsByID[aliasKey] = friend end
            end
        end
    end
    if not result.grouped and #friends == 0 then return result end
    -- A solo Overview snapshot is empty. Only use the local row for a friend ranking.
    local overview = result.grouped and (overviewPlayers or self:GetOverviewPlayers()) or self:GetOverviewPlayers(true)
    local cached, ranked, rankedCharacters = self.rankingOrderCache, {}, {}
    local changed = cached == nil
    local function Add(row, key)
        result.players[#result.players + 1] = row
        ranked[row.id] = row
        if key then rankedCharacters[key] = true end
        if not cached or not SameProgress(row, cached.progress[row.id]) then changed = true end
    end
    local ownKey
    for _, player in ipairs(overview) do
        local key = hasPreferences and PlayerKey(self, player.id)
        if player.isSelf then ownKey = key end
        if not hasPreferences or (not hiddenFriendIDs[key] and shownPlayers[key] ~= false) then
            local row = Copy(player)
            row.stale = not player.isSelf and (not result.connected or not player.online
                or player.xpStale == true or player.statusSynchronized == false)
            row.xpStale = row.stale
            if player.isSelf then result.own = row end
            if Complete(player) then
                local friend = not player.isSelf and friendsByID[key]
                -- XP from the previous level cannot rank a friend at their new level.
                if not HasNewerFriendLevel(row, friend) then
                    if friend then row.displayName = friend.displayName end
                    Add(row, key)
                end
            end
        end
    end
    for _, friend in ipairs(friends) do
        local key, aliasKey = PlayerKey(self, friend.id), PlayerKey(self, friend.aliasID)
        if FriendLevel(friend) and not rankedCharacters[key] and not rankedCharacters[aliasKey]
            and not (ownKey and (ownKey == key or ownKey == aliasKey)) then
            local row = Copy(friend)
            row.friendOnly, row.stale = true, not friend.online
            row.xpState, row.xp, row.xpMax = "unavailable", nil, nil
            Add(row, key)
            result.hasFriends = true
        end
    end
    if not result.grouped and not result.hasFriends then
        result.players, result.own = {}, nil
        return result
    end
    if cached and #result.players ~= #cached.order then changed = true end
    if changed then
        table.sort(result.players, function(left, right)
            local order = CompareProgress(left, right)
            if order ~= 0 then return order > 0 end
            return left.id < right.id
        end)
        local rank, order, progress = 0, {}, {}
        for index, player in ipairs(result.players) do
            if index == 1 or CompareProgress(player, result.players[index - 1]) ~= 0 then rank = index end
            player.rank = rank
            order[index] = { id = player.id, rank = rank }
            progress[player.id] = { level = player.level, xpState = player.xpState,
                xp = player.xp, xpMax = player.xpMax }
        end
        -- Keep only immutable progress and rank values. Returned display rows may
        -- be annotated by a view and must never own the next call's ordering.
        self.rankingOrderCache = { progress = progress, order = order }
    else
        for index, entry in ipairs(cached.order) do
            local player = ranked[entry.id]
            player.rank, result.players[index] = entry.rank, player
        end
    end
    return result
end

function addon:GetPlayerTooltipPlayers()
    local now = GetTime()
    local cached = self.rankingTooltipCache
    if cached and now >= cached.at and now - cached.at < 1 then return cached.players end
    -- One coherent Overview read supplies unranked discovery and every rank.
    -- Pin/overlay callers apply their current position separately; movement must
    -- not rebuild all progress metadata on every receive or hover frame.
    local overview = self:GetOverviewPlayers()
    local ranking = self:GetPlayerRanking(overview)
    local players = {}
    for _, player in ipairs(overview) do players[player.id] = player end
    for _, player in ipairs(ranking.players) do
        if player.friendOnly then
            -- The map pin owns its shared contact and position. Only attach the
            -- native ranking when it describes the same level.
            local discovered = players[player.id] or players[player.aliasID]
            if discovered and (not discovered.level or discovered.level == player.level) then
                local row = Copy(discovered)
                row.level, row.rank = player.level, player.rank
                players[row.id] = row
            end
        else
            players[player.id] = player
        end
    end
    if ranking.own then players[ranking.own.id] = ranking.own end
    self.rankingTooltipCache = { at = now, players = players }
    return players
end

for _, notification in ipairs({ "ROSTER_CHANGED", "DATA_CHANGED", "RANKING_CHANGED", "FRIENDS_CHANGED" }) do
    addon:RegisterNotification(notification, function() addon.rankingTooltipCache = nil end)
end
