-- Changing transparency must touch backing layers only, never reload the guide
-- or inherit opacity onto text, interactions, checkboxes or the resize controls.
local helpers = dofile("tests/support/helpers.lua")

local function Fixture()
    local world = { writes = 0, nativeCalls = 0, layouts = 0, hooks = 0, combat = false }
    local function Layer(alpha, kind)
        local layer = { alpha = alpha or 1, shown = true, kind = kind or "Texture" }
        function layer:GetAlpha() return self.alpha end
        function layer:SetAlpha(value) self.alpha = value; world.writes = world.writes + 1 end
        function layer:GetObjectType() return self.kind end
        function layer:GetVertexColor() return 0.1, 0.2, 0.3, self.alpha end
        function layer:SetVertexColor(_, _, _, alpha) self:SetAlpha(alpha) end
        function layer:Show() error("transparency must not change visibility") end
        function layer:Hide() error("transparency must not change visibility") end
        return layer
    end
    local function Panel()
        local frame = { alpha = 1, text = Layer(0.9, "FontString"), Center = Layer(0.8), TopEdge = Layer(0.7),
            BottomEdge = Layer(), LeftEdge = Layer(), RightEdge = Layer(), TopLeftCorner = Layer(),
            TopRightCorner = Layer(), BottomLeftCorner = Layer(), BottomRightCorner = Layer(),
            rxpBackground = Layer(0.9, "Frame"), rxpBorder = Layer(0.6, "Frame"), rxpShadow = Layer(0.5, "Frame") }
        function frame:GetAlpha() return self.alpha end
        function frame:SetAlpha() error("structural frame opacity would also hide text and controls") end
        frame.rxpShadow.shown = false
        return frame
    end
    local function Auxiliary()
        local frame = Panel()
        frame.title = Panel()
        function frame:UpdateVisuals() self.TopEdge = Layer(0.75) end
        return frame
    end
    local root = Panel()
    root.BottomFrame, root.GuideName, root.Footer = Panel(), Panel(), Panel()
    root.GuideName.bg, root.Footer.bg = Layer(0.6), Layer(0.7)
    root.GuideName.icon, root.GuideName.classIcon, root.Footer.icon = Layer(), Layer(), Layer()
    root.CurrentStepFrame = { framePool = { Panel() } }
    root.CurrentStepFrame.framePool[1].number = Panel()
    root.CurrentStepFrame.framePool[1].elements = { { button = Panel(), text = Layer(0.9, "FontString") } }
    root.ScrollChild = { framePool = { Panel() } }
    root.ScrollChild.framePool[1].number = Panel()
    function root.UpdateVisuals() root.BottomFrame.Center:SetAlpha(0.8) end
    local rxp = { settings = { profile = { activeTheme = "LockInTools" } }, RXPFrame = root,
        activeItemFrame = Auxiliary(), targeting = { activeTargetFrame = Auxiliary() }, v2 = { state = { player = {} } } }
    rxp.themes = { LockInTools = { background = { 0.1, 0.2, 0.3, 0.8 }, bottomFrameBG = { 0.1, 0.2, 0.3, 0.8 } } }
    rxp.activeTheme = rxp.themes.LockInTools
    rxp.v2.themes = { LockInTools = { backgroundColors = { common = { 0.1, 0.2, 0.3, 0.8 },
        guideWindow = { 0.1, 0.2, 0.3, 0.9 }, activeStepCheckbox = { 0.1, 0.2, 0.3, 0.8 } } } }
    function rxp:LoadActiveTheme() world.nativeCalls = world.nativeCalls + 1 end
    function rxp.RenderFrame() world.nativeCalls = world.nativeCalls + 1 end
    function rxp:ReloadTheme() world.nativeCalls = world.nativeCalls + 1 end
    function rxp:LoadGuide() world.nativeCalls = world.nativeCalls + 1 end
    function rxp:ReloadGuide() world.nativeCalls = world.nativeCalls + 1 end
    function rxp:RegisterTheme() world.nativeCalls = world.nativeCalls + 1 end
    function rxp.SetStep() world.nativeCalls = world.nativeCalls + 1 end
    function rxp.v2:GetGuideWindow()
        if not self.state.guideWindow then
            local steps = { items = {}, scroll = { scrollbg = Layer(0.8) } }
            function steps:SetRows(rows) self.items = rows; world.layouts = world.layouts + 1 end
            local window = { frame = Panel(), upperFrame = Panel(), guideStepsFrame = Panel(), guideNameFrame = Panel(),
                guideSteps = steps, banner = Layer(0.9), footerBackground = Layer(0.7), footerText = Layer(1, "FontString"),
                sizer = Layer(), closebutton = Layer(), title = Layer(1, "FontString") }
            function window:UpdateTheme() self.upperFrame.rxpShadow:SetAlpha(0.5) end
            self.state.guideWindow = window
        end
        return self.state.guideWindow
    end
    function rxp.v2:ReconcileActiveStepItems(player, items)
        self.state.player[player] = { activeStepItems = items,
            activeStepFrame = { frame = Panel() }, childContainer = { frame = Panel(), scrollbg = Layer(0.8) } }
        world.layouts = world.layouts + 1
    end
    local party = { frame = Panel(), content = Panel(), tabButtons = { Panel() },
        footer = { background = Layer(0.7), text = Layer(1, "FontString") } }
    function party.footer:GetRegions() return self.background, self.text end
    function party:RefreshTabTheme() self.tabButtons[1].rxpBackground:SetAlpha(0.9) end
    rxp.v2.state.activePartyStepFrame = party
    local track, thumb = Layer(), Layer()
    local addon = { db = { restedxpSkin = { enabled = true, backgroundTransparency = 0 } },
        restedxpScrollbarState = { [rxp] = { bars = { native = { track = track, thumb = thumb } } } } }
    local env = setmetatable({ InCombatLockdown = function() return world.combat end }, { __index = _G })
    env.hooksecurefunc = helpers.hooksecurefunc(env, function() world.hooks = world.hooks + 1 end)
    helpers.loadModule("RestedXPSkin.lua", addon, env)
    function addon:RefreshRestedXPScrollbar()
        self.restedxpScrollbarState[rxp].bars.late = { track = Layer(), thumb = Layer() }
    end
    return addon, rxp, world, Panel, track, thumb
end

local function Near(actual, expected)
    assert(math.abs(actual - expected) < 0.000001, "backing opacity must scale from its native alpha")
end

do
    local addon, rxp, world, _, track, thumb = Fixture()
    local root = rxp.RXPFrame
    addon:RefreshRestedXPTransparency(rxp)
    assert(world.writes == 0 and world.nativeCalls == 0 and world.layouts == 0,
        "zero transparency does not redraw, register themes, lay out rows or reload a guide")
    addon.db.restedxpSkin.backgroundTransparency = 50
    addon:RefreshRestedXPTransparency(rxp)
    Near(root.BottomFrame.Center:GetAlpha(), 0.4)
    Near(root.BottomFrame.TopEdge:GetAlpha(), 0.35)
    Near(root.BottomFrame.rxpBorder:GetAlpha(), 0.3)
    Near(root.BottomFrame.rxpShadow:GetAlpha(), 0.25)
    Near(root.GuideName.bg:GetAlpha(), 0.3)
    Near(root.Footer.bg:GetAlpha(), 0.35)
    Near(root.CurrentStepFrame.framePool[1].number.Center:GetAlpha(), 0.4)
    Near(root.ScrollChild.framePool[1].Center:GetAlpha(), 0.4)
    Near(rxp.activeItemFrame.title.TopEdge:GetAlpha(), 0.35)
    Near(rxp.targeting.activeTargetFrame.Center:GetAlpha(), 0.4)
    Near(track:GetAlpha(), 0.5)
    assert(thumb:GetAlpha() == 1 and root.Footer.icon:GetAlpha() == 1 and root.GuideName.icon:GetAlpha() == 1
        and root.GuideName.classIcon:GetAlpha() == 1 and root.BottomFrame.text:GetAlpha() == 0.9
        and root.CurrentStepFrame.framePool[1].elements[1].button.Center:GetAlpha() == 0.8,
        "text, interaction icons, resize controls, checkboxes and scroll thumbs stay readable")
    assert(not root.BottomFrame.rxpShadow.shown, "opacity must not reveal a deliberately hidden shadow")
    local writes, hooks = world.writes, world.hooks
    addon:RefreshRestedXPTransparency(rxp)
    assert(world.writes == writes and world.hooks == hooks, "repeated ticks neither compound alpha nor add hooks")
    addon.db.restedxpSkin.backgroundTransparency = 100
    addon:RefreshRestedXPTransparency(rxp)
    assert(root.BottomFrame.Center:GetAlpha() == 0 and root.BottomFrame.TopEdge:GetAlpha() == 0
        and root.BottomFrame.rxpShadow:GetAlpha() == 0 and root.GuideName.bg:GetAlpha() == 0 and track:GetAlpha() == 0)
    assert(root.BottomFrame.text:GetAlpha() == 0.9 and thumb:GetAlpha() == 1)
    addon.db.restedxpSkin.backgroundTransparency = 0
    addon:RefreshRestedXPTransparency(rxp)
    Near(root.BottomFrame.Center:GetAlpha(), 0.8)
    Near(root.BottomFrame.TopEdge:GetAlpha(), 0.7)
    Near(root.BottomFrame.rxpShadow:GetAlpha(), 0.5)
    Near(track:GetAlpha(), 1)
    assert(world.nativeCalls == 0 and world.layouts == 0, "dragging through opacity values never invokes guide or theme rebuilds")
end

do
    local addon, rxp, world, Panel = Fixture()
    addon.db.restedxpSkin.backgroundTransparency = 60
    addon:RefreshRestedXPTransparency(rxp)
    assert(not rxp.v2.state.guideWindow, "opacity must not acquire unused native windows")
    local window = rxp.v2:GetGuideWindow()
    Near(window.upperFrame.rxpBackground:GetAlpha(), 0.36)
    Near(window.guideNameFrame.rxpBorder:GetAlpha(), 0.24)
    Near(window.footerBackground:GetAlpha(), 0.28)
    Near(window.banner:GetAlpha(), 0.36)
    Near(window.guideSteps.scroll.scrollbg:GetAlpha(), 0.32)
    local row = { frame = Panel(), numberFrame = Panel(), text = { alpha = 1 } }
    window.guideSteps:SetRows({ row })
    Near(row.frame.Center:GetAlpha(), 0.32)
    Near(row.numberFrame.rxpShadow:GetAlpha(), 0.2)
    local item = { frame = Panel(), card = Panel(), title = Panel(), elementRows = { { button = Panel() } } }
    rxp.v2:ReconcileActiveStepItems("Player", { item })
    Near(item.card.rxpBorder:GetAlpha(), 0.24)
    Near(item.title.Center:GetAlpha(), 0.32)
    assert(item.elementRows[1].button.rxpBackground:GetAlpha() == 0.9)
    Near(rxp.v2.state.activePartyStepFrame.footer.background:GetAlpha(), 0.28)
    assert(rxp.v2.state.activePartyStepFrame.footer.text:GetAlpha() == 1)
    local layouts = world.layouts
    window:UpdateTheme()
    rxp.activeItemFrame:UpdateVisuals()
    Near(window.upperFrame.rxpShadow:GetAlpha(), 0.2)
    Near(rxp.activeItemFrame.TopEdge:GetAlpha(), 0.3)
    addon:RefreshRestedXPScrollbar(rxp)
    Near(addon.restedxpScrollbarState[rxp].bars.late.track:GetAlpha(), 0.4)
    assert(addon.restedxpScrollbarState[rxp].bars.late.thumb:GetAlpha() == 1)
    assert(world.nativeCalls == 0 and world.layouts == layouts, "native visual refresh hooks only reapply backing opacity")
end

do
    local addon, rxp, world = Fixture()
    addon.db.restedxpSkin.backgroundTransparency = 75
    world.combat = true
    addon:RefreshRestedXPTransparency(rxp)
    Near(rxp.RXPFrame.BottomFrame.rxpBorder:GetAlpha(), 0.15)
    assert(world.nativeCalls == 0 and world.layouts == 0, "combat allows visual layer edits without native protected refreshes")
    rxp.settings.profile.activeTheme = "RXP Blue"
    addon:RefreshRestedXPTransparency(rxp)
    Near(rxp.RXPFrame.BottomFrame.rxpBorder:GetAlpha(), 0.6)
    rxp.settings.profile.activeTheme = "LockInTools"
    addon:RefreshRestedXPTransparency(rxp)
    addon.savedDataReadOnly = true
    addon:RefreshRestedXPTransparency(rxp)
    Near(rxp.RXPFrame.BottomFrame.rxpBorder:GetAlpha(), 0.6)
    assert(addon.db.restedxpSkin.backgroundTransparency == 75, "read-only preferences restore native opacity without mutating saved values")
end

do
    local addon, rxp, world = Fixture()
    -- Some clients keep native backdrop pixels private. Their public color API
    -- must recover a stale zero fill without depending on an exposed Center.
    local panel, color = rxp.RXPFrame.BottomFrame, { 0.2, 0.3, 0.4, 0 }
    panel.Center = nil
    panel.rxpBackground, panel.rxpBorder, panel.rxpShadow = nil, nil, nil
    function panel:GetBackdropColor() return unpack(color) end
    function panel:SetBackdropColor(red, green, blue, alpha) color = { red, green, blue, alpha } end
    rxp.themes.LockInTools.background[4] = 0.98
    rxp.activeTheme = { background = { 0.1, 0.2, 0.3, 0 } }
    addon:RefreshRestedXPTransparency(rxp)
    Near(color[4], 0.98)
    addon.db.restedxpSkin.backgroundTransparency = 100
    addon:RefreshRestedXPTransparency(rxp)
    Near(color[4], 0)
    addon.db.restedxpSkin.backgroundTransparency = 50
    addon:RefreshRestedXPTransparency(rxp)
    Near(color[4], 0.49)
    assert(color[1] == 0.2 and color[2] == 0.3 and color[3] == 0.4)
    panel:SetBackdropColor(0.8, 0.7, 0.6, 1)
    Near(color[4], 0.5)
    assert(color[1] == 0.8 and color[2] == 0.7 and color[3] == 0.6, "native highlight RGB survives opacity application")
    addon.db.restedxpSkin.backgroundTransparency = 0
    addon:RefreshRestedXPTransparency(rxp)
    Near(color[4], 0.98)
    assert(world.nativeCalls == 0 and world.layouts == 0)
    addon.db.restedxpSkin.backgroundTransparency = 50
    addon:RefreshRestedXPTransparency(rxp)
    rxp.settings.profile.activeTheme = "RXP Blue"
    panel:SetBackdropColor(0.6, 0.5, 0.4, 0.3)
    addon:RefreshRestedXPTransparency(rxp)
    Near(color[4], 0.3)
    assert(color[1] == 0.6, "restoration preserves a newer native theme color")
end

do
    local addon, rxp, world = Fixture()
    local window = rxp.v2:GetGuideWindow()
    local function Pixel(alpha)
        local pixel = { alpha = alpha }
        function pixel:GetVertexColor() return 0.1, 0.2, 0.3, self.alpha end
        function pixel:SetVertexColor(_, _, _, value) self.alpha = value end
        function pixel:GetAlpha() return self.alpha end
        function pixel:SetAlpha(value) self.alpha = value end
        return pixel
    end
    local fill, header, border = Pixel(0), Pixel(0), Pixel(0)
    window.guideStepsFrame.rxpBackground.alpha = 0
    window.guideStepsFrame.rxpBackground.textures = { fill }
    window.guideNameFrame.rxpBackground.textures = { header }
    window.guideStepsFrame.rxpBorder.textures = { border }
    window.guideStepsFrame.rxpBackground.shown = false
    addon:RefreshRestedXPTransparency(rxp)
    Near(fill:GetAlpha(), 0.8)
    Near(window.guideStepsFrame.rxpBackground:GetAlpha(), 1)
    addon.db.restedxpSkin.backgroundTransparency = 100
    addon:RefreshRestedXPTransparency(rxp)
    Near(fill:GetAlpha(), 0.8)
    Near(window.guideStepsFrame.rxpBackground:GetAlpha(), 0)
    addon.db.restedxpSkin.backgroundTransparency = 50
    addon:RefreshRestedXPTransparency(rxp)
    Near(fill:GetAlpha(), 0.8)
    Near(header:GetAlpha(), 0.5)
    Near(window.guideStepsFrame.rxpBackground:GetAlpha(), 0.5)
    Near(fill:GetAlpha() * window.guideStepsFrame.rxpBackground:GetAlpha(), 0.4)
    Near(border:GetAlpha(), 0)
    assert(not window.guideStepsFrame.rxpBackground.shown, "repairing fill pixels never reveals a deliberately hidden backing")
    addon.db.restedxpSkin.backgroundTransparency = 0
    addon:RefreshRestedXPTransparency(rxp)
    Near(window.guideStepsFrame.rxpBackground:GetAlpha(), 1)
    Near(fill:GetAlpha() * window.guideStepsFrame.rxpBackground:GetAlpha(), 0.8)
    assert(world.nativeCalls == 0 and world.layouts == 0)
end

print("PASS: lightweight RestedXP backing/border/shadow opacity, native redraws and unchanged content")
