local _, addon = ...
local UI = addon.Theme
local WIDTH, ROW_WIDTH, ROW_HEIGHT, ROW_TOP = 326, 302, 34, 34
local VISIBLE_ROWS = 5

local function HideTooltip(widget)
    if GameTooltip and GameTooltip:IsOwned(widget) then GameTooltip:Hide() end
end

local function HideTooltips(panel)
    for _, widget in ipairs(panel.tooltipOwners or {}) do HideTooltip(widget) end
end

local function Tooltip(panel, widget, title, description)
    panel.tooltipOwners = panel.tooltipOwners or {}
    panel.tooltipOwners[#panel.tooltipOwners + 1] = widget
    if widget.SetMotionScriptsWhileDisabled then widget:SetMotionScriptsWhileDisabled(true) end
    local function Show()
        if not GameTooltip then return end
        GameTooltip:SetOwner(widget, "ANCHOR_RIGHT")
        GameTooltip:SetText(type(title) == "function" and title() or title)
        GameTooltip:AddLine(type(description) == "function" and description() or description, 1, 1, 1, true)
        GameTooltip:Show()
    end
    widget:HookScript("OnEnter", Show)
    widget:HookScript("OnLeave", function() HideTooltip(widget) end)
    widget:HookScript("OnHide", function() HideTooltip(widget) end)
    return Show
end

local function Age(stamp)
    if type(stamp) ~= "number" then return "age unknown" end
    local seconds = math.max(0, math.floor(GetServerTime() - stamp))
    if seconds < 60 then return seconds .. "s ago" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m ago" end
    if seconds < 86400 then return math.floor(seconds / 3600) .. "h ago" end
    return math.floor(seconds / 86400) .. "d ago"
end

local function Percentage(xp, maximum, roundUp)
    local tenths = xp * 1000 / maximum
    tenths = roundUp and math.ceil(tenths) or math.floor(tenths)
    return string.format("%.1f", tenths / 10):gsub("%.0$", "") .. "%"
end

local function LocationName(player)
    -- Cached coordinates stay private when either side has stopped sharing.
    if not addon.db.position or not addon.db.position.sharing then return "Position sharing is off" end
    if player.sharing == false then return "Not sharing" end
    if not player.map then return "Unknown location" end
    if C_Map and type(C_Map.GetMapInfo) == "function" then
        local ok, info = pcall(C_Map.GetMapInfo, player.map)
        if ok and type(info) == "table" and type(info.name) == "string" then return info.name end
    end
    return "Map " .. tostring(player.map)
end

local function PlayerTooltip(row)
    local player = row.player
    if not player or not GameTooltip then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetText("#" .. (player.rank or "?") .. " - " .. addon:GetPlayerDisplayName(player.name))
    if player.xpState ~= "max" then
        local progress = "Awaiting XP"
        if player.level and player.xpState == "known" and type(player.xp) == "number"
            and type(player.xpMax) == "number" and player.xpMax > 0 then
            local missing = math.max(0, player.xpMax - player.xp)
            -- Round missing progress up so a pending level never reads as 0% needed.
            progress = Percentage(missing, player.xpMax, true) .. " (" .. missing .. " XP)"
        end
        GameTooltip:AddLine("Lv " .. (player.level or "?") .. " - " .. progress)
    end
    local location = LocationName(player)
    if not player.online and not player.isSelf then location = location .. " - " .. Age(player.seenAt) end
    GameTooltip:AddLine(location)
    GameTooltip:Show()
end

local function ClearRowInteractions(row)
    HideTooltip(row)
    local panel = row.panel
    -- Refresh can recycle a dragged row before its drag-stop event arrives.
    if panel.dragHandle == row then addon:SaveRankingPosition() end
    local menu = panel.actionMenu
    if menu and menu.anchor == row then menu:Hide() end
end

local function MakeDraggable(panel, widget)
    widget:EnableMouse(true)
    widget:RegisterForDrag("LeftButton")
    widget:SetScript("OnDragStart", function(_, button)
        -- Shift replaces the old saved lock preference, including on existing profiles.
        if button ~= "LeftButton" or not IsShiftKeyDown() then return end
        HideTooltips(panel)
        if panel.actionMenu then panel.actionMenu:Hide() end
        panel.moving = true
        panel.dragHandle = widget
        panel:StartMoving()
    end)
    widget:SetScript("OnDragStop", function()
        if panel.moving then addon:SaveRankingPosition() end
    end)
end

local function Label(parent, text, x, y, width, size, role)
    local label = UI:Label(parent, text, size or 12, role)
    label:SetPoint("TOPLEFT", x, -y)
    label:SetSize(width, 16)
    if label.SetWordWrap then label:SetWordWrap(false) end
    return label
end

local function CreateRow(panel)
    local row = CreateFrame("Button", nil, panel)
    row.panel = panel
    row:SetSize(ROW_WIDTH, ROW_HEIGHT)
    MakeDraggable(panel, row)
    row:RegisterForClicks("RightButtonUp")
    panel.tooltipOwners[#panel.tooltipOwners + 1] = row
    row:SetScript("OnEnter", PlayerTooltip)
    row:SetScript("OnLeave", HideTooltip)
    row:SetScript("OnHide", ClearRowInteractions)
    row:SetScript("OnClick", function(_, button)
        if button ~= "RightButton" or not row.playerID then return end
        HideTooltips(panel)
        if not row.player or row.player.isSelf then
            if panel.actionMenu then panel.actionMenu:Hide() end
            return
        end
        if not panel.actionMenu then
            panel.actionMenu = addon:CreatePlayerActionMenu(panel, "LockInToolsRankingActions", function(_, message)
                if message then addon:Print(message) end
                addon:RefreshRankingOverlay()
            end)
        end
        panel.actionMenu:Open(row.playerID, row)
    end)
    row.highlight = row:CreateTexture(nil, "BACKGROUND")
    row.highlight:SetAllPoints(row)
    row.rank = Label(row, "", 5, 6, 24, 12, "muted")
    row.name = Label(row, "", 30, 5, 218, 12)
    row.level = Label(row, "", 260, 6, 36, 13)
    row.level:SetJustifyH("RIGHT")
    row.progress = Label(row, "", 210, 21, 50, 10, "muted")
    row.progress:SetJustifyH("RIGHT")
    row.progress:SetHeight(12)
    row.progressTrack = row:CreateTexture(nil, "BACKGROUND")
    row.progressTrack:SetPoint("TOPLEFT", 30, -26)
    row.progressTrack:SetSize(174, 3)
    row.progressFill = row:CreateTexture(nil, "ARTWORK")
    row.progressFill:SetPoint("TOPLEFT", row.progressTrack, "TOPLEFT")
    row.progressFill:SetHeight(3)
    row:Hide()
    return row
end

local function PaintRow(row, player)
    -- A pooled row must never keep a tooltip or menu for its previous character.
    local playerID = player and player.id or nil
    if row.playerID ~= playerID then ClearRowInteractions(row) end
    row.playerID = playerID
    row.player = player
    if not player then
        row:SetAlpha(1)
        row.rank:SetText("")
        row.name:SetText("")
        row.level:SetText("")
        row.progress:SetText("")
        row.progressTrack:Hide()
        row.progressFill:Hide()
        row.highlight:Hide()
        row:Hide()
        return
    end

    local red, green, blue = UI:GetAccentColor()
    local rank = player.rank
    local stale = player.stale == true
    row:SetAlpha(stale and 0.65 or 1)
    row.rank:SetText(rank and tostring(rank) or "—")
    row.name:SetText(addon:GetPlayerDisplayName(player.name))
    row.level:SetText(player.level and tostring(player.level) or "—")
    row.highlight:SetColorTexture(red, green, blue, 0.14)
    if player.isSelf then
        row.highlight:Show()
        row.rank:SetTextColor(red, green, blue)
        row.name:SetTextColor(0.84, 0.92, 1)
    else
        row.highlight:Hide()
        if rank == 1 then row.rank:SetTextColor(0.91, 0.76, 0.54)
        else row.rank:SetTextColor(0.60, 0.67, 0.76) end
        row.name:SetTextColor(0.91, 0.94, 0.98)
    end

    row.progress:ClearAllPoints()
    row.progressTrack:Hide()
    row.progressFill:Hide()
    local known = player.level and player.xpState == "known" and type(player.xp) == "number"
        and type(player.xpMax) == "number" and player.xpMax > 0
    local maximum = player.level and player.xpState == "max"
    if known or maximum then
        local fraction = maximum and 1 or math.max(0, math.min(1, player.xp / player.xpMax))
        row.progress:SetPoint("TOPLEFT", 210, -21)
        row.progress:SetWidth(50)
        row.progress:SetJustifyH("RIGHT")
        row.progress:SetText((stale and "~" or "") .. (maximum and "MAX" or Percentage(player.xp, player.xpMax)))
        if not player.isSelf then
            if maximum then red, green, blue = 0.68, 0.61, 0.45
            else red, green, blue = 0.40, 0.51, 0.61 end
        end
        row.progressTrack:SetColorTexture(red * 0.35, green * 0.35, blue * 0.35, 0.8)
        row.progressFill:SetColorTexture(red, green, blue, 1)
        row.progressTrack:Show()
        if fraction > 0 then
            row.progressFill:SetWidth(174 * fraction)
            row.progressFill:Show()
        end
    else
        row.progress:SetPoint("TOPLEFT", 30, -21)
        row.progress:SetWidth(230)
        row.progress:SetJustifyH("LEFT")
        row.progress:SetText("Waiting for XP")
    end
    row:Show()
    if GameTooltip and GameTooltip:IsOwned(row) and GameTooltip:IsShown() then PlayerTooltip(row) end
end

function addon:SaveRankingPosition()
    local panel = self.rankingOverlay
    if not panel then return end
    panel:StopMovingOrSizing()
    panel.moving = false
    panel.dragHandle = nil
    panel:SetUserPlaced(false)
    local point, relativeTo, relativePoint, x, y = panel:GetPoint()
    if relativeTo and relativeTo ~= UIParent then return end
    local position = { point = point, relativePoint = relativePoint, x = x, y = y }
    panel.runtimePosition = position
    return self:SetRankingPosition(position)
end

local function Activate(panel)
    if not panel:IsVisible() then return end
    panel.elapsed = 0
    panel:SetScript("OnUpdate", function(_, elapsed)
        panel.elapsed = panel.elapsed + elapsed
        if panel.elapsed >= 1 then
            panel.elapsed = panel.elapsed % 1
            addon:RefreshRankingOverlay()
        end
    end)
end

local function CreateOverlay()
    local panel = UI:Window("LockInToolsRankingOverlay", WIDTH, 180)
    addon.rankingOverlay = panel
    panel:SetFrameStrata("MEDIUM")
    panel:EnableMouse(false)
    panel:RegisterForDrag()
    panel:SetScript("OnDragStart", nil)
    panel:SetScript("OnDragStop", nil)
    panel:SetUserPlaced(false)
    panel.TitleIcon:Hide()
    panel.TitleText:ClearAllPoints()
    panel.TitleText:SetPoint("TOPLEFT", 12, -13)
    panel.TitleText:SetSize(270, 18)
    local font, _, flags = panel.TitleText:GetFont()
    panel.TitleText:SetFont(font, 14, flags)
    panel.TitleText:SetText("Player Rankings (XP)")
    panel.CloseButton:ClearAllPoints()
    panel.CloseButton:SetPoint("TOPRIGHT", -6, -7)
    panel.CloseButton:SetSize(24, 24)
    panel.CloseButton:SetScript("OnClick", function()
        if addon.savedDataReadOnly then
            addon.rankingOverlayDismissed = true
            addon:Notify("RANKING_CHANGED")
        else addon:SetRankingEnabled(false) end
    end)
    Tooltip(panel, panel.CloseButton, "Hide ranking", function()
        if addon.savedDataReadOnly then return "Hide the overlay for this session. Use /lit ranking to reopen it." end
        return "Hide this overlay. Reopen it from Settings > Ranking or /lit ranking."
    end)

    panel.header = CreateFrame("Frame", nil, panel)
    panel.header:SetPoint("TOPLEFT", 1, -1)
    panel.header:SetSize(WIDTH - 38, ROW_TOP - 1)
    MakeDraggable(panel, panel.header)
    panel.rows = {}
    for index = 1, VISIBLE_ROWS do
        local row = CreateRow(panel)
        row:SetPoint("TOPLEFT", 12, -ROW_TOP - (index - 1) * ROW_HEIGHT)
        panel.rows[index] = row
    end
    panel.ownRow = CreateRow(panel)
    panel.separator = Label(panel, "Your position", 12, ROW_TOP, ROW_WIDTH, 10, "muted")
    panel.separator:SetJustifyH("CENTER")
    panel.separator:Hide()
    panel.empty = Label(panel, "", 12, ROW_TOP + 4, ROW_WIDTH, 11, "muted")
    panel.empty:SetHeight(36)
    if panel.empty.SetWordWrap then panel.empty:SetWordWrap(true) end

    local position = addon:GetRankingSettings().position
    panel:ClearAllPoints()
    if position then
        panel:SetPoint(position.point, UIParent, position.relativePoint, position.x, position.y)
    else panel:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -40, -180) end
    panel:SetScript("OnShow", function()
        Activate(panel)
        addon:RefreshRankingOverlay()
    end)
    panel:SetScript("OnHide", function()
        HideTooltips(panel)
        if panel.actionMenu then panel.actionMenu:Hide() end
        panel:SetScript("OnUpdate", nil)
        if panel.moving then addon:SaveRankingPosition() end
    end)
    return panel
end

function addon:RefreshRankingOverlay()
    local panel = self.rankingOverlay
    if not self.initialized or not self.ready or not self:GetRankingSettings().enabled
        or self.rankingOverlayDismissed then
        if panel then panel:Hide() end
        return
    end
    if not panel then panel = CreateOverlay() end
    local ranking = self:GetPlayerRanking()

    local hasStandings = ranking.grouped and not ranking.switching
    local players, own = hasStandings and ranking.players or {}, ranking.own
    if ranking.switching then
        panel.empty:SetText("Switching groups... Waiting for the new group.")
        own = nil
    elseif not ranking.grouped then
        panel.empty:SetText("Choose a group in Settings > Group. Your group standings will appear here.")
        own = nil
    else
        panel.empty:SetText("Waiting for usable player progress.")
    end

    local rowTop = ROW_TOP
    panel.empty:SetPoint("TOPLEFT", 12, -rowTop - 4)

    local count, ownVisible = 0, false
    for index, row in ipairs(panel.rows) do
        local offset = rowTop + (index - 1) * ROW_HEIGHT
        if row.layoutY and row.layoutY ~= offset then ClearRowInteractions(row) end
        row.layoutY = offset
        row:SetPoint("TOPLEFT", 12, -offset)
        local player = players[index]
        PaintRow(row, player)
        if player then
            count = count + 1
            if own and (player.isSelf or player.id == own.id) then ownVisible = true end
        end
    end
    local bottom = rowTop + count * ROW_HEIGHT
    local showOwn = hasStandings and own and not ownVisible
    if showOwn then
        if count > 0 then
            panel.separator:ClearAllPoints()
            panel.separator:SetPoint("TOPLEFT", 12, -bottom - 4)
            panel.separator:Show()
            bottom = bottom + 24
        else panel.separator:Hide() end
        panel.ownRow:ClearAllPoints()
        if panel.ownRow.layoutY and panel.ownRow.layoutY ~= bottom then ClearRowInteractions(panel.ownRow) end
        panel.ownRow.layoutY = bottom
        panel.ownRow:SetPoint("TOPLEFT", 12, -bottom)
        PaintRow(panel.ownRow, own)
        bottom = bottom + ROW_HEIGHT
    else
        panel.separator:Hide()
        PaintRow(panel.ownRow, nil)
    end
    local hasRows = count > 0 or showOwn
    if hasRows then panel.empty:Hide()
    else
        panel.empty:Show()
        bottom = bottom + ROW_HEIGHT
    end
    panel:SetHeight(bottom + 12)
    UI:Fit(panel)
    panel:Show()
    if panel.actionMenu and panel.actionMenu:IsShown() then panel.actionMenu:Refresh() end
end

function addon:OnRankingLogin()
    self:RefreshRankingOverlay()
end

for _, notification in ipairs({ "GROUP_CHANGED", "ROSTER_CHANGED", "DATA_CHANGED", "RANKING_CHANGED",
    "POSITIONS_CHANGED", "POSITION_CONTACT_CHANGED" }) do
    addon:RegisterNotification(notification, function() addon:RefreshRankingOverlay() end)
end

addon:RegisterGameEvents({ "PLAYER_LOGOUT", "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED" }, function(self, event)
    if event == "PLAYER_LOGOUT" then self:SaveRankingPosition()
    elseif self.rankingOverlay and self.rankingOverlay:IsVisible() then
        HideTooltips(self.rankingOverlay)
        if self.rankingOverlay.actionMenu then self.rankingOverlay.actionMenu:Hide() end
        UI:Fit(self.rankingOverlay)
    end
end)
