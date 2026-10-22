-- Native sliders and input callbacks remain responsible for all scrolling.
local function Same(actual, expected)
    if type(actual) ~= "table" or type(expected) ~= "table" then return actual == expected end
    if #actual ~= #expected then return false end
    for index = 1, #actual do if actual[index] ~= expected[index] then return false end end
    return true
end

local function Fixture(v2Enabled)
    local world = { combat = false, mutations = 0, hooks = 0, changes = 0 }
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
        local button = { shown = true, scripts = {} }
        function button:IsShown() return self.shown end
        function button:Show() self.shown = true; world.mutations = world.mutations + 1 end
        function button:Hide() self.shown = false; world.mutations = world.mutations + 1 end
        function button:GetScript(name) return self.scripts[name] end
        button.scripts.OnClick = function() slider:SetValue(slider:GetValue() + amount) end
        return button
    end
    local function Scroll()
        local viewport = { scripts = {} }
        function viewport:GetScript(name) return self.scripts[name] end
        local slider = { width = 16, height = 180, value = 275, low = 0, high = 1000, points = {}, scripts = {}, shown = true }
        function slider:GetWidth() return self.width end
        function slider:SetWidth(value) self.width = value; world.mutations = world.mutations + 1 end
        function slider:GetHeight() return self.height end
        function slider:GetNumPoints() return #self.points end
        function slider:GetPoint(index) return unpack(self.points[index], 1, 5) end
        function slider:ClearAllPoints() self.points = {}; world.mutations = world.mutations + 1 end
        function slider:SetPoint(...) self.points[#self.points + 1] = { ... }; world.mutations = world.mutations + 1 end
        function slider:GetValue() return self.value end
        function slider:SetValue(value)
            self.value = math.max(self.low, math.min(self.high, value))
            self.scripts.OnValueChanged(self, self.value)
        end
        function slider:GetMinMaxValues() return self.low, self.high end
        function slider:GetScript(name) return self.scripts[name] end
        function slider:IsShown() return self.shown end
        function slider:Show() self.shown = true; world.mutations = world.mutations + 1 end
        function slider:Hide() self.shown = false; world.mutations = world.mutations + 1 end
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
        slider.scripts.OnValueChanged = function(_, value) world.changes = world.changes + 1; viewport.offset = value end
        slider.scripts.OnMouseDown = function() slider:SetValue(slider:GetValue() + 100) end
        viewport.scripts.OnMouseWheel = function(_, direction) slider:SetValue(slider:GetValue() - direction * 45) end
        local widget = { scrollframe = viewport, scrollbar = slider, scrollbg = Region("native-track") }
        function widget:RefreshVisuals()
            self.scrollbar.thumb:SetDesaturated(false)
            self.scrollbar.thumb:SetVertexColor(1, 1, 1, 1)
            self.scrollbg:SetColorTexture(0.1, 0.1, 0.1, 1)
        end
        function widget:FixScroll() self.scrollbar:Show() end
        viewport.ScrollBar = slider
        return widget
    end
    local classic = Scroll()
    local rxp = { settings = { profile = { activeTheme = "LockInTools" } }, RXPFrame = { ScrollFrame = classic.scrollframe },
        v2 = { enabled = v2Enabled, state = {} } }
    function rxp:LoadActiveTheme() end
    function rxp.RXPFrame.UpdateScrollBar() classic.scrollbar:SetThumbTexture("updated-native-thumb") end
    function rxp.RXPFrame.UpdateVisuals() rxp.RXPFrame.UpdateScrollBar() end
    function rxp.RenderFrame() rxp.RXPFrame.UpdateVisuals() end
    function rxp.v2:IsGuideWindowEnabled() return self.enabled end
    function rxp.v2:GetGuideWindow()
        if not self.state.guideWindow then self.state.guideWindow = { guideSteps = { scroll = Scroll() } } end
        return self.state.guideWindow
    end
    function rxp.v2:UpdateGuideWindow() self:GetGuideWindow().guideSteps.scroll:RefreshVisuals() end
    local addon = { db = { restedxpSkin = { enabled = false } }, restedxpSkinState = {}, Theme = {} }
    function addon.Theme:GetPalette() return { surface = { 0.1, 0.15, 0.2, 1 }, accent = { 0.27, 0.65, 1 } } end
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
    setfenv(assert(loadfile("RestedXPSkin.lua")), env)("LockInTools", addon)
    return addon, rxp, world, classic
end

local function Snapshot(slider)
    local thumb = slider:GetThumbTexture()
    return { width = slider:GetWidth(), points = { { slider:GetPoint(1) }, { slider:GetPoint(2) } },
        texture = thumb:GetTexture(), coordinates = { thumb:GetTexCoord() }, color = { thumb:GetVertexColor() },
        thumbWidth = thumb:GetWidth(), thumbHeight = thumb:GetHeight(), alpha = thumb:GetAlpha(), desaturated = thumb:IsDesaturated(),
        wheel = slider.obj and slider.obj.scrollframe:GetScript("OnMouseWheel"),
        change = slider:GetScript("OnValueChanged"), click = slider:GetScript("OnMouseDown") }
end

local function Restored(slider, saved)
    local thumb = slider:GetThumbTexture()
    assert(slider:GetWidth() == saved.width and thumb:GetWidth() == saved.thumbWidth and thumb:GetHeight() == saved.thumbHeight)
    assert(Same({ slider:GetPoint(1) }, saved.points[1]) and Same({ slider:GetPoint(2) }, saved.points[2]), "native slider geometry restores")
    assert(thumb:GetTexture() == saved.texture and Same({ thumb:GetTexCoord() }, saved.coordinates)
        and Same({ thumb:GetVertexColor() }, saved.color) and thumb:GetAlpha() == saved.alpha
        and thumb:IsDesaturated() == saved.desaturated, "native thumb appearance restores")
    assert(slider:GetScript("OnValueChanged") == saved.change and slider:GetScript("OnMouseDown") == saved.click,
        "the native slider callbacks must never be replaced")
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

print("PASS: optional RestedXP native scrollbar styling, input, restoration and combat deferral")
