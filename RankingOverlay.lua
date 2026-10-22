local _, addon = ...
local UI = addon.Theme
local WIDTH, ROW_WIDTH, ROW_HEIGHT = 326, 302, 34
local HEADER_HEIGHT, METER_HEIGHT = 34, 44
local ROW_TOP = HEADER_HEIGHT + METER_HEIGHT
local VISIBLE_ROWS = 5
local BURNED_STEP = 10
local BURNING_THRESHOLD, BURNING_FRAME_TIME = 70, 1 / 30
local XP_BAR_WIDTH, XP_ANIMATION_TIME, XP_GAIN_TIME = 174, 0.3, 0.65
local ROW_ANIMATION_TIME, OWN_SEPARATOR_HEIGHT = 0.7, 24
local GLOW_TEXTURE = "Interface\\AddOns\\LockInTools\\Media\\BurningGlow.tga"
local FLAME_TEXTURE = "Interface\\AddOns\\LockInTools\\Media\\BurningFlame.tga"
local FinishRowMotion

local function HideTooltip(widget)
    if GameTooltip and GameTooltip:IsOwned(widget) then GameTooltip:Hide() end
end

local function HideTooltips(panel)
    for _, widget in ipairs(panel.tooltipOwners or {}) do HideTooltip(widget) end
end

local function RefreshBackground(panel)
    local transparency = addon:GetRankingSettings().backgroundTransparency
    if panel.backgroundTransparency == transparency then return end
    -- Fade only window decoration: parent alpha would also fade text and meters.
    local alpha = 1 - transparency / 100
    panel.background:SetAlpha(alpha)
    for _, border in ipairs(panel.borders) do border:SetAlpha(alpha) end
    panel.stripe:SetAlpha(alpha)
    panel.backgroundTransparency = transparency
end

local function Percentage(xp, maximum)
    local tenths = math.floor(xp * 1000 / maximum)
    return string.format("%.1f", tenths / 10):gsub("%.0$", "") .. "%"
end

local function PlayerTooltip(row)
    if row.motionInteractive == false then HideTooltip(row); return end
    local player = row.player
    if not player then return end
    if not player.isSelf then
        local position = addon:GetSharedPositions()[player.id]
        if position or addon.db.position.keepLastKnown == false then
            local current = {}
            for key, value in pairs(player) do current[key] = value end
            current.map, current.x, current.y = position and position.map, position and position.x, position and position.y
            current.positionStamp = position and position.positionStamp
            current.positionAvailable = position and position.positionAvailable
            player = current
        end
    end
    -- Use native anchoring on hover and live refresh so global tooltip hooks apply.
    addon:ShowCompactPlayerTooltip(row, { { player = player } })
end

local function RefreshPositionTooltips()
    local panel = addon.rankingOverlay
    if not panel or not panel:IsVisible() or not GameTooltip or not GameTooltip:IsShown() then return end
    for _, row in ipairs(panel.rows) do
        if GameTooltip:IsOwned(row) then PlayerTooltip(row); return end
    end
    if GameTooltip:IsOwned(panel.ownRow) then PlayerTooltip(panel.ownRow) end
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
        if button ~= "LeftButton" or not IsShiftKeyDown() or widget.motionInteractive == false then return end
        FinishRowMotion(panel)
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

local function HideXPGain(row)
    row.progressGain:Hide()
    row.progressGlow:Hide()
end

local function PaintXPProgress(row, progress)
    local width = XP_BAR_WIDTH * progress.display
    if width > 0 then
        row.progressFill:SetWidth(width)
        row.progressFill:Show()
    else row.progressFill:Hide() end
    if not progress.flashElapsed then HideXPGain(row); return end

    -- Give subpixel gains a small halo; this does not change the actual fill.
    local start = math.min(XP_BAR_WIDTH - 3, XP_BAR_WIDTH * progress.flashFrom)
    local gained = math.min(XP_BAR_WIDTH - start, math.max(3, width - start))
    local alpha = math.min(0.7, (1 - progress.flashElapsed / XP_GAIN_TIME) * 0.95)
    row.progressGain:ClearAllPoints()
    row.progressGain:SetPoint("TOPLEFT", row.progressTrack, "TOPLEFT", start, 1)
    row.progressGain:SetWidth(gained)
    row.progressGain:SetAlpha(alpha)
    row.progressGain:Show()
    row.progressGlow:ClearAllPoints()
    row.progressGlow:SetPoint("TOPLEFT", row.progressTrack, "TOPLEFT", start - 4, 3)
    row.progressGlow:SetSize(gained + 8, 9)
    row.progressGlow:SetAlpha(alpha * 0.55)
    row.progressGlow:Show()
end

local function AnimateXPProgress(animator, elapsed)
    local active = false
    -- Presentation only: at most six visible players, with no standings refresh,
    -- data requests, timers or region allocation in this frame callback.
    for id, progress in pairs(animator.panel.xpProgress) do
        local row = progress.row
        if row and row.playerID == id and row:IsVisible() and (progress.elapsed or progress.flashElapsed) then
            if progress.elapsed then
                progress.elapsed = progress.elapsed + elapsed
                local fraction = math.min(1, progress.elapsed / XP_ANIMATION_TIME)
                progress.display = progress.from + (progress.target - progress.from) * (1 - (1 - fraction) ^ 3)
                if fraction == 1 then
                    progress.display, progress.elapsed, progress.from = progress.target, nil, nil
                end
            end
            if progress.flashElapsed then
                progress.flashElapsed = progress.flashElapsed + elapsed
                if progress.flashElapsed >= XP_GAIN_TIME then progress.flashElapsed, progress.flashFrom = nil, nil end
            end
            PaintXPProgress(row, progress)
            if progress.elapsed or progress.flashElapsed then active = true end
        end
    end
    if not active then animator:SetScript("OnUpdate", nil) end
end

local function ResetXPProgress(panel)
    panel.xpAnimator:SetScript("OnUpdate", nil)
    panel.xpProgress = {}
    for _, row in ipairs(panel.rows) do HideXPGain(row) end
    HideXPGain(panel.ownRow)
end

local function RefreshXPProgress(row, player, fraction, known)
    local panel = row.panel
    local progress = panel.xpProgress[player.id]
    local stale = player.stale == true
    if not progress then
        progress = { display = fraction, target = fraction }
        panel.xpProgress[player.id] = progress
    end
    if not panel:IsVisible() or not known or not progress.known or stale or progress.stale
        or player.level ~= progress.level or player.xpMax ~= progress.xpMax or fraction < progress.target then
        progress.display, progress.target = fraction, fraction
        progress.elapsed, progress.from, progress.flashElapsed, progress.flashFrom = nil, nil, nil, nil
    elseif fraction > progress.target then
        -- Continue from the currently painted width, including when another XP
        -- report arrives mid-animation. Identical repaints keep the old timing.
        progress.from, progress.target, progress.elapsed = progress.display, fraction, 0
        progress.flashFrom, progress.flashElapsed = progress.display, 0
    end
    progress.row, progress.level, progress.xpMax = row, player.level, player.xpMax
    progress.known, progress.stale = known, stale
    PaintXPProgress(row, progress)
end

local function RefreshXPAnimator(panel)
    local active = false
    -- Bind every pooled row before pruning: a player may have moved between a
    -- leader row and the separate own row while its animation was in flight.
    for id, progress in pairs(panel.xpProgress) do
        if not progress.row then panel.xpProgress[id] = nil
        elseif progress.elapsed or progress.flashElapsed then active = true end
    end
    panel.xpAnimator:SetScript("OnUpdate", panel:IsVisible() and active and AnimateXPProgress or nil)
end

local function PaintRowMotion(panel, motion)
    local row = motion.row
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", panel.rowContent, "TOPLEFT", 0, -motion.display)
    row:SetAlpha((row.baseAlpha or 1) * motion.alpha)
    -- Fading entrants have no visible target yet. Existing moving buttons keep
    -- their hit area attached to the player; decorative copies stay inert.
    row.motionInteractive = not row.isGhost and motion.alpha == 1
    row:EnableMouse(row.motionInteractive)
    local rising = motion.elapsed and motion.target < motion.from and not motion.leaving
    if rising then
        if motion.player.isSelf then row.motionBacking:SetColorTexture(0.094, 0.19, 0.29, 1)
        else row.motionBacking:SetColorTexture(0.063, 0.106, 0.153, 1) end
        row.motionBacking:Show()
    else row.motionBacking:Hide() end
    -- Stable layers keep a crossing player's name/bar together and above the
    -- displaced rows. Ghosts never cover live buttons or accept mouse input.
    local layer = motion.leaving and 1 or rising and (motion.player.isSelf and 4 or 3) or 2
    local level = panel.rowContent:GetFrameLevel() + layer
    if row:GetFrameLevel() ~= level then row:SetFrameLevel(level) end
end

local function PaintRowLayout(panel)
    local height = panel.rowLayout.display
    panel.rowViewport:SetHeight(math.max(1, height))
    panel.personalBurned:ClearAllPoints()
    panel.personalBurned:SetPoint("TOPLEFT", 12, -ROW_TOP - height - 25)
    panel:SetHeight(ROW_TOP + height + METER_HEIGHT + 8)
end

local function FitRankingPanel(panel)
    local height = panel:GetHeight()
    -- Fit the larger layout once, rather than zooming the whole overlay while
    -- the own-row space opens/closes. Screen changes may still refit mid-motion.
    if panel.rowScaleHeight then panel:SetHeight(math.max(height, panel.rowScaleHeight)) end
    UI:Fit(panel)
    panel:SetHeight(height)
end

local function ReleaseRowGhost(row)
    row:Hide()
    row.playerID, row.player = nil, nil
end

local function ResetRowMotion(panel)
    panel.rowAnimator:SetScript("OnUpdate", nil)
    for _, motion in pairs(panel.rowMotion) do
        if not motion.leaving then
            motion.display, motion.alpha, motion.elapsed = motion.target, 1, nil
            PaintRowMotion(panel, motion)
        end
    end
    for _, ghost in ipairs(panel.rowGhosts) do ReleaseRowGhost(ghost) end
    panel.rowMotion, panel.rowLayout, panel.rowScaleHeight, panel.rowMotionReady = {}, nil, nil, false
end

local function SetMotionTarget(motion, target, alpha, animate)
    if not animate then
        motion.display, motion.target, motion.alpha, motion.targetAlpha = target, target, alpha, alpha
        motion.elapsed = nil
    elseif motion.target ~= target or motion.targetAlpha ~= alpha then
        motion.from, motion.target, motion.elapsed = motion.display, target, 0
        motion.fromAlpha, motion.targetAlpha = motion.alpha, alpha
    end
end

local function BindRowMotion(panel, row, player, target, animate)
    row.layoutY = target
    local motion = panel.rowMotion[player.id]
    if not motion then
        motion = { display = target + (animate and 12 or 0), alpha = animate and 0 or 1 }
        panel.rowMotion[player.id] = motion
    elseif motion.leaving then
        -- A peer can return before its outgoing fade finishes. Transfer the
        -- visible position and opacity back into its live row without a clone.
        ReleaseRowGhost(motion.row)
        motion.leaving = nil
    end
    if animate and motion.target ~= target then ClearRowInteractions(row) end
    motion.row, motion.player, motion.seen = row, player, true
    SetMotionTarget(motion, target, 1, animate)
    PaintRowMotion(panel, motion)
end

local function AdvanceRowMotion(motion, elapsed)
    motion.elapsed = motion.elapsed + elapsed
    local fraction = math.min(1, motion.elapsed / ROW_ANIMATION_TIME)
    local eased = 1 - (1 - fraction) ^ 3
    motion.display = motion.from + (motion.target - motion.from) * eased
    motion.alpha = motion.fromAlpha + (motion.targetAlpha - motion.fromAlpha) * eased
    if fraction == 1 then motion.display, motion.alpha, motion.elapsed = motion.target, motion.targetAlpha, nil end
end

local function AnimateRankingRows(animator, elapsed)
    local panel, active = animator.panel, false
    -- Only position/opacity/layout work for the fixed live and ghost pools;
    -- rankings, XP snapshots, networking and region creation stay event-driven.
    for id, motion in pairs(panel.rowMotion) do
        if motion.elapsed then
            AdvanceRowMotion(motion, elapsed)
            if motion.leaving and not motion.elapsed then
                ReleaseRowGhost(motion.row)
                panel.rowMotion[id] = nil
            else
                PaintRowMotion(panel, motion)
                if motion.elapsed then active = true end
            end
        end
    end
    if panel.rowLayout.elapsed then
        AdvanceRowMotion(panel.rowLayout, elapsed)
        PaintRowLayout(panel)
        if panel.rowLayout.elapsed then active = true end
    end
    if not active then
        animator:SetScript("OnUpdate", nil)
        panel.rowScaleHeight = nil
        FitRankingPanel(panel)
    end
end

FinishRowMotion = function(panel)
    for id, motion in pairs(panel.rowMotion) do
        if motion.leaving then
            ReleaseRowGhost(motion.row)
            panel.rowMotion[id] = nil
        else
            motion.display, motion.alpha, motion.elapsed = motion.target, 1, nil
            PaintRowMotion(panel, motion)
        end
    end
    if panel.rowLayout then
        panel.rowLayout.display, panel.rowLayout.elapsed = panel.rowLayout.target, nil
        PaintRowLayout(panel)
    end
    panel.rowAnimator:SetScript("OnUpdate", nil)
    panel.rowScaleHeight = nil
    FitRankingPanel(panel)
end

local function RefreshRowAnimator(panel)
    local active = panel.rowLayout.elapsed ~= nil
    for _, motion in pairs(panel.rowMotion) do
        if motion.elapsed then active = true; break end
    end
    panel.rowAnimator:SetScript("OnUpdate", panel:IsVisible() and active and AnimateRankingRows or nil)
    if not active then panel.rowScaleHeight = nil end
    FitRankingPanel(panel)
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

local function CanEditBurned()
    return addon.initialized and addon.ready and not addon.savedDataReadOnly
        and addon:GetBurnedStatusCooldown() == 0
end

local function CancelBurnedEdit(meter)
    meter.editingBurned, meter.pendingBurned = nil, nil
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
    local cooldown = addon:GetBurnedStatusCooldown()
    local editable = CanEditBurned()
    if not editable then CancelBurnedEdit(personal) end
    local value = personal.pendingBurned or addon:GetBurnedStatus()
    -- Native SetValue also fires OnValueChanged during a data refresh.
    personal.refreshing = true
    personal:SetValue(value)
    personal.refreshing = nil
    personal:SetEnabled(editable)
    personal:SetAlpha(editable and 1 or 0.65)
    local suffix = ""
    if cooldown > 0 then
        suffix = " (ready in " .. string.format("%d:%02d", math.floor(cooldown / 60), cooldown % 60) .. ")"
    elseif personal.editingBurned then suffix = " (release to set)" end
    PaintMeter(personal, value, "Your burned status: " .. value .. "%" .. suffix)
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
            -- Native track clicks can report a value before OnMouseDown. Stage
            -- all input and commit only on release so a drag locks its final
            -- value, rather than the first 10% tick it crosses.
            if CanEditBurned() and meter:IsVisible() then
                meter.pendingBurned = math.max(0, math.min(100, math.floor(value / BURNED_STEP + 0.5) * BURNED_STEP))
                meter.editingBurned = true
            else CancelBurnedEdit(meter) end
            addon:RefreshRankingOverlay()
        end)
        meter:SetScript("OnMouseDown", function(_, button)
            if button ~= "LeftButton" or not CanEditBurned() or not meter:IsVisible() then return end
            meter.pendingBurned = meter.pendingBurned or addon:GetBurnedStatus()
            meter.editingBurned = true
            addon:RefreshRankingOverlay()
        end)
        meter:SetScript("OnMouseUp", function(_, button)
            if button ~= "LeftButton" then return end
            local value = meter.pendingBurned
            CancelBurnedEdit(meter)
            if value ~= nil and CanEditBurned() and meter:IsVisible() and value ~= addon:GetBurnedStatus() then
                local success, message = addon:SetBurnedStatus(value)
                if not success and message then addon:Print(message) end
            end
            addon:RefreshRankingOverlay()
        end)
        meter:HookScript("OnHide", CancelBurnedEdit)
    end
    return meter
end

local function CreateRow(panel, ghost)
    local row = CreateFrame("Button", nil, panel.rowContent)
    row.panel = panel
    row.isGhost = ghost == true
    row:SetSize(ROW_WIDTH, ROW_HEIGHT)
    if not ghost then
        MakeDraggable(panel, row)
        row:RegisterForClicks("RightButtonUp")
        panel.tooltipOwners[#panel.tooltipOwners + 1] = row
        row:SetScript("OnEnter", PlayerTooltip)
        row:SetScript("OnLeave", HideTooltip)
        row:SetScript("OnHide", function()
            ClearRowInteractions(row)
            HideXPGain(row)
        end)
        row:SetScript("OnClick", function(_, button)
            if button ~= "RightButton" or not row.playerID or row.motionInteractive == false then return end
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
    else
        row:EnableMouse(false)
        row:SetScript("OnHide", HideXPGain)
    end
    row.motionBacking = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    row.motionBacking:SetAllPoints(row)
    row.motionBacking:Hide()
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
    row.progressTrack:SetSize(XP_BAR_WIDTH, 3)
    row.progressFill = row:CreateTexture(nil, "ARTWORK")
    row.progressFill:SetPoint("TOPLEFT", row.progressTrack, "TOPLEFT")
    row.progressFill:SetHeight(3)
    row.progressGlow = row:CreateTexture(nil, "ARTWORK", nil, 1)
    row.progressGlow:SetTexture(GLOW_TEXTURE)
    row.progressGlow:SetVertexColor(0.44, 0.74, 1)
    row.progressGlow:SetBlendMode("ADD")
    row.progressGain = row:CreateTexture(nil, "ARTWORK", nil, 2)
    row.progressGain:SetColorTexture(0.69, 0.86, 1, 1)
    row.progressGain:SetHeight(5)
    row:Hide()
    return row
end

local function PaintRow(row, player)
    -- A pooled row must never keep a tooltip or menu for its previous character.
    local playerID = player and player.id or nil
    if not row.isGhost and row.playerID ~= playerID then ClearRowInteractions(row) end
    row.playerID = playerID
    row.player = player
    if not player then
        row.baseAlpha = 1
        row:SetAlpha(1)
        row.rank:SetText("")
        row.name:SetText("")
        row.level:SetText("")
        row.progress:SetText("")
        row.progressTrack:Hide()
        row.progressFill:Hide()
        row.highlight:Hide()
        row.motionBacking:Hide()
        row:Hide()
        return
    end

    local red, green, blue = UI:GetAccentColor()
    local rank = player.rank
    local stale = player.stale == true
    row.baseAlpha = stale and 0.65 or 1
    row:SetAlpha(row.baseAlpha)
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
    HideXPGain(row)
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
        if row.isGhost then PaintXPProgress(row, { display = row.frozenXP or fraction })
        else RefreshXPProgress(row, player, fraction, known) end
    else
        if not row.isGhost then row.panel.xpProgress[playerID] = nil end
        local font, _, flags = row.level:GetFont()
        row.progress:SetFont(font, 10, flags)
        row.progress:SetHeight(12)
        row.progress:SetPoint("TOPLEFT", 30, -21)
        row.progress:SetWidth(230)
        row.progress:SetJustifyH("LEFT")
        row.progress:SetText("Waiting for XP")
    end
    row:Show()
    if not row.isGhost and GameTooltip and GameTooltip:IsOwned(row) and GameTooltip:IsShown() then PlayerTooltip(row) end
end

local function RetireRankingRows(panel, animate)
    for id, motion in pairs(panel.rowMotion) do
        if not motion.seen then
            if not animate then
                if motion.leaving then ReleaseRowGhost(motion.row) end
                panel.rowMotion[id] = nil
            elseif not motion.leaving then
                local ghost
                for _, candidate in ipairs(panel.rowGhosts) do
                    if not candidate.playerID then ghost = candidate; break end
                end
                if not ghost then
                    -- Repeated full replacements cannot grow the pool. Drop an
                    -- old decorative fade, cycling so a single refresh does not
                    -- repeatedly evict the outgoing rows it just created.
                    panel.rowGhostCursor = (panel.rowGhostCursor or 0) % #panel.rowGhosts + 1
                    ghost = panel.rowGhosts[panel.rowGhostCursor]
                    panel.rowMotion[ghost.playerID] = nil
                    ReleaseRowGhost(ghost)
                end
                local progress = panel.xpProgress[id]
                ghost.frozenXP = progress and progress.display or nil
                PaintRow(ghost, motion.player)
                motion.row, motion.leaving = ghost, true
                SetMotionTarget(motion, math.max(panel.rowLayout.display, panel.rowLayout.target) + 8, 0, true)
                PaintRowMotion(panel, motion)
            end
        end
    end
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
    panel.xpProgress = {}
    panel.xpAnimator = CreateFrame("Frame", nil, panel)
    panel.xpAnimator.panel = panel
    panel.xpAnimator:EnableMouse(false)
    panel.rowMotion, panel.rowGhosts = {}, {}
    panel.rowAnimator = CreateFrame("Frame", nil, panel)
    panel.rowAnimator.panel = panel
    panel.rowAnimator:EnableMouse(false)
    panel.rowViewport = CreateFrame("ScrollFrame", nil, panel)
    panel.rowViewport:SetPoint("TOPLEFT", 12, -ROW_TOP)
    panel.rowViewport:SetSize(ROW_WIDTH, 1)
    panel.rowViewport:EnableMouse(false)
    panel.rowContent = CreateFrame("Frame", nil, panel.rowViewport)
    panel.rowContent:SetPoint("TOPLEFT", panel.rowViewport, "TOPLEFT", 0, 0)
    panel.rowContent:SetSize(ROW_WIDTH, (VISIBLE_ROWS + 2) * ROW_HEIGHT + OWN_SEPARATOR_HEIGHT)
    panel.rowContent:EnableMouse(false)
    panel.rowViewport:SetScrollChild(panel.rowContent)
    panel.rowViewport:SetVerticalScroll(0)
    panel.tooltipOwners = {}
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
        row:SetPoint("TOPLEFT", panel.rowContent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
        panel.rows[index] = row
    end
    panel.ownRow = CreateRow(panel)
    for index = 1, VISIBLE_ROWS + 1 do panel.rowGhosts[index] = CreateRow(panel, true) end
    panel.separator = Label(panel.rowContent, "Your position", 0, 0, ROW_WIDTH, 10, "muted")
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
        ResetRowMotion(panel)
        ResetXPProgress(panel)
        Activate(panel)
        addon:RefreshRankingOverlay()
    end)
    panel:SetScript("OnHide", function()
        HideTooltips(panel)
        if panel.actionMenu then panel.actionMenu:Hide() end
        panel:SetScript("OnUpdate", nil)
        ResetRowMotion(panel)
        ResetXPProgress(panel)
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
    local animate = panel:IsVisible() and panel.rowMotionReady and not panel.moving
    for _, motion in pairs(panel.rowMotion) do motion.seen = false end
    for _, progress in pairs(panel.xpProgress) do progress.row = nil end
    RefreshBackground(panel)
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

    panel.empty:SetPoint("TOPLEFT", 12, -ROW_TOP - 4)

    local count, ownVisible = 0, false
    for index, row in ipairs(panel.rows) do
        local player = players[index]
        PaintRow(row, player)
        if player then
            BindRowMotion(panel, row, player, (index - 1) * ROW_HEIGHT, animate)
            count = count + 1
            if own and (player.isSelf or player.id == own.id) then ownVisible = true end
        end
    end
    local bottom = count * ROW_HEIGHT
    local showOwn = hasStandings and own and not ownVisible
    if showOwn then
        if count > 0 then
            panel.separator:ClearAllPoints()
            panel.separator:SetPoint("TOPLEFT", 0, -bottom - 4)
            panel.separator:Show()
            bottom = bottom + OWN_SEPARATOR_HEIGHT
        else panel.separator:Hide() end
        PaintRow(panel.ownRow, own)
        BindRowMotion(panel, panel.ownRow, own, bottom, animate)
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
    if not panel.rowLayout then panel.rowLayout = { display = bottom, target = bottom, alpha = 1, targetAlpha = 1 } end
    SetMotionTarget(panel.rowLayout, bottom, 1, animate)
    if animate then panel.rowScaleHeight = math.max(panel.rowScaleHeight or panel:GetHeight(), ROW_TOP + bottom + METER_HEIGHT + 8) end
    RetireRankingRows(panel, animate)
    PaintRowLayout(panel)
    RefreshBurnedMeters(panel)
    panel:Show()
    panel.rowMotionReady = panel:IsVisible()
    RefreshRowAnimator(panel)
    RefreshXPAnimator(panel)
    if panel.actionMenu and panel.actionMenu:IsShown() then panel.actionMenu:Refresh() end
end

function addon:OnRankingLogin()
    self:RefreshRankingOverlay()
end

addon:RegisterNotification("GROUP_CHANGED", function()
    if addon.rankingOverlay then
        ResetRowMotion(addon.rankingOverlay)
        ResetXPProgress(addon.rankingOverlay)
    end
    addon:RefreshRankingOverlay()
end)

for _, notification in ipairs({ "ROSTER_CHANGED", "DATA_CHANGED", "RANKING_CHANGED" }) do
    addon:RegisterNotification(notification, function() addon:RefreshRankingOverlay() end)
end

-- Coordinates change tooltips, not XP standings or row layout. The visible
-- one-second tick still refreshes contact expiry and the local player's map.
for _, notification in ipairs({ "POSITIONS_CHANGED", "POSITION_CONTACT_CHANGED" }) do
    addon:RegisterNotification(notification, RefreshPositionTooltips)
end

addon:RegisterNotification("BURNED_CHANGED", function()
    local panel = addon.rankingOverlay
    if panel and panel:IsVisible() then RefreshBurnedMeters(panel) end
end)

addon:RegisterGameEvents({ "PLAYER_LOGOUT", "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED" }, function(self, event)
    if event == "PLAYER_LOGOUT" then self:SaveRankingPosition()
    elseif self.rankingOverlay and self.rankingOverlay:IsVisible() then
        HideTooltips(self.rankingOverlay)
        if self.rankingOverlay.actionMenu then self.rankingOverlay.actionMenu:Hide() end
        FitRankingPanel(self.rankingOverlay)
    end
end)
