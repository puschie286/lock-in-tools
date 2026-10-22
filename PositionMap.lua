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

local function PlayerID(name)
    if IsSecret(name) or type(name) ~= "string" or name == "" then return nil end
    local character, realm = name:match("^([^%-]+)%-(.+)$")
    if not character then
        character = name
        realm = type(GetNormalizedRealmName) == "function" and GetNormalizedRealmName() or nil
    end
    if IsSecret(realm) or type(realm) ~= "string" or realm == "" then return nil end
    return (character .. "-" .. realm:gsub("%s", "")):lower()
end

local function TooltipPlayer(pin, players)
    local source = players[PlayerID(pin.playerID) or PlayerID(pin.playerName)]
    local player = {}
    for key, value in pairs(source or {}) do player[key] = value end
    local position = pin.positionPeer
    if not source then
        player.name, player.online = pin.playerName, pin.online
        player.seenAt = position and position.stamp
    end
    if position then
        -- Coordinates belong to this pin's source map, not its projected map.
        -- Keep roster contact/sharing metadata authoritative for stale pins.
        player.map, player.x, player.y = position.map, position.x, position.y
        player.positionStamp, player.positionAvailable = position.positionStamp, position.positionAvailable
    end
    return player
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

local function WorldPoint(mapID, x, y)
    local continentID, position = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(x, y))
    if not Number(continentID) or IsSecret(position) or not position then return nil end
    local worldX, worldY = position:GetXY()
    if Number(worldX) and Number(worldY) then return continentID, worldX, worldY end
end

local function WorldPositionOnMap(peer, mapID)
    if not C_Map or not C_Map.GetWorldPosFromMapPos or not CreateVector2D then return nil end
    local continentID, worldX, worldY = WorldPoint(peer.map, peer.x, peer.y)
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

function Pin:OnAcquired(name, x, y, online, class, motion, provider, playerID, position)
    self.playerID, self.provider = playerID, provider
    self:UpdatePeer(name, x, y, online, class, motion, position)
end

function Pin:UpdatePeer(name, x, y, online, class, motion, position)
    if self.playerName ~= name or self.online ~= online or self.playerClass ~= class then
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
    end
    self.playerName, self.online, self.playerClass = name, online, class
    self.positionPeer, self.motion, self.tooltipUpdated = position, motion, nil
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
    if self.hovered then
        if not self:GetMap():IsShown() or not GameTooltip or not GameTooltip:IsOwned(self)
            or not GameTooltip:IsShown() then
            self:OnMouseLeave()
        elseif not self.tooltipUpdated or now - self.tooltipUpdated >= TOOLTIP_INTERVAL then
            self:RefreshTooltip(true)
        end
    end
    if not moving and not self.hovered then self:SetScript("OnUpdate", nil) end
end

function Pin:RefreshTooltip(preserveAnchor)
    local pins = {}
    for _, pin in ipairs(self.provider.pins) do
        if pin.playerName and Overlaps(self, pin) then pins[#pins + 1] = pin end
    end
    -- Acquisition order follows the peer table; keep tooltip rows stable.
    table.sort(pins, function(first, second)
        local a, b = string.lower(first.playerName), string.lower(second.playerName)
        return a == b and first.playerName < second.playerName or a < b
    end)
    if #pins == 0 then pins[1] = self end
    local players = self.provider.addon:GetPlayerTooltipPlayers()
    local entries = {}
    for _, pin in ipairs(pins) do
        entries[#entries + 1] = { player = TooltipPlayer(pin, players),
            red = pin.red, green = pin.green, blue = pin.blue }
    end
    if addon:ShowCompactPlayerTooltip(self, entries, preserveAnchor) then self.tooltipUpdated = GetTime() end
end

function Pin:OnMouseEnter()
    -- Native acquisition shows the frame before assigning the peer metadata.
    if not self.playerName or not self.provider or not GameTooltip or not self:GetMap():IsShown() then return end
    self.hovered = true
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
    if not moving then self:SetScript("OnUpdate", nil) end
end

function Pin:OnReleased()
    if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    self:SetScript("OnUpdate", nil)
    self.motion = nil
    self.playerName = nil
    self.playerID, self.positionPeer = nil, nil
    self.playerClass, self.providerIndex = nil, nil
    self.online = nil
    self.provider = nil
    self.red, self.green, self.blue = nil, nil, nil
    self.hovered, self.tooltipUpdated = nil, nil
    MapCanvasPinMixin.OnReleased(self)
end

function Pin:GetDisplayName()
    return addon:GetPlayerDisplayName(self.playerName)
end

function Provider:RemoveAllData()
    self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE)
    self.positions, self.pins, self.pinsBySender = {}, {}, {}
    self.mapID = nil
end

function Provider:RemovePeer(sender)
    self.positions[sender] = nil
    local pin = self.pinsBySender[sender]
    if not pin then return end
    local index, last = pin.providerIndex, self.pins[#self.pins]
    self.pins[index], last.providerIndex = last, index
    self.pins[#self.pins] = nil
    self.pinsBySender[sender] = nil
    -- Native removal owns pool release and OnReleased; never release twice.
    self:GetMap():RemovePin(pin)
end

function Provider:OnHide()
    for _, pin in ipairs(self.pins or {}) do
        pin:OnMouseLeave()
        pin:SetScript("OnUpdate", nil)
    end
end

local function ValidPeer(peer)
    return peer and not IsSecret(peer.name) and type(peer.name) == "string" and peer.name ~= ""
        and MapID(peer.map) and Coordinate(peer.x) and Coordinate(peer.y)
end

function Provider:RefreshAllData(fromOnShow, incremental)
    local map = self:GetMap()
    if not map:IsShown() or not self.addon:GetShowPlayerIcons() then self:RemoveAllData(); return end
    if not self.pins then self.positions, self.pins, self.pinsBySender = {}, {}, {} end
    local mapID = map:GetMapID()
    -- Native map/art changes must reproject even when the numeric map ID is unchanged.
    local keepMotion = incremental and self.mapID == mapID
    self.mapID = mapID
    local now = GetTime()
    local peers = self.addon:GetSharedPositions()
    -- Release departed players first so their frames are available for new arrivals.
    for sender in pairs(self.pinsBySender) do
        if not ValidPeer(peers[sender]) then self:RemovePeer(sender) end
    end
    for sender, peer in pairs(peers) do
        if ValidPeer(peer) then
            local pin, previous = self.pinsBySender[sender], keepMotion and self.positions[sender]
            local sameCoordinates = previous and previous.sourceMap == peer.map
                and previous.sourceX == peer.x and previous.sourceY == peer.y
            local x, y
            if sameCoordinates then x, y = previous.x, previous.y
            else x, y = PositionOnMap(peer, mapID) end
            if x then
                local class = not IsSecret(peer.class) and type(peer.class) == "string" and peer.class or nil
                if pin and sameCoordinates and previous.name == peer.name and previous.online == (peer.online == true)
                    and pin.playerClass == class then
                    -- New status snapshots can replace the peer table without moving its pin.
                    pin.positionPeer = peer
                else
                    local motion = NewMotion(peer, mapID, x, y, previous, now)
                    self.positions[sender] = motion
                    if pin then
                        pin:UpdatePeer(peer.name, x, y, peer.online, class, motion, peer)
                    else
                        pin = map:AcquirePin(PIN_TEMPLATE, peer.name, x, y, peer.online, class, motion, self, sender, peer)
                        self.pins[#self.pins + 1] = pin
                        pin.providerIndex = #self.pins
                        self.pinsBySender[sender] = pin
                    end
                end
            elseif pin then
                self:RemovePeer(sender)
            end
        end
    end
end

function addon:RefreshPositionPins()
    if self.positionMapProvider then self.positionMapProvider:RefreshAllData(false, true) end
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
