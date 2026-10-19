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
    local addon = {
        positions = {}, initialized = true, positionState = {},
        db = { position = { showPlayerIcons = true } },
    }
    local world = {
        frames = {}, added = 0, created = 0, released = 0, rectangles = {},
        bounds = {}, secretValues = {}, worldConversions = 0, mapConversions = 0, now = 0,
        menuModifiers = {}, menuRegistrations = 0,
    }
    local environment = setmetatable({
        CreateFromMixins = Mix,
        Mixin = Mixin,
        CreateVector2D = Vector,
        GetTime = function() return world.now end,
        Menu = { ModifyMenu = function(tag, callback)
            world.menuRegistrations = world.menuRegistrations + 1
            assert(not world.menuModifiers[tag], "register each menu modifier only once")
            world.menuModifiers[tag] = callback
        end },
        issecretvalue = function(value) return world.secretValues[value] == true end,
        CLASS_ICON_TCOORDS = {
            WARRIOR = { 0, 0.25, 0, 0.25 },
            MAGE = { 0.25, 0.5, 0, 0.25 },
        },
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
    for _, file in ipairs({ "Position.lua", "PositionMap.lua" }) do
        local chunk = assert(loadfile(file))
        setfenv(chunk, environment)
        chunk("LockInTools", addon)
    end
    function addon:GetSharedPositions() return self.positions end
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
                assert(pin:GetScript("OnUpdate") == nil, "released pins stop their animation callbacks")
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
                pin.scripts = {}
                function pin:SetScript(script, callback) self.scripts[script] = callback end
                function pin:GetScript(script) return self.scripts[script] end
                pin.Label = {
                    SetText = function(self, text) self.text = text end,
                    SetTextColor = function(self, ...) self.color = { ... } end,
                }
                pin.Icon = {
                    SetColorTexture = function(self, ...) self.color, self.texture = { ... }, nil end,
                    SetTexture = function(self, texture) self.texture, self.color = texture, nil end,
                    SetTexCoord = function(self, ...) self.coordinates = { ... } end,
                    SetVertexColor = function(self, ...) self.vertexColor = { ... } end,
                    SetDesaturated = function(self, value) self.desaturated = value end,
                    SetAlpha = function(self, alpha) self.alpha = alpha end,
                }
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
    function world:openMenu(tag)
        local root = { entries = { { kind = "native" } } }
        function root:CreateDivider() self.entries[#self.entries + 1] = { kind = "divider" } end
        function root:CreateTitle(text) self.entries[#self.entries + 1] = { kind = "title", text = text } end
        function root:CreateCheckbox(text, isSelected, toggle)
            local checkbox = { kind = "checkbox", text = text, IsSelected = isSelected, toggle = toggle }
            function checkbox:SetEnabled(enabled) self.enabled = enabled end
            function checkbox:Click() if self.enabled then self.toggle() end end
            self.entries[#self.entries + 1] = checkbox
            return checkbox
        end
        local modifier = self.menuModifiers[tag]
        if modifier then modifier({}, root) end
        return root.entries
    end
    function world:advance(seconds)
        self.now = self.now + seconds
        if self.map and self.map:IsShown() then
            for _, pin in ipairs(self.map.pins) do
                local update = pin:GetScript("OnUpdate")
                if update then update(pin, seconds) end
            end
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
assert(world.menuRegistrations == 1, "register the filter once before the world map loads")
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

local filtered, filterWorld = LoadMap()
filterWorld:loadNativeMap(true)
local filteredPeer = { name = "Alice-Realm", map = 101, x = 0.25, y = 0.5, online = true }
filtered.positions.alice = filteredPeer
filtered:InitializePositionMap()
local menu = filterWorld:openMenu("MENU_WORLD_MAP_TRACKING")
assert(#menu == 4 and menu[1].kind == "native" and menu[2].kind == "divider"
    and menu[3].text == "LockInTools", "append a distinct addon section without changing native filters")
local icons = menu[4]
assert(icons.text == "Show player icons" and icons:IsSelected() and icons.enabled,
    "the world-map filter reflects the default-enabled preference")
assert(#filterWorld:openMenu("MENU_MINIMAP_TRACKING") == 1, "leave other map menus alone")
filteredPeer.x = 0.3
filtered:RefreshPositionPins()
local filteredPin = filterWorld.map.pins[1]
assert(filteredPin:GetScript("OnUpdate"), "the pin is moving before being hidden")
icons:Click()
assert(not filtered.db.position.showPlayerIcons and not icons:IsSelected() and #filterWorld.map.pins == 0,
    "unchecking the filter saves the preference and hides pins immediately")
assert(filteredPin:GetScript("OnUpdate") == nil and next(filtered.positionMapProvider.positions) == nil,
    "hiding icons clears animated pins and cached motion")
local createdWhileFiltered = filterWorld.created
filteredPeer.x = 0.35
filtered:RefreshPositionPins()
filterWorld.map:changeMap(100)
filterWorld.map:changeMap(101)
filterWorld.map:show()
assert(#filterWorld.map.pins == 0 and filterWorld.created == createdWhileFiltered
    and filtered.positions.alice == filteredPeer, "hidden updates and map changes preserve the model without creating pins")
menu = filterWorld:openMenu("MENU_WORLD_MAP_TRACKING")
icons = menu[4]
assert(#menu == 4 and not icons:IsSelected(), "reopening has one checkbox with the current preference")
icons:Click()
assert(filtered.db.position.showPlayerIcons and #filterWorld.map.pins == 1 and filterWorld.map.unrelatedPin,
    "checking the filter immediately restores only addon pins")
Near(filterWorld.map.pins[1].x, 0.35)
assert(filterWorld.map.pins[1]:GetScript("OnUpdate") == nil, "restored pins snap to the latest received position")
filtered.savedDataReadOnly = true
icons = filterWorld:openMenu("MENU_WORLD_MAP_TRACKING")[4]
assert(not icons.enabled, "newer-schema settings disable the map checkbox")
icons:Click()
assert(filtered:GetShowPlayerIcons() and #filterWorld.map.pins == 1, "disabled checkbox preserves read-only settings")
filtered.savedDataReadOnly, filtered.initialized = false, false
assert(not filterWorld:openMenu("MENU_WORLD_MAP_TRACKING")[4].enabled, "disable the checkbox while settings are loading")

local delayedMenu, delayedMenuWorld = LoadMap()
local nativeMenu = delayedMenuWorld.environment.Menu
delayedMenuWorld.environment.Menu = nil
delayedMenuWorld:loadNativeMap(true)
delayedMenu:InitializePositionMap()
delayedMenu:InitializePositionMap()
assert(delayedMenuWorld.added == 1 and delayedMenuWorld.menuRegistrations == 0
    and #delayedMenuWorld.frames == 1, "missing menu APIs preserve the map provider and use one late-load listener")
delayedMenuWorld.environment.Menu = {}
delayedMenuWorld:fire("ADDON_LOADED", "Blizzard_Menu")
assert(delayedMenuWorld.menuRegistrations == 0, "an unavailable menu registration function is safe")
delayedMenuWorld.environment.Menu = nativeMenu
delayedMenuWorld:fire("ADDON_LOADED", "Blizzard_Menu")
assert(delayedMenuWorld.added == 1 and delayedMenuWorld.menuRegistrations == 1
    and not delayedMenuWorld.frames[1].events.ADDON_LOADED, "late menu loading registers without duplicating the existing provider")
delayedMenuWorld:fire("ADDON_LOADED", "Blizzard_Menu")
delayedMenu:InitializePositionMap()
assert(delayedMenuWorld.menuRegistrations == 1, "repeated initialization never duplicates menu entries")

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

local classes, classWorld = LoadMap()
classWorld:loadNativeMap(true)
classes.positions.alice = { name = "Alice-Realm", map = 101, x = 0.25, y = 0.5, online = true, class = "WARRIOR" }
classes:InitializePositionMap()
local classPin = classWorld.map.pins[1]
local classTexture = "Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES"
local function CheckClassIcon(class, online)
    assert(classWorld.map.pins[1] == classPin and classWorld.created == 1,
        "class and presence updates reuse a native pooled pin")
    assert(classPin.Icon.texture == classTexture and classPin.Icon.color == nil,
        "a known class uses the native class icon texture")
    for index = 1, 4 do
        Near(classPin.Icon.coordinates[index], classWorld.environment.CLASS_ICON_TCOORDS[class][index])
    end
    assert(classPin.Icon.desaturated == not online)
    Near(classPin.Icon.alpha, online and 1 or 0.6)
    for index = 1, 3 do Near(classPin.Icon.vertexColor[index], online and 1 or 0.6) end
end
local function CheckFallback(online)
    assert(classPin.Icon.texture == nil and classPin.Icon.color,
        "unknown classes retain the position square")
    local color = online and { 0.1, 0.8, 1, 1 } or { 0.5, 0.5, 0.5, 0.6 }
    for index = 1, 4 do Near(classPin.Icon.color[index], color[index]) end
    for index, value in ipairs({ 0, 1, 0, 1 }) do Near(classPin.Icon.coordinates[index], value) end
    assert(classPin.Icon.desaturated == false, "fallback squares do not retain class desaturation")
    Near(classPin.Icon.alpha, 1)
    for index = 1, 3 do Near(classPin.Icon.vertexColor[index], 1) end
end
CheckClassIcon("WARRIOR", true)
assert(classPin.Label.text == "Alice-Realm")

classes.positions = { bob = { name = "Bob-Realm", map = 101, x = 0.5, y = 0.5, online = false, class = "MAGE" } }
classes:RefreshPositionPins()
CheckClassIcon("MAGE", false)
assert(classPin.Label.text == "Bob-Realm (Offline)" and classPin:GetDisplayName() == "Bob-Realm",
    "a pooled pin replaces its class and name while retaining offline labels")
classes.positions.bob.online = true
classes:RefreshPositionPins()
CheckClassIcon("MAGE", true)
assert(classPin.Label.text == "Bob-Realm", "online class icons restore the normal label")

classes.positions.bob.online = false
classes:RefreshPositionPins()
CheckClassIcon("MAGE", false)
classes.positions.bob.class = nil
classes:RefreshPositionPins()
CheckFallback(false)
classes.positions.bob.online = true
classes:RefreshPositionPins()
CheckFallback(true)

local secretClass = {}
classWorld.secretValues[secretClass] = true
classWorld.secretValues.MAGE = true
for _, class in ipairs({ "UNKNOWN", "warrior", 1, false, {}, secretClass, "MAGE" }) do
    classes.positions.bob.class = class
    classes:RefreshPositionPins()
    CheckFallback(true)
end
classWorld.secretValues.MAGE = nil
classes.positions.bob.class = "MAGE"
classes:RefreshPositionPins()
CheckClassIcon("MAGE", true)
local nativeCoordinates = classWorld.environment.CLASS_ICON_TCOORDS
classWorld.environment.CLASS_ICON_TCOORDS = nil
classes:RefreshPositionPins()
CheckFallback(true)
classWorld.environment.CLASS_ICON_TCOORDS = nativeCoordinates
classes:RefreshPositionPins()
CheckClassIcon("MAGE", true)

local projection, projectionWorld = LoadMap()
-- Synthetic geometry for Thunder Bluff, Mulgore, Kalimdor and a different continent.
projectionWorld.bounds[1456] = { 1000, 1400, 4000, 4600, continent = 1 }
projectionWorld.bounds[1412] = { 500, 2500, 2000, 6000, continent = 1 }
projectionWorld.bounds[1414] = { -5000, 5000, -4000, 8000, continent = 1 }
projectionWorld.bounds[13] = { -5000, 5000, -4000, 8000, continent = 2 }
projectionWorld:loadNativeMap(true)
projectionWorld.map.id = 1456
local shared = { name = "Alice-Realm", map = 1456, x = 0.25, y = 0.5, online = true, class = "MAGE" }
projection.positions.alice = shared
projection:InitializePositionMap()
Near(projectionWorld.map.pins[1].x, 0.25)
Near(projectionWorld.map.pins[1].y, 0.5)
assert(projectionWorld.worldConversions == 0, "own-map positions need no conversion")

projectionWorld.map:changeMap(1412)
assert(#projectionWorld.map.pins == 1, "city coordinates appear on the overlapping region without a direct rectangle")
assert(projectionWorld.map.pins[1].Icon.texture == classTexture,
    "class icons remain available when projecting city positions onto the region")
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

local function FindPin(testWorld, name)
    for _, candidate in ipairs(testWorld.map.pins) do
        if candidate:GetDisplayName() == name then return candidate end
    end
    error("missing map pin for " .. name)
end

local smooth, smoothWorld = LoadMap()
smoothWorld:loadNativeMap(true)
local moving = { name = "Alice-Realm", map = 101, x = 0.2, y = 0.4, online = true }
smooth.positions.alice = moving
smooth:InitializePositionMap()
local movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.2)
Near(movingPin.y, 0.4)
assert(movingPin:GetScript("OnUpdate") == nil, "a first sample appears immediately without animation")

moving.x, moving.y = 0.24, 0.46
smooth:RefreshPositionPins()
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.2)
Near(movingPin.y, 0.4)
assert(movingPin:GetScript("OnUpdate"), "ordinary online movement installs an animation callback")
smoothWorld:advance(1)
Near(movingPin.x, 0.22)
Near(movingPin.y, 0.43)
Near(moving.x, 0.24)
Near(moving.y, 0.46)

moving.class = "MAGE"
smooth.positions.bob = { name = "Bob-Realm", map = 101, x = 0.8, y = 0.8, online = true }
smooth:RefreshPositionPins()
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.22)
Near(movingPin.y, 0.43)
assert(movingPin.Icon.texture == classTexture, "class changes update visuals during motion")
smoothWorld:advance(0.5)
Near(movingPin.x, 0.23)
Near(movingPin.y, 0.445)
assert(smoothWorld.created == 2, "refreshes reuse pooled pins while preserving each player's motion")

moving.x, moving.y = 0.28, 0.46
smooth:RefreshPositionPins()
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.23)
Near(movingPin.y, 0.445)
smoothWorld:advance(1)
Near(movingPin.x, 0.255)
Near(movingPin.y, 0.4525)
smoothWorld:advance(3)
Near(movingPin.x, 0.28)
Near(movingPin.y, 0.46)
assert(movingPin:GetScript("OnUpdate") == nil, "a long frame clamps to the new target and stops updating")

moving.x, moving.y = 0.32, 0.5
smooth:RefreshPositionPins()
smoothWorld:advance(0.5)
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.29)
Near(movingPin.y, 0.47)
smooth:RefreshPositionPins()
movingPin = FindPin(smoothWorld, moving.name)
smoothWorld:advance(1.5)
Near(movingPin.x, 0.32)
Near(movingPin.y, 0.5)
assert(movingPin:GetScript("OnUpdate") == nil, "unchanged targets do not restart the original two-second transition")

moving.x = 0.36
smooth:RefreshPositionPins()
smoothWorld.now = smoothWorld.now + 0.5
moving.x = 0.4
smooth:RefreshPositionPins()
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.33)
smoothWorld:advance(1)
Near(movingPin.x, 0.365)
assert(movingPin:GetScript("OnUpdate"), "retargeting uses absolute elapsed time even between rendered frames")

moving.x, moving.online = 0.44, false
smooth:RefreshPositionPins()
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.44)
assert(movingPin:GetScript("OnUpdate") == nil, "offline changes stop movement at the retained coordinates")
moving.x, moving.online = 0.48, true
smooth:RefreshPositionPins()
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.48)
assert(movingPin:GetScript("OnUpdate") == nil, "reconnecting snaps to the fresh online position")

moving.x = 0.7
smooth:RefreshPositionPins()
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.7)
assert(movingPin:GetScript("OnUpdate") == nil, "large same-map jumps do not sweep across the map")
moving.x, moving.y = 0.78, 0.58
smooth:RefreshPositionPins()
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.78)
Near(movingPin.y, 0.58)
assert(movingPin:GetScript("OnUpdate") == nil, "jump detection measures diagonal source-coordinate distance")

moving.x, moving.y = 0.8, 0.6
smooth:RefreshPositionPins()
smoothWorld:advance(1)
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.79)
Near(movingPin.y, 0.59)
smoothWorld.rectangles["102:101"] = { 0, 1, 0, 1 }
moving.map, moving.x, moving.y = 102, 0.82, 0.62
smooth:RefreshPositionPins()
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.82)
Near(movingPin.y, 0.62)
assert(movingPin:GetScript("OnUpdate") == nil, "source-map changes snap even on the same displayed map")

moving.x, moving.y = 0.84, 0.64
smooth:RefreshPositionPins()
smoothWorld:advance(0.5)
smoothWorld.rectangles["102:100"] = { 0, 1, 0, 1 }
smoothWorld.map:changeMap(100)
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.84)
Near(movingPin.y, 0.64)
assert(movingPin:GetScript("OnUpdate") == nil, "displayed-map changes discard the previous projected transition")

moving.x, moving.y = 0.86, 0.66
smooth:RefreshPositionPins()
smoothWorld.map.shown = false
smoothWorld:advance(0.5)
moving.x, moving.y = 0.88, 0.68
local createdBeforeHidden = smoothWorld.created
smooth:RefreshPositionPins()
assert(#smoothWorld.map.pins == 0 and smoothWorld.created == createdBeforeHidden,
    "hidden refreshes release motion without allocating new pins")
smoothWorld.map:show()
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.88)
Near(movingPin.y, 0.68)
assert(movingPin:GetScript("OnUpdate") == nil, "reopening displays the latest hidden sample immediately")

moving.x, moving.y = 0.9, 0.7
smooth:RefreshPositionPins()
smoothWorld:advance(0.5)
smoothWorld.map.shown = false
smoothWorld:advance(0.5)
smoothWorld.map:show()
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.9)
Near(movingPin.y, 0.7)
assert(movingPin:GetScript("OnUpdate") == nil, "map-show refreshes snap even without an intervening hidden update")

moving.x, moving.y = 0.92, 0.72
smooth:RefreshPositionPins()
smoothWorld:advance(0.5)
smooth.positionMapProvider:RemoveAllData()
assert(#smoothWorld.map.pins == 0, "removing the provider's data releases every animated pin")
smooth:RefreshPositionPins()
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.92)
Near(movingPin.y, 0.72)
assert(movingPin:GetScript("OnUpdate") == nil, "explicit data removal also clears cached motion")

moving.x, moving.y = 0.94, 0.74
smooth:RefreshPositionPins()
smooth.positions = { carol = { name = "Carol-Realm", map = 100, x = 0.1, y = 0.2, online = true } }
smooth:RefreshPositionPins()
local carolPin = FindPin(smoothWorld, "Carol-Realm")
Near(carolPin.x, 0.1)
Near(carolPin.y, 0.2)
assert(carolPin:GetScript("OnUpdate") == nil, "a pooled frame cannot transfer another player's movement")
smooth.positions = {}
smooth:RefreshPositionPins()
assert(#smoothWorld.map.pins == 0, "an empty model removes animated data after sharing or group changes")
smooth.positions.alice = moving
smooth:RefreshPositionPins()
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.94)
Near(movingPin.y, 0.74)
assert(movingPin:GetScript("OnUpdate") == nil, "removed players return with a fresh position")

local projectedSmooth, projectedSmoothWorld = LoadMap()
projectedSmoothWorld:loadNativeMap(true)
projectedSmoothWorld.map.id = 100
projectedSmoothWorld.rectangles["101:100"] = { 0.1, 0.5, 0.2, 0.6 }
local projectedMoving = { name = "Alice-Realm", map = 101, x = 0.25, y = 0.5, online = true }
projectedSmooth.positions.alice = projectedMoving
projectedSmooth:InitializePositionMap()
projectedMoving.x, projectedMoving.y = 0.29, 0.56
projectedSmooth:RefreshPositionPins()
local projectedPin = FindPin(projectedSmoothWorld, projectedMoving.name)
Near(projectedPin.x, 0.2)
Near(projectedPin.y, 0.4)
projectedSmoothWorld:advance(1)
Near(projectedPin.x, 0.208)
Near(projectedPin.y, 0.412)
projectedSmoothWorld:advance(1)
Near(projectedPin.x, 0.216)
Near(projectedPin.y, 0.424)
Near(projectedMoving.x, 0.29)
Near(projectedMoving.y, 0.56)
assert(projectedMoving.map == 101 and projectedPin:GetScript("OnUpdate") == nil,
    "projected movement ends at native map coordinates without changing the shared source data")

print("PASS: native map attachment/filter, class icons/fallbacks, presence labels/colors, projection, smooth movement and pooled pin lifecycle")
