-- Native MapCanvas callback contracts are mocked; rendering needs in-game checks.
local loadNotifications = dofile("tests/support/notifications.lua")
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

local function CheckDotAssets()
    for _, asset in ipairs({ "PositionDot", "PositionRing" }) do
        local file = assert(io.open("Media/" .. asset .. ".tga", "rb"))
        local data = file:read("*a")
        file:close()
        assert(data:byte(2) == 0 and data:byte(3) == 2 and data:byte(17) == 32,
            "position markers use native uncompressed TGA textures with alpha")
        local width = data:byte(13) + data:byte(14) * 256
        local height = data:byte(15) + data:byte(16) * 256
        local offset = 18 + data:byte(1)
        assert(width > 0 and height > 0 and #data >= offset + width * height * 4)
        local function Alpha(x, y) return data:byte(offset + (y * width + x) * 4 + 4) end
        assert(Alpha(0, 0) == 0 and Alpha(width - 1, 0) == 0
            and Alpha(0, height - 1) == 0 and Alpha(width - 1, height - 1) == 0,
            "dot textures have transparent corners rather than square backgrounds")
        local centerAlpha = Alpha(math.floor(width / 2), math.floor(height / 2))
        assert(asset == "PositionDot" and centerAlpha == 255 or asset == "PositionRing" and centerAlpha == 0,
            "the active dot has a filled center and the stale ring has a transparent center")
        local visible = false
        for index = offset + 4, offset + width * height * 4, 4 do
            if data:byte(index) == 255 then visible = true; break end
        end
        assert(visible, "each position marker contains opaque visible pixels")
    end
end
CheckDotAssets()

local function LoadMap()
    local addon = {
        positions = {}, initialized = true, positionState = {},
        db = { position = { showPlayerIcons = true } },
    }
    local world = {
        frames = {}, added = 0, created = 0, released = 0, rectangles = {},
        bounds = {}, secretValues = {}, worldConversions = 0, now = 0,
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
        RAID_CLASS_COLORS = {
            WARRIOR = { r = 0.78, g = 0.61, b = 0.43 },
            MAGE = { r = 0.25, g = 0.78, b = 0.92 },
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
                -- Native world axes are reversed: world X follows map Y, world Y follows map X.
                return bounds.continent, Vector(bounds[3] + y * (bounds[4] - bounds[3]),
                    bounds[1] + x * (bounds[2] - bounds[1]))
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
    local tooltip = { shown = false, lines = {}, hideCount = 0 }
    function tooltip:SetOwner(owner, anchor) self.owner, self.anchor = owner, anchor end
    function tooltip:IsOwned(owner) return self.owner == owner end
    function tooltip:SetText(text, ...)
        self.title, self.titleColor, self.lines = text, { ... }, {}
    end
    function tooltip:AddLine(text, ...) self.lines[#self.lines + 1] = { text = text, color = { ... } } end
    function tooltip:Show() self.shown = true end
    function tooltip:Hide() self.shown, self.owner, self.hideCount = false, nil, self.hideCount + 1 end
    function tooltip:IsShown() return self.shown end
    world.tooltip, environment.GameTooltip = tooltip, tooltip
    world.environment, world.mapAPI = environment, environment.C_Map
    world.notificationErrors = loadNotifications(addon, environment)
    world.libraryFrames = #world.frames
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
            GetMap = function(self) return self.owningMap end,
            SetPosition = function(self, x, y) self.x, self.y = x, y end,
            SetScalingLimits = function() end,
            SetIgnoreGlobalPinScale = function() end,
            UseFrameLevelType = function(_, level) assert(level == "PIN_FRAME_LEVEL_GROUP_MEMBER") end,
            OnReleased = function() world.released = world.released + 1 end,
        }
        local map = { shown = shown, id = 101, pins = {}, pool = {}, unrelatedPin = {},
            width = 1000, height = 600, zoom = 1, effectiveScale = 1, originX = 100, originY = 200 }
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
                assert(pin.playerName == nil and pin.online == nil and pin.provider == nil and not pin.hovered,
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
                function pin:IsMouseOver() return world.hoveredName == self.playerName end
                function pin:GetEffectiveScale() return self.effectiveScale or self:GetMap().effectiveScale end
                function pin:GetCenter()
                    if self.centerUnavailable then return end
                    if self.centerX then return self.centerX, self.centerY end
                    local owner, scale = self:GetMap(), self:GetEffectiveScale()
                    return (owner.originX + self.x * owner.width * owner.zoom) / scale,
                        (owner.originY + self.y * owner.height * owner.zoom) / scale
                end
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
        function map:hide()
            self.shown = false
            self.provider:OnHide()
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
    function world:hover(pin)
        self.hoveredName = pin.playerName
        pin:OnMouseEnter()
    end
    function world:leave(pin)
        if self.hoveredName == pin.playerName then self.hoveredName = nil end
        pin:OnMouseLeave()
    end
    return addon, world
end

local function Near(actual, expected)
    assert(math.abs(actual - expected) < 0.000001)
end

local dotTexture = "Interface\\AddOns\\LockInTools\\Media\\PositionDot"
local ringTexture = "Interface\\AddOns\\LockInTools\\Media\\PositionRing"
local fallbackColor, staleColor = { 0.27, 0.65, 1 }, { 0.6, 0.6, 0.6 }
local function CheckDot(pin, color, online)
    assert(pin.Label == nil, "player names are never rendered as map labels")
    assert(pin.Icon.texture == (online and dotTexture or ringTexture),
        "fresh positions use filled dots and stale positions use hollow dots")
    assert(pin.Icon.color == nil, "dot textures are tinted rather than replaced with squares")
    for index, value in ipairs({ 0, 1, 0, 1 }) do Near(pin.Icon.coordinates[index], value) end
    for index = 1, 3 do Near(pin.Icon.vertexColor[index], color[index]) end
    Near(pin.Icon.alpha, 1)
    assert(not pin.Icon.desaturated, "pooled dots do not retain class-icon desaturation")
end

local function FindPin(testWorld, name)
    for _, candidate in ipairs(testWorld.map.pins) do
        if candidate:GetDisplayName() == name then return candidate end
    end
    error("missing map pin for " .. name)
end

local addon, world = LoadMap()
addon.positions.alice = { name = "Alice-Realm", map = 101, x = 0.25, y = 0.5 }
addon:InitializePositionMap()
local mapEvents = addon.positionMapEvents
addon:InitializePositionMap()
assert(#world.frames == world.libraryFrames and world.added == 0 and addon.positionMapEvents == mapEvents,
    "wait for native map with one owner on the shared event frame")
local otherAddonLoads = 0
local otherEvents = addon:RegisterGameEvents({ "ADDON_LOADED" }, function(self)
    assert(self == addon, "native event callbacks receive the addon as self")
    otherAddonLoads = otherAddonLoads + 1
end)
assert(world.menuRegistrations == 1, "register the filter once before the world map loads")
world:fire("ADDON_LOADED", "UnrelatedAddon")
assert(world.added == 0)
world:loadNativeMap(false)
world:fire("ADDON_LOADED", "Blizzard_WorldMap")
assert(world.added == 1 and #world.map.pins == 0, "attach while hidden without creating pins")
world:fire("ADDON_LOADED", "AnotherAddon")
assert(otherAddonLoads == 3 and world.frames[1].events.ADDON_LOADED,
    "attaching the map unregisters only its owner while another addon-load listener remains")
otherEvents:UnregisterAllEvents()
assert(not world.frames[1].events.ADDON_LOADED,
    "the shared frame releases native addon-load events once the last owner unregisters")
addon:InitializePositionMap()
assert(world.added == 1, "attach the provider only once")

world.map:show()
assert(#world.map.pins == 1, "opening the map displays an existing retained position")
local pin = world.map.pins[1]
assert(pin.Label == nil and pin:GetDisplayName() == "Alice-Realm" and pin.online == nil,
    "retained coordinates have no map label while preserving the native display name")
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
assert(earlyWorld.added == 1 and #earlyWorld.map.pins == 1 and #earlyWorld.frames == earlyWorld.libraryFrames,
    "an already loaded world map refreshes immediately without a late-load event")
early.db.position.showPlayerIcons = false
early:Notify("POSITION_VISIBILITY_CHANGED")
assert(#earlyWorld.map.pins == 0, "the map independently subscribes to icon visibility notifications")
early.db.position.showPlayerIcons = true
early:Notify("POSITIONS_CHANGED")
assert(#earlyWorld.map.pins == 1, "position notifications refresh the loaded map without an options view")
early.positions = {}
early:Notify("GROUP_CHANGED")
assert(#earlyWorld.map.pins == 0 and #earlyWorld.notificationErrors == 0,
    "group cleanup notifications independently remove old map pins")

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
    and #delayedMenuWorld.frames == delayedMenuWorld.libraryFrames,
    "missing menu APIs preserve the map provider and use one late-load listener")
delayedMenuWorld.environment.Menu = {}
delayedMenuWorld:fire("ADDON_LOADED", "Blizzard_Menu")
assert(delayedMenuWorld.menuRegistrations == 0, "an unavailable menu registration function is safe")
delayedMenuWorld.environment.Menu = nativeMenu
delayedMenuWorld:fire("ADDON_LOADED", "Blizzard_Menu")
assert(delayedMenuWorld.added == 1 and delayedMenuWorld.menuRegistrations == 1
    and not delayedMenuWorld.frames[1].events.ADDON_LOADED,
    "late menu loading registers without duplicating the existing provider")
delayedMenuWorld:fire("ADDON_LOADED", "Blizzard_Menu")
delayedMenu:InitializePositionMap()
assert(delayedMenuWorld.menuRegistrations == 1, "repeated initialization never duplicates menu entries")

local presence, presenceWorld = LoadMap()
presenceWorld:loadNativeMap(true)
presence.positions.alice = { name = "Alice-Realm", map = 101, x = 0.25, y = 0.5 }
presence:InitializePositionMap()
local presencePin = presenceWorld.map.pins[1]
assert(presencePin.online == nil)
CheckDot(presencePin, staleColor, false)
assert(not presenceWorld.tooltip:IsShown(), "a map position does not display its name before hover")
presenceWorld:hover(presencePin)
assert(presenceWorld.tooltip.title == "Alice-Realm" and presenceWorld.tooltip:IsOwned(presencePin)
    and presenceWorld.tooltip:IsShown(), "hover shows the complete retained player name")
assert(#presenceWorld.tooltip.lines == 1 and presenceWorld.tooltip.lines[1].text == "Last known position",
    "retained positions explain freshness without asserting that the player logged out")
presenceWorld:leave(presencePin)
assert(not presenceWorld.tooltip:IsShown() and presencePin:GetScript("OnUpdate") == nil,
    "leaving a stationary position dismisses its tooltip and stops hover updates")

presence.positions.alice.online = false
presence:RefreshPositionPins()
assert(presenceWorld.map.pins[1] == presencePin and presenceWorld.created == 1,
    "presence changes refresh an existing native pooled pin")
assert(presencePin.online == false, "timed-out peers retain their stale status")
assert(presencePin:GetDisplayName() == "Alice-Realm", "native player actions keep the real player name")
CheckDot(presencePin, staleColor, false)

presence.positions.alice.online = true
presence:RefreshPositionPins()
assert(presencePin.online == true, "a new update restores the active state on a pooled pin")
CheckDot(presencePin, fallbackColor, true)
presenceWorld:hover(presencePin)
assert(presenceWorld.tooltip.title == "Alice-Realm" and #presenceWorld.tooltip.lines == 0,
    "a fresh position has no stale-position warning")
presenceWorld:leave(presencePin)

presence.positions = { bob = { name = "Bob-Realm", map = 101, x = 0.5, y = 0.5 } }
presence:RefreshPositionPins()
assert(presenceWorld.map.pins[1] == presencePin and presencePin.online == nil)
assert(presencePin:GetDisplayName() == "Bob-Realm",
    "a pooled pin replaces the previous name and presence with the retained player's state")
CheckDot(presencePin, staleColor, false)
presence.positions = {}
presence:RefreshPositionPins()
assert(#presenceWorld.map.pins == 0 and presenceWorld.released == 4)
assert(presencePin.playerName == nil and presencePin.online == nil and presencePin.provider == nil)

local classes, classWorld = LoadMap()
classWorld:loadNativeMap(true)
classes.positions.alice = { name = "Alice-Realm", map = 101, x = 0.25, y = 0.5, online = true, class = "WARRIOR" }
classes:InitializePositionMap()
local classPin = classWorld.map.pins[1]
local function CheckClassDot(class, online)
    assert(classWorld.map.pins[1] == classPin and classWorld.created == 1,
        "class and presence updates reuse a native pooled pin")
    local color = classWorld.environment.RAID_CLASS_COLORS[class]
    CheckDot(classPin, online and { color.r, color.g, color.b } or staleColor, online)
end
local function CheckFallback(online)
    CheckDot(classPin, online and fallbackColor or staleColor, online)
end
CheckClassDot("WARRIOR", true)

classes.positions = { bob = { name = "Bob-Realm", map = 101, x = 0.5, y = 0.5, online = false, class = "MAGE" } }
classes:RefreshPositionPins()
CheckClassDot("MAGE", false)
assert(classPin:GetDisplayName() == "Bob-Realm", "a pooled pin replaces its class and name")
classes.positions.bob.online = true
classes:RefreshPositionPins()
CheckClassDot("MAGE", true)

classes.positions.bob.online = false
classes:RefreshPositionPins()
CheckClassDot("MAGE", false)
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
CheckClassDot("MAGE", true)
local nativeColors = classWorld.environment.RAID_CLASS_COLORS
classWorld.environment.RAID_CLASS_COLORS = nil
classes:RefreshPositionPins()
CheckFallback(true)
classWorld.environment.RAID_CLASS_COLORS = nativeColors
local mageColor = nativeColors.MAGE
for _, invalidColor in ipairs({ {}, false, { r = -0.1, g = 0.5, b = 0.5 },
    { r = 0.5, g = 1.1, b = 0.5 }, { r = 0.5, g = 0.5, b = 0 / 0 },
    { r = math.huge, g = 0.5, b = 0.5 }, { r = "0.5", g = 0.5, b = 0.5 },
    { r = 0.5, g = 0.5, b = secretClass } }) do
    nativeColors.MAGE = invalidColor
    classes:RefreshPositionPins()
    CheckFallback(true)
end
nativeColors.MAGE = mageColor
classes:RefreshPositionPins()
CheckClassDot("MAGE", true)

local function CheckSharedTooltips()
    local shared, sharedWorld = LoadMap()
    sharedWorld:loadNativeMap(true)
    shared.positions.zed = { name = "Zed-Realm", map = 101, x = 0.2, y = 0.4, online = true, class = "WARRIOR" }
    shared.positions.bob = { name = "Bob-Realm", map = 101, x = 0.2, y = 0.4, online = false, class = "MAGE" }
    shared.positions.alice = { name = "Alice-Realm", map = 101, x = 0.2, y = 0.4, online = true, class = "MAGE" }
    shared:InitializePositionMap()
    local alice = FindPin(sharedWorld, "Alice-Realm")
    local bob = FindPin(sharedWorld, "Bob-Realm")
    local zed = FindPin(sharedWorld, "Zed-Realm")
    local tooltip = sharedWorld.tooltip
    assert(#shared.positionMapProvider.pins == 3 and alice.provider == shared.positionMapProvider,
        "the provider tracks only its acquired pins for shared tooltips")
    sharedWorld:hover(zed)
    assert(tooltip.title == "Shared positions (3)" and #tooltip.lines == 3 and tooltip:IsOwned(zed),
        "hovering any coincident dot shows all players in one owned tooltip")
    assert(tooltip.lines[1].text == "Alice-Realm" and tooltip.lines[2].text == "Bob-Realm (Last known position)"
        and tooltip.lines[3].text == "Zed-Realm", "shared names sort alphabetically and label stale positions")
    local mage, warrior = sharedWorld.environment.RAID_CLASS_COLORS.MAGE, sharedWorld.environment.RAID_CLASS_COLORS.WARRIOR
    for index, value in ipairs({ mage.r, mage.g, mage.b }) do Near(tooltip.lines[1].color[index], value) end
    for index = 1, 3 do Near(tooltip.lines[2].color[index], staleColor[index]) end
    for index, value in ipairs({ warrior.r, warrior.g, warrior.b }) do Near(tooltip.lines[3].color[index], value) end
    alice:OnMouseLeave()
    assert(tooltip:IsShown() and tooltip:IsOwned(zed), "another pin's leave callback cannot hide the owned tooltip")
    sharedWorld:leave(zed)

    alice.centerX, alice.centerY = 300, 440
    bob.centerX, bob.centerY = 309, 449
    zed.centerX, zed.centerY = 312, 440
    sharedWorld:hover(alice)
    assert(tooltip.title == "Shared positions (2)" and tooltip.lines[1].text == "Alice-Realm"
        and tooltip.lines[2].text == "Zed-Realm",
        "overlap includes touching 12-pixel dots but excludes diagonal hover-rectangle overlap")
    zed.centerX = 312.01
    sharedWorld:advance(0.11)
    assert(tooltip.title == "Alice-Realm" and #tooltip.lines == 0,
        "dots immediately beyond the visible circular boundary have separate tooltips")
    zed.centerX = 311.99
    sharedWorld:advance(0.11)
    assert(tooltip.title == "Shared positions (2)", "nearby dot movement refreshes a stationary hovered tooltip")

    alice.effectiveScale, alice.centerX, alice.centerY = 2, 150, 220
    bob.centerX, bob.centerY = 400, 440
    zed.effectiveScale, zed.centerX, zed.centerY = 0.5, 630, 880
    sharedWorld:advance(0.11)
    assert(tooltip.title == "Shared positions (2)",
        "overlap uses screen-space centers and the sum of differently scaled dot radii")
    zed.centerX = 630.1
    sharedWorld:advance(0.11)
    assert(tooltip.title == "Alice-Realm", "scaled circles just beyond their summed radii remain separate")

    alice.effectiveScale, zed.effectiveScale = nil, nil
    for _, candidate in ipairs({ alice, bob, zed }) do candidate.centerX, candidate.centerY = nil, nil end
    alice.x, bob.x, zed.x = 0.2, 0.211, 0.24
    sharedWorld:advance(0.11)
    assert(tooltip.title == "Shared positions (2)", "rendered map geometry identifies close normalized coordinates")
    sharedWorld.map.zoom = 2
    sharedWorld:advance(0.11)
    assert(tooltip.title == "Alice-Realm", "zooming separates dots without receiving new position data")
    sharedWorld.map.zoom = 0.25
    sharedWorld:advance(0.11)
    assert(tooltip.title == "Shared positions (3)", "zooming out merges all visibly overlapping dots")
    sharedWorld:leave(alice)
    assert(alice:GetScript("OnUpdate") == nil and not tooltip:IsShown(), "stationary dots do no idle work after hover")

    sharedWorld:hover(alice)
    local foreignOwner, beforeHide = {}, tooltip.hideCount
    tooltip:SetOwner(foreignOwner, "ANCHOR_RIGHT")
    tooltip:SetText("Unrelated tooltip")
    tooltip:Show()
    sharedWorld:advance(0.11)
    assert(tooltip:IsOwned(foreignOwner) and tooltip.title == "Unrelated tooltip" and tooltip.hideCount == beforeHide,
        "hover refresh cannot take back or hide another control's tooltip")
    assert(alice:GetScript("OnUpdate") == nil and not alice.hovered,
        "losing tooltip ownership stops stationary hover updates")
    sharedWorld:leave(alice)
    shared.positionMapProvider:RemoveAllData()
    assert(tooltip:IsShown() and tooltip:IsOwned(foreignOwner) and tooltip.hideCount == beforeHide,
        "leaving and releasing pins preserve an unrelated tooltip")
end
CheckSharedTooltips()

local function CheckTooltipLifecycle()
    local lifecycle, lifecycleWorld = LoadMap()
    lifecycleWorld:loadNativeMap(true)
    local peer = { name = "Alice-Realm", map = 101, x = 0.2, y = 0.4, online = true, class = "MAGE" }
    lifecycle.positions.alice = peer
    lifecycle:InitializePositionMap()
    local tooltip = lifecycleWorld.tooltip
    local hovered = FindPin(lifecycleWorld, peer.name)
    lifecycleWorld:hover(hovered)
    peer.online = false
    lifecycle:RefreshPositionPins()
    assert(not tooltip:IsShown(), "rebuilding releases the previous owned tooltip before native layout")
    lifecycleWorld:advance(0.01)
    hovered = FindPin(lifecycleWorld, peer.name)
    assert(tooltip:IsShown() and tooltip:IsOwned(hovered) and tooltip.title == peer.name
        and tooltip.lines[1].text == "Last known position", "hover survives a stationary freshness refresh after layout")
    peer.online = true
    lifecycle:RefreshPositionPins()
    lifecycleWorld:advance(0.01)
    hovered = FindPin(lifecycleWorld, peer.name)
    assert(tooltip:IsOwned(hovered) and #tooltip.lines == 0, "a fresh sample clears the restored stale tooltip warning")
    CheckDot(hovered, { 0.25, 0.78, 0.92 }, true)

    lifecycle:RefreshPositionPins()
    local foreignOwner = {}
    tooltip:SetOwner(foreignOwner, "ANCHOR_RIGHT")
    tooltip:SetText("Unrelated tooltip")
    tooltip:Show()
    local beforeHide = tooltip.hideCount
    lifecycleWorld:advance(0.01)
    assert(tooltip:IsOwned(foreignOwner) and tooltip.title == "Unrelated tooltip" and tooltip.hideCount == beforeHide,
        "a deferred hover restoration preserves tooltips opened during native layout")
    hovered = FindPin(lifecycleWorld, peer.name)
    assert(hovered:GetScript("OnUpdate") == nil, "a cancelled deferred restoration leaves no idle update")
    tooltip:Hide()

    lifecycleWorld:hover(hovered)
    lifecycleWorld.map:hide()
    assert(not tooltip:IsShown() and hovered:GetScript("OnUpdate") == nil and not hovered.hovered,
        "hiding the map dismisses its owned tooltip and stops stationary hover updates")
    lifecycleWorld.map:show()
    hovered = FindPin(lifecycleWorld, peer.name)
    assert(not tooltip:IsShown(), "opening the map waits for native hover before showing a player name")
    lifecycleWorld:hover(hovered)
    lifecycle.db.position.showPlayerIcons = false
    lifecycle:Notify("POSITION_VISIBILITY_CHANGED")
    assert(not tooltip:IsShown() and #lifecycleWorld.map.pins == 0 and #lifecycle.positionMapProvider.pins == 0,
        "filtering removes the owned tooltip and all overlap candidates")
    lifecycle.db.position.showPlayerIcons = true
    lifecycle:Notify("POSITION_VISIBILITY_CHANGED")
    hovered = FindPin(lifecycleWorld, peer.name)
    lifecycleWorld:hover(hovered)
    lifecycle.positions = {}
    lifecycle:Notify("GROUP_CHANGED")
    assert(not tooltip:IsShown() and #lifecycleWorld.map.pins == 0 and not hovered.hovered
        and hovered.provider == nil and hovered:GetScript("OnUpdate") == nil,
        "group cleanup releases tooltip ownership and pooled player state")

    lifecycle.positions.bob = { name = "Bob-Realm", map = 101, x = 0.2, y = 0.4, online = true }
    lifecycle:RefreshPositionPins()
    local bob = FindPin(lifecycleWorld, "Bob-Realm")
    assert(not tooltip:IsShown() and not bob.hovered and bob:GetScript("OnUpdate") == nil,
        "a pooled frame does not inherit the previous player's tooltip or hover loop")
    tooltip:SetOwner(foreignOwner, "ANCHOR_RIGHT")
    tooltip:SetText("Unrelated tooltip")
    tooltip:Show()
    beforeHide = tooltip.hideCount
    lifecycleWorld.map:hide()
    lifecycle.db.position.showPlayerIcons = false
    lifecycle:Notify("POSITION_VISIBILITY_CHANGED")
    lifecycle.positions = {}
    lifecycle:Notify("GROUP_CHANGED")
    assert(tooltip:IsShown() and tooltip:IsOwned(foreignOwner) and tooltip.hideCount == beforeHide,
        "map hiding, filtering and group changes leave unrelated tooltips intact")
end
CheckTooltipLifecycle()

local function CheckAnimatedTooltips()
    local animated, animatedWorld = LoadMap()
    animatedWorld:loadNativeMap(true)
    animated.positions.alice = { name = "Alice-Realm", map = 101, x = 0.2, y = 0.4, online = true }
    local movingPeer = { name = "Bob-Realm", map = 101, x = 0.24, y = 0.4, online = true }
    animated.positions.bob = movingPeer
    animated:InitializePositionMap()
    local hovered = FindPin(animatedWorld, "Alice-Realm")
    animatedWorld:hover(hovered)
    assert(animatedWorld.tooltip.title == "Alice-Realm", "separated dots begin with individual tooltips")
    movingPeer.x = 0.2
    animated:RefreshPositionPins()
    animatedWorld:advance(0.01)
    hovered = FindPin(animatedWorld, "Alice-Realm")
    assert(animatedWorld.tooltip:IsOwned(hovered) and animatedWorld.tooltip.title == "Alice-Realm",
        "overlap uses the displayed start of interpolation instead of the newly received target")
    animatedWorld:advance(0.9)
    assert(animatedWorld.tooltip.title == "Alice-Realm", "dots remain separate before their animation reaches the radius")
    animatedWorld:advance(0.6)
    animatedWorld:advance(0.11)
    assert(animatedWorld.tooltip.title == "Shared positions (2)",
        "a moving neighbor enters the shared tooltip while the hovered dot stays stationary")
    animatedWorld:advance(0.5)
    assert(hovered:GetScript("OnUpdate"), "stationary hover keeps overlap detection alive after nearby motion ends")
    movingPeer.x = 0.24
    animated:RefreshPositionPins()
    animatedWorld:advance(0.01)
    assert(animatedWorld.tooltip.title == "Shared positions (2)",
        "moving away preserves shared names until the displayed dots actually separate")
    animatedWorld:advance(1.5)
    animatedWorld:advance(0.11)
    assert(animatedWorld.tooltip.title == "Alice-Realm" and #animatedWorld.tooltip.lines == 0,
        "the tooltip removes a player whose interpolated dot moves outside the overlap")
    hovered = FindPin(animatedWorld, "Alice-Realm")
    animatedWorld:leave(hovered)
    assert(hovered:GetScript("OnUpdate") == nil, "leaving a stationary dot stops updates after animated overlap")
end
CheckAnimatedTooltips()

local function CheckOrgrimmarProjection()
    local city, cityWorld = LoadMap()
    -- Synthetic Orgrimmar/Durotar geometry; one native world axis decreases.
    cityWorld.bounds[1454] = { -1000, -1400, 4000, 4600, continent = 1 }
    cityWorld.bounds[1411] = { -500, -2500, 2000, 6000, continent = 1 }
    cityWorld.rectangles["1454:1414"] = { 0.6, 0.64, 2 / 3, 43 / 60 }
    cityWorld.mapAPI.GetMapPosFromWorldPos = function() return 1454, Vector(0.25, 0.5) end
    cityWorld:loadNativeMap(true)
    cityWorld.map.id = 1454
    local peer = { name = "Alice-Realm", map = 1454, x = 0.25, y = 0.5, online = true }
    city.positions.alice = peer
    city:InitializePositionMap()
    Near(cityWorld.map.pins[1].x, 0.25)
    Near(cityWorld.map.pins[1].y, 0.5)
    cityWorld.map:changeMap(1411)
    assert(#cityWorld.map.pins == 1,
        "Orgrimmar positions appear on Durotar even when the native inverse lookup selects the city")
    Near(cityWorld.map.pins[1].x, 0.3)
    Near(cityWorld.map.pins[1].y, 0.575)
    cityWorld.mapAPI.GetMapPosFromWorldPos = nil
    city:RefreshPositionPins()
    assert(#cityWorld.map.pins == 1, "overlapping region projection needs no native inverse lookup")
    cityWorld.rectangles["1454:1411"] = { 2, 3, 2, 3 }
    city:RefreshPositionPins()
    assert(#cityWorld.map.pins == 1, "out-of-bounds rectangles still try world projection")
    Near(cityWorld.map.pins[1].x, 0.3)
    Near(cityWorld.map.pins[1].y, 0.575)
    peer.online = false
    city:RefreshPositionPins()
    assert(cityWorld.map.pins[1].Icon.texture == ringTexture, "retained city positions also project onto the region")
    cityWorld.map:changeMap(1414)
    Near(cityWorld.map.pins[1].x, 0.61)
    Near(cityWorld.map.pins[1].y, 83 / 120)
    cityWorld.map:changeMap(1454)
    Near(cityWorld.map.pins[1].x, 0.25)
    Near(cityWorld.map.pins[1].y, 0.5)
    assert(peer.map == 1454 and peer.x == 0.25 and peer.y == 0.5, "map navigation preserves the shared city position")
end
CheckOrgrimmarProjection()

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
assert(projectionWorld.map.pins[1].Icon.texture == dotTexture,
    "class-colored dots remain available when projecting city positions onto the region")
Near(projectionWorld.map.pins[1].x, 0.3)
Near(projectionWorld.map.pins[1].y, 0.575)
assert(projectionWorld.worldConversions == 3, "projection uses the source position and target origin/center")

projectionWorld.rectangles["1456:1414"] = { 0.6, 0.64, 2 / 3, 43 / 60 }
projectionWorld.map:changeMap(1414)
Near(projectionWorld.map.pins[1].x, 0.61)
Near(projectionWorld.map.pins[1].y, 83 / 120)
assert(projectionWorld.worldConversions == 3, "native rectangle projection stays preferred")
projectionWorld.map:changeMap(1456)
Near(projectionWorld.map.pins[1].x, 0.25)
Near(projectionWorld.map.pins[1].y, 0.5)
Near(shared.x, 0.25)
Near(shared.y, 0.5)
assert(shared.map == 1456 and projectionWorld.worldConversions == 3, "map switches preserve shared source coordinates")

projectionWorld.rectangles["1456:1412"] = { 0, 0, 0, 0 }
projectionWorld.map:changeMap(1412)
Near(projectionWorld.map.pins[1].x, 0.3)
Near(projectionWorld.map.pins[1].y, 0.575)
assert(projectionWorld.worldConversions == 6, "a degenerate native rectangle falls back to world coordinates")
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
local toWorld, rectangle = api.GetWorldPosFromMapPos, api.GetMapRectOnMap
api.GetMapRectOnMap = nil
projectionWorld.map:changeMap(1412)
Near(projectionWorld.map.pins[1].x, 0.3)
Near(projectionWorld.map.pins[1].y, 0.575)
assert(#projectionWorld.map.pins == 1, "world conversion works when the rectangle API is absent")

local secret = {}
projectionWorld.secretValues[secret] = true
local invalidWorldPoints = { {}, { 1 }, { secret, Vector(4300, 1100) }, { 1, secret },
    { 1, Vector(nil, 1100) }, { 1, Vector(4300, nil) } }
for _, value in ipairs({ secret, 0 / 0, math.huge, -math.huge, "bad", false }) do
    invalidWorldPoints[#invalidWorldPoints + 1] = { 1, Vector(value, 1100) }
    invalidWorldPoints[#invalidWorldPoints + 1] = { 1, Vector(4300, value) }
end
for _, stage in ipairs({ "source", "origin", "center" }) do
    for _, result in ipairs(invalidWorldPoints) do
        api.GetWorldPosFromMapPos = function(mapID, position)
            local x, y = position:GetXY()
            if stage == "source" and mapID == shared.map
                or stage == "origin" and mapID == 1412 and x == 0 and y == 0
                or stage == "center" and mapID == 1412 and x == 0.5 and y == 0.5 then
                return unpack(result)
            end
            return toWorld(mapID, position)
        end
        projection:RefreshPositionPins()
        assert(#projectionWorld.map.pins == 0, "missing, invalid or secret world points remain hidden at " .. stage)
    end
end
for _, offset in ipairs({ 0, 0.5 }) do
    api.GetWorldPosFromMapPos = function(mapID, position)
        local x, y = position:GetXY()
        if mapID == 1412 and x == offset and y == offset then return 2, Vector(4300, 1100) end
        return toWorld(mapID, position)
    end
    projection:RefreshPositionPins()
    assert(#projectionWorld.map.pins == 0, "both target world points must share the source continent")
end
api.GetWorldPosFromMapPos = toWorld

local targetBounds = projectionWorld.bounds[1412]
for _, bounds in ipairs({ { 500, 500, 2000, 6000, continent = 1 },
    { 500, 2500, 2000, 2000, continent = 1 } }) do
    projectionWorld.bounds[1412] = bounds
    projection:RefreshPositionPins()
    assert(#projectionWorld.map.pins == 0, "zero world width or height cannot project a position")
end
projectionWorld.bounds[1412] = nil
projection:RefreshPositionPins()
assert(#projectionWorld.map.pins == 0, "maps without world geometry remain hidden")
projectionWorld.bounds[1412] = targetBounds
api.GetWorldPosFromMapPos = nil
projection:RefreshPositionPins()
assert(#projectionWorld.map.pins == 0, "the optional world conversion API may be unavailable")
api.GetWorldPosFromMapPos = toWorld
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
smoothWorld:advance(0.5)
Near(movingPin.x, 0.21)
Near(movingPin.y, 0.415)
smoothWorld:advance(0.5)
Near(movingPin.x, 0.22)
Near(movingPin.y, 0.43)
assert(movingPin:GetScript("OnUpdate"), "linear movement covers half the distance after one second")
Near(moving.x, 0.24)
Near(moving.y, 0.46)

moving.class = "MAGE"
smooth.positions.bob = { name = "Bob-Realm", map = 101, x = 0.8, y = 0.8, online = true }
smooth:RefreshPositionPins()
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.22)
Near(movingPin.y, 0.43)
assert(movingPin.Icon.texture == dotTexture, "class changes retain dots during motion")
Near(movingPin.Icon.vertexColor[1], smoothWorld.environment.RAID_CLASS_COLORS.MAGE.r)
smoothWorld:advance(0.5)
Near(movingPin.x, 0.23)
Near(movingPin.y, 0.445)
assert(movingPin:GetScript("OnUpdate"), "linear movement keeps its speed without arriving early or overshooting")
assert(smoothWorld.created == 2, "refreshes reuse pooled pins while preserving each player's motion")
smoothWorld:advance(0.5)
Near(movingPin.x, 0.24)
Near(movingPin.y, 0.46)
assert(movingPin:GetScript("OnUpdate") == nil, "movement reaches its target and stops updating after two seconds")
smoothWorld:advance(1)
Near(movingPin.x, 0.24)
Near(movingPin.y, 0.46)
assert(movingPin:GetScript("OnUpdate") == nil,
    "a delayed sample holds the received target without predicting further movement")

moving.x = 0.26
smooth:RefreshPositionPins()
movingPin = FindPin(smoothWorld, moving.name)
smoothWorld:advance(0.5)
Near(movingPin.x, 0.245)
moving.x = 0.28
smooth:RefreshPositionPins()
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.245)
Near(movingPin.y, 0.46)
smoothWorld:advance(1)
Near(movingPin.x, 0.2625)
Near(movingPin.y, 0.46)
assert(movingPin:GetScript("OnUpdate"), "a fast new target continues from the current displayed position")
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

-- Older profiles can retain removed display settings without affecting player icons.
local legacy, legacyWorld = LoadMap()
legacy.db.position.showTrails, legacy.db.position.trailLength = true, 27
legacyWorld:loadNativeMap(true)
local lineCreations = 0
local canvas = { GetWidth = function() return 1000 end, GetHeight = function() return 600 end }
function canvas:CreateLine()
    lineCreations = lineCreations + 1
    error("player movement must not allocate map lines")
end
function legacyWorld.map:GetCanvas() return canvas end
local legacyPeer = { name = "Alice-Realm", map = 101, x = 0.2, y = 0.4, online = true }
legacy.positions.alice = legacyPeer
legacy:InitializePositionMap()
legacyPeer.x = 0.24
legacy:RefreshPositionPins()
local legacyPin = FindPin(legacyWorld, legacyPeer.name)
legacyWorld:advance(1)
Near(legacyPin.x, 0.22)
legacyWorld:advance(1)
Near(legacyPin.x, 0.24)
assert(lineCreations == 0 and legacyPin:GetScript("OnUpdate") == nil,
    "legacy display settings leave smooth icons without lines or idle animation")
assert(legacy.db.position.showTrails == true and legacy.db.position.trailLength == 27,
    "rendering preserves obsolete saved preferences")

print("PASS: native map attachment/filter, class dots/fallbacks, stale rings, shared tooltips, projection, smooth movement and pooled lifecycle")
