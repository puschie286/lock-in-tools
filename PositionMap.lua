local _, addon = ...
local PIN_TEMPLATE = "LockInToolsPositionPinTemplate"
local DOT_TEXTURE = "Interface\\AddOns\\LockInTools\\Media\\PositionDot"
local RING_TEXTURE = "Interface\\AddOns\\LockInTools\\Media\\PositionRing"
local DOT_RADIUS, TOOLTIP_INTERVAL = 6, 0.1
local INTERPOLATION_SECONDS, MAX_INTERPOLATION_DISTANCE = 2, 0.1
local Provider, Pin = {}, {}
LockInToolsPositionPinMixin = {}

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function Number(value)
    return not IsSecret(value) and type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function Coordinate(value)
    return Number(value) and value >= 0 and value <= 1
end

local function MapID(value)
    return Number(value) and value >= 1 and value <= 1000000 and value == math.floor(value)
end

local function ClassColor(class)
    if not IsSecret(class) and type(class) == "string" and not IsSecret(RAID_CLASS_COLORS)
        and type(RAID_CLASS_COLORS) == "table" then
        local color = RAID_CLASS_COLORS[class]
        if not IsSecret(color) and type(color) == "table"
            and Coordinate(color.r) and Coordinate(color.g) and Coordinate(color.b) then
            return color.r, color.g, color.b
        end
    end
    return 0.27, 0.65, 1
end

local function ScreenCircle(pin)
    local x, y = pin:GetCenter()
    local scale = pin:GetEffectiveScale()
    if Number(x) and Number(y) and Number(scale) and scale > 0 then
        return x * scale, y * scale, DOT_RADIUS * scale
    end
end

local function Overlaps(first, second)
    if first == second then return true end
    local x, y, radius = ScreenCircle(first)
    local otherX, otherY, otherRadius = ScreenCircle(second)
    if not x or not otherX then return false end
    local dx, dy = otherX - x, otherY - y
    return dx * dx + dy * dy <= (radius + otherRadius) * (radius + otherRadius)
end

local function WorldPositionOnMap(peer, mapID)
    if not C_Map or not C_Map.GetWorldPosFromMapPos or not C_Map.GetMapPosFromWorldPos
        or not CreateVector2D then return nil end
    local continentID, worldPosition = C_Map.GetWorldPosFromMapPos(peer.map, CreateVector2D(peer.x, peer.y))
    if not Number(continentID) or IsSecret(worldPosition) or not worldPosition then return nil end
    local projectedMap, position = C_Map.GetMapPosFromWorldPos(continentID, worldPosition, mapID)
    if IsSecret(projectedMap) or projectedMap ~= mapID or IsSecret(position) or not position then return nil end
    local x, y = position:GetXY()
    if Coordinate(x) and Coordinate(y) then return x, y end
end

local function PositionOnMap(peer, mapID)
    if not MapID(peer.map) or not MapID(mapID) or not Coordinate(peer.x) or not Coordinate(peer.y) then return nil end
    if peer.map == mapID then return peer.x, peer.y end
    if C_Map and C_Map.GetMapRectOnMap then
        local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(peer.map, mapID)
        if Number(minX) and Number(maxX) and Number(minY) and Number(maxY)
            and maxX > minX and maxY > minY then
            local x = minX + peer.x * (maxX - minX)
            local y = minY + peer.y * (maxY - minY)
            if Coordinate(x) and Coordinate(y) then return x, y end
            return nil
        end
    end
    -- Overlapping city/zone maps need not have a direct parent-map rectangle.
    return WorldPositionOnMap(peer, mapID)
end

local function DisplayPosition(motion, now)
    if motion.started then
        local progress = math.max(0, math.min(1, (now - motion.started) / INTERPOLATION_SECONDS))
        if progress < 1 then
            return motion.fromX + (motion.x - motion.fromX) * progress,
                motion.fromY + (motion.y - motion.fromY) * progress, true
        end
    end
    return motion.x, motion.y, false
end

local function NewMotion(peer, mapID, x, y, previous, now)
    local motion = {
        x = x, y = y, map = mapID, sourceMap = peer.map, sourceX = peer.x, sourceY = peer.y,
        name = peer.name, online = peer.online == true,
    }
    if previous and previous.online and motion.online and previous.map == mapID
        and previous.sourceMap == peer.map and previous.name == peer.name then
        local dx, dy = peer.x - previous.sourceX, peer.y - previous.sourceY
        -- Snap large jumps rather than drawing a path through a teleport.
        if dx * dx + dy * dy <= MAX_INTERPOLATION_DISTANCE * MAX_INTERPOLATION_DISTANCE then
            -- Metadata and other peers can refresh the map without a new target.
            if previous.x == x and previous.y == y then return previous end
            motion.fromX, motion.fromY = DisplayPosition(previous, now)
            if motion.fromX ~= x or motion.fromY ~= y then motion.started = now end
        end
    end
    return motion
end

local function RegisterMapFilter(self)
    if self.positionMapFilterRegistered or not Menu or type(Menu.ModifyMenu) ~= "function" then return end
    Menu.ModifyMenu("MENU_WORLD_MAP_TRACKING", function(_, rootDescription)
        rootDescription:CreateDivider()
        rootDescription:CreateTitle("LockInTools")
        local checkbox = rootDescription:CreateCheckbox("Show player icons", function()
            return self:GetShowPlayerIcons()
        end, function()
            self:SetShowPlayerIcons(not self:GetShowPlayerIcons())
        end)
        checkbox:SetEnabled(self.initialized and not self.savedDataReadOnly)
    end)
    self.positionMapFilterRegistered = true
end

function Pin:OnLoad()
    self:SetScalingLimits(1, 1, 1)
    self:SetIgnoreGlobalPinScale(true)
    self:UseFrameLevelType("PIN_FRAME_LEVEL_GROUP_MEMBER")
end

function Pin:OnAcquired(name, x, y, online, class, motion, provider)
    self.playerName = name
    self.online = online
    self.provider = provider
    if online == true then
        self.red, self.green, self.blue = ClassColor(class)
    else
        self.red, self.green, self.blue = 0.6, 0.6, 0.6
    end
    -- Native pins are pooled, so reset every texture property before reuse.
    self.Icon:SetTexture(online == true and DOT_TEXTURE or RING_TEXTURE)
    self.Icon:SetTexCoord(0, 1, 0, 1)
    self.Icon:SetVertexColor(self.red, self.green, self.blue)
    self.Icon:SetDesaturated(false)
    self.Icon:SetAlpha(1)
    self.motion = motion
    if motion then
        self:SetScript("OnUpdate", self.OnUpdate)
        self:OnUpdate()
    else
        self:SetPosition(x, y)
    end
end

function Pin:OnUpdate()
    local now, moving = GetTime(), false
    if self.motion then
        local x, y
        x, y, moving = DisplayPosition(self.motion, now)
        self:SetPosition(x, y)
    end
    if self.restoreTooltip then
        self.restoreTooltip = nil
        -- Wait for the rebuilt pins' layout before restoring a stationary hover.
        if GameTooltip and not GameTooltip:IsShown() and self:GetMap():IsShown() and self:IsMouseOver() then
            self:OnMouseEnter()
        end
    end
    if self.hovered then
        if not self:GetMap():IsShown() or not GameTooltip or not GameTooltip:IsOwned(self)
            or not GameTooltip:IsShown() then
            self:OnMouseLeave()
        elseif not self.tooltipUpdated or now - self.tooltipUpdated >= TOOLTIP_INTERVAL then
            self:RefreshTooltip()
        end
    end
    if not moving and not self.hovered then self:SetScript("OnUpdate", nil) end
end

function Pin:RefreshTooltip()
    local players = {}
    for _, pin in ipairs(self.provider.pins) do
        if pin.playerName and Overlaps(self, pin) then players[#players + 1] = pin end
    end
    -- Acquisition order follows the peer table; keep tooltip rows stable.
    table.sort(players, function(first, second)
        local a, b = string.lower(first.playerName), string.lower(second.playerName)
        return a == b and first.playerName < second.playerName or a < b
    end)
    if #players <= 1 then
        GameTooltip:SetText(self.playerName, self.red, self.green, self.blue)
        if self.online ~= true then GameTooltip:AddLine("Last known position", 0.6, 0.6, 0.6) end
    else
        GameTooltip:SetText("Shared positions (" .. #players .. ")")
        for _, pin in ipairs(players) do
            local text = pin.playerName .. (pin.online == true and "" or " (Last known position)")
            GameTooltip:AddLine(text, pin.red, pin.green, pin.blue)
        end
    end
    GameTooltip:Show()
    self.tooltipUpdated = GetTime()
end

function Pin:OnMouseEnter()
    -- Native acquisition shows the frame before assigning the peer metadata.
    if not self.playerName or not self.provider or not GameTooltip or not self:GetMap():IsShown() then return end
    self.hovered = true
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    self:RefreshTooltip()
    self:SetScript("OnUpdate", self.OnUpdate)
end

function Pin:OnMouseLeave()
    self.hovered, self.tooltipUpdated = nil, nil
    if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    local moving = false
    if self.motion then
        local _, _, active = DisplayPosition(self.motion, GetTime())
        moving = active
    end
    if not moving and not self.restoreTooltip then self:SetScript("OnUpdate", nil) end
end

function Pin:OnReleased()
    if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    self:SetScript("OnUpdate", nil)
    self.motion = nil
    self.playerName = nil
    self.online = nil
    self.provider = nil
    self.red, self.green, self.blue = nil, nil, nil
    self.hovered, self.tooltipUpdated, self.restoreTooltip = nil, nil, nil
    MapCanvasPinMixin.OnReleased(self)
end

function Pin:GetDisplayName()
    return self.playerName or ""
end

function Provider:RemoveAllData()
    self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE)
    self.positions, self.pins = {}, {}
end

function Provider:OnHide()
    for _, pin in ipairs(self.pins or {}) do
        pin.restoreTooltip = nil
        pin:OnMouseLeave()
    end
end

function Provider:RefreshAllData(fromOnShow)
    -- Keep motion by sender, independently of which pooled pin is acquired next.
    local previous = not fromOnShow and self.positions or nil
    local hoveredName
    for _, pin in ipairs(self.pins or {}) do
        if pin.hovered and GameTooltip and GameTooltip:IsOwned(pin) then hoveredName = pin.playerName end
    end
    self:RemoveAllData()
    local map = self:GetMap()
    if not map:IsShown() or not self.addon:GetShowPlayerIcons() then return end
    local mapID = map:GetMapID()
    local now = GetTime()
    for sender, peer in pairs(self.addon:GetSharedPositions()) do
        if not IsSecret(peer.name) and type(peer.name) == "string" and peer.name ~= "" then
            local x, y = PositionOnMap(peer, mapID)
            if x then
                local motion = NewMotion(peer, mapID, x, y, previous and previous[sender], now)
                self.positions[sender] = motion
                local pin = map:AcquirePin(PIN_TEMPLATE, peer.name, x, y, peer.online, peer.class, motion, self)
                self.pins[#self.pins + 1] = pin
            end
        end
    end
    if hoveredName then
        for _, pin in ipairs(self.pins) do
            if pin.playerName == hoveredName then
                pin.restoreTooltip = true
                pin:SetScript("OnUpdate", pin.OnUpdate)
                break
            end
        end
    end
end

function addon:RefreshPositionPins()
    if self.positionMapProvider then self.positionMapProvider:RefreshAllData() end
end

for _, notification in ipairs({ "GROUP_CHANGED", "POSITIONS_CHANGED", "POSITION_VISIBILITY_CHANGED" }) do
    addon:RegisterNotification(notification, function() addon:RefreshPositionPins() end)
end

function addon:InitializePositionMap()
    RegisterMapFilter(self)
    if not self.positionMapProvider and WorldMapFrame and WorldMapFrame.AddDataProvider
        and MapCanvasDataProviderMixin and MapCanvasPinMixin then
        -- Keep the XML mixin table stable when native map code loads later.
        Mixin(LockInToolsPositionPinMixin, MapCanvasPinMixin, Pin)
        local provider = CreateFromMixins(MapCanvasDataProviderMixin, Provider)
        provider.addon = self
        WorldMapFrame:AddDataProvider(provider)
        self.positionMapProvider = provider
        provider:RefreshAllData()
    end

    if self.positionMapProvider and self.positionMapFilterRegistered then
        if self.positionMapEvents then self.positionMapEvents:UnregisterEvent("ADDON_LOADED") end
    elseif not self.positionMapEvents then
        self.positionMapEvents = self:RegisterGameEvents({ "ADDON_LOADED" }, function(self, _, loadedAddon)
            if loadedAddon == "Blizzard_WorldMap" or loadedAddon == "Blizzard_Menu" then
                self:InitializePositionMap()
            end
        end)
    end
end
