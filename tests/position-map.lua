-- Native MapCanvas callback contracts are mocked; rendering needs in-game checks.
local function Mix(...)
    local result = {}
    for index = 1, select("#", ...) do
        for key, value in pairs(select(index, ...)) do result[key] = value end
    end
    return result
end

local function Mixin(target, ...)
    for index = 1, select("#", ...) do
        for key, value in pairs(select(index, ...)) do target[key] = value end
    end
    return target
end

local function Vector(x, y)
    return { x = x, y = y, GetXY = function(self) return self.x, self.y end }
end

local function LoadMap()
    local addon = { positions = {} }
    function addon:GetSharedPositions() return self.positions end
    local world = {
        frames = {}, added = 0, created = 0, released = 0, rectangles = {},
        bounds = {}, secretValues = {}, worldConversions = 0, mapConversions = 0,
    }
    local environment = setmetatable({
        CreateFromMixins = Mix,
        Mixin = Mixin,
        CreateVector2D = Vector,
        issecretvalue = function(value) return world.secretValues[value] == true end,
        C_Map = { GetMapRectOnMap = function(source, target)
            local rectangle = world.rectangles[source .. ":" .. target]
            if rectangle then return unpack(rectangle) end
        end,
        GetWorldPosFromMapPos = function(source, position)
            world.worldConversions = world.worldConversions + 1
            local bounds = world.bounds[source]
            if bounds then
                local x, y = position:GetXY()
                return bounds.continent, Vector(bounds[1] + x * (bounds[2] - bounds[1]),
                    bounds[3] + y * (bounds[4] - bounds[3]))
            end
        end,
        GetMapPosFromWorldPos = function(continent, position, target)
            world.mapConversions = world.mapConversions + 1
            local bounds = world.bounds[target]
            if bounds and bounds.continent == continent then
                local x, y = position:GetXY()
                return target, Vector((x - bounds[1]) / (bounds[2] - bounds[1]),
                    (y - bounds[3]) / (bounds[4] - bounds[3]))
            end
        end },
        CreateFrame = function(frameType)
            assert(frameType == "Frame")
            local frame = { events = {} }
            function frame:RegisterEvent(event) self.events[event] = true end
            function frame:UnregisterEvent(event) self.events[event] = nil end
            function frame:SetScript(script, callback)
                assert(script == "OnEvent")
                self.callback = callback
            end
            world.frames[#world.frames + 1] = frame
            return frame
        end,
    }, { __index = _G })
    world.environment, world.mapAPI = environment, environment.C_Map
    local chunk = assert(loadfile("PositionMap.lua"))
    setfenv(chunk, environment)
    chunk("LockInTools", addon)
    -- Simulate a virtual template retaining its mixin table before map load.
    world.templateMixin = assert(environment.LockInToolsPositionPinMixin)

    function world:loadNativeMap(shown)
        environment.MapCanvasDataProviderMixin = {
            OnAdded = function(self, map) self.owningMap = map end,
            GetMap = function(self) return self.owningMap end,
            OnMapChanged = function(self) self:RefreshAllData() end,
        }
        environment.MapCanvasPinMixin = {
            SetOwningMap = function(self, map) self.owningMap = map end,
            SetPosition = function(self, x, y) self.x, self.y = x, y end,
            SetScalingLimits = function() end,
            SetIgnoreGlobalPinScale = function() end,
            UseFrameLevelType = function(_, level) assert(level == "PIN_FRAME_LEVEL_GROUP_MEMBER") end,
            OnReleased = function() world.released = world.released + 1 end,
        }
        local map = { shown = shown, id = 101, pins = {}, pool = {}, unrelatedPin = {} }
        function map:IsShown() return self.shown end
        function map:GetMapID() return self.id end
        function map:AddDataProvider(provider)
            world.added = world.added + 1
            self.provider = provider
            provider:OnAdded(self)
        end
        function map:RemoveAllPinsByTemplate(template)
            assert(template == "LockInToolsPositionPinTemplate", "remove only LockInTools pins")
            for _, pin in ipairs(self.pins) do
                pin:OnReleased()
                assert(pin.playerName == nil and pin.online == nil and pin.Label.text == "",
                    "release clears player state before returning the pin to the native pool")
                self.pool[#self.pool + 1] = pin
            end
            self.pins = {}
        end
        function map:AcquirePin(template, ...)
            assert(template == "LockInToolsPositionPinTemplate")
            -- Native AcquirePin expects every mixin method before it calls OnLoad.
            assert(environment.LockInToolsPositionPinMixin == world.templateMixin)
            local pin = table.remove(self.pool)
            if not pin then
                pin = Mix(world.templateMixin)
                pin.Label = {
                    SetText = function(self, text) self.text = text end,
                    SetTextColor = function(self, ...) self.color = { ... } end,
                }
                pin.Icon = { SetColorTexture = function(self, ...) self.color = { ... } end }
                pin:OnLoad()
                world.created = world.created + 1
            end
            pin:SetOwningMap(self)
            pin:OnAcquired(...)
            self.pins[#self.pins + 1] = pin
            return pin
        end
        function map:show()
            self.shown = true
            self.provider:RefreshAllData(true)
        end
        function map:changeMap(mapID)
            self.id = mapID
            self.provider:OnMapChanged()
        end
        self.map = map
        environment.WorldMapFrame = map
    end

    function world:fire(event, name)
        for _, frame in ipairs(self.frames) do
            if frame.events[event] then frame.callback(frame, event, name) end
        end
    end
    return addon, world
end

local function Near(actual, expected)
    assert(math.abs(actual - expected) < 0.000001)
end

local addon, world = LoadMap()
addon.positions.alice = { name = "Alice-Realm", map = 101, x = 0.25, y = 0.5 }
addon:InitializePositionMap()
addon:InitializePositionMap()
assert(#world.frames == 1 and world.added == 0, "wait for native map without duplicate event frames")
world:fire("ADDON_LOADED", "UnrelatedAddon")
assert(world.added == 0)
world:loadNativeMap(false)
world:fire("ADDON_LOADED", "Blizzard_WorldMap")
assert(world.added == 1 and #world.map.pins == 0, "attach while hidden without creating pins")
assert(not world.frames[1].events.ADDON_LOADED, "release the late-load event when attached")
addon:InitializePositionMap()
assert(world.added == 1, "attach the provider only once")

world.map:show()
assert(#world.map.pins == 1, "opening the map displays an existing retained position")
local pin = world.map.pins[1]
assert(pin.Label.text == "Alice-Realm (Offline)" and pin:GetDisplayName() == "Alice-Realm",
    "retained coordinates show offline until fresh data arrives without changing the native display name")
Near(pin.x, 0.25)
Near(pin.y, 0.5)

world.rectangles["101:100"] = { 0.1, 0.5, 0.2, 0.6 }
addon.positions.bob = { name = "Bob-Realm", map = 999, x = 0.5, y = 0.5 }
world.map:changeMap(100)
assert(#world.map.pins == 1, "omit unrelated maps while projecting a child map onto its parent")
Near(world.map.pins[1].x, 0.2)
Near(world.map.pins[1].y, 0.4)
Near(addon.positions.alice.x, 0.25)
assert(world.released == 1 and world.map.unrelatedPin, "release old pins through the native base without changing other providers")

world.rectangles["102:100"] = { 0.9, 1.3, 0.1, 0.2 }
addon.positions.outside = { name = "Outside-Realm", map = 102, x = 1, y = 0.5 }
addon.positions.invalid = { name = "Invalid-Realm", map = 100, x = 0 / 0, y = 0.5 }
addon.positions.alice.x = 0.75
addon:RefreshPositionPins()
assert(#world.map.pins == 1, "new data replaces existing pins and omits off-map or invalid coordinates")
Near(world.map.pins[1].x, 0.4)
assert(world.map.pins[1] == pin, "native pool reuses the released pin")

addon.positions = {}
addon:RefreshPositionPins()
assert(#world.map.pins == 0, "an empty visible model removes pins after disabling or changing group")
addon.positions.alice = { name = "Alice-Realm", map = 101, x = 0.25, y = 0.5 }
world.map.shown = false
local before = world.created
addon:RefreshPositionPins()
assert(world.created == before, "updates while the map is closed do not allocate pins")
world.map:show()
assert(#world.map.pins == 1, "reopening restores the current model without waiting for a new update")

local early, earlyWorld = LoadMap()
earlyWorld:loadNativeMap(true)
early.positions.alice = { name = "Alice-Realm", map = 101, x = 0.25, y = 0.5 }
early:InitializePositionMap()
assert(earlyWorld.added == 1 and #earlyWorld.map.pins == 1 and #earlyWorld.frames == 0,
    "an already loaded world map refreshes immediately without a late-load event")

local presence, presenceWorld = LoadMap()
presenceWorld:loadNativeMap(true)
presence.positions.alice = { name = "Alice-Realm", map = 101, x = 0.25, y = 0.5 }
presence:InitializePositionMap()
local presencePin = presenceWorld.map.pins[1]
assert(presencePin.Label.text == "Alice-Realm (Offline)" and presencePin.online == nil)
Near(presencePin.Icon.color[1], 0.5)
Near(presencePin.Icon.color[4], 0.6)
Near(presencePin.Label.color[1], 0.6)

presence.positions.alice.online = false
presence:RefreshPositionPins()
assert(presenceWorld.map.pins[1] == presencePin and presenceWorld.created == 1,
    "presence changes refresh an existing native pooled pin")
assert(presencePin.Label.text == "Alice-Realm (Offline)" and presencePin.online == false,
    "timed-out peers show offline")
assert(presencePin:GetDisplayName() == "Alice-Realm", "native player actions keep the real player name")
Near(presencePin.Icon.color[1], 0.5)
Near(presencePin.Icon.color[4], 0.6)

presence.positions.alice.online = true
presence:RefreshPositionPins()
assert(presencePin.Label.text == "Alice-Realm" and presencePin.online == true,
    "a new update restores the online label on a pooled pin")
Near(presencePin.Icon.color[1], 0.1)
Near(presencePin.Icon.color[2], 0.8)
Near(presencePin.Icon.color[3], 1)
Near(presencePin.Icon.color[4], 1)
Near(presencePin.Label.color[1], 1)

presence.positions = { bob = { name = "Bob-Realm", map = 101, x = 0.5, y = 0.5 } }
presence:RefreshPositionPins()
assert(presenceWorld.map.pins[1] == presencePin and presencePin.online == nil)
assert(presencePin.Label.text == "Bob-Realm (Offline)" and presencePin:GetDisplayName() == "Bob-Realm",
    "a pooled pin replaces the previous name and online status with an offline retained position")
Near(presencePin.Icon.color[1], 0.5)
Near(presencePin.Icon.color[4], 0.6)
Near(presencePin.Label.color[1], 0.6)
presence.positions = {}
presence:RefreshPositionPins()
assert(#presenceWorld.map.pins == 0 and presenceWorld.released == 4)
assert(presencePin.playerName == nil and presencePin.online == nil and presencePin.Label.text == "")

local projection, projectionWorld = LoadMap()
-- Synthetic geometry for Thunder Bluff, Mulgore, Kalimdor and a different continent.
projectionWorld.bounds[1456] = { 1000, 1400, 4000, 4600, continent = 1 }
projectionWorld.bounds[1412] = { 500, 2500, 2000, 6000, continent = 1 }
projectionWorld.bounds[1414] = { -5000, 5000, -4000, 8000, continent = 1 }
projectionWorld.bounds[13] = { -5000, 5000, -4000, 8000, continent = 2 }
projectionWorld:loadNativeMap(true)
projectionWorld.map.id = 1456
local shared = { name = "Alice-Realm", map = 1456, x = 0.25, y = 0.5 }
projection.positions.alice = shared
projection:InitializePositionMap()
Near(projectionWorld.map.pins[1].x, 0.25)
Near(projectionWorld.map.pins[1].y, 0.5)
assert(projectionWorld.worldConversions == 0, "own-map positions need no conversion")

projectionWorld.map:changeMap(1412)
assert(#projectionWorld.map.pins == 1, "city coordinates appear on the overlapping region without a direct rectangle")
Near(projectionWorld.map.pins[1].x, 0.3)
Near(projectionWorld.map.pins[1].y, 0.575)
assert(projectionWorld.worldConversions == 1 and projectionWorld.mapConversions == 1)

projectionWorld.rectangles["1456:1414"] = { 0.6, 0.64, 2 / 3, 43 / 60 }
projectionWorld.map:changeMap(1414)
Near(projectionWorld.map.pins[1].x, 0.61)
Near(projectionWorld.map.pins[1].y, 83 / 120)
assert(projectionWorld.worldConversions == 1, "native rectangle projection stays preferred")
projectionWorld.map:changeMap(1456)
Near(projectionWorld.map.pins[1].x, 0.25)
Near(projectionWorld.map.pins[1].y, 0.5)
Near(shared.x, 0.25)
Near(shared.y, 0.5)
assert(shared.map == 1456 and projectionWorld.worldConversions == 1, "map switches preserve shared source coordinates")

projectionWorld.rectangles["1456:1412"] = { 0, 0, 0, 0 }
projectionWorld.map:changeMap(1412)
Near(projectionWorld.map.pins[1].x, 0.3)
Near(projectionWorld.map.pins[1].y, 0.575)
assert(projectionWorld.worldConversions == 2, "a degenerate native rectangle falls back to world coordinates")
shared.map, shared.x, shared.y = 1412, 0.3, 0.575
projectionWorld.map:changeMap(1456)
Near(projectionWorld.map.pins[1].x, 0.25)
Near(projectionWorld.map.pins[1].y, 0.5)
shared.x, shared.y = 0.9, 0.9
projection:RefreshPositionPins()
assert(#projectionWorld.map.pins == 0, "region positions outside the city remain hidden")
shared.map, shared.x, shared.y = 1456, 0.25, 0.5
projectionWorld.map:changeMap(13)
assert(#projectionWorld.map.pins == 0, "world conversion does not project onto another continent")

local api = projectionWorld.mapAPI
local toWorld, toMap, rectangle = api.GetWorldPosFromMapPos, api.GetMapPosFromWorldPos, api.GetMapRectOnMap
api.GetMapRectOnMap = nil
projectionWorld.map:changeMap(1412)
Near(projectionWorld.map.pins[1].x, 0.3)
Near(projectionWorld.map.pins[1].y, 0.575)
assert(#projectionWorld.map.pins == 1, "world conversion works when the rectangle API is absent")

api.GetMapPosFromWorldPos = function() return 1456, Vector(0.3, 0.575) end
projection:RefreshPositionPins()
assert(#projectionWorld.map.pins == 0, "a converted position must belong to the displayed map")
api.GetMapPosFromWorldPos = function() return nil end
projection:RefreshPositionPins()
assert(#projectionWorld.map.pins == 0, "missing converted positions remain hidden")
local secret = {}
projectionWorld.secretValues[secret] = true
for _, point in ipairs({ Vector(-0.1, 0.5), Vector(0.5, 1.1), Vector(0 / 0, 0.5),
    Vector(secret, 0.5), Vector(0.5, secret), Vector(nil, 0.5) }) do
    api.GetMapPosFromWorldPos = function() return 1412, point end
    projection:RefreshPositionPins()
    assert(#projectionWorld.map.pins == 0, "invalid or secret converted coordinates remain hidden")
end
api.GetMapPosFromWorldPos = function() return secret, Vector(0.3, 0.575) end
projection:RefreshPositionPins()
assert(#projectionWorld.map.pins == 0, "secret converted map IDs remain hidden")
api.GetMapPosFromWorldPos = toMap
for _, result in ipairs({ {}, { 1 }, { secret, Vector(1100, 4300) }, { 1, secret } }) do
    api.GetWorldPosFromMapPos = function() return unpack(result) end
    projection:RefreshPositionPins()
    assert(#projectionWorld.map.pins == 0, "missing or secret world conversion results remain hidden")
end
api.GetWorldPosFromMapPos = toWorld

for _, missing in ipairs({ "GetWorldPosFromMapPos", "GetMapPosFromWorldPos" }) do
    local original = api[missing]
    api[missing] = nil
    projection:RefreshPositionPins()
    assert(#projectionWorld.map.pins == 0, "optional conversion APIs may be unavailable")
    api[missing] = original
end
projectionWorld.environment.CreateVector2D = nil
projection:RefreshPositionPins()
assert(#projectionWorld.map.pins == 0, "a missing vector constructor disables conversion safely")
projectionWorld.environment.CreateVector2D = Vector
api.GetMapRectOnMap = rectangle

for _, invalidID in ipairs({ 0, -1, 1.5, math.huge, secret, false }) do
    local beforeConversions = projectionWorld.worldConversions
    shared.map = invalidID
    projection:RefreshPositionPins()
    assert(#projectionWorld.map.pins == 0, "invalid source map IDs remain hidden")
    shared.map = 1456
    projectionWorld.map:changeMap(invalidID)
    assert(#projectionWorld.map.pins == 0, "invalid target map IDs remain hidden")
    assert(projectionWorld.worldConversions == beforeConversions, "validate IDs before calling native conversion APIs")
    projectionWorld.map.id = 1412
end
shared.map = nil
projection:RefreshPositionPins()
assert(#projectionWorld.map.pins == 0, "a missing source map remains hidden")
projectionWorld.map:changeMap(nil)
assert(#projectionWorld.map.pins == 0, "missing source and target maps cannot match as an own-map position")
shared.map = 1456
projection:RefreshPositionPins()
assert(#projectionWorld.map.pins == 0, "a missing displayed map remains hidden")

projectionWorld.bounds[1456].continent = 0
projectionWorld.bounds[1412].continent = 0
projectionWorld.map:changeMap(1412)
assert(#projectionWorld.map.pins == 1, "world continent ID zero is valid")
Near(projectionWorld.map.pins[1].x, 0.3)
Near(projectionWorld.map.pins[1].y, 0.575)

print("PASS: native map attachment, presence labels/colors, parent/overlapping-map projection and pooled pin lifecycle")
