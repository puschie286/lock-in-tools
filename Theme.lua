local addonName, addon = ...

local Theme = { windows = {} }
addon.Theme = Theme

local colors = {
    background = { 0.045, 0.055, 0.075, 0.98 },
    surface = { 0.075, 0.09, 0.12, 1 },
    border = { 0.16, 0.20, 0.26, 1 },
    text = { 0.91, 0.94, 0.98 },
    muted = { 0.60, 0.67, 0.76 },
    heading = { 0.96, 0.98, 1 },
    accent = { 0.27, 0.65, 1 },
}

local function Texture(parent, layer, color)
    local texture = parent:CreateTexture(nil, layer)
    texture:SetColorTexture(unpack(color))
    return texture
end

local function Surface(frame, color, inset)
    inset = inset or 0
    local fill = Texture(frame, "BACKGROUND", color)
    fill:SetPoint("TOPLEFT", inset, -inset)
    fill:SetPoint("BOTTOMRIGHT", -inset, inset)
    local edges = {}
    for i = 1, 4 do edges[i] = Texture(frame, "BORDER", colors.border) end
    edges[1]:SetPoint("TOPLEFT", inset, -inset)
    edges[1]:SetPoint("TOPRIGHT", -inset, -inset)
    edges[1]:SetHeight(1)
    edges[2]:SetPoint("BOTTOMLEFT", inset, inset)
    edges[2]:SetPoint("BOTTOMRIGHT", -inset, inset)
    edges[2]:SetHeight(1)
    edges[3]:SetPoint("TOPLEFT", inset, -inset)
    edges[3]:SetPoint("BOTTOMLEFT", inset, inset)
    edges[3]:SetWidth(1)
    edges[4]:SetPoint("TOPRIGHT", -inset, -inset)
    edges[4]:SetPoint("BOTTOMRIGHT", -inset, inset)
    edges[4]:SetWidth(1)
    return fill, edges
end

local function Border(edges, color)
    for _, edge in ipairs(edges) do edge:SetColorTexture(unpack(color)) end
end

local function Track(parent, kind, widget)
    local owner = parent.themeOwner or parent
    widget.themeOwner = owner
    local entry = { kind = kind, widget = widget }
    owner.themeElements[#owner.themeElements + 1] = entry
    return entry
end

local function Try(skin, method, ...)
    if type(skin[method]) ~= "function" then return false end
    return pcall(skin[method], ...)
end

local function RefreshSkin(entry, skin)
    if entry.kind == "font" then
        Try(skin, "Font", entry.widget)
    elseif entry.kind == "edit" then
        -- EditBoxes are FontInstances; keep their native padding and behavior.
        Try(skin, "Font", entry.widget)
    elseif entry.kind == "checkbox" and type(skin.GetAccentColor) == "function" then
        local ok, red, green, blue = pcall(skin.GetAccentColor)
        if ok and type(red) == "number" and type(green) == "number" and type(blue) == "number" then
            entry.widget:GetCheckedTexture():SetVertexColor(red, green, blue)
        end
    end
end

local skinMethods = { window = "Shell", section = "Panel", button = "Button",
    close = "CloseButton", edit = "EditBox", checkbox = "Checkbox" }

local function SkinWindow(panel, skin)
    for _, entry in ipairs(panel.themeElements) do
        if not entry.skinned then
            local method = skinMethods[entry.kind]
            if method then entry.skinned = Try(skin, method, entry.widget) end
            if entry.kind == "button" and entry.skinned then
                entry.widget:GetFontString():SetAlpha(1)
                Try(skin, "StateButtonLabel", entry.widget)
            elseif entry.kind == "close" and entry.skinned then
                entry.widget:GetFontString():SetAlpha(0)
            end
        end
        RefreshSkin(entry, skin)
    end
end

function Theme:Label(parent, text, size, role)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    local font = label:GetFont()
    label:SetFont(font, size or 14, "")
    label:SetJustifyH("LEFT")
    label:SetTextColor(unpack(colors[role or "text"]))
    label:SetText(text or "")
    Track(parent, "font", label)
    return label
end

function Theme:Button(parent, text, style)
    local button = CreateFrame("Button", nil, parent)
    local entry = Track(parent, "button", button)
    local fill, edges = Surface(button, colors.surface)
    local label = self:Label(button, "", 13)
    label:SetPoint("CENTER", button, "CENTER")
    button:SetFontString(label)
    button:SetText(text or "")
    local function Paint()
        local enabled = button:IsEnabled()
        local color = not enabled and colors.muted
            or (not entry.skinned and style == "danger" and { 1, 0.47, 0.47 } or colors.text)
        label:SetTextColor(unpack(color))
        label:SetAlpha((enabled or entry.skinned) and 1 or 0.5)
        if entry.skinned then return end
        local primary = style == "primary"
        local hover = enabled and entry.hover
        local light = hover and 0.04 or 0
        fill:SetColorTexture(0.10 + light, (primary and 0.26 or 0.12) + light,
            (primary and 0.43 or 0.16) + light, enabled and 1 or 0.45)
        Border(edges, enabled and (hover or primary) and colors.accent or colors.border)
    end
    button:HookScript("OnEnter", function() entry.hover = true; Paint() end)
    button:HookScript("OnLeave", function() entry.hover = false; Paint() end)
    button:HookScript("OnEnable", Paint)
    button:HookScript("OnDisable", Paint)
    Paint()
    return button
end

function Theme:EditBox(parent)
    local edit = CreateFrame("EditBox", nil, parent)
    local entry = Track(parent, "edit", edit)
    local _, edges = Surface(edit, { 0.025, 0.035, 0.05, 1 })
    edit:SetFontObject("GameFontHighlight")
    local font = edit:GetFont()
    edit:SetFont(font, 14, "")
    edit:SetTextColor(unpack(colors.text))
    edit:SetTextInsets(10, 10, 0, 0)
    edit:SetAutoFocus(false)
    local function Paint()
        edit:SetTextColor(unpack(edit:IsEnabled() and colors.text or colors.muted))
        if entry.skinned then return end
        Border(edges, entry.focused and colors.accent or colors.border)
    end
    edit:HookScript("OnEditFocusGained", function() entry.focused = true; Paint() end)
    edit:HookScript("OnEditFocusLost", function() entry.focused = false; Paint() end)
    hooksecurefunc(edit, "SetEnabled", Paint)
    return edit
end

function Theme:Checkbox(parent)
    local checkbox = CreateFrame("CheckButton", nil, parent)
    local entry = Track(parent, "checkbox", checkbox)
    local _, edges = Surface(checkbox, { 0.025, 0.035, 0.05, 1 }, 4)
    local checked = checkbox:CreateTexture(nil, "ARTWORK")
    checked:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    checked:SetAllPoints(checkbox)
    checked:SetVertexColor(unpack(colors.accent))
    checkbox:SetCheckedTexture(checked)
    local disabled = checkbox:CreateTexture(nil, "ARTWORK")
    disabled:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    disabled:SetAllPoints(checkbox)
    disabled:SetVertexColor(unpack(colors.muted))
    checkbox:SetDisabledCheckedTexture(disabled)
    checkbox:HookScript("OnEnter", function()
        if not entry.skinned and checkbox:IsEnabled() then Border(edges, colors.accent) end
    end)
    checkbox:HookScript("OnLeave", function()
        if not entry.skinned then Border(edges, colors.border) end
    end)
    return checkbox
end

function Theme:Window(name, width, height)
    local panel = CreateFrame("Frame", name, UIParent)
    panel.themeOwner, panel.themeElements = panel, {}
    panel:SetSize(width, height)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("DIALOG")
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:Hide()
    Track(panel, "window", panel)
    Surface(panel, colors.background)
    local stripe = Texture(panel, "ARTWORK", colors.accent)
    stripe:SetPoint("TOPLEFT", 1, -1)
    stripe:SetPoint("TOPRIGHT", -1, -1)
    stripe:SetHeight(2)
    panel.TitleText = self:Label(panel, "LockInTools", 16, "heading")
    panel.TitleText:SetPoint("TOPLEFT", 24, -19)
    panel.CloseButton = CreateFrame("Button", nil, panel)
    Track(panel, "close", panel.CloseButton)
    panel.CloseButton:SetSize(32, 32)
    panel.CloseButton:SetPoint("TOPRIGHT", -10, -10)
    local close = self:Label(panel.CloseButton, "\195\151", 24, "muted")
    close:SetPoint("CENTER", panel.CloseButton, "CENTER")
    panel.CloseButton:SetFontString(close)
    panel.CloseButton:HookScript("OnEnter", function() close:SetTextColor(unpack(colors.text)) end)
    panel.CloseButton:HookScript("OnLeave", function() close:SetTextColor(unpack(colors.muted)) end)
    panel.CloseButton:SetScript("OnClick", function() panel:Hide() end)
    self.windows[#self.windows + 1] = panel
    return panel
end

function Theme:Section(parent, x, y, width, height, title)
    local section = CreateFrame("Frame", nil, parent)
    Track(parent, "section", section)
    section:SetPoint("TOPLEFT", x, -y)
    section:SetSize(width, height)
    Surface(section, colors.surface)
    local heading = self:Label(section, title, 18, "heading")
    heading:SetPoint("TOPLEFT", 16, -16)
    return section
end

function Theme:Finish(panel)
    panel.themeFinished = true
    if self.skin then SkinWindow(panel, self.skin) end
end

function Theme:Fit(panel)
    local width, height = UIParent:GetWidth(), UIParent:GetHeight()
    if width and height and width > 32 and height > 32 then
        panel:SetScale(math.min(1, (width - 32) / panel:GetWidth(), (height - 32) / panel:GetHeight()))
    end
end

-- EUI owns the opt-in and dispatch timing. Keep native visuals until it calls us.
-- Turning a skin off is reload-bound; do not undo its installed visual hooks.
if type(EllesmereUI) == "table" and type(EllesmereUI.RegisterSkin) == "function" then
    pcall(EllesmereUI.RegisterSkin, addonName, function(skin)
        if type(skin) ~= "table" then return end
        Theme.skin = skin
        for _, panel in ipairs(Theme.windows) do
            if panel.themeFinished then SkinWindow(panel, skin) end
        end
        Try(skin, "OnLooksChanged", function()
            for _, panel in ipairs(Theme.windows) do
                if panel.themeFinished then SkinWindow(panel, skin) end
            end
        end)
    end)
end
