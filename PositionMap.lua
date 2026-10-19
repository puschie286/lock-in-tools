local _, addon = ...
local PIN_TEMPLATE = "LockInToolsPositionPinTemplate"
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

function Pin:OnLoad()
    self:SetScalingLimits(1, 1, 1)
    self:SetIgnoreGlobalPinScale(true)
    self:UseFrameLevelType("PIN_FRAME_LEVEL_GROUP_MEMBER")
end

function Pin:OnAcquired(name, x, y, online)
    self.playerName = name
    self.online = online
    if online == true then
        self.Label:SetText(name)
        self.Label:SetTextColor(1, 1, 1, 1)
        self.Icon:SetColorTexture(0.1, 0.8, 1, 1)
    else
        self.Label:SetText(name .. " (Offline)")
        self.Label:SetTextColor(0.6, 0.6, 0.6, 1)
        self.Icon:SetColorTexture(0.5, 0.5, 0.5, 0.6)
    end
    self:SetPosition(x, y)
end

function Pin:OnReleased()
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
end

function Provider:RefreshAllData()
    self:RemoveAllData()
    local map = self:GetMap()
    if not map:IsShown() then return end
    local mapID = map:GetMapID()
    for _, peer in pairs(self.addon:GetSharedPositions()) do
        if not IsSecret(peer.name) and type(peer.name) == "string" and peer.name ~= "" then
            local x, y = PositionOnMap(peer, mapID)
            if x then map:AcquirePin(PIN_TEMPLATE, peer.name, x, y, peer.online) end
        end
    end
end

function addon:RefreshPositionPins()
    if self.positionMapProvider then self.positionMapProvider:RefreshAllData() end
end

function addon:InitializePositionMap()
    if self.positionMapProvider then return end
    if not WorldMapFrame or not WorldMapFrame.AddDataProvider
        or not MapCanvasDataProviderMixin or not MapCanvasPinMixin then
        if not self.positionMapFrame then
            self.positionMapFrame = CreateFrame("Frame")
            self.positionMapFrame:RegisterEvent("ADDON_LOADED")
            self.positionMapFrame:SetScript("OnEvent", function(_, _, loadedAddon)
                if loadedAddon == "Blizzard_WorldMap" then self:InitializePositionMap() end
            end)
        end
        return
    end

    -- Keep the XML mixin table stable when native map code loads later.
    Mixin(LockInToolsPositionPinMixin, MapCanvasPinMixin, Pin)
    local provider = CreateFromMixins(MapCanvasDataProviderMixin, Provider)
    provider.addon = self
    WorldMapFrame:AddDataProvider(provider)
    self.positionMapProvider = provider
    if self.positionMapFrame then self.positionMapFrame:UnregisterEvent("ADDON_LOADED") end
    provider:RefreshAllData()
end
