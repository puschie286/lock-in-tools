local _, addon = ...
local PIN_TEMPLATE = "LockInToolsPositionPinTemplate"
local CLASS_TEXTURE = "Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES"
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

local function ClassCoordinates(class)
    if IsSecret(class) or type(class) ~= "string" or IsSecret(CLASS_ICON_TCOORDS)
        or type(CLASS_ICON_TCOORDS) ~= "table" then return nil end
    local coordinates = CLASS_ICON_TCOORDS[class]
    if IsSecret(coordinates) or type(coordinates) ~= "table" then return nil end
    for index = 1, 4 do
        if not Coordinate(coordinates[index]) then return nil end
    end
    return coordinates
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

function Pin:OnAcquired(name, x, y, online, class, motion)
    self.playerName = name
    self.online = online
    -- Native pins are pooled, so reset every texture property before reuse.
    self.Icon:SetTexCoord(0, 1, 0, 1)
    self.Icon:SetVertexColor(1, 1, 1)
    self.Icon:SetDesaturated(false)
    self.Icon:SetAlpha(1)
    local coordinates = ClassCoordinates(class)
    if coordinates then
        self.Icon:SetTexture(CLASS_TEXTURE)
        self.Icon:SetTexCoord(coordinates[1], coordinates[2], coordinates[3], coordinates[4])
        if online ~= true then
            self.Icon:SetDesaturated(true)
            self.Icon:SetVertexColor(0.6, 0.6, 0.6)
            self.Icon:SetAlpha(0.6)
        end
    elseif online == true then
        self.Icon:SetColorTexture(0.1, 0.8, 1, 1)
    else
        self.Icon:SetColorTexture(0.5, 0.5, 0.5, 0.6)
    end
    if online == true then
        self.Label:SetText(name)
        self.Label:SetTextColor(1, 1, 1, 1)
    else
        self.Label:SetText(name .. " (Offline)")
        self.Label:SetTextColor(0.6, 0.6, 0.6, 1)
    end
    self.motion = motion
    if motion then
        self:SetScript("OnUpdate", self.OnUpdate)
        self:OnUpdate()
    else
        self:SetPosition(x, y)
    end
end

function Pin:OnUpdate()
    local x, y, moving = DisplayPosition(self.motion, GetTime())
    self:SetPosition(x, y)
    if not moving then self:SetScript("OnUpdate", nil) end
end

function Pin:OnReleased()
    self:SetScript("OnUpdate", nil)
    self.motion = nil
    self.playerName = nil
    self.online = nil
    self.Label:SetText("")
    MapCanvasPinMixin.OnReleased(self)
end

function Pin:GetDisplayName()
    return self.playerName or ""
end

function Provider:RemoveAllData()
    self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE)
    self.positions = {}
end

function Provider:RefreshAllData(fromOnShow)
    -- Keep motion by sender, independently of which pooled pin is acquired next.
    local previous = not fromOnShow and self.positions or nil
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
                map:AcquirePin(PIN_TEMPLATE, peer.name, x, y, peer.online, peer.class, motion)
            end
        end
    end
end

function addon:RefreshPositionPins()
    if self.positionMapProvider then self.positionMapProvider:RefreshAllData() end
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
        if self.positionMapFrame then self.positionMapFrame:UnregisterEvent("ADDON_LOADED") end
    elseif not self.positionMapFrame then
        self.positionMapFrame = CreateFrame("Frame")
        self.positionMapFrame:RegisterEvent("ADDON_LOADED")
        self.positionMapFrame:SetScript("OnEvent", function(_, _, loadedAddon)
            if loadedAddon == "Blizzard_WorldMap" or loadedAddon == "Blizzard_Menu" then
                self:InitializePositionMap()
            end
        end)
    end
end
