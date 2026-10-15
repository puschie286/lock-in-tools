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

local function LoadMap()
    local addon = { positions = {} }
    function addon:GetSharedPositions() return self.positions end
    local world = { frames = {}, added = 0, created = 0, released = 0, rectangles = {} }
    local environment = setmetatable({
        CreateFromMixins = Mix,
        Mixin = Mixin,
        C_Map = { GetMapRectOnMap = function(source, target)
            local rectangle = world.rectangles[source .. ":" .. target]
            if rectangle then return unpack(rectangle) end
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

print("PASS: native map attachment, presence labels/colors, parent-map projection and pooled pin lifecycle")
