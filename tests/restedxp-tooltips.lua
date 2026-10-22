-- GameTooltip is shared with Blizzard and other addons; styling follows ownership.
local helpers = dofile("tests/support/helpers.lua")
local HookScript, RunScript = dofile("tests/support/scripts.lua")
local Copy, Equal = helpers.copy, helpers.equal

local function Points(frame)
    local points = {}
    for index = 1, frame:GetNumPoints() do points[index] = { frame:GetPoint(index) } end
    return points
end

local function Appearance(tooltip)
    local backdrop = tooltip:GetBackdrop()
    return { backdrop = Copy(backdrop), fill = backdrop and { tooltip:GetBackdropColor() },
        border = backdrop and { tooltip:GetBackdropBorderColor() } }
end

local function Content(tooltip)
    return { owner = tooltip:GetOwner(), anchor = tooltip.anchor, offsets = Copy(tooltip.offsets), points = Points(tooltip),
        lines = Copy(tooltip.lines), fonts = Copy(tooltip.fonts), shown = tooltip:IsShown(),
        width = tooltip:GetWidth(), height = tooltip:GetHeight(), alpha = tooltip:GetAlpha() }
end

local function Fixture(nilBackdrop, nineSlice)
    local world = { ownerWrites = 0, anchorWrites = 0, contentWrites = 0,
        hooks = 0, createdTooltips = 0, combat = false }
    local function Frame(parent, name)
        local frame = { parent = parent, name = name, forbidden = false, alpha = 0.7, shown = true, width = 240, height = 70 }
        function frame:GetParent() return self.parent end
        function frame:GetName() return self.name end
        function frame:IsForbidden() return self.forbidden end
        function frame:GetAlpha() return self.alpha end
        function frame:SetAlpha(value) self.alpha = value end
        function frame:IsShown() return self.shown end
        function frame:GetWidth() return self.width end
        function frame:GetHeight() return self.height end
        function frame:Show() self.shown = true end
        function frame:Hide() self.shown = false end
        return frame
    end
    local unrelated = Frame(nil, "CharacterFrame")
    local root = Frame(nil, "RXPFrame")
    root.CurrentStepFrame = Frame(root)
    local classicRow = Frame(root.CurrentStepFrame)
    classicRow.button = Frame(classicRow)
    root.CurrentStepFrame.framePool = { { elements = { classicRow } } }
    local itemFrame, targetFrame = Frame(nil), Frame(nil)
    local guideWindow = { frame = Frame(nil, "RXPV2GuideWindow") }
    local activeItem = { frame = Frame(nil), elementRows = {} }
    local party = { frame = Frame(nil) }
    local player = { activeStepItems = { activeItem }, activeStepFrame = { frame = Frame(nil) }, childContainer = { frame = Frame(nil) } }
    local row = Frame(activeItem.frame)
    row.button = Frame(row)
    row.button.rxpHoverFrame = Frame(row.button)
    activeItem.elementRows[1] = row
    local rxp = { settings = { profile = { activeTheme = "LockInTools" } }, RXPFrame = root,
        activeItemFrame = itemFrame, targeting = { activeTargetFrame = targetFrame },
        enabledFrames = { RXPV2GuideWindow = guideWindow.frame },
        v2 = { state = { guideWindow = guideWindow, activePartyStepFrame = party, player = { Self = player } } } }
    function rxp:LoadActiveTheme() end
    function rxp.RenderFrame() end
    function rxp.v2:UpdateGuideWindow() end
    function rxp.v2:ReconcileActiveStepItems() end
    local tooltip = Frame(nil, "GameTooltip")
    tooltip.backdrop = not nilBackdrop and { bgFile = "native-background", edgeFile = "native-border", edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 } } or nil
    tooltip.fill, tooltip.border = { 0.2, 0.3, 0.4, 0.6 }, { 0.8, 0.7, 0.6, 0.9 }
    tooltip.points, tooltip.lines, tooltip.offsets, tooltip.fonts, tooltip.regions = {}, {}, {}, { title = "NativeTitle", body = "NativeBody" }, {}
    tooltip.scripts, tooltip.scriptHooks, tooltip.shown = {}, {}, false
    if nineSlice then
        tooltip.NineSlice, tooltip.BackdropContainer, tooltip.TextureSliceBackground = Frame(tooltip), Frame(tooltip), Frame(tooltip)
    end
    function tooltip:GetBackdrop() return self.backdrop end
    function tooltip:SetBackdrop(value)
        self.backdrop, self.fill, self.border = Copy(value), { 1, 1, 1, 1 }, { 1, 1, 1, 1 }
    end
    function tooltip:GetBackdropColor() assert(self.backdrop, "no fill color exists without a native backdrop"); return unpack(self.fill) end
    function tooltip:SetBackdropColor(...)
        assert(select("#", ...) == 4, "backdrop restoration needs complete fill RGBA")
        self.fill = { ... }
    end
    function tooltip:GetBackdropBorderColor() assert(self.backdrop, "no border color exists without a native backdrop"); return unpack(self.border) end
    function tooltip:SetBackdropBorderColor(...)
        assert(select("#", ...) == 4, "backdrop restoration needs complete border RGBA")
        self.border = { ... }
    end
    function tooltip:CreateTexture(_, layer)
        local texture = { shown = true, alpha = 1, parent = self, layer = layer, points = {} }
        function texture:GetAlpha() return self.alpha end
        function texture:SetAlpha(value) self.alpha = value end
        function texture:IsShown() return self.shown end
        function texture:IsVisible() return self.shown and self.parent:IsShown() end
        function texture:Show() self.shown = true end
        function texture:Hide() self.shown = false end
        function texture:SetColorTexture(...) self.color = { ... } end
        function texture:SetTexture(path) self.path = path end
        function texture:SetVertexColor(...) self.color = { ... } end
        function texture:GetVertexColor() return unpack(self.color or { 1, 1, 1, 1 }) end
        function texture:SetPoint(...) self.points[#self.points + 1] = { ... } end
        function texture:SetAllPoints(frame) self.allPoints = frame or self.parent end
        function texture:SetHeight(value) self.height = value end
        function texture:SetWidth(value) self.width = value end
        self.regions[#self.regions + 1] = texture
        return texture
    end
    function tooltip:GetOwner() return self.owner end
    function tooltip:IsOwned(owner) return self.owner == owner end
    function tooltip:SetOwner(owner, anchor, ...)
        self.owner, self.anchor, self.offsets = owner, anchor, { ... }
        world.ownerWrites = world.ownerWrites + 1
    end
    function tooltip:GetNumPoints() return #self.points end
    function tooltip:GetPoint(index) return unpack(self.points[index], 1, 5) end
    function tooltip:ClearAllPoints() self.points = {}; world.anchorWrites = world.anchorWrites + 1 end
    function tooltip:SetPoint(...) self.points[#self.points + 1] = { ... }; world.anchorWrites = world.anchorWrites + 1 end
    function tooltip:ClearLines() self.lines = {}; world.contentWrites = world.contentWrites + 1 end
    function tooltip:SetText(...) self.lines = { { ... } }; world.contentWrites = world.contentWrites + 1 end
    function tooltip:AddLine(...) self.lines[#self.lines + 1] = { ... }; world.contentWrites = world.contentWrites + 1 end
    function tooltip:SetHyperlink(link) self.lines = { { link, "native hyperlink contents" } }; world.contentWrites = world.contentWrites + 1 end
    function tooltip:GetScript(name) return self.scripts[name] end
    function tooltip:SetScript(name, callback) self.scripts[name] = callback end
    tooltip.HookScript, tooltip.RunScript = HookScript, RunScript
    tooltip.scripts.OnShow = function() end
    tooltip.scripts.OnHide = function() end
    function tooltip:IsShown() return self.shown end
    function tooltip:Show() self.shown = true; self:RunScript("OnShow") end
    function tooltip:Hide() self.shown = false; self:RunScript("OnHide") end
    function tooltip:SetShown(value)
        self.shown = value == true
        self:RunScript(self.shown and "OnShow" or "OnHide")
    end
    local addon = { db = { restedxpSkin = { enabled = false } }, restedxpSkinState = {} }
    local worldPin, miniPin, unrelatedPin = Frame(nil), Frame(nil), Frame(nil)
    local pins = { worldmapPinRegistry = { [rxp] = { [worldPin] = true }, otherAddon = { [unrelatedPin] = true } },
        minimapPinRegistry = { [rxp] = { [miniPin] = true } } }
    local env = setmetatable({ GameTooltip = tooltip, InCombatLockdown = function() return world.combat end,
        LibStub = function(name, silent)
            assert(name == "HereBeDragons-Pins-2.0" and silent == true)
            return pins
        end,
        CreateFrame = function(kind)
            if kind == "GameTooltip" then world.createdTooltips = world.createdTooltips + 1; error("reuse native tooltip ownership") end
            return Frame()
        end,
    }, { __index = _G })
    env._G = env
    env.hooksecurefunc = helpers.hooksecurefunc(env, function() world.hooks = world.hooks + 1 end)
    helpers.loadModule("Theme.lua", addon, env)
    helpers.loadModule("RestedXPSkin.lua", addon, env)
    function world:Hover(owner)
        tooltip:SetOwner(owner, "ANCHOR_NONE", 4, 7)
        tooltip:ClearAllPoints()
        tooltip:SetPoint("BOTTOM", owner, "TOP", 0, 6)
        tooltip:ClearLines()
        tooltip:AddLine("Native title", 1, 0.8, 0.2)
        tooltip:AddLine("Native |Hquest:123|h[quest]|h text", 0.3, 0.7, 0.4, true)
        tooltip:Show()
    end
    world.classicOwner, world.skipOwner = classicRow.button, row.button.rxpHoverFrame
    world.itemOwner, world.targetOwner, world.headerOwner = Frame(itemFrame), Frame(targetFrame), Frame(guideWindow.frame)
    world.partyOwner, world.activeOwner, world.childOwner = Frame(party.frame), Frame(player.activeStepFrame.frame), Frame(player.childContainer.frame)
    world.worldPin, world.miniPin, world.unrelatedPin = worldPin, miniPin, unrelatedPin
    world.unrelated, world.falsePrefix = unrelated, Frame(nil, "RXPUnrelatedAddonButton")
    world.Frame = Frame
    return addon, rxp, world, tooltip
end

local function Styled(addon, tooltip)
    local palette = addon.Theme:GetPalette()
    local fill, borders = 0, 0
    for _, region in ipairs(tooltip.regions) do
        if region:IsVisible() and region:GetAlpha() > 0 then
            if region.layer == "BACKGROUND" then
                assert(Equal(region.color, palette.background), "tooltip fills use the LockInTools background")
                fill = fill + 1
            elseif region.layer == "BORDER" then
                assert(Equal(region.color, palette.border) and (region.width == 1 or region.height == 1),
                    "tooltip borders use a thin LockInTools edge")
                borders = borders + 1
            end
        end
    end
    assert(fill == 1 and borders == 4, "RestedXP tooltips draw one flat surface and four thin borders")
end

local function NoSkin(tooltip)
    for _, region in ipairs(tooltip.regions) do
        assert(not region:IsVisible() or region:GetAlpha() == 0, "shared tooltips cannot retain RestedXP artwork under another owner")
    end
end

do
    local addon, rxp, world, tooltip = Fixture()
    local native = Appearance(tooltip)
    local show, hide = tooltip:GetScript("OnShow"), tooltip:GetScript("OnHide")
    addon:RefreshRestedXPTooltips(rxp)
    world:Hover(world.classicOwner)
    assert(Equal(Appearance(tooltip), native), "tooltip styling defaults off")
    local content = Content(tooltip)
    local ownerWrites, anchors, contents = world.ownerWrites, world.anchorWrites, world.contentWrites
    addon.db.restedxpSkin.enabled = true
    addon:RefreshRestedXPTooltips(rxp)
    Styled(addon, tooltip)
    addon.db.restedxpSkin.backgroundTransparency = 100
    addon:RefreshRestedXPTooltips(rxp)
    Styled(addon, tooltip)
    assert(Equal(Content(tooltip), content) and world.ownerWrites == ownerWrites
        and world.anchorWrites == anchors and world.contentWrites == contents,
        "styling preserves native tooltip ownership, position, text, colors and fonts")
    assert(tooltip:GetScript("OnShow") == show and tooltip:GetScript("OnHide") == hide and world.createdTooltips == 0,
        "styling reuses the native tooltip and preserves its scripts")
    local hooks = world.hooks
    addon:RefreshRestedXPTooltips(rxp)
    assert(world.hooks == hooks, "repeated refreshes do not add duplicate tooltip observers")
    tooltip:SetOwner(world.unrelated, "ANCHOR_RIGHT")
    assert(Equal(Appearance(tooltip), native), "ownership changes restore the shared tooltip before another UI uses it")
    NoSkin(tooltip)
    world:Hover(world.falsePrefix)
    assert(Equal(Appearance(tooltip), native), "an unrelated frame name beginning with RXP cannot claim the shared skin")
    NoSkin(tooltip)
    world:Hover(world.skipOwner)
    Styled(addon, tooltip)
    tooltip:Hide()
    assert(Equal(Appearance(tooltip), native), "hiding an RXP tooltip restores the shared native backdrop")
    for _, owner in ipairs({ world.classicOwner, world.skipOwner, world.itemOwner, world.targetOwner, world.headerOwner,
        world.partyOwner, world.activeOwner, world.childOwner, world.worldPin, world.miniPin }) do
        world:Hover(owner)
        Styled(addon, tooltip)
        local savedContent = Content(tooltip)
        addon.db.restedxpSkin.enabled = false
        addon:RefreshRestedXPTooltips(rxp)
        assert(Equal(Appearance(tooltip), native) and Equal(Content(tooltip), savedContent), "opting out restores all supported native tooltip owners")
        NoSkin(tooltip)
        addon.db.restedxpSkin.enabled = true
    end
    world:Hover(world.unrelatedPin)
    assert(Equal(Appearance(tooltip), native), "map-pin registration by another addon cannot claim the RestedXP tooltip style")
    NoSkin(tooltip)
    world:Hover(world.classicOwner)
    rxp.settings.profile.activeTheme = "Custom"
    rxp:LoadActiveTheme()
    assert(Equal(Appearance(tooltip), native), "choosing another native theme restores the shared tooltip")
    NoSkin(tooltip)
end

do
    local addon, rxp, world, tooltip = Fixture(false, true)
    addon.db.restedxpSkin.enabled = true
    local native = Appearance(tooltip)
    local groups = { tooltip.NineSlice, tooltip.BackdropContainer, tooltip.TextureSliceBackground }
    local alphas = {}
    for index, group in ipairs(groups) do alphas[index] = group:GetAlpha() end
    addon:RefreshRestedXPTooltips(rxp)
    world:Hover(world.headerOwner)
    Styled(addon, tooltip)
    for _, group in ipairs(groups) do assert(group:GetAlpha() == 0, "known native tooltip decoration groups are suppressed") end
    tooltip:SetOwner(world.unrelated, "ANCHOR_RIGHT")
    NoSkin(tooltip)
    for index, group in ipairs(groups) do assert(group:GetAlpha() == alphas[index], "shared native tooltip decoration alpha restores") end
    assert(Equal(Appearance(tooltip), native))
end

do
    local addon, rxp, world, tooltip = Fixture()
    addon.db.restedxpSkin.enabled = true
    addon:RefreshRestedXPTooltips(rxp)
    world:Hover(world.classicOwner)
    tooltip:Hide()
    tooltip:SetBackdrop({ bgFile = "later-native-background", edgeFile = "later-native-border", edgeSize = 9 })
    tooltip:SetBackdropColor(0.1, 0.2, 0.3, 0.7)
    tooltip:SetBackdropBorderColor(0.6, 0.5, 0.4, 0.8)
    local later = Appearance(tooltip)
    world:Hover(world.unrelated)
    assert(Equal(Appearance(tooltip), later))
    world:Hover(world.classicOwner)
    Styled(addon, tooltip)
    tooltip:Hide()
    assert(Equal(Appearance(tooltip), later), "each ownership cycle preserves the current native tooltip appearance")
end

do
    local addon, rxp, world, tooltip = Fixture()
    addon.db.restedxpSkin.enabled = true
    addon:RefreshRestedXPTooltips(rxp)
    world:Hover(world.classicOwner)
    local content = Content(tooltip)
    tooltip:SetBackdrop({ bgFile = "native-redraw-background", edgeFile = "native-redraw-border", edgeSize = 7 })
    tooltip:SetBackdropColor(0.3, 0.2, 0.1, 0.6)
    tooltip:SetBackdropBorderColor(0.4, 0.5, 0.6, 0.7)
    Styled(addon, tooltip)
    assert(Equal(Content(tooltip), content), "native backdrop redraws retain tooltip contents and placement")
    tooltip:Hide()
    local restored = Appearance(tooltip)
    assert(restored.backdrop.edgeFile == "native-redraw-border" and Equal(restored.fill, { 0.3, 0.2, 0.1, 0.6 })
        and Equal(restored.border, { 0.4, 0.5, 0.6, 0.7 }), "restoration preserves the latest native backdrop and color intent")
end

do
    local addon, rxp, world, tooltip = Fixture(true)
    addon.db.restedxpSkin.enabled = true
    addon:RefreshRestedXPTooltips(rxp)
    world:Hover(world.classicOwner)
    Styled(addon, tooltip)
    tooltip:Hide()
    assert(tooltip:GetBackdrop() == nil, "a tooltip without an original backdrop restores nil without empty color writes")
end

do
    local addon, rxp, world, tooltip = Fixture()
    addon.db.restedxpSkin.enabled = true
    addon:RefreshRestedXPTooltips(rxp)
    tooltip:SetOwner(world.classicOwner, "ANCHOR_RIGHT")
    tooltip:SetText("Native implicit-show text", 0.8, 0.7, 0.6)
    tooltip:SetShown(true)
    Styled(addon, tooltip)
    tooltip:SetBackdrop(nil)
    Styled(addon, tooltip)
    tooltip:SetShown(false)
    assert(tooltip:GetBackdrop() == nil, "a native backdrop clear while styled remains the latest restoration intent")
    NoSkin(tooltip)
end

do
    local addon, rxp, world, tooltip = Fixture()
    addon.db.restedxpSkin.enabled, addon.savedDataReadOnly = true, true
    local native = Appearance(tooltip)
    addon:RefreshRestedXPTooltips(rxp)
    world:Hover(world.classicOwner)
    assert(Equal(Appearance(tooltip), native), "newer-schema read-only preferences do not style shared tooltips")
    addon.savedDataReadOnly = false
    addon:RefreshRestedXPTooltips(rxp)
    Styled(addon, tooltip)
    addon.savedDataReadOnly = true
    addon:RefreshRestedXPTooltips(rxp)
    assert(Equal(Appearance(tooltip), native), "read-only state also restores an already styled shared tooltip")
    NoSkin(tooltip)
end

do
    local addon, rxp, world, tooltip = Fixture()
    local native = Appearance(tooltip)
    addon.db.restedxpSkin.enabled = true
    world.combat = true
    world:Hover(world.classicOwner)
    addon:RefreshRestedXPTooltips(rxp)
    assert(#tooltip.regions == 0 and Equal(Appearance(tooltip), native) and addon.restedxpSkinState.pending,
        "combat defers first-time tooltip artwork creation")
    world.combat = false
    addon:RefreshRestedXPTooltips(rxp)
    Styled(addon, tooltip)
    world.combat, addon.db.restedxpSkin.enabled = true, false
    addon:RefreshRestedXPTooltips(rxp)
    assert(Equal(Appearance(tooltip), native), "existing ordinary tooltip artwork restores safely during combat")
    NoSkin(tooltip)
end

do
    local addon, rxp, world, tooltip = Fixture()
    addon.db.restedxpSkin.enabled = true
    local owner = world.Frame(nil)
    local panel = world.Frame(nil, "DropDownList1")
    panel.dropdown = owner
    local row = world.Frame(panel)
    addon.restedxpMenuState = { [rxp] = { owners = { [owner] = true }, panels = { [panel] = { frame = panel } } } }
    addon:RefreshRestedXPTooltips(rxp)
    world:Hover(row)
    Styled(addon, tooltip)
    panel.dropdown = world.unrelated
    world:Hover(row)
    NoSkin(tooltip)
    panel.dropdown = owner
    panel:Hide()
    world:Hover(row)
    NoSkin(tooltip)
    panel:Show()
    world:Hover(row)
    Styled(addon, tooltip)
    assert(tooltip:GetOwner() == row, "menu row tooltips keep their native owner while appearance follows the exact visible RXP menu")
end

print("PASS: RestedXP tooltip ownership, native content preservation and shared appearance restoration")
