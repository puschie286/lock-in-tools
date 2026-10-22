-- Native CheckButtons retain click/state ownership; the skin only draws an overlay.
local function CopyPoints(value)
    local result = {}
    for index, point in ipairs(value) do
        result[index] = {}
        for coordinate, child in pairs(point) do result[index][coordinate] = child end
    end
    return result
end

local function Equal(left, right)
    if left == right then return true end
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do if not Equal(value, right[key]) then return false end end
    for key in pairs(right) do if left[key] == nil then return false end end
    return true
end

local function Fixture(v2Enabled)
    local world = { combat = false, mutations = 0, geometry = 0, hooks = 0, createdFrames = 0,
        checkedWrites = 0, enabledWrites = 0, clicks = 0, enters = 0, leaves = 0, buttons = {}, nativeAlpha = 0.8 }
    local function Changed() world.mutations = world.mutations + 1 end
    local Frame, Region
    local function Alpha(object)
        local alpha = object.alpha or 1
        if object.parent then alpha = alpha * Alpha(object.parent) end
        return alpha
    end
    local function Visible(object)
        if not object.shown then return false end
        if object.parent and not Visible(object.parent) then return false end
        local owner = object.owner
        if object.role == "checked" and (not owner.checked or not owner.enabled) then return false end
        if object.role == "disabledChecked" and (not owner.checked or owner.enabled) then return false end
        if object.role == "disabled" and owner.enabled then return false end
        if object.role == "highlight" and not owner.hovered then return false end
        if object.role == "pushed" and not owner.pushed then return false end
        return true
    end
    Region = function(parent, texture, role)
        local region = { parent = parent, owner = parent, texture = texture, role = role, shown = true,
            alpha = world.nativeAlpha, color = { 0.7, 0.6, 0.5, 1 }, points = {}, width = 12, height = 12,
            coordinates = { 0.1, 0.9, 0.2, 0.8 }, rotation = 0, desaturated = false }
        function region:GetObjectType() return "Texture" end
        function region:GetTexture() return self.texture end
        function region:SetTexture(value) self.texture = value; Changed() end
        function region:GetAlpha() return self.alpha end
        function region:SetAlpha(value) self.alpha = value; Changed() end
        function region:GetVertexColor() return unpack(self.color) end
        function region:SetVertexColor(...) self.color = { ... }; Changed() end
        function region:SetColorTexture(...) self.texture, self.color = "solid", { ... }; Changed() end
        function region:GetTexCoord() return unpack(self.coordinates) end
        function region:SetTexCoord(...) self.coordinates = { ... }; Changed() end
        function region:IsShown() return self.shown end
        function region:IsVisible() return Visible(self) end
        function region:Show() self.shown = true; Changed() end
        function region:Hide() self.shown = false; Changed() end
        function region:SetShown(value) self.shown = value == true; Changed() end
        function region:GetWidth() return self.width end
        function region:GetHeight() return self.height end
        function region:SetWidth(value) self.width = value; Changed(); world.geometry = world.geometry + 1 end
        function region:SetHeight(value) self.height = value; Changed(); world.geometry = world.geometry + 1 end
        function region:SetSize(width, height) self.width, self.height = width, height; Changed(); world.geometry = world.geometry + 1 end
        function region:ClearAllPoints() self.points = {}; Changed(); world.geometry = world.geometry + 1 end
        function region:SetPoint(...) self.points[#self.points + 1] = { ... }; Changed(); world.geometry = world.geometry + 1 end
        function region:SetAllPoints(frame) self.points = { { "ALL", frame or self.parent } }; Changed(); world.geometry = world.geometry + 1 end
        function region:SetRotation(value) self.rotation = value; Changed(); world.geometry = world.geometry + 1 end
        function region:SetBlendMode(value) self.blend = value; Changed() end
        function region:SetDrawLayer(layer, sublevel) self.layer, self.sublevel = layer, sublevel; Changed() end
        function region:IsDesaturated() return self.desaturated end
        function region:SetDesaturated(value) self.desaturated = value; Changed() end
        parent.regions[#parent.regions + 1] = region
        return region
    end
    Frame = function(kind, parent)
        local frame = { kind = kind or "Frame", parent = parent, children = {}, regions = {}, shown = true,
            alpha = 1, mouse = true, width = 12, height = 12, points = {}, scripts = {}, scriptHooks = {}, level = 3 }
        if parent then parent.children[#parent.children + 1] = frame end
        function frame:GetObjectType() return self.kind end
        function frame:IsForbidden() return false end
        function frame:GetParent() return self.parent end
        function frame:GetAlpha() return self.alpha end
        function frame:SetAlpha(value) self.alpha = value; Changed() end
        function frame:IsShown() return self.shown end
        function frame:IsVisible() return Visible(self) end
        function frame:Show() self.shown = true; Changed() end
        function frame:Hide() self.shown = false; Changed() end
        function frame:SetShown(value) self.shown = value == true; Changed() end
        function frame:EnableMouse(value) self.mouse = value; Changed() end
        function frame:IsMouseEnabled() return self.mouse end
        function frame:GetFrameLevel() return self.level end
        function frame:SetFrameLevel(value) self.level = value; Changed() end
        function frame:GetWidth() return self.width end
        function frame:GetHeight() return self.height end
        function frame:SetSize(width, height) self.width, self.height = width, height; Changed(); world.geometry = world.geometry + 1 end
        function frame:SetWidth(value) self.width = value; Changed(); world.geometry = world.geometry + 1 end
        function frame:SetHeight(value) self.height = value; Changed(); world.geometry = world.geometry + 1 end
        function frame:ClearAllPoints() self.points = {}; Changed(); world.geometry = world.geometry + 1 end
        function frame:SetPoint(...) self.points[#self.points + 1] = { ... }; Changed(); world.geometry = world.geometry + 1 end
        function frame:SetAllPoints(other) self.points = { { "ALL", other or self.parent } }; Changed(); world.geometry = world.geometry + 1 end
        function frame:GetNumPoints() return #self.points end
        function frame:GetPoint(index) return unpack(self.points[index], 1, 5) end
        function frame:CreateTexture() return Region(self, nil) end
        function frame:GetRegions() return unpack(self.regions) end
        function frame:GetScript(name) return self.scripts[name] end
        function frame:SetScript(name, callback) self.scripts[name] = callback; Changed() end
        function frame:HookScript(name, callback)
            self.scriptHooks[name] = self.scriptHooks[name] or {}
            self.scriptHooks[name][#self.scriptHooks[name] + 1] = callback
        end
        function frame:RunScript(name, ...)
            if self.scripts[name] then self.scripts[name](self, ...) end
            for _, callback in ipairs(self.scriptHooks[name] or {}) do callback(self, ...) end
        end
        return frame
    end
    local rxp = { settings = { profile = { activeTheme = "LockInTools" } }, RXPFrame = { CurrentStepFrame = { framePool = {} } },
        v2 = { state = { player = {} }, enabled = v2Enabled } }
    function rxp.v2:IsGuideWindowEnabled() return self.enabled end
    local item = { elementRows = {} }
    world.item = item
    rxp.v2.state.player.Self = { activeStepItems = { item } }
    local function NativeV2(button)
        if not button.rxpBackground then return end
        local hovered, checked = button.rxpHovered == true, button:GetChecked()
        button.rxpBackground:SetShown(not hovered)
        button.rxpBorder:SetShown(not hovered)
        button.rxpCheckShort:SetShown(checked and not hovered)
        button.rxpCheckLong:SetShown(checked and not hovered)
        button.rxpHoverFrame:SetShown(hovered)
    end
    local function NewRow()
        local row = Frame()
        row.element = { completed = false, skip = false }
        row.text = Region(row, "native-text")
        local button = Frame("CheckButton", row)
        button.checked, button.enabled = false, true
        button:SetPoint("TOPLEFT", row, "TOPLEFT", 2, -2)
        row.button = button
        function button:GetChecked() return self.checked end
        function button:SetChecked(value) self.checked = not not value; world.checkedWrites = world.checkedWrites + 1 end
        function button:IsEnabled() return self.enabled end
        function button:Enable() self.enabled = true; world.enabledWrites = world.enabledWrites + 1 end
        function button:Disable() self.enabled = false; world.enabledWrites = world.enabledWrites + 1 end
        function button:SetEnabled(value) self.enabled = value == true; world.enabledWrites = world.enabledWrites + 1 end
        for _, entry in ipairs({ { "Normal", "normal" }, { "Pushed", "pushed" }, { "Highlight", "highlight" },
            { "Disabled", "disabled" }, { "Checked", "checked" }, { "DisabledChecked", "disabledChecked" } }) do
            local name, role = entry[1], entry[2]
            local region = not v2Enabled and Region(button, "native-" .. name, role) or nil
            button["Get" .. name .. "Texture"] = function() return region end
        end
        if v2Enabled then
            button.rxpBackground, button.rxpBorder = Frame("Frame", button), Frame("Frame", button)
            button.rxpBackground.textures = { Region(button.rxpBackground, "native-v2-fill") }
            button.rxpBorder.textures = { Region(button.rxpBorder, "native-v2-edge") }
            button.rxpCheckShort, button.rxpCheckLong = Region(button, "native-check-short"), Region(button, "native-check-long")
            button.rxpHoverFrame = Frame("Frame", button)
            button.rxpHoverFrame:EnableMouse(false)
            button.rxpHoverFrame.skipIcon = Region(button.rxpHoverFrame, "native-skip-hover")
            NativeV2(button)
        end
        button:SetScript("PostClick", function(self)
            world.clicks = world.clicks + 1
            row.element.skip = self:GetChecked()
        end)
        if v2Enabled then button:HookScript("PostClick", NativeV2) end
        button:SetScript("OnEnter", function(self)
            world.enters, self.hovered = world.enters + 1, true
            if v2Enabled then self.rxpHovered = true; NativeV2(self) end
        end)
        button:SetScript("OnLeave", function(self)
            world.leaves, self.hovered = world.leaves + 1, false
            if v2Enabled then self.rxpHovered = nil; NativeV2(self) end
        end)
        function button:Click()
            if not self.enabled then return end
            self.checked = not self.checked
            self:RunScript("PostClick", "LeftButton")
        end
        button.nativeHandlers = { button:GetScript("PostClick"), button:GetScript("OnEnter"), button:GetScript("OnLeave") }
        if v2Enabled then
            item.elementRows[#item.elementRows + 1] = row
        else
            local pool = rxp.RXPFrame.CurrentStepFrame.framePool
            if not pool[1] then pool[1] = { elements = {} } end
            pool[1].elements[#pool[1].elements + 1] = row
        end
        world.buttons[#world.buttons + 1] = button
        return row, button
    end
    function world:NewRow() return NewRow() end
    function rxp:LoadActiveTheme() end
    function rxp.SetStep() end
    function rxp.RenderFrame()
        for _, button in ipairs(world.buttons) do
            for _, role in ipairs({ "Normal", "Pushed", "Highlight", "Disabled", "Checked", "DisabledChecked" }) do
                local region = button["Get" .. role .. "Texture"](button)
                if region then region:SetAlpha(world.nativeAlpha) end
            end
            NativeV2(button)
        end
    end
    function rxp.v2:ReconcileActiveStepItems() end
    function rxp.v2:UpdateActiveStepTheme() item:UpdateTheme() end
    function item:UpdateSubTheme() for _, row in ipairs(self.elementRows) do NativeV2(row.button) end end
    function item:UpdateTheme() self:UpdateSubTheme() end
    function item:SetElements() end
    local addon = { db = { restedxpSkin = { enabled = false } }, restedxpSkinState = {} }
    local env = setmetatable({ InCombatLockdown = function() return world.combat end,
        CreateFrame = function(kind, _, parent)
            world.createdFrames = world.createdFrames + 1
            return Frame(kind, parent)
        end,
    }, { __index = _G })
    function env.hooksecurefunc(owner, method, callback)
        world.hooks = world.hooks + 1
        local original = assert(owner[method])
        owner[method] = function(...)
            local result = { original(...) }
            callback(...)
            return unpack(result)
        end
    end
    setfenv(assert(loadfile("Theme.lua")), env)("LockInTools", addon)
    setfenv(assert(loadfile("RestedXPSkin.lua")), env)("LockInTools", addon)
    function world:Visual(button)
        local parts = {}
        local function Draw(frame)
            if not Visible(frame) or Alpha(frame) == 0 then return end
            for _, region in ipairs(frame.regions) do
                if Visible(region) and Alpha(region) > 0 and region.texture and (region.color[4] or 1) > 0 then
                    parts[#parts + 1] = tostring(region.texture) .. ":" .. table.concat(region.color, ",")
                        .. ":" .. Alpha(region) .. ":" .. region.rotation
                end
            end
            for _, child in ipairs(frame.children) do Draw(child) end
        end
        Draw(button)
        table.sort(parts)
        return table.concat(parts, "|")
    end
    return addon, rxp, world, NewRow
end

local function NativeUnchanged(button, saved)
    assert(button:GetScript("PostClick") == button.nativeHandlers[1]
        and button:GetScript("OnEnter") == button.nativeHandlers[2]
        and button:GetScript("OnLeave") == button.nativeHandlers[3], "native click and tooltip handlers remain installed")
    assert(button:GetParent() == saved.parent and button:GetWidth() == saved.width and button:GetHeight() == saved.height
        and Equal(button.points, saved.points) and button:IsMouseEnabled() == saved.mouse,
        "modern visuals preserve the native hit area and input geometry")
end

for _, v2 in ipairs({ false, true }) do
    local addon, rxp, world, NewRow = Fixture(v2)
    local row, button = NewRow()
    local saved = { parent = button:GetParent(), width = button:GetWidth(), height = button:GetHeight(),
        points = CopyPoints(button.points), mouse = button:IsMouseEnabled() }
    local native = world:Visual(button)
    local mutations, frames = world.mutations, world.createdFrames
    addon:RefreshRestedXPCheckboxes(rxp)
    assert(world.mutations == mutations and world.createdFrames == frames, "the optional skin leaves native checkboxes untouched by default")
    addon.db.restedxpSkin.enabled = true
    local checkedWrites, enabledWrites = world.checkedWrites, world.enabledWrites
    addon:RefreshRestedXPCheckboxes(rxp)
    assert(world:Visual(button) ~= native and world.createdFrames > frames, "the enabled skin supplies modern checkbox artwork")
    assert(world.checkedWrites == checkedWrites and world.enabledWrites == enabledWrites and not button:GetChecked()
        and button:IsEnabled() and not row.element.skip and not row.element.completed, "restyling does not change guide completion or native button state")
    NativeUnchanged(button, saved)
    for _, child in ipairs(button.children) do
        if child ~= button.rxpBackground and child ~= button.rxpBorder and child ~= button.rxpHoverFrame then
            assert(not child:IsMouseEnabled(), "the added artwork never intercepts native clicks")
        end
    end
    local unchecked = world:Visual(button)
    button:Click()
    assert(world.clicks == 1 and button:GetChecked() and row.element.skip, "native PostClick still controls manual skipping exactly once")
    local skipped = world:Visual(button)
    assert(skipped ~= unchecked, "checked and unchecked states remain visually distinct")
    row.element.skip, row.element.completed = false, true
    button:Disable()
    local automatic = world:Visual(button)
    assert(automatic ~= skipped, "automatic disabled completion remains distinguishable from manual skipping")
    button:Click()
    assert(world.clicks == 1 and button:GetChecked(), "disabled native checkboxes cannot trigger completion callbacks")
    button:SetChecked(false)
    local disabled = world:Visual(button)
    assert(disabled ~= automatic and disabled ~= unchecked, "unchecked disabled controls remain distinct from automatic completion and active controls")
    button:Enable()
    button:SetEnabled(false)
    assert(world:Visual(button) == disabled, "native SetEnabled changes also repaint the existing control")
    button:SetEnabled(true)
    row.element.completed = false
    button:RunScript("OnEnter")
    assert(world.enters == 1 and world:Visual(button) ~= unchecked, "native hover feedback remains visible")
    if v2 then assert(button.rxpHoverFrame:IsShown() and button.rxpHoverFrame.skipIcon:IsVisible(), "the native V2 skip preview remains intact") end
    button:RunScript("OnLeave")
    assert(world.leaves == 1 and world:Visual(button) == unchecked, "leaving hover restores the unchecked visual")
    local created = world.createdFrames
    rxp.RenderFrame()
    addon:RefreshRestedXPCheckboxes(rxp)
    assert(world.createdFrames == created and world:Visual(button) == unchecked, "native redraws reuse the same modern artwork")
    local _, late = NewRow()
    if v2 then rxp.v2:ReconcileActiveStepItems() else rxp.SetStep() end
    assert(world.createdFrames > created and world:Visual(late) == unchecked, "new native rows acquire the same checkbox style")
    if v2 then
        local _, localLate = NewRow()
        world.item:SetElements()
        assert(world:Visual(localLate) == unchecked, "local V2 row refreshes style new controls without a full guide rebuild")
    end
    addon.db.restedxpSkin.enabled = false
    addon:RefreshRestedXPCheckboxes(rxp)
    assert(world:Visual(button) == native, "opting out restores native checkbox artwork")
    NativeUnchanged(button, saved)
    addon.db.restedxpSkin.enabled = true
    addon:RefreshRestedXPCheckboxes(rxp)
    rxp.settings.profile.activeTheme = "Custom"
    rxp:LoadActiveTheme()
    assert(world:Visual(button) == native, "choosing another native theme restores native checkbox visuals")
end

do
    local addon, rxp, world, NewRow = Fixture(true)
    local _, button = NewRow()
    addon.db.restedxpSkin.enabled, addon.savedDataReadOnly = true, true
    local native, mutations = world:Visual(button), world.mutations
    addon:RefreshRestedXPCheckboxes(rxp)
    assert(world.mutations == mutations and world.createdFrames == 0 and world:Visual(button) == native,
        "newer-schema read-only settings cannot activate checkbox styling")
end

do
    local addon, rxp, world, NewRow = Fixture(false)
    local _, button = NewRow()
    addon.db.restedxpSkin.enabled = true
    addon:RefreshRestedXPCheckboxes(rxp)
    world.nativeAlpha = 0.55
    rxp.RenderFrame()
    assert(button:GetNormalTexture():GetAlpha() == 0)
    addon.db.restedxpSkin.enabled = false
    addon:RefreshRestedXPCheckboxes(rxp)
    assert(button:GetNormalTexture():GetAlpha() == world.nativeAlpha,
        "restoration respects a native texture alpha changed during a redraw")
end

for _, v2 in ipairs({ false, true }) do
    local addon, rxp, world, NewRow = Fixture(v2)
    local _, button = NewRow()
    addon.db.restedxpSkin.enabled = true
    world.combat = true
    local native, frames, geometry = world:Visual(button), world.createdFrames, world.geometry
    addon:RefreshRestedXPCheckboxes(rxp)
    assert(world:Visual(button) == native and world.createdFrames == frames and world.geometry == geometry
        and addon.restedxpSkinState.pending, "combat defers creating or activating checkbox artwork")
    world.combat = false
    addon:RefreshRestedXPCheckboxes(rxp)
    local unchecked = world:Visual(button)
    world.combat = true
    frames, geometry = world.createdFrames, world.geometry
    button:SetChecked(true)
    assert(world:Visual(button) ~= unchecked and world.createdFrames == frames and world.geometry == geometry,
        "existing artwork reflects native checked changes during combat without layout changes")
    local _, late = NewRow()
    local lateNative = world:Visual(late)
    frames, geometry = world.createdFrames, world.geometry
    if v2 then rxp.v2:ReconcileActiveStepItems() else rxp.SetStep() end
    assert(world:Visual(late) == lateNative and world.createdFrames == frames and world.geometry == geometry,
        "new controls created by RestedXP in combat remain native until combat ends")
    world.combat = false
    addon:RefreshRestedXPCheckboxes(rxp)
    assert(world:Visual(late) ~= lateNative, "new controls receive their modern artwork after combat")
    world.combat = true
    addon.db.restedxpSkin.enabled = false
    addon:RefreshRestedXPCheckboxes(rxp)
    assert(world:Visual(button) ~= native and addon.restedxpSkinState.pending, "combat defers restoration of active artwork")
    world.combat = false
    button:SetChecked(false)
    addon:RefreshRestedXPCheckboxes(rxp)
    assert(world:Visual(button) == native, "restoration completes after combat")
end

print("PASS: modern RestedXP checkboxes preserve native state, callbacks, redraws and combat behavior")
