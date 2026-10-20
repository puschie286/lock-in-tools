-- Exercise the real options callbacks against strict native-widget stubs.
local function loadOptions(uiAddon, uiEnvironment)
    local createEventFrame = uiEnvironment.CreateFrame
    uiEnvironment.namedFrameCreations = {}
    local methods = {}
    local function makeWidget()
        return setmetatable({ scripts = {}, handlers = {}, hooks = {}, enabled = true, shown = true,
            visible = true, children = {} }, { __index = methods })
    end
    local function updateScript(widget, script)
        if not widget.handlers[script] and not widget.hooks[script] then
            widget.scripts[script] = nil
            return
        end
        widget.scripts[script] = function(...)
            if widget.handlers[script] then widget.handlers[script](...) end
            for _, callback in ipairs(widget.hooks[script] or {}) do callback(...) end
        end
    end
    for _, name in ipairs({ "SetFrameStrata", "SetClampedToScreen",
        "SetMovable", "EnableMouse", "RegisterForDrag",
        "SetJustifyH", "SetAutoFocus", "SetTextInsets", "SetMotionScriptsWhileDisabled", "Raise" }) do
        methods[name] = function() end
    end
    function methods:SetPoint(...) self.point = { ... } end
    function methods:GetPoint()
        local point = self.point
        if not point then return end
        if type(point[2]) == "number" then
            return point[1], self.parent, point[1], point[2], point[3] or 0
        end
        return point[1], point[2] or self.parent, point[3] or point[1], point[4] or 0, point[5] or 0
    end
    function methods:ClearAllPoints() self.point = nil end
    function methods:SetUserPlaced(placed) self.userPlaced = placed end
    function methods:StartMoving() self.moving, self.userPlaced = true, true end
    function methods:StopMovingOrSizing() self.moving = false end
    function methods:SetSize(width, height) self.width, self.height = width, height end
    function methods:SetAllPoints(widget) self.allPoints = widget or self.parent end
    function methods:SetWidth(width) self.width = width end
    function methods:SetHeight(height) self.height = height end
    function methods:SetMultiLine(multiline) self.multiline = multiline end
    function methods:SetMaxLetters(maximum) self.maxLetters = maximum end
    function methods:GetNumLines()
        local lines = 0
        for line in (self:GetText() .. "\n"):gmatch("([^\n]*)\n") do
            lines = lines + math.max(1, math.ceil(#line / math.max(1, math.floor(self:GetWidth() / 8))))
        end
        return lines
    end
    function methods:SetScrollChild(child) self.scrollChild = child end
    function methods:UpdateScrollChildRect() self.scrollRectUpdates = (self.scrollRectUpdates or 0) + 1 end
    function methods:SetVerticalScroll(value) self.verticalScroll = value end
    function methods:GetVerticalScroll() return self.verticalScroll or 0 end
    function methods:GetWidth() return self.width or (self.allPoints and self.allPoints:GetWidth()) or 0 end
    function methods:GetHeight() return self.height or (self.allPoints and self.allPoints:GetHeight()) or 0 end
    function methods:SetColorTexture(...)
        self.textureColor = { ... }
        if self.parent then self.parent.texturePaints = (self.parent.texturePaints or 0) + 1 end
    end
    function methods:SetVertexColor(...) self.vertexColor = { ... } end
    function methods:SetTexture(texture) self.texture = texture end
    function methods:SetParent(parent)
        if self.parent then
            for index, child in ipairs(self.parent.children) do
                if child == self then table.remove(self.parent.children, index); break end
            end
        end
        self.parent = parent
        if parent then parent.children[#parent.children + 1] = self end
        self.visible = self:IsVisible()
    end
    function methods:SetScale(scale) self.scale = scale end
    function methods:GetFrameLevel() return self.frameLevel or 0 end
    function methods:SetFrameLevel(level) self.frameLevel = level end
    function methods:EnableMouseWheel(enabled) self.mouseWheel = enabled end
    function methods:SetOrientation(orientation) self.orientation = orientation end
    function methods:SetMinMaxValues(minimum, maximum)
        self.minimum, self.maximum = minimum, maximum
    end
    function methods:GetMinMaxValues() return self.minimum, self.maximum end
    function methods:SetValue(value)
        value = math.max(self.minimum or value, math.min(self.maximum or value, value))
        local changed = self.value ~= value
        self.value = value
        if changed and self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, value) end
    end
    function methods:GetValue() return self.value or 0 end
    function methods:SetValueStep(step) self.valueStep = step end
    function methods:SetThumbTexture(texture)
        if type(texture) ~= "table" then
            local path = texture
            texture = makeWidget()
            texture:SetTexture(path)
        end
        self.thumbTexture = texture
    end
    function methods:GetThumbTexture() return self.thumbTexture end
    function methods:SetFont(path, size, flags) self.font = { path, size, flags }; return true end
    function methods:GetFont() return unpack(self.font or { "Fonts\\FRIZQT__.TTF", 12, "" }) end
    function methods:SetFontObject(fontObject) self.fontObject = fontObject end
    function methods:SetAlpha(alpha) self.alpha = alpha end
    function methods:SetText(text)
        if self.maxLetters then text = text:sub(1, self.maxLetters) end
        self.text = text
        if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self, false) end
    end
    function methods:GetText() return self.text or "" end
    function methods:SetTextColor(red, green, blue) self.color = { red, green, blue } end
    function methods:SetEnabled(enabled)
        local changed = self.enabled ~= enabled
        self.enabled = enabled
        local callback = self.scripts[enabled and "OnEnable" or "OnDisable"]
        if changed and callback and (self.frameType == "Button" or self.frameType == "CheckButton") then
            callback(self)
        end
    end
    function methods:IsEnabled() return self.enabled end
    function methods:SetChecked(checked) self.checked = checked end
    function methods:GetChecked() return self.checked end
    function methods:ClearFocus()
        local wasFocused = self.focused
        self.focusCleared, self.focused = true, false
        if wasFocused and self.scripts.OnEditFocusLost then self.scripts.OnEditFocusLost(self) end
    end
    function methods:SetFocus()
        local wasFocused = self.focused
        self.focused, self.focusCleared = true, false
        if not wasFocused and self.scripts.OnEditFocusGained then self.scripts.OnEditFocusGained(self) end
    end
    function methods:HighlightText() self.highlighted = true end
    function methods:SetFontString(fontString) self.fontString = fontString end
    function methods:GetFontString() return self.fontString end
    function methods:SetCheckedTexture(texture)
        if type(texture) ~= "table" then
            local path = texture
            texture = makeWidget()
            texture:SetTexture(path)
        end
        self.checkedTexture = texture
    end
    function methods:GetCheckedTexture() return self.checkedTexture end
    function methods:SetDisabledCheckedTexture(texture) self.disabledCheckedTexture = texture end
    local function checkScript(widget, script)
        assert(widget.frameType ~= "EditBox" or (script ~= "OnEnable" and script ~= "OnDisable"),
            "native EditBoxes do not support button enable/disable scripts")
    end
    function methods:SetScript(script, callback)
        checkScript(self, script)
        self.handlers[script] = callback
        updateScript(self, script)
    end
    function methods:GetScript(script) return self.handlers[script] end
    function methods:HookScript(script, callback)
        checkScript(self, script)
        self.hooks[script] = self.hooks[script] or {}
        table.insert(self.hooks[script], callback)
        updateScript(self, script)
    end
    function methods:CreateFontString()
        local fontString = makeWidget()
        fontString.parent = self
        return fontString
    end
    function methods:CreateTexture()
        local texture = makeWidget()
        texture.parent = self
        return texture
    end
    function methods:IsShown() return self.shown end
    function methods:IsVisible()
        return self.shown and (not self.parent or not self.parent.IsVisible or self.parent:IsVisible())
    end
    local function updateVisibility(widget)
        local visible = widget:IsVisible()
        if widget.visible ~= visible then
            widget.visible = visible
            local callback = widget.scripts[visible and "OnShow" or "OnHide"]
            if callback then callback(widget) end
        end
        for _, child in ipairs(widget.children) do updateVisibility(child) end
    end
    function methods:Hide()
        self.shown = false
        updateVisibility(self)
    end
    function methods:Show()
        self.shown = true
        updateVisibility(self)
    end
    function methods:Click()
        if not self.enabled then return end
        if self.frameType == "CheckButton" then self:SetChecked(not self:GetChecked()) end
        if self.scripts.OnClick then self.scripts.OnClick(self) end
    end
    function methods:UserInput(text)
        assert(self.enabled, "disabled fields do not accept user input")
        assert(self:IsVisible(), "hidden fields do not accept user input")
        self.text = self.maxLetters and text:sub(1, self.maxLetters) or text
        if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self, true) end
    end
    uiEnvironment.CreateFrame = function(frameType, name, parent, template)
        if frameType == "Button" and name == "LibDBIcon10_LockInTools" then
            return createEventFrame(frameType, name, parent, template)
        end
        if frameType == "Frame" and not name and not template and not parent then
            return createEventFrame(frameType)
        end
        assert(frameType == "Frame" or frameType == "EditBox"
            or frameType == "CheckButton" or frameType == "Button" or frameType == "Slider"
            or frameType == "ScrollFrame", "use supported native widgets")
        local widget = makeWidget()
        widget.frameType, widget.name, widget.template = frameType, name, template
        widget:SetParent(parent)
        if template == "BasicFrameTemplateWithInset" then widget.TitleText = makeWidget() end
        if name then
            uiEnvironment[name] = widget
            uiEnvironment.namedFrameCreations[name] = (uiEnvironment.namedFrameCreations[name] or 0) + 1
        end
        return widget
    end
    uiEnvironment.UIParent, uiEnvironment.UISpecialFrames = makeWidget(), {}
    uiEnvironment._G = uiEnvironment
    uiEnvironment.tinsert = table.insert
    uiEnvironment.hooksecurefunc = function(object, methodName, callback)
        assert(type(object) == "table" and type(methodName) == "string" and type(callback) == "function",
            "this harness supports named object method hooks")
        local original = assert(object[methodName], "hooked methods must exist")
        local function capture(...) return { n = select("#", ...), ... } end
        object[methodName] = function(...)
            local result = capture(original(...))
            callback(...)
            return unpack(result, 1, result.n)
        end
    end
    for _, file in ipairs({ "Theme.lua", "Overview.lua", "Options.lua" }) do
        local chunk, problem
        if setfenv then
            chunk, problem = loadfile(file)
            assert(chunk, problem)
            setfenv(chunk, uiEnvironment)
        else
            chunk, problem = loadfile(file, "t", uiEnvironment)
            assert(chunk, problem)
        end
        chunk("LockInTools", uiAddon)
    end
end

-- Native surfaces used by the real LibDBIcon, without replacing its behavior.
local function prepareMinimap(environment, world)
    local createEventFrame = environment.CreateFrame
    local methods = {}
    local function widget(parent)
        return setmetatable({ parent = parent, scripts = {}, hooks = {}, shown = true,
            textures = {}, alpha = 1 }, { __index = methods })
    end
    local function fire(self, script, ...)
        if self.scripts[script] then self.scripts[script](self, ...) end
        for _, callback in ipairs(self.hooks[script] or {}) do callback(self, ...) end
    end
    function methods:GetParent() return self.parent end
    function methods:GetName() return self.name end
    function methods:SetSize(width, height) self.width, self.height = width, height end
    function methods:GetWidth() return self.width or 0 end
    function methods:GetHeight() return self.height or 0 end
    function methods:SetPoint(...) self.point = { ... } end
    function methods:ClearAllPoints() self.point = nil end
    function methods:SetAllPoints() self.allPoints = true end
    function methods:GetCenter()
        local x, y = self.parent:GetCenter()
        return x + (self.point and self.point[4] or 0), y + (self.point and self.point[5] or 0)
    end
    function methods:SetFrameStrata(strata) self.strata = strata end
    function methods:SetFrameLevel(level) self.level = level end
    function methods:SetFixedFrameStrata(fixed) self.fixedStrata = fixed end
    function methods:SetFixedFrameLevel(fixed) self.fixedLevel = fixed end
    function methods:RegisterForClicks(...) self.clicks = { ... } end
    function methods:RegisterForDrag(...) self.drags = { ... } end
    function methods:SetHighlightTexture(texture) self.highlight = texture end
    function methods:LockHighlight() self.highlightLocked = true end
    function methods:UnlockHighlight() self.highlightLocked = false end
    function methods:SetAlpha(alpha) self.alpha = alpha end
    function methods:GetAlpha() return self.alpha end
    function methods:SetScript(script, callback) self.scripts[script] = callback end
    function methods:GetScript(script) return self.scripts[script] end
    function methods:HookScript(script, callback)
        self.hooks[script] = self.hooks[script] or {}
        self.hooks[script][#self.hooks[script] + 1] = callback
    end
    function methods:Click(button) fire(self, "OnClick", button) end
    function methods:Show()
        local changed = not self.shown
        self.shown = true
        if changed then fire(self, "OnShow") end
    end
    function methods:Hide()
        local changed = self.shown
        self.shown = false
        if changed then fire(self, "OnHide") end
    end
    function methods:IsShown() return self.shown end
    function methods:SetTexture(path) self.path = path end
    function methods:SetTexCoord(...) self.texCoord = { ... } end
    function methods:SetVertexColor(...) self.vertexColor = { ... } end
    function methods:GetVertexColor() return unpack(self.vertexColor or { 1, 1, 1, 1 }) end
    function methods:CreateTexture()
        local texture = widget(self)
        self.textures[#self.textures + 1] = texture
        return texture
    end
    function methods:CreateAnimationGroup()
        local group = { animations = {}, playing = false }
        function group:CreateAnimation(kind)
            assert(kind == "Alpha", "DBIcon uses a native alpha animation")
            local animation = {}
            for _, name in ipairs({ "Order", "Duration", "FromAlpha", "ToAlpha", "StartDelay" }) do
                animation["Set" .. name] = function(self, value) self[name] = value end
            end
            self.animations[#self.animations + 1] = animation
            return animation
        end
        function group:SetToFinalAlpha(final) self.toFinalAlpha = final end
        function group:Play() self.playing = true end
        function group:Stop() self.playing = false end
        return group
    end
    function methods:SetOwner(owner, anchor) self.owner, self.anchor = owner, anchor end
    function methods:IsOwned(owner) return self.owner == owner end
    function methods:SetText(text) self.text, self.lines = text, {} end
    function methods:AddLine(text) self.lines[#self.lines + 1] = text end
    environment.UIParent = widget()
    environment.UIParent:SetSize(1920, 1080)
    environment.WOW_PROJECT_ID, environment.WOW_PROJECT_MAINLINE = 1, 1
    local minimap = environment.Minimap
    minimap.hooksByScript = {}
    function minimap:HookScript(script, callback)
        local handlers = self.hooksByScript[script] or {}
        self.hooksByScript[script] = handlers
        handlers[#handlers + 1] = callback
        self.hooks[#self.hooks + 1] = callback
    end
    function minimap:SetSize(width, height)
        self.width, self.height = width, height
        for _, callback in ipairs(self.hooksByScript.OnSizeChanged or {}) do callback(self, width, height) end
    end
    environment.CreateFrame = function(frameType, name, parent, template)
        if frameType ~= "Button" and frameType ~= "GameTooltip" then
            return createEventFrame(frameType, name, parent, template)
        end
        local result = widget(parent)
        result.name, result.frameType = name, frameType
        if frameType == "Button" then
            assert(name == "LibDBIcon10_LockInTools" and parent == minimap,
                "the real DBIcon creates the broker's named minimap child")
            world.minimapButtonCreations = world.minimapButtonCreations + 1
        else
            assert(name == "LibDBIconTooltip" and template == "GameTooltipTemplate",
                "DBIcon owns its shared native tooltip")
        end
        if name then environment[name] = result end
        return result
    end
end

return loadOptions, prepareMinimap
