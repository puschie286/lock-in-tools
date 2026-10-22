-- This offline suite is never loaded by the addon.
local fixture = dofile("tests/support/addon.lua")
local loadAddon, settings = fixture.loadAddon, fixture.settings
local SECRET, OTHER_SECRET, contains = fixture.SECRET, fixture.OTHER_SECRET, fixture.contains
local loadOptions = dofile("tests/support/ui.lua")

local function loadOverlay(addon, environment)
    loadOptions(addon, environment)
    if addon.RefreshRankingOverlay then return end
    local chunk, problem
    if setfenv then
        chunk, problem = loadfile("RankingOverlay.lua")
        assert(chunk, problem)
        setfenv(chunk, environment)
    else
        chunk, problem = loadfile("RankingOverlay.lua", "t", environment)
        assert(chunk, problem)
    end
    chunk("LockInTools", addon)
end

local function placed(window, parent, point, relativePoint, x, y)
    local anchor, relativeTo, relativeAnchor, actualX, actualY = window:GetPoint()
    return anchor == point and relativeTo == parent and relativeAnchor == relativePoint
        and actualX == x and actualY == y
end

local function row(id, rank, level, xp, maximum, isSelf)
    return { id = id, name = id, rank = rank, level = level, xp = xp, xpMax = maximum,
        xpState = xp and "known" or "max", online = true, isSelf = isSelf }
end

-- Visibility is independent of the main window and dismissal survives subsequent data events.
do
    local saved = settings(SECRET, false)
    local ranking, api, messages, _, world = loadAddon(saved, false)
    world:initialize()
    loadOverlay(ranking, api)
    local command = api.SlashCmdList.LOCKINTOOLS
    ranking:RefreshRankingOverlay()
    assert(not ranking.rankingOverlay and not ranking.mainPanel and not ranking:GetRankingSettings().enabled,
        "ranking starts disabled without constructing either window")
    command("ranking")
    local panel = ranking.rankingOverlay
    assert(panel and panel:IsVisible() and saved.ranking.enabled and not ranking.mainPanel,
        "the ranking command opens its own lazy overlay without opening Content")
    local tooltip = api.GameTooltip
    command("options")
    local main = ranking.mainPanel
    assert(main:IsVisible() and panel:IsVisible(), "Settings and ranking can be visible independently")
    command("ranking")
    assert(not panel:IsShown() and not panel.scripts.OnUpdate and main:IsVisible() and not saved.ranking.enabled,
        "toggling ranking off saves its preference without closing Settings")
    command("ranking")
    assert(ranking.rankingOverlay == panel and panel:IsVisible() and main:IsVisible(),
        "reopening ranking reuses its window and leaves Settings visible")
    main.CloseButton:Click()
    assert(panel:IsVisible(), "closing the main window leaves the overlay visible")
    panel.CloseButton.scripts.OnEnter(panel.CloseButton)
    assert(not tooltip:IsShown(), "hovering the overlay close button shows no tooltip")
    panel.CloseButton:Click()
    assert(not panel:IsShown() and not saved.ranking.enabled and not panel.scripts.OnUpdate and not tooltip:IsShown(),
        "the overlay close button saves disabled and stops refresh work")
    ranking:Notify("ROSTER_CHANGED")
    ranking:Notify("DATA_CHANGED")
    ranking:Notify("GROUP_CHANGED")
    ranking:Notify("BURNED_CHANGED")
    ranking:RefreshRankingOverlay()
    assert(not panel:IsShown() and not panel.scripts.OnUpdate,
        "status, connection and group events cannot reopen a dismissed overlay")
    command("ranking on")
    assert(panel:IsVisible() and saved.ranking.enabled and panel.header.mouseEnabled,
        "the explicit on command immediately shows ranking with its Shift-drag header available")
    command("ranking off")
    assert(not saved.ranking.enabled and not panel:IsShown(), "the explicit off command hides and persists ranking")
    assert(not contains(messages, SECRET) and not contains(messages, OTHER_SECRET),
        "ranking visibility never logs group keys")
end

-- Transparency fades window decoration independently of foreground content and other windows.
do
    local saved = settings(SECRET, false)
    saved.ranking = { enabled = false, backgroundTransparency = 50 }
    local ranking, api, _, _, world = loadAddon(saved, false)
    world:initialize()
    loadOverlay(ranking, api)
    local peer, own = row("Peer", 1, 30, 500, 1000), row("Self", 2, 25, 400, 1000, true)
    peer.stale = true
    ranking.GetPlayerRanking = function()
        return { grouped = true, connected = true, players = { peer, own }, own = own }
    end
    ranking.GetGroupBurnedStatus = function() return { average = 45, count = 2 } end
    assert(not ranking.rankingOverlay, "a saved transparency preference does not create a disabled overlay")
    assert(ranking:SetRankingEnabled(true))
    ranking:OpenOptions("ranking")
    local panel, main = ranking.rankingOverlay, ranking.mainPanel
    local slider = ranking.optionsPanel.rankingTransparencySlider
    local first, second = panel.rows[1], panel.rows[2]
    local function decorationAlpha(alpha)
        assert(panel.background.alpha == alpha and panel.stripe.alpha == alpha,
            "window backing and accent use the selected transparency")
        for _, border in ipairs(panel.borders) do
            assert(border.alpha == alpha, "window borders use the selected transparency")
        end
    end
    local function opaque(widget) return (widget.alpha or 1) == 1 end
    local function foregroundVisible()
        assert(opaque(panel) and opaque(panel.TitleText) and opaque(panel.CloseButton)
            and opaque(first.name) and opaque(first.progressFill) and opaque(first.highlight)
            and first.alpha == 0.65 and second.alpha == 1 and first.name:GetText() == "Peer"
            and opaque(panel.groupBurned) and opaque(panel.groupBurned.label)
            and opaque(panel.groupBurned.track) and opaque(panel.groupBurned.fill)
            and opaque(panel.personalBurned) and opaque(panel.personalBurned.track)
            and opaque(panel.personalBurned.thumbTexture) and opaque(panel.personalBurned.ticks[0])
            and opaque(main.background) and opaque(main.stripe),
            "transparency preserves readable names, stale dimming, meters, controls and the main window")
    end
    decorationAlpha(0.5)
    foregroundVisible()
    local statusSends, rosterSends, dataSends = #world.statusSends, #world.rosterSends, #world.dataSends
    for _, value in ipairs({ 100, 0, 50, 100 }) do
        slider:SetValue(value)
        decorationAlpha(1 - value / 100)
        foregroundVisible()
        assert(saved.ranking.backgroundTransparency == value and panel:IsVisible()
            and ranking.rankingOverlay == panel and panel.rows[1] == first and panel.rows[2] == second
            and #world.statusSends == statusSends and #world.rosterSends == rosterSends
            and #world.dataSends == dataSends,
            "dragging updates the existing overlay immediately without changing group traffic")
    end
    panel.CloseButton:Click()
    slider:SetValue(40)
    assert(not panel:IsShown() and not saved.ranking.enabled,
        "editing transparency leaves a dismissed overlay hidden")
    assert(ranking:SetRankingEnabled(true))
    decorationAlpha(0.6)
    slider:SetValue(100)
    local restored, restoredAPI, _, _, restoredWorld = loadAddon(saved, false)
    restoredWorld:initialize()
    loadOverlay(restored, restoredAPI)
    restored:RefreshRankingOverlay()
    local restoredPanel = restored.rankingOverlay
    assert(restoredPanel:IsVisible() and restoredPanel.background.alpha == 0
        and restoredPanel.stripe.alpha == 0 and opaque(restoredPanel.TitleText),
        "a fully transparent overlay restores its saved account-wide preference")
    assert(restored:SetRankingBackgroundTransparency(0))
    assert(restoredPanel.background.alpha == 1 and restoredPanel.stripe.alpha == 1,
        "returning from full transparency restores the existing window backing immediately")
end

-- Header double-click navigation stays separate from ordinary clicks and Shift movement.
do
    local saved = settings(SECRET, false)
    local ranking, api, _, _, world = loadAddon(saved, false)
    local shiftDown = false
    api.IsShiftKeyDown = function() return shiftDown end
    world:initialize()
    loadOverlay(ranking, api)
    assert(ranking:SetRankingEnabled(true))
    local panel = ranking.rankingOverlay
    local header = panel.header
    assert(header.frameType == "Button" and #header.clicks == 1 and header.clicks[1] == "LeftButtonUp",
        "the title uses a native button to receive left double clicks")
    header:Click()
    header.scripts.OnDoubleClick(header, "RightButton")
    assert(not ranking.mainPanel, "single clicks and right double clicks leave the main window closed")
    shiftDown = true
    header.scripts.OnDoubleClick(header, "LeftButton")
    assert(not ranking.mainPanel, "Shift double clicks do not open Overview")
    header.scripts.OnDragStart(header, "LeftButton")
    shiftDown = false
    header.scripts.OnDoubleClick(header, "LeftButton")
    assert(panel.moving and not ranking.mainPanel,
        "releasing Shift during an active drag does not turn it into Overview navigation")
    header.scripts.OnDragStop(header)
    local position = saved.ranking.position
    panel.rows[1].scripts.OnEnter(panel.rows[1])
    assert(api.GameTooltip:IsShown(), "a player tooltip is visible before Overview navigation")
    header.scripts.OnDoubleClick(header, "LeftButton")
    local main, content = ranking.mainPanel, ranking.contentPanel
    assert(main:IsVisible() and content:IsVisible() and content.selectedTab == "overview"
        and panel:IsVisible() and saved.ranking.enabled and saved.ranking.position == position
        and not api.GameTooltip:IsShown(),
        "double clicking the title opens Overview and clears overlay help while preserving the overlay")
    main.CloseButton:Click()
    header.scripts.OnDoubleClick(header, "LeftButton")
    assert(ranking.mainPanel == main and ranking.contentPanel == content and content:IsVisible(),
        "a later double click reopens the existing Overview window")
    ranking:OpenOptions("ranking")
    header.scripts.OnDoubleClick(header, "LeftButton")
    header.scripts.OnDoubleClick(header, "LeftButton")
    assert(content:IsVisible() and not ranking.optionsPanel:IsVisible() and panel:IsVisible(),
        "double clicks return from Settings to Overview and keep an already open Overview visible")
end

-- Burned meters distinguish an unknown average from zero; repainting never sends edits.
do
    local ranking, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    loadOverlay(ranking, api)
    local personalValue, groupState, edits = 20, { average = 45, count = 2 }, {}
    ranking.GetBurnedStatus = function() return personalValue end
    ranking.GetGroupBurnedStatus = function() return groupState end
    ranking.SetBurnedStatus = function(self, value)
        edits[#edits + 1] = value
        personalValue = value
        self:Notify("BURNED_CHANGED")
        return true
    end
    assert(ranking:SetRankingEnabled(true))
    local panel, tooltip = ranking.rankingOverlay, api.GameTooltip
    local group, personal = panel.groupBurned, panel.personalBurned
    local function selectPersonal(value)
        personal:SetValue(value)
        personal.scripts.OnMouseUp(personal, "LeftButton")
    end
    local minimum, maximum = personal:GetMinMaxValues()
    assert(group and group:IsShown() and personal:IsShown()
        and personal.frameType == "Slider" and personal.orientation == "HORIZONTAL"
        and minimum == 0 and maximum == 100 and personal.valueStep == 10 and personal:IsEnabled(),
        "ranking exposes the group meter and a native horizontal 0-100 personal slider in ten-percent steps")
    for index = 0, 10 do
        assert(personal.ticks[index] and personal.ticks[index]:IsShown(),
            "the personal slider marks each selectable ten-percent point, including its endpoints")
    end
    assert(group.value == 45 and group.fill:IsShown()
        and group.fill:GetWidth() == group.track:GetWidth() * 0.45
        and personal:GetValue() == 20 and personal.label:GetText():find("20%%") and #edits == 0,
        "opening ranking paints the average and saved personal value without sending a personal edit")
    selectPersonal(73.6)
    assert(#edits == 1 and edits[1] == 70 and personal:GetValue() == 70
        and personal.label:GetText():find("70%%"),
        "dragging snaps to the nearest ten percent and emits one personal edit despite its synchronous refresh event")
    for _, sample in ipairs({ { 0, 0 }, { 100, 100 }, { 4.9, 0 }, { 5, 10 },
        { 14.9, 10 }, { 15, 20 }, { 94.9, 90 }, { 95, 100 } }) do
        local previous = #edits
        local expectedWrites = personalValue == sample[2] and 0 or 1
        selectPersonal(sample[1])
        assert(#edits == previous + expectedWrites and edits[#edits] == sample[2]
            and personal:GetValue() == sample[2],
            "personal input snaps at five-percent boundaries and does not repeat a write in the same ten-percent bucket")
    end
    local sameBucketEdits = #edits
    for _, value in ipairs({ 99.9, 96, 95.1 }) do selectPersonal(value) end
    assert(#edits == sameBucketEdits and personal:GetValue() == 100,
        "dragging within a selected ten-percent bucket restores its fixed point without duplicate model writes")
    local previousEdits = #edits
    personalValue, groupState.average = 19, 33.3
    ranking:Notify("DATA_CHANGED")
    assert(personal:GetValue() == 19 and group.value == 33.3 and #edits == previousEdits,
        "data refresh updates both meters without writing the model")
    groupState.average, groupState.count = 60, 3
    ranking:Notify("BURNED_CHANGED")
    assert(group.value == 60 and group.fill:GetWidth() == group.track:GetWidth() * 0.6
        and #edits == previousEdits, "burned notifications immediately repaint the group average without local writes")
    groupState.average, groupState.count = nil, 0
    ranking:Notify("ROSTER_CHANGED")
    local unknownLabel = group.label:GetText()
    assert(group.value == nil and not group.fill:IsShown() and unknownLabel ~= "",
        "no reports leave an explained unknown average instead of an invented zero")
    groupState.average, groupState.count = 0, 1
    ranking:Notify("BURNED_CHANGED")
    assert(group.value == 0 and group.label:GetText():find("0%%")
        and group.label:GetText() ~= unknownLabel and #edits == previousEdits,
        "a known zero average remains distinct from an unknown average")
    assert(not group.scripts.OnEnter and not group.scripts.OnLeave
        and not personal.scripts.OnEnter and not personal.scripts.OnLeave and not tooltip:IsShown(),
        "group and personal burned meters attach no descriptive hover help")
    api.UIParent:Hide()
    assert(not panel:IsVisible(), "hiding the interface also hides the burned meters")
    api.UIParent:Show()
    assert(panel:IsVisible() and #edits == previousEdits and personal:GetValue() == 19,
        "showing the interface restores burned meters without treating repaint as input")
    panel.CloseButton:Click()
    assert(not panel:IsShown(), "closing ranking hides both burned meters")
end

-- A drag commits once on release, then its personal meter counts down five minutes.
do
    local saved = settings(SECRET, false)
    saved.burned = { status = 20 }
    local ranking, api, _, _, world = loadAddon(saved, false)
    world:initialize()
    world:completeJoin(ranking:GetGroupDataChannelName(), 7)
    loadOverlay(ranking, api)
    assert(ranking:SetRankingEnabled(true))
    local panel = ranking.rankingOverlay
    local personal, group = panel.personalBurned, panel.groupBurned
    local writes, setBurned = 0, ranking.SetBurnedStatus
    ranking.SetBurnedStatus = function(self, value)
        writes = writes + 1
        return setBurned(self, value)
    end
    local function sends()
        return #world.dataSends + #world.statusSends + #world.rosterSends + #world.guideSends
    end
    personal.scripts.OnMouseDown(personal, "LeftButton")
    personal.scripts.OnMouseUp(personal, "LeftButton")
    assert(writes == 0 and ranking:GetBurnedStatusCooldown() == 0 and personal:IsEnabled(),
        "releasing an unchanged personal selection neither writes the model nor starts a cooldown")

    local beforeSends = sends()
    personal:SetValue(36)
    personal.scripts.OnMouseDown(personal, "LeftButton")
    personal:SetValue(81)
    assert(writes == 0 and personal:GetValue() == 80 and personal.label:GetText():find("80%%")
        and ranking:GetBurnedStatus() == 20 and group.value == 20
        and ranking:GetBurnedStatusCooldown() == 0 and personal:IsEnabled() and sends() == beforeSends,
        "one drag can cross several fixed points and previews its last value without changing the shared status")
    panel:AdvanceFrame(1)
    ranking:Notify("DATA_CHANGED")
    assert(writes == 0 and personal:GetValue() == 80 and personal.label:GetText():find("80%%")
        and ranking:GetBurnedStatus() == 20 and group.value == 20 and sends() == beforeSends,
        "periodic and data refreshes preserve the active personal draft without sharing it or changing the group average")
    personal.scripts.OnMouseUp(personal, "RightButton")
    assert(writes == 0 and ranking:GetBurnedStatus() == 20,
        "an unrelated mouse button cannot commit the active personal drag")
    personal.scripts.OnMouseUp(personal, "LeftButton")
    assert(writes == 1 and ranking:GetBurnedStatus() == 80 and personal:GetValue() == 80
        and group.value == 80 and ranking:GetBurnedStatusCooldown() == 300 and not personal:IsEnabled()
        and personal.label:GetText():find("80%%") and personal.label:GetText():find("5:00", 1, true),
        "left release commits only the last drag value and locks its meter with a five-minute countdown")
    local lockedSends = sends()
    personal:SetValue(0)
    personal.scripts.OnMouseDown(personal, "LeftButton")
    personal:SetValue(40)
    personal.scripts.OnMouseUp(personal, "LeftButton")
    assert(writes == 1 and ranking:GetBurnedStatus() == 80 and personal:GetValue() == 80
        and ranking:GetBurnedStatusCooldown() == 300 and sends() == lockedSends,
        "stale disabled-slider callbacks cannot edit, extend the cooldown or send group traffic")
    world.now = world.now + 299
    panel:AdvanceFrame(1)
    assert(not personal:IsEnabled() and ranking:GetBurnedStatusCooldown() == 1
        and personal.label:GetText():find("0:01", 1, true),
        "the visible meter counts down and remains locked through the final cooldown second")
    world.now = world.now + 1
    panel:AdvanceFrame(1)
    assert(personal:IsEnabled() and ranking:GetBurnedStatusCooldown() == 0
        and personal:GetValue() == 80 and not personal.label:GetText():find("0:00", 1, true),
        "the periodic overlay refresh reenables personal input at the exact five-minute boundary")
    personal.scripts.OnMouseDown(personal, "LeftButton")
    personal:SetValue(40)
    personal.scripts.OnMouseUp(personal, "LeftButton")
    assert(writes == 2 and ranking:GetBurnedStatus() == 40 and personal:GetValue() == 40
        and not personal:IsEnabled() and ranking:GetBurnedStatusCooldown() == 300,
        "the next completed edit after expiry starts a fresh five-minute cooldown")
    world.now = world.now + 300
    panel:AdvanceFrame(1)
    personal.scripts.OnMouseDown(personal, "LeftButton")
    personal:SetValue(90)
    assert(personal:GetValue() == 90 and ranking:GetBurnedStatus() == 40,
        "a later drag still previews locally before committing")
    local hideSends = sends()
    api.UIParent:Hide()
    api.UIParent:Show()
    personal.scripts.OnMouseUp(personal, "LeftButton")
    assert(writes == 2 and personal:GetValue() == 40 and ranking:GetBurnedStatus() == 40
        and ranking:GetBurnedStatusCooldown() == 0 and personal:IsEnabled() and sends() == hideSends,
        "hiding the interface cancels its uncommitted personal draft and a stale release cannot publish it")
end

-- Burning is a local visual preference: high meters animate independently and stop when hidden.
do
    local saved = settings(SECRET, false)
    saved.burned = { status = 69 }
    local ranking, api, _, _, world = loadAddon(saved, false)
    world:initialize()
    world:completeJoin(ranking:GetGroupDataChannelName(), 7)
    loadOverlay(ranking, api)
    local groupState = { average = 69.9, count = 2 }
    ranking.GetGroupBurnedStatus = function() return groupState end
    local modelWrites, setBurned = 0, ranking.SetBurnedStatus
    ranking.SetBurnedStatus = function(self, value)
        modelWrites = modelWrites + 1
        return setBurned(self, value)
    end
    assert(ranking:SetRankingEnabled(true))
    local panel = ranking.rankingOverlay
    local group, personal = panel.groupBurned, panel.personalBurned
    assert(ranking:GetRankingSettings().burningEffect and not group.burningEffect and not personal.burningEffect,
        "the default-on burning preference allocates no effect regions while both meters are below seventy percent")

    local function active(meter)
        local effect = meter.burningEffect
        return effect and effect:IsShown() and effect:IsVisible() and effect.scripts.OnUpdate ~= nil
    end
    local function stopped(meter)
        local effect = meter.burningEffect
        if not effect then return true end
        if effect:IsShown() or effect.scripts.OnUpdate then return false end
        for _, texture in ipairs(effect.textures) do
            if texture:IsShown() then return false end
        end
        return true
    end
    local function descendants(widget)
        local count = 0
        for _, child in ipairs(widget.children) do count = count + 1 + descendants(child) end
        return count
    end
    local function ordinaryFill(meter, value)
        local fraction, color = value / 100, meter.fill.textureColor
        return meter.fill:IsShown() and color
            and math.abs(color[1] - (0.30 + 0.65 * fraction)) < 0.000001
            and math.abs(color[2] - (0.75 - 0.40 * fraction)) < 0.000001
            and color[3] == 0.30 and color[4] == 1
            and meter.fill:GetWidth() == meter:GetWidth() * fraction
    end
    local function sends()
        return #world.dataSends + #world.statusSends + #world.rosterSends + #world.guideSends
    end

    groupState.average = 70
    ranking:Notify("BURNED_CHANGED")
    assert(active(group) and not personal.burningEffect and ranking:GetBurnedStatus() == 69 and modelWrites == 0,
        "the group effect begins at seventy percent independently of a personal value below the threshold")
    personal:SetValue(76)
    personal.scripts.OnMouseUp(personal, "LeftButton")
    local groupEffect, personalEffect = group.burningEffect, personal.burningEffect
    assert(active(group) and active(personal) and modelWrites == 1 and ranking:GetBurnedStatus() == 80
        and personal:GetValue() == 80 and personal.valueStep == 10
        and groupEffect.mouseEnabled ~= true and personalEffect.mouseEnabled ~= true,
        "a hot personal edit still snaps to ten percent and activates a visual that does not capture slider input")
    for index = 0, 10 do
        assert(personal.ticks[index]:IsShown(), "burning leaves every personal fixed-point tick visible")
    end

    ranking:OpenOptions("ranking")
    local options = ranking.optionsPanel
    assert(options.rankingBurningEffect:GetChecked(), "Ranking Settings exposes the enabled burning preference")
    local timerCalls, timerAfter, timerNew = 0, api.C_Timer.After, api.C_Timer.NewTimer
    api.C_Timer.After = function(...)
        timerCalls = timerCalls + 1
        return timerAfter(...)
    end
    api.C_Timer.NewTimer = function(...)
        timerCalls = timerCalls + 1
        return timerNew(...)
    end
    local beforeSends, beforeWrites = sends(), modelWrites
    local groupLabel, personalLabel = group.label:GetText(), personal.label:GetText()
    options.rankingBurningEffect:Click()
    assert(not saved.ranking.burningEffect and not options.rankingBurningEffect:GetChecked()
        and stopped(group) and stopped(personal) and ordinaryFill(group, 70) and ordinaryFill(personal, 80)
        and panel:IsVisible() and saved.ranking.enabled and options:IsVisible() and options.selectedTab == "ranking"
        and ranking:GetBurnedStatus() == 80 and group.label:GetText() == groupLabel
        and personal.label:GetText() == personalLabel and modelWrites == beforeWrites and sends() == beforeSends,
        "disabling burning immediately clears both effects and retains plain meters, visibility, status and group traffic")
    options.rankingBurningEffect:Click()
    assert(saved.ranking.burningEffect and options.rankingBurningEffect:GetChecked()
        and active(group) and active(personal) and group.burningEffect == groupEffect
        and personal.burningEffect == personalEffect and modelWrites == beforeWrites and sends() == beforeSends,
        "reenabling burning immediately reuses the hot meters' effects without changing or broadcasting status")

    local regions = descendants(panel)
    for _ = 1, 20 do ranking:RefreshRankingOverlay() end
    local flame, heightChanges = personalEffect.flames[1], 0
    local setHeight = flame.SetHeight
    flame.SetHeight = function(self, value)
        heightChanges = heightChanges + 1
        return setHeight(self, value)
    end
    for _ = 1, 3 do personalEffect:AdvanceFrame(1 / 120) end
    assert(heightChanges == 0, "burning skips texture work between its thirty-frame-per-second drawing intervals")
    personalEffect:AdvanceFrame(0.01)
    assert(heightChanges == 1, "burning updates its flame geometry once when the drawing interval elapses")
    personalEffect:AdvanceFrame(1)
    groupEffect:AdvanceFrame(1)
    assert(heightChanges == 2 and descendants(panel) == regions and group.burningEffect == groupEffect
        and personal.burningEffect == personalEffect and timerCalls == 0
        and modelWrites == beforeWrites and sends() == beforeSends,
        "redraws and animation reuse existing regions, bound long-frame work and never schedule timers or send status")

    groupState.average = nil
    groupState.count = 0
    ranking:Notify("ROSTER_CHANGED")
    assert(stopped(group) and not group.fill:IsShown() and active(personal),
        "an unknown group average cannot burn while a known hot personal meter continues independently")
    groupState.average, groupState.count = 69.9, 2
    world.now = world.now + 300
    assert(ranking:SetBurnedStatus(60))
    assert(stopped(group) and stopped(personal) and ordinaryFill(group, 69.9) and ordinaryFill(personal, 60),
        "dropping below seventy percent clears all burning regions and restores the ordinary fills")
    groupState.average = 100
    world.now = world.now + 300
    assert(ranking:SetBurnedStatus(100))
    assert(active(group) and active(personal), "both fully burned meters resume their existing effects")
    api.UIParent:Hide()
    assert(not panel:IsVisible() and stopped(group) and stopped(personal),
        "hiding the native interface clears both burning visuals and removes their update callbacks")
    ranking:Notify("BURNED_CHANGED")
    assert(stopped(group) and stopped(personal), "refresh notifications cannot restart burning while the interface is hidden")
    api.UIParent:Show()
    assert(panel:IsVisible() and active(group) and active(personal),
        "restoring the native interface resumes burning for current hot values")
    panel:Hide()
    assert(stopped(group) and stopped(personal), "directly hiding the overlay also stops its burning work")
    ranking:RefreshRankingOverlay()
    assert(active(group) and active(personal), "showing the enabled overlay restores its current burning visuals")
    panel.CloseButton:Click()
    assert(not saved.ranking.enabled and stopped(group) and stopped(personal),
        "closing ranking clears all burning textures and removes their update callbacks")
    ranking:Notify("BURNED_CHANGED")
    assert(not panel:IsShown() and stopped(group) and stopped(personal),
        "later burned updates cannot restart effects on a dismissed ranking overlay")
    assert(ranking:SetRankingEnabled(true))
    assert(active(group) and active(personal) and descendants(panel) == regions,
        "reopening ranking reuses the same burning textures and resumes animation for hot meters")
end

-- Disabled burning stays lazy even when both meters start at their maximum.
do
    local saved = settings(SECRET, false)
    saved.ranking = { enabled = true, burningEffect = false }
    saved.burned = { status = 100 }
    local ranking, api, _, _, world = loadAddon(saved, false)
    ranking.GetGroupBurnedStatus = function() return { average = 100, count = 2 } end
    loadOverlay(ranking, api)
    world:initialize()
    local panel = ranking.rankingOverlay
    assert(panel:IsVisible() and not panel.groupBurned.burningEffect and not panel.personalBurned.burningEffect
        and panel.groupBurned.fill:IsShown() and panel.personalBurned.fill:IsShown(),
        "a saved disabled burning preference shows plain maximum meters without allocating effect regions")
    assert(ranking:SetRankingBurningEffect(true))
    assert(panel.groupBurned.burningEffect:IsShown() and panel.personalBurned.burningEffect:IsShown(),
        "enabling a saved disabled preference creates and starts both currently hot effects immediately")
end

-- A personal burned edit works before joining a group and survives another addon load.
do
    local saved = settings(SECRET, false)
    saved.group = {}
    saved.burned = { status = 19 }
    local ranking, api, _, _, world = loadAddon(saved, false)
    world:initialize()
    loadOverlay(ranking, api)
    assert(ranking:SetRankingEnabled(true))
    local personal = ranking.rankingOverlay.personalBurned
    assert(not ranking:HasGroup() and personal:IsEnabled()
        and personal:GetValue() == 19 and saved.burned.status == 19,
        "personal burned status remains editable without a group and opening preserves a saved value between fixed points")
    personal:SetValue(67)
    personal.scripts.OnMouseUp(personal, "LeftButton")
    assert(ranking:GetBurnedStatus() == 70 and personal:GetValue() == 70 and saved.burned.status == 70,
        "the personal slider writes the selected ten-percent point through the production burned model without a group")
    local restored, restoredAPI, _, _, restoredWorld = loadAddon(saved, false)
    restoredWorld:initialize()
    loadOverlay(restored, restoredAPI)
    restored:RefreshRankingOverlay()
    local restoredPersonal = restored.rankingOverlay.personalBurned
    assert(restored:GetBurnedStatus() == 70 and restoredPersonal:GetValue() == 70
        and not restoredPersonal:IsEnabled() and restored:GetBurnedStatusCooldown() == 300
        and restoredPersonal.label:GetText():find("5:00", 1, true),
        "the personal burned value, cooldown and disabled meter survive reloading the addon")
end

-- Future-schema personal meters remain read-only without descriptive hover help.
do
    local future = settings(SECRET, false)
    future.schemaVersion = 99
    future.ranking = { enabled = true }
    future.burned = { status = 61, future = "keep" }
    local originalBurned = future.burned
    local ranking, api, _, _, world = loadAddon(future, false)
    loadOverlay(ranking, api)
    world:initialize()
    local panel, tooltip = ranking.rankingOverlay, api.GameTooltip
    local personal, writes = panel.personalBurned, 0
    local previous = ranking:GetBurnedStatus()
    ranking.SetBurnedStatus = function() writes = writes + 1 end
    assert(ranking.savedDataReadOnly and not personal:IsEnabled()
        and personal:GetValue() == 61 and future.burned.status == 61,
        "future-schema profiles expose a disabled personal burned meter without snapping the saved value")
    -- A stale native callback must retain the same write guard as ordinary input.
    personal:SetValue(previous == 100 and 0 or 100)
    assert(writes == 0 and personal:GetValue() == previous
        and future.burned == originalBurned and future.burned.status == 61 and future.burned.future == "keep",
        "disabled personal meter callbacks restore the current value without writing future saved data")
    assert(not personal.scripts.OnEnter and not personal.scripts.OnLeave and not tooltip:IsShown(),
        "disabled personal meters also attach no descriptive hover help")
    panel.CloseButton:Click()
    assert(not panel:IsShown(), "closing read-only ranking hides its disabled meter")
end

-- Settings controls apply overlay preferences immediately without changing the active view.
do
    local saved = settings(SECRET, false)
    local ranking, api, _, _, world = loadAddon(saved, false)
    world:initialize()
    loadOverlay(ranking, api)
    ranking:OpenOptions("ranking")
    local options = ranking.optionsPanel
    assert(options.selectedTab == "ranking" and options.pages.ranking:IsVisible()
        and not options.rankingEnabled:GetChecked()
        and not ranking.rankingOverlay,
        "the Ranking Settings page exposes the default-off preference without a separate lock control")
    local tooltip = api.GameTooltip
    options.rankingEnabled:Click()
    local panel = ranking.rankingOverlay
    assert(saved.ranking.enabled and options.rankingEnabled:GetChecked()
        and panel:IsVisible() and options:IsVisible() and options.selectedTab == "ranking",
        "enabling from Settings immediately saves and shows the independent overlay")
    panel.CloseButton:Click()
    assert(not saved.ranking.enabled and not options.rankingEnabled:GetChecked() and options:IsVisible()
        and not tooltip:IsShown(),
        "closing ranking refreshes its visibility checkbox while retaining the Settings page")
end

-- Five pooled leaders and a separate local row preserve actual ranks and progress states.
do
    local ranking, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    loadOverlay(ranking, api)
    local own = row("Self", 6, 24, 250, 1000, true)
    local players = {
        row("Alpha", 1, 60), row("Bravo", 2, 25, 500, 1000),
        row("Charlie", 2, 25, 1, 2), row("Delta", 4, 24, 999, 1000),
        row("Echo", 5, 24, 500, 1000), own,
    }
    players[1].name, own.name = "Alpha-RemoteRealm", "Self-HomeRealm"
    local state = { players = players, own = own, connected = true, grouped = true,
        awaiting = 2, stale = 2, inactive = 4 }
    players[1].stale, players[4].stale = true, true
    ranking.GetPlayerRanking = function() return state end
    assert(ranking:SetRankingEnabled(true))
    local panel = ranking.rankingOverlay
    assert(#panel.rows == 5 and panel.rows[1].player == players[1] and panel.rows[5].player == players[5]
        and panel.rows[1].rank:GetText() == "1" and panel.rows[2].rank:GetText() == "2"
        and panel.rows[3].rank:GetText() == "2" and panel.rows[4].rank:GetText() == "4"
        and panel.ownRow:IsShown() and panel.ownRow.player == own and panel.ownRow.rank:GetText() == "6"
        and panel.ownRow.name:GetText() == "Self"
        and panel.separator:IsShown() and panel.ownRow.highlight:IsShown(),
        "the top five retain tie ranks and a lower local player uses a plain name in its highlighted separate row")
    panel.ownRow:Click("RightButton")
    assert(not panel.actionMenu, "the separate local row cannot allocate or open player actions")
    assert(panel.rows[1].progress:GetText() == "MAX" and panel.rows[1].progressTrack:IsShown()
        and panel.rows[1].progressFill:IsShown()
        and panel.rows[1].progressFill:GetWidth() == panel.rows[1].progressTrack:GetWidth()
        and panel.rows[2].progress:GetText() == "50%"
        and panel.rows[2].progressTrack:IsShown() and panel.rows[2].progressFill:IsShown()
        and panel.rows[4].progress:GetText() == "99.9%"
        and panel.rows[1].alpha == 0.65 and panel.rows[4].alpha == 0.65,
        "maximum level and percentages omit stale prefixes while saved rows stay dim and near-level XP stays below 100 percent")
    local firstRowY, secondRowY = select(5, panel.rows[1]:GetPoint()), select(5, panel.rows[2]:GetPoint())
    assert(panel.rows[1]:GetHeight() == 34 and secondRowY - firstRowY == -34
        and panel.rows[1].progressTrack.point[3] == -26
        and placed(panel.rows[1].progress, panel.rows[1].level, "RIGHT", "LEFT", -8, 0)
        and placed(panel.rows[2].progress, panel.rows[2].level, "RIGHT", "LEFT", -8, 0)
        and placed(panel.ownRow.progress, panel.ownRow.level, "RIGHT", "LEFT", -8, 0)
        and panel.rows[1].progress:GetHeight() == panel.rows[1].level:GetHeight()
        and panel.rows[2].progress:GetHeight() == panel.rows[2].level:GetHeight()
        and select(2, panel.rows[1].progress:GetFont()) == select(2, panel.rows[1].level:GetFont())
        and select(2, panel.rows[2].progress:GetFont()) == select(2, panel.rows[2].level:GetFont())
        and panel.rows[2].name:GetWidth() == 164
        and panel.rows[1].progress.justifyH == "RIGHT" and panel.rows[2].progress.justifyH == "RIGHT",
        "MAX and percentages share the level's text line and font size with space reserved beside player names")
    players[1], own.rank = own, 1
    state.players = { own }
    state.stale, state.awaiting = 0, 0
    ranking:Notify("ROSTER_CHANGED")
    assert(panel.rows[1].player == own and panel.rows[1].highlight:IsShown()
        and panel.rows[1].name:GetText() == "Self"
        and panel.rows[1].progress:GetText() == "25%"
        and placed(panel.rows[1].progress, panel.rows[1].level, "RIGHT", "LEFT", -8, 0)
        and not panel.ownRow:IsShown() and not panel.separator:IsShown()
        and not panel.ownRow.player and panel.ownRow.rank:GetText() == ""
        and not panel.ownRow.highlight:IsShown(),
        "a local leader is highlighted in place and clears its former separate pooled row")
    panel.rows[1]:Click("RightButton")
    assert(not panel.actionMenu, "a highlighted local leader cannot allocate or open player actions")
    for index = 2, 5 do
        local unused = panel.rows[index]
        assert(not unused:IsShown() and not unused.player and unused.rank:GetText() == ""
            and unused.name:GetText() == "" and unused.level:GetText() == "" and unused.progress:GetText() == ""
            and not unused.progressTrack:IsShown() and not unused.progressFill:IsShown()
            and not unused.highlight:IsShown(),
            "unused pooled rows clear names, targets, ranks, progress and highlighting")
    end
    own.xp, own.xpMax, own.xpState, own.rank = nil, nil, "unavailable", nil
    state.players, state.awaiting, state.stale = {}, 1, 0
    ranking:RefreshRankingOverlay()
    assert(panel.ownRow:IsShown() and panel.ownRow.player == own
        and panel.ownRow.progress:GetText() == "Waiting for XP"
        and panel.ownRow.progress.point[3] == -21
        and panel.ownRow.progress:GetHeight() == 12
        and panel.ownRow.progress.justifyH == "LEFT"
        and not panel.empty:IsShown() and not panel.separator:IsShown()
        and not panel.ownRow.rank:GetText():find("%d") and not panel.ownRow.progressTrack:IsShown(),
        "missing local XP uses the first row without duplicate empty messages or an invented rank")
    state.grouped, state.own = false, nil
    ranking:Notify("GROUP_CHANGED")
    assert(panel.empty:IsShown() and panel.empty:GetText():find("group", 1, true)
        and not panel.rows[1]:IsShown() and not panel.rows[1].player,
        "leaving the group clears all player rows while leaving the chosen overlay visible")
end

-- XP animation is presentation-only: exact values update now while earned fill catches up.
do
    local ranking, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    loadOverlay(ranking, api)
    local own = row("Self", 1, 24, 250, 1000, true)
    local reads = 0
    ranking.GetPlayerRanking = function()
        reads = reads + 1
        return { grouped = true, connected = true, players = { own }, own = own }
    end
    assert(ranking:SetRankingEnabled(true))
    local panel, first = ranking.rankingOverlay, ranking.rankingOverlay.rows[1]
    local function near(actual, expected) return math.abs(actual - expected) < 0.000001 end
    local function descendants(widget)
        local count = 1
        for _, child in ipairs(widget.children or {}) do count = count + descendants(child) end
        return count
    end
    local regions = descendants(panel)
    assert(near(first.progressFill:GetWidth(), 174 * 0.25) and not first.progressGain:IsShown()
        and not panel.xpAnimator.scripts.OnUpdate,
        "first display establishes an exact XP baseline without replaying saved progress")
    own.xp = 430
    ranking:Notify("ROSTER_CHANGED")
    assert(first.progress:GetText() == "43%" and first.player.xp == 430
        and near(first.progressFill:GetWidth(), 174 * 0.25) and first.progressGain:IsShown()
        and panel.xpAnimator.scripts.OnUpdate,
        "fresh XP updates the percentage immediately and starts the fill and gain highlight from the old width")
    first.scripts.OnEnter(first)
    assert(api.GameTooltip.text == "#1 - Self"
        and api.GameTooltip.lines[1]:find("570", 1, true),
        "hover details immediately use the authoritative XP rather than the animated fraction")
    panel.xpAnimator:AdvanceFrame(0.15)
    local halfway = 0.25 + (0.43 - 0.25) * 0.875
    assert(near(first.progressFill:GetWidth(), 174 * halfway),
        "the fill uses a cubic ease-out and covers seven eighths of a gain halfway through 300 ms")
    local width = first.progressFill:GetWidth()
    for _ = 1, 10 do ranking:Notify("ROSTER_CHANGED") end
    panel:AdvanceFrame(1)
    assert(near(first.progressFill:GetWidth(), width) and first.progressGain:IsShown(),
        "unrelated redraws preserve the current XP animation and highlight")
    panel.xpAnimator:AdvanceFrame(0.15)
    assert(near(first.progressFill:GetWidth(), 174 * 0.43) and first.progressGain:IsShown()
        and panel.xpAnimator.scripts.OnUpdate,
        "the fill reaches its exact target at 300 ms while the gain highlight continues")
    panel.xpAnimator:AdvanceFrame(0.350001)
    assert(not first.progressGain:IsShown() and not panel.xpAnimator.scripts.OnUpdate,
        "the highlight ends after 650 ms and removes the animation callback")

    own.xp = 500
    ranking:RefreshRankingOverlay()
    panel.xpAnimator:AdvanceFrame(0.1)
    width = first.progressFill:GetWidth()
    own.xp = 650
    ranking:RefreshRankingOverlay()
    assert(first.progress:GetText() == "65%" and near(first.progressFill:GetWidth(), width),
        "a second gain retargets from the visible fill without jumping to the previous target")
    local beforeReads = reads
    local beforeSends = #world.statusSends + #world.rosterSends + #world.dataSends + #world.guideSends
    local timerCalls, after, newTimer = 0, api.C_Timer.After, api.C_Timer.NewTimer
    api.C_Timer.After = function(...) timerCalls = timerCalls + 1; return after(...) end
    api.C_Timer.NewTimer = function(...) timerCalls = timerCalls + 1; return newTimer(...) end
    panel.xpAnimator:AdvanceFrame(0.15)
    assert(near(first.progressFill:GetWidth(), width + (174 * 0.65 - width) * 0.875),
        "retargeted gains retain the same easing from their current displayed position")
    panel.xpAnimator:AdvanceFrame(10)
    assert(near(first.progressFill:GetWidth(), 174 * 0.65) and not first.progressGain:IsShown()
        and not panel.xpAnimator.scripts.OnUpdate and descendants(panel) == regions
        and reads == beforeReads and timerCalls == 0
        and #world.statusSends + #world.rosterSends + #world.dataSends + #world.guideSends == beforeSends,
        "animation frames reuse regions, finish long frames once and never read rankings, schedule timers or send status")
    own.xp = 651
    ranking:RefreshRankingOverlay()
    panel.xpAnimator:AdvanceFrame(0.01)
    assert(first.progressGain:IsShown() and first.progressGain:GetWidth() >= 3
        and first.progressGain:GetHeight() == 5,
        "subpixel XP gains receive a visible minimum-width five-pixel-high highlight")
    panel.xpAnimator:AdvanceFrame(0.65)
    assert(not first.progressGain:IsShown() and not panel.xpAnimator.scripts.OnUpdate,
        "a small gain also removes its callback after the highlight expires")
    own.xp = 0
    ranking:RefreshRankingOverlay()
    assert(not first.progressFill:IsShown() and first.progress:GetText() == "0%",
        "a corrected zero-XP baseline hides its empty fill")
    own.xp = 10
    ranking:RefreshRankingOverlay()
    assert(not first.progressFill:IsShown() and first.progressGain:IsShown(),
        "gaining XP from zero starts at the empty baseline with its gain highlight")
    panel.xpAnimator:AdvanceFrame(0.65)
    assert(first.progressFill:IsShown() and near(first.progressFill:GetWidth(), 1.74)
        and not first.progressGain:IsShown() and not panel.xpAnimator.scripts.OnUpdate,
        "a gain from zero finishes with the exact nonzero fill and no lingering work")
    own.xp = 999
    ranking:RefreshRankingOverlay()
    panel.xpAnimator:AdvanceFrame(0.65)
    own.xp = 1000
    ranking:RefreshRankingOverlay()
    local _, _, _, gainStart = first.progressGain:GetPoint()
    assert(first.progressGain:IsShown() and first.progressGain:GetWidth() >= 3
        and gainStart >= 0 and gainStart + first.progressGain:GetWidth() <= 174,
        "a minimum-width highlight near full XP stays inside the progress track")
    panel.xpAnimator:AdvanceFrame(0.65)
end

-- Animation follows player identity across pooled leaders and the separate own row.
do
    local ranking, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    loadOverlay(ranking, api)
    local peers = {
        row("Alpha", 1, 24, 850, 1000), row("Bravo", 2, 24, 750, 1000),
        row("Charlie", 3, 24, 650, 1000), row("Delta", 4, 24, 550, 1000),
        row("Echo", 5, 24, 450, 1000),
    }
    local own = row("Self", 6, 24, 250, 1000, true)
    local state = { grouped = true, connected = true,
        players = { peers[1], peers[2], peers[3], peers[4], peers[5], own }, own = own }
    ranking.GetPlayerRanking = function() return state end
    assert(ranking:SetRankingEnabled(true))
    local panel = ranking.rankingOverlay
    local function near(actual, expected) return math.abs(actual - expected) < 0.000001 end
    local function entries()
        local count = 0
        for _ in pairs(panel.xpProgress) do count = count + 1 end
        return count
    end
    assert(panel.ownRow:IsShown() and entries() == 6,
        "progress state is bounded to five visible leaders and the separate local player")
    own.xp, own.rank = 600, 4
    state.players = { peers[1], peers[2], peers[3], own, peers[4], peers[5] }
    ranking:Notify("ROSTER_CHANGED")
    assert(panel.rows[4].player == own and panel.rows[4].rank:GetText() == "4"
        and panel.rows[4].progress:GetText() == "60%" and not panel.ownRow:IsShown()
        and near(panel.rows[4].progressFill:GetWidth(), 174 * 0.25)
        and panel.rows[4].progressGain:IsShown() and entries() == 5,
        "entering the leaders updates rank immediately and transfers the separate row's previous XP baseline")
    panel.xpAnimator:AdvanceFrame(0.1)
    local width = panel.rows[4].progressFill:GetWidth()
    own.xp, own.rank = 800, 2
    state.players = { peers[1], own, peers[2], peers[3], peers[4], peers[5] }
    ranking:RefreshRankingOverlay()
    assert(panel.rows[2].player == own and panel.rows[2].rank:GetText() == "2"
        and near(panel.rows[2].progressFill:GetWidth(), width) and panel.rows[2].progressGain:IsShown()
        and panel.rows[4].player == peers[3] and not panel.rows[4].progressGain:IsShown()
        and near(panel.rows[4].progressFill:GetWidth(), 174 * 0.65),
        "reordering leaders transfers an active gain by identity and never gives a recycled row another player's animation")
    for index, peer in ipairs(peers) do peer.level, peer.rank = 25, index end
    own.rank = 6
    state.players = { peers[1], peers[2], peers[3], peers[4], peers[5], own }
    ranking:RefreshRankingOverlay()
    assert(panel.ownRow:IsShown() and panel.ownRow.player == own and panel.ownRow.rank:GetText() == "6"
        and near(panel.ownRow.progressFill:GetWidth(), width) and panel.ownRow.progressGain:IsShown()
        and panel.rows[2].player == peers[2] and not panel.rows[2].progressGain:IsShown() and entries() == 6,
        "falling outside the leaders carries the active fill and highlight into the separate local row")
    panel.xpAnimator:AdvanceFrame(0.65)
    assert(near(panel.ownRow.progressFill:GetWidth(), 174 * 0.8)
        and not panel.ownRow.progressGain:IsShown() and not panel.xpAnimator.scripts.OnUpdate,
        "a transferred animation finishes on its current row and removes its callback")
    local fresh = row("Fresh", 1, 25, 100, 1000)
    state.players, state.own = { fresh }, nil
    ranking:RefreshRankingOverlay()
    assert(entries() == 1 and panel.xpProgress.Fresh and not panel.xpProgress.Self,
        "players leaving the visible rows do not accumulate retained animation state")
    fresh.xp = 500
    ranking:RefreshRankingOverlay()
    panel.xpAnimator:AdvanceFrame(0.1)
    fresh.xp = 600
    ranking:Notify("GROUP_CHANGED")
    assert(entries() == 1 and near(panel.rows[1].progressFill:GetWidth(), 174 * 0.6)
        and not panel.rows[1].progressGain:IsShown() and not panel.xpAnimator.scripts.OnUpdate,
        "changing groups resets progress even when the new standings reuse a visible player identity")
    state.grouped, state.players = false, {}
    ranking:Notify("GROUP_CHANGED")
    assert(entries() == 0 and not panel.xpAnimator.scripts.OnUpdate,
        "leaving a group clears every presentation state and active XP callback")
end

-- Level, denominator and availability changes establish fresh baselines instead of fake gains.
do
    local ranking, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    loadOverlay(ranking, api)
    local own = row("Self", 1, 24, 250, 1000, true)
    local state = { grouped = true, connected = true, players = { own }, own = own }
    ranking.GetPlayerRanking = function() return state end
    assert(ranking:SetRankingEnabled(true))
    local panel, first = ranking.rankingOverlay, ranking.rankingOverlay.rows[1]
    local function snapped(fraction, message)
        ranking:RefreshRankingOverlay()
        assert(math.abs(first.progressFill:GetWidth() - 174 * fraction) < 0.000001
            and not first.progressGain:IsShown() and not panel.xpAnimator.scripts.OnUpdate, message)
    end
    own.xp = 400
    ranking:RefreshRankingOverlay()
    panel.xpAnimator:AdvanceFrame(0.1)
    own.xp = 200
    snapped(0.2, "a corrected XP decrease snaps instead of playing a backward or stale forward animation")
    own.level, own.xp = 25, 80
    snapped(0.08, "a level-up snaps to the new level's XP baseline without a backward tween")
    assert(first.level:GetText() == "25" and first.progress:GetText() == "8%",
        "level-up text immediately matches its new progress baseline")
    own.level, own.xp = 26, 300
    snapped(0.3, "a report for a new level snaps even when its percentage exceeds the previous level's percentage")
    own.xpMax = 500
    snapped(0.6, "a changed XP denominator snaps rather than interpreting a larger fraction as earned XP")
    own.xp, own.xpMax, own.xpState = nil, nil, "max"
    snapped(1, "maximum-level reports snap to a full bar without a gain highlight")
    assert(first.progress:GetText() == "MAX", "maximum-level text updates with the full baseline")
    own.xp, own.xpMax, own.xpState = 100, 1000, "known"
    snapped(0.1, "returning from maximum-level state establishes a known-progress baseline")
    own.xp, own.xpMax, own.xpState, own.rank = nil, nil, "unavailable", nil
    state.players = {}
    ranking:RefreshRankingOverlay()
    assert(panel.ownRow:IsShown() and panel.ownRow.progress:GetText() == "Waiting for XP"
        and not panel.ownRow.progressTrack:IsShown() and not panel.ownRow.progressFill:IsShown()
        and not panel.ownRow.progressGain:IsShown() and not panel.xpProgress.Self
        and not panel.xpAnimator.scripts.OnUpdate,
        "unknown XP clears its animation state and shows no invented progress")
    own.xp, own.xpMax, own.xpState, own.rank = 300, 1000, "known", 1
    state.players = { own }
    snapped(0.3, "recovering unknown XP snaps to the first complete report without replaying missing gains")
end

-- Stale reports and hidden interfaces never replay catch-up progress as a new gain.
do
    local ranking, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    loadOverlay(ranking, api)
    local peer = row("Peer", 1, 24, 250, 1000)
    ranking.GetPlayerRanking = function()
        return { grouped = true, connected = true, players = { peer } }
    end
    assert(ranking:SetRankingEnabled(true))
    local panel, first = ranking.rankingOverlay, ranking.rankingOverlay.rows[1]
    local function at(fraction)
        return math.abs(first.progressFill:GetWidth() - 174 * fraction) < 0.000001
    end
    peer.xp = 400
    ranking:RefreshRankingOverlay()
    panel.xpAnimator:AdvanceFrame(0.1)
    peer.stale = true
    ranking:Notify("ROSTER_CHANGED")
    assert(at(0.4) and first.alpha == 0.65 and not first.progressGain:IsShown()
        and not panel.xpAnimator.scripts.OnUpdate,
        "contact expiry ends an active gain at the saved target and restores ordinary stale dimming")
    peer.xp = 600
    ranking:RefreshRankingOverlay()
    assert(at(0.6) and not first.progressGain:IsShown() and not panel.xpAnimator.scripts.OnUpdate,
        "changed stale snapshots are displayed without claiming a fresh gain")
    peer.xp, peer.stale = 700, false
    ranking:Notify("ROSTER_CHANGED")
    assert(at(0.7) and first.alpha == 1 and not first.progressGain:IsShown()
        and not panel.xpAnimator.scripts.OnUpdate,
        "reconnection updates brightness and establishes a fresh baseline without replaying catch-up XP")
    peer.xp = 800
    ranking:RefreshRankingOverlay()
    panel.xpAnimator:AdvanceFrame(0.1)
    panel.CloseButton:Click()
    assert(not panel:IsShown() and not panel.xpAnimator.scripts.OnUpdate
        and not first.progressGain:IsShown(),
        "closing the ranking overlay stops active XP work and clears its gain highlight")
    peer.xp = 900
    ranking:Notify("ROSTER_CHANGED")
    assert(not panel:IsShown() and not panel.xpAnimator.scripts.OnUpdate,
        "fresh XP cannot restart the animation driver on a dismissed overlay")
    assert(ranking:SetRankingEnabled(true))
    assert(at(0.9) and not first.progressGain:IsShown() and not panel.xpAnimator.scripts.OnUpdate,
        "reopening ranking snaps to XP received while the overlay was dismissed")
    peer.xp = 950
    ranking:RefreshRankingOverlay()
    panel.xpAnimator:AdvanceFrame(0.1)
    api.UIParent:Hide()
    assert(not panel:IsVisible() and not panel.xpAnimator.scripts.OnUpdate
        and not first.progressGain:IsShown(),
        "hiding the native interface stops active XP animation as well as the standings refresh")
    peer.xp = 980
    ranking:Notify("ROSTER_CHANGED")
    assert(not panel.xpAnimator.scripts.OnUpdate and not first.progressGain:IsShown(),
        "XP notifications while the native interface is hidden cannot restart a gain animation")
    api.UIParent:Show()
    assert(panel:IsVisible() and at(0.98) and not first.progressGain:IsShown()
        and not panel.xpAnimator.scripts.OnUpdate,
        "restoring the native interface starts from current XP without replaying hidden gains")
    peer.xp = 990
    ranking:RefreshRankingOverlay()
    panel.xpAnimator:AdvanceFrame(0.1)
    panel:Hide()
    ranking:RefreshRankingOverlay()
    assert(panel:IsVisible() and at(0.99) and not first.progressGain:IsShown()
        and not panel.xpAnimator.scripts.OnUpdate,
        "a direct hide and refresh also discard unfinished motion and establish a current baseline")
end

-- Ranking motion moves native row hit areas while live values and XP keep their own timing.
do
    local function near(actual, expected) return math.abs(actual - expected) < 0.000001 end
    local function position(widget) return -select(5, widget:GetPoint()) end
    local function count(map)
        local total = 0
        for _ in pairs(map) do total = total + 1 end
        return total
    end
    local function descendants(widget)
        local total = 1
        for _, child in ipairs(widget.children or {}) do total = total + descendants(child) end
        return total
    end
    local function scene(players, own)
        local ranking, api, _, _, world = loadAddon(settings(SECRET, false), false)
        world:initialize()
        loadOverlay(ranking, api)
        local state = { grouped = true, connected = true, players = players, own = own, reads = 0 }
        ranking.GetPlayerRanking = function()
            state.reads = state.reads + 1
            return state
        end
        assert(ranking:SetRankingEnabled(true))
        return ranking, api, world, ranking.rankingOverlay, state
    end
    local function four()
        local own = row("Self", 4, 24, 500, 1000, true)
        return { row("Alpha", 1, 24, 850, 1000), row("Bravo", 2, 24, 750, 1000),
            row("Charlie", 3, 24, 650, 1000), own }, own
    end
    local function activeGhosts(panel)
        local total = 0
        for _, ghost in ipairs(panel.rowGhosts) do
            if ghost:IsShown() and ghost.playerID then total = total + 1 end
        end
        return total
    end

    do
        local players, own = four()
        local ranking, api, world, panel, state = scene(players, own)
        assert(panel.rowViewport.frameType == "ScrollFrame" and panel.rowViewport.scrollChild == panel.rowContent
            and panel.rows[1].parent == panel.rowContent and near(position(panel.rows[4]), 102)
            and not panel.rowAnimator.scripts.OnUpdate,
            "ranking first display uses a native clipped row viewport and snaps its initial positions")
        local regions = descendants(panel)
        own.xp, own.rank, players[3].rank = 700, 3, 4
        state.players = { players[1], players[2], own, players[3] }
        ranking:Notify("ROSTER_CHANGED")
        local moving, displaced = panel.rows[3], panel.rows[4]
        assert(moving.player == own and moving.rank:GetText() == "3" and moving.progress:GetText() == "70%"
            and displaced.rank:GetText() == "4" and moving.layoutY == 68
            and near(position(moving), 102) and near(position(displaced), 68)
            and moving.mouseEnabled and displaced.mouseEnabled and panel.rowAnimator.scripts.OnUpdate,
            "a rank swap updates logical slots and labels immediately while complete interactive rows start at their old positions")
        assert(moving.motionBacking:IsShown() and not displaced.motionBacking:IsShown()
            and moving:GetFrameLevel() > displaced:GetFrameLevel(),
            "the climbing player's opaque backing and frame layer preserve readable content through crossings")
        panel.xpAnimator:AdvanceFrame(0.3)
        assert(near(moving.progressFill:GetWidth(), 174 * 0.7) and moving.progressGain:IsShown()
            and near(position(moving), 102) and panel.rowAnimator.scripts.OnUpdate,
            "the existing 300 ms XP fill finishes independently of the slower ranking glide")
        panel.rowAnimator:AdvanceFrame(0.35)
        assert(near(position(moving), 102 + (68 - 102) * 0.875)
            and near(position(displaced), 68 + (102 - 68) * 0.875),
            "ranking rows use cubic ease-out over 700 ms in both directions")
        local movingY, displacedY = position(moving), position(displaced)
        for _ = 1, 5 do ranking:Notify("ROSTER_CHANGED") end
        panel:AdvanceFrame(1)
        assert(near(position(moving), movingY) and near(position(displaced), displacedY),
            "unchanged full repaints and the standings timer preserve visible ranking positions")
        local reads = state.reads
        local sends = #world.statusSends + #world.rosterSends + #world.dataSends + #world.guideSends
        local timerCalls, after, newTimer = 0, api.C_Timer.After, api.C_Timer.NewTimer
        api.C_Timer.After = function(...) timerCalls = timerCalls + 1; return after(...) end
        api.C_Timer.NewTimer = function(...) timerCalls = timerCalls + 1; return newTimer(...) end
        panel.xpAnimator:AdvanceFrame(0.350001)
        assert(not moving.progressGain:IsShown() and not panel.xpAnimator.scripts.OnUpdate
            and panel.rowAnimator.scripts.OnUpdate,
            "the 650 ms gain highlight also finishes without stopping the 700 ms row glide")
        panel.rowAnimator:AdvanceFrame(0.35)
        assert(near(position(moving), 68) and near(position(displaced), 102)
            and not panel.rowAnimator.scripts.OnUpdate and not moving.motionBacking:IsShown()
            and state.reads == reads and timerCalls == 0
            and descendants(panel) == regions
            and #world.statusSends + #world.rosterSends + #world.dataSends + #world.guideSends == sends,
            "rows settle at exactly 700 ms without allocation, ranking reads, timers or group traffic")
    end

    do
        local players, own = four()
        local ranking, api, _, panel, state = scene(players, own)
        local fresh = row("Fresh", 3, 24, 700, 1000)
        fresh.stale = true
        state.players = { players[1], players[2], fresh, own }
        ranking:RefreshRankingOverlay()
        local incoming = panel.rows[3]
        api.IsShiftKeyDown = function() return true end
        local function rejectedCallbacks()
            incoming.scripts.OnEnter(incoming)
            incoming.scripts.OnClick(incoming, "RightButton")
            incoming.scripts.OnDragStart(incoming, "LeftButton")
            assert(not api.GameTooltip:IsShown() and not panel.actionMenu and not panel.moving
                and not panel.dragHandle and panel.rowAnimator.scripts.OnUpdate
                and fresh.xp == 700 and fresh.rank == 3,
                "late hover, click and Shift-drag callbacks from a fading entrant cannot open interactions or change its report")
        end
        assert(incoming.player == fresh and near(incoming.alpha, 0) and not incoming.mouseEnabled
            and panel.xpProgress.Fresh and not panel.xpProgress.Charlie and count(panel.xpProgress) == 4,
            "an invisible incoming peer cannot accept input and its outgoing ghost cannot retain or steal live XP state")
        rejectedCallbacks()
        panel.rowAnimator:AdvanceFrame(0.35)
        assert(near(incoming.alpha, 0.65 * 0.875) and not incoming.mouseEnabled,
            "incoming opacity multiplies stale dimming while unfinished fades remain noninteractive")
        rejectedCallbacks()
        ranking:Notify("ROSTER_CHANGED")
        assert(near(incoming.alpha, 0.65 * 0.875) and not incoming.mouseEnabled,
            "an unchanged full redraw preserves a partially faded peer's opacity and input state")
        panel.rowAnimator:AdvanceFrame(0.35)
        assert(near(incoming.alpha, 0.65) and incoming.mouseEnabled and activeGhosts(panel) == 0
            and not panel.rowAnimator.scripts.OnUpdate and count(panel.xpProgress) == 4,
            "a stale incoming peer regains input at its normal dimmed opacity once its fade settles")
        panel.header.scripts.OnDragStart(panel.header, "LeftButton")
        assert(panel.moving and panel.dragHandle == panel.header,
            "the entrant interaction guard leaves ordinary header Shift dragging available")
        panel.header.scripts.OnDragStop(panel.header)
    end

    do
        local players, own = four()
        local ranking, _, _, panel, state = scene(players, own)
        own.xp, own.rank, players[3].rank = 700, 3, 4
        state.players = { players[1], players[2], own, players[3] }
        ranking:RefreshRankingOverlay()
        panel.rowAnimator:AdvanceFrame(0.2)
        local y, x = position(panel.rows[3]), select(4, panel.rows[3]:GetPoint())
        own.xp, own.rank, players[2].rank = 800, 2, 3
        state.players = { players[1], own, players[2], players[3] }
        ranking:RefreshRankingOverlay()
        assert(near(position(panel.rows[2]), y) and near(select(4, panel.rows[2]:GetPoint()), x)
            and panel.rows[2].player == own and panel.rows[2].rank:GetText() == "2",
            "a quick second reorder transfers the player's current visible position without a horizontal or vertical jump")
        panel.rowAnimator:AdvanceFrame(0.35)
        assert(near(position(panel.rows[2]), y + (34 - y) * 0.875),
            "a retargeted row eases from its displayed position toward the newest ranking slot")
        panel.rowAnimator:AdvanceFrame(10)
        assert(near(position(panel.rows[2]), 34) and not panel.rowAnimator.scripts.OnUpdate,
            "one long frame completes the latest row motion without repeated catch-up steps")
    end

    do
        local peers = {
            row("Alpha", 1, 24, 850, 1000), row("Bravo", 2, 24, 750, 1000),
            row("Charlie", 3, 24, 650, 1000), row("Delta", 4, 24, 550, 1000),
            row("Echo", 5, 24, 450, 1000),
        }
        local own = row("Self", 6, 24, 250, 1000, true)
        local ranking, _, _, panel, state = scene(
            { peers[1], peers[2], peers[3], peers[4], peers[5], own }, own)
        assert(near(panel.rowViewport:GetHeight(), 228) and near(position(panel.ownRow), 194)
            and near(position(panel.personalBurned), 78 + 228 + 25),
            "a separate own row starts below the leaders and separator with matching meter placement")
        own.xp, own.rank = 800, 2
        peers[2].rank, peers[3].rank, peers[4].rank, peers[5].rank = 3, 4, 5, 6
        state.players = { peers[1], own, peers[2], peers[3], peers[4], peers[5] }
        ranking:Notify("ROSTER_CHANGED")
        local departing
        for _, ghost in ipairs(panel.rowGhosts) do
            if ghost:IsShown() and ghost.playerID == "Echo" then departing = ghost end
        end
        assert(panel.rows[2].player == own and near(position(panel.rows[2]), 194)
            and not panel.ownRow:IsShown() and departing and departing.mouseEnabled == false
            and near(panel.rowViewport:GetHeight(), 228) and panel.rowLayout.target == 170,
            "entering the top five transfers the own-row position while a decorative outgoing peer fades inside the old viewport")
        panel.rowAnimator:AdvanceFrame(0.35)
        local height = 228 + (170 - 228) * 0.875
        assert(near(panel.rowViewport:GetHeight(), height)
            and near(position(panel.personalBurned), 78 + height + 25)
            and near(position(panel.rows[2]), 194 + (34 - 194) * 0.875),
            "the viewport, personal meter and incoming player interpolate together without an abrupt own-area collapse")
        local ownY, returningY = position(panel.rows[2]), position(departing)
        for index, peer in ipairs(peers) do peer.level, peer.rank = 25, index end
        own.rank = 6
        state.players = { peers[1], peers[2], peers[3], peers[4], peers[5], own }
        ranking:RefreshRankingOverlay()
        assert(panel.ownRow:IsShown() and panel.ownRow.player == own and near(position(panel.ownRow), ownY)
            and panel.rows[5].player == peers[5] and near(position(panel.rows[5]), returningY)
            and activeGhosts(panel) == 0 and panel.rowLayout.target == 228,
            "reversing before entry completes transfers self back and reuses an outgoing peer's current position without a duplicate ghost")
        panel.rowAnimator:AdvanceFrame(0.7)
        assert(near(position(panel.ownRow), 194) and near(position(panel.rows[5]), 136)
            and near(panel.rowViewport:GetHeight(), 228)
            and near(position(panel.personalBurned), 78 + 228 + 25)
            and not panel.rowAnimator.scripts.OnUpdate,
            "leaving the top five settles the separate row and expanded lower layout in 700 ms")
        local regions = descendants(panel)
        for index = 1, 24 do
            state.players, state.own = { row("Transient" .. index, 1, 25, index, 1000) }, nil
            ranking:RefreshRankingOverlay()
            assert(count(panel.rowMotion) <= 12 and #panel.rowGhosts == 6 and activeGhosts(panel) <= 6,
                "rapid membership churn keeps live snapshots and outgoing decorative rows bounded")
        end
        for _, prefix in ipairs({ "BatchA", "BatchB" }) do
            state.players = {}
            for index = 1, 5 do state.players[index] = row(prefix .. index, index, 25, 500, 1000) end
            ranking:RefreshRankingOverlay()
        end
        for index = 1, 5 do
            local departing = panel.rowMotion["BatchA" .. index]
            assert(departing and departing.leaving and departing.row:IsShown()
                and not departing.row.mouseEnabled,
                "a full replacement with an occupied pool preserves each newly outgoing player's fade")
        end
        panel.rowAnimator:AdvanceFrame(10)
        assert(count(panel.rowMotion) == 5 and activeGhosts(panel) == 0
            and descendants(panel) == regions and not panel.rowAnimator.scripts.OnUpdate,
            "finished exits release their snapshots and reuse the fixed ghost pool without allocating rows")
    end

    do
        local players, own = four()
        local ranking, _, _, panel, state = scene(players, own)
        own.xp, own.rank, players[2].rank, players[3].rank = 750, 2, 2, 4
        state.players = { players[1], players[2], own, players[3] }
        ranking:RefreshRankingOverlay()
        assert(panel.rows[2].rank:GetText() == "2" and panel.rows[3].rank:GetText() == "2"
            and panel.rows[4].rank:GetText() == "4" and panel.rows[2].player.id == "Bravo"
            and panel.rows[3].player == own and near(position(panel.rows[3]), 102),
            "shared competition ranks and stable tie order are authoritative before tied players finish moving")
        panel.rowAnimator:AdvanceFrame(0.7)
        own.level, own.xp, own.rank = 25, 80, 1
        players[1].rank, players[2].rank = 2, 3
        state.players = { own, players[1], players[2], players[3] }
        ranking:RefreshRankingOverlay()
        assert(panel.rows[1].player == own and panel.rows[1].rank:GetText() == "1"
            and panel.rows[1].level:GetText() == "25" and panel.rows[1].progress:GetText() == "8%"
            and near(panel.rows[1].progressFill:GetWidth(), 174 * 0.08)
            and not panel.rows[1].progressGain:IsShown() and near(position(panel.rows[1]), 68)
            and panel.rowAnimator.scripts.OnUpdate and not panel.xpAnimator.scripts.OnUpdate,
            "a level-up snaps its new XP baseline immediately while the player's ranking position still glides")
        panel.rowAnimator:AdvanceFrame(0.7)
        assert(near(position(panel.rows[1]), 0) and not panel.rowAnimator.scripts.OnUpdate,
            "level-up ranking motion also settles into its exact new slot")
    end

    do
        local players, own = four()
        local ranking, api, _, panel, state = scene(players, own)
        local function overtake()
            own.xp, own.rank, players[3].rank = 700, 3, 4
            state.players = { players[1], players[2], own, players[3] }
            ranking:RefreshRankingOverlay()
            panel.rowAnimator:AdvanceFrame(0.2)
        end
        overtake()
        panel.CloseButton:Click()
        assert(not panel:IsShown() and not panel.rowAnimator.scripts.OnUpdate
            and count(panel.rowMotion) == 0 and activeGhosts(panel) == 0,
            "closing ranking clears unfinished row motion and every outgoing decorative player")
        own.xp, own.rank, players[2].rank = 800, 2, 3
        state.players = { players[1], own, players[2], players[3] }
        ranking:Notify("ROSTER_CHANGED")
        assert(not panel:IsShown() and not panel.rowAnimator.scripts.OnUpdate,
            "reports cannot restart row motion on a dismissed overlay")
        assert(ranking:SetRankingEnabled(true))
        assert(near(position(panel.rows[2]), 34) and not panel.rowAnimator.scripts.OnUpdate,
            "reopening ranking snaps to the latest complete order instead of replaying missed moves")
        own.xp, own.rank, players[1].rank = 900, 1, 2
        state.players = { own, players[1], players[2], players[3] }
        ranking:RefreshRankingOverlay()
        panel.rowAnimator:AdvanceFrame(0.2)
        api.UIParent:Hide()
        assert(not panel:IsVisible() and not panel.rowAnimator.scripts.OnUpdate and activeGhosts(panel) == 0,
            "hiding the native interface stops row motion and clears outgoing ghosts")
        own.level, own.xp, own.rank = 23, 400, 4
        players[1].rank, players[2].rank, players[3].rank = 1, 2, 3
        state.players = { players[1], players[2], players[3], own }
        ranking:Notify("ROSTER_CHANGED")
        assert(not panel.rowAnimator.scripts.OnUpdate,
            "hidden-interface reports cannot restart the ranking animation driver")
        api.UIParent:Show()
        assert(panel:IsVisible() and near(position(panel.rows[4]), 102)
            and not panel.rowAnimator.scripts.OnUpdate,
            "restoring the interface uses the newest ranking baseline")
        own.level = 24
        overtake()
        own.xp, own.rank, players[2].rank = 800, 2, 3
        state.players = { players[1], own, players[2], players[3] }
        ranking:Notify("GROUP_CHANGED")
        assert(near(position(panel.rows[2]), 34) and not panel.rowAnimator.scripts.OnUpdate
            and activeGhosts(panel) == 0,
            "switching groups establishes fresh positions even when player identities overlap")
        own.xp, own.rank, players[1].rank = 900, 1, 2
        state.players = { own, players[1], players[2], players[3] }
        ranking:RefreshRankingOverlay()
        panel.rowAnimator:AdvanceFrame(0.2)
        api.IsShiftKeyDown = function() return true end
        panel.rows[1].scripts.OnDragStart(panel.rows[1], "LeftButton")
        assert(panel.moving and not panel.rowAnimator.scripts.OnUpdate and near(position(panel.rows[1]), 0),
            "starting a Shift drag settles unfinished row motion before moving the overlay")
        panel.rows[1].scripts.OnDragStop(panel.rows[1])
        state.switching = true
        ranking:Notify("GROUP_CHANGED")
        assert(count(panel.rowMotion) == 0 and activeGhosts(panel) == 0
            and not panel.rowAnimator.scripts.OnUpdate,
            "unavailable standings during group switching clear all row animation state")
    end
end

-- Real roster events update local XP immediately; quiet peers keep their rank using stale progress.
do
    local ranking, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    world:completeJoin(ranking:GetGroupDataChannelName(), 7)
    loadOverlay(ranking, api)
    assert(ranking:ReceivePlayerStatus("Alpha-TestRealm", {
        level = 24, xp = 400, xpMax = 1000, xpState = "known",
    }, api.GetServerTime(), 1))
    local requests, originalRequest = 0, ranking.RequestData
    ranking.RequestData = function(self, feature, ...)
        requests = requests + 1
        return originalRequest(self, feature, ...)
    end
    assert(ranking:SetRankingEnabled(true))
    local panel = ranking.rankingOverlay
    assert(panel.rows[1].player.id == "alpha-testrealm" and panel.rows[2].player.isSelf
        and panel.rows[2].progress:GetText() == "0%" and panel.scripts.OnUpdate,
        "production roster data reaches the overlay without requiring Content")
    world.xp = 250
    world.fire("PLAYER_XP_UPDATE", "player")
    assert(panel.rows[2].progress:GetText() == "25%",
        "the real XP event refreshes local progress immediately without waiting for the UI tick")
    world.now = world.now + 90
    panel.scripts.OnUpdate(panel, 1)
    assert(panel.rows[1].player.id == "alpha-testrealm" and panel.rows[1].rank:GetText() == "1"
        and panel.rows[1].progress:GetText() == "40%" and panel.rows[1].alpha == 0.65
        and panel.rows[2].player.isSelf
        and requests == 0,
        "contact expiry retains saved peer progress without requesting a snapshot")
    assert(ranking:ReceivePlayerStatus("Alpha-TestRealm", {
        level = 24, xp = 400, xpMax = 1000, xpState = "known",
    }, api.GetServerTime(), 2))
    assert(panel.rows[1].progress:GetText() == "40%" and panel.rows[1].alpha == 1,
        "a fresh valid report restores the row brightness without changing its percentage")
    api.UIParent:Hide()
    assert(panel:IsShown() and not panel:IsVisible() and not panel.scripts.OnUpdate,
        "hiding the native interface stops overlay refresh work without changing its preference")
    api.UIParent:Show()
    assert(panel:IsVisible() and panel.scripts.OnUpdate and ranking:GetRankingSettings().enabled,
        "restoring the interface resumes refreshes for the enabled overlay")
    panel.CloseButton:Click()
    assert(not panel.scripts.OnUpdate and not ranking:GetRankingSettings().enabled,
        "explicitly closing removes the visible-only timer")
end

-- Position receives update only the owned tooltip. XP, expiry and local map
-- changes still reach the visible overlay through their existing refresh paths.
do
    local ranking, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world.level = 24
    world:initialize()
    world:completeJoin(ranking:GetGroupDataChannelName(), 7)
    api.C_Map.GetMapInfo = function(map)
        return { name = map == 37 and "Elwynn Forest" or "Westfall" }
    end
    loadOverlay(ranking, api)
    assert(ranking:ReceivePlayerStatus("Friend-TestRealm", {
        level = 24, xp = 400, xpMax = 1000, xpState = "known",
    }, api.GetServerTime(), 1))
    assert(ranking:ReceivePosition("Friend-TestRealm", "2|P|" .. api.GetServerTime() .. "|37|30000|70000"))
    assert(ranking:SetRankingEnabled(true))
    local panel, tooltip = ranking.rankingOverlay, api.GameTooltip
    local first = panel.rows[1]
    first.scripts.OnEnter(first)
    assert(tooltip.lines[2] == "Elwynn Forest")
    local rankingReads, overviewReads, paints = 0, 0, 0
    local getRanking, getOverview, setRank = ranking.GetPlayerRanking, ranking.GetOverviewPlayers, first.rank.SetText
    ranking.GetPlayerRanking = function(self, ...)
        rankingReads = rankingReads + 1
        return getRanking(self, ...)
    end
    ranking.GetOverviewPlayers = function(self, ...)
        overviewReads = overviewReads + 1
        return getOverview(self, ...)
    end
    first.rank.SetText = function(self, ...)
        paints = paints + 1
        return setRank(self, ...)
    end
    for _ = 1, 20 do
        world.now = world.now + 1
        assert(ranking:ReceivePosition("Friend-TestRealm", "2|P|" .. api.GetServerTime() .. "|38|40000|60000"))
    end
    ranking:Notify("POSITION_CONTACT_CHANGED")
    assert(tooltip.lines[2] == "Westfall" and rankingReads == 0 and overviewReads == 0 and paints == 0,
        "Movement refreshes the owned location without rebuilding standings or repainting XP rows")
    assert(ranking:SetPositionSharing(false))
    assert(tooltip.lines[2] == "Position sharing is off" and rankingReads == 0,
        "The fast tooltip path must immediately respect the local sharing opt-out")
    assert(ranking:SetPositionSharing(true))
    assert(tooltip.lines[2] == "Westfall")
    assert(ranking:SetPositionRetention(false))
    world.now = world.now + 61
    ranking:PositionTick()
    assert(tooltip.lines[2] == "Unknown location" and rankingReads == 0,
        "Expiring a live-only peer must clear its hovered location without rebuilding XP standings")
    world.map = 38
    api.C_Map.GetBestMapForUnit = function() return world.map end
    panel.scripts.OnUpdate(panel, 1)
    assert(rankingReads == 1 and overviewReads == 1 and panel.rows[2].player.map == 38,
        "The visible tick still refreshes the local map and current contact metadata")
    world.xp = 500
    world.fire("PLAYER_XP_UPDATE", "player")
    assert(panel.rows[1].player.isSelf and panel.rows[1].progress:GetText() == "50%",
        "XP changes still rerank and repaint immediately after position-only updates")
end

-- Compact hover details show missing XP, location and offline-only contact age;
-- refreshed pooled rows retain their original privacy guards.
do
    local ranking, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    loadOverlay(ranking, api)
    local anchorOwners = {}
    api.GameTooltip_SetDefaultAnchor = function(tooltip, owner)
        assert(tooltip == api.GameTooltip, "global tooltip positioning receives the native tooltip")
        anchorOwners[#anchorOwners + 1] = owner
        tooltip:SetOwner(owner, "ANCHOR_CURSOR")
    end
    ranking.db.position.sharing = true
    local own = row("Self", 6, 24, 250, 1000, true)
    local players = {
        row("Alpha", 1, 30, 420, 1000), row("Bravo", 2, 29, 175, 2000),
        row("Charlie", 3, 28), row("Delta", 4, 27, 50, 1000),
        row("Echo", 5, 26, 50, 1000), own,
    }
    players[1].name, own.name = "Alpha-RemoteRealm", "Self-HomeRealm"
    players[1].map, players[1].positionAvailable = 37, true
    players[1].seenAt, players[1].positionStamp = api.GetServerTime(), api.GetServerTime() - 300
    players[1].xpUpdatedAt = api.GetServerTime() - 30
    players[2].map, players[2].positionAvailable = 38, false
    players[2].stale, players[2].xpStale, players[2].online = true, true, false
    players[2].seenAt, players[2].xpUpdatedAt = api.GetServerTime() - 120, api.GetServerTime() - 150
    players[2].positionStamp = api.GetServerTime() - 300
    players[4].sharing, players[4].map, players[4].online = false, 37, false
    players[4].seenAt = api.GetServerTime() - 60
    local lookups = {}
    api.C_Map.GetMapInfo = function(map)
        lookups[#lookups + 1] = map
        assert(map == 37 or map == 38, "hover must only resolve a map exposed by the roster")
        return { name = map == 37 and "Elwynn Forest" or "Westfall" }
    end
    local state = { players = players, own = own, connected = true, grouped = true }
    ranking.GetPlayerRanking = function() return state end
    assert(ranking:SetRankingEnabled(true))
    local panel, tooltip = ranking.rankingOverlay, api.GameTooltip
    local first = panel.rows[1]
    first.scripts.OnEnter(first)
    assert(tooltip:IsShown() and tooltip:IsOwned(first) and tooltip.text == "#1 - Alpha"
        and #tooltip.lines == 2 and tooltip.lines[1] == "Lv 30 - 58% (580 XP)"
        and tooltip.lines[2] == "Elwynn Forest" and #lookups == 1,
        "online hover uses the requested rank/name, missing XP and location without a contact age")
    assert(#anchorOwners == 1 and anchorOwners[1] == first and tooltip.anchor == "ANCHOR_CURSOR",
        "ranking player tooltips follow the global tooltip positioning hook")
    players[1].xp = 500
    ranking:RefreshRankingOverlay()
    assert(tooltip:IsShown() and tooltip:IsOwned(first) and #tooltip.lines == 2
        and tooltip.lines[1] == "Lv 30 - 50% (500 XP)",
        "hover refreshes missing XP for the same player identity")
    assert(#anchorOwners == 2 and anchorOwners[2] == first and tooltip.anchor == "ANCHOR_CURSOR",
        "live refresh preserves global tooltip positioning for the same player")
    players[1].xp, players[1].xpMax = 9999, 10000
    ranking:RefreshRankingOverlay()
    assert(tooltip.lines[1] == "Lv 30 - 0.1% (1 XP)",
        "rounding never describes a positive amount of missing XP as zero percent")
    local beforeOnlineMap = #lookups
    players[1].map = 38
    ranking:Notify("POSITIONS_CHANGED")
    assert(tooltip:IsShown() and #tooltip.lines == 2 and tooltip.lines[2] == "Westfall"
        and #lookups == beforeOnlineMap + 1,
        "online position changes update the location while still omitting a contact age")
    first.scripts.OnLeave(first)
    assert(not tooltip:IsShown(), "leaving a player dismisses their details")
    local stale = panel.rows[2]
    local beforeOffline = #lookups
    stale.scripts.OnEnter(stale)
    assert(tooltip.text == "#2 - Bravo" and #tooltip.lines == 2
        and tooltip.lines[1] == "Lv 29 - 91.3% (1825 XP)"
        and tooltip.lines[2] == "Westfall - 2m ago" and #lookups == beforeOffline + 1,
        "offline hover uses saved missing XP and combines the location with last contact")
    players[2].map = 37
    ranking:Notify("POSITIONS_CHANGED")
    assert(tooltip.lines[2] == "Elwynn Forest - 2m ago" and #tooltip.lines == 2,
        "a position change refreshes the offline location without extra labels or timestamps")
    local beforeLocalOff = #lookups
    ranking.db.position.sharing = false
    ranking:RefreshRankingOverlay()
    assert(tooltip.lines[2] == "Position sharing is off - 2m ago" and #lookups == beforeLocalOff,
        "turning local position sharing off hides cached peer locations without another map lookup")
    ranking.db.position.sharing = true
    local beforePrivate = #lookups
    panel.rows[4].scripts.OnEnter(panel.rows[4])
    assert(tooltip.lines[2] == "Not sharing - 1m ago" and #tooltip.lines == 2 and #lookups == beforePrivate,
        "a player who does not share position has no map lookup or previously hovered location leak")
    local maximum = panel.rows[3]
    maximum.scripts.OnEnter(maximum)
    assert(tooltip.text == "#3 - Charlie" and #tooltip.lines == 1
        and tooltip.lines[1] == "Unknown location" and #lookups == beforePrivate,
        "an online maximum-level tooltip contains its rank/name and location without level, XP or contact")
    players[3].online, players[3].map, players[3].seenAt = false, 38, api.GetServerTime() - 3600
    ranking:RefreshRankingOverlay()
    assert(tooltip.text == "#3 - Charlie" and #tooltip.lines == 1
        and tooltip.lines[1] == "Westfall - 1h ago",
        "an offline maximum-level tooltip adds only the combined location/contact line")
    players[3].map = nil
    ranking:RefreshRankingOverlay()
    assert(#tooltip.lines == 1 and tooltip.lines[1] == "Unknown location - 1h ago",
        "missing permitted position data has a compact location fallback")
    own.rank, own.xp, own.xpMax, own.xpState = nil, nil, nil, "unavailable"
    ranking:RefreshRankingOverlay()
    local beforeOwn = #lookups
    panel.ownRow.scripts.OnEnter(panel.ownRow)
    assert(tooltip.text == "#? - Self" and #tooltip.lines == 2
        and tooltip.lines[1] == "Lv 24 - Awaiting XP" and tooltip.lines[2] == "Unknown location"
        and #lookups == beforeOwn,
        "unranked local progress is explained with a location but no contact age")
    assert(anchorOwners[#anchorOwners] == panel.ownRow and tooltip:IsOwned(panel.ownRow)
        and tooltip.anchor == "ANCHOR_CURSOR", "the separate local row uses global tooltip positioning")
    own.level = nil
    ranking:RefreshRankingOverlay()
    assert(tooltip.lines[1] == "Lv ? - Awaiting XP" and #tooltip.lines == 2,
        "a missing level is shown without inventing an XP value")
    panel.ownRow.scripts.OnLeave(panel.ownRow)
    local beforeCloseHover = #anchorOwners
    panel.CloseButton.scripts.OnEnter(panel.CloseButton)
    panel.CloseButton.scripts.OnLeave(panel.CloseButton)
    assert(not tooltip:IsShown() and #anchorOwners == beforeCloseHover,
        "the overlay close button never shows a tooltip or calls global tooltip positioning")
    first.scripts.OnEnter(first)
    state.players[1], state.players[2] = state.players[2], state.players[1]
    ranking:RefreshRankingOverlay()
    assert(not tooltip:IsShown() and first.player.id == "Bravo",
        "reusing a pooled row for a new ranked player dismisses old hover details")
    first.scripts.OnEnter(first)
    state.players, state.own = {}, nil
    ranking:RefreshRankingOverlay()
    assert(not tooltip:IsShown() and not first:IsShown() and not first.player,
        "removing a hovered player clears the pooled row and its details")
end

-- Ranking targets current players without constructing Content; row reuse clears old interactions.
do
    local saved = settings(SECRET, false)
    local ranking, api, messages, _, world = loadAddon(saved, false)
    local invites, requests, mayInvite, grouped = {}, {}, true, false
    local shiftDown = false
    api.IsShiftKeyDown = function() return shiftDown end
    api.IsInGroup = function() return grouped end
    api.C_PartyInfo = {
        CanInvite = function() return mayInvite end,
        IsPartyFull = function() return false end,
        InviteUnit = function(name) invites[#invites + 1] = name end,
        RequestInviteFromUnit = function(name) requests[#requests + 1] = name end,
    }
    world:initialize()
    world:completeJoin(ranking:GetGroupDataChannelName(), 7)
    for index, name in ipairs({ "Alpha", "Bravo", "Charlie", "Delta", "Echo" }) do
        assert(ranking:ReceivePlayerStatus(name .. "-TestRealm", {
            level = 30 - index, xp = 400, xpMax = 1000, xpState = "known",
            inParty = name == "Bravo", canInvite = true, partyFull = false, sharing = true,
        }, api.GetServerTime(), 1))
    end
    loadOverlay(ranking, api)
    assert(ranking:SetRankingEnabled(true))
    local panel, tooltip = ranking.rankingOverlay, api.GameTooltip
    assert(not panel.actionMenu and not ranking.mainPanel and not ranking.contentPanel,
        "showing ranking does not allocate an action menu or the main interface")
    assert(panel.ownRow:IsShown() and panel.ownRow.player.isSelf
        and panel.ownRow.name:GetText() == ranking:GetPlayerDisplayName(panel.ownRow.player.name),
        "the production local row has the same plain display name as other players")
    panel.ownRow:Click("RightButton")
    assert(not panel.actionMenu and #invites == 0 and #requests == 0,
        "right clicking the local player cannot allocate a menu or perform party actions")
    local first = panel.rows[1]
    first:Click()
    assert(not panel.actionMenu and #invites == 0 and #requests == 0,
        "left clicks do not invoke addon player actions")
    local function openMenu(entry)
        entry:Click("RightButton")
        local menu = panel.actionMenu
        assert(menu and menu:IsShown() and menu.playerID == entry.player.id and menu.anchor == entry,
            "right clicking a player opens the action list for that row's current identity")
        return menu
    end
    first.scripts.OnEnter(first)
    local menu = openMenu(first)
    assert(not tooltip:IsShown() and menu.invite:IsEnabled()
        and not menu.request:IsEnabled() and not ranking.mainPanel and not ranking.contentPanel,
        "right clicking dismisses hover details and offers the roster's actions independently of Content")
    menu.invite:Click()
    assert(#invites == 1 and invites[1] == "Alpha-TestRealm" and not menu:IsShown(),
        "the ranking invite uses the production permission check and complete player name")
    menu = openMenu(first)
    world.level = 35
    world.fire("PLAYER_XP_UPDATE", "player")
    assert(first.player.isSelf and first.highlight:IsShown() and not menu:IsShown(),
        "recycling an actionable peer row for the local leader closes its previous action menu")
    first:Click("RightButton")
    assert(not menu:IsShown() and #invites == 1 and #requests == 0,
        "the recycled local leader cannot reopen player actions")
    world.level = 12
    world.fire("PLAYER_XP_UPDATE", "player")
    assert(first.player.id == "alpha-testrealm", "the pooled row returns to the peer after the local rank changes")
    menu = openMenu(first)
    first.scripts.OnEnter(first)
    assert(ranking:ReceivePlayerStatus("Bravo-TestRealm", {
        level = 31, xp = 400, xpMax = 1000, xpState = "known",
        inParty = true, canInvite = true, partyFull = false,
    }, api.GetServerTime(), 2))
    assert(first.player.id == "bravo-testrealm" and not menu:IsShown() and not tooltip:IsShown(),
        "a rank reorder closes menu and hover details before a row can target another player")
    -- Alpha is now the second leader. Contact expiry retains its rank but not permission.
    local alpha = panel.rows[2]
    menu = openMenu(alpha)
    world.now = world.now + 90
    panel.scripts.OnUpdate(panel, 1)
    assert(menu:IsShown() and not menu.invite:IsEnabled() and not menu.request:IsEnabled()
        and menu.invite.reason == "No recent contact with this player.",
        "offline players keep their ranking while current action eligibility becomes disabled")
    alpha.scripts.OnEnter(alpha)
    api.UIParent:Hide()
    assert(not menu:IsShown() and not tooltip:IsShown(), "hiding the native interface dismisses ranking interactions")
    api.UIParent:Show()
    menu = openMenu(panel.rows[2])
    panel.rows[2].scripts.OnEnter(panel.rows[2])
    shiftDown = true
    panel.rows[2].scripts.OnDragStart(panel.rows[2], "LeftButton")
    panel:SetPoint("TOPLEFT", api.UIParent, "TOPLEFT", 145, -75)
    assert(panel.moving and panel.dragHandle == panel.rows[2], "a player row owns its active Shift drag")
    assert(ranking:LeaveGroup())
    assert(not menu:IsShown() and not tooltip:IsShown() and not panel.rows[1]:IsShown()
        and not panel.moving and not panel.dragHandle
        and saved.ranking.position.point == "TOPLEFT" and saved.ranking.position.x == 145
        and saved.ranking.position.y == -75,
        "removing a dragged player after a group change stops and saves movement and clears old interactions")
    assert(not contains(messages, SECRET) and not contains(messages, OTHER_SECRET),
        "ranking action feedback never logs group credentials")
end

-- Shift movement saves account-wide placement without disabling player interaction.
do
    local saved = settings(SECRET, false)
    saved.ranking = { enabled = true, locked = true,
        position = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 140, y = -90, future = "keep" } }
    local ranking, api, _, _, world = loadAddon(saved, false)
    local shiftDown = false
    api.IsShiftKeyDown = function() return shiftDown end
    loadOverlay(ranking, api)
    assert(not ranking.rankingOverlay, "saved visibility waits for initialization and login")
    world:initialize()
    local panel = ranking.rankingOverlay
    assert(panel and panel:IsVisible() and placed(panel, api.UIParent, "TOPLEFT", "TOPLEFT", 140, -90)
        and panel.userPlaced == false and panel.mouseEnabled == false and panel.header.mouseEnabled
        and not panel.scripts.OnDragStart and not panel.scripts.OnDragStop,
        "login restores saved placement and enables Shift movement even with a legacy locked preference")
    local originalPosition = saved.ranking.position
    panel.header.scripts.OnDragStart(panel.header, "LeftButton")
    panel.header.scripts.OnDragStop(panel.header)
    assert(not panel.moving and saved.ranking.position == originalPosition and originalPosition.x == 140,
        "a drag without Shift neither moves the overlay nor changes its saved placement")
    shiftDown = true
    panel.header.scripts.OnDragStart(panel.header, "RightButton")
    assert(not panel.moving, "Shift-right-drag does not move the overlay")
    panel.rows[1].scripts.OnEnter(panel.rows[1])
    assert(api.GameTooltip:IsShown(), "a player tooltip is visible before Shift-dragging")
    panel.header.scripts.OnDragStart(panel.header, "LeftButton")
    assert(panel.moving and not api.GameTooltip:IsShown(), "Shift-dragging the header moves the overlay and clears visible help")
    panel:SetPoint("BOTTOMRIGHT", api.UIParent, "BOTTOMRIGHT", -120, 65)
    panel.header.scripts.OnDragStop(panel.header)
    local position = saved.ranking.position
    assert(position.point == "BOTTOMRIGHT" and position.relativePoint == "BOTTOMRIGHT"
        and position.x == -120 and position.y == 65 and position.future == "keep"
        and not position.relativeTo and not panel.moving and panel.userPlaced == false,
        "drag stop saves only an anchor and offsets while preserving unknown position fields")
    local restored, restoredAPI, _, _, restoredWorld = loadAddon(saved, false)
    restoredWorld:initialize()
    assert(not restored.rankingOverlay, "login without widget support safely defers overlay creation")
    loadOverlay(restored, restoredAPI)
    restored:RefreshRankingOverlay()
    assert(restored.rankingOverlay:IsVisible()
        and placed(restored.rankingOverlay, restoredAPI.UIParent, "BOTTOMRIGHT", "BOTTOMRIGHT", -120, 65),
        "an enabled overlay created after login restores its saved account-wide position")
end

-- Malformed anchors use a usable default; future-schema settings remain untouched.
do
    local damaged = settings(SECRET, false)
    damaged.ranking = { enabled = true, locked = false,
        position = { point = "BAD", relativePoint = "CENTER", x = 0 / 0, y = 4 } }
    local ranking, api, _, _, world = loadAddon(damaged, false)
    loadOverlay(ranking, api)
    world:initialize()
    local panel = ranking.rankingOverlay
    local point, owner, relative, x, y = panel:GetPoint()
    assert(owner == api.UIParent and point ~= "BAD" and relative ~= "BAD"
        and type(x) == "number" and x == x and type(y) == "number" and y == y,
        "damaged saved placement falls back to a valid finite native anchor")
    local future = settings(SECRET, false)
    future.schemaVersion = 99
    future.ranking = { enabled = true, locked = false, backgroundTransparency = 75,
        position = { point = "TOPRIGHT", relativePoint = "TOPRIGHT", x = -80, y = -70 }, future = "keep" }
    local originalPosition = future.ranking.position
    local readonly, readonlyAPI, _, _, readonlyWorld = loadAddon(future, false)
    readonlyAPI.IsShiftKeyDown = function() return true end
    loadOverlay(readonly, readonlyAPI)
    readonlyWorld:initialize()
    local readonlyPanel = readonly.rankingOverlay
    assert(readonly.savedDataReadOnly and readonlyPanel:IsVisible() and readonlyPanel.header.mouseEnabled
        and readonlyPanel.CloseButton:IsEnabled() and readonlyPanel.background.alpha == 0.25,
        "a future-schema profile permits viewing its saved transparency, temporary Shift movement and closing")
    readonlyPanel.CloseButton.scripts.OnEnter(readonlyPanel.CloseButton)
    assert(not readonlyAPI.GameTooltip:IsShown(), "read-only overlay close buttons also have no tooltip")
    -- A future profile intentionally has no active group. Exercise a stale row
    -- callback against the production action guard without reading its schema.
    local readonlyPlayer = row("Future", 1, 24, 200, 1000)
    readonly.GetPlayerRanking = function()
        return { players = { readonlyPlayer }, connected = false, grouped = true }
    end
    readonly:RefreshRankingOverlay()
    readonlyPanel.rowAnimator:AdvanceFrame(0.7)
    readonlyPanel.rows[1]:Click("RightButton")
    local readonlyMenu = readonlyPanel.actionMenu
    assert(readonlyMenu and readonlyMenu:IsShown(), "future-schema profiles permit viewing the action list")
    assert(not readonlyMenu.invite:IsEnabled() and not readonlyMenu.request:IsEnabled(),
        "read-only ranking party actions remain unavailable")
    readonly:OpenOptions("ranking")
    assert(not readonly.optionsPanel.rankingEnabled:IsEnabled()
        and not readonly.optionsPanel.rankingBurningEffect:IsEnabled()
        and not readonly.optionsPanel.rankingTransparencySlider:IsEnabled(),
        "future-schema Ranking Settings cannot change saved visibility, burning effects or transparency")
    readonlyPanel.header.scripts.OnDragStart(readonlyPanel.header, "LeftButton")
    assert(readonlyPanel.moving, "Shift movement remains available for a read-only profile")
    readonlyPanel:SetPoint("CENTER", readonlyAPI.UIParent, "CENTER", 20, 30)
    readonlyPanel.header.scripts.OnDragStop(readonlyPanel.header)
    readonlyPanel.CloseButton:Click()
    readonly:Notify("ROSTER_CHANGED")
    readonly:Notify("DATA_CHANGED")
    assert(not readonlyPanel:IsShown() and not readonlyPanel.scripts.OnUpdate
        and future.ranking.enabled and future.ranking.locked == false and future.ranking.future == "keep"
        and future.ranking.position == originalPosition and originalPosition.x == -80 and originalPosition.y == -70
        and future.schemaVersion == 99 and future.ranking.backgroundTransparency == 75,
        "read-only movement and session dismissal never write settings or allow notifications to reopen the overlay")
    local command = readonlyAPI.SlashCmdList.LOCKINTOOLS
    command("ranking on")
    assert(readonlyPanel:IsVisible()
        and placed(readonlyPanel, readonlyAPI.UIParent, "CENTER", "CENTER", 20, 30),
        "a read-only saved overlay can reopen for the session at its temporary position")
    command("ranking off")
    readonly:Notify("RANKING_CHANGED")
    assert(not readonlyPanel:IsShown() and future.ranking.enabled,
        "explicit read-only off stays dismissed without rewriting saved visibility")
    command("ranking")
    assert(readonlyPanel:IsVisible() and future.ranking.enabled and future.schemaVersion == 99,
        "the read-only toggle reopens the session overlay while preserving the future profile")
end

assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep ranking test environments isolated")
print("PASS: Player ranking overlay visibility, rendering, burned meters, burning effects, hover details, actions, updates and placement")
