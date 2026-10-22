-- Chrome changes use native layout hooks, preserve the step viewport, and undo
-- only their own frame changes. They never replace scripts or secure actions.
local function Points(frame)
    local result = {}
    for index = 1, frame:GetNumPoints() do result[index] = { frame:GetPoint(index) } end
    return result
end

local function SamePoints(frame, expected)
    assert(frame:GetNumPoints() == #expected, "native anchor count must be restored")
    for index, point in ipairs(expected) do
        local actual = { frame:GetPoint(index) }
        for coordinate = 1, 5 do assert(actual[coordinate] == point[coordinate], "native anchors must be restored") end
    end
end

local function SameValues(actual, expected)
    for index, value in ipairs(expected) do assert(actual[index] == value, "native backdrop colors must be restored") end
end

local function NativeResize(grip, shell, rxp, world)
    assert(grip:IsVisible() and grip:IsMouseEnabled(), "the native resize handle remains reachable while chrome is hidden")
    assert(grip:GetScript("OnMouseDown") == grip.nativeDown and grip:GetScript("OnMouseUp") == grip.nativeUp,
        "chrome changes preserve the native resize scripts")
    rxp.settings.profile.lockFrames = true
    grip:GetScript("OnMouseDown")(grip, "LeftButton")
    assert(not shell.sizing, "the native frame lock still prevents resizing")
    rxp.settings.profile.lockFrames = false
    local starts, saves = world.resizeStarts or 0, world.resizeSaves or 0
    grip:GetScript("OnMouseDown")(grip, "LeftButton")
    assert(shell.sizing and world.resizeStarts == starts + 1, "the native handle starts resizing the guide shell")
    shell:SetHeight(shell:GetHeight() + 5)
    grip:GetScript("OnMouseUp")(grip, "LeftButton")
    assert(not shell.sizing and world.resizeSaves == saves + 1, "releasing the native handle finishes and saves resizing")
end

local function AttachedTodo(root)
    assert(root.CurrentStepFrame:IsVisible() and root.CurrentStepFrame.row:IsVisible(),
        "hiding chrome must preserve the todo list above the guide")
    for _, point in ipairs(Points(root.CurrentStepFrame)) do
        assert(point[2] == root.BottomFrame and point[2]:IsVisible() and point[5] == 2,
            "the top todo list anchors directly to visible content without a collapsed header")
    end
end

local function Fixture(v2Enabled)
    local world = { combat = false, hooks = 0, mutations = 0 }
    local function Frame(height, shown, parent)
        local frame = { height = height or 100, shown = shown ~= false, points = {}, scripts = {}, parent = parent, mouse = true,
            backdrop = { edgeFile = "native-border" }, backdropColor = { 0.1, 0.2, 0.3, 0.9 }, borderColor = { 0.4, 0.5, 0.6, 1 } }
        function frame:GetHeight() return self.height end
        function frame:SetHeight(value) self.height = value; world.mutations = world.mutations + 1 end
        function frame:IsShown() return self.shown end
        function frame:IsVisible() return self.shown and (not self.parent or self.parent:IsVisible()) end
        function frame:GetParent() return self.parent end
        function frame:SetParent(value) self.parent = value; world.mutations = world.mutations + 1 end
        function frame:Show() self.shown = true; world.mutations = world.mutations + 1 end
        function frame:Hide() self.shown = false; world.mutations = world.mutations + 1 end
        function frame:GetScript(name) return self.scripts[name] end
        function frame:SetScript(name, callback) self.scripts[name] = callback; world.mutations = world.mutations + 1 end
        function frame:EnableMouse(value) self.mouse = value; world.mutations = world.mutations + 1 end
        function frame:IsMouseEnabled() return self.mouse end
        function frame:GetBackdrop() return self.backdrop end
        function frame:SetBackdrop(value)
            self.backdrop, self.backdropColor, self.borderColor = value, { 1, 1, 1, 1 }, { 1, 1, 1, 1 }
            world.mutations = world.mutations + 1
        end
        function frame:GetBackdropColor()
            assert(self.backdrop, "a frame without a native backdrop has no native fill color")
            return unpack(self.backdropColor)
        end
        function frame:SetBackdropColor(...)
            assert(select("#", ...) == 4, "restoring a backdrop fill requires RGBA values")
            self.backdropColor = { ... }; world.mutations = world.mutations + 1
        end
        function frame:GetBackdropBorderColor()
            assert(self.backdrop, "a frame without a native backdrop has no native border color")
            return unpack(self.borderColor)
        end
        function frame:SetBackdropBorderColor(...)
            assert(select("#", ...) == 4, "restoring a backdrop border requires RGBA values")
            self.borderColor = { ... }; world.mutations = world.mutations + 1
        end
        function frame:StartSizing() self.sizing = true; world.resizeStarts = (world.resizeStarts or 0) + 1 end
        function frame:StopMovingOrSizing() self.sizing = false; world.resizeSaves = (world.resizeSaves or 0) + 1 end
        function frame:GetNumPoints() return #self.points end
        function frame:GetPoint(index) return unpack(self.points[index], 1, 5) end
        function frame:ClearAllPoints() self.points = {}; world.mutations = world.mutations + 1 end
        function frame:SetPoint(...) self.points[#self.points + 1] = { ... }; world.mutations = world.mutations + 1 end
        return frame
    end
    local rxp = { settings = { profile = { activeTheme = "LockInTools" } } }
    local root = Frame(125)
    rxp.RXPFrame = root
    root.BottomFrame, root.GuideName, root.Footer = Frame(108, true, root), Frame(35, true, root), Frame(20, true, root)
    root.BottomFrame:SetPoint("TOPLEFT", root, "TOPLEFT", 3, -3)
    root.BottomFrame:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", -3, 14)
    root.GuideName:SetPoint("BOTTOMLEFT", root.BottomFrame, "TOPLEFT", 0, -9)
    root.GuideName:SetPoint("BOTTOMRIGHT", root.BottomFrame, "TOPRIGHT", 0, -9)
    root.Footer:SetPoint("BOTTOMLEFT", root, "BOTTOMLEFT", 3, 0)
    root.Footer:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", -3, 0)
    root.GuideName.text, root.GuideName.bg = Frame(10, true, root.GuideName), Frame(35, true, root.GuideName)
    root.GuideName.icon, root.GuideName.classIcon = Frame(42, true, root.GuideName), Frame(24, true, root.GuideName)
    root.Footer.bg = Frame(20, true, root.Footer)
    root.Footer.text = Frame(10, true, root.GuideName) -- Native Footer.text belongs to GuideName.
    root.Footer.cog = Frame(18, true, root)
    root.Footer.icon = Frame(16, true, root.Footer)
    root.Footer.icon:SetPoint("BOTTOMRIGHT", root.Footer, "BOTTOMRIGHT", -1, 3)
    root.Footer.icon:SetScript("OnMouseDown", function()
        if not rxp.settings.profile.lockFrames then root:StartSizing("BOTTOMRIGHT") end
    end)
    root.Footer.icon:SetScript("OnMouseUp", function() root:StopMovingOrSizing() end)
    root.Footer.icon.nativeDown, root.Footer.icon.nativeUp = root.Footer.icon:GetScript("OnMouseDown"), root.Footer.icon:GetScript("OnMouseUp")
    root.CurrentStepFrame = Frame(80, true, root)
    root.CurrentStepFrame.anchor = "TOP"
    root.CurrentStepFrame.row = Frame(40, true, root.CurrentStepFrame)
    root.CurrentStepFrame:SetPoint("BOTTOMLEFT", root.GuideName, "TOPLEFT", 0, 2)
    root.CurrentStepFrame:SetPoint("BOTTOMRIGHT", root.GuideName, "TOPRIGHT", 0, 2)
    function root.UpdateVisuals() end
    function root.SetStepFrameAnchor()
        local step = root.CurrentStepFrame
        step:ClearAllPoints()
        if rxp.settings.profile.anchorOrientation == "bottom" then
            step.anchor = "BOTTOM"
            step:SetPoint("TOPLEFT", root, "BOTTOMLEFT", 3, 0)
            step:SetPoint("TOPRIGHT", root, "BOTTOMRIGHT", -3, 0)
        else
            step.anchor = "TOP"
            step:SetPoint("BOTTOMLEFT", root.GuideName, "TOPLEFT", 0, 2)
            step:SetPoint("BOTTOMRIGHT", root.GuideName, "TOPRIGHT", 0, 2)
        end
    end
    function rxp:LoadActiveTheme() end
    function rxp.RenderFrame() root.UpdateVisuals() end
    function rxp.SetupGuideWindow() end
    rxp.v2 = { state = {}, enabled = v2Enabled }
    function rxp.v2:IsGuideWindowEnabled() return self.enabled end
    local function Window()
        local window = { frame = Frame(270) }
        window.upperFrame, window.guideStepsFrame = Frame(36, true, window.frame), Frame(234, true, window.frame)
        window.footer, window.sizer = Frame(16, true, window.guideStepsFrame), Frame(12, true, window.guideStepsFrame)
        window.header = Frame(34, true, window.upperFrame)
        window.guideNameFrame = Frame(25, true, window.header)
        window.upperFrame.backdrop, window.header.backdrop, window.guideNameFrame.backdrop, window.footer.backdrop = nil, nil, nil, nil
        window.banner, window.iconLogo, window.classIcon = Frame(34, true, window.header), Frame(20, true, window.header), Frame(12, true, window.header)
        window.title, window.subtitle = Frame(10, true, window.guideNameFrame), Frame(10, true, window.guideNameFrame)
        window.settingsButton, window.guideSelectButton = Frame(20, true, window.header), Frame(20, true, window.header)
        window.closebutton = Frame(20, true, window.upperFrame)
        window.footerBackground, window.footerText = Frame(16, true, window.footer), Frame(10, true, window.footer)
        window.upperFrame.rxpShadow = Frame(36, true, window.upperFrame)
        window.upperFrame.rxpBackground, window.upperFrame.rxpBorder = Frame(36, true, window.upperFrame), Frame(36, true, window.upperFrame)
        window.guideStepsFrame.rxpBackground = Frame(234, true, window.guideStepsFrame)
        window.guideSteps = { frame = Frame(214, true, window.guideStepsFrame) }
        window.guideSteps.row = Frame(40, true, window.guideSteps.frame)
        window.sizer:SetPoint("BOTTOMRIGHT", window.guideStepsFrame, "BOTTOMRIGHT", 0, 0)
        window.sizer:SetScript("OnMouseDown", function()
            if not rxp.settings.profile.lockFrames then window.frame:StartSizing("BOTTOMRIGHT") end
        end)
        window.sizer:SetScript("OnMouseUp", function() window.frame:StopMovingOrSizing() end)
        window.sizer.nativeDown, window.sizer.nativeUp = window.sizer:GetScript("OnMouseDown"), window.sizer:GetScript("OnMouseUp")
        function window:UpdateFrameLayout()
            local headerHeight = self.snapshotEmpty and 34 or 36
            self.upperFrame:SetHeight(headerHeight)
            self.guideStepsFrame:ClearAllPoints()
            self.guideStepsFrame:SetPoint("TOPLEFT", self.upperFrame, "TOPLEFT", 0, -headerHeight)
            self.guideStepsFrame:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", 0, 0)
            self.guideSteps.frame:ClearAllPoints()
            self.guideSteps.frame:SetPoint("TOPLEFT", self.guideStepsFrame, "TOPLEFT", 2, -2)
            self.guideSteps.frame:SetPoint("BOTTOMRIGHT", self.guideStepsFrame, "BOTTOMRIGHT", -2, 16)
        end
        function window:SetSnapshot(empty)
            self.snapshotEmpty = empty
            self:UpdateFrameLayout()
            self.footer:Show()
            self.sizer:Show()
        end
        function window.guideSteps:UpdateScrollbar() world.scrollbars = (world.scrollbars or 0) + 1 end
        window:UpdateFrameLayout()
        return window
    end
    function rxp.v2:GetGuideWindow()
        if not self.state.guideWindow then self.state.guideWindow = Window() end
        return self.state.guideWindow
    end
    function rxp.v2:UpdateGuideWindow() self:GetGuideWindow():SetSnapshot(false) end
    local addon = { db = { restedxpSkin = { hideChrome = false } }, restedxpSkinState = {} }
    local env = setmetatable({ InCombatLockdown = function() return world.combat end }, { __index = _G })
    function env.hooksecurefunc(owner, method, callback)
        world.hooks = world.hooks + 1
        local original = owner[method]
        owner[method] = function(...)
            local result = { original(...) }
            callback(...)
            return unpack(result)
        end
    end
    local chunk = assert(loadfile("RestedXPSkin.lua"))
    setfenv(chunk, env)("LockInTools", addon)
    function addon:IsRestedXPChromeHidden() return self.db.restedxpSkin.hideChrome == true end
    return addon, rxp, world
end

do
    local addon, rxp, world = Fixture(false)
    local root = rxp.RXPFrame
    local headerPoints, contentPoints, stepPoints = Points(root.GuideName), Points(root.BottomFrame), Points(root.CurrentStepFrame)
    local resizePoints = Points(root.Footer.icon)
    local headerColor, headerBorder = { root.GuideName:GetBackdropColor() }, { root.GuideName:GetBackdropBorderColor() }
    local footerColor, footerBorder = { root.Footer:GetBackdropColor() }, { root.Footer:GetBackdropBorderColor() }
    addon:RefreshRestedXPChrome(rxp)
    assert(root.GuideName:IsShown() and root.Footer:IsShown(), "chrome is optional")
    addon.db.restedxpSkin.hideChrome = true
    addon:RefreshRestedXPChrome(rxp)
    assert(root.GuideName:IsShown() and root.GuideName:GetHeight() == 35 and root.Footer:IsShown(),
        "native header and footer containers retain their layout and parent visibility")
    for _, region in ipairs({ root.GuideName.text, root.GuideName.bg, root.GuideName.icon,
        root.GuideName.classIcon, root.Footer.bg, root.Footer.text, root.Footer.cog }) do
        assert(not region:IsVisible(), "header and footer decorations must hide")
    end
    assert(root.GuideName:GetBackdrop() == nil and root.Footer:GetBackdrop() == nil
        and not root.GuideName:IsMouseEnabled() and not root.Footer:IsMouseEnabled(),
        "empty chrome containers neither draw nor capture the mouse")
    SamePoints(root.GuideName, headerPoints)
    assert(root.BottomFrame.points[2][5] < contentPoints[2][5], "content must recover the footer space")
    AttachedTodo(root)
    assert(root.Footer.icon:GetParent() == root.Footer, "the resize handle retains its native parent")
    SamePoints(root.Footer.icon, resizePoints)
    NativeResize(root.Footer.icon, root, rxp, world)
    local hooks = world.hooks
    rxp.RenderFrame()
    root.SetStepFrameAnchor()
    addon:RefreshRestedXPChrome(rxp)
    assert(world.hooks == hooks and not root.GuideName.text:IsVisible(), "redraws keep chrome hidden without adding hooks")
    AttachedTodo(root)
    addon.db.restedxpSkin.hideChrome = false
    addon:RefreshRestedXPChrome(rxp)
    assert(root.GuideName:IsShown() and root.GuideName:GetHeight() == 35 and root.Footer:IsShown() and root.Footer.cog:IsShown())
    SamePoints(root.GuideName, headerPoints)
    SamePoints(root.BottomFrame, contentPoints)
    SamePoints(root.CurrentStepFrame, stepPoints)
    assert(root.GuideName.text:IsVisible() and root.Footer.bg:IsVisible() and root.Footer.text:IsVisible())
    assert(root.GuideName:GetBackdrop().edgeFile == "native-border" and root.Footer:GetBackdrop().edgeFile == "native-border"
        and root.GuideName:IsMouseEnabled() and root.Footer:IsMouseEnabled(), "opting out restores native backdrop and mouse settings")
    SameValues({ root.GuideName:GetBackdropColor() }, headerColor)
    SameValues({ root.GuideName:GetBackdropBorderColor() }, headerBorder)
    SameValues({ root.Footer:GetBackdropColor() }, footerColor)
    SameValues({ root.Footer:GetBackdropBorderColor() }, footerBorder)
    SamePoints(root.Footer.icon, resizePoints)
    NativeResize(root.Footer.icon, root, rxp, world)
end

do
    local addon, rxp = Fixture(false)
    local root = rxp.RXPFrame
    addon.db.restedxpSkin.hideChrome = true
    addon:RefreshRestedXPChrome(rxp)
    AttachedTodo(root)
    rxp.settings.profile.anchorOrientation = "bottom"
    root.SetStepFrameAnchor()
    local bottomPoints = Points(root.CurrentStepFrame)
    assert(bottomPoints[1][2] == root and bottomPoints[1][3] == "BOTTOMLEFT")
    addon.db.restedxpSkin.hideChrome = false
    addon:RefreshRestedXPChrome(rxp)
    SamePoints(root.CurrentStepFrame, bottomPoints)
    addon.db.restedxpSkin.hideChrome = true
    addon:RefreshRestedXPChrome(rxp)
    rxp.settings.profile.anchorOrientation = "top"
    root.SetStepFrameAnchor()
    AttachedTodo(root)
    addon.db.restedxpSkin.hideChrome = false
    addon:RefreshRestedXPChrome(rxp)
    assert(root.CurrentStepFrame.points[1][2] == root.GuideName
        and root.CurrentStepFrame.points[1][3] == "TOPLEFT", "restoration follows a native todo orientation change while chrome was hidden")
end

do
    local addon, rxp = Fixture(false)
    local root = rxp.RXPFrame
    rxp.settings.profile.anchorOrientation = "bottom"
    root.SetStepFrameAnchor()
    local stepPoints = Points(root.CurrentStepFrame)
    addon.db.restedxpSkin.hideChrome = true
    addon:RefreshRestedXPChrome(rxp)
    SamePoints(root.CurrentStepFrame, stepPoints)
    assert(root.CurrentStepFrame.row:IsVisible(), "the bottom todo orientation remains visible")
    root.SetStepFrameAnchor()
    SamePoints(root.CurrentStepFrame, stepPoints)
    addon.db.restedxpSkin.hideChrome = false
    addon:RefreshRestedXPChrome(rxp)
    SamePoints(root.CurrentStepFrame, stepPoints)
end

do
    local addon, rxp = Fixture(false)
    local root = rxp.RXPFrame
    root.Footer.cog:Hide()
    addon.db.restedxpSkin.hideChrome = true
    addon:RefreshRestedXPChrome(rxp)
    rxp.settings.profile.activeTheme = "RXP Blue"
    rxp:LoadActiveTheme()
    assert(root.GuideName.text:IsVisible() and root.Footer.bg:IsVisible() and not root.Footer.cog:IsShown(),
        "switching native themes restores original visibility without showing previously hidden controls")
end

do
    local addon, rxp, world = Fixture(true)
    addon.db.restedxpSkin.hideChrome = true
    addon:RefreshRestedXPChrome(rxp)
    assert(not rxp.v2.state.guideWindow, "chrome hooks must not acquire a disabled or uncreated widget")
    local window = rxp.v2:GetGuideWindow()
    assert(window.upperFrame:IsShown() and window.footer:IsShown() and window.sizer:IsVisible(),
        "V2 structural containers and its native resize handle remain visible")
    for _, region in ipairs({ window.banner, window.iconLogo, window.classIcon, window.title, window.subtitle,
        window.settingsButton, window.guideSelectButton, window.closebutton, window.footerBackground, window.footerText,
        window.upperFrame.rxpShadow, window.upperFrame.rxpBackground, window.upperFrame.rxpBorder }) do
        assert(not region:IsVisible(), "V2 header and footer decorations must hide")
    end
    assert(window.guideSteps.frame:IsVisible() and window.guideSteps.row:IsVisible() and window.guideStepsFrame.rxpBackground:IsVisible(),
        "V2 step content remains visible through its parent chain")
    assert(window.upperFrame:GetHeight() == 36 and window.footer:GetHeight() == 16 and window.frame:GetHeight() == 270,
        "native shell sizing metadata must remain intact")
    assert(window.guideStepsFrame.points[1][2] == window.frame and window.guideStepsFrame.points[1][5] == 0,
        "step content must start at the top of the outer frame")
    assert(window.guideSteps.frame.points[2][5] < 16 and world.scrollbars > 0,
        "the step viewport must recover the footer area and update scrolling")
    NativeResize(window.sizer, window.frame, rxp, world)
    window:SetSnapshot(true)
    assert(not window.footerText:IsVisible() and window.sizer:IsVisible(),
        "native snapshots keep decorations hidden and resizing available")
    addon.db.restedxpSkin.hideChrome = false
    addon:RefreshRestedXPChrome(rxp)
    assert(window.upperFrame:IsShown() and window.footer:IsShown() and window.sizer:IsShown())
    assert(window.guideStepsFrame.points[1][2] == window.upperFrame and window.guideStepsFrame.points[1][5] == -34,
        "restoration follows a native header height change while chrome was hidden")
    assert(window.guideSteps.frame.points[2][5] == 16, "restoration must return the native footer inset")
    assert(window.title:IsVisible() and window.footerText:IsVisible() and window.upperFrame.rxpShadow:IsVisible())
    assert(window.upperFrame:GetBackdrop() == nil and window.footer:GetBackdrop() == nil,
        "V2 restoration preserves custom decoration groups without inventing native backdrops or empty colors")
    NativeResize(window.sizer, window.frame, rxp, world)
end

do
    local addon, rxp, world = Fixture(false)
    world.combat = true
    addon:RefreshRestedXPChrome(rxp)
    assert(not addon.restedxpSkinState.pending,
        "unchanged native chrome must not advertise a pending combat change")
end

do
    local addon, rxp, world = Fixture(false)
    addon.db.restedxpSkin.hideChrome = true
    world.combat = true
    local mutations = world.mutations
    addon:RefreshRestedXPChrome(rxp)
    assert(world.mutations == mutations and addon.restedxpSkinState.pending,
        "combat callbacks must queue changes without touching frame geometry or visibility")
    world.combat = false
    addon:RefreshRestedXPChrome(rxp)
    assert(not rxp.RXPFrame.GuideName.text:IsVisible())
    addon.db.restedxpSkin.hideChrome = false
    world.combat = true
    mutations = world.mutations
    rxp:LoadActiveTheme()
    assert(world.mutations == mutations and not rxp.RXPFrame.GuideName.text:IsVisible(), "restoration also waits for combat to end")
    world.combat = false
    addon:RefreshRestedXPChrome(rxp)
    assert(rxp.RXPFrame.GuideName.text:IsVisible())
end

do
    local addon, rxp, world = Fixture(false)
    addon.db.restedxpSkin.hideChrome = true
    addon:RefreshRestedXPChrome(rxp)
    world.combat = true
    rxp.settings.profile.activeTheme = "RXP Blue"
    rxp:LoadActiveTheme()
    assert(addon.restedxpSkinState.pending and not rxp.RXPFrame.GuideName.text:IsVisible(),
        "switching away queues restoration of chrome still hidden during combat")
    world.combat = false
    addon:RefreshRestedXPChrome(rxp)
    assert(rxp.RXPFrame.GuideName.text:IsVisible() and rxp.RXPFrame.Footer.bg:IsVisible())
end

print("PASS: optional RestedXP chrome, native redraws, restoration and combat deferral")
