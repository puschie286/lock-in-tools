local _, addon = ...
local DEATH_PIN_TEMPLATE = "LockInToolsDeathPinTemplate"
local MINIMAP_DEATH_PIN_TEMPLATE = "LockInToolsDeathMarkerTemplate"
local MINIMAP_PIN_SIZE, MINIMAP_UPDATE_INTERVAL = 14, 0.05
local Provider, DeathPin = {}, {}
local deathLocations = {}
local minimapDeathPins
LockInToolsDeathPinMixin = {}

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

local function NativeValue(callback, ...)
    if type(callback) ~= "function" then return nil end
    local ok, value = pcall(callback, ...)
    if ok and not IsSecret(value) then return value end
end

local function WorldPoint(mapID, x, y)
    local continentID, position = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(x, y))
    if not Number(continentID) or IsSecret(position) or not position then return nil end
    local worldX, worldY = position:GetXY()
    if Number(worldX) and Number(worldY) then return continentID, worldX, worldY end
end

local function WorldPositionOnMap(position, mapID)
    if not C_Map or not C_Map.GetWorldPosFromMapPos or not CreateVector2D then return nil end
    local continentID, worldX, worldY = WorldPoint(position.map, position.x, position.y)
    if not continentID then return nil end
    local originContinent, originX, originY = WorldPoint(mapID, 0, 0)
    if originContinent ~= continentID then return nil end
    -- The native inverse lookup can select the city instead of the overlapping region.
    -- Derive the target bounds from its origin and center; (1,1) is inaccurate on some maps.
    local centerContinent, centerX, centerY = WorldPoint(mapID, 0.5, 0.5)
    if centerContinent ~= continentID then return nil end
    local width, height = centerY - originY, centerX - originX
    if not Number(width) or not Number(height) or width == 0 or height == 0 then return nil end
    -- Native world X follows map Y, and world Y follows map X; spans may be negative.
    local x, y = (worldY - originY) / width * 0.5, (worldX - originX) / height * 0.5
    if Coordinate(x) and Coordinate(y) then return x, y end
end

local function PositionOnMap(position, mapID)
    if not MapID(position.map) or not MapID(mapID) or not Coordinate(position.x) or not Coordinate(position.y) then return nil end
    if position.map == mapID then return position.x, position.y end
    if C_Map and C_Map.GetMapRectOnMap then
        local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(position.map, mapID)
        if Number(minX) and Number(maxX) and Number(minY) and Number(maxY)
            and maxX > minX and maxY > minY then
            local x = minX + position.x * (maxX - minX)
            local y = minY + position.y * (maxY - minY)
            if Coordinate(x) and Coordinate(y) then return x, y end
        end
    end
    -- Overlapping city/zone maps need not have a direct parent-map rectangle.
    return WorldPositionOnMap(position, mapID)
end

local function NativeMapPosition(unit)
    local map = NativeValue(C_Map and C_Map.GetBestMapForUnit, unit)
    if not MapID(map) then return nil end
    local position = NativeValue(C_Map.GetPlayerMapPosition, map, unit)
    if not position then return nil end
    local ok, x, y = pcall(function() return position:GetXY() end)
    if ok and Coordinate(x) and Coordinate(y) then return map, x, y end
end

local function ShowDeathTooltip(pin)
    if not pin.playerName or not GameTooltip then return end
    GameTooltip_SetDefaultAnchor(GameTooltip, pin)
    GameTooltip:SetText(pin.playerName, 1, 0, 0)
    GameTooltip:Show()
end

local function HideDeathTooltip(pin)
    if GameTooltip and GameTooltip:IsOwned(pin) then GameTooltip:Hide() end
end

local function MinimapView(minimap)
    local map, x, y = NativeMapPosition("player")
    if not map then return nil end
    local radius = NativeValue(C_Minimap.GetViewRadius)
    local width, height = NativeValue(minimap.GetWidth, minimap), NativeValue(minimap.GetHeight, minimap)
    if not Number(radius) or radius <= 0 or not Number(width) or width <= 0
        or not Number(height) or height <= 0 then return nil end

    local rotate = NativeValue(C_CVar and C_CVar.GetCVarBool or GetCVarBool, "rotateMinimap")
    if type(rotate) ~= "boolean" then return nil end
    local facing = 0
    if rotate then
        local ignored = NativeValue(C_Minimap.IsRotateMinimapIgnored)
        if type(ignored) ~= "boolean" then return nil end
        if not ignored then facing = NativeValue(GetPlayerFacing) end
        if not Number(facing) then return nil end
    end

    local ok, worldID, north, west = pcall(WorldPoint, map, x, y)
    local group = NativeValue(C_Map.GetMapGroupID, map)
    return { map = map, x = x, y = y, worldID = ok and worldID or nil, north = north, west = west,
        group = Number(group) and group > 0 and group or nil, radius = radius, halfWidth = width / 2,
        halfHeight = height / 2, cos = math.cos(facing), sin = math.sin(facing),
        square = NativeValue(GetMinimapShape) == "SQUARE" }
end

local function MinimapOffset(position, view)
    if not position.worldID then
        local ok, worldID, north, west = pcall(WorldPoint, position.map, position.x, position.y)
        if ok then position.worldID, position.north, position.west = worldID, north, west end
    end
    local east, north
    if view.worldID and view.worldID == position.worldID then
        -- Floors of the same dungeon can overlap in world coordinates.
        if position.map ~= view.map and view.group
            and NativeValue(C_Map.GetMapGroupID, position.map) == view.group then return nil end
        east, north = view.west - position.west, position.north - view.north
    elseif position.map == view.map and (not view.worldID or not position.worldID) then
        local ok, width, height = pcall(C_Map.GetMapWorldSize, view.map)
        if not ok or not Number(width) or width <= 0 or not Number(height) or height <= 0 then return nil end
        east, north = (position.x - view.x) * width, (view.y - position.y) * height
    else
        return nil
    end

    -- Facing rotates east/north world offsets clockwise on screen.
    local x = (east * view.cos + north * view.sin) * view.halfWidth / view.radius
    local y = (north * view.cos - east * view.sin) * view.halfHeight / view.radius
    local edgeX = (math.abs(x) + MINIMAP_PIN_SIZE / 2) / view.halfWidth
    local edgeY = (math.abs(y) + MINIMAP_PIN_SIZE / 2) / view.halfHeight
    if view.square then
        if edgeX <= 1 and edgeY <= 1 then return x, y end
    elseif edgeX * edgeX + edgeY * edgeY <= 1 then
        return x, y
    end
end

local function AcquireMinimapDeathPin(frame)
    local pin = table.remove(frame.freePins)
    if pin then return pin end
    pin = CreateFrame("Frame", nil, frame, MINIMAP_DEATH_PIN_TEMPLATE)
    pin:SetSize(MINIMAP_PIN_SIZE, MINIMAP_PIN_SIZE)
    pin:SetScript("OnEnter", ShowDeathTooltip)
    pin:SetScript("OnLeave", HideDeathTooltip)
    pin:SetScript("OnHide", HideDeathTooltip)
    return pin
end

local function UpdateMinimapDeathPins(frame)
    local view = frame.minimap:IsVisible() and MinimapView(frame.minimap)
    for id, position in pairs(deathLocations) do
        local pin, x, y = frame.pins[id]
        if view then x, y = MinimapOffset(position, view) end
        if x then
            if not pin then
                pin = AcquireMinimapDeathPin(frame)
                frame.pins[id] = pin
                pin.playerName = position.name
            end
            if pin.x ~= x or pin.y ~= y then
                pin:ClearAllPoints()
                pin:SetPoint("CENTER", frame.minimap, "CENTER", x, y)
                pin.x, pin.y = x, y
            end
            pin:Show()
        elseif pin then
            pin:Hide()
        end
    end
end

local function RefreshMinimapDeathPins(self)
    local frame = minimapDeathPins
    if frame then
        for id, pin in pairs(frame.pins) do
            if not deathLocations[id] then
                pin:Hide()
                pin.playerName = nil
                frame.pins[id] = nil
                frame.freePins[#frame.freePins + 1] = pin
            end
        end
    end
    if not self:GetShowDeathMarkers() or not next(deathLocations) then
        if frame then frame:Hide() end
        return
    end
    if not frame then
        if not Minimap or not C_Minimap or type(C_Minimap.GetViewRadius) ~= "function" then return end
        frame = CreateFrame("Frame", nil, Minimap)
        minimapDeathPins = frame
        frame.minimap, frame.pins, frame.freePins, frame.elapsed = Minimap, {}, {}, 0
        frame:SetScript("OnShow", UpdateMinimapDeathPins)
        frame:SetScript("OnUpdate", function(driver, elapsed)
            driver.elapsed = driver.elapsed + elapsed
            if driver.elapsed < MINIMAP_UPDATE_INTERVAL then return end
            driver.elapsed = 0
            UpdateMinimapDeathPins(driver)
        end)
    end
    if frame:IsShown() then UpdateMinimapDeathPins(frame) else frame:Show() end
end

local function RefreshDeathMarkers(self)
    if self.positionMapProvider then self.positionMapProvider:RefreshAllData() end
    RefreshMinimapDeathPins(self)
end

local function UpdateDeathLocation(self, event, unit)
    if IsSecret(unit) or type(unit) ~= "string" then return end
    local raid = unit:match("^raid%d+$")
    if not raid and not unit:match("^party[1-4]$") then return end
    local dead = NativeValue(UnitIsDeadOrGhost, unit)
    if type(dead) ~= "boolean" or (not dead and not next(deathLocations))
        or NativeValue(UnitIsConnected, unit) ~= true then return end
    local id, name = self:GetNativeGroupMemberID(unit)
    if not id then return end
    if not dead then
        if not deathLocations[id] then return end
        deathLocations[id] = nil
    else
        -- A released spirit's coordinates describe its current location.
        -- Freeze the first readable corpse position until a confirmed revive.
        if deathLocations[id] or event == "UNIT_CONNECTION"
            or NativeValue(UnitIsDead, unit) ~= true or NativeValue(UnitIsGhost, unit) ~= false
            or (raid and NativeValue(UnitIsUnit, unit, "player") ~= false) then return end
        local map, x, y = NativeMapPosition(unit)
        if not map then return end
        deathLocations[id] = { map = map, x = x, y = y, name = self:GetPlayerDisplayName(name) }
    end
    RefreshDeathMarkers(self)
end

local function PruneDeathLocations(self)
    local changed = false
    for id in pairs(deathLocations) do
        local unit = self:GetNativeGroupUnit(id)
        if not unit or (NativeValue(UnitIsConnected, unit) == true
            and NativeValue(UnitIsDeadOrGhost, unit) == false) then
            deathLocations[id] = nil
            changed = true
        end
    end
    if changed then RefreshDeathMarkers(self) end
end

local function SaveDeathLocations(self)
    if self.savedDataReadOnly then return end
    local settings = self.db.position
    settings.deathMarkers = nil
    if not next(deathLocations) then return end
    local owner = self:GetNativePlayerID()
    if not owner then return end
    local entries = {}
    for id, position in pairs(deathLocations) do
        entries[id] = { map = position.map, x = position.x, y = position.y }
    end
    settings.deathMarkers = { owner = owner, entries = entries }
end

local function RestoreDeathLocations(self, initialLogin, reloading)
    if self.savedDataReadOnly then return end
    local saved = self.db.position.deathMarkers
    -- Consume the snapshot once, while checking eligibility against the startup roster.
    self.db.position.deathMarkers = nil
    if IsSecret(initialLogin) or IsSecret(reloading) or (initialLogin ~= true and reloading ~= true)
        or type(saved) ~= "table" or type(saved.entries) ~= "table" then return end
    local owner = self:GetNativePlayerID()
    if not owner or saved.owner ~= owner then return end

    -- Other entering-world listeners may not have refreshed the roster yet.
    self:RefreshNativeGroupMembership()
    local changed = false
    for id, position in pairs(saved.entries) do
        if id ~= owner and type(position) == "table" and MapID(position.map) and Coordinate(position.x)
            and Coordinate(position.y) and not deathLocations[id] then
            local unit = self:GetNativeGroupUnit(id)
            if unit and NativeValue(UnitIsConnected, unit) == true and NativeValue(UnitIsDeadOrGhost, unit) == true then
                local memberID, name = self:GetNativeGroupMemberID(unit)
                if memberID == id then
                    deathLocations[id] = { map = position.map, x = position.x, y = position.y,
                        name = self:GetPlayerDisplayName(name) }
                    changed = true
                end
            end
        end
    end
    if changed then RefreshDeathMarkers(self) end
end

local function OnDeathLocationEvent(self, event, unitOrInitialLogin, reloading)
    if event == "PLAYER_ENTERING_WORLD" then
        self.positionDeathEvents:UnregisterEvent(event)
        RestoreDeathLocations(self, unitOrInitialLogin, reloading)
    elseif event == "PLAYER_LOGOUT" then
        SaveDeathLocations(self)
    else
        UpdateDeathLocation(self, event, unitOrInitialLogin)
    end
end

function addon:GetShowDeathMarkers()
    return not self.db or type(self.db.position) ~= "table" or self.db.position.showDeathMarkers ~= false
end

function addon:SetShowDeathMarkers(enabled)
    if not self.initialized then return false, "Still loading. Please try again after login." end
    if self.savedDataReadOnly then return false, "Update LockInTools before changing saved preferences." end
    if type(enabled) ~= "boolean" then return false, "Choose on or off." end
    self.db.position.showDeathMarkers = enabled
    self:Notify("DEATH_MARKER_VISIBILITY_CHANGED")
    return true
end

local function RegisterMapFilter(self)
    if self.positionMapFilterRegistered or not Menu or type(Menu.ModifyMenu) ~= "function" then return end
    Menu.ModifyMenu("MENU_WORLD_MAP_TRACKING", function(_, rootDescription)
        rootDescription:CreateDivider()
        rootDescription:CreateTitle("LockInTools")
        local editable = self.initialized and not self.savedDataReadOnly
        local deathMarkers = rootDescription:CreateCheckbox("Show death markers", function()
            return self:GetShowDeathMarkers()
        end, function()
            self:SetShowDeathMarkers(not self:GetShowDeathMarkers())
        end)
        deathMarkers:SetEnabled(editable)
    end)
    self.positionMapFilterRegistered = true
end

function DeathPin:OnLoad()
    self:SetScalingLimits(1, 1, 1)
    self:SetIgnoreGlobalPinScale(true)
    self:UseFrameLevelType("PIN_FRAME_LEVEL_CORPSE")
end

function DeathPin:OnAcquired(x, y, name)
    self.playerName = name
    self:SetPosition(x, y)
end

function DeathPin:OnMouseEnter()
    if self.playerName and self:GetMap():IsShown() then ShowDeathTooltip(self) end
end

DeathPin.OnMouseLeave = HideDeathTooltip

function DeathPin:OnReleased()
    self:OnMouseLeave()
    self.playerName = nil
    MapCanvasPinMixin.OnReleased(self)
end

function Provider:OnRemoved(map)
    if self.addon.positionMapProvider == self then self.addon.positionMapProvider = nil end
    MapCanvasDataProviderMixin.OnRemoved(self, map)
end

function Provider:RemoveAllData()
    self:GetMap():RemoveAllPinsByTemplate(DEATH_PIN_TEMPLATE)
end

Provider.OnHide = Provider.RemoveAllData

function Provider:RefreshAllData()
    local map = self:GetMap()
    self:RemoveAllData()
    if not map:IsShown() or not self.addon:GetShowDeathMarkers() then return end
    local mapID = map:GetMapID()
    for _, position in pairs(deathLocations) do
        local ok, x, y = pcall(PositionOnMap, position, mapID)
        if ok and x then map:AcquirePin(DEATH_PIN_TEMPLATE, x, y, position.name) end
    end
end

addon:RegisterNotification("DEATH_MARKER_VISIBILITY_CHANGED", function()
    RefreshDeathMarkers(addon)
end)
addon:RegisterNotification("NATIVE_GROUP_CHANGED", function()
    PruneDeathLocations(addon)
end)

function addon:InitializeDeathMarkers()
    self:InitializeNativeGroupMembership()
    if not self.positionDeathEvents then
        self.positionDeathEvents = self:RegisterGameEvents({ "UNIT_FLAGS", "UNIT_HEALTH", "PLAYER_FLAGS_CHANGED",
            "UNIT_CONNECTION", "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT" }, OnDeathLocationEvent)
    end
    RegisterMapFilter(self)
    if not self.positionMapProvider and WorldMapFrame and WorldMapFrame.AddDataProvider
        and MapCanvasDataProviderMixin and MapCanvasPinMixin then
        -- Keep the XML mixin table stable when native map code loads later.
        Mixin(LockInToolsDeathPinMixin, MapCanvasPinMixin, DeathPin)
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
                self:InitializeDeathMarkers()
            end
        end)
    end
end
