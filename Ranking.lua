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

function addon:InitializeRanking()
    if self.rankingSettings then return end
    local database = self.savedDataReadOnly and type(LockInToolsDB) == "table" and LockInToolsDB or self.db
    local saved = type(database.ranking) == "table" and database.ranking or {}
    local settings = self.savedDataReadOnly and {} or saved
    settings.enabled, settings.locked = saved.enabled == true, saved.locked ~= false
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

function addon:GetRankingHelpText()
    return "Rank: higher level first, then exact XP progress; equal progress shares a rank.\n"
        .. "XP %: progress toward the next level. MAX: confirmed maximum level.\n"
        .. "Dimmed progress: last saved values, which may have changed; these values still count in the ranking.\n"
        .. "Awaiting XP: no usable level and XP report yet (new discovery, older saved data or a level-up). "
        .. "These characters have no rank until progress is available.\n"
        .. "Hover a player for exact XP and location; right-click for Invite or Request to join."
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
    local lines = { "#" .. (player.rank or "?") .. " - " .. self:GetPlayerDisplayName(player.name) }
    if player.xpState ~= "max" then
        local progress = "Awaiting XP"
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
    if type(value) ~= "boolean" then return false, "Choose on or off." end
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

function addon:SetRankingLocked(locked)
    local success, message = Editable(self, locked)
    if not success then return false, message end
    self.rankingSettings.locked = locked
    self:Notify("RANKING_CHANGED")
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

function addon:GetPlayerRanking(overviewPlayers)
    local result = { players = {}, awaiting = 0, stale = 0, inactive = 0,
        connected = false, grouped = false, switching = false }
    if not self.initialized or not self.ready then return result end
    result.grouped, result.switching = self:HasGroup(), self:IsGroupSwitching()
    result.connected = self:IsDataConnected()
    if not result.grouped or result.switching then return result end
    local cached, ranked = self.rankingOrderCache, {}
    local changed = cached == nil
    for _, player in ipairs(overviewPlayers or self:GetOverviewPlayers()) do
        local row = Copy(player)
        row.stale = not player.isSelf and (not result.connected or not player.online
            or player.xpStale == true or player.statusSynchronized == false)
        row.xpStale = row.stale
        if player.isSelf then result.own = row end
        if not player.online then result.inactive = result.inactive + 1 end
        if not Complete(player) then result.awaiting = result.awaiting + 1
        else
            result.players[#result.players + 1] = row
            ranked[row.id] = row
            if not cached or not SameProgress(row, cached.progress[row.id]) then changed = true end
            if row.stale then result.stale = result.stale + 1 end
        end
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
    for _, player in ipairs(ranking.players) do players[player.id] = player end
    if ranking.own then players[ranking.own.id] = ranking.own end
    self.rankingTooltipCache = { at = now, players = players }
    return players
end

for _, notification in ipairs({ "GROUP_CHANGED", "ROSTER_CHANGED", "DATA_CHANGED" }) do
    addon:RegisterNotification(notification, function() addon.rankingTooltipCache = nil end)
end
