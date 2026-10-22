local _, addon = ...
local NAME = "LockInTools"
local WHITE = "Interface/Buttons/WHITE8X8"

local function Copy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, child in pairs(value) do copy[key] = Copy(child) end
    return copy
end

local function InCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown()
end

local function Installation()
    local rxp = addon:GetRestedXPAddon()
    if not rxp then return nil, "Enable RestedXP to use the skin." end
    if type(rxp.settings) ~= "table" or type(rxp.settings.profile) ~= "table" then
        return nil, "RestedXP is still loading."
    end
    if type(rxp.RegisterTheme) ~= "function" or type(rxp.ReloadTheme) ~= "function"
        or type(rxp.RenderFrame) ~= "function" or type(rxp.LoadActiveTheme) ~= "function"
        or type(rxp.themes) ~= "table" or type(rxp.themes["RXP Blue"]) ~= "table" then
        return nil, "This RestedXP version does not support the LockInTools skin."
    end
    return rxp
end

local function ProfileKey(rxp)
    if type(rxp.settings.GetSettingsDB) == "function" then
        local success, name = pcall(rxp.settings.GetSettingsDB)
        if success and type(name) == "string" then return name end
    end
    return "Default"
end

function addon:IsRestedXPSkinEnabled()
    local settings = self.db and self.db.restedxpSkin
    return not self.savedDataReadOnly and type(settings) == "table" and settings.enabled == true
end

function addon:IsRestedXPSkinOverridesEnabled()
    -- Earlier builds saved these separately. The visible skin switch now owns
    -- both effects, including profiles with mixed legacy preference values.
    return self:IsRestedXPSkinEnabled()
end

function addon:IsRestedXPChromeHidden()
    local settings = self.db and self.db.restedxpSkin
    return not self.savedDataReadOnly and type(settings) == "table" and settings.hideChrome == true
end

function addon:IsRestedXPModernScrollbarEnabled()
    return self:IsRestedXPSkinEnabled()
end

local function Transparency(value)
    if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then return nil end
    return math.floor(math.max(0, math.min(100, value)) + 0.5)
end

function addon:GetRestedXPBackgroundTransparency()
    local settings = self.db and self.db.restedxpSkin
    if self.savedDataReadOnly or type(settings) ~= "table" then return 0 end
    return Transparency(settings.backgroundTransparency) or 0
end

local function Selected(rxp)
    return rxp.settings.profile.activeTheme == NAME and rxp.activeTheme and rxp.activeTheme.name == NAME
end

local function Overrides(rxp)
    return Selected(rxp) and addon:IsRestedXPSkinOverridesEnabled()
end

local function RegisterThemes(rxp, overrides)
    local palette = addon.Theme:GetPalette()
    local theme = Copy(rxp.themes["RXP Blue"])
    theme.name, theme.displayName, theme.author, theme.version = NAME, NAME, NAME, 1
    theme.applicable = true
    theme.background, theme.bottomFrameBG = palette.background, palette.surface
    theme.bottomFrameHighlight, theme.mapPins = palette.accent, Copy(palette.accent)
    theme.textColor, theme.font = palette.text, addon.Theme:GetFont() or theme.font
    theme.tooltip = string.format("|cff%02x%02x%02x", palette.accent[1] * 255,
        palette.accent[2] * 255, palette.accent[3] * 255)
    if overrides then
        theme.bgTextures = { edge = WHITE, bottom = WHITE, guideName = WHITE }
        theme.edges = { edge = WHITE, guideName = WHITE }
    end
    -- Keep RXP's texture directory: arrow, class and interaction icons remain native.
    rxp:RegisterTheme(theme)

    local v2 = rxp.v2
    if v2 and type(v2.themes) == "table" and type(v2.themes["RXP Blue V2"]) == "table" then
        local converted = Copy(v2.themes["RXP Blue V2"])
        converted.name, converted.displayName, converted.author = NAME, NAME, NAME
        -- ConvertThemes preserves a V2 entry newer than its V1 source. Its normal
        -- conversion otherwise leaves several blue backgrounds and changes map pins.
        converted.version, converted.applicable = 2, true
        converted.font, converted.mapPins = theme.font, Copy(palette.accent)
        if overrides then converted.headerTexture = { texCoords = { 0, 1, 0, 1 } } end
        for key in pairs(converted.backgroundColors) do converted.backgroundColors[key] = Copy(palette.surface) end
        converted.backgroundColors.guideWindow = Copy(palette.background)
        converted.backgroundColors.guideName = Copy(palette.background)
        converted.backgroundColors.activeStepCheckboxChecked = Copy(palette.accent)
        for key in pairs(converted.borderColors) do converted.borderColors[key] = Copy(palette.border) end
        converted.borderColors.activeStepCheckboxChecked = Copy(palette.accent)
        for key in pairs(converted.textColor) do converted.textColor[key] = Copy(palette.text) end
        converted.textColor.title, converted.textColor.inactivePartyTab = Copy(palette.accent), Copy(palette.muted)
        if overrides then
            converted.edge.edgeFile, converted.edge.edgeSize = WHITE, 1
            for key in pairs(converted.edge.texCoords) do converted.edge.texCoords[key] = { 0, 1, 0, 1 } end
        end
        v2.themes[NAME] = converted
    end
end

local function HookVisuals(rxp, state)
    if type(hooksecurefunc) ~= "function" then return end
    local function Hook(owner, method, callback)
        if not owner or type(owner[method]) ~= "function" then return end
        local methods = state.hooked[owner] or {}
        state.hooked[owner] = methods
        if not methods[method] then
            hooksecurefunc(owner, method, callback)
            methods[method] = true
        end
    end
    local palette, saved = addon.Theme:GetPalette(), nil
    local borderColors = setmetatable({}, { __mode = "k" })
    local function PaintBorder(panel)
        if not panel or type(panel.GetBackdropBorderColor) ~= "function"
            or type(panel.SetBackdropBorderColor) ~= "function" then return end
        if not borderColors[panel] then borderColors[panel] = { panel:GetBackdropBorderColor() } end
        panel:SetBackdropBorderColor(unpack(palette.border))
    end
    local function Metadata()
        local frame = rxp.RXPFrame
        if not frame or not frame.backdrop then return end
        if Overrides(rxp) then
            if not saved then
                saved = {}
                for _, key in ipairs({ "edge", "guideName" }) do
                    local backdrop = frame.backdrop[key]
                    if backdrop then saved[key] = { edgeSize = backdrop.edgeSize, insets = backdrop.insets } end
                end
            end
            for _, key in ipairs({ "edge", "guideName" }) do
                local backdrop = frame.backdrop[key]
                if backdrop then
                    backdrop.edgeSize = 1
                    backdrop.insets = { left = 1, right = 1, top = 1, bottom = 1 }
                end
            end
        elseif saved then
            for _, key in ipairs({ "edge", "guideName" }) do
                if frame.backdrop[key] and saved[key] then
                    frame.backdrop[key].edgeSize, frame.backdrop[key].insets = saved[key].edgeSize, saved[key].insets
                end
            end
            for panel, color in pairs(borderColors) do
                panel:SetBackdropBorderColor(unpack(color))
                borderColors[panel] = nil
            end
            saved = nil
        end
    end
    local function ClassicVisuals()
        local frame = rxp.RXPFrame
        if not frame then return end
        if not Overrides(rxp) then return end
        -- These banners ignore theme.headerTexture in the legacy renderer.
        for _, key in ipairs({ "GuideName", "Footer" }) do
            if frame[key] and frame[key].bg then frame[key].bg:SetTexture(nil) end
        end
        for _, key in ipairs({ "BottomFrame", "GuideName", "Footer" }) do
            PaintBorder(frame[key])
        end
    end
    local function StepVisuals()
        if not Overrides(rxp) then return end
        local current = rxp.RXPFrame and rxp.RXPFrame.CurrentStepFrame
        for _, panel in ipairs(current and current.framePool or {}) do
            PaintBorder(panel)
            PaintBorder(panel.number)
        end
    end
    local function AuxiliaryVisuals()
        local function Attach(frame)
            if not frame or frame.v2 then return end
            local function Paint()
                if Overrides(rxp) then PaintBorder(frame); PaintBorder(frame.title) end
            end
            Hook(frame, "UpdateVisuals", Paint)
            Paint()
        end
        Attach(rxp.activeItemFrame)
        Attach(rxp.targeting and rxp.targeting.activeTargetFrame)
    end
    Hook(rxp, "LoadActiveTheme", function()
        Metadata()
        addon:Notify("RESTEDXP_SKIN_CHANGED")
    end)
    Hook(rxp.RXPFrame, "UpdateVisuals", ClassicVisuals)
    Hook(rxp, "SetupGuideWindow", ClassicVisuals)
    Hook(rxp, "SetStep", StepVisuals)
    Hook(rxp, "CreateActiveItemFrame", AuxiliaryVisuals)
    Hook(rxp.targeting, "CreateTargetFrame", AuxiliaryVisuals)
    Hook(rxp.targeting, "RenderTargetFrameBackground", AuxiliaryVisuals)
    AuxiliaryVisuals()
    local function V2Visuals()
        local v2 = rxp.v2
        -- Do not acquire a disabled V2 widget just to style it.
        local window = v2 and v2.state and v2.state.guideWindow
        if not window or state.windows[window] or type(window.UpdateSubTheme) ~= "function" then return end
        local function Title()
            -- V2 hardcodes yellow here instead of reading theme.textColor.title.
            if Overrides(rxp) and window.title then window.title:SetTextColor(unpack(palette.accent)) end
        end
        Hook(window, "UpdateSubTheme", Title)
        state.windows[window] = true
        Title()
    end
    Hook(rxp.v2, "UpdateGuideWindow", V2Visuals)
    V2Visuals()
end

local function RefreshTheme(rxp)
    if rxp.settings.profile.enableThemeLiveReload then
        rxp:ReloadTheme()
        return
    end
    -- This is an explicit Apply, even when RXP's automatic theme preview is off.
    -- Follow ReloadTheme's refresh path without changing that saved preference.
    rxp.RenderFrame("themeReload")
    local v2 = rxp.v2
    if v2 and type(v2.ConvertThemes) == "function" then v2:ConvertThemes() end
    if type(rxp.SetupArrow) == "function" then rxp.SetupArrow() end
    if v2 and type(v2.IsGuideWindowEnabled) == "function" and v2:IsGuideWindowEnabled() then
        if type(v2.UpdateGuideWindow) == "function" then v2:UpdateGuideWindow() end
        local window = type(v2.GetGuideWindow) == "function" and v2:GetGuideWindow()
        if window and type(window.UpdateTheme) == "function" then window:UpdateTheme({}) end
        if type(v2.UpdateActiveStepTheme) == "function" then v2:UpdateActiveStepTheme() end
        if rxp.activeItemFrame then rxp.activeItemFrame:UpdateVisuals() end
        if rxp.targeting and rxp.targeting.activeTargetFrame then rxp.targeting.activeTargetFrame:UpdateVisuals() end
    end
    if rxp.guideImporter and type(rxp.guideImporter.UpdateTheme) == "function" then rxp.guideImporter:UpdateTheme() end
end

function addon:GetRestedXPSkinState()
    local rxp, problem = Installation()
    local state = self.restedxpSkinState
    local enabled = self:IsRestedXPSkinEnabled()
    local active = rxp and Selected(rxp) == true or false
    return {
        enabled = enabled, available = rxp ~= nil, active = active,
        pending = state and state.pending == true or false,
        problem = state and state.problem or problem,
        status = state and state.pending and "The skin change will apply after combat."
            or active and "LockInTools theme is active."
            or enabled and rxp and "A different theme is selected in RestedXP."
            or rxp and "Choose the LockInTools theme in RestedXP."
            or "Enable RestedXP to choose the LockInTools theme.",
    }
end

function addon:RefreshRestedXPSkin()
    local state = self.restedxpSkinState
    if not state then return end
    local rxp, problem = Installation()
    local enabled = self:IsRestedXPSkinEnabled()
    state.problem, state.pending = problem, false
    if not rxp then self:Notify("RESTEDXP_SKIN_CHANGED"); return end
    local profile = rxp.settings.profile
    local settings = self.db.restedxpSkin
    local previousSelection = profile.activeTheme
    local previousRestore = type(settings) == "table" and settings.restorePending
    local key = ProfileKey(rxp)
    local previousTheme = type(settings) == "table" and type(settings.previousThemes) == "table"
        and settings.previousThemes[key] or nil
    local refreshing = false
    local success = pcall(function()
        local overrides = self:IsRestedXPSkinOverridesEnabled()
        local changed = state.registered ~= rxp or state.registeredOverrides ~= overrides
        if changed then
            -- Registration only changes theme tables, so the chooser is always
            -- populated, including with automatic selection off or read-only LIT data.
            RegisterThemes(rxp, overrides)
            state.registered, state.registeredOverrides = rxp, overrides
        end
        HookVisuals(rxp, state)
        if self.savedDataReadOnly then return end
        local selected = profile.activeTheme == NAME
        -- A pending restore on another character must not claim this profile's
        -- later manual theme choice after its own saved selection was consumed.
        local restore = type(settings) == "table" and settings.restorePending == true and previousTheme ~= nil
        local selectionChange = enabled and not selected or not enabled and restore and selected
        local visualChange = selected and (changed or state.dirty or state.profile ~= profile or not Selected(rxp))
        -- Registration is safe in combat; native refreshes reach secure item buttons.
        if InCombat() then
            state.dirty = state.dirty or visualChange
            state.pending = selectionChange or visualChange or selected and state.chromeHidden ~= self:IsRestedXPChromeHidden()
            if self.RefreshRestedXPChrome then self:RefreshRestedXPChrome(rxp) end
            if self.RefreshRestedXPScrollbar then self:RefreshRestedXPScrollbar(rxp) end
            if self.RefreshRestedXPCheckboxes then self:RefreshRestedXPCheckboxes(rxp) end
            if self.RefreshRestedXPTooltips then self:RefreshRestedXPTooltips(rxp) end
            if self.RefreshRestedXPMenus then self:RefreshRestedXPMenus(rxp) end
            if self.RefreshRestedXPTransparency then self:RefreshRestedXPTransparency(rxp) end
            return
        end
        if enabled then
            if type(settings.previousThemes) ~= "table" then settings.previousThemes = {} end
            if profile.activeTheme ~= NAME then settings.previousThemes[key] = profile.activeTheme or "RXP Blue" end
            profile.activeTheme = NAME
        elseif restore then
            if selected then
                local previous = type(settings.previousThemes) == "table" and settings.previousThemes[key]
                profile.activeTheme = type(previous) == "string" and previous or "RXP Blue"
            end
            if type(settings.previousThemes) == "table" then settings.previousThemes[key] = nil end
            -- Other characters can still have a theme this option selected.
            settings.restorePending = type(settings.previousThemes) == "table"
                and next(settings.previousThemes) ~= nil or nil
        end
        -- Manual native selection remains valid when automatic selection is off.
        if selectionChange or visualChange then
            refreshing = true
            RefreshTheme(rxp)
        end
        if self.RefreshRestedXPChrome then self:RefreshRestedXPChrome(rxp) end
        if self.RefreshRestedXPScrollbar then self:RefreshRestedXPScrollbar(rxp) end
        if self.RefreshRestedXPCheckboxes then self:RefreshRestedXPCheckboxes(rxp) end
        if self.RefreshRestedXPTooltips then self:RefreshRestedXPTooltips(rxp) end
        if self.RefreshRestedXPMenus then self:RefreshRestedXPMenus(rxp) end
        if self.RefreshRestedXPTransparency then self:RefreshRestedXPTransparency(rxp) end
        state.profile, state.chromeHidden, state.dirty = profile, self:IsRestedXPChromeHidden(), nil
    end)
    if not success then
        profile.activeTheme = previousSelection
        if type(settings) == "table" then
            settings.restorePending = previousRestore
            if type(settings.previousThemes) == "table" then settings.previousThemes[key] = previousTheme end
        end
        if refreshing then pcall(RefreshTheme, rxp) end
        state.problem = "The RestedXP skin could not be applied. Try updating RestedXP and reloading."
    end
    self:Notify("RESTEDXP_SKIN_CHANGED")
end

local function SetPreference(self, key, enabled)
    if not self.initialized or type(self.db) ~= "table" then return false, "Settings are still loading." end
    if self.savedDataReadOnly then return false, "Saved preferences are read-only." end
    if type(enabled) ~= "boolean" then return false, "Choose whether to enable this setting." end
    if type(self.db.restedxpSkin) ~= "table" then self.db.restedxpSkin = {} end
    local settings = self.db.restedxpSkin
    if key == "enabled" then
        if not enabled and settings.enabled == true then settings.restorePending = true end
        if enabled then
            local restoring = settings.restorePending
            local rxp = Installation()
            if settings.enabled ~= true and rxp and rxp.settings.profile.activeTheme == NAME then
                -- Turning automatic selection on must not take ownership of a
                -- theme the player already selected through RestedXP itself.
                if type(settings.previousThemes) ~= "table" then settings.previousThemes = {} end
                local key = ProfileKey(rxp)
                if not (restoring and settings.previousThemes[key]) then settings.previousThemes[key] = NAME end
            end
            settings.restorePending = nil
        end
    end
    settings[key] = enabled
    if key == "enabled" then
        -- One skin switch owns theme selection, flat styling and the scrollbar.
        -- Keep the legacy fields synchronized for earlier builds.
        settings.overrides, settings.modernScrollbar = enabled, enabled
    end
    if self.restedxpSkinState then self.restedxpSkinState.dirty = true end
    self:RefreshRestedXPSkin()
    return true
end

function addon:SetRestedXPSkinEnabled(enabled)
    return SetPreference(self, "enabled", enabled)
end

function addon:SetRestedXPSkinOverridesEnabled(enabled)
    return self:SetRestedXPSkinEnabled(enabled)
end

function addon:SetRestedXPChromeHidden(enabled)
    return SetPreference(self, "hideChrome", enabled)
end

function addon:SetRestedXPModernScrollbarEnabled(enabled)
    return self:SetRestedXPSkinEnabled(enabled)
end

function addon:SetRestedXPBackgroundTransparency(value)
    if not self.initialized or type(self.db) ~= "table" then return false, "Settings are still loading." end
    if self.savedDataReadOnly then return false, "Saved preferences are read-only." end
    local percent = Transparency(value)
    if not percent then return false, "Choose a transparency between 0 and 100%." end
    if self:GetRestedXPBackgroundTransparency() == percent then return true end
    if type(self.db.restedxpSkin) ~= "table" then self.db.restedxpSkin = {} end
    self.db.restedxpSkin.backgroundTransparency = percent
    local state = self.restedxpSkinState
    if not state or state.transparencyQueued then return true end
    state.transparencyQueued = true
    local function Apply()
        state.transparencyQueued = nil
        local rxp = Installation()
        if rxp and self.RefreshRestedXPTransparency then
            local success = pcall(self.RefreshRestedXPTransparency, self, rxp)
            if not success then state.problem = "Could not update transparency. Reload and try again." end
        end
        self:Notify("RESTEDXP_SKIN_CHANGED")
    end
    -- Many slider events in one frame need one layer repaint, not guide parsing,
    -- layout, theme registration or a window-wide alpha change.
    if C_Timer and type(C_Timer.After) == "function" then C_Timer.After(0, Apply) else Apply() end
    return true
end

function addon:InitializeRestedXPSkin()
    if self.restedxpSkinState then return end
    self.restedxpSkinState = {
        hooked = setmetatable({}, { __mode = "k" }), windows = setmetatable({}, { __mode = "k" }),
    }
    self:RegisterGameEvents({ "ADDON_LOADED", "PLAYER_REGEN_ENABLED" }, function(_, event, name)
        if event == "PLAYER_REGEN_ENABLED" then
            if self.restedxpSkinState.pending then self:RefreshRestedXPSkin() end
        elseif name == "RXPGuides" then
            -- AceAddon initializes through ADDON_LOADED too. Run after its handlers.
            C_Timer.After(0, function() self:RefreshRestedXPSkin() end)
        end
    end)
    self:RefreshRestedXPSkin()
end

-- RXP 4.11.26 rebuilds these anchors in its native layout methods. Keep its
-- shell-height calculations intact and give the recovered space to the rows.
-- Only known decorative frames are changed; secure item/target buttons stay put.
local function ChromePoints(frame)
    local points = {}
    for index = 1, frame:GetNumPoints() do points[index] = { frame:GetPoint(index) } end
    return points
end

local function ChromePointsEqual(left, right)
    if #left ~= #right then return false end
    for index = 1, #left do
        for coordinate = 1, 5 do
            if left[index][coordinate] ~= right[index][coordinate] then return false end
        end
    end
    return true
end

local function ChromeCapable(frame, geometry)
    if not frame or type(frame.IsShown) ~= "function" or type(frame.Show) ~= "function"
        or type(frame.Hide) ~= "function" then return false end
    return not geometry or type(frame.GetNumPoints) == "function" and type(frame.GetPoint) == "function"
        and type(frame.ClearAllPoints) == "function" and type(frame.SetPoint) == "function"
        and type(frame.GetHeight) == "function" and type(frame.SetHeight) == "function"
end

local function ChromeRemember(group, frame, points, height, shown, mouse, backdrop)
    local record = group[frame]
    if not record then
        record = { frame = frame, points = points, height = height, shown = shown,
            mouse = mouse, backdrop = backdrop, original = {} }
        group[frame] = record
    end
    -- A native layout may have run since the last application. Preserve its new
    -- values rather than restoring an obsolete header size after a guide change.
    local original, applied = record.original, record.applied
    if points then
        local current = ChromePoints(frame)
        if not applied or not ChromePointsEqual(current, applied.points) then original.points = current end
    end
    if height and (not applied or frame:GetHeight() ~= applied.height) then original.height = frame:GetHeight() end
    if shown and (not applied or frame:IsShown() ~= applied.shown) then original.shown = frame:IsShown() end
    if mouse and (not applied or frame:IsMouseEnabled() ~= applied.mouse) then original.mouse = frame:IsMouseEnabled() end
    if backdrop and (not applied or frame:GetBackdrop() ~= nil) then
        original.backdrop = frame:GetBackdrop()
        original.fill, original.border = nil, nil
        if original.backdrop then
            if type(frame.GetBackdropColor) == "function" then original.fill = { frame:GetBackdropColor() } end
            if type(frame.GetBackdropBorderColor) == "function" then original.border = { frame:GetBackdropBorderColor() } end
        end
    end
    return record
end

local function ChromeApplied(group)
    for frame, record in pairs(group) do
        record.applied = {
            points = record.points and ChromePoints(frame),
            height = record.height and frame:GetHeight(),
            shown = record.shown and frame:IsShown(),
            mouse = record.mouse and frame:IsMouseEnabled(),
        }
    end
end

local function ChromeRestore(group)
    for frame, record in pairs(group) do
        ChromeRemember(group, frame, record.points, record.height, record.shown, record.mouse, record.backdrop)
        local original = record.original
        if record.points then
            frame:ClearAllPoints()
            for _, point in ipairs(original.points) do frame:SetPoint(unpack(point, 1, 5)) end
        end
        if record.height then frame:SetHeight(original.height) end
        if record.backdrop then
            frame:SetBackdrop(original.backdrop)
            if original.fill and type(frame.SetBackdropColor) == "function" then frame:SetBackdropColor(unpack(original.fill)) end
            if original.border and type(frame.SetBackdropBorderColor) == "function" then frame:SetBackdropBorderColor(unpack(original.border)) end
        end
        if record.mouse then frame:EnableMouse(original.mouse) end
        if record.shown then
            if original.shown then frame:Show() else frame:Hide() end
        end
        group[frame] = nil
    end
end

local function ChromeHide(group, region)
    if not ChromeCapable(region) then return end
    ChromeRemember(group, region, false, false, true)
    region:Hide()
end

local function ChromeDecoration(group, frame)
    if not frame then return end
    local mouse = type(frame.IsMouseEnabled) == "function" and type(frame.EnableMouse) == "function"
    local backdrop = type(frame.GetBackdrop) == "function" and type(frame.SetBackdrop) == "function"
    if mouse or backdrop then
        ChromeRemember(group, frame, false, false, false, mouse, backdrop)
        if mouse then frame:EnableMouse(false) end
        if backdrop then frame:SetBackdrop(nil) end
    end
    for _, key in ipairs({ "rxpBackground", "rxpBorder", "rxpShadow" }) do ChromeHide(group, frame[key]) end
end

local function ChromeClassic(rxp, state, hide, v2Enabled)
    local frame = rxp.RXPFrame
    if not hide or v2Enabled then ChromeRestore(state.classic); return end
    local header, footer, content = frame and frame.GuideName, frame and frame.Footer, frame and frame.BottomFrame
    if not ChromeCapable(header, true) or not ChromeCapable(footer) or not ChromeCapable(content, true) then return end
    -- These are structural anchors, not just decorations. Hiding/collapsing
    -- GuideName can lose the todo list; hiding Footer also hides its resize grip.
    ChromeDecoration(state.classic, header)
    ChromeDecoration(state.classic, footer)
    for _, key in ipairs({ "bg", "text", "icon", "classIcon" }) do ChromeHide(state.classic, header[key]) end
    for _, key in ipairs({ "bg", "text", "cog" }) do ChromeHide(state.classic, footer[key]) end
    ChromeRemember(state.classic, content, true, false, false)
    content:ClearAllPoints()
    content:SetPoint("TOPLEFT", frame, "TOPLEFT", 3, -3)
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -3, 3)
    local todo = frame.CurrentStepFrame
    if ChromeCapable(todo, true) then
        if todo.anchor == "BOTTOM" then
            if state.classic[todo] then ChromeRemember(state.classic, todo, true, false, false) end
        else
            local attached = state.classic[todo] ~= nil
            for _, point in ipairs(ChromePoints(todo)) do attached = attached or point[2] == header end
            if attached then
                ChromeRemember(state.classic, todo, true, false, false)
                todo:ClearAllPoints()
                todo:SetPoint("BOTTOMLEFT", content, "TOPLEFT", 0, 2)
                todo:SetPoint("BOTTOMRIGHT", content, "TOPRIGHT", 0, 2)
            end
        end
    end
    ChromeApplied(state.classic)
end

local function ChromeV2(window, group, hide)
    if not hide then ChromeRestore(group); return end
    local upper, footer, content = window.upperFrame, window.footer, window.guideStepsFrame
    local steps = window.guideSteps and window.guideSteps.frame
    if not ChromeCapable(upper) or not ChromeCapable(footer)
        or not ChromeCapable(content, true) or not ChromeCapable(steps, true) then return end
    ChromeDecoration(group, upper)
    ChromeDecoration(group, window.header)
    ChromeDecoration(group, window.guideNameFrame)
    ChromeDecoration(group, footer)
    for _, key in ipairs({ "banner", "iconLogo", "classIcon", "title", "subtitle",
        "settingsButton", "guideSelectButton", "closebutton", "footerBackground", "footerText" }) do
        ChromeHide(group, window[key])
    end
    ChromeRemember(group, content, true, false, false)
    ChromeRemember(group, steps, true, false, false)
    content:ClearAllPoints()
    content:SetPoint("TOPLEFT", window.frame, "TOPLEFT", 0, 0)
    content:SetPoint("BOTTOMRIGHT", window.frame, "BOTTOMRIGHT", 0, 0)
    steps:ClearAllPoints()
    steps:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -2)
    steps:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -2, 2)
    ChromeApplied(group)
    if type(window.guideSteps.UpdateScrollbar) == "function" then window.guideSteps:UpdateScrollbar() end
end

function addon:RefreshRestedXPChrome(rxp)
    if not rxp or type(rxp.settings) ~= "table" or type(rxp.settings.profile) ~= "table" then return end
    self.restedxpChromeState = self.restedxpChromeState or setmetatable({}, { __mode = "k" })
    local state = self.restedxpChromeState[rxp]
    if not state then
        state = { classic = {}, windows = setmetatable({}, { __mode = "k" }),
            hooks = setmetatable({}, { __mode = "k" }) }
        self.restedxpChromeState[rxp] = state
    end
    if state.applying then return end
    local function Refresh() self:RefreshRestedXPChrome(rxp) end
    local function Hook(owner, method)
        if not owner or type(owner[method]) ~= "function" or type(hooksecurefunc) ~= "function" then return end
        local hooks = state.hooks[owner] or {}
        state.hooks[owner] = hooks
        if hooks[method] then return end
        hooksecurefunc(owner, method, Refresh)
        hooks[method] = true
    end
    Hook(rxp, "LoadActiveTheme")
    Hook(rxp, "RenderFrame")
    Hook(rxp, "SetupGuideWindow")
    Hook(rxp.RXPFrame, "UpdateVisuals")
    Hook(rxp.RXPFrame, "SetStepFrameAnchor")
    local v2 = rxp.v2
    Hook(v2, "GetGuideWindow")
    Hook(v2, "UpdateGuideWindow")
    local window = v2 and v2.state and v2.state.guideWindow
    if window then
        state.windows[window] = state.windows[window] or {}
        Hook(window, "UpdateFrameLayout")
        Hook(window, "SetSnapshot")
    end
    local hide = rxp.settings.profile.activeTheme == NAME and self:IsRestedXPChromeHidden()
    if InCombat() then
        local pending = hide or next(state.classic) ~= nil
        for _, group in pairs(state.windows) do pending = pending or next(group) ~= nil end
        if pending and self.restedxpSkinState then self.restedxpSkinState.pending = true end
        return
    end
    local v2Enabled = v2 and type(v2.IsGuideWindowEnabled) == "function" and v2:IsGuideWindowEnabled()
    state.applying = true
    local success, problem = pcall(function()
        ChromeClassic(rxp, state, hide, v2Enabled)
        for existing, group in pairs(state.windows) do ChromeV2(existing, group, hide and v2Enabled and existing == window) end
    end)
    state.applying = false
    if not success then error(problem, 0) end
end

-- Keep RXP's slider, callbacks and scroll range. The hidden-header shortcut
-- adds only a right-button mouse-up hook; scrolling and dragging stay native.
local function ScrollbarArrayEqual(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then return left == right end
    if #left ~= #right then return false end
    for index = 1, #left do if left[index] ~= right[index] then return false end end
    return true
end

local function ScrollbarThumbState(thumb)
    local alpha, desaturated
    if type(thumb.GetAlpha) == "function" then alpha = thumb:GetAlpha() end
    if type(thumb.IsDesaturated) == "function" then desaturated = thumb:IsDesaturated() end
    return {
        texture = thumb:GetTexture(), coordinates = { thumb:GetTexCoord() }, color = { thumb:GetVertexColor() },
        width = thumb:GetWidth(), height = thumb:GetHeight(),
        alpha = alpha, desaturated = desaturated,
    }
end

local function ScrollbarRememberThumb(record)
    local current = ScrollbarThumbState(record.thumb)
    for _, key in ipairs({ "texture", "coordinates", "color", "width", "height", "alpha", "desaturated" }) do
        if not record.appliedThumb or not ScrollbarArrayEqual(current[key], record.appliedThumb[key]) then
            record.originalThumb[key] = current[key]
        end
    end
end

local function ScrollbarRestoreThumb(thumb, saved)
    thumb:SetTexture(saved.texture)
    thumb:SetTexCoord(unpack(saved.coordinates))
    thumb:SetVertexColor(unpack(saved.color))
    thumb:SetWidth(saved.width)
    thumb:SetHeight(saved.height)
    if saved.alpha ~= nil and type(thumb.SetAlpha) == "function" then thumb:SetAlpha(saved.alpha) end
    if saved.desaturated ~= nil and type(thumb.SetDesaturated) == "function" then thumb:SetDesaturated(saved.desaturated) end
end

local function ScrollbarCapable(slider, thumb)
    for _, method in ipairs({ "GetWidth", "SetWidth", "GetHeight", "GetNumPoints", "GetPoint",
        "ClearAllPoints", "SetPoint", "CreateTexture" }) do
        if type(slider[method]) ~= "function" then return false end
    end
    for _, method in ipairs({ "GetTexture", "SetTexture", "GetTexCoord", "SetTexCoord", "GetVertexColor",
        "SetVertexColor", "GetWidth", "SetWidth", "GetHeight", "SetHeight" }) do
        if type(thumb[method]) ~= "function" then return false end
    end
    return true
end

local function ScrollbarRestore(record)
    if not record.active then return end
    ScrollbarRememberThumb(record)
    ScrollbarRestoreThumb(record.thumb, record.originalThumb)
    record.slider:SetWidth(record.originalWidth)
    record.slider:ClearAllPoints()
    for _, point in ipairs(record.originalPoints) do record.slider:SetPoint(unpack(point, 1, 5)) end
    for region, shown in pairs(record.visibility) do
        if region:IsShown() then shown = true end -- A native redraw may have shown it again.
        if shown then region:Show() else region:Hide() end
    end
    record.track:Hide()
    record.active, record.appliedThumb = false, nil
end

local function ScrollbarPaint(record, enabled, palette)
    local slider = record.slider
    if not enabled then ScrollbarRestore(record); return end
    local thumb = slider:GetThumbTexture()
    if not thumb or not ScrollbarCapable(slider, thumb) then return end
    if record.active and record.thumb ~= thumb then ScrollbarRestore(record) end
    if not record.active then
        record.thumb, record.originalThumb = thumb, {}
        record.originalWidth, record.originalPoints = slider:GetWidth(), ChromePoints(slider)
        record.visibility = {}
        for _, region in ipairs(record.ornaments) do record.visibility[region] = region:IsShown() end
        record.active = true
    end
    ScrollbarRememberThumb(record)
    slider:SetWidth(8)
    slider:ClearAllPoints()
    slider:SetPoint("TOPLEFT", record.scrollframe, "TOPRIGHT", 2, -2)
    slider:SetPoint("BOTTOMLEFT", record.scrollframe, "BOTTOMRIGHT", 2, 2)
    thumb:SetTexture(WHITE)
    thumb:SetTexCoord(0, 1, 0, 1)
    thumb:SetVertexColor(palette.accent[1], palette.accent[2], palette.accent[3], 1)
    thumb:SetWidth(8)
    thumb:SetHeight(math.max(8, math.min(24, slider:GetHeight())))
    if type(thumb.SetAlpha) == "function" and type(thumb.GetAlpha) == "function" then thumb:SetAlpha(1) end
    if type(thumb.SetDesaturated) == "function" and type(thumb.IsDesaturated) == "function" then thumb:SetDesaturated(false) end
    for region in pairs(record.visibility) do
        if region:IsShown() then record.visibility[region] = true end
        region:Hide()
    end
    record.track:SetColorTexture(unpack(palette.surface))
    record.track:Show()
    record.appliedThumb = ScrollbarThumbState(thumb)
end

local function ScrollbarGuideSelection(rxp)
    local v2 = rxp.v2
    -- This native chooser is available in both interfaces, despite its V2
    -- namespace. It keeps RXP's guide filtering, submenus and load callbacks.
    if v2 and type(v2.ShowGuideSelectionMenu) == "function" then v2:ShowGuideSelectionMenu(); return end
    local frame = rxp.RXPFrame
    if not frame or type(frame.GenerateMenuTable) ~= "function" or type(rxp.ShowMenu) ~= "function" then return end
    -- Older versions lack the dedicated chooser. Match its guide-only prefix;
    -- the rest of GenerateMenuTable contains unrelated settings and actions.
    local source = frame:GenerateMenuTable({})
    if type(source) ~= "table" then return end
    local menu = {}
    for _, item in ipairs(source) do
        if item.isTitle and item.text == "" then break end
        menu[#menu + 1] = item
    end
    menu[#menu + 1] = { text = "", notCheckable = 1, isTitle = 1 }
    menu[#menu + 1] = { text = CLOSE or "Close", notCheckable = 1, func = function(button) button:Hide() end }
    rxp:ShowMenu(menu)
end

local function ScrollbarVisibility(target, forced)
    if not target then return end
    if target.forced == nil and forced == nil then return end
    if target.forced == nil then target.native = target.frame:IsShown() end
    target.forced = forced
    local shown = forced
    if shown == nil then shown = target.native; target.native = nil end
    if target.frame:IsShown() ~= shown then
        if shown then target.frame:Show() else target.frame:Hide() end
    end
end

local function ScrollbarAccess(record, enabled)
    record.accessActive = enabled
    -- Empty/collapsed guides hide this ancestor. Keep only the control visible;
    -- showing cached step rows would undo RXP's collapsed/hidden-list setting.
    ScrollbarVisibility(record.container, enabled and true or nil)
    local hideContent = enabled and record.container and record.container.native == false
    local contentVisibility
    if hideContent then contentVisibility = false end
    ScrollbarVisibility(record.content, contentVisibility)
    ScrollbarVisibility(record.control, enabled and true or nil)
end

local function ScrollbarSpace(record, enabled, modern)
    local frame, parent = record.outer, record.container and record.container.frame
    if not frame or not parent or not ChromeCapable(frame, true) then return end
    record.spacing = record.spacing or {}
    if not enabled then ChromeRestore(record.spacing); return end
    -- FixScroll rewrites the inner viewport's anchors. Reserve space on its
    -- outer frame instead so the bar stays inside the window at zero overflow.
    ChromeRemember(record.spacing, frame, true, false, false)
    local points = { { "TOPLEFT", parent, "TOPLEFT", 0, 0 },
        { "BOTTOMRIGHT", parent, "BOTTOMRIGHT", modern and -10 or -18, 0 } }
    if not ChromePointsEqual(ChromePoints(frame), points) then
        frame:ClearAllPoints()
        for _, point in ipairs(points) do frame:SetPoint(unpack(point, 1, 5)) end
    end
    ChromeApplied(record.spacing)
end

function addon:RefreshRestedXPScrollbar(rxp)
    if not rxp or type(rxp.settings) ~= "table" or type(rxp.settings.profile) ~= "table" then return end
    self.restedxpScrollbarState = self.restedxpScrollbarState or setmetatable({}, { __mode = "k" })
    local state = self.restedxpScrollbarState[rxp]
    if not state then
        state = { bars = {}, hooks = setmetatable({}, { __mode = "k" }) }
        self.restedxpScrollbarState[rxp] = state
    end
    if state.applying then return end
    local function Refresh() self:RefreshRestedXPScrollbar(rxp) end
    local function Hook(owner, method, callback)
        if not owner or type(owner[method]) ~= "function" or type(hooksecurefunc) ~= "function" then return end
        local hooks = state.hooks[owner] or {}
        state.hooks[owner] = hooks
        if hooks[method] then return end
        hooksecurefunc(owner, method, callback or Refresh)
        hooks[method] = true
    end
    local function RepairAccess(record)
        for _, item in pairs({ record.container, record.content, record.control }) do
            if InCombat() and type(item.frame.IsProtected) == "function" and item.frame:IsProtected() then
                if self.restedxpSkinState then self.restedxpSkinState.pending = true end
                return
            end
        end
        -- Visibility retries must not repaint/reanchor the slider or run a
        -- guide layout on every native Hide/SetShown.
        state.applying = true
        local success, problem = pcall(ScrollbarAccess, record, record.accessActive)
        state.applying = false
        if not success then error(problem, 0) end
    end
    local function Find(scrollframe, slider, background, container, content, outer)
        if not scrollframe or not slider or type(slider.GetThumbTexture) ~= "function" then return end
        local thumb = slider:GetThumbTexture()
        if not thumb or not ScrollbarCapable(slider, thumb) then return end
        local record = state.bars[slider]
        if not record then
            if not (rxp.settings.profile.activeTheme == NAME
                and (self:IsRestedXPModernScrollbarEnabled() or self:IsRestedXPChromeHidden())) then return end
            record = { slider = slider, scrollframe = scrollframe, ornaments = {}, outer = outer }
            state.bars[slider] = record
            local function AccessTarget(frame)
                if not ChromeCapable(frame) then return end
                local target = { frame = frame }
                local function Request(shown)
                    if state.applying or target.forced == nil then return end
                    target.native = shown
                    RepairAccess(record)
                end
                Hook(frame, "Show", function()
                    Request(true)
                    if frame == slider and not state.applying and target.forced == nil and record.active then Refresh() end
                end)
                Hook(frame, "Hide", function() Request(false) end)
                Hook(frame, "SetShown", function(_, shown) Request(not not shown) end)
                if type(frame.HookScript) == "function" then
                    local function Changed()
                        -- Parent hiding fires OnHide too; IsShown still reports
                        -- the child's own flag, preserving the user's root hide.
                        if target.forced ~= nil and frame:IsShown() ~= target.forced then Request(frame:IsShown()) end
                    end
                    frame:HookScript("OnShow", Changed)
                    frame:HookScript("OnHide", Changed)
                end
                return target
            end
            record.container, record.content, record.control = AccessTarget(container), AccessTarget(content), AccessTarget(slider)
            local included = {}
            local function Ornament(region)
                if region and region ~= thumb and not included[region] and ChromeCapable(region) then
                    included[region] = true
                    record.ornaments[#record.ornaments + 1] = region
                    local function KeepHidden()
                        if state.applying or not record.active or not region:IsShown() then return end
                        -- SetShown and native OnShow paths can bypass the Lua
                        -- Show method. Hide just this ornament, keeping the
                        -- slider's drag, geometry and scroll callbacks intact.
                        record.visibility[region] = true
                        if InCombat() and type(region.IsProtected) == "function" and region:IsProtected() then
                            if self.restedxpSkinState then self.restedxpSkinState.pending = true end
                            return
                        end
                        region:Hide()
                    end
                    Hook(region, "Show", KeepHidden)
                    Hook(region, "SetShown", KeepHidden)
                    if type(region.HookScript) == "function" then region:HookScript("OnShow", KeepHidden) end
                end
            end
            Ornament(slider.ScrollUpButton)
            Ornament(slider.ScrollDownButton)
            if type(slider.GetRegions) == "function" then
                for _, region in ipairs({ slider:GetRegions() }) do
                    if type(region.GetObjectType) == "function" and region:GetObjectType() == "Texture" then Ornament(region) end
                end
            end
            Ornament(background)
            -- Scan the slider's own texture regions once, before adding our track.
            record.track = slider:CreateTexture(nil, "BACKGROUND")
            record.track:SetAllPoints(slider)
            record.track:Hide()
            Hook(slider, "SetThumbTexture")
            if type(slider.HookScript) == "function" then
                slider:HookScript("OnMouseUp", function(_, button)
                    if button ~= "RightButton" or rxp.settings.profile.activeTheme ~= NAME
                        or not self:IsRestedXPChromeHidden() then return end
                    local native = rxp.v2
                    local useV2 = native and type(native.IsGuideWindowEnabled) == "function" and native:IsGuideWindowEnabled()
                    local window = native and native.state and native.state.guideWindow
                    local steps = window and window.guideSteps
                    local current = useV2 and steps and steps.scroll and steps.scroll.scrollbar
                        or not useV2 and rxp.RXPFrame and rxp.RXPFrame.ScrollFrame and rxp.RXPFrame.ScrollFrame.ScrollBar
                    if slider == current then ScrollbarGuideSelection(rxp) end
                end)
            end
        end
    end
    Hook(rxp, "LoadActiveTheme")
    Hook(rxp, "RenderFrame")
    Hook(rxp.RXPFrame, "UpdateVisuals")
    Hook(rxp.RXPFrame, "UpdateScrollBar")
    local classic = rxp.RXPFrame and rxp.RXPFrame.ScrollFrame
    Hook(rxp.RXPFrame and rxp.RXPFrame.BottomFrame, "UpdateFrame", function()
        local record = classic and state.bars[classic.ScrollBar]
        if state.applying or not record or not record.accessActive or not record.container then return end
        local body = record.container.frame
        if type(body.GetHeight) ~= "function" then return end
        -- Classic UpdateFrame only calls Show when IsShown is false. Our
        -- forced visibility masks that transition, so capture its actual
        -- postcondition (height >=30 and no guide.hidewindow) at this boundary.
        record.container.native = body:GetHeight() >= 30 and not (rxp.currentGuide and rxp.currentGuide.hidewindow)
        RepairAccess(record)
    end)
    -- Discovery is read-only in combat; creation and frame changes wait below.
    local v2 = rxp.v2
    Hook(v2, "GetGuideWindow")
    Hook(v2, "UpdateGuideWindow")
    local window = v2 and v2.state and v2.state.guideWindow
    local scroll = window and window.guideSteps and window.guideSteps.scroll
    Hook(scroll, "RefreshVisuals", function()
        local record = scroll and state.bars[scroll.scrollbar]
        if record and record.active then
            -- Native V2 writes these even when their value equals our current
            -- styling, which cannot be detected by comparing snapshots alone.
            record.originalThumb.color = { record.thumb:GetVertexColor() }
            if type(record.thumb.IsDesaturated) == "function" then
                record.originalThumb.desaturated = record.thumb:IsDesaturated()
            end
        end
        Refresh()
    end)
    Hook(scroll, "FixScroll")
    local enabled = rxp.settings.profile.activeTheme == NAME
        and type(self.IsRestedXPModernScrollbarEnabled) == "function" and self:IsRestedXPModernScrollbarEnabled()
    local accessible = rxp.settings.profile.activeTheme == NAME and self:IsRestedXPChromeHidden()
    if InCombat() then
        local pending = enabled or accessible
        for _, record in pairs(state.bars) do pending = pending or record.active or record.accessActive end
        if pending and self.restedxpSkinState then self.restedxpSkinState.pending = true end
        return
    end
    state.applying = true
    local success, problem = pcall(function()
        local root, steps = rxp.RXPFrame, window and window.guideSteps
        Find(classic, classic and classic.ScrollBar, nil, root and root.BottomFrame, root and root.ScrollChild)
        Find(scroll and scroll.scrollframe, scroll and scroll.scrollbar, scroll and scroll.scrollbg,
            steps and steps.frame, scroll and scroll.content, scroll and scroll.frame)
        local palette = self.Theme:GetPalette()
        local v2Enabled = v2 and type(v2.IsGuideWindowEnabled) == "function" and v2:IsGuideWindowEnabled()
        for slider, record in pairs(state.bars) do
            local current = v2Enabled and scroll and slider == scroll.scrollbar
                or not v2Enabled and classic and slider == classic.ScrollBar
            ScrollbarPaint(record, enabled and current, palette)
            ScrollbarSpace(record, accessible and current, enabled)
            -- Never set scrollBarShown or change the native range. V2's wheel
            -- math assumes positive overflow when that native flag is set.
            ScrollbarAccess(record, accessible and current)
        end
    end)
    state.applying = false
    if not success then error(problem, 0) end
end

-- Opacity is a layer edit, not a theme reload. BackdropTemplate exposes these
-- nine-slice textures; RXP V2 keeps backing, border and shadow in separate groups.
-- Never fade a structural frame: its text, controls and native input stay intact.
local backdropPieces = { "Center", "TopEdge", "BottomEdge", "LeftEdge", "RightEdge",
    "TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner" }

function addon:RefreshRestedXPTransparency(rxp)
    if not rxp or type(rxp.settings) ~= "table" or type(rxp.settings.profile) ~= "table" then return end
    self.restedxpTransparencyState = self.restedxpTransparencyState or setmetatable({}, { __mode = "k" })
    local state = self.restedxpTransparencyState[rxp]
    if not state then
        state = { original = setmetatable({}, { __mode = "k" }), applied = setmetatable({}, { __mode = "k" }),
            fills = setmetatable({}, { __mode = "k" }), fillRoles = setmetatable({}, { __mode = "k" }),
            hooks = setmetatable({}, { __mode = "k" }), footerRegions = setmetatable({}, { __mode = "k" }) }
        self.restedxpTransparencyState[rxp] = state
    end
    if state.applying then return end
    local function Refresh() self:RefreshRestedXPTransparency(rxp) end
    local function Hook(owner, method, callback)
        if not owner or type(owner[method]) ~= "function" or type(hooksecurefunc) ~= "function" then return end
        local hooks = state.hooks[owner] or {}
        state.hooks[owner] = hooks
        if hooks[method] then return end
        hooksecurefunc(owner, method, callback or Refresh)
        hooks[method] = true
    end
    Hook(rxp, "LoadActiveTheme")
    Hook(rxp, "RenderFrame")
    Hook(rxp, "LoadGuide")
    Hook(rxp, "SetStep")
    Hook(rxp, "SetupGuideWindow")
    Hook(rxp, "CreateActiveItemFrame")
    Hook(rxp.RXPFrame, "UpdateVisuals")
    Hook(rxp.targeting, "CreateTargetFrame")
    Hook(rxp.targeting, "RenderTargetFrameBackground")
    Hook(self, "RefreshRestedXPScrollbar")
    local v2 = rxp.v2
    for _, method in ipairs({ "GetGuideWindow", "UpdateGuideWindow", "GetActiveStepsFrame", "GetActivePartyStepsFrame",
        "ReconcileActiveStepItems", "UpdateActiveStepTheme", "UpdateActiveStepsFrame", "RenderActivePartyStepsFrame" }) do
        Hook(v2, method)
    end
    local selected = not self.savedDataReadOnly and rxp.settings.profile.activeTheme == NAME
    local factor = selected and (1 - self:GetRestedXPBackgroundTransparency() / 100) or 1
    local legacy = rxp.themes and rxp.themes[NAME] or rxp.activeTheme or {}
    local modern = v2 and v2.themes and v2.themes[NAME]
    local backgrounds = modern and modern.backgroundColors or {}
    local function ColorAlpha(color) if type(color) == "table" then return color[4] or 1 end end
    local common = ColorAlpha(backgrounds.common)
    local visited = {}
    local function Layer(region, recoverAlpha)
        if not region or visited[region] or type(region.GetAlpha) ~= "function" or type(region.SetAlpha) ~= "function" then return end
        visited[region] = true
        local current, original = region:GetAlpha(), state.original[region]
        if factor == 1 and original == nil and not (selected and current == 0 and recoverAlpha) then return end
        if type(current) ~= "number" then return end
        if original == nil or state.applied[region] ~= current then
            original = current
            state.original[region] = original
        end
        if selected and original == 0 and recoverAlpha then original = recoverAlpha; state.original[region] = original end
        local alpha = original * factor
        if current ~= alpha then region:SetAlpha(alpha) end
        state.applied[region] = alpha
    end
    local function BackdropFill(frame, alpha)
        local red, green, blue, current = frame:GetBackdropColor()
        if type(red) ~= "number" or type(green) ~= "number" or type(blue) ~= "number" or type(current) ~= "number" then return end
        local target = alpha * (1 - self:GetRestedXPBackgroundTransparency() / 100)
        state.fills[frame] = { original = alpha, applied = target }
        if current ~= target then frame:SetBackdropColor(red, green, blue, target) end
    end
    local function Panel(frame, fillAlpha)
        if not frame then return end
        local publicFill = not frame.rxpBackground and type(frame.GetBackdropColor) == "function"
            and type(frame.SetBackdropColor) == "function"
        if publicFill and selected and fillAlpha then
            state.fillRoles[frame] = fillAlpha
            -- Public backdrop colors also cover clients without exposed Center
            -- textures. Do not additionally fade Center's texture alpha.
            local center = frame.Center
            if center and state.original[center] ~= nil then
                center:SetAlpha(state.original[center])
                state.original[center], state.applied[center] = nil, nil
            end
            BackdropFill(frame, fillAlpha)
            Hook(frame, "SetBackdropColor", function(_, _, _, _, nativeAlpha)
                if state.applying then return end
                if self.savedDataReadOnly or rxp.settings.profile.activeTheme ~= NAME then state.fills[frame] = nil; return end
                state.applying = true
                local baseline = type(nativeAlpha) == "number" and nativeAlpha > 0 and nativeAlpha or state.fillRoles[frame]
                local success, problem = pcall(BackdropFill, frame, baseline)
                state.applying = false
                if not success then error(problem, 0) end
            end)
        end
        for _, piece in ipairs(backdropPieces) do
            if piece ~= "Center" or not publicFill then Layer(frame[piece], piece == "Center" and fillAlpha) end
        end
        -- V2's fill pixel alpha can be left at zero by a previous theme render.
        -- Recover only known fill roles; transparent border/check pixels stay native.
        if selected and fillAlpha then
            for _, texture in ipairs(frame.rxpBackground and frame.rxpBackground.textures or {}) do
                if type(texture.GetVertexColor) == "function" and type(texture.SetVertexColor) == "function" then
                    local red, green, blue, alpha = texture:GetVertexColor()
                    if alpha ~= fillAlpha then texture:SetVertexColor(red, green, blue, fillAlpha) end
                end
            end
        end
        Layer(frame.rxpBackground, fillAlpha and 1)
        Layer(frame.rxpBorder)
        Layer(frame.rxpShadow)
    end
    local function Scroll(scroll)
        if not scroll then return end
        Layer(scroll.scrollbg)
        Hook(scroll, "RefreshVisuals")
    end
    local function Widget(widget)
        if not widget then return end
        Panel(widget.frame, common)
        Panel(widget.card, common)
        Panel(widget.title, common)
        Panel(widget.content, common)
        Layer(widget.footerBackground)
        Hook(widget, "UpdateTheme")
        Hook(widget, "UpdateSubTheme")
        Scroll(widget)
    end
    local function Auxiliary(frame)
        if not frame then return end
        Panel(frame, frame.v2 and common or frame == rxp.activeItemFrame and 0.4 or ColorAlpha(legacy.background))
        Panel(frame.title, frame.v2 and common or ColorAlpha(legacy.background))
        Hook(frame, "UpdateVisuals")
    end
    state.applying = true
    local success, problem = pcall(function()
        if factor == 1 then
            -- Also restore released/pooled regions no longer in the current rows.
            for region in pairs(state.original) do Layer(region) end
            for region in pairs(state.original) do state.original[region], state.applied[region] = nil, nil end
            for frame, fill in pairs(state.fills) do
                local red, green, blue, alpha = frame:GetBackdropColor()
                if alpha == fill.applied and alpha ~= fill.original then frame:SetBackdropColor(red, green, blue, fill.original) end
                state.fills[frame] = nil
            end
        end
        local root = rxp.RXPFrame
        if root then
            Panel(root)
            for _, key in ipairs({ "BottomFrame", "GuideName", "Footer", "CurrentStepFrame", "ScrollChild" }) do Panel(root[key], ColorAlpha(legacy.background)) end
            Layer(root.GuideName and root.GuideName.bg)
            Layer(root.Footer and root.Footer.bg)
            local current = root.CurrentStepFrame
            for _, panel in ipairs(current and current.framePool or {}) do Panel(panel, ColorAlpha(legacy.background)); Panel(panel.number, ColorAlpha(legacy.background)) end
            local list = root.ScrollChild
            for _, panel in ipairs(list and list.framePool or {}) do Panel(panel, ColorAlpha(legacy.bottomFrameBG)); Panel(panel.number) end
            Auxiliary(root.activeItemFrame)
        end
        Auxiliary(rxp.activeItemFrame)
        Auxiliary(rxp.targeting and rxp.targeting.activeTargetFrame)
        local native = v2 and v2.state
        local window = native and native.guideWindow
        if window then
            Widget(window)
            Panel(window.upperFrame, ColorAlpha(backgrounds.guideWindow))
            Panel(window.guideStepsFrame, common)
            Panel(window.guideNameFrame, modern and 0.5)
            Layer(window.banner)
            local steps = window.guideSteps
            if steps then
                Hook(steps, "SetRows")
                Hook(steps, "RefreshVisuals")
                Scroll(steps.scroll)
                for _, row in pairs(steps.items or {}) do
                    Panel(row.frame, common)
                    Panel(row.numberFrame, ColorAlpha(backgrounds.activeStepCheckbox))
                end
            end
        end
        local party = native and native.activePartyStepFrame
        if party then
            Widget(party)
            Hook(party, "RefreshTabTheme")
            for _, tab in pairs(party.tabButtons or {}) do Panel(tab, common) end
            -- This footer's background is local in RXP; cache its own texture
            -- regions once, excluding the footer font string and child buttons.
            local footer = party.footer
            if footer and type(footer.GetRegions) == "function" then
                local regions = state.footerRegions[footer]
                if not regions then
                    regions = {}
                    for _, region in ipairs({ footer:GetRegions() }) do
                        if type(region.GetObjectType) == "function" and region:GetObjectType() == "Texture" then
                            regions[#regions + 1] = region
                        end
                    end
                    state.footerRegions[footer] = regions
                end
                for _, region in ipairs(regions) do Layer(region) end
            end
        end
        for _, player in pairs(native and native.player or {}) do
            Widget(player.activeStepFrame)
            Widget(player.childContainer)
            for _, item in ipairs(player.activeStepItems or {}) do Widget(item) end
        end
        local scrollbarState = self.restedxpScrollbarState and self.restedxpScrollbarState[rxp]
        for _, bar in pairs(scrollbarState and scrollbarState.bars or {}) do Layer(bar.track) end
    end)
    state.applying = false
    if not success then error(problem, 0) end
end

-- Keep the native CheckButton and all of its state/input. Only its artwork is
-- covered by an input-transparent child; in V2 the native skip preview stays on top.
local checkboxTextures = { "Normal", "Pushed", "Highlight", "Disabled", "Checked", "DisabledChecked" }

local function CheckboxNative(record, region)
    if not region or type(region.GetAlpha) ~= "function" or type(region.SetAlpha) ~= "function" then return end
    local alpha = region:GetAlpha()
    if record.native[region] == nil or alpha ~= 0 then record.native[region] = alpha end
    if alpha ~= 0 then region:SetAlpha(0) end
end

local function CheckboxPaint(record)
    if not record.active or record.painting then return end
    record.painting = true
    local button, visual, palette = record.button, record.visual, record.palette
    for _, name in ipairs(checkboxTextures) do
        local getter = button["Get" .. name .. "Texture"]
        if type(getter) == "function" then CheckboxNative(record, getter(button)) end
    end
    for _, name in ipairs({ "rxpBackground", "rxpBorder", "rxpCheckShort", "rxpCheckLong" }) do
        CheckboxNative(record, button[name])
    end
    local enabled, checked = button:IsEnabled(), button:GetChecked()
    local hovered = record.hovered or button.rxpHovered
    local border = enabled and (hovered or checked) and palette.accent or palette.border
    for _, edge in ipairs(visual.edges) do edge:SetColorTexture(unpack(border)) end
    visual.fill:SetColorTexture(checked and 0.055 or 0.025, checked and 0.13 or 0.035, checked and 0.20 or 0.05, 1)
    visual:SetAlpha(enabled and 1 or 0.5)
    for _, mark in ipairs(visual.check) do
        mark:SetColorTexture(unpack(enabled and palette.accent or palette.muted))
        if checked then mark:Show() else mark:Hide() end
    end
    -- RXP V2 swaps the checkbox for a skip icon while hovered. Its hover frame
    -- also owns the tooltip; leave its visibility, artwork and scripts untouched.
    if button.rxpHoverFrame and button.rxpHovered then visual:Hide() else visual:Show() end
    record.painting = false
end

local function CheckboxRestore(record)
    if not record.active then return end
    record.active = false
    for region, alpha in pairs(record.native) do
        if region:GetAlpha() == 0 then region:SetAlpha(alpha) end
        record.native[region] = nil
    end
    record.visual:Hide()
end

local function CheckboxVisual(button)
    local visual = CreateFrame("Frame", nil, button)
    visual:SetAllPoints(button)
    visual:SetFrameLevel(button:GetFrameLevel() + 1)
    visual:EnableMouse(false)
    visual.fill = visual:CreateTexture(nil, "BACKGROUND")
    visual.fill:SetAllPoints(visual)
    visual.edges = {}
    for index = 1, 4 do visual.edges[index] = visual:CreateTexture(nil, "BORDER") end
    local edges = visual.edges
    edges[1]:SetPoint("TOPLEFT"); edges[1]:SetPoint("TOPRIGHT"); edges[1]:SetHeight(1)
    edges[2]:SetPoint("BOTTOMLEFT"); edges[2]:SetPoint("BOTTOMRIGHT"); edges[2]:SetHeight(1)
    edges[3]:SetPoint("TOPLEFT"); edges[3]:SetPoint("BOTTOMLEFT"); edges[3]:SetWidth(1)
    edges[4]:SetPoint("TOPRIGHT"); edges[4]:SetPoint("BOTTOMRIGHT"); edges[4]:SetWidth(1)
    visual.check = {}
    for index, length in ipairs({ 3.5, 6 }) do
        local mark = visual:CreateTexture(nil, "OVERLAY")
        mark:SetSize(length, 1.25)
        mark:SetPoint("CENTER", visual, "CENTER", index == 1 and -1.5 or 1, index == 1 and -0.8 or -0.1)
        mark:SetRotation(index == 1 and -math.pi / 4 or math.pi / 4)
        visual.check[index] = mark
    end
    return visual
end

function addon:RefreshRestedXPCheckboxes(rxp)
    if not rxp or type(rxp.settings) ~= "table" or type(rxp.settings.profile) ~= "table" then return end
    self.restedxpCheckboxState = self.restedxpCheckboxState or setmetatable({}, { __mode = "k" })
    local state = self.restedxpCheckboxState[rxp]
    if not state then
        state = { buttons = setmetatable({}, { __mode = "k" }), hooks = setmetatable({}, { __mode = "k" }) }
        self.restedxpCheckboxState[rxp] = state
    end
    if state.applying then return end
    local function Hook(owner, method, callback)
        if not owner or type(owner[method]) ~= "function" or type(hooksecurefunc) ~= "function" then return end
        local hooks = state.hooks[owner] or {}
        state.hooks[owner] = hooks
        if hooks[method] then return end
        hooksecurefunc(owner, method, callback)
        hooks[method] = true
    end
    local function Wanted()
        return self:IsRestedXPSkinEnabled() and rxp.settings.profile.activeTheme == NAME
    end
    local function Pending()
        if self.restedxpSkinState then self.restedxpSkinState.pending = true end
    end
    local function Attach(button)
        if not button or type(button.GetChecked) ~= "function" or type(button.IsEnabled) ~= "function"
            or type(button.HookScript) ~= "function" or type(CreateFrame) ~= "function" then return end
        local record = state.buttons[button]
        local wanted = Wanted()
        if InCombat() then
            if wanted or record and record.active then Pending() end
            if record then CheckboxPaint(record) end
            return
        end
        if not wanted then if record then CheckboxRestore(record) end; return end
        if not record then
            record = { button = button, visual = CheckboxVisual(button), native = setmetatable({}, { __mode = "k" }) }
            state.buttons[button] = record
            local function Paint() CheckboxPaint(record) end
            for _, method in ipairs({ "SetChecked", "Enable", "Disable", "SetEnabled" }) do Hook(button, method, Paint) end
            button:HookScript("PostClick", Paint)
            button:HookScript("OnEnter", function() record.hovered = true; Paint() end)
            button:HookScript("OnLeave", function() record.hovered = nil; Paint() end)
        end
        record.active, record.palette = true, self.Theme:GetPalette()
        CheckboxPaint(record)
    end
    local function Rows(widget)
        for _, row in ipairs(widget and widget.elementRows or {}) do Attach(row.button) end
    end
    local function Widget(widget)
        if not widget then return end
        for _, method in ipairs({ "SetElements", "RefreshElements", "UpdateSubTheme" }) do
            Hook(widget, method, function() Rows(widget) end)
        end
        Rows(widget)
    end
    local function Refresh() self:RefreshRestedXPCheckboxes(rxp) end
    Hook(rxp, "LoadActiveTheme", Refresh)
    Hook(rxp, "RenderFrame", Refresh)
    Hook(rxp, "SetStep", Refresh)
    Hook(rxp, "BindActiveStepElement", function(row) if row then Attach(row.button) end end)
    Hook(rxp.v2, "ReconcileActiveStepItems", Refresh)
    Hook(rxp.v2, "UpdateActiveStepTheme", Refresh)
    state.applying = true
    local success, problem = pcall(function()
        if not Wanted() and not InCombat() then
            for _, record in pairs(state.buttons) do CheckboxRestore(record) end
            return
        end
        local current = rxp.RXPFrame and rxp.RXPFrame.CurrentStepFrame
        for _, step in ipairs(current and current.framePool or {}) do
            for _, row in ipairs(step.elements or {}) do Attach(row.button) end
        end
        local native = rxp.v2 and rxp.v2.state
        for _, player in pairs(native and native.player or {}) do
            for _, item in ipairs(player.activeStepItems or {}) do Widget(item) end
        end
        -- Pooled controls can be absent from the current item list when disabled.
        if InCombat() and not Wanted() then
            for _, record in pairs(state.buttons) do if record.active then Pending(); break end end
        end
    end)
    state.applying = false
    if not success then error(problem, 0) end
end

-- RXP uses the shared GameTooltip. Match exact addon-owned frame ancestry,
-- never tooltip text or frame-name prefixes (RXP also annotates ordinary items).
local function RestedXPTooltipOwner(rxp, owner)
    local roots = {}
    local function Root(frame)
        if not frame or frame == UIParent or frame == WorldFrame then return end
        roots[frame] = true
        if frame.frame and frame.frame ~= UIParent and frame.frame ~= WorldFrame then roots[frame.frame] = true end
    end
    Root(rxp.RXPFrame)
    Root(rxp.RXPFrame and rxp.RXPFrame.activeItemFrame)
    Root(rxp.activeItemFrame)
    Root(rxp.targeting and rxp.targeting.activeTargetFrame)
    for _, frame in pairs(rxp.enabledFrames or {}) do Root(frame) end
    local native = rxp.v2 and rxp.v2.state
    Root(native and native.guideWindow)
    Root(native and native.activePartyStepFrame)
    for _, player in pairs(native and native.player or {}) do
        Root(player.activeStepFrame)
        Root(player.childContainer)
        for _, item in ipairs(player.activeStepItems or {}) do Root(item); Root(item.card) end
    end
    local menus = addon.restedxpMenuState and addon.restedxpMenuState[rxp]
    for frame in pairs(menus and menus.panels or {}) do
        if not (type(frame.IsForbidden) == "function" and frame:IsForbidden())
            and frame:IsShown() and menus.owners[frame.dropdown] then Root(frame) end
    end
    -- Map buttons live under shared map frames. HBD's addon-keyed registries
    -- identify RXP pins without claiming other addons' pins or the whole map.
    local pins
    if LibStub then
        local success, library = pcall(LibStub, "HereBeDragons-Pins-2.0", true)
        if success and type(library) == "table" then pins = library end
    end
    local worldPins = pins and pins.worldmapPinRegistry and pins.worldmapPinRegistry[rxp]
    local miniPins = pins and pins.minimapPinRegistry and pins.minimapPinRegistry[rxp]
    local seen = {}
    for _ = 1, 32 do
        if not owner or owner == UIParent or owner == WorldFrame or seen[owner] then return false end
        if type(owner.IsForbidden) == "function" and owner:IsForbidden() then return false end
        if roots[owner] or worldPins and worldPins[owner] or miniPins and miniPins[owner] then return true end
        seen[owner] = true
        owner = type(owner.GetParent) == "function" and owner:GetParent() or nil
    end
    return false
end

local function TooltipColor(tooltip, method)
    if type(tooltip[method]) ~= "function" then return end
    local red, green, blue, alpha = tooltip[method](tooltip)
    if type(red) == "number" and type(green) == "number" and type(blue) == "number" then
        return { red, green, blue, alpha or 1 }
    end
end

local function TooltipRestore(tooltip, state)
    if not state.active then return end
    state.active = false
    for region, alpha in pairs(state.native) do
        if region:GetAlpha() == 0 then region:SetAlpha(alpha) end
        state.native[region] = nil
    end
    -- A new owner may already have supplied its own backdrop; preserve it.
    local legacy = state.legacy
    if legacy and not tooltip:GetBackdrop() and legacy.backdrop then
        tooltip:SetBackdrop(legacy.backdrop)
        if legacy.fill and type(tooltip.SetBackdropColor) == "function" then tooltip:SetBackdropColor(unpack(legacy.fill)) end
        if legacy.border and type(tooltip.SetBackdropBorderColor) == "function" then tooltip:SetBackdropBorderColor(unpack(legacy.border)) end
    end
    state.legacy = nil
    for _, texture in ipairs(state.textures or {}) do texture:Hide() end
end

local function FlatPanelTextures(frame)
    local textures = {}
    for index = 1, 5 do textures[index] = frame:CreateTexture(nil, index == 1 and "BACKGROUND" or "BORDER") end
    textures[1]:SetAllPoints(frame)
    textures[2]:SetPoint("TOPLEFT"); textures[2]:SetPoint("TOPRIGHT"); textures[2]:SetHeight(1)
    textures[3]:SetPoint("BOTTOMLEFT"); textures[3]:SetPoint("BOTTOMRIGHT"); textures[3]:SetHeight(1)
    textures[4]:SetPoint("TOPLEFT"); textures[4]:SetPoint("BOTTOMLEFT"); textures[4]:SetWidth(1)
    textures[5]:SetPoint("TOPRIGHT"); textures[5]:SetPoint("BOTTOMRIGHT"); textures[5]:SetWidth(1)
    return textures
end

function addon:RefreshRestedXPTooltips(rxp)
    local tooltip = GameTooltip
    if not rxp or not rxp.settings or not rxp.settings.profile or not tooltip
        or type(tooltip.GetOwner) ~= "function" or type(tooltip.HookScript) ~= "function"
        or type(tooltip.CreateTexture) ~= "function" then return end
    if type(tooltip.IsForbidden) == "function" and tooltip:IsForbidden() then return end
    self.restedxpTooltipState = self.restedxpTooltipState or setmetatable({}, { __mode = "k" })
    local state = self.restedxpTooltipState[rxp]
    if not state then
        state = { native = setmetatable({}, { __mode = "k" }), hooks = setmetatable({}, { __mode = "k" }) }
        self.restedxpTooltipState[rxp] = state
    end
    if state.applying then return end
    local function Update() self:RefreshRestedXPTooltips(rxp) end
    local function Hook(owner, method, callback)
        if not owner or type(owner[method]) ~= "function" or type(hooksecurefunc) ~= "function" then return end
        local hooks = state.hooks[owner] or {}
        state.hooks[owner] = hooks
        if hooks[method] then return end
        hooksecurefunc(owner, method, callback or Update)
        hooks[method] = true
    end
    if not state.scripts then
        tooltip:HookScript("OnShow", Update)
        tooltip:HookScript("OnHide", Update)
        state.scripts = true
    end
    Hook(tooltip, "SetOwner")
    Hook(tooltip, "Show")
    Hook(tooltip, "SetShown")
    Hook(tooltip, "Hide")
    Hook(tooltip, "SetHyperlink")
    Hook(tooltip, "SetBackdrop", function()
        if state.applying then return end
        if state.legacy then
            local backdrop = tooltip:GetBackdrop()
            state.legacy = { backdrop = Copy(backdrop), fill = backdrop and TooltipColor(tooltip, "GetBackdropColor"),
                border = backdrop and TooltipColor(tooltip, "GetBackdropBorderColor") }
        end
        Update()
    end)
    for _, entry in ipairs({ { "SetBackdropColor", "fill" }, { "SetBackdropBorderColor", "border" } }) do
        local field = entry[2]
        Hook(tooltip, entry[1], function(_, red, green, blue, alpha)
            if state.applying then return end
            if state.legacy and type(red) == "number" and type(green) == "number" and type(blue) == "number" then
                state.legacy[field] = { red, green, blue, alpha or 1 }
            end
            Update()
        end)
    end
    Hook(rxp, "LoadActiveTheme")
    local wanted = self:IsRestedXPSkinEnabled() and rxp.settings.profile.activeTheme == NAME
        and tooltip:IsShown() and RestedXPTooltipOwner(rxp, tooltip:GetOwner())
    if wanted and not state.textures and InCombat() then
        if self.restedxpSkinState then self.restedxpSkinState.pending = true end
        return
    end
    state.applying = true
    local success, problem = pcall(function()
        if not wanted then TooltipRestore(tooltip, state); return end
        state.textures = state.textures or FlatPanelTextures(tooltip)
        state.active = true
        local function Suppress(region)
            if not region or region == tooltip or type(region.GetAlpha) ~= "function" or type(region.SetAlpha) ~= "function" then return end
            local alpha = region:GetAlpha()
            if state.native[region] == nil or alpha ~= 0 then state.native[region] = alpha end
            if alpha ~= 0 then region:SetAlpha(0) end
        end
        Suppress(tooltip.NineSlice)
        Suppress(tooltip.BackdropContainer)
        Suppress(tooltip.TextureSliceBackground)
        for _, piece in ipairs(backdropPieces) do Suppress(tooltip[piece]) end
        -- Older clients keep backdrop pixels private. Clearing only that
        -- decoration leaves tooltip padding, text and native anchor untouched.
        if not tooltip.Center and type(tooltip.GetBackdrop) == "function" and type(tooltip.SetBackdrop) == "function" then
            local backdrop = tooltip:GetBackdrop()
            if backdrop then
                state.legacy = { backdrop = Copy(backdrop), fill = TooltipColor(tooltip, "GetBackdropColor"),
                    border = TooltipColor(tooltip, "GetBackdropBorderColor") }
                tooltip:SetBackdrop(nil)
            end
        end
        local palette = self.Theme:GetPalette()
        for index, texture in ipairs(state.textures) do
            texture:SetColorTexture(unpack(index == 1 and palette.background or palette.border))
            texture:Show()
        end
    end)
    state.applying = false
    if not success then error(problem, 0) end
end

local function MenuRestore(record)
    if not record.active then return end
    record.active = false
    for region, alpha in pairs(record.native) do
        if region:GetAlpha() == 0 then region:SetAlpha(alpha) end
        record.native[region] = nil
    end
    for _, texture in ipairs(record.textures or {}) do texture:Hide() end
    for _, texture in pairs(record.highlights) do texture:Hide() end
end

function addon:RefreshRestedXPMenus(rxp)
    if not rxp or not rxp.settings or not rxp.settings.profile then return end
    self.restedxpMenuState = self.restedxpMenuState or setmetatable({}, { __mode = "k" })
    local state = self.restedxpMenuState[rxp]
    if not state then
        state = { owners = setmetatable({}, { __mode = "k" }), panels = setmetatable({}, { __mode = "k" }),
            hooks = setmetatable({}, { __mode = "k" }) }
        self.restedxpMenuState[rxp] = state
    end
    if state.applying then return end
    local default = rxp.RXPFrame and rxp.RXPFrame.MenuFrame
    if default then state.owners[default] = true end
    local function Update() self:RefreshRestedXPMenus(rxp) end
    local function Hook(owner, method, callback)
        if not owner or type(owner[method]) ~= "function" or type(hooksecurefunc) ~= "function" then return end
        local hooks = state.hooks[owner] or {}
        state.hooks[owner] = hooks
        if hooks[method] then return end
        hooksecurefunc(owner, method, callback or Update)
        hooks[method] = true
    end
    Hook(rxp, "ShowMenu", function(_, _, menuFrame)
        local owner = menuFrame or rxp.RXPFrame and rxp.RXPFrame.MenuFrame
        if owner then state.owners[owner] = true end
        Update()
    end)
    Hook(rxp, "LoadActiveTheme")
    -- Both menu backends pool their lists across addons. Discover after native
    -- creation/toggling; submenus can open without another RXP ShowMenu call.
    for _, method in ipairs({ "EasyMenu", "ToggleDropDownMenu", "UIDropDownMenu_CreateFrames", "UIDropDownMenu_Initialize" }) do
        Hook(_G, method)
    end
    if LibStub then
        local success, library = pcall(LibStub, "LibUIDropDownMenu-4.0", true)
        if success and type(library) == "table" then
            for _, method in ipairs({ "EasyMenu", "ToggleDropDownMenu", "UIDropDownMenu_CreateFrames", "UIDropDownMenu_Initialize" }) do
                Hook(library, method)
            end
        end
    end
    -- Native V2 themes menus after OnShow, including delayed submenu hooks.
    -- Reapply decorations afterward; never change its menu-theme preference.
    Hook(rxp.v2, "UpdateMenuTheme")
    local function Pending()
        if self.restedxpSkinState then self.restedxpSkinState.pending = true end
    end
    local function Find(frame)
        if not frame or state.panels[frame] or type(frame.HookScript) ~= "function"
            or type(frame.CreateTexture) ~= "function" then return end
        if type(frame.IsForbidden) == "function" and frame:IsForbidden() then return end
        state.panels[frame] = { frame = frame, native = setmetatable({}, { __mode = "k" }),
            highlights = setmetatable({}, { __mode = "k" }) }
        frame:HookScript("OnShow", Update)
        frame:HookScript("OnHide", Update)
        Hook(frame, "Show")
        Hook(frame, "SetShown")
        Hook(frame, "Hide")
    end
    local enabled = rxp.settings.profile.activeTheme == NAME
        and (self:IsRestedXPSkinEnabled() or self:IsRestedXPChromeHidden())
    state.applying = true
    local success, problem = pcall(function()
        for _, backend in ipairs({ { "DropDownList", "UIDROPDOWNMENU_MAXLEVELS" },
            { "L_DropDownList", "L_UIDROPDOWNMENU_MAXLEVELS" } }) do
            local levels = math.min(32, math.max(3, tonumber(_G[backend[2]]) or 3))
            for level = 1, levels do Find(_G[backend[1] .. level]) end
        end
        local palette = self.Theme:GetPalette()
        for frame, record in pairs(state.panels) do
            if not (type(frame.IsForbidden) == "function" and frame:IsForbidden()) then
                -- A hidden list retains its last dropdown owner. That stale
                -- reference must not keep our artwork on a shared native panel.
                local wanted = enabled and frame:IsShown() and state.owners[frame.dropdown] == true
                if not wanted then
                    MenuRestore(record)
                elseif not record.textures and InCombat() then
                    Pending()
                else
                    record.textures = record.textures or FlatPanelTextures(frame)
                    record.active = true
                    local function Suppress(region)
                        if not region or region == frame or type(region.GetAlpha) ~= "function" or type(region.SetAlpha) ~= "function" then return end
                        local alpha = region:GetAlpha()
                        if record.native[region] == nil or alpha ~= 0 then record.native[region] = alpha end
                        if alpha ~= 0 then region:SetAlpha(0) end
                    end
                    local name = type(frame.GetName) == "function" and frame:GetName()
                    Suppress(frame.Backdrop or name and _G[name .. "Backdrop"])
                    Suppress(frame.MenuBackdrop or name and _G[name .. "MenuBackdrop"])
                    Suppress(frame.NineSlice)
                    for _, piece in ipairs(backdropPieces) do Suppress(frame[piece]) end
                    for _, group in ipairs({ "rxpBackground", "rxpBorder", "rxpShadow" }) do Suppress(frame[group]) end
                    for index, texture in ipairs(record.textures) do
                        texture:SetColorTexture(unpack(index == 1 and palette.background or palette.border))
                        texture:Show()
                    end
                    for index = 1, frame.numButtons or 0 do
                        local button = frame["Button" .. index] or name and _G[name .. "Button" .. index]
                        if button and type(button.CreateTexture) == "function" then
                            local highlight = record.highlights[button]
                            if not highlight and InCombat() then
                                Pending()
                            else
                                if not highlight then
                                    -- HIGHLIGHT follows native hover and
                                    -- LockHighlight selection. No input handlers,
                                    -- checked callbacks or hit areas change.
                                    highlight = button:CreateTexture(nil, "HIGHLIGHT")
                                    highlight:SetAllPoints(button)
                                    record.highlights[button] = highlight
                                end
                                local native = button.Highlight or type(button.GetHighlightTexture) == "function" and button:GetHighlightTexture()
                                Suppress(native or name and _G[name .. "Button" .. index .. "Highlight"])
                                highlight:SetColorTexture(palette.accent[1], palette.accent[2], palette.accent[3], 0.18)
                                highlight:Show()
                            end
                        end
                    end
                end
            end
        end
    end)
    state.applying = false
    if not success then error(problem, 0) end
end
