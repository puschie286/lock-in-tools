local _, addon = ...
local UI = addon.Theme
local WIDTH, ROW_WIDTH, ROW_HEIGHT = 326, 302, 34
local HEADER_HEIGHT, METER_HEIGHT = 34, 44
local ROW_TOP = HEADER_HEIGHT + METER_HEIGHT
local VISIBLE_ROWS = 5
local BURNED_STEP = 10
local BURNING_THRESHOLD, BURNING_FRAME_TIME = 70, 1 / 30
local GLOW_TEXTURE = "Interface\\AddOns\\LockInTools\\Media\\BurningGlow.tga"
local FLAME_TEXTURE = "Interface\\AddOns\\LockInTools\\Media\\BurningFlame.tga"

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
        GameTooltip_SetDefaultAnchor(GameTooltip, widget)
        GameTooltip:SetText(type(title) == "function" and title() or title)
        GameTooltip:AddLine(type(description) == "function" and description() or description, 1, 1, 1, true)
        GameTooltip:Show()
    end
    widget:HookScript("OnEnter", Show)
    widget:HookScript("OnLeave", function() HideTooltip(widget) end)
    widget:HookScript("OnHide", function() HideTooltip(widget) end)
    return Show
end

local function Percentage(xp, maximum)
    local tenths = math.floor(xp * 1000 / maximum)
    return string.format("%.1f", tenths / 10):gsub("%.0$", "") .. "%"
end

local function PlayerTooltip(row)
    local player = row.player
    if not player then return end
    -- Use native anchoring on hover and live refresh so global tooltip hooks apply.
    addon:ShowCompactPlayerTooltip(row, { { player = player } })
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

local function StopBurningEffect(meter)
    local effect = meter.burningEffect
    if not effect then return end
    effect:SetScript("OnUpdate", nil)
    effect.elapsed = 0
    for _, texture in ipairs(effect.textures) do texture:Hide() end
    effect:Hide()
end

local function PaintBurningEffect(effect)
    local pulse = 0.89 - 0.11 * math.cos(effect.phase * math.pi * 2 / 1.8)
    local strength = effect.strength * pulse
    effect.glow:SetAlpha(0.9 * strength)
    effect.innerGlow:SetAlpha(0.8 * strength)
    effect.edgeGlow:SetAlpha(strength)
    effect.edge:SetAlpha(0.85 + 0.15 * pulse)
    for index, flame in ipairs(effect.flames) do
        local wave = (math.sin(effect.phase * (4.5 + index % 5) + index * 1.7) + 1) / 2
        flame:SetHeight((5 + ((index - 1) * 7 % 6)) * (0.65 + 0.35 * wave))
        flame:SetAlpha((0.8 + 0.2 * wave) * strength)
    end
end

local function AnimateBurningEffect(effect, elapsed)
    effect.elapsed = effect.elapsed + elapsed
    if effect.elapsed < BURNING_FRAME_TIME then return end
    -- Keep animation work bounded after a long frame. This never polls player
    -- data, allocates textures, or drives the group's status scheduler.
    effect.phase = (effect.phase + math.min(effect.elapsed, 0.1)) % (math.pi * 40)
    effect.elapsed = 0
    PaintBurningEffect(effect)
end

local function CreateBurningEffect(meter)
    local effect = CreateFrame("Frame", nil, meter)
    effect:SetAllPoints(meter)
    effect:EnableMouse(false)
    effect:Hide()
    effect.textures, effect.bands, effect.flames = {}, {}, {}
    effect.elapsed, effect.phase = 0, 0
    -- Own regions on the meter so its OVERLAY labels/thumb/ticks always remain
    -- above the fire. The child frame only runs the visible animation driver.
    local function Texture(layer, sublevel, path, red, green, blue)
        local texture = meter:CreateTexture(nil, layer, nil, sublevel)
        if path then
            texture:SetTexture(path)
            texture:SetVertexColor(red, green, blue)
            texture:SetBlendMode("ADD")
        else texture:SetColorTexture(red, green, blue, 1) end
        effect.textures[#effect.textures + 1] = texture
        return texture
    end
    effect.glow = Texture("ARTWORK", -2, GLOW_TEXTURE, 1, 0.25, 0.015)
    effect.innerGlow = Texture("ARTWORK", -1, GLOW_TEXTURE, 1, 0.55, 0.06)
    for index, color in ipairs({ { 1, 0.69, 0.12 }, { 1, 0.94, 0.60 }, { 1, 0.75, 0.18 },
        { 1, 0.54, 0.04 }, { 1, 0.34, 0.02 }, { 0.82, 0.18, 0.02 } }) do
        local band = Texture("ARTWORK", 1, nil, unpack(color))
        band:SetPoint("TOPLEFT", meter, "TOPLEFT", 0, -(index - 1) * 2)
        band:SetHeight(2)
        effect.bands[index] = band
    end
    for index = 1, 18 do
        local flame = Texture("ARTWORK", 2, FLAME_TEXTURE, 1, 0.82, 0.35)
        flame:SetWidth(12)
        effect.flames[index] = flame
    end
    effect.edgeGlow = Texture("ARTWORK", 2, GLOW_TEXTURE, 1, 0.48, 0.06)
    effect.edge = Texture("ARTWORK", 3, nil, 1, 0.96, 0.70)
    effect.edge:SetSize(2, 12)
    effect:SetScript("OnHide", function()
        effect:SetScript("OnUpdate", nil)
        effect.elapsed = 0
        for _, texture in ipairs(effect.textures) do texture:Hide() end
    end)
    effect:SetScript("OnShow", function()
        if effect:IsVisible() then effect:SetScript("OnUpdate", AnimateBurningEffect) end
    end)
    meter.burningEffect = effect
    return effect
end

local function RefreshBurningEffect(meter, value)
    if not UIParent:IsVisible() or not addon:GetRankingSettings().burningEffect
        or not value or value < BURNING_THRESHOLD then
        StopBurningEffect(meter)
        return
    end
    local effect = meter.burningEffect or CreateBurningEffect(meter)
    local width = ROW_WIDTH * value / 100
    effect.strength = 0.72 + 0.28 * (value - BURNING_THRESHOLD) / (100 - BURNING_THRESHOLD)
    effect.glow:ClearAllPoints()
    effect.glow:SetPoint("TOPLEFT", meter, "TOPLEFT", -12, 7)
    effect.glow:SetSize(width + 24, 26)
    effect.innerGlow:ClearAllPoints()
    effect.innerGlow:SetPoint("TOPLEFT", meter, "TOPLEFT", -6, 3)
    effect.innerGlow:SetSize(width + 12, 18)
    for _, band in ipairs(effect.bands) do band:SetWidth(width) end
    for index, flame in ipairs(effect.flames) do
        flame:ClearAllPoints()
        flame:SetPoint("BOTTOMLEFT", meter, "TOPLEFT", (index - 1) * (width - 12) / 17, -5)
    end
    effect.edgeGlow:ClearAllPoints()
    effect.edgeGlow:SetPoint("TOPLEFT", meter, "TOPLEFT", width - 10, 5)
    effect.edgeGlow:SetSize(20, 22)
    effect.edge:ClearAllPoints()
    effect.edge:SetPoint("TOPLEFT", meter, "TOPLEFT", width - 2, 0)
    PaintBurningEffect(effect)
    for _, texture in ipairs(effect.textures) do texture:Show() end
    effect:Show()
    if effect:IsVisible() then effect:SetScript("OnUpdate", AnimateBurningEffect) end
end

local function PaintMeter(meter, value, text)
    meter.value = value
    meter.label:SetText(text)
    if value and value > 0 then
        local fraction = value / 100
        meter.fill:SetColorTexture(0.30 + 0.65 * fraction, 0.75 - 0.40 * fraction, 0.30, 1)
        meter.fill:SetWidth(ROW_WIDTH * fraction)
        meter.fill:Show()
    else meter.fill:Hide() end
    RefreshBurningEffect(meter, value)
end

local function RefreshBurnedMeters(panel)
    local group = addon:GetGroupBurnedStatus()
    local text = "Group burned: "
    if group.average ~= nil then
        text = text .. string.format("%.0f%%", group.average) .. " (" .. group.count .. " reporting)"
    elseif addon:IsGroupSwitching() then text = text .. "switching groups"
    elseif not addon:HasGroup() then text = text .. "no group"
    elseif not addon:IsDataConnected() then text = text .. "disconnected"
    else text = text .. "awaiting reports" end
    PaintMeter(panel.groupBurned, group.average, text)

    local personal = panel.personalBurned
    local value = addon:GetBurnedStatus()
    -- Native SetValue also fires OnValueChanged during a data refresh.
    personal.refreshing = true
    personal:SetValue(value)
    personal.refreshing = nil
    personal:SetEnabled(not addon.savedDataReadOnly)
    personal:SetAlpha(addon.savedDataReadOnly and 0.5 or 1)
    PaintMeter(personal, value, "Your burned status: " .. value .. "%")
end

local function CreateBurnedMeter(panel, personal)
    local meter = CreateFrame(personal and "Slider" or "Frame", nil, panel)
    meter:SetSize(ROW_WIDTH, 12)
    meter:EnableMouse(true)
    meter.label = UI:Label(meter, "", 11, "muted")
    meter.label:SetPoint("BOTTOMLEFT", meter, "TOPLEFT", 0, 5)
    meter.label:SetSize(ROW_WIDTH, 16)
    if meter.label.SetWordWrap then meter.label:SetWordWrap(false) end
    meter.track = meter:CreateTexture(nil, "BACKGROUND")
    meter.track:SetAllPoints(meter)
    meter.track:SetColorTexture(0.12, 0.16, 0.20, 1)
    meter.fill = meter:CreateTexture(nil, "ARTWORK")
    meter.fill:SetPoint("TOPLEFT", meter, "TOPLEFT")
    meter.fill:SetHeight(12)
    if personal then
        meter:SetOrientation("HORIZONTAL")
        meter:SetMinMaxValues(0, 100)
        meter:SetValueStep(BURNED_STEP)
        meter.ticks = {}
        for index = 0, 100 / BURNED_STEP do
            local tick = meter:CreateTexture(nil, "OVERLAY")
            tick:SetColorTexture(0.60, 0.67, 0.76, 0.7)
            tick:SetSize(1, 3)
            tick:SetPoint("TOPLEFT", meter, "BOTTOMLEFT", (ROW_WIDTH - 1) * index * BURNED_STEP / 100, -2)
            meter.ticks[index] = tick
        end
        local thumb = meter:CreateTexture(nil, "OVERLAY")
        thumb:SetColorTexture(0.91, 0.94, 0.98, 1)
        thumb:SetSize(5, 18)
        meter:SetThumbTexture(thumb)
        meter:SetScript("OnValueChanged", function(_, value)
            if meter.refreshing then return end
            if not addon.savedDataReadOnly and addon.initialized and addon.ready then
                -- Snap user edits only; old saved reports and group averages
                -- retain their precision when the overlay simply repaints.
                value = math.max(0, math.min(100, math.floor(value / BURNED_STEP + 0.5) * BURNED_STEP))
                if value ~= addon:GetBurnedStatus() then
                    local success, message = addon:SetBurnedStatus(value)
                    if not success and message then addon:Print(message) end
                end
            end
            addon:RefreshRankingOverlay()
        end)
        Tooltip(panel, meter, "Your burned status", function()
            if addon.savedDataReadOnly then return "Update LockInTools before changing your saved burned status." end
            return "Drag in 10% steps to set how burned you feel: 0% is fresh, 100% is fully burned. "
                .. "Your status is saved and shared with your LockInTools group."
        end)
    else
        Tooltip(panel, meter, "Group burned status", "Average burned status of connected group members "
            .. "with current reports, including you. Members without a current report are left out. "
            .. "0% is fresh; 100% is fully burned.")
    end
    return meter
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
    row.name = Label(row, "", 30, 5, 164, 12)
    row.level = Label(row, "", 260, 6, 36, 13)
    row.level:SetJustifyH("RIGHT")
    row.progress = Label(row, "", 202, 6, 50, 13, "muted")
    row.progress:SetJustifyH("RIGHT")
    row.progress:SetHeight(16)
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
        -- Match the level's text height and font so both values share a baseline.
        row.progress:SetPoint("RIGHT", row.level, "LEFT", -8, 0)
        row.progress:SetFont(row.level:GetFont())
        row.progress:SetHeight(16)
        row.progress:SetWidth(50)
        row.progress:SetJustifyH("RIGHT")
        row.progress:SetText(maximum and "MAX" or Percentage(player.xp, player.xpMax))
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
        local font, _, flags = row.level:GetFont()
        row.progress:SetFont(font, 10, flags)
        row.progress:SetHeight(12)
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

    panel.header = CreateFrame("Button", nil, panel)
    panel.header:SetPoint("TOPLEFT", 1, -1)
    panel.header:SetSize(WIDTH - 38, HEADER_HEIGHT - 1)
    MakeDraggable(panel, panel.header)
    panel.header:RegisterForClicks("LeftButtonUp")
    panel.header:SetScript("OnDoubleClick", function(_, button)
        -- Keep double-click navigation separate from Shift-drag movement.
        if button ~= "LeftButton" or IsShiftKeyDown() or panel.moving then return end
        HideTooltips(panel)
        if panel.actionMenu then panel.actionMenu:Hide() end
        addon:OpenOverview()
    end)
    panel.groupBurned = CreateBurnedMeter(panel, false)
    panel.groupBurned:SetPoint("TOPLEFT", 12, -HEADER_HEIGHT - 23)
    panel.personalBurned = CreateBurnedMeter(panel, true)
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
        StopBurningEffect(panel.groupBurned)
        StopBurningEffect(panel.personalBurned)
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
    panel.personalBurned:ClearAllPoints()
    panel.personalBurned:SetPoint("TOPLEFT", 12, -bottom - 25)
    RefreshBurnedMeters(panel)
    panel:SetHeight(bottom + METER_HEIGHT + 8)
    UI:Fit(panel)
    panel:Show()
    if panel.actionMenu and panel.actionMenu:IsShown() then panel.actionMenu:Refresh() end
end

function addon:OnRankingLogin()
    self:RefreshRankingOverlay()
end

for _, notification in ipairs({ "GROUP_CHANGED", "ROSTER_CHANGED", "DATA_CHANGED", "RANKING_CHANGED",
    "POSITIONS_CHANGED", "POSITION_CONTACT_CHANGED", "BURNED_CHANGED" }) do
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
