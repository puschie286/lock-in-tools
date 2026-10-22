-- Skin integration uses RestedXP's public theme API; the native renderer stays in control.
local function Copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = Copy(child) end
    return result
end

local function Fixture(saved, options, native)
    options = options or {}
    local world = { available = options.available ~= false, combat = options.combat == true,
        events = {}, notifications = {}, registered = 0, reloads = 0, conversions = 0, hooks = 0,
        renders = 0, guideReloads = 0, profileName = options.profileName or "Default", timers = {} }
    local addon = { initialized = true, ready = true, db = saved or {}, savedDataReadOnly = options.readOnly == true }
    local rxp = native or { themes = {}, settings = { profile = {
        activeTheme = "RXP Blue", enableThemeLiveReload = options.liveReload ~= false,
    } } }
    rxp.themes["RXP Blue"] = rxp.themes["RXP Blue"] or {
        name = "RXP Blue", author = "RestedXP", version = 1, applicable = true,
        displayName = "RXP Blue", texturePath = "Interface/AddOns/RXPGuides/Textures/", headerTexture = "rxp-banner",
        background = { 0.1, 0.1, 0.2, 1 }, bottomFrameBG = { 0.2, 0.2, 0.3, 1 },
        bottomFrameHighlight = { 0.3, 0.4, 0.5, 1 }, mapPins = { 1, 1, 1, 1 }, textColor = { 1, 1, 1 },
        font = "Fonts\\FRIZQT__.TTF", tooltip = "|cFFFFFFFF",
        bgTextures = { edge = "Interface/BUTTONS/WHITE8X8", bottom = "Interface/BUTTONS/WHITE8X8" },
        edges = { edge = "native-border", guideName = "native-border" },
    }
    rxp.themes["Custom"] = rxp.themes["Custom"] or Copy(rxp.themes["RXP Blue"])
    rxp.themes.Custom.name, rxp.themes.Custom.author = "Custom", "Player"
    local function Region(alpha)
        local region = { alpha = alpha or 0.75 }
        function region:SetTexture(path) self.path = path end
        function region:GetAlpha() return self.alpha end
        function region:SetAlpha(value) self.alpha = value end
        return region
    end
    local function Panel()
        local panel = { color = { 0.3, 0.4, 0.5, 1 }, bg = Region() }
        panel.nativeColor = Copy(panel.color)
        function panel:GetBackdropBorderColor() return unpack(self.color) end
        function panel:SetBackdropBorderColor(...) self.color = { ... } end
        function panel:RestoreNativeBorder() self:SetBackdropBorderColor(unpack(self.nativeColor)) end
        return panel
    end
    rxp.RXPFrame = { BottomFrame = Panel(), GuideName = Panel(), Footer = Panel(),
        CurrentStepFrame = { framePool = {} },
        backdrop = { edge = { edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } },
            guideName = { edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } } } }
    function rxp.SetStep(create)
        local pool = rxp.RXPFrame.CurrentStepFrame.framePool
        if create or #pool == 0 then
            local step = Panel()
            step.number = Panel()
            pool[#pool + 1] = step
        end
        for _, step in ipairs(pool) do step:RestoreNativeBorder(); step.number:RestoreNativeBorder() end
        return pool[#pool]
    end
    local function AuxiliaryPanel()
        local panel = Panel()
        panel.title = Panel()
        function panel:UpdateVisuals()
            self:RestoreNativeBorder()
            self.title:RestoreNativeBorder()
        end
        return panel
    end
    function rxp.CreateActiveItemFrame()
        rxp.activeItemFrame = AuxiliaryPanel()
        return rxp.activeItemFrame
    end
    rxp.targeting = {}
    function rxp.targeting.CreateTargetFrame()
        rxp.targeting.activeTargetFrame = AuxiliaryPanel()
        return rxp.targeting.activeTargetFrame
    end
    function rxp.targeting.RenderTargetFrameBackground()
        local frame = rxp.targeting.activeTargetFrame
        frame:RestoreNativeBorder()
        frame.title:RestoreNativeBorder()
    end
    function rxp.RXPFrame.UpdateVisuals()
        for _, name in ipairs({ "BottomFrame", "GuideName", "Footer" }) do
            rxp.RXPFrame[name]:SetBackdropBorderColor(unpack(rxp.activeTheme.bottomFrameHighlight))
        end
        rxp.RXPFrame.GuideName.bg:SetTexture("native-banner")
        rxp.RXPFrame.Footer.bg:SetTexture("native-banner")
    end
    rxp.v2 = { themes = {}, enabled = options.v2 == true }
    rxp.v2.themes["RXP Blue V2"] = {
        name = "RXP Blue", author = "RestedXP", version = 2, applicable = true,
        headerTexture = { path = "native-header", texCoords = { 0, 1, 0, 1 } },
        guideWindow = { logo = "native-logo", settingsIcon = "native-cog", guideSelectIcon = "native-scroll" },
        navigationArrow = "native-arrow", mapPins = { 1, 1, 1, 1 },
        backgroundColors = { common = {}, guideName = {}, guideWindow = {}, scrollbar = {},
            inactivePartyTab = {}, activeStepCheckbox = {}, activeStepCheckboxChecked = {} },
        borderColors = { common = {}, commonEdge = {}, inactivePartyTab = {}, activeStepCheckboxChecked = {} },
        textColor = { common = {}, title = {}, inactivePartyTab = {} },
        edge = { edgeFile = "native-edge", edgeSize = 1,
            texCoords = { top = { 0, 0.25, 0, 1 }, bottom = { 0.25, 0.5, 0, 1 },
                left = { 0.5, 0.75, 0, 1 }, right = { 0.75, 1, 0, 1 } } },
    }
    function rxp.v2:IsGuideWindowEnabled() return self.enabled end
    function rxp.v2:ConvertThemes()
        world.conversions = world.conversions + 1
        for name, theme in pairs(rxp.themes) do
            if not self.themes[name] or (theme.version or 1) >= (self.themes[name].version or 1) then
                local converted = Copy(self.themes["RXP Blue V2"])
                converted.name, converted.version = name, theme.version or 1
                converted.backgroundColors.common = Copy(theme.background)
                self.themes[name] = converted
            end
        end
    end
    rxp.v2:ConvertThemes()
    function rxp:RegisterTheme(theme)
        assert(type(theme.name) == "string" and type(theme.author) == "string", "native themes require identity")
        world.registered = world.registered + 1
        for key, value in pairs(self.themes["RXP Blue"]) do if not theme[key] then theme[key] = Copy(value) end end
        self.themes[theme.name] = theme
        if self.v2:IsGuideWindowEnabled() then self.v2:ConvertThemes() end
    end
    function rxp:GetThemeOptions()
        local result = {}
        local themes = self.v2:IsGuideWindowEnabled() and self.v2.themes or self.themes
        for name, theme in pairs(themes) do
            if theme.applicable ~= false then result[name] = name end
        end
        return result
    end
    function rxp.settings:GetCurrentProfile() return world.profileName end
    function rxp.settings.GetSettingsDB() return world.profileName end
    function rxp:LoadActiveTheme()
        self.activeTheme = self.themes[self.settings.profile.activeTheme] or self.themes["RXP Blue"]
        return self.activeTheme
    end
    function rxp.RenderFrame(reason)
        assert(reason == "themeReload" and not world.combat)
        if world.failNextRender then
            world.failNextRender = false
            error("native render exception contains private details")
        end
        world.renders = world.renders + 1
        rxp:LoadActiveTheme()
        rxp.RXPFrame.UpdateVisuals()
        rxp.SetupGuideWindow()
        rxp:ReloadGuide()
    end
    function rxp:ReloadGuide() world.guideReloads = world.guideReloads + 1 end
    function rxp.SetupArrow() assert(not world.combat); world.arrows = (world.arrows or 0) + 1 end
    function rxp.SetupGuideWindow()
        rxp.RXPFrame.GuideName.bg:SetTexture("native-banner")
        rxp.RXPFrame.Footer.bg:SetTexture("native-banner")
    end
    local guideWindow = { banner = Region(0.65), guideNameFrame = { rxpBackground = Region(0.55) } }
    guideWindow.title = { alpha = 0.9, nativeColor = { 1, 0.82, 0 },
        GetAlpha = function(self) return self.alpha end, SetAlpha = function(self, value) self.alpha = value end,
        SetTextColor = function(self, ...) self.color = { ... } end }
    function guideWindow:UpdateSubTheme() self.title:SetTextColor(unpack(self.title.nativeColor)) end
    function guideWindow:UpdateTheme()
        local theme = rxp.v2.themes[rxp.settings.profile.activeTheme]
        -- Native ApplyFrameBackdrop reads all four coordinate arrays even for WHITE8X8.
        for _, side in ipairs({ "top", "bottom", "left", "right" }) do
            local left, right, top, bottom = unpack(theme.edge.texCoords[side])
            assert(type(left) == "number" and type(right) == "number" and type(top) == "number" and type(bottom) == "number")
        end
        self:UpdateSubTheme()
        world.guideThemes = (world.guideThemes or 0) + 1
    end
    rxp.v2.state = options.v2 and { guideWindow = guideWindow } or {}
    function rxp.v2:GetGuideWindow() return guideWindow end
    function rxp.v2:UpdateGuideWindow() world.guideUpdates = (world.guideUpdates or 0) + 1 end
    function rxp.v2:UpdateActiveStepTheme() world.stepUpdates = (world.stepUpdates or 0) + 1 end
    function rxp:ReloadTheme()
        if not self.settings.profile.enableThemeLiveReload then return end
        assert(not world.combat, "native visual refresh waits until combat ends")
        world.reloads = world.reloads + 1
        self.RenderFrame("themeReload")
        self.v2:ConvertThemes()
        self.SetupArrow()
        if self.v2:IsGuideWindowEnabled() then
            self.v2:UpdateGuideWindow()
            self.v2:GetGuideWindow():UpdateTheme({})
            self.v2:UpdateActiveStepTheme()
        end
    end
    if options.incompatible then rxp.RegisterTheme = nil end
    local library = {}
    function library:GetAddon(name, silent)
        assert(name == "RXPGuides" and silent == true, "resolve native addon through AceAddon")
        return world.available and rxp or nil
    end
    local env = setmetatable({
        LibStub = function(name, silent)
            assert(name == "AceAddon-3.0" and silent == true)
            return library
        end,
        RXPGuides = { RegisterTheme = function() error("the global guide API is not the AceAddon instance") end },
        GameFontHighlight = { GetFont = function() return "Fonts\\FRIZQT__.TTF", 12, "" end },
        InCombatLockdown = function() return world.combat end,
        C_Timer = { After = function(delay, callback)
            assert(delay == 0, "native initialization is retried on the following tick")
            world.timers[#world.timers + 1] = callback
        end },
        hooksecurefunc = function(owner, method, callback)
            local original = assert(owner[method])
            world.hooks = world.hooks + 1
            owner[method] = function(...)
                local result = { original(...) }
                callback(...)
                return unpack(result)
            end
        end,
    }, { __index = _G })
    env._G = env
    function addon:RegisterGameEvents(events, callback)
        local frame = {}
        for _, event in ipairs(events) do world.events[event] = callback end
        function frame:RegisterEvent(event) world.events[event] = callback end
        function frame:UnregisterEvent(event) world.events[event] = nil end
        return frame
    end
    function addon:Notify(event) world.notifications[#world.notifications + 1] = event end
    function world:fire(event, ...)
        if self.events[event] then self.events[event](addon, event, ...) end
    end
    function world:tick()
        local timers = self.timers
        self.timers = {}
        for _, callback in ipairs(timers) do callback() end
    end
    local function Load(path)
        local chunk = assert(loadfile(path))
        setfenv(chunk, env)("LockInTools", addon)
    end
    world.nativeV1, world.nativeV2 = Copy(rxp.themes["RXP Blue"]), Copy(rxp.v2.themes["RXP Blue V2"])
    Load("Theme.lua")
    Load("RestedXPAdapter.lua")
    Load("RestedXPSkin.lua")
    addon:InitializeRestedXPSkin()
    return addon, world, rxp, Load
end

local function SameColor(actual, expected)
    assert(type(actual) == "table", "theme exposes a native color table")
    for index = 1, #expected do assert(actual[index] == expected[index], "skin uses the LockInTools palette") end
end

local function SameData(actual, expected)
    assert(type(actual) == type(expected), "native theme data retains its type")
    if type(expected) ~= "table" then
        assert(actual == expected, "native theme data must remain unchanged")
        return
    end
    for key, value in pairs(expected) do SameData(actual[key], value) end
    for key in pairs(actual) do assert(expected[key] ~= nil, "native themes must not acquire skin data") end
end

do
    local addon, world, rxp = Fixture()
    local state = addon:GetRestedXPSkinState()
    assert(not addon:IsRestedXPSkinEnabled() and not state.enabled and state.available and not state.active)
    assert(addon:GetRestedXPBackgroundTransparency() == 0 and not addon:IsRestedXPModernScrollbarEnabled(),
        "background transparency and modern scrolling default to the native appearance")
    assert(addon.db.restedxpSkin == nil and rxp.settings.profile.activeTheme == "RXP Blue" and world.renders == 0,
        "the optional skin defaults off without changing native preferences or rendering")
    assert(world.registered == 1 and type(rxp:GetThemeOptions().LockInTools) == "string",
        "the LockInTools theme is available in the native chooser even when automatic application is off")
    rxp.v2.enabled = true
    assert(type(rxp:GetThemeOptions().LockInTools) == "string", "the native V2 chooser also lists the theme")
    rxp.v2.enabled = false
    addon:InitializeRestedXPSkin()
    assert(world.registered == 1, "repeated initialization does not register the theme again")
    assert(not addon:IsRestedXPSkinOverridesEnabled(), "extra frame styling defaults off")
    assert(addon:SetRestedXPSkinOverridesEnabled(true))
    assert(addon:SetRestedXPSkinEnabled(true))
    assert(addon:IsRestedXPSkinEnabled() and addon:GetRestedXPSkinState().active
        and rxp.settings.profile.activeTheme == "LockInTools" and world.renders > 0)
    assert(addon.db.restedxpSkin.previousThemes.Default == "RXP Blue", "remember the native theme before opting in")
    local palette, theme = addon.Theme:GetPalette(), rxp.themes.LockInTools
    SameColor(theme.background, palette.background)
    SameColor(theme.textColor, palette.text)
    SameColor(theme.mapPins, palette.accent)
    assert(theme.texturePath == rxp.themes["RXP Blue"].texturePath,
        "native arrow and icon textures retain their own artwork")
    assert(rxp.RXPFrame.backdrop.edge.edgeSize == 1 and rxp.RXPFrame.backdrop.guideName.insets.left == 1
        and rxp.RXPFrame.GuideName.bg.path == nil and rxp.RXPFrame.Footer.bg.path == nil,
        "the legacy guide uses thin borders and flat headers")
    SameColor(rxp.RXPFrame.BottomFrame.color, palette.border)
    rxp:LoadActiveTheme()
    rxp.RXPFrame.UpdateVisuals()
    rxp.SetupGuideWindow()
    assert(rxp.RXPFrame.GuideName.bg.path == nil and rxp.RXPFrame.Footer.bg.path == nil,
        "native redraws retain the flat skin")
    assert(addon:SetRestedXPSkinEnabled(true))
    assert(addon.db.restedxpSkin.previousThemes.Default == "RXP Blue", "repeated opt-in retains the restore target")
    assert(addon:SetRestedXPSkinEnabled(false))
    assert(not addon:IsRestedXPSkinEnabled() and rxp.settings.profile.activeTheme == "RXP Blue",
        "opting out restores the original native theme")
    assert(rxp.RXPFrame.backdrop.edge.edgeSize == 16 and rxp.RXPFrame.backdrop.guideName.insets.left == 4
        and rxp.RXPFrame.GuideName.bg.path == "native-banner",
        "opting out restores legacy frame metadata and native headers")
end

for _, v2 in ipairs({ false, true }) do
    local addon, world, rxp = Fixture(nil, { v2 = v2 })
    rxp.settings.profile.activeTheme = "LockInTools"
    rxp:ReloadTheme()
    assert(addon:GetRestedXPSkinState().active and not addon:IsRestedXPSkinEnabled()
        and addon.db.restedxpSkin == nil, "native theme selection works independently of automatic application")
    assert(rxp.RXPFrame.backdrop.edge.edgeSize == 16 and rxp.RXPFrame.GuideName.bg.path == "native-banner",
        "the default theme keeps native legacy header artwork and border geometry")
    if v2 then
        assert(rxp.v2.themes.LockInTools.headerTexture.path == "native-header")
        SameColor(rxp.v2.state.guideWindow.title.color, rxp.v2.state.guideWindow.title.nativeColor)
    end
    local renders = world.renders
    addon:RefreshRestedXPSkin()
    assert(rxp.settings.profile.activeTheme == "LockInTools" and world.renders == renders
        and addon.db.restedxpSkin == nil, "login refresh preserves a manually chosen theme with automatic application off")
    local reloaded = Fixture(addon.db, { v2 = v2 }, rxp)
    assert(rxp.settings.profile.activeTheme == "LockInTools" and reloaded.db.restedxpSkin == nil,
        "UI reload preserves native selection without creating a LockInTools preference")
    rxp:ReloadTheme()
    assert(rxp.RXPFrame.backdrop.edge.edgeSize == 16 and rxp.RXPFrame.GuideName.bg.path == "native-banner")
    if v2 then SameColor(rxp.v2.state.guideWindow.title.color, rxp.v2.state.guideWindow.title.nativeColor) end
end

for _, v2 in ipairs({ false, true }) do
    local addon, _, rxp = Fixture(nil, { v2 = v2 })
    rxp.settings.profile.activeTheme = "LockInTools"
    rxp:ReloadTheme()
    assert(addon:SetRestedXPSkinOverridesEnabled(true))
    assert(addon:IsRestedXPSkinOverridesEnabled() and addon:IsRestedXPSkinEnabled() and addon:IsRestedXPModernScrollbarEnabled()
        and rxp.settings.profile.activeTheme == "LockInTools",
        "the legacy styling setter enables the grouped style while preserving a manually chosen theme")
    assert(rxp.RXPFrame.backdrop.edge.edgeSize == 1 and rxp.RXPFrame.GuideName.bg.path == nil)
    SameColor(rxp.RXPFrame.BottomFrame.color, addon.Theme:GetPalette().border)
    if v2 then
        assert(rxp.v2.themes.LockInTools.headerTexture.path == nil)
        SameColor(rxp.v2.state.guideWindow.title.color, addon.Theme:GetPalette().accent)
    end
    assert(addon:SetRestedXPSkinOverridesEnabled(false))
    assert(not addon:IsRestedXPSkinOverridesEnabled() and not addon:IsRestedXPSkinEnabled()
        and rxp.settings.profile.activeTheme == "LockInTools",
        "opting out of the grouped style preserves a theme chosen manually beforehand")
    assert(rxp.RXPFrame.backdrop.edge.edgeSize == 16 and rxp.RXPFrame.GuideName.bg.path == "native-banner")
    if v2 then
        assert(rxp.v2.themes.LockInTools.headerTexture.path == "native-header")
        SameColor(rxp.v2.state.guideWindow.title.color, rxp.v2.state.guideWindow.title.nativeColor)
    end
end

do
    local addon, _, rxp = Fixture()
    rxp.settings.profile.activeTheme = "Custom"
    assert(addon:SetRestedXPSkinEnabled(true))
    local reloaded = Fixture(addon.db, {}, rxp)
    assert(reloaded:GetRestedXPSkinState().active
        and reloaded.db.restedxpSkin.previousThemes.Default == "Custom",
        "SavedVariables preserve the restore target through a UI reload")
    assert(reloaded:SetRestedXPSkinEnabled(false) and rxp.settings.profile.activeTheme == "Custom")
end

do
    local addon, _, rxp = Fixture()
    assert(addon:SetRestedXPSkinOverridesEnabled(true))
    assert(addon:SetRestedXPSkinEnabled(true))
    local border = addon.Theme:GetPalette().border
    local step = rxp.SetStep(true)
    local item = rxp.CreateActiveItemFrame()
    local target = rxp.targeting.CreateTargetFrame()
    for _, panel in ipairs({ step, step.number, item, item.title, target, target.title }) do
        SameColor(panel.color, border)
    end
    rxp.SetStep(false)
    item:UpdateVisuals()
    target:UpdateVisuals()
    rxp.targeting.RenderTargetFrameBackground()
    for _, panel in ipairs({ step, step.number, item, item.title, target, target.title }) do
        SameColor(panel.color, border)
    end
    local nextStep = rxp.SetStep(true)
    local nextItem = rxp.CreateActiveItemFrame()
    local nextTarget = rxp.targeting.CreateTargetFrame()
    for _, panel in ipairs({ nextStep, nextStep.number, nextItem, nextItem.title, nextTarget, nextTarget.title }) do
        SameColor(panel.color, border)
    end
    assert(addon:SetRestedXPSkinEnabled(false))
    for _, panel in ipairs({ step, step.number, item, item.title, target, target.title,
        nextStep, nextStep.number, nextItem, nextItem.title, nextTarget, nextTarget.title }) do
        SameColor(panel.color, panel.nativeColor)
    end
    nextItem:UpdateVisuals()
    nextTarget:UpdateVisuals()
    rxp.targeting.RenderTargetFrameBackground()
    SameColor(nextItem.color, nextItem.nativeColor)
    SameColor(nextTarget.color, nextTarget.nativeColor)
end

do
    local addon, _, rxp = Fixture()
    assert(addon:SetRestedXPSkinEnabled(true))
    rxp.settings.profile.activeTheme = "Custom"
    rxp:LoadActiveTheme()
    assert(not addon:GetRestedXPSkinState().active, "native selection can replace the enabled skin")
    assert(addon:SetRestedXPSkinEnabled(false) and rxp.settings.profile.activeTheme == "Custom",
        "opting out preserves a theme selected manually in RestedXP")
end

do
    local addon, _, rxp = Fixture()
    rxp.settings.profile.activeTheme = "LockInTools"
    rxp:ReloadTheme()
    assert(addon:SetRestedXPSkinEnabled(true) and addon:SetRestedXPSkinEnabled(false))
    assert(rxp.settings.profile.activeTheme == "LockInTools",
        "automatic application never takes ownership of a theme already selected manually")
    rxp.settings.profile.activeTheme = "RXP Blue"
    rxp:ReloadTheme()
    assert(addon:SetRestedXPSkinEnabled(true) and addon:SetRestedXPSkinEnabled(false))
    rxp.settings.profile.activeTheme = "LockInTools"
    rxp:ReloadTheme()
    assert(addon:SetRestedXPSkinEnabled(true) and addon:SetRestedXPSkinEnabled(false))
    assert(rxp.settings.profile.activeTheme == "LockInTools",
        "a later manual selection replaces ownership from a previous automatic session")
end

do
    local addon, world, rxp = Fixture()
    assert(addon:SetRestedXPSkinEnabled(true))
    local originalProfile = rxp.settings.profile
    world.profileName = "Other character"
    rxp.settings.profile = { activeTheme = "Custom", enableThemeLiveReload = true }
    assert(addon:SetRestedXPSkinEnabled(true))
    assert(addon.db.restedxpSkin.previousThemes.Default == "RXP Blue"
        and addon.db.restedxpSkin.previousThemes["Other character"] == "Custom",
        "each native profile keeps its own previous theme")
    assert(addon:SetRestedXPSkinEnabled(false) and rxp.settings.profile.activeTheme == "Custom")
    rxp.settings.profile, world.profileName = originalProfile, "Default"
    assert(addon:SetRestedXPSkinEnabled(false) and rxp.settings.profile.activeTheme == "RXP Blue",
        "a later opt-out can restore another native profile too")
end

do
    local addon, world, rxp = Fixture()
    assert(addon:SetRestedXPSkinEnabled(true))
    local first = rxp.settings.profile
    local second = { activeTheme = "Custom", enableThemeLiveReload = true }
    rxp.settings.profile, world.profileName = second, "Other character"
    assert(addon:SetRestedXPSkinEnabled(true) and addon:SetRestedXPSkinEnabled(false))
    assert(second.activeTheme == "Custom")
    assert(addon:SetRestedXPSkinEnabled(true))
    rxp.settings.profile, world.profileName = first, "Default"
    addon:RefreshRestedXPSkin()
    assert(first.activeTheme == "LockInTools" and addon:GetRestedXPSkinState().active,
        "re-enabling automatic application cancels a pending cross-profile opt-out")
    assert(addon:SetRestedXPSkinEnabled(false) and first.activeTheme == "RXP Blue")
    rxp.settings.profile, world.profileName = second, "Other character"
    addon:RefreshRestedXPSkin()
    assert(second.activeTheme == "Custom",
        "a later opt-out still restores each profile after automatic application was re-enabled")
end

do
    local addon, world, rxp = Fixture()
    assert(addon:SetRestedXPSkinEnabled(true))
    local first = rxp.settings.profile
    rxp.settings.profile, world.profileName = { activeTheme = "Custom", enableThemeLiveReload = true }, "Other character"
    assert(addon:SetRestedXPSkinEnabled(true) and addon:SetRestedXPSkinEnabled(false))
    rxp.settings.profile.activeTheme = "LockInTools"
    rxp:ReloadTheme()
    addon:RefreshRestedXPSkin()
    assert(rxp.settings.profile.activeTheme == "LockInTools", "another profile's pending restoration cannot claim a manual native theme")
    local reloaded, reloadedWorld = Fixture(addon.db, { profileName = "Other character" }, rxp)
    assert(rxp.settings.profile.activeTheme == "LockInTools" and not reloaded:IsRestedXPSkinEnabled(),
        "reload preserves the manual theme while restoration remains pending for another character")
    rxp.settings.profile, reloadedWorld.profileName = first, "Default"
    reloaded:RefreshRestedXPSkin()
    assert(first.activeTheme == "RXP Blue", "preserving one manual choice does not discard restoration owed to another profile")
end

do
    local addon, world, rxp = Fixture(nil, { available = false })
    assert(not addon:GetRestedXPSkinState().available)
    assert(addon:SetRestedXPSkinEnabled(true) and addon:IsRestedXPSkinEnabled(),
        "users can save the optional skin preference before RestedXP is loaded")
    assert(world.registered == 0 and world.renders == 0 and rxp.settings.profile.activeTheme == "RXP Blue")
    world.available = true
    world:fire("ADDON_LOADED", "UnrelatedAddon")
    assert(rxp.settings.profile.activeTheme == "RXP Blue", "only the native addon load triggers a retry")
    world:fire("ADDON_LOADED", "RXPGuides")
    assert(rxp.settings.profile.activeTheme == "RXP Blue", "native initialization finishes before applying the skin")
    world:tick()
    assert(addon:GetRestedXPSkinState().active and rxp.settings.profile.activeTheme == "LockInTools",
        "late native availability applies the saved preference")
end

do
    local addon, world, rxp = Fixture(nil, { available = false })
    assert(world.registered == 0 and addon.db.restedxpSkin == nil)
    world.available = true
    world:fire("ADDON_LOADED", "RXPGuides")
    world:tick()
    assert(world.registered == 1 and type(rxp:GetThemeOptions().LockInTools) == "string"
        and rxp.settings.profile.activeTheme == "RXP Blue" and world.renders == 0
        and addon.db.restedxpSkin == nil,
        "loading RestedXP later registers the theme without opting in or changing its current appearance")
end

do
    local addon, world, rxp = Fixture(nil, { incompatible = true })
    assert(addon:SetRestedXPSkinEnabled(true) and addon:IsRestedXPSkinEnabled())
    assert(not addon:GetRestedXPSkinState().available and type(addon:GetRestedXPSkinState().problem) == "string",
        "a loaded addon without the theme API reports skin unavailability")
    assert(world.renders == 0 and rxp.settings.profile.activeTheme == "RXP Blue",
        "missing native capabilities preserve the opt-in without partially changing RestedXP")
end

do
    local addon, world, rxp = Fixture(nil, { combat = true })
    assert(addon:SetRestedXPSkinEnabled(true))
    assert(addon:GetRestedXPSkinState().pending and rxp.settings.profile.activeTheme == "RXP Blue"
        and world.renders == 0, "combat defers native theme selection and rendering")
    world.combat = false
    world:fire("PLAYER_REGEN_ENABLED")
    assert(addon:GetRestedXPSkinState().active and not addon:GetRestedXPSkinState().pending)
    world.combat = true
    local renders = world.renders
    assert(addon:SetRestedXPSkinEnabled(false))
    assert(addon:GetRestedXPSkinState().pending and rxp.settings.profile.activeTheme == "LockInTools"
        and world.renders == renders, "combat also defers restoring the original theme")
    world.combat = false
    world:fire("PLAYER_REGEN_ENABLED")
    assert(not addon:GetRestedXPSkinState().pending and rxp.settings.profile.activeTheme == "RXP Blue")
end

do
    local addon, world, rxp = Fixture(nil, { combat = true })
    assert(addon:SetRestedXPSkinEnabled(true) and addon:SetRestedXPSkinEnabled(false))
    world.combat = false
    world:fire("PLAYER_REGEN_ENABLED")
    assert(not addon:GetRestedXPSkinState().active and rxp.settings.profile.activeTheme == "RXP Blue"
        and world.renders == 0, "opting out before combat ends cancels a pending application")
end

do
    local addon, world, rxp = Fixture(nil, { v2 = true, liveReload = false })
    local nativeBase = Copy(rxp.v2.themes["RXP Blue V2"])
    assert(addon:SetRestedXPSkinOverridesEnabled(true))
    assert(addon:SetRestedXPSkinEnabled(true))
    local theme = rxp.v2.themes.LockInTools
    assert(not addon:GetRestedXPSkinState().problem and world.guideThemes > 0,
        "the V2 guide can render the skin through its native backdrop path")
    assert(theme and theme.version > (rxp.themes.LockInTools.version or 1),
        "explicit V2 data survives the native V1 conversion pass")
    assert(theme.headerTexture.path == nil, "V2 uses the flat LockInTools header")
    SameColor(theme.backgroundColors.guideWindow, addon.Theme:GetPalette().background)
    SameColor(theme.textColor.common, addon.Theme:GetPalette().text)
    SameColor(rxp.v2.state.guideWindow.title.color, addon.Theme:GetPalette().accent)
    rxp.v2.state.guideWindow:UpdateSubTheme()
    SameColor(rxp.v2.state.guideWindow.title.color, addon.Theme:GetPalette().accent)
    rxp.v2:ConvertThemes()
    assert(rxp.v2.themes.LockInTools == theme, "native theme refresh keeps the explicit V2 skin")
    assert(rxp.v2.themes["RXP Blue V2"].headerTexture.path == nativeBase.headerTexture.path,
        "building the skin does not mutate RestedXP's base theme")
    assert(rxp.settings.profile.enableThemeLiveReload == false and world.renders > 0,
        "an explicit skin toggle refreshes visuals while preserving the native live-preview preference")
    assert(addon:SetRestedXPSkinEnabled(false) and rxp.settings.profile.activeTheme == "RXP Blue"
        and rxp.settings.profile.enableThemeLiveReload == false)
    SameColor(rxp.v2.state.guideWindow.title.color, rxp.v2.state.guideWindow.title.nativeColor)
end

do
    local saved = { restedxpSkin = { enabled = true, previousThemes = { Default = "Custom" } } }
    local snapshot = Copy(saved.restedxpSkin)
    local addon, world, rxp = Fixture(saved, { readOnly = true })
    assert(not addon:SetRestedXPSkinEnabled(false), "newer-schema preferences reject edits")
    assert(not addon:SetRestedXPSkinOverridesEnabled(true), "newer-schema preferences also reject extra styling edits")
    assert(saved.restedxpSkin.enabled == snapshot.enabled
        and saved.restedxpSkin.previousThemes.Default == snapshot.previousThemes.Default
        and saved.restedxpSkin.overrides == nil
        and rxp.settings.profile.activeTheme == "RXP Blue" and world.renders == 0
        and world.registered == 1 and type(rxp:GetThemeOptions().LockInTools) == "string",
        "read-only initialization registers the theme while preserving saved data and native selection")
end

do
    local addon, world, rxp = Fixture()
    world.failNextRender = true
    assert(addon:SetRestedXPSkinEnabled(true))
    local state = addon:GetRestedXPSkinState()
    assert(not state.active and rxp.settings.profile.activeTheme == "RXP Blue",
        "a failed native refresh rolls selection back to its prior theme")
    assert(type(state.problem) == "string" and not state.problem:find("private", 1, true),
        "native failures report a generic skin problem without exposing native error details")
    assert(addon:SetRestedXPSkinEnabled(true) and addon:GetRestedXPSkinState().active,
        "users can retry the saved skin preference after a native failure")
end

do
    local addon, _, _, Load = Fixture()
    assert(addon:SetRestedXPSkinEnabled(true))
    local preference = addon.db.restedxpSkin
    addon.db.restedxp = { sourceBattleTag = "Source#1234", groups = { obsolete = "guide payload" } }
    Load("RestedXP.lua")
    addon:CleanupRestedXPData(true)
    assert(addon.db.restedxpSkin == preference and addon:IsRestedXPSkinEnabled()
        and addon.db.restedxp.sourceBattleTag == "Source#1234" and addon.db.restedxp.groups == nil,
        "obsolete importer cleanup preserves the separate skin preference")
end

do
    local saved = { restedxpSkin = { backgroundTransparency = 50 } }
    local snapshot = Copy(saved)
    local addon, world, rxp = Fixture(saved)
    assert(addon:GetRestedXPBackgroundTransparency() == 50)
    assert(rxp.themes.LockInTools.background[4] == addon.Theme:GetPalette().background[4])
    assert(rxp.settings.profile.activeTheme == "RXP Blue" and world.renders == 0,
        "saved transparency configures the registered theme without selecting it or rendering native frames")
    SameData(saved, snapshot)
end

do
    local addon = Fixture()
    assert(not addon:IsRestedXPSkinEnabled() and not addon:IsRestedXPSkinOverridesEnabled()
        and not addon:IsRestedXPModernScrollbarEnabled())
    assert(addon:SetRestedXPSkinEnabled(true))
    assert(addon:IsRestedXPSkinEnabled() and addon:IsRestedXPSkinOverridesEnabled()
        and addon:IsRestedXPModernScrollbarEnabled(), "enabling the RestedXP style includes its frame styling and modern scrollbar")
    assert(addon:SetRestedXPSkinEnabled(false))
    assert(not addon:IsRestedXPSkinEnabled() and not addon:IsRestedXPSkinOverridesEnabled()
        and not addon:IsRestedXPModernScrollbarEnabled(), "one opt-out disables the combined RestedXP style")
end

for _, enabled in ipairs({ false, true }) do
    local saved = { restedxpSkin = { enabled = enabled, overrides = not enabled, modernScrollbar = not enabled } }
    local addon, world, rxp = Fixture(saved)
    assert(addon:IsRestedXPSkinEnabled() == enabled and addon:IsRestedXPSkinOverridesEnabled() == enabled
        and addon:IsRestedXPModernScrollbarEnabled() == enabled,
        "the grouped checkbox consistently determines all style effects for older mixed preferences")
    assert(saved.restedxpSkin.overrides == not enabled and saved.restedxpSkin.modernScrollbar == not enabled,
        "normalizing effective bundled behavior does not rewrite older preference fields")
    if enabled then
        assert(rxp.settings.profile.activeTheme == "LockInTools" and rxp.RXPFrame.backdrop.edge.edgeSize == 1)
    else
        assert(rxp.settings.profile.activeTheme == "RXP Blue" and world.renders == 0)
        rxp.settings.profile.activeTheme = "LockInTools"
        rxp:ReloadTheme()
        assert(rxp.RXPFrame.backdrop.edge.edgeSize == 16 and rxp.RXPFrame.GuideName.bg.path == "native-banner",
            "older extras flags cannot apply hidden styling when the grouped checkbox is off")
    end
end

for _, v2 in ipairs({ false, true }) do
    local addon, world, rxp = Fixture(nil, { v2 = v2 })
    local originalV1, originalV2 = Copy(rxp.themes.LockInTools), Copy(rxp.v2.themes.LockInTools)
    rxp.settings.profile.activeTheme = "LockInTools"
    rxp:ReloadTheme()
    for _, percent in ipairs({ 0, 50, 100 }) do
        assert(addon:SetRestedXPBackgroundTransparency(percent))
        world:tick()
        assert(addon:GetRestedXPBackgroundTransparency() == percent
            and (percent == 0 or addon.db.restedxpSkin.backgroundTransparency == percent)
            and not addon:IsRestedXPSkinEnabled() and rxp.settings.profile.activeTheme == "LockInTools",
            "transparency is independent of automatic theme selection")
        SameData(rxp.themes.LockInTools, originalV1)
        SameData(rxp.v2.themes.LockInTools, originalV2)
    end
    SameData(rxp.themes["RXP Blue"], world.nativeV1)
    SameData(rxp.v2.themes["RXP Blue V2"], world.nativeV2)
    assert(addon:SetRestedXPBackgroundTransparency(0))
    world:tick()
    SameData(rxp.themes.LockInTools, originalV1)
    SameData(rxp.v2.themes.LockInTools, originalV2)
    assert(addon:SetRestedXPBackgroundTransparency(50))
    world:tick()
    rxp.settings.profile.activeTheme = "Custom"
    rxp:ReloadTheme()
    assert(rxp.settings.profile.activeTheme == "Custom" and addon:GetRestedXPBackgroundTransparency() == 50,
        "native theme selection remains independent of the saved transparency")
    rxp.settings.profile.activeTheme = "LockInTools"
    rxp:ReloadTheme()
    local reloaded = Fixture(addon.db, { v2 = v2 }, rxp)
    assert(reloaded:GetRestedXPBackgroundTransparency() == 50 and rxp.settings.profile.activeTheme == "LockInTools"
        and not reloaded:IsRestedXPSkinEnabled(), "reload preserves transparency and a manually chosen native theme")
end

do
    local addon, world, rxp, Load = Fixture(nil, { available = false })
    assert(addon:SetRestedXPBackgroundTransparency(41.7) and addon:GetRestedXPBackgroundTransparency() == 42)
    assert(addon:SetRestedXPModernScrollbarEnabled(true) and addon:IsRestedXPModernScrollbarEnabled(),
        "optional appearance preferences can be edited before RestedXP is available")
    assert(addon:SetRestedXPBackgroundTransparency(-25) and addon:GetRestedXPBackgroundTransparency() == 0)
    assert(addon:SetRestedXPBackgroundTransparency(125) and addon:GetRestedXPBackgroundTransparency() == 100,
        "finite transparency values are clamped to the supported percentage range")
    for _, invalid in ipairs({ "50", false, math.huge, -math.huge, 0 / 0 }) do
        assert(not addon:SetRestedXPBackgroundTransparency(invalid)
            and addon:GetRestedXPBackgroundTransparency() == 100, "non-finite and nonnumeric edits cannot replace the saved value")
    end
    assert(not addon:SetRestedXPBackgroundTransparency(nil))
    assert(not addon:SetRestedXPModernScrollbarEnabled("yes") and addon:IsRestedXPModernScrollbarEnabled())
    assert(addon:SetRestedXPBackgroundTransparency(50))
    local preference = addon.db.restedxpSkin
    addon.db.restedxp = { sourceBattleTag = "Source#1234", groups = { stale = "obsolete payload" } }
    Load("RestedXP.lua")
    assert(addon:CleanupRestedXPData(true) and addon.db.restedxpSkin == preference
        and addon:GetRestedXPBackgroundTransparency() == 50 and addon:IsRestedXPModernScrollbarEnabled(),
        "importer cleanup preserves independent appearance preferences")
    world.available = true
    world:fire("ADDON_LOADED", "RXPGuides")
    world:tick()
    assert(rxp.themes.LockInTools.background[4] == addon.Theme:GetPalette().background[4]
        and rxp.settings.profile.activeTheme == "LockInTools" and addon:IsRestedXPSkinEnabled()
        and world.renders > 0, "late native availability applies the saved grouped style without changing baseline theme alpha")
end

do
    local addon, world, rxp = Fixture()
    rxp.settings.profile.activeTheme = "LockInTools"
    rxp:ReloadTheme()
    local first = rxp.settings.profile
    rxp.settings.profile, world.profileName = { activeTheme = "Custom", enableThemeLiveReload = true }, "Other character"
    local renders = world.renders
    assert(addon:SetRestedXPBackgroundTransparency(25) and rxp.settings.profile.activeTheme == "Custom"
        and world.renders == renders, "appearance changes leave another native profile's selected theme untouched")
    world:tick()
    rxp.settings.profile, world.profileName = first, "Default"
    addon:RefreshRestedXPSkin()
    world.combat = true
    renders = world.renders
    assert(addon:SetRestedXPBackgroundTransparency(75) and addon:GetRestedXPBackgroundTransparency() == 75
        and world.renders == renders, "combat saves appearance edits without rerendering the native guide")
    world:tick()
    world.combat = false
    world:fire("PLAYER_REGEN_ENABLED")
    world:tick()
    assert(not addon:GetRestedXPSkinState().pending and world.renders == renders
        and addon:GetRestedXPBackgroundTransparency() == 75
        and rxp.themes.LockInTools.background[4] == addon.Theme:GetPalette().background[4]
        and rxp.settings.profile.activeTheme == "LockInTools", "appearance edits settle through combat without rerendering the selected native guide")
end

do
    local saved = { restedxpSkin = { backgroundTransparency = 35, modernScrollbar = true } }
    local snapshot = Copy(saved)
    local addon, _, rxp = Fixture(saved, { readOnly = true })
    assert(not addon:SetRestedXPBackgroundTransparency(50) and not addon:SetRestedXPModernScrollbarEnabled(false),
        "newer-schema preferences reject both new appearance edits")
    SameData(saved, snapshot)
    assert(rxp.settings.profile.activeTheme == "RXP Blue")
end

for _, v2 in ipairs({ false, true }) do
    local addon, world, rxp = Fixture(nil, { v2 = v2 })
    rxp.settings.profile.activeTheme = "LockInTools"
    rxp:ReloadTheme()
    local source, converted = rxp.themes.LockInTools, rxp.v2.themes.LockInTools
    local originalV1, originalV2 = Copy(source), Copy(converted)
    -- Native layer rendering has its own suite; this harness observes core dispatch.
    local paint = addon.RefreshRestedXPTransparency
    local painted = {}
    function addon:RefreshRestedXPTransparency(...)
        painted[#painted + 1] = self:GetRestedXPBackgroundTransparency()
        if paint then return paint(self, ...) end
    end
    local renders, reloads, guideReloads, registrations = world.renders, world.reloads, world.guideReloads, world.registered
    for percent = 0, 100 do assert(addon:SetRestedXPBackgroundTransparency(percent)) end
    world:tick()
    assert(world.renders == renders and world.reloads == reloads and world.guideReloads == guideReloads and world.registered == registrations,
        "dragging the transparency slider never reloads guides, rerenders native frames or registers themes again")
    assert(rxp.themes.LockInTools == source and rxp.v2.themes.LockInTools == converted,
        "slider paints keep the existing registered theme tables")
    assert(addon:GetRestedXPBackgroundTransparency() == 100 and #painted == 1 and painted[1] == 100,
        "a burst of slider edits coalesces into one lightweight paint using its latest value")
    SameData(source, originalV1)
    SameData(converted, originalV2)
    assert(addon:SetRestedXPBackgroundTransparency(0))
    world:tick()
    assert(addon:GetRestedXPBackgroundTransparency() == 0 and #painted == 2 and painted[2] == 0,
        "returning the slider to zero schedules one lightweight restoration")
    SameData(source, originalV1)
    SameData(converted, originalV2)
    assert(world.renders == renders and world.reloads == reloads and world.guideReloads == guideReloads and world.registered == registrations,
        "restoring opacity also avoids the native guide reload path")
end

print("PASS: optional RestedXP skin lifecycle, appearance preferences and combat deferral")
