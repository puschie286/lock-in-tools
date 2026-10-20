local _, addon = ...

local NAME = "LockInTools"
local DEFAULT_ANGLE = 225

local function Angle(value)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return nil end
    return value % 360
end

local function MinimapSettings(self)
    local saved = self.db.minimap
    local settings
    if self.savedDataReadOnly then
        -- LibDBIcon writes while dragging: never give it a saved-data table
        -- when this addon cannot safely edit the current settings schema.
        settings = {}
        for key, value in pairs(type(saved) == "table" and saved or {}) do settings[key] = value end
    else
        if type(saved) ~= "table" then saved = {}; self.db.minimap = saved end
        settings = saved
    end
    settings.minimapPos = Angle(settings.minimapPos) or Angle(settings.angle) or DEFAULT_ANGLE
    return settings
end

function addon:InitializeMinimapButton()
    if self.minimapButton or not self.ready or not Minimap then return end
    local broker = LibStub("LibDataBroker-1.1")
    local icons = LibStub("LibDBIcon-1.0")
    self.minimapDataObject = broker:NewDataObject(NAME, {
        type = "launcher",
        text = NAME,
        icon = "Interface\\AddOns\\LockInTools\\Media\\Icon.tga",
        OnClick = function(_, mouseButton)
            if mouseButton == "LeftButton" then self:OpenContent()
            elseif mouseButton == "RightButton" then self:OpenOptions() end
        end,
        OnTooltipShow = function(tooltip)
            -- LibDBIcon anchors its shared tooltip before this callback. Other
            -- broker displays own their tooltip placement and only need content.
            if tooltip == icons.tooltip then
                tooltip:ClearAllPoints()
                GameTooltip_SetDefaultAnchor(tooltip, tooltip:GetOwner())
            end
            tooltip:SetText(NAME)
            tooltip:AddLine("Left-click: Content", 1, 1, 1)
            tooltip:AddLine("Right-click: Settings", 1, 1, 1)
        end,
    })
    icons:Register(NAME, self.minimapDataObject, MinimapSettings(self))
    local button = icons:GetMinimapButton(NAME)
    self.minimapButton = button
    button:HookScript("OnHide", function(hidden)
        local stop = hidden:GetScript("OnDragStop")
        if hidden:GetScript("OnUpdate") and stop then stop(hidden) end
        if icons.tooltip:IsOwned(hidden) then icons.tooltip:Hide() end
    end)
    Minimap:HookScript("OnSizeChanged", function() icons:Refresh(NAME) end)
    -- Registration can occur during PLAYER_LOGIN before LibDBIcon's own frame
    -- receives it, or after login through an addon manager.
    icons:Refresh(NAME)
end
