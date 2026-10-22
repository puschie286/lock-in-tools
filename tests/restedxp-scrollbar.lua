-- Native sliders and input callbacks remain responsible for all scrolling.
local helpers = dofile("tests/support/helpers.lua")
local HookScript, RunScript = dofile("tests/support/scripts.lua")

local function Same(actual, expected)
    if type(actual) ~= "table" or type(expected) ~= "table" then return actual == expected end
    if #actual ~= #expected then return false end
    for index = 1, #actual do if actual[index] ~= expected[index] then return false end end
    return true
end

local function Fixture(v2Enabled)
    local world = { combat = false, mutations = 0, hooks = 0, changes = 0, sliderLayouts = 0, containerLayouts = 0,
        nativeDown = 0, nativeUp = 0, guideMenus = 0, shownMenus = 0, settingsMenus = 0, guideSelections = 0 }
    local function Region(texture)
        local region = { texture = texture, coordinates = { 0.2, 0.8, 0.2, 0.8 }, color = { 0.8, 0.7, 0.6, 0.9 },
            width = 16, height = 16, alpha = 0.8, desaturated = true, shown = true }
        function region:GetObjectType() return "Texture" end
        function region:GetTexture() return self.texture end
        function region:SetTexture(value) self.texture = value; world.mutations = world.mutations + 1 end
        function region:GetTexCoord() return unpack(self.coordinates) end
        function region:SetTexCoord(...) self.coordinates = { ... }; world.mutations = world.mutations + 1 end
        function region:GetVertexColor() return unpack(self.color) end
        function region:SetVertexColor(...) self.color = { ... }; world.mutations = world.mutations + 1 end
        function region:GetWidth() return self.width end
        function region:SetWidth(value) self.width = value; world.mutations = world.mutations + 1 end
        function region:GetHeight() return self.height end
        function region:SetHeight(value) self.height = value; world.mutations = world.mutations + 1 end
        function region:GetAlpha() return self.alpha end
        function region:SetAlpha(value) self.alpha = value; world.mutations = world.mutations + 1 end
        function region:IsDesaturated() return self.desaturated end
        function region:SetDesaturated(value) self.desaturated = value; world.mutations = world.mutations + 1 end
        function region:IsShown() return self.shown end
        function region:Show() self.shown = true; world.mutations = world.mutations + 1 end
        function region:Hide() self.shown = false; world.mutations = world.mutations + 1 end
        function region:SetAllPoints(frame) self.anchor = frame; world.mutations = world.mutations + 1 end
        function region:SetColorTexture(...) self.fill = { ... }; world.mutations = world.mutations + 1 end
        return region
    end
    local function Button(slider, amount)
        local button = { shown = true, enabled = true, scripts = {}, scriptHooks = {} }
        local function Visibility(self, value)
            local wasShown = self.shown
            self.shown = value == true
            world.mutations = world.mutations + 1
            if self.shown and not wasShown then RunScript(self, "OnShow") end
        end
        function button:IsShown() return self.shown end
        function button:IsProtected() return false end
        function button:Show() Visibility(self, true) end
        -- Engine/native visibility changes need not call the public Show method.
        function button:SetShown(value) Visibility(self, value) end
        function button:NativeShow() Visibility(self, true) end -- C-side OnShow, with no public Show/SetShown call.
        function button:Hide() self.shown = false; world.mutations = world.mutations + 1 end
        function button:IsEnabled() return self.enabled end
        function button:SetEnabled(value)
            local wasEnabled = self.enabled
            self.enabled = value == true
            if self.enabled ~= wasEnabled then RunScript(self, self.enabled and "OnEnable" or "OnDisable") end
        end
        function button:Enable() self:SetEnabled(true) end
        function button:Disable() self:SetEnabled(false) end
        function button:GetScript(name) return self.scripts[name] end
        button.HookScript = HookScript
        button.scripts.OnClick = function() slider:SetValue(slider:GetValue() + amount) end
        button.scripts.OnShow = function() world.arrowShows = (world.arrowShows or 0) + 1 end
        return button
    end
    local function VisibilityFrame(parent)
        local frame = { parent = parent, shown = true, scripts = {}, scriptHooks = {}, points = {}, width = 220, height = 180 }
        function frame:GetParent() return self.parent end
        function frame:IsShown() return self.shown end
        function frame:IsVisible() return self.shown and (not self.parent or self.parent:IsVisible()) end
        function frame:IsProtected() return false end
        function frame:GetWidth() return self.width end
        function frame:GetHeight() return self.height end
        function frame:SetWidth(value) self.width = value; world.containerLayouts = world.containerLayouts + 1 end
        function frame:SetHeight(value) self.height = value; world.containerLayouts = world.containerLayouts + 1 end
        function frame:GetNumPoints() return #self.points end
        function frame:GetPoint(index) return unpack(self.points[index], 1, 5) end
        function frame:ClearAllPoints() self.points = {}; world.containerLayouts = world.containerLayouts + 1 end
        function frame:SetPoint(...) self.points[#self.points + 1] = { ... }; world.containerLayouts = world.containerLayouts + 1 end
        function frame:GetScript(name) return self.scripts[name] end
        frame.HookScript, frame.RunScript = HookScript, RunScript
        local function Visibility(self, value)
            local previous = self.shown
            self.shown = value == true
            if previous ~= self.shown then self:RunScript(self.shown and "OnShow" or "OnHide") end
        end
        function frame:Show() Visibility(self, true) end
        function frame:Hide() Visibility(self, false) end
        function frame:SetShown(value) Visibility(self, value) end
        function frame:NativeHide() Visibility(self, false) end
        return frame
    end
    local function Scroll()
        local widget
        local scrollRoot = VisibilityFrame()
        local viewport = VisibilityFrame(scrollRoot)
        local slider = { width = 16, height = 180, value = 275, low = 0, high = 1000, points = {}, scripts = {}, scriptHooks = {}, shown = true }
        function slider:GetWidth() return self.width end
        function slider:SetWidth(value) self.width = value; world.mutations = world.mutations + 1; world.sliderLayouts = world.sliderLayouts + 1 end
        function slider:GetHeight() return self.height end
        function slider:GetNumPoints() return #self.points end
        function slider:GetPoint(index) return unpack(self.points[index], 1, 5) end
        function slider:ClearAllPoints() self.points = {}; world.mutations = world.mutations + 1; world.sliderLayouts = world.sliderLayouts + 1 end
        function slider:SetPoint(...) self.points[#self.points + 1] = { ... }; world.mutations = world.mutations + 1; world.sliderLayouts = world.sliderLayouts + 1 end
        function slider:GetValue() return self.value end
        function slider:SetValue(value)
            self.value = math.max(self.low, math.min(self.high, value))
            self.scripts.OnValueChanged(self, self.value)
        end
        function slider:GetMinMaxValues() return self.low, self.high end
        function slider:SetMinMaxValues(low, high) self.low, self.high = low, high end
        function slider:GetScript(name) return self.scripts[name] end
        slider.HookScript, slider.RunScript = HookScript, RunScript
        function slider:IsShown() return self.shown end
        function slider:IsVisible() return self.shown and viewport:IsVisible() end
        function slider:GetParent() return viewport end
        function slider:IsProtected() return false end
        local function Visibility(self, shown)
            local previous = self.shown
            self.shown = shown == true
            world.mutations = world.mutations + 1
            if previous ~= self.shown then self:RunScript(self.shown and "OnShow" or "OnHide") end
        end
        function slider:Show() Visibility(self, true) end
        function slider:Hide() Visibility(self, false) end
        function slider:SetShown(value) Visibility(self, value) end
        function slider:NativeHide() Visibility(self, false) end -- Engine OnHide, no public Hide/SetShown call.
        slider.thumb = Region("native-thumb")
        slider.ornament = Region("native-ornament")
        slider.regions = { slider.thumb, slider.ornament }
        function slider:GetThumbTexture() return self.thumb end
        function slider:SetThumbTexture(path) self.thumb:SetTexture(path) end
        function slider:GetRegions() return unpack(self.regions) end
        function slider:CreateTexture()
            local texture = Region(nil)
            texture.alpha = 1
            self.regions[#self.regions + 1] = texture
            return texture
        end
        slider.ScrollUpButton, slider.ScrollDownButton = Button(slider, -45), Button(slider, 45)
        slider:SetPoint("TOPLEFT", viewport, "TOPRIGHT", 2, -17)
        slider:SetPoint("BOTTOMLEFT", viewport, "BOTTOMRIGHT", 2, 17)
        slider.scripts.OnValueChanged = function(_, value)
            world.changes = world.changes + 1
            viewport.offset = widget.noScroll and 0 or value
            slider.ScrollUpButton:SetEnabled(value > slider.low)
            slider.ScrollDownButton:SetEnabled(value < slider.high)
            slider.ScrollUpButton:SetShown(true)
            slider.ScrollDownButton:SetShown(true)
        end
        slider.scripts.OnMouseDown = function(_, button)
            world.nativeDown = world.nativeDown + 1
            if button == "LeftButton" then slider.dragging = true; slider:SetValue(slider:GetValue() + 100) end
        end
        slider.scripts.OnMouseUp = function(_, button)
            world.nativeUp = world.nativeUp + 1
            if button == "LeftButton" then slider.dragging = false end
        end
        slider.scripts.OnShow = function() end
        slider.scripts.OnHide = function() world.sliderHides = (world.sliderHides or 0) + 1 end
        viewport.scripts.OnMouseWheel = function(_, direction)
            if not widget.noScroll then slider:SetValue(slider:GetValue() - direction * 45) end
        end
        widget = { frame = scrollRoot, content = VisibilityFrame(viewport), scrollframe = viewport, scrollbar = slider, scrollbg = Region("native-track") }
        function widget:RefreshVisuals()
            self.scrollbar.thumb:SetDesaturated(false)
            self.scrollbar.thumb:SetVertexColor(1, 1, 1, 1)
            self.scrollbg:SetColorTexture(0.1, 0.1, 0.1, 1)
        end
        function widget:FixScroll()
            if self.noScroll then
                self.scrollBarShown = nil
                self.scrollbar:SetValue(0)
                self.scrollbar:Hide()
            else
                self.scrollBarShown = true
                self.scrollbar:Show()
            end
        end
        viewport.ScrollBar = slider
        return widget
    end
    local classic = Scroll()
    local legacyRoot = VisibilityFrame()
    legacyRoot.BottomFrame, legacyRoot.ScrollFrame = VisibilityFrame(legacyRoot), classic.scrollframe
    legacyRoot.ScrollChild = VisibilityFrame(legacyRoot.BottomFrame)
    classic.scrollframe.parent = legacyRoot.BottomFrame
    local rxp = { settings = { profile = { activeTheme = "LockInTools" } }, RXPFrame = legacyRoot,
        v2 = { enabled = v2Enabled, state = {} } }
    function legacyRoot.BottomFrame:UpdateFrame()
        local guide = rxp.currentGuide
        if self:GetHeight() < 30 then
            self:Hide()
            if legacyRoot:GetHeight() < 28 then legacyRoot:SetHeight(28) end
        elseif guide and guide.hidewindow then
            if legacyRoot:GetHeight() > 50 then rxp.settings.profile.frameHeight = legacyRoot:GetHeight() end
            legacyRoot:SetHeight(28)
            self:Hide()
        elseif not self:IsShown() then
            -- Native UpdateFrame skips this branch when the access override
            -- already showed BottomFrame; it then emits no Show to observe.
            if rxp.settings.profile.frameHeight then legacyRoot:SetHeight(math.max(rxp.settings.profile.frameHeight, 50)) end
            world.nativeContainerShows = (world.nativeContainerShows or 0) + 1
            self:Show()
        end
    end
    function rxp:LoadGuide(guide)
        self.currentGuide = guide
        -- Native guide loading restores frameHeight before UpdateFrame runs.
        if self.settings.profile.frameHeight then legacyRoot:SetHeight(self.settings.profile.frameHeight) end
        legacyRoot.BottomFrame:UpdateFrame()
    end
    function rxp:LoadActiveTheme() end
    function rxp.RXPFrame.UpdateScrollBar() classic.scrollbar:SetThumbTexture("updated-native-thumb") end
    function rxp.RXPFrame.UpdateVisuals() rxp.RXPFrame.UpdateScrollBar() end
    function rxp.RenderFrame() rxp.RXPFrame.UpdateVisuals() end
    function rxp.v2:IsGuideWindowEnabled() return self.enabled end
    function rxp.v2:GetGuideWindow()
        if not self.state.guideWindow then
            local rootFrame, scroll = VisibilityFrame(), Scroll()
            local guideStepsFrame = VisibilityFrame(rootFrame)
            scroll.frame.parent = guideStepsFrame
            scroll.frame:SetPoint("TOPLEFT", guideStepsFrame, "TOPLEFT", 0, 0)
            scroll.frame:SetPoint("BOTTOMRIGHT", guideStepsFrame, "BOTTOMRIGHT", 0, 0)
            self.state.guideWindow = { frame = rootFrame, guideSteps = { frame = guideStepsFrame, scroll = scroll } }
        end
        return self.state.guideWindow
    end
    function rxp.v2:UpdateGuideWindow() self:GetGuideWindow().guideSteps.scroll:RefreshVisuals() end
    world.guideEntry = { text = "Native guide group", hasArrow = true, notCheckable = true, menuList = {
        { text = "A native guide", notCheckable = true, arg1 = "native-guide",
            func = function(_, guide) world.guideSelections = world.guideSelections + 1; world.selectedGuide = guide end },
    } }
    world.settingsEntry = { text = "Settings", notCheckable = true, func = function() world.settingsMenus = world.settingsMenus + 1 end }
    function rxp.RXPFrame:GenerateMenuTable(menu)
        menu = menu or {}
        if not world.emptyGuides then menu[#menu + 1] = world.guideEntry end
        menu[#menu + 1] = { text = "", isTitle = true, notCheckable = true }
        menu[#menu + 1] = world.settingsEntry
        return menu
    end
    function rxp:ShowMenu(menu)
        world.shownMenus = world.shownMenus + 1
        world.lastMenu = menu
    end
    function rxp.RXPFrame.DropDownMenu()
        world.settingsMenus = world.settingsMenus + 1
        rxp:ShowMenu(rxp.RXPFrame:GenerateMenuTable({}))
    end
    function rxp.v2:ShowGuideSelectionMenu()
        world.guideMenus = world.guideMenus + 1
        local menu = {}
        for _, item in ipairs(rxp.RXPFrame:GenerateMenuTable({})) do
            if item.isTitle and item.text == "" then break end
            menu[#menu + 1] = item
        end
        menu[#menu + 1] = { text = "", notCheckable = true, isTitle = true }
        menu[#menu + 1] = { text = "Close", notCheckable = true, func = function(frame) frame:Hide() end }
        rxp:ShowMenu(menu)
    end
    local addon = { db = { restedxpSkin = { enabled = false } }, restedxpSkinState = {}, Theme = {} }
    function addon.Theme:GetPalette() return { surface = { 0.1, 0.15, 0.2, 1 }, accent = { 0.27, 0.65, 1 } } end
    local env = setmetatable({ InCombatLockdown = function() return world.combat end, CLOSE = "Close" }, { __index = _G })
    env._G = env
    env.hooksecurefunc = helpers.hooksecurefunc(env, function() world.hooks = world.hooks + 1 end)
    helpers.loadModule("RestedXPSkin.lua", addon, env)
    return addon, rxp, world, classic
end

local function Snapshot(slider)
    local thumb = slider:GetThumbTexture()
    return { width = slider:GetWidth(), points = { { slider:GetPoint(1) }, { slider:GetPoint(2) } },
        texture = thumb:GetTexture(), coordinates = { thumb:GetTexCoord() }, color = { thumb:GetVertexColor() },
        thumbWidth = thumb:GetWidth(), thumbHeight = thumb:GetHeight(), alpha = thumb:GetAlpha(), desaturated = thumb:IsDesaturated(),
        wheel = slider.obj and slider.obj.scrollframe:GetScript("OnMouseWheel"),
        change = slider:GetScript("OnValueChanged"), click = slider:GetScript("OnMouseDown"), release = slider:GetScript("OnMouseUp"),
        upClick = slider.ScrollUpButton:GetScript("OnClick"), downClick = slider.ScrollDownButton:GetScript("OnClick"),
        upShow = slider.ScrollUpButton:GetScript("OnShow"), downShow = slider.ScrollDownButton:GetScript("OnShow") }
end

local function Restored(slider, saved)
    local thumb = slider:GetThumbTexture()
    assert(slider:GetWidth() == saved.width and thumb:GetWidth() == saved.thumbWidth and thumb:GetHeight() == saved.thumbHeight)
    assert(Same({ slider:GetPoint(1) }, saved.points[1]) and Same({ slider:GetPoint(2) }, saved.points[2]), "native slider geometry restores")
    assert(thumb:GetTexture() == saved.texture and Same({ thumb:GetTexCoord() }, saved.coordinates)
        and Same({ thumb:GetVertexColor() }, saved.color) and thumb:GetAlpha() == saved.alpha
        and thumb:IsDesaturated() == saved.desaturated, "native thumb appearance restores")
    assert(slider:GetScript("OnValueChanged") == saved.change and slider:GetScript("OnMouseDown") == saved.click
        and slider:GetScript("OnMouseUp") == saved.release,
        "the native slider callbacks must never be replaced")
    assert(slider.ScrollUpButton:GetScript("OnClick") == saved.upClick and slider.ScrollDownButton:GetScript("OnClick") == saved.downClick
        and slider.ScrollUpButton:GetScript("OnShow") == saved.upShow and slider.ScrollDownButton:GetScript("OnShow") == saved.downShow,
        "the arrow buttons retain their native input and visibility handlers")
end

do
    local addon, rxp, world, classic = Fixture(false)
    local bar, viewport = classic.scrollbar, classic.scrollframe
    local saved, nativeThumb, wheel = Snapshot(bar), bar:GetThumbTexture(), viewport:GetScript("OnMouseWheel")
    local mutations = world.mutations
    addon:RefreshRestedXPScrollbar(rxp)
    assert(world.mutations == mutations and #bar.regions == 2, "default-off must leave native scrollbar regions untouched")
    addon.db.restedxpSkin.enabled = true
    addon:RefreshRestedXPScrollbar(rxp)
    assert(bar:GetThumbTexture() == nativeThumb and bar:GetWidth() < saved.width)
    assert(not bar.ScrollUpButton:IsShown() and not bar.ScrollDownButton:IsShown() and not bar.ornament:IsShown())
    assert(bar:GetValue() == 275 and world.changes == 0, "restyling must not change scroll position or range")
    local low, high = bar:GetMinMaxValues()
    assert(low == 0 and high == 1000 and viewport:GetScript("OnMouseWheel") == wheel)
    wheel(viewport, -1)
    assert(viewport.offset == 320, "native wheel callbacks still move the content")
    bar:GetScript("OnMouseDown")(bar, "LeftButton")
    assert(viewport.offset == 420, "native track clicks still move the content")
    bar:SetValue(800)
    assert(viewport.offset == 800 and bar:GetScript("OnValueChanged") == saved.change, "native thumb changes still move the content")
    local hooks = world.hooks
    rxp.RXPFrame.UpdateScrollBar()
    addon:RefreshRestedXPScrollbar(rxp)
    assert(world.hooks == hooks and bar:GetThumbTexture():GetTexture() ~= "updated-native-thumb", "native redraws keep the modern appearance without duplicate hooks")
    addon.db.restedxpSkin.enabled = false
    addon:RefreshRestedXPScrollbar(rxp)
    saved.texture = "updated-native-thumb"
    Restored(bar, saved)
    assert(bar.ScrollUpButton:IsShown() and bar.ScrollDownButton:IsShown() and bar.ornament:IsShown() and not bar.regions[3]:IsShown())
end

do
    local addon, rxp, _, classic = Fixture(false)
    local saved = Snapshot(classic.scrollbar)
    addon.db.restedxpSkin.enabled = true
    addon:RefreshRestedXPScrollbar(rxp)
    rxp.settings.profile.activeTheme = "RXP Blue"
    rxp:LoadActiveTheme()
    Restored(classic.scrollbar, saved)
end

do
    local addon, rxp, world, classic = Fixture(true)
    addon.db.restedxpSkin.enabled = true
    addon.db.restedxpSkin.backgroundTransparency = 75
    addon:RefreshRestedXPTransparency(rxp)
    addon:RefreshRestedXPScrollbar(rxp)
    assert(not rxp.v2.state.guideWindow and classic.scrollbar:GetWidth() == 16, "discovery must not acquire a V2 widget")
    local scroll = rxp.v2:GetGuideWindow().guideSteps.scroll
    assert(scroll.scrollbar:GetWidth() == 8 and not scroll.scrollbg:IsShown(), "late-created V2 native controls acquire the optional style")
    local track = scroll.scrollbar.regions[3]
    assert(track.fill[4] == 1 and track:GetAlpha() == 0.25 and scroll.scrollbar.thumb.color[4] == 1 and scroll.scrollbar.thumb:GetAlpha() == 1,
        "track transparency follows the background preference while the thumb stays readable")
    scroll:RefreshVisuals()
    scroll:FixScroll()
    assert(scroll.scrollbar.thumb:GetTexture() ~= "native-thumb" and not scroll.scrollbar.ScrollUpButton:IsShown())
    addon.db.restedxpSkin.enabled = false
    addon:RefreshRestedXPScrollbar(rxp)
    assert(scroll.scrollbar:GetWidth() == 16 and scroll.scrollbar.thumb:GetTexture() == "native-thumb"
        and Same(scroll.scrollbar.thumb.color, { 1, 1, 1, 1 }) and not scroll.scrollbar.thumb:IsDesaturated()
        and scroll.scrollbg:IsShown() and not track:IsShown(), "V2 restoration preserves the latest native theme refresh")
    assert(world.hooks > 0)
end

for _, v2 in ipairs({ false, true }) do
    local addon, rxp, world, classic = Fixture(v2)
    addon.db.restedxpSkin.enabled = true
    addon:RefreshRestedXPScrollbar(rxp)
    local scroll = v2 and rxp.v2:GetGuideWindow().guideSteps.scroll or classic
    local bar, viewport = scroll.scrollbar, scroll.scrollframe
    local saved = Snapshot(bar)
    local layouts = world.sliderLayouts
    local function Hidden()
        assert(not bar.ScrollUpButton:IsShown() and not bar.ScrollDownButton:IsShown(),
            "native scrolling cannot reveal legacy arrows while the modern skin is active")
    end
    local wheel = viewport:GetScript("OnMouseWheel")
    wheel(viewport, -1)
    assert(viewport.offset == 320)
    Hidden()
    bar:GetScript("OnMouseDown")(bar, "LeftButton")
    assert(viewport.offset == 420)
    Hidden()
    bar:SetValue(800)
    assert(viewport.offset == 800)
    Hidden()
    local shows = world.arrowShows or 0
    bar.ScrollUpButton:NativeShow()
    bar.ScrollDownButton:NativeShow()
    assert(world.arrowShows == shows + 2, "the native OnShow handlers still receive engine visibility events")
    Hidden()
    bar:SetValue(0)
    assert(viewport.offset == 0 and not bar.ScrollUpButton:IsEnabled() and bar.ScrollDownButton:IsEnabled())
    Hidden()
    bar:SetValue(1000)
    assert(viewport.offset == 1000 and bar.ScrollUpButton:IsEnabled() and not bar.ScrollDownButton:IsEnabled(),
        "native arrow enabled states and scroll offsets still follow the native range")
    Hidden()
    assert(world.sliderLayouts == layouts and bar:GetWidth() == 8,
        "suppressing a reappearing arrow never rebuilds slider layout during input")
    assert(viewport:GetScript("OnMouseWheel") == wheel and bar:GetScript("OnValueChanged") == saved.change
        and bar:GetScript("OnMouseDown") == saved.click and bar.ScrollUpButton:GetScript("OnShow") == saved.upShow
        and bar.ScrollDownButton:GetScript("OnShow") == saved.downShow, "scroll and visibility handlers retain their native identity")
    world.combat = true
    wheel(viewport, 1)
    assert(viewport.offset == 955, "existing native scrolling remains usable in combat")
    bar.ScrollUpButton:NativeShow()
    bar.ScrollDownButton:NativeShow()
    Hidden()
    assert(world.sliderLayouts == layouts and bar:GetWidth() == 8,
        "already active ordinary arrows stay hidden in combat without changing slider geometry")
    world.combat = false
    if v2 then scroll:RefreshVisuals(); scroll:FixScroll() else rxp.RXPFrame.UpdateScrollBar() end
    Hidden()
    rxp.settings.profile.activeTheme = "RXP Blue"
    rxp:LoadActiveTheme()
    assert(bar:GetWidth() == 16 and bar.ScrollUpButton:IsShown() and bar.ScrollDownButton:IsShown(),
        "choosing a native theme restores the arrow buttons")
    bar:SetValue(500)
    assert(viewport.offset == 500 and bar.ScrollUpButton:IsShown() and bar.ScrollDownButton:IsShown(),
        "native arrows remain available after theme restoration")
    rxp.settings.profile.activeTheme = "LockInTools"
    rxp:LoadActiveTheme()
    Hidden()
    addon.db.restedxpSkin.enabled = false
    addon:RefreshRestedXPScrollbar(rxp)
    assert(bar:GetWidth() == 16 and bar.ScrollUpButton:IsShown() and bar.ScrollDownButton:IsShown(),
        "disabling the skin restores arrows after native scrolling and redraws")
end

do
    local addon, rxp, world, classic = Fixture(false)
    addon.db.restedxpSkin.enabled = true
    world.combat = true
    local mutations = world.mutations
    addon:RefreshRestedXPScrollbar(rxp)
    assert(world.mutations == mutations and addon.restedxpSkinState.pending and #classic.scrollbar.regions == 2,
        "combat defers texture creation, visibility and geometry changes")
    world.combat = false
    addon:RefreshRestedXPScrollbar(rxp)
    assert(classic.scrollbar:GetWidth() == 8)
    addon.db.restedxpSkin.enabled = false
    world.combat = true
    mutations = world.mutations
    addon:RefreshRestedXPScrollbar(rxp)
    assert(world.mutations == mutations and classic.scrollbar:GetWidth() == 8, "combat also defers restoration")
    world.combat = false
    addon:RefreshRestedXPScrollbar(rxp)
    assert(classic.scrollbar:GetWidth() == 16)
end

for _, v2 in ipairs({ false, true }) do
    local addon, rxp, world, classic = Fixture(v2)
    local scroll = v2 and rxp.v2:GetGuideWindow().guideSteps.scroll or classic
    local bar, viewport = scroll.scrollbar, scroll.scrollframe
    local saved = Snapshot(bar)
    local function Click(button)
        bar:RunScript("OnMouseDown", button)
        bar:RunScript("OnMouseUp", button)
    end
    addon:RefreshRestedXPScrollbar(rxp)
    Click("RightButton")
    assert(world.shownMenus == 0, "default-off does not add scrollbar menu behavior")
    addon.db.restedxpSkin.hideChrome = true
    addon:RefreshRestedXPScrollbar(rxp)
    Click("RightButton")
    assert(world.shownMenus == 1 and world.guideMenus == 1 and bar:GetWidth() == saved.width,
        "a manually selected LockInTools theme with hidden chrome retains guide access while extra styling is off")
    local menuBaseline = world.shownMenus
    addon.db.restedxpSkin.enabled = true
    addon.db.restedxpSkin.hideChrome = false
    addon:RefreshRestedXPScrollbar(rxp)
    Click("RightButton")
    assert(world.shownMenus == menuBaseline, "the scrollbar shortcut is reserved for the hidden-header layout")
    addon.db.restedxpSkin.hideChrome = true
    addon:RefreshRestedXPScrollbar(rxp)
    local changes, layouts, down, up = world.changes, world.sliderLayouts, world.nativeDown, world.nativeUp
    Click("RightButton")
    assert(world.guideMenus == menuBaseline + 1 and world.shownMenus == menuBaseline + 1 and world.settingsMenus == 0 and world.guideSelections == 0,
        "right-clicking the hidden-header scrollbar opens the native guide chooser without settings or selecting a guide")
    assert(world.lastMenu[1] == world.guideEntry and world.lastMenu[2].isTitle and world.lastMenu[3].text == "Close",
        "the native guide hierarchy and close action are retained")
    for _, item in ipairs(world.lastMenu) do assert(item ~= world.settingsEntry, "settings entries do not appear in the guide chooser") end
    assert(world.changes == changes and bar:GetValue() == 275 and world.sliderLayouts == layouts,
        "opening the guide chooser does not move content or rebuild the slider")
    assert(world.nativeDown == down + 1 and world.nativeUp == up + 1,
        "right-click is added after the original native mouse handlers")
    assert(bar:GetScript("OnMouseDown") == saved.click and bar:GetScript("OnMouseUp") == saved.release
        and bar:GetScript("OnValueChanged") == saved.change, "adding the shortcut preserves native handler identity")
    Click("LeftButton")
    assert(viewport.offset == 375 and not bar.dragging and world.shownMenus == menuBaseline + 1,
        "left track clicks and native drag release keep scrolling without opening menus")
    bar:RunScript("OnMouseDown", "LeftButton")
    bar:SetValue(800)
    bar:RunScript("OnMouseUp", "LeftButton")
    assert(viewport.offset == 800 and not bar.dragging and world.shownMenus == menuBaseline + 1, "native thumb dragging remains available")
    viewport:GetScript("OnMouseWheel")(viewport, 1)
    assert(viewport.offset == 755 and world.shownMenus == menuBaseline + 1, "native wheel scrolling remains available")
    Click("MiddleButton")
    assert(world.shownMenus == menuBaseline + 1, "other mouse buttons do not open the guide chooser")
    for _ = 1, 10 do addon:RefreshRestedXPScrollbar(rxp) end
    Click("RightButton")
    assert(world.shownMenus == menuBaseline + 2, "repeated native redraws do not duplicate right-click actions")
    addon.savedDataReadOnly = true
    Click("RightButton")
    assert(world.shownMenus == menuBaseline + 2, "read-only settings disable the additional interaction immediately")
    addon.savedDataReadOnly = nil
    rxp.settings.profile.activeTheme = "RXP Blue"
    rxp:LoadActiveTheme()
    Click("RightButton")
    assert(world.shownMenus == menuBaseline + 2, "another selected native theme has no added scrollbar action")
    rxp.settings.profile.activeTheme = "LockInTools"
    rxp:LoadActiveTheme()
    addon.db.restedxpSkin.hideChrome = false
    Click("RightButton")
    assert(world.shownMenus == menuBaseline + 2, "showing the header disables the shortcut without replacing scripts")
    addon.db.restedxpSkin.hideChrome = true
    addon.db.restedxpSkin.enabled = false
    addon:RefreshRestedXPScrollbar(rxp)
    Click("RightButton")
    assert(world.shownMenus == menuBaseline + 3 and bar:GetWidth() == saved.width,
        "opting out of modern styling restores native geometry while independently hidden chrome retains guide access")
    addon.db.restedxpSkin.hideChrome = false
    Click("RightButton")
    assert(world.shownMenus == menuBaseline + 3, "opting out of hidden chrome removes the added action")
    local nativeGuide = world.lastMenu[1].menuList[1]
    nativeGuide.func({}, nativeGuide.arg1)
    assert(world.guideSelections == 1 and world.selectedGuide == "native-guide", "choosing a submenu entry still invokes its native guide action")
end

do
    local addon, rxp, world, classic = Fixture(false)
    rxp.v2.ShowGuideSelectionMenu = nil
    addon.db.restedxpSkin.enabled, addon.db.restedxpSkin.hideChrome = true, true
    addon:RefreshRestedXPScrollbar(rxp)
    classic.scrollbar:RunScript("OnMouseDown", "RightButton")
    classic.scrollbar:RunScript("OnMouseUp", "RightButton")
    assert(world.shownMenus == 1 and world.guideMenus == 0 and world.settingsMenus == 0 and world.guideSelections == 0,
        "older native APIs use the guide-only menu table instead of the full legacy settings menu")
    assert(world.lastMenu[1] == world.guideEntry and world.lastMenu[1].menuList[1].arg1 == "native-guide",
        "the legacy fallback preserves native guide callbacks and submenu data")
    for _, item in ipairs(world.lastMenu) do assert(item ~= world.settingsEntry) end
end

do
    local addon, rxp, world, classic = Fixture(false)
    addon.db.restedxpSkin.hideChrome = true
    addon:RefreshRestedXPScrollbar(rxp)
    classic.scrollbar:RunScript("OnMouseUp", "RightButton")
    assert(world.shownMenus == 1)
    rxp.v2.enabled = true
    addon:RefreshRestedXPScrollbar(rxp)
    classic.scrollbar:RunScript("OnMouseUp", "RightButton")
    assert(world.shownMenus == 1, "the inactive classic interface cannot open a menu after switching to V2")
    local scroll = rxp.v2:GetGuideWindow().guideSteps.scroll
    scroll.scrollbar:RunScript("OnMouseUp", "RightButton")
    assert(world.shownMenus == 2 and scroll.scrollbar:GetWidth() == 16,
        "a late-created V2 slider gains guide access without enabling modern scrollbar geometry")
    local layouts = world.sliderLayouts
    world.combat = true
    scroll.scrollbar:RunScript("OnMouseUp", "RightButton")
    assert(world.shownMenus == 3 and world.sliderLayouts == layouts,
        "an existing ordinary scrollbar can invoke the native chooser in combat without relayout")
    world.combat = false
    rxp.v2.enabled = false
    addon:RefreshRestedXPScrollbar(rxp)
    scroll.scrollbar:RunScript("OnMouseUp", "RightButton")
    assert(world.shownMenus == 3, "the inactive V2 interface cannot open a menu after switching to classic")
    classic.scrollbar:RunScript("OnMouseUp", "RightButton")
    assert(world.shownMenus == 4, "the current classic interface regains its guide shortcut")
end

for _, v2 in ipairs({ false, true }) do
    for _, modern in ipairs({ false, true }) do
        local addon, rxp, world, classic = Fixture(v2)
        local window = v2 and rxp.v2:GetGuideWindow()
        local scroll = window and window.guideSteps.scroll or classic
        local container = window and window.guideSteps.frame or rxp.RXPFrame.BottomFrame
        local content = window and scroll.content or rxp.RXPFrame.ScrollChild
        local outerPoints = window and { { scroll.frame:GetPoint(1) }, { scroll.frame:GetPoint(2) } }
        local bar, viewport = scroll.scrollbar, scroll.scrollframe
        scroll.noScroll = true
        if not v2 then bar:SetMinMaxValues(0, 0) end
        scroll:FixScroll()
        world.emptyGuides, rxp.currentGuide = true, { empty = true, hidewindow = true }
        container:Hide()
        assert(not bar:IsVisible(), "native empty content initially hides the slider or its guide-step container")
        local low, high = bar:GetMinMaxValues()
        addon.db.restedxpSkin.enabled, addon.db.restedxpSkin.hideChrome = modern, true
        addon:RefreshRestedXPScrollbar(rxp)
        assert(bar:IsShown() and bar:IsVisible(), "hidden chrome keeps guide selection reachable even with no scrollable content or guide")
        assert(not content:IsVisible(), "forcing an empty or collapsed container never exposes its cached native guide rows")
        assert(scroll.scrollBarShown == nil, "cosmetic visibility does not change the native no-scroll state")
        scroll:FixScroll()
        assert(bar:IsVisible() and scroll.scrollBarShown == nil, "native no-scroll layout cannot remove the available guide shortcut")
        if window then
            local _, _, _, rightInset = scroll.frame:GetPoint(2)
            assert(rightInset < outerPoints[2][4], "the outer content frame reserves room for the visible native scrollbar")
        end
        local layouts, containerLayouts = world.sliderLayouts, world.containerLayouts
        local hides = world.sliderHides or 0
        bar:Hide()
        assert(bar:IsVisible(), "native Hide cannot remove the hidden-header guide shortcut")
        bar:SetShown(false)
        assert(bar:IsVisible(), "native SetShown(false) cannot remove the hidden-header guide shortcut")
        bar:NativeHide()
        assert(bar:IsVisible() and world.sliderHides == hides + 3, "C-side OnHide still runs its native handler and retains the shortcut")
        assert(world.sliderLayouts == layouts and world.containerLayouts == containerLayouts,
            "visibility repair never rebuilds scrollbar or content layout during native events")
        container:NativeHide()
        assert(bar:IsVisible(), "an empty guide's hidden native ancestor cannot conceal the guide shortcut")
        viewport:GetScript("OnMouseWheel")(viewport, -1)
        bar:RunScript("OnMouseDown", "LeftButton")
        bar:SetValue(500)
        bar:RunScript("OnMouseUp", "LeftButton")
        local nowLow, nowHigh = bar:GetMinMaxValues()
        assert(viewport.offset == 0 and bar:GetValue() == bar:GetValue() and nowLow == low and nowHigh == high
            and bar:GetValue() >= low and bar:GetValue() <= high and scroll.scrollBarShown == nil,
            "wheel and thumb input preserve native no-scroll offsets and finite values without inventing a range")
        local menus = world.shownMenus
        bar:RunScript("OnMouseDown", "RightButton")
        bar:RunScript("OnMouseUp", "RightButton")
        assert(world.shownMenus == menus + 1 and world.lastMenu[1].isTitle and world.lastMenu[2].text == "Close"
            and world.settingsMenus == 0 and world.guideSelections == 0,
            "the always-visible empty-guide bar opens the native guide chooser exactly once")
        world.combat = true
        bar:NativeHide()
        assert(bar:IsVisible(), "an already active ordinary shortcut remains visible during combat")
        world.combat = false
        addon.db.restedxpSkin.hideChrome = false
        addon:RefreshRestedXPScrollbar(rxp)
        assert(not bar:IsShown() and not container:IsShown(),
            "showing the header restores the latest native hidden slider and empty-guide container")
        assert(content:IsShown(), "releasing the forced container restores the cached content's own native visibility")
        if window then
            assert(Same({ scroll.frame:GetPoint(1) }, outerPoints[1]) and Same({ scroll.frame:GetPoint(2) }, outerPoints[2]),
                "releasing hidden chrome restores the native outer scroll-frame anchors")
        end
        addon.db.restedxpSkin.hideChrome = true
        addon:RefreshRestedXPScrollbar(rxp)
        assert(bar:IsVisible())
        rxp.settings.profile.activeTheme = "RXP Blue"
        rxp:LoadActiveTheme()
        assert(not bar:IsShown() and not container:IsShown(),
            "another selected theme restores native visibility")
        rxp.settings.profile.activeTheme = "LockInTools"
        rxp:LoadActiveTheme()
        assert(bar:IsVisible())
        addon.savedDataReadOnly = true
        addon:RefreshRestedXPScrollbar(rxp)
        assert(not bar:IsShown(), "read-only settings release forced scrollbar visibility")
        addon.savedDataReadOnly = nil
        addon:RefreshRestedXPScrollbar(rxp)
        assert(bar:IsVisible())
        scroll.noScroll = false
        container:Show()
        scroll:FixScroll()
        assert(content:IsVisible(), "a later native decision to show the guide restores its content while chrome remains hidden")
        addon.db.restedxpSkin.hideChrome = false
        addon:RefreshRestedXPScrollbar(rxp)
        assert(bar:IsVisible(), "restoration respects a later native decision to show the scrollbar")
        addon.db.restedxpSkin.hideChrome = true
        local root = window and window.frame or rxp.RXPFrame
        root:Hide()
        addon:RefreshRestedXPScrollbar(rxp)
        assert(not root:IsShown() and not bar:IsVisible(), "keeping guide access available never reopens a user-hidden native guide window")
    end
end

do
    local addon, rxp, world, classic = Fixture(false)
    local root, bottom, content = rxp.RXPFrame, rxp.RXPFrame.BottomFrame, rxp.RXPFrame.ScrollChild
    local nativeHeight = root:GetHeight()
    rxp:LoadGuide({ hidewindow = true })
    assert(not bottom:IsShown() and root:GetHeight() == 28, "native hidewindow guide collapses its body before styling")
    addon.db.restedxpSkin.hideChrome = true
    addon:RefreshRestedXPScrollbar(rxp)
    assert(bottom:IsShown() and classic.scrollbar:IsVisible() and not content:IsVisible())
    rxp:LoadGuide({})
    assert((world.nativeContainerShows or 0) == 0, "the actual native conditional skips Show when the override already showed BottomFrame")
    assert(bottom:IsShown() and content:IsVisible() and root:GetHeight() == nativeHeight,
        "a normal guide restores native rows after LoadGuide sizing even when UpdateFrame emits no Show")
    addon.db.restedxpSkin.hideChrome = false
    addon:RefreshRestedXPScrollbar(rxp)
    assert(bottom:IsShown() and content:IsVisible(), "releasing the override retains the inferred native expanded state")
    bottom:SetHeight(24)
    bottom:UpdateFrame()
    assert(not bottom:IsShown(), "native short content also hides the body")
    addon.db.restedxpSkin.hideChrome = true
    addon:RefreshRestedXPScrollbar(rxp)
    assert(classic.scrollbar:IsVisible() and not content:IsVisible())
    bottom:SetHeight(150)
    bottom:UpdateFrame()
    assert(content:IsVisible() and (world.nativeContainerShows or 0) == 0,
        "growing past the native minimum restores rows without requiring an explicit native Show")
end

print("PASS: optional RestedXP native scrollbar styling, input, guide chooser, restoration and combat deferral")
