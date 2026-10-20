local _, addon = ...
local UI = addon.Theme
local WIDTH, ROW_WIDTH, ROW_HEIGHT, ROW_TOP = 326, 302, 42, 82
local VISIBLE_ROWS = 5

local function Label(parent, text, x, y, width, size, role)
    local label = UI:Label(parent, text, size or 12, role)
    label:SetPoint("TOPLEFT", x, -y)
    label:SetSize(width, 16)
    if label.SetWordWrap then label:SetWordWrap(false) end
    return label
end

local function CreateRow(panel)
    local row = CreateFrame("Frame", nil, panel)
    row:SetSize(ROW_WIDTH, ROW_HEIGHT)
    row:EnableMouse(false)
    row.highlight = row:CreateTexture(nil, "BACKGROUND")
    row.highlight:SetAllPoints(row)
    row.rank = Label(row, "", 5, 6, 24, 12, "muted")
    row.name = Label(row, "", 30, 5, 218, 12)
    row.level = Label(row, "", 260, 6, 36, 13)
    row.level:SetJustifyH("RIGHT")
    row.progress = Label(row, "", 210, 23, 50, 10, "muted")
    row.progress:SetJustifyH("RIGHT")
    row.progressTrack = row:CreateTexture(nil, "BACKGROUND")
    row.progressTrack:SetPoint("TOPLEFT", 30, -30)
    row.progressTrack:SetSize(174, 3)
    row.progressFill = row:CreateTexture(nil, "ARTWORK")
    row.progressFill:SetPoint("TOPLEFT", row.progressTrack, "TOPLEFT")
    row.progressFill:SetHeight(3)
    row:Hide()
    return row
end

local function PaintRow(row, player)
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
    row.name:SetText(player.name .. (player.isSelf and " (you)" or "") .. (stale and " (stale)" or ""))
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
        local tenths = maximum and 1000 or math.floor(player.xp * 1000 / player.xpMax)
        local percentage = string.format("%.1f", tenths / 10):gsub("%.0$", "")
        row.progress:SetPoint("TOPLEFT", 210, -23)
        row.progress:SetWidth(50)
        row.progress:SetJustifyH("RIGHT")
        row.progress:SetText((stale and "~" or "") .. (maximum and "MAX" or percentage .. "%"))
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
        row.progress:SetPoint("TOPLEFT", 30, -23)
        row.progress:SetWidth(230)
        row.progress:SetJustifyH("LEFT")
        row.progress:SetText("Waiting for XP")
    end
    row:Show()
end

function addon:SaveRankingPosition()
    local panel = self.rankingOverlay
    if not panel then return end
    panel:StopMovingOrSizing()
    panel.moving = false
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
    panel.TitleText:SetSize(168, 18)
    local font, _, flags = panel.TitleText:GetFont()
    panel.TitleText:SetFont(font, 14, flags)
    panel.TitleText:SetText("Player ranking")
    panel.CloseButton:ClearAllPoints()
    panel.CloseButton:SetPoint("TOPRIGHT", -6, -7)
    panel.CloseButton:SetSize(24, 24)
    panel.CloseButton:SetScript("OnClick", function()
        if addon.savedDataReadOnly then
            addon.rankingOverlayDismissed = true
            addon:Notify("RANKING_CHANGED")
        else addon:SetRankingEnabled(false) end
    end)

    panel.header = CreateFrame("Frame", nil, panel)
    panel.header:SetPoint("TOPLEFT", 1, -1)
    panel.header:SetSize(180, 34)
    panel.header:RegisterForDrag("LeftButton")
    panel.header:SetScript("OnDragStart", function()
        if addon:GetRankingSettings().locked then return end
        panel.moving = true
        panel:StartMoving()
    end)
    panel.header:SetScript("OnDragStop", function() addon:SaveRankingPosition() end)
    panel.lock = UI:Button(panel, "Unlock")
    panel.lock:SetPoint("TOPRIGHT", -36, -8)
    panel.lock:SetSize(60, 23)
    panel.lock:SetScript("OnClick", function()
        addon:SetRankingLocked(not addon:GetRankingSettings().locked)
    end)
    panel.help = UI:Button(panel, "Info")
    panel.help:SetPoint("TOPRIGHT", -102, -8)
    panel.help:SetSize(36, 23)
    local function ShowHelp(button)
        if not GameTooltip then return end
        GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
        GameTooltip:SetText("Ranking values")
        GameTooltip:AddLine(addon:GetRankingHelpText(), 1, 1, 1, true)
        GameTooltip:Show()
    end
    local function HideHelp(button)
        if GameTooltip and GameTooltip:IsOwned(button) then GameTooltip:Hide() end
    end
    panel.help:HookScript("OnEnter", ShowHelp)
    panel.help:HookScript("OnLeave", HideHelp)
    panel.help:HookScript("OnHide", HideHelp)
    panel.help:SetScript("OnClick", ShowHelp)
    panel.subtitle = Label(panel, "", 12, 38, ROW_WIDTH, 10, "muted")
    panel.subtitle:SetHeight(24)
    if panel.subtitle.SetWordWrap then panel.subtitle:SetWordWrap(true) end
    Label(panel, "#", 17, 65, 24, 10, "muted")
    Label(panel, "Player · XP progress", 42, 65, 218, 10, "muted")
    local level = Label(panel, "Level", 272, 65, 36, 10, "muted")
    level:SetJustifyH("RIGHT")
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
    panel.summary = Label(panel, "", 12, 130, ROW_WIDTH, 10, "muted")
    panel.summary:SetHeight(32)

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
    local settings, ranking = self:GetRankingSettings(), self:GetPlayerRanking()
    panel.header:EnableMouse(not settings.locked)
    panel.lock:SetText(settings.locked and "Unlock" or "Lock")
    panel.lock:SetEnabled(not self.savedDataReadOnly)
    if settings.locked and panel.moving then self:SaveRankingPosition() end

    local hasStandings = ranking.grouped and not ranking.switching
    local players, own = hasStandings and ranking.players or {}, ranking.own
    if ranking.switching then
        panel.subtitle:SetText("Switching groups...")
        panel.empty:SetText("Waiting for the new group.")
        own = nil
    elseif not ranking.grouped then
        panel.subtitle:SetText("Choose a group in Settings > Group")
        panel.empty:SetText("Your group standings will appear here.")
        own = nil
    elseif not ranking.connected then
        panel.subtitle:SetText("Connection lost — showing last reports")
        panel.empty:SetText("Waiting for usable player progress.")
    else
        panel.subtitle:SetText("Last reported standings")
        panel.empty:SetText("Waiting for usable player progress.")
    end

    local count, ownVisible = 0, false
    for index, row in ipairs(panel.rows) do
        local player = players[index]
        PaintRow(row, player)
        if player then
            count = count + 1
            if own and (player.isSelf or player.id == own.id) then ownVisible = true end
        end
    end
    local bottom = ROW_TOP + math.max(1, count) * ROW_HEIGHT
    if hasStandings and own and not ownVisible then
        panel.separator:ClearAllPoints()
        panel.separator:SetPoint("TOPLEFT", 12, -bottom - 4)
        panel.separator:Show()
        panel.ownRow:ClearAllPoints()
        panel.ownRow:SetPoint("TOPLEFT", 12, -bottom - 24)
        PaintRow(panel.ownRow, own)
        bottom = bottom + 24 + ROW_HEIGHT
    else
        panel.separator:Hide()
        PaintRow(panel.ownRow, nil)
    end
    if count == 0 then panel.empty:Show() else panel.empty:Hide() end
    if hasStandings then
        panel.summary:SetText(#players .. " ranked · " .. (ranking.stale or 0) .. " stale\n"
            .. (ranking.awaiting or 0) .. " awaiting XP")
    else panel.summary:SetText("") end
    panel.summary:ClearAllPoints()
    panel.summary:SetPoint("TOPLEFT", 12, -bottom - 10)
    panel:SetHeight(bottom + 52)
    UI:Fit(panel)
    panel:Show()
end

function addon:OnRankingLogin()
    self:RefreshRankingOverlay()
end

for _, notification in ipairs({ "GROUP_CHANGED", "ROSTER_CHANGED", "DATA_CHANGED", "RANKING_CHANGED" }) do
    addon:RegisterNotification(notification, function() addon:RefreshRankingOverlay() end)
end

addon:RegisterGameEvents({ "PLAYER_LOGOUT", "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED" }, function(self, event)
    if event == "PLAYER_LOGOUT" then self:SaveRankingPosition()
    elseif self.rankingOverlay and self.rankingOverlay:IsVisible() then UI:Fit(self.rankingOverlay) end
end)
