local _, addon = ...
local PIN_TEMPLATE = "LockInToolsPositionPinTemplate"
local CLASS_TEXTURE = "Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES"
local INTERPOLATION_SECONDS, MAX_INTERPOLATION_DISTANCE = 2, 0.1
local TRAIL_SAMPLE_SECONDS, TRAIL_DRAW_SECONDS, MAX_TRAIL_POINTS = 0.5, 0.05, 64
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
            motion.trail = previous.trail
            -- Metadata and other peers can refresh the map without a new target.
            if previous.x == x and previous.y == y then return previous end
            motion.fromX, motion.fromY = DisplayPosition(previous, now)
            if motion.fromX ~= x or motion.fromY ~= y then motion.started = now end
        end
    end
    return motion
end

local function HideTrailLines(pin, first)
    if not first then pin.trailHeadLine = nil end
    for index = first or 1, #(pin.trailLines or {}) do
        pin.trailLines[index]:Hide()
        pin.trailLines[index]:ClearAllPoints()
    end
end

local function AppendTrailPoint(trail, point)
    local last = trail.points[#trail.points]
    if last and last.x == point.x and last.y == point.y then
        trail.points[#trail.points] = point
    else
        trail.points[#trail.points + 1] = point
    end
    if #trail.points > MAX_TRAIL_POINTS then table.remove(trail.points, 1) end
    trail.lastSampleAt = point.at
end

function Pin:UpdateTrail(x, y, now)
    local trail, canvas = self.motion.trail, self.trailCanvas
    if not trail or not canvas then HideTrailLines(self); return false end
    local headChanged = false
    if not trail.head or (self.motion.started == now and trail.motionStarted ~= now) then
        -- A fresh movement starts at the displayed point, including after a pause.
        trail.head = { x = x, y = y, at = now }
        AppendTrailPoint(trail, trail.head)
        trail.motionStarted = self.motion.started
        headChanged = true
    elseif trail.head.x ~= x or trail.head.y ~= y then
        trail.head = { x = x, y = y, at = now }
        headChanged = true
        if now - trail.lastSampleAt >= TRAIL_SAMPLE_SECONDS then AppendTrailPoint(trail, trail.head) end
    end
    local cutoff = now - self.trailLength
    while trail.points[1] and trail.points[1].at <= cutoff do table.remove(trail.points, 1) end
    local head, points = trail.head, trail.points
    local last = points[#points]
    local active = #points > 1 or (last and head.at > cutoff and (last.x ~= head.x or last.y ~= head.y))
    if not active then HideTrailLines(self); return false end
    if self.lastTrailDraw and now - self.lastTrailDraw < TRAIL_DRAW_SECONDS then
        -- Keep the head attached every frame; older geometry and fading need less work.
        if headChanged and self.trailHeadLine then
            self.trailHeadLine:SetEndPoint("TOPLEFT", canvas, x * self.trailWidth, -y * self.trailHeight)
        end
        return true
    end
    self.lastTrailDraw = now

    local width, height = canvas:GetWidth(), canvas:GetHeight()
    if not Number(width) or not Number(height) or width <= 0 or height <= 0 then
        HideTrailLines(self)
        return true
    end
    self.trailWidth, self.trailHeight = width, height
    local scale = self.trailMap.GetCanvasScale and self.trailMap:GetCanvasScale() or 1
    if not Number(scale) or scale <= 0 then scale = 1 end
    local used = 0
    local function DrawSegment(a, b)
        if a.x == b.x and a.y == b.y then return end
        used = used + 1
        local line = self.trailLines[used]
        if not line then
            line = canvas:CreateLine(nil, "ARTWORK")
            self.trailLines[used] = line
        end
        line:SetColorTexture(0.1, 0.8, 1, 1)
        line:SetAlpha(0.65 * math.max(0, 1 - (now - a.at) / self.trailLength))
        line:SetThickness(2 / scale)
        line:ClearAllPoints()
        line:SetStartPoint("TOPLEFT", canvas, a.x * width, -a.y * height)
        line:SetEndPoint("TOPLEFT", canvas, b.x * width, -b.y * height)
        line:Show()
    end
    for index = 2, #points do DrawSegment(points[index - 1], points[index]) end
    if last and head.at > cutoff then DrawSegment(last, head) end
    HideTrailLines(self, used + 1)
    self.trailHeadLine = self.trailLines[used]
    return true
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
    self.trailLines = {}
    self:SetScalingLimits(1, 1, 1)
    self:SetIgnoreGlobalPinScale(true)
    self:UseFrameLevelType("PIN_FRAME_LEVEL_GROUP_MEMBER")
end

function Pin:OnAcquired(name, x, y, online, class, motion, trailMap, trailCanvas, trailLength)
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
    if trailCanvas and self.trailLineCanvas ~= trailCanvas then
        HideTrailLines(self)
        self.trailLines = {}
        self.trailLineCanvas = trailCanvas
    end
    self.trailMap, self.trailCanvas, self.trailLength = trailMap, trailCanvas, trailLength
    self.lastTrailDraw = nil
    if motion then
        self:SetScript("OnUpdate", self.OnUpdate)
        self:OnUpdate()
    else
        self:SetPosition(x, y)
    end
end

function Pin:OnUpdate()
    local now = GetTime()
    local x, y, moving = DisplayPosition(self.motion, now)
    self:SetPosition(x, y)
    local trailActive = self:UpdateTrail(x, y, now)
    if not moving and not trailActive then self:SetScript("OnUpdate", nil) end
end

function Pin:OnReleased()
    self:SetScript("OnUpdate", nil)
    HideTrailLines(self)
    self.motion = nil
    self.trailMap, self.trailCanvas, self.trailLength, self.lastTrailDraw = nil, nil, nil, nil
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
    local showTrails, trailLength = self.addon:GetPositionTrailSettings()
    local canvas = showTrails and map.GetCanvas and map:GetCanvas()
    if not canvas or not canvas.CreateLine then canvas = nil end
    local now = GetTime()
    for sender, peer in pairs(self.addon:GetSharedPositions()) do
        if not IsSecret(peer.name) and type(peer.name) == "string" and peer.name ~= "" then
            local x, y = PositionOnMap(peer, mapID)
            if x then
                local motion = NewMotion(peer, mapID, x, y, previous and previous[sender], now)
                if canvas and peer.online == true then
                    motion.trail = motion.trail or { points = {} }
                else
                    motion.trail = nil
                end
                self.positions[sender] = motion
                map:AcquirePin(PIN_TEMPLATE, peer.name, x, y, peer.online, peer.class, motion, map, canvas, trailLength)
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
