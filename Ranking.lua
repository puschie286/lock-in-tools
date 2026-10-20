local _, addon = ...

local POINTS = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
    RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true }

local function Number(value, maximum)
    return not (issecretvalue and issecretvalue(value)) and type(value) == "number"
        and value == value and value >= 0 and value <= maximum and value == math.floor(value)
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
        .. "Stale / ~: last saved progress, which may have changed; these values still count in the ranking.\n"
        .. "Awaiting XP: no usable level and XP report yet (new discovery, older saved data or a level-up). "
        .. "These characters have no rank until progress is available.\n"
        .. "Hover a player for exact XP and location; right-click for Invite or Request to join."
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

function addon:GetPlayerRanking()
    local result = { players = {}, awaiting = 0, stale = 0, inactive = 0,
        connected = false, grouped = false, switching = false }
    if not self.initialized or not self.ready then return result end
    result.grouped, result.switching = self:HasGroup(), self:IsGroupSwitching()
    result.connected = self:IsDataConnected()
    if not result.grouped or result.switching then return result end
    for _, player in ipairs(self:GetOverviewPlayers()) do
        local row = Copy(player)
        row.stale = not player.isSelf and (not result.connected or not player.online
            or player.xpStale == true or player.statusSynchronized == false)
        row.xpStale = row.stale
        if player.isSelf then result.own = row end
        if not player.online then result.inactive = result.inactive + 1 end
        if not Complete(player) then result.awaiting = result.awaiting + 1
        else
            result.players[#result.players + 1] = row
            if row.stale then result.stale = result.stale + 1 end
        end
    end
    table.sort(result.players, function(left, right)
        local order = CompareProgress(left, right)
        if order ~= 0 then return order > 0 end
        return left.id < right.id
    end)
    local rank = 0
    for index, player in ipairs(result.players) do
        if index == 1 or CompareProgress(player, result.players[index - 1]) ~= 0 then rank = index end
        player.rank = rank
    end
    return result
end
