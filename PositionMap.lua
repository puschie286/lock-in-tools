local _, addon = ...
local PIN_TEMPLATE = "LockInToolsPositionPinTemplate"
local DEATH_PIN_TEMPLATE = "LockInToolsDeathPinTemplate"
local DOT_TEXTURE = "Interface\\AddOns\\LockInTools\\Media\\PositionDot"
local RING_TEXTURE = "Interface\\AddOns\\LockInTools\\Media\\PositionRing"
local DOT_RADIUS, TOOLTIP_INTERVAL = 6, 0.1
local INTERPOLATION_SECONDS, MAX_INTERPOLATION_DISTANCE = 2, 0.1
local Provider, Pin, DeathPin = {}, {}, {}
local deathLocations = {}
LockInToolsPositionPinMixin = {}
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

local function NativeValue(callback, ...)
    if type(callback) ~= "function" then return nil end
    local ok, value = pcall(callback, ...)
    if ok and not IsSecret(value) then return value end
end

local function NativeMarkerCategories(map, mapID)
    if type(map.EnumeratePinsByTemplate) ~= "function" then return false, false end
    local ok, party, raid = pcall(function()
        for pin in map:EnumeratePinsByTemplate("GroupMembersPinTemplate") do
            local provider = pin.dataProvider
            if NativeValue(pin.IsShown, pin) == true and NativeValue(pin.GetUiMapID, pin) == mapID
                and provider then
                return NativeValue(provider.ShouldShowUnit, provider, "party") == true,
                    NativeValue(provider.ShouldShowUnit, provider, "raid") == true
            end
        end
    end)
    party, raid = ok and party == true, ok and raid == true
    -- Battleground markers may classify units using the home party rather than
    -- the active raid. With differing filters, preserve our fallback instead of
    -- guessing which native appearance applies (including unknown PvP state).
    if party ~= raid and NativeValue(C_PvP and C_PvP.IsActiveBattlefield) ~= false then return false, false end
    return party, raid
end

local function HasNativeMarker(unit, party, raid)
    -- Native rendering owns group markers; only suppress our pin when its frame,
    -- filter and connected unit are available. GetPlayerMapPosition is not a
    -- renderer visibility API: it can return nil for raid units or the underlying
    -- map of a stitched view even while that view draws the group member.
    if not (party or raid) or NativeValue(UnitIsConnected, unit) ~= true then return false end
    local subgroup = NativeValue(UnitInSubgroup, unit)
    if type(subgroup) ~= "boolean" then return false end
    if subgroup then
        if not party then return false end
    else
        if not raid then return false end
    end
    return true
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

local function NativeDeathPosition(unit)
    local map = NativeValue(C_Map and C_Map.GetBestMapForUnit, unit)
    if not MapID(map) then return nil end
    local position = NativeValue(C_Map.GetPlayerMapPosition, map, unit)
    if not position then return nil end
    local ok, x, y = pcall(function() return position:GetXY() end)
    if ok and Coordinate(x) and Coordinate(y) then return { map = map, x = x, y = y } end
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
        local position = NativeDeathPosition(unit)
        if not position then return end
        position.name = self:GetPlayerDisplayName(name)
        deathLocations[id] = position
    end
    if self.positionMapProvider then self.positionMapProvider:RefreshDeathPins() end
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
    if changed and self.positionMapProvider then self.positionMapProvider:RefreshDeathPins() end
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
    if changed and self.positionMapProvider then self.positionMapProvider:RefreshDeathPins() end
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
        local editable = self.initialized and not self.savedDataReadOnly
        local playerIcons = rootDescription:CreateCheckbox("Show player icons", function()
            return self:GetShowPlayerIcons()
        end, function()
            self:SetShowPlayerIcons(not self:GetShowPlayerIcons())
        end)
        playerIcons:SetEnabled(editable)
        local deathMarkers = rootDescription:CreateCheckbox("Show death markers", function()
            return self:GetShowDeathMarkers()
        end, function()
            self:SetShowDeathMarkers(not self:GetShowDeathMarkers())
        end)
        deathMarkers:SetEnabled(editable)
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
    if not self.playerName or not GameTooltip or not self:GetMap():IsShown() then return end
    GameTooltip_SetDefaultAnchor(GameTooltip, self)
    GameTooltip:SetText(self.playerName, 1, 0, 0)
    GameTooltip:Show()
end

function DeathPin:OnMouseLeave()
    if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
end

function DeathPin:OnReleased()
    self:OnMouseLeave()
    self.playerName = nil
    MapCanvasPinMixin.OnReleased(self)
end

function Provider:OnAdded(map)
    MapCanvasDataProviderMixin.OnAdded(self, map)
    if map.RegisterDataProviderOnUpdate then map:RegisterDataProviderOnUpdate(self) end
end

function Provider:OnRemoved(map)
    if map.UnregisterDataProviderOnUpdate then map:UnregisterDataProviderOnUpdate(self) end
    if self.addon.positionMapProvider == self then self.addon.positionMapProvider = nil end
    MapCanvasDataProviderMixin.OnRemoved(self, map)
end

function Provider:OnUpdate()
    local now = GetTime()
    if self.hasGroupedPeers and self:GetMap():IsShown() and self.addon:GetShowPlayerIcons()
        and (not self.nativeCheckedAt or now < self.nativeCheckedAt or now - self.nativeCheckedAt >= 1) then
        -- Native availability can change while everybody is stationary. Avoid
        -- a per-peer frame callback or rebuilding the membership cache here.
        self.nativeCheckedAt = now
        self:RefreshAllData(false, true)
    end
end

function Provider:RemovePositionPins()
    self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE)
    self.positions, self.pins, self.pinsBySender = {}, {}, {}
    self.unmapped = {}
    self.nativeMarkers = {}
    self.hasGroupedPeers, self.nativeCheckedAt = nil, nil
end

function Provider:RemoveAllData()
    self:RemovePositionPins()
    self:GetMap():RemoveAllPinsByTemplate(DEATH_PIN_TEMPLATE)
    self.mapID = nil
end

function Provider:RefreshDeathPins()
    local map = self:GetMap()
    map:RemoveAllPinsByTemplate(DEATH_PIN_TEMPLATE)
    if not map:IsShown() or not self.addon:GetShowDeathMarkers() then return end
    local mapID = map:GetMapID()
    for _, position in pairs(deathLocations) do
        local ok, x, y = pcall(PositionOnMap, position, mapID)
        if ok and x then map:AcquirePin(DEATH_PIN_TEMPLATE, x, y, position.name) end
    end
end

function Provider:HasNativeMarker(peer, unit, party, raid, now)
    -- Contact-only updates must restore retained/offline pins immediately, even
    -- while native unit availability is cached for a busy raid's receives.
    if peer.online ~= true or peer.positionAvailable == false then return false end
    local cached = self.nativeMarkers[unit]
    if cached and cached.party == party and cached.raid == raid
        and now >= cached.at and now - cached.at < 1 then return cached.visible end
    local visible = HasNativeMarker(unit, party, raid)
    self.nativeMarkers[unit] = { at = now, visible = visible, party = party, raid = raid }
    return visible
end

function Provider:RemovePeer(sender)
    self.positions[sender] = nil
    self.unmapped[sender] = nil
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
    self:GetMap():RemoveAllPinsByTemplate(DEATH_PIN_TEMPLATE)
end

local function ValidPeer(peer)
    return peer and not IsSecret(peer.name) and type(peer.name) == "string" and peer.name ~= ""
        and MapID(peer.map) and Coordinate(peer.x) and Coordinate(peer.y)
end

local function MapOpener()
    if C_Map and type(C_Map.OpenWorldMap) == "function" then return C_Map.OpenWorldMap end
    if type(OpenWorldMap) == "function" then return OpenWorldMap end
end

function addon:GetPlayerMapActionState(id)
    if not ValidPeer(self:GetSharedPositions()[id]) then
        return false, "No shared location is available for this player."
    end
    if not self:GetShowPlayerIcons() then
        return false, "Enable 'Show player icons' in the world map filter first."
    end
    if not MapOpener() then return false, "The world map is unavailable in this client." end
    return true
end

function addon:ShowPlayerOnMap(id)
    local allowed, reason = self:GetPlayerMapActionState(id)
    if not allowed then return false, reason end
    -- Resolve again at click time; a menu can outlive its captured roster row.
    local position = self:GetSharedPositions()[id]
    local mapID = position.map
    local ok = pcall(MapOpener(), mapID)
    local map = WorldMapFrame
    if not ok or not map or NativeValue(map.IsShown, map) ~= true
        or NativeValue(map.GetMapID, map) ~= mapID then
        return false, "Could not show this location. Open the world map and try again."
    end
    ok = pcall(function()
        -- Bypass scale-ratio interpolation so unchanged zoom still replaces the old pan.
        map:InstantPanAndZoom(map:GetCanvasScale(), position.x, position.y, true)
    end)
    if not ok then return false, "Could not bring this player into view. Open the world map and try again." end
    return true
end

function Provider:RefreshAllData(fromOnShow, incremental)
    local map = self:GetMap()
    if not map:IsShown() then self:RemoveAllData(); return end
    local mapID = map:GetMapID()
    -- Native map/art changes must reproject even when the numeric map ID is unchanged.
    local keepMotion = incremental and self.mapID == mapID
    self.mapID = mapID
    if not keepMotion then self:RefreshDeathPins() end
    if not self.addon:GetShowPlayerIcons() then self:RemovePositionPins(); return end
    if not self.pins then self:RemovePositionPins() end
    if not keepMotion then self.unmapped, self.nativeMarkers = {}, {} end
    local now = GetTime()
    local party, raid
    local peers = {}
    self.hasGroupedPeers = false
    self.nativeCheckedAt = self.nativeCheckedAt or now
    for sender, peer in pairs(self.addon:GetSharedPositions()) do
        if ValidPeer(peer) then
            local unit = self.addon:GetNativeGroupUnit(peer.name)
            if unit then
                self.hasGroupedPeers = true
                if party == nil then party, raid = NativeMarkerCategories(map, mapID) end
            end
            if not unit or not self:HasNativeMarker(peer, unit, party, raid, now) then peers[sender] = peer end
        end
    end
    -- Release departed players first so their frames are available for new arrivals.
    for sender in pairs(self.pinsBySender) do
        if not peers[sender] then self:RemovePeer(sender) end
    end
    for sender in pairs(self.unmapped) do
        if not peers[sender] then self.unmapped[sender] = nil end
    end
    for sender, peer in pairs(peers) do
        local pin, previous = self.pinsBySender[sender], keepMotion and self.positions[sender]
        local sameCoordinates = previous and previous.sourceMap == peer.map
            and previous.sourceX == peer.x and previous.sourceY == peer.y
        local missing = self.unmapped[sender]
        -- Off-map/temporarily unavailable geometry should not be retried for
        -- every unrelated receive. Retry after a second or a native map refresh.
        local waitForMap = missing and missing.map == peer.map and missing.x == peer.x and missing.y == peer.y
            and now >= missing.at and now - missing.at < 1
        local x, y
        if sameCoordinates then x, y = previous.x, previous.y
        elseif not waitForMap then x, y = PositionOnMap(peer, mapID) end
        if x then
            self.unmapped[sender] = nil
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
        else
            if pin then self:RemovePeer(sender) end
            if not waitForMap then
                self.unmapped[sender] = { map = peer.map, x = peer.x, y = peer.y, at = now }
            end
        end
    end
end

function addon:RefreshPositionPins()
    if self.positionMapProvider then self.positionMapProvider:RefreshAllData(false, true) end
end

function addon:RefreshNativePositionPins()
    if self.positionMapProvider then self.positionMapProvider.nativeMarkers = {} end
    self:RefreshPositionPins()
end

for _, notification in ipairs({ "POSITIONS_CHANGED", "POSITION_CONTACT_CHANGED",
    "POSITION_VISIBILITY_CHANGED" }) do
    addon:RegisterNotification(notification, function() addon:RefreshPositionPins() end)
end
addon:RegisterNotification("DEATH_MARKER_VISIBILITY_CHANGED", function()
    if addon.positionMapProvider then addon.positionMapProvider:RefreshDeathPins() end
end)
addon:RegisterNotification("NATIVE_GROUP_CHANGED", function()
    PruneDeathLocations(addon)
    addon:RefreshNativePositionPins()
end)

function addon:InitializePositionMap()
    self:InitializeNativeGroupMembership()
    if not self.positionNativeEvents then
        self.positionNativeEvents = self:RegisterGameEvents({ "UNIT_CONNECTION", "ZONE_CHANGED_NEW_AREA" },
            function() self:RefreshNativePositionPins() end)
    end
    if not self.positionDeathEvents then
        self.positionDeathEvents = self:RegisterGameEvents({ "UNIT_FLAGS", "UNIT_HEALTH", "PLAYER_FLAGS_CHANGED",
            "UNIT_CONNECTION", "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT" }, OnDeathLocationEvent)
    end
    RegisterMapFilter(self)
    if not self.positionMapProvider and WorldMapFrame and WorldMapFrame.AddDataProvider
        and MapCanvasDataProviderMixin and MapCanvasPinMixin then
        -- Keep the XML mixin table stable when native map code loads later.
        Mixin(LockInToolsPositionPinMixin, MapCanvasPinMixin, Pin)
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
                self:InitializePositionMap()
            end
        end)
    end
end
