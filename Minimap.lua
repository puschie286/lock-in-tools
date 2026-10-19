local _, addon = ...

local DEFAULT_ANGLE = 225

local function SavedAngle(settings)
    local angle = type(settings) == "table" and settings.angle
    if type(angle) ~= "number" or angle ~= angle or angle == math.huge or angle == -math.huge then
        return DEFAULT_ANGLE
    end
    return angle % 360
end

local function PositionButton(button)
    local radians = math.rad(button.angle)
    local x, y = math.cos(radians), math.sin(radians)
    if type(GetMinimapShape) == "function" and GetMinimapShape() == "SQUARE" then
        local edge = math.max(math.abs(x), math.abs(y))
        x, y = x / edge, y / edge
    end
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER",
        x * (Minimap:GetWidth() / 2 + 8), y * (Minimap:GetHeight() / 2 + 8))
end

local function DragButton(button)
    local centerX, centerY = Minimap:GetCenter()
    if not centerX or not centerY then return end
    local cursorX, cursorY = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    local x = (cursorX / scale - centerX) / (Minimap:GetWidth() / 2 + 8)
    local y = (cursorY / scale - centerY) / (Minimap:GetHeight() / 2 + 8)
    if x == 0 and y == 0 then return end
    button.angle = math.deg(math.atan2(y, x)) % 360
    PositionButton(button)
end

local function StopDragging(button)
    button:SetScript("OnUpdate", nil)
    if not button.dragging then return end
    button.dragging = nil
    if not addon.savedDataReadOnly then
        if type(addon.db.minimap) ~= "table" then addon.db.minimap = {} end
        addon.db.minimap.angle = button.angle
    end
end

function addon:InitializeMinimapButton()
    if self.minimapButton or not self.ready or not Minimap then return end

    local button = CreateFrame("Button", "LockInToolsMinimapButton", Minimap)
    self.minimapButton = button
    button.angle = SavedAngle(self.db.minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetPoint("TOPLEFT", 7, -5)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("TOPLEFT", 7, -5)
    icon:SetTexture("Interface\\AddOns\\LockInTools\\Media\\Icon.tga")
    button.icon = icon

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "LeftButton" then self:OpenOptions()
        elseif mouseButton == "RightButton" then self:OpenWelcome() end
    end)
    button:SetScript("OnEnter", function()
        if button.dragging then return end
        GameTooltip:SetOwner(button, "ANCHOR_LEFT")
        GameTooltip:SetText("LockInTools")
        GameTooltip:AddLine("Left-click: settings", 1, 1, 1)
        GameTooltip:AddLine("Right-click: welcome", 1, 1, 1)
        GameTooltip:AddLine("Drag to move around the minimap", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetScript("OnDragStart", function()
        button.dragging = true
        GameTooltip:Hide()
        button:SetScript("OnUpdate", DragButton)
    end)
    button:SetScript("OnDragStop", StopDragging)
    button:SetScript("OnHide", function()
        StopDragging(button)
        if GameTooltip:IsOwned(button) then GameTooltip:Hide() end
    end)

    Minimap:HookScript("OnSizeChanged", function() PositionButton(button) end)
    PositionButton(button)
end
