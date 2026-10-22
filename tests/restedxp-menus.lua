-- RestedXP uses shared dropdown pools; appearance must follow the exact owner.
local helpers = dofile("tests/support/helpers.lua")
local HookScript, RunScript = dofile("tests/support/scripts.lua")
local Copy, Equal = helpers.copy, helpers.equal

local function Points(frame)
    local points = {}
    for index = 1, frame:GetNumPoints() do points[index] = { frame:GetPoint(index) } end
    return points
end

local function Fixture(bundled, v2Enabled)
    local world = { combat = false, createdFrames = 0, nativeClicks = 0, checkedCalls = 0,
        enters = 0, leaves = 0, callbacks = {}, lists = {}, hooks = 0 }
    local env = setmetatable({}, { __index = _G })
    env._G = env
    local Frame, Region
    Region = function(parent, name, layer, kind)
        local region = { parent = parent, name = name, layer = layer, kind = kind or "Texture", shown = true,
            alpha = 0.8, color = { 0.7, 0.6, 0.5, 0.9 }, coordinates = { 0, 1, 0, 1 },
            font = { "NativeMenuFont", 12, "OUTLINE" }, points = {}, width = 16, height = 16 }
        function region:GetName() return self.name end
        function region:GetObjectType() return self.kind end
        function region:GetParent() return self.parent end
        function region:GetAlpha() return self.alpha end
        function region:SetAlpha(value) self.alpha = value end
        function region:IsShown() return self.shown end
        function region:IsVisible()
            return self.shown and (self.layer ~= "HIGHLIGHT" or self.parent.hovered == true or self.parent.highlightLocked == true)
                and (not self.parent or self.parent:IsVisible())
        end
        function region:Show() self.shown = true end
        function region:Hide() self.shown = false end
        function region:SetShown(value) self.shown = value == true end
        function region:GetTexture() return self.texture end
        function region:SetTexture(value) self.texture = value end
        function region:SetColorTexture(...) self.color = { ... }; self.texture = "solid" end
        function region:GetVertexColor() return unpack(self.color) end
        function region:SetVertexColor(...) self.color = { ... } end
        function region:GetTexCoord() return unpack(self.coordinates) end
        function region:SetTexCoord(...) self.coordinates = { ... } end
        function region:SetBlendMode(value) self.blend = value end
        function region:GetBlendMode() return self.blend end
        function region:SetDesaturated(value) self.desaturated = value end
        function region:IsDesaturated() return self.desaturated end
        function region:GetFont() return unpack(self.font) end
        function region:SetFont(...) self.font = { ... } end
        function region:GetTextColor() return unpack(self.color) end
        function region:SetTextColor(...) self.color = { ... } end
        function region:GetText() return self.text end
        function region:SetText(value) self.text = value end
        function region:GetWidth() return self.width end
        function region:GetHeight() return self.height end
        function region:SetWidth(value) self.width = value end
        function region:SetHeight(value) self.height = value end
        function region:SetSize(width, height) self.width, self.height = width, height end
        function region:GetNumPoints() return #self.points end
        function region:GetPoint(index) return unpack(self.points[index or 1]) end
        function region:ClearAllPoints() self.points = {} end
        function region:SetPoint(...) self.points[#self.points + 1] = { ... } end
        function region:SetAllPoints(value) self.allPoints = value or self.parent end
        if name then env[name] = region end
        return region
    end
    Frame = function(name, parent, kind)
        local frame = { name = name, parent = parent, kind = kind or "Frame", shown = true, alpha = 1,
            width = 220, height = 90, enabled = true, points = {}, regions = {}, children = {}, scripts = {}, scriptHooks = {} }
        function frame:GetName() return self.name end
        function frame:GetObjectType() return self.kind end
        function frame:GetParent() return self.parent end
        function frame:IsForbidden() return false end
        function frame:IsProtected() return false end
        function frame:GetAlpha() return self.alpha end
        function frame:SetAlpha(value) self.alpha = value end
        function frame:IsShown() return self.shown end
        function frame:IsVisible() return self.shown and (not self.parent or self.parent:IsVisible()) end
        function frame:GetWidth() return self.width end
        function frame:GetHeight() return self.height end
        function frame:SetWidth(value) self.width = value end
        function frame:SetHeight(value) self.height = value end
        function frame:SetSize(width, height) self.width, self.height = width, height end
        function frame:GetNumPoints() return #self.points end
        function frame:GetPoint(index) return unpack(self.points[index or 1]) end
        function frame:ClearAllPoints() self.points = {} end
        function frame:SetPoint(...) self.points[#self.points + 1] = { ... } end
        function frame:SetAllPoints(value) self.allPoints = value or self.parent end
        function frame:GetScript(name) return self.scripts[name] end
        function frame:SetScript(name, callback) self.scripts[name] = callback end
        frame.HookScript, frame.RunScript = HookScript, RunScript
        function frame:Show() self.shown = true; self:RunScript("OnShow") end
        function frame:Hide() self.shown = false; self:RunScript("OnHide") end
        function frame:SetShown(value)
            self.shown = value == true
            self:RunScript(self.shown and "OnShow" or "OnHide")
        end
        function frame:IsEnabled() return self.enabled end
        function frame:Enable() self.enabled = true; self:RunScript("OnEnable") end
        function frame:Disable() self.enabled = false; self:RunScript("OnDisable") end
        function frame:SetEnabled(value) if value then self:Enable() else self:Disable() end end
        function frame:LockHighlight() self.highlightLocked = true end
        function frame:UnlockHighlight() self.highlightLocked = false end
        function frame:GetFontString() return self.NormalText end
        function frame:GetNormalTexture() return self.NormalTexture end
        function frame:GetHighlightTexture() return self.Highlight end
        function frame:GetRegions() return unpack(self.regions) end
        function frame:GetChildren() return unpack(self.children) end
        function frame:GetID() return self.id end
        function frame:CreateTexture(name, layer)
            local region = Region(self, name, layer)
            self.regions[#self.regions + 1] = region
            return region
        end
        function frame:GetBackdrop() return self.backdrop end
        function frame:SetBackdrop(value) self.backdrop = Copy(value) end
        function frame:GetBackdropColor() return unpack(self.fill or { 1, 1, 1, 1 }) end
        function frame:SetBackdropColor(...) self.fill = { ... } end
        function frame:GetBackdropBorderColor() return unpack(self.border or { 1, 1, 1, 1 }) end
        function frame:SetBackdropBorderColor(...) self.border = { ... } end
        if parent then parent.children[#parent.children + 1] = frame end
        if name then env[name] = frame end
        return frame
    end
    env.UIParent = Frame("UIParent")
    local root = Frame("RXPFrame", env.UIParent)
    root.MenuFrame = Frame("RXPG_MenuFrame", env.UIParent)
    local rxp = { RXPFrame = root, settings = { profile = { activeTheme = "LockInTools", enableV2MenuTheme = true } }, v2 = {} }
    function rxp.v2:IsGuideWindowEnabled() return v2Enabled == true end
    function rxp.v2:UpdateMenuTheme(list, enabled)
        if not self:IsGuideWindowEnabled() or not list then return end
        if enabled then
            env[list.name .. "Backdrop"]:Hide()
            env[list.name .. "MenuBackdrop"]:Hide()
            list.rxpBackground:SetAlpha(0.65)
            list.rxpBorder:SetAlpha(0.75)
            list.rxpShadow:SetAlpha(0.85)
            list.rxpV2MenuThemeApplied = true
            for index = 1, list.numButtons do list.rows[index].NormalText:SetFont("NativeV2MenuFont", 12, "OUTLINE") end
        elseif list.rxpV2MenuThemeApplied then
            env[list.name .. "Backdrop"]:Show()
            env[list.name .. "MenuBackdrop"]:Show()
            list.rxpV2MenuThemeApplied = nil
        end
    end
    function rxp.v2:HookMenuSubmenus(prefix)
        for level = 2, env.UIDROPDOWNMENU_MAXLEVELS do
            local list = env[prefix .. level]
            if list and not list.rxpV2MenuThemeHooked then
                list:HookScript("OnShow", function(frame)
                    if frame.dropdown and frame.dropdown.rxpV2MenuTheme ~= nil then self:UpdateMenuTheme(frame, frame.dropdown.rxpV2MenuTheme) end
                end)
                list.rxpV2MenuThemeHooked = true
            end
        end
    end
    local function NewRow(list, index)
        local row = Frame(list.name .. "Button" .. index, list, "Button")
        row.id, row.width, row.height = index, 190, 16
        row.NormalText = Region(row, row.name .. "NormalText", "ARTWORK", "FontString")
        row.NormalText:SetPoint("LEFT", row, "LEFT", 16, 0)
        row.Highlight = row:CreateTexture(row.name .. "Highlight", "BACKGROUND")
        row.Highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row.Highlight:SetBlendMode("ADD")
        row.Check, row.UnCheck = row:CreateTexture(row.name .. "Check", "ARTWORK"), row:CreateTexture(row.name .. "UnCheck", "ARTWORK")
        row.Icon = row:CreateTexture(row.name .. "Icon", "ARTWORK")
        row.ExpandArrow = Frame(row.name .. "ExpandArrow", row, "Button")
        row.ExpandArrow.NormalTexture = row.ExpandArrow:CreateTexture(nil, "ARTWORK")
        row.ExpandArrow.NormalTexture:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
        row.scripts.OnClick = function(button, mouse)
            if not button:IsEnabled() then return end
            world.nativeClicks = world.nativeClicks + 1
            local checked = button.checked
            if type(checked) == "function" then checked = checked(button) end
            if button.keepShownOnClick then
                if not button.notCheckable then checked = not checked; button.Check:SetShown(checked); button.UnCheck:SetShown(not checked) end
            else list:Hide() end
            if type(button.checked) ~= "function" then button.checked = checked end
            if button.func then button.func(button, button.arg1, button.arg2, checked, mouse) end
        end
        row.scripts.OnEnter = function(button)
            world.enters = world.enters + 1
            button.hovered = true
            button.Highlight:Show()
            if button.hasArrow then world:OpenSubmenu(button) end
        end
        row.scripts.OnLeave = function(button) world.leaves = world.leaves + 1; button.hovered = false; button.Highlight:Hide() end
        row.ExpandArrow.scripts.OnEnter = function() if row.enabled then world:OpenSubmenu(row) end end
        row.ExpandArrow.scripts.OnMouseDown = row.ExpandArrow.scripts.OnEnter
        list.rows[index] = row
        return row
    end
    function world:NewList(prefix, level)
        local list = Frame(prefix .. level, env.UIParent)
        list.prefix, list.id, list.rows, list.numButtons, list.shown = prefix, level, {}, 0, false
        list.Backdrop, list.MenuBackdrop = Frame(list.name .. "Backdrop", list), Frame(list.name .. "MenuBackdrop", list)
        list.rxpBackground, list.rxpBorder, list.rxpShadow = Frame(nil, list), Frame(nil, list), Frame(nil, list)
        list.rxpBackground.alpha, list.rxpBorder.alpha, list.rxpShadow.alpha = 0.65, 0.75, 0.85
        list.scripts.OnShow = function() end
        list.scripts.OnHide = function() end
        self.lists[#self.lists + 1] = list
        return list
    end
    function world:OpenNative(prefix, owner, menu, level, anchor)
        local list = env[prefix .. level] or self:NewList(prefix, level)
        list:Hide() -- Native pooled reuse leaves the old .dropdown set until initialization.
        list.dropdown, list.numButtons = owner, #menu
        list.Backdrop:Show(); list.MenuBackdrop:Show()
        list:ClearAllPoints()
        list:SetPoint("TOPLEFT", anchor or owner, anchor and "TOPRIGHT" or "BOTTOMLEFT", 3, -4)
        list.width, list.height = 220, #menu * 16 + 20
        for index, info in ipairs(menu) do
            local row = list.rows[index] or NewRow(list, index)
            row.func, row.arg1, row.arg2, row.checked, row.menuList = info.func, info.arg1, info.arg2, info.checked, info.menuList
            row.keepShownOnClick, row.notCheckable, row.hasArrow, row.isNotRadio = info.keepShownOnClick, info.notCheckable, info.hasArrow, info.isNotRadio
            row.isTitle, row.value, row.enabled, row.shown = info.isTitle, info.value, not info.disabled, true
            row.NormalText:SetText(info.text)
            row.NormalText:SetFont("NativeMenuFont", 12, "OUTLINE")
            row.NormalText:SetTextColor(unpack(info.disabled and { 0.4, 0.4, 0.4, 1 } or info.isTitle and { 1, 0.8, 0, 1 } or { 1, 1, 1, 1 }))
            row.Highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            row.Highlight:SetBlendMode("ADD"); row.Highlight:SetVertexColor(1, 1, 1, 1); row.Highlight:Hide()
            for _, region in ipairs({ row.Check, row.UnCheck }) do
                region:SetTexture(info.customCheckIconTexture or "Interface\\Common\\UI-DropDownRadioChecks")
                region:SetTexCoord(0, 0.5, info.isNotRadio and 0 or 0.5, info.isNotRadio and 0.5 or 1)
                region:SetAlpha(info.disabled and 0.5 or 1); region:SetDesaturated(info.disabled == true)
            end
            local checked = info.checked
            if type(checked) == "function" then checked = checked(row) end
            if not info.notCheckable then
                if checked then row:LockHighlight() else row:UnlockHighlight() end
            end
            row.Check:SetShown(not info.notCheckable and checked == true)
            row.UnCheck:SetShown(not info.notCheckable and not checked)
            row.ExpandArrow:SetShown(info.hasArrow == true)
            row.Icon:SetTexture(info.icon); row.Icon:SetShown(info.icon ~= nil)
        end
        for index = #menu + 1, #list.rows do list.rows[index]:Hide() end
        list:Show()
        return list
    end
    local prefix = bundled and "L_DropDownList" or "DropDownList"
    env.UIDROPDOWNMENU_MAXLEVELS, env.L_UIDROPDOWNMENU_MAXLEVELS = 3, 3
    for level = 1, 3 do world:NewList(prefix, level) end
    function world:OpenSubmenu(row)
        if bundled then return self.lib:ToggleDropDownMenu(row.parent.id + 1, nil, nil, nil, nil, nil, row.menuList, row) end
        return env.ToggleDropDownMenu(row.parent.id + 1, nil, nil, nil, nil, nil, row.menuList, row)
    end
    local lib = {}
    function lib:EasyMenu(menu, owner) return world:OpenNative(prefix, owner, menu, 1) end
    function lib:ToggleDropDownMenu(level, _, owner, _, _, _, menu, button)
        return world:OpenNative(prefix, owner or button.parent.dropdown, menu, level or 1, button)
    end
    function env.ToggleDropDownMenu(level, value, owner, anchor, x, y, menu, button)
        return lib:ToggleDropDownMenu(level, value, owner, anchor, x, y, menu, button)
    end
    if not bundled then env.EasyMenu = function(menu, owner) return lib:EasyMenu(menu, owner) end end
    function rxp:ShowMenu(menu, owner)
        owner = owner or root.MenuFrame
        local previous = owner.rxpV2MenuTheme
        owner.rxpV2MenuTheme = v2Enabled and self.settings.profile.enableV2MenuTheme or nil
        if previous then self.v2:UpdateMenuTheme(env[prefix .. "1"], false) end
        local list = lib:EasyMenu(menu, owner)
        if owner.rxpV2MenuTheme then self.v2:UpdateMenuTheme(list, owner.rxpV2MenuTheme) end
        if v2Enabled then self.v2:HookMenuSubmenus(prefix) end
        return list
    end
    function world:CloseAll()
        for _, list in ipairs(self.lists) do list:Hide() end
    end
    env.CloseDropDownMenus = function() world:CloseAll() end
    function lib:CloseDropDownMenus() world:CloseAll() end
    local stub = setmetatable({}, { __call = function(_, name, silent)
        assert(silent == true)
        if name == "LibUIDropDownMenu-4.0" then return lib end
    end })
    function stub:GetLibrary(name, silent) return self(name, silent) end
    env.LibStub = stub
    env.InCombatLockdown = function() return world.combat end
    env.CreateFrame = function(kind, name, parent)
        world.createdFrames = world.createdFrames + 1
        return Frame(name, parent, kind)
    end
    env.GameFontHighlight = { GetFont = function() return "LockInToolsFont", 13, "" end }
    env.hooksecurefunc = helpers.hooksecurefunc(env, function() world.hooks = world.hooks + 1 end)
    local addon = { db = { restedxpSkin = { enabled = false } }, restedxpSkinState = {} }
    helpers.loadModule("Theme.lua", addon, env)
    helpers.loadModule("RestedXPSkin.lua", addon, env)
    world.env, world.Frame, world.lib, world.prefix = env, Frame, lib, prefix
    world.otherOwner = Frame("OtherAddonMenu", env.UIParent)
    world.falsePrefixOwner = Frame("RXPG_UnrelatedAddonMenu", env.UIParent)
    function world:Menu()
        local function Action(button, arg1, arg2, checked, mouse)
            self.callbacks[#self.callbacks + 1] = { button, arg1, arg2, checked, mouse }
        end
        local function Checked() self.checkedCalls = self.checkedCalls + 1; return true end
        return {
            { text = "Guide options", isTitle = true, disabled = true, notCheckable = true },
            { text = "Show completed steps", checked = Checked, isNotRadio = true, keepShownOnClick = true,
                func = Action, arg1 = "completion", arg2 = 17 },
            { text = "Compact", checked = false, func = Action, arg1 = "layout", arg2 = "compact" },
            { text = "Unavailable", disabled = true, checked = true, func = Action },
            { text = "Guides", notCheckable = true, hasArrow = true, menuList = {
                { text = "Zone", notCheckable = true, hasArrow = true, menuList = {
                    { text = "A native guide", notCheckable = true, icon = "native-guide-icon", func = Action, arg1 = "native-guide" },
                } },
            } },
            { text = "Special", checked = true, customCheckIconTexture = "native-custom-indicator", func = Action },
        }
    end
    return addon, rxp, world
end

local function Semantics(list)
    local snapshot = { owner = list.dropdown, points = Points(list), width = list.width, height = list.height, rows = {} }
    for index = 1, list.numButtons do
        local row = list.rows[index]
        snapshot.rows[index] = { text = row.NormalText:GetText(), textPoints = Points(row.NormalText),
            font = { row.NormalText:GetFont() }, textColor = { row.NormalText:GetTextColor() },
            scripts = Copy(row.scripts), func = row.func, arg1 = row.arg1, arg2 = row.arg2, checked = row.checked,
            menuList = row.menuList, enabled = row.enabled, keepShown = row.keepShownOnClick, notCheckable = row.notCheckable,
            highlightLocked = row.highlightLocked,
            width = row.width, height = row.height, arrowShown = row.ExpandArrow:IsShown(), arrowScripts = Copy(row.ExpandArrow.scripts),
            checkTexture = row.Check:GetTexture(), checkCoords = { row.Check:GetTexCoord() }, checkShown = row.Check:IsShown(),
            uncheckTexture = row.UnCheck:GetTexture(), uncheckCoords = { row.UnCheck:GetTexCoord() }, uncheckShown = row.UnCheck:IsShown(),
            disabledCheck = row.Check:IsDesaturated(), checkAlpha = row.Check:GetAlpha(), icon = row.Icon:GetTexture() }
    end
    return snapshot
end

local function NativeAppearance(list)
    local appearance = { backdrop = list.Backdrop:GetAlpha(), menuBackdrop = list.MenuBackdrop:GetAlpha(),
        backdropShown = list.Backdrop:IsShown(), menuBackdropShown = list.MenuBackdrop:IsShown(),
        fill = list.rxpBackground:GetAlpha(), border = list.rxpBorder:GetAlpha(), shadow = list.rxpShadow:GetAlpha(), rows = {} }
    for index = 1, list.numButtons do
        local row = list.rows[index]
        appearance.rows[index] = { font = { row.NormalText:GetFont() }, color = { row.NormalText:GetTextColor() },
            highlight = row.Highlight:GetTexture(), highlightColor = { row.Highlight:GetVertexColor() },
            highlightBlend = row.Highlight:GetBlendMode(), highlightAlpha = row.Highlight:GetAlpha() }
    end
    return appearance
end

local function OverlayShown(list)
    local count = 0
    for _, region in ipairs(list.regions) do
        if region:IsVisible() and region:GetAlpha() > 0 then count = count + 1 end
    end
    return count
end

local function Styled(addon, list)
    assert(OverlayShown(list) >= 5, "RXP menus receive a flat fill and four thin borders")
    assert(list.Backdrop:GetAlpha() == 0 and list.MenuBackdrop:GetAlpha() == 0, "native pooled menu artwork is suppressed only for RXP")
    local palette = addon.Theme:GetPalette()
    local fill, edges = 0, 0
    for _, region in ipairs(list.regions) do
        if region:IsVisible() and region:GetAlpha() > 0 then
            if region.layer == "BACKGROUND" then
                assert(Equal(region.color, palette.background), "menus use the LockInTools background")
                fill = fill + 1
            elseif region.layer == "BORDER" then
                assert(Equal(region.color, palette.border) and (region.width == 1 or region.height == 1), "menu borders remain thin and readable")
                edges = edges + 1
            end
        end
    end
    assert(fill == 1 and edges == 4)
    for index = 1, list.numButtons do
        assert(list.rows[index].Highlight:GetAlpha() == 0, "native additive hover artwork is suppressed")
    end
end

local function FlatHoverVisible(row)
    local visible = 0
    for _, region in ipairs(row.regions) do
        if region.layer == "HIGHLIGHT" and region:IsVisible() and region:GetAlpha() > 0 then visible = visible + 1 end
    end
    return visible
end

for _, bundled in ipairs({ false, true }) do
    for _, v2 in ipairs({ false, true }) do
        local addon, rxp, world = Fixture(bundled, v2)
        local menu = world:Menu()
        local list = rxp:ShowMenu(menu)
        local semantics, appearance = Semantics(list), NativeAppearance(list)
        local checkedCalls = world.checkedCalls
        addon:RefreshRestedXPMenus(rxp)
        assert(OverlayShown(list) == 0 and Equal(NativeAppearance(list), appearance), "disabled by default, native menus retain their appearance")
        addon.db.restedxpSkin.enabled = true
        addon:RefreshRestedXPMenus(rxp)
        Styled(addon, list)
        assert(Equal(Semantics(list), semantics), "styling preserves native rows, callbacks, check/radio art, layout and anchors")
        assert(world.checkedCalls == checkedCalls and #world.callbacks == 0, "styling never evaluates checked functions or invokes actions")
        assert(world.createdFrames == 0, "native dropdown panels and input controls are reused")

        assert(FlatHoverVisible(list.rows[2]) == 1 and list.rows[2].highlightLocked, "native selected-row highlighting remains locked")
        assert(FlatHoverVisible(list.rows[3]) == 0, "flat highlights follow the native engine hover state")
        list.rows[3]:RunScript("OnEnter")
        assert(world.enters == 1 and list.rows[3].Highlight:IsShown(), "native hover behavior still runs")
        assert(FlatHoverVisible(list.rows[3]) == 1, "native hovering shows one flat highlight")
        list.rows[3]:RunScript("OnLeave")
        assert(world.leaves == 1 and not list.rows[3].Highlight:IsShown(), "native leave behavior still runs")
        assert(FlatHoverVisible(list.rows[3]) == 0)
        list.rows[2]:RunScript("OnClick", "LeftButton")
        assert(world.checkedCalls == checkedCalls + 1 and world.nativeClicks == 1 and #world.callbacks == 1)
        assert(Equal(world.callbacks[1], { list.rows[2], "completion", 17, false, "LeftButton" }) and list:IsShown(),
            "native checked callback and keep-open action keep their exact arguments")
        list.rows[4]:RunScript("OnClick", "LeftButton")
        assert(#world.callbacks == 1 and not list.rows[4]:IsEnabled(), "disabled native rows stay disabled")

        list.rows[5].ExpandArrow:RunScript("OnEnter")
        local submenu = world.env[world.prefix .. "2"]
        assert(submenu:IsShown() and submenu.dropdown == rxp.RXPFrame.MenuFrame and submenu:GetPoint(1) == "TOPLEFT",
            "native submenu ownership and positioning remain intact")
        assert(OverlayShown(submenu) >= 5, "submenus opened by native hover receive the same skin")
        submenu.rows[1]:RunScript("OnEnter")
        local leaf = world.env[world.prefix .. "3"]
        assert(OverlayShown(leaf) >= 5 and leaf.rows[1].Icon:GetTexture() == "native-guide-icon", "nested native guides retain their icons")
        leaf.rows[1]:RunScript("OnClick", "RightButton")
        assert(world.callbacks[2][2] == "native-guide" and world.callbacks[2][5] == "RightButton" and not leaf:IsShown(),
            "nested guide actions and native click closing remain intact")
        world:CloseAll()
        assert(not list:IsShown() and not submenu:IsShown() and OverlayShown(list) == 0 and list.dropdown == rxp.RXPFrame.MenuFrame,
            "outside-click closing restores hidden panels even when native owner fields stay stale")

        list = rxp:ShowMenu(menu)
        Styled(addon, list)
        list = world:OpenNative(world.prefix, world.otherOwner, world:Menu(), 1)
        assert(OverlayShown(list) == 0 and list.Backdrop:GetAlpha() > 0 and list.MenuBackdrop:GetAlpha() > 0,
            "a reused shared panel immediately restores for another addon")
        assert(list.rows[2].NormalText:GetFont() == "NativeMenuFont", "font styling never leaks to another addon")
        list = world:OpenNative(world.prefix, world.falsePrefixOwner, world:Menu(), 1)
        assert(OverlayShown(list) == 0, "names resembling RestedXP do not claim another addon's menu")

        local customOwner = world.Frame(nil, world.env.UIParent)
        list = rxp:ShowMenu(menu, customOwner)
        Styled(addon, list)
        assert(list.dropdown == customOwner, "explicit menu owners passed through RestedXP are recognized by identity")
        local activeAppearance = NativeAppearance(list)
        rxp.settings.profile.activeTheme = "RXP Blue"
        addon:RefreshRestedXPMenus(rxp)
        assert(OverlayShown(list) == 0 and list.Backdrop:GetAlpha() > 0, "choosing another native theme restores shared panels")
        rxp.settings.profile.activeTheme = "LockInTools"
        addon:RefreshRestedXPMenus(rxp)
        Styled(addon, list)
        addon.savedDataReadOnly = true
        addon:RefreshRestedXPMenus(rxp)
        assert(OverlayShown(list) == 0, "read-only settings do not activate extra menu styling")
        addon.savedDataReadOnly = nil
        addon:RefreshRestedXPMenus(rxp)
        Styled(addon, list)
        addon.db.restedxpSkin.enabled = false
        addon:RefreshRestedXPMenus(rxp)
        assert(OverlayShown(list) == 0 and NativeAppearance(list).backdrop > 0 and activeAppearance.backdrop == 0,
            "opting out restores native appearance without closing the menu")
        assert(list:IsShown() and #world.callbacks == 2, "appearance transitions never trigger menu actions")
    end
end

for _, bundled in ipairs({ false, true }) do
    local addon, rxp, world = Fixture(bundled, true)
    addon.db.restedxpSkin.enabled = true
    -- The native dropdown pool may not exist when LockInTools initializes.
    for level = 1, 3 do world.env[world.prefix .. level] = nil end
    addon:RefreshRestedXPMenus(rxp)
    local menu = world:Menu()
    local list = rxp:ShowMenu(menu)
    Styled(addon, list)
    assert(world.env[world.prefix .. "2"] == nil, "the skin does not create native submenu panels")
    list.rows[5]:RunScript("OnEnter")
    local submenu = world.env[world.prefix .. "2"]
    assert(OverlayShown(submenu) == 5, "late native submenu creation is discovered after the native toggle")

    world.env.UIDROPDOWNMENU_MAXLEVELS, world.env.L_UIDROPDOWNMENU_MAXLEVELS = 4, 4
    menu[5].menuList[1].menuList[1].hasArrow = true
    menu[5].menuList[1].menuList[1].menuList = { { text = "Late level four", notCheckable = true } }
    submenu.rows[1]:RunScript("OnEnter")
    local third = world.env[world.prefix .. "3"]
    third.rows[1]:RunScript("OnEnter")
    local fourth = world.env[world.prefix .. "4"]
    assert(fourth:IsShown() and OverlayShown(fourth) == 5 and fourth.dropdown == rxp.RXPFrame.MenuFrame,
        "growing native dropdown levels receive styling without rebuilding their hierarchy")

    menu[#menu + 1] = { text = "Late row", notCheckable = true }
    list = rxp:ShowMenu(menu)
    Styled(addon, list)
    local native = Semantics(list)
    local hooks, textures, rowTextures = world.hooks, #list.regions, #list.rows[7].regions
    for _ = 1, 20 do addon:RefreshRestedXPMenus(rxp) end
    assert(world.hooks == hooks and #list.regions == textures and #list.rows[7].regions == rowTextures,
        "repeated menu redraws reuse hooks and visual regions")
    assert(Equal(Semantics(list), native), "late rows retain native fonts, state and geometry")

    list.Backdrop:SetAlpha(0.31)
    list.MenuBackdrop:SetAlpha(0.42)
    list.rxpBackground:SetAlpha(0.53)
    list.rxpBorder:SetAlpha(0.64)
    list.rxpShadow:SetAlpha(0.75)
    for index = 1, list.numButtons do list.rows[index].Highlight:SetAlpha(0.8) end
    list.rows[2].Highlight:SetAlpha(0.46)
    local latest = NativeAppearance(list)
    addon:RefreshRestedXPMenus(rxp)
    Styled(addon, list)
    addon.db.restedxpSkin.enabled = false
    addon:RefreshRestedXPMenus(rxp)
    assert(Equal(NativeAppearance(list), latest), "restoration uses the latest native decoration alpha rather than an earlier pool use")
    assert(OverlayShown(list) == 0 and list:IsShown(), "restoration keeps an already open menu usable")
end

do
    local addon, rxp, world = Fixture(false, false)
    addon.db.restedxpSkin.enabled, world.combat = true, true
    local list = rxp:ShowMenu(world:Menu())
    local native = NativeAppearance(list)
    addon:RefreshRestedXPMenus(rxp)
    assert(#list.regions == 0 and Equal(NativeAppearance(list), native) and addon.restedxpSkinState.pending,
        "combat defers first-time menu texture creation")
    world.combat = false
    addon:RefreshRestedXPMenus(rxp)
    Styled(addon, list)
    world.combat = true
    list.rows[5]:RunScript("OnEnter")
    local submenu = world.env[world.prefix .. "2"]
    assert(submenu:IsShown() and #submenu.regions == 0, "late submenu controls keep working natively while combat defers their art")
    addon.db.restedxpSkin.enabled = false
    addon:RefreshRestedXPMenus(rxp)
    assert(Equal(NativeAppearance(list), native) and OverlayShown(list) == 0,
        "existing ordinary menu decorations restore safely during combat")
    world.combat = false
    addon.db.restedxpSkin.enabled = true
    addon:RefreshRestedXPMenus(rxp)
    assert(OverlayShown(submenu) == 5, "the native submenu gains its skin after combat")
end

for _, bundled in ipairs({ false, true }) do
    local addon, rxp, world = Fixture(bundled, true)
    addon.db.restedxpSkin.hideChrome = true
    local guide = world:Menu()[5]
    local chooser = { guide, { text = "", isTitle = true, notCheckable = true },
        { text = "Close", notCheckable = true, func = function(button) button.parent:Hide() end } }
    addon:RefreshRestedXPMenus(rxp)
    local list = rxp:ShowMenu(chooser)
    Styled(addon, list)
    assert(not addon:IsRestedXPSkinEnabled(), "hidden chrome can use a manually selected LockInTools theme independently")
    local native = Semantics(list)
    addon:RefreshRestedXPMenus(rxp)
    assert(Equal(Semantics(list), native) and #world.callbacks == 0,
        "the hidden-header chooser is skinned without changing guide hierarchy, native actions or selection")
    list.rows[1].ExpandArrow:RunScript("OnEnter")
    local submenu = world.env[world.prefix .. "2"]
    assert(OverlayShown(submenu) == 5, "guide submenus share the hidden-header chooser appearance")
    list = world:OpenNative(world.prefix, world.otherOwner, chooser, 1)
    assert(OverlayShown(list) == 0 and list.Backdrop:GetAlpha() > 0, "hidden-header menu styling remains scoped to exact RXP owners")
    list = rxp:ShowMenu(chooser)
    Styled(addon, list)
    addon.db.restedxpSkin.hideChrome = false
    addon:RefreshRestedXPMenus(rxp)
    assert(OverlayShown(list) == 0 and list:IsShown(), "showing the header releases chooser styling when the main skin is off")
    addon.db.restedxpSkin.hideChrome = true
    addon:RefreshRestedXPMenus(rxp)
    Styled(addon, list)
    rxp.settings.profile.activeTheme = "RXP Blue"
    addon:RefreshRestedXPMenus(rxp)
    assert(OverlayShown(list) == 0, "a different native theme releases hidden-header chooser styling")
    rxp.settings.profile.activeTheme = "LockInTools"
    addon:RefreshRestedXPMenus(rxp)
    Styled(addon, list)
    addon.savedDataReadOnly = true
    addon:RefreshRestedXPMenus(rxp)
    assert(OverlayShown(list) == 0, "read-only preferences release hidden-header chooser styling")
end

print("PASS: RestedXP shared menu ownership, native interactions and restoration")
