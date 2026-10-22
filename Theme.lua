local _, addon = ...

local Theme = {}
addon.Theme = Theme

local colors = {
    background = { 0.045, 0.055, 0.075, 0.98 },
    surface = { 0.075, 0.09, 0.12, 1 },
    border = { 0.16, 0.20, 0.26, 1 },
    text = { 0.91, 0.94, 0.98 },
    muted = { 0.60, 0.67, 0.76 },
    heading = { 0.96, 0.98, 1 },
    accent = { 0.27, 0.65, 1 },
    danger = { 1, 0.47, 0.47 },
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

function Theme:GetAccentColor()
    return unpack(colors.accent)
end

function Theme:GetPalette()
    local palette = {}
    for role, color in pairs(colors) do palette[role] = { unpack(color) } end
    return palette
end

function Theme:GetFont()
    local font = GameFontHighlight or GameFontNormal
    if font then return font:GetFont() end
end

function Theme:Label(parent, text, size, role)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    local font = label:GetFont()
    label:SetFont(font, size or 14, "")
    label:SetJustifyH("LEFT")
    label:SetTextColor(unpack(colors[role or "text"]))
    label:SetText(text or "")
    return label
end

function Theme:Button(parent, text, style)
    local button = CreateFrame("Button", nil, parent)
    local entry = {}
    if style == "tab" then button.themeTab = entry end
    local fill, edges = Surface(button, colors.surface)
    local label = self:Label(button, "", 13)
    label:SetPoint("CENTER", button, "CENTER")
    button:SetFontString(label)
    button:SetText(text or "")
    local function Paint()
        local enabled = button:IsEnabled()
        local color = not enabled and colors.muted
            or (style == "danger" and colors.danger or colors.text)
        label:SetTextColor(unpack(color))
        label:SetAlpha(enabled and 1 or 0.5)
        local primary = style == "primary" or entry.selected
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
    entry.paint = Paint
    Paint()
    return button
end

function Theme:SetTabSelected(button, selected)
    local entry = button.themeTab
    entry.selected = selected == true
    entry.paint()
end

function Theme:EditBox(parent)
    local edit = CreateFrame("EditBox", nil, parent)
    local focused = false
    local _, edges = Surface(edit, { 0.025, 0.035, 0.05, 1 })
    edit:SetFontObject("GameFontHighlight")
    local font = edit:GetFont()
    edit:SetFont(font, 14, "")
    edit:SetTextColor(unpack(colors.text))
    edit:SetTextInsets(10, 10, 0, 0)
    edit:SetAutoFocus(false)
    local function Paint()
        edit:SetTextColor(unpack(edit:IsEnabled() and colors.text or colors.muted))
        Border(edges, focused and colors.accent or colors.border)
    end
    edit:HookScript("OnEditFocusGained", function() focused = true; Paint() end)
    edit:HookScript("OnEditFocusLost", function() focused = false; Paint() end)
    hooksecurefunc(edit, "SetEnabled", Paint)
    return edit
end

function Theme:Checkbox(parent)
    local checkbox = CreateFrame("CheckButton", nil, parent)
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
        if checkbox:IsEnabled() then Border(edges, colors.accent) end
    end)
    checkbox:HookScript("OnLeave", function()
        Border(edges, colors.border)
    end)
    return checkbox
end

function Theme:Window(name, width, height)
    local panel = CreateFrame("Frame", name, UIParent)
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
    panel.background, panel.borders = Surface(panel, colors.background)
    local stripe = Texture(panel, "ARTWORK", colors.accent)
    panel.stripe = stripe
    stripe:SetPoint("TOPLEFT", 1, -1)
    stripe:SetPoint("TOPRIGHT", -1, -1)
    stripe:SetHeight(2)
    panel.TitleIcon = panel:CreateTexture(nil, "OVERLAY")
    panel.TitleIcon:SetSize(32, 32)
    panel.TitleIcon:SetPoint("TOPLEFT", 24, -12)
    panel.TitleIcon:SetTexture("Interface\\AddOns\\LockInTools\\Media\\Icon.tga")
    panel.TitleText = self:Label(panel, "LockInTools", 16, "heading")
    panel.TitleText:SetPoint("LEFT", panel.TitleIcon, "RIGHT", 10, 0)
    panel.CloseButton = CreateFrame("Button", nil, panel)
    panel.CloseButton:SetSize(32, 32)
    panel.CloseButton:SetPoint("TOPRIGHT", -10, -10)
    local close = self:Label(panel.CloseButton, "\195\151", 24, "muted")
    close:SetPoint("CENTER", panel.CloseButton, "CENTER")
    panel.CloseButton:SetFontString(close)
    panel.CloseButton:HookScript("OnEnter", function() close:SetTextColor(unpack(colors.text)) end)
    panel.CloseButton:HookScript("OnLeave", function() close:SetTextColor(unpack(colors.muted)) end)
    panel.CloseButton:SetScript("OnClick", function() panel:Hide() end)
    return panel
end

function Theme:Section(parent, x, y, width, height, title)
    local section = CreateFrame("Frame", nil, parent)
    section:SetPoint("TOPLEFT", x, -y)
    section:SetSize(width, height)
    Surface(section, colors.surface)
    local heading = self:Label(section, title, 18, "heading")
    heading:SetPoint("TOPLEFT", 16, -16)
    return section
end

function Theme:Fit(panel)
    local width, height = UIParent:GetWidth(), UIParent:GetHeight()
    if width and height and width > 32 and height > 32 then
        panel:SetScale(math.min(1, (width - 32) / panel:GetWidth(), (height - 32) / panel:GetHeight()))
    end
end

