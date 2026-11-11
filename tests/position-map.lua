-- Native MapCanvas callback contracts are mocked; rendering needs in-game checks.
local loadNotifications = dofile("tests/support/notifications.lua")
local POSITION_PIN = "LockInToolsPositionPinTemplate"
local DEATH_PIN = "LockInToolsDeathPinTemplate"
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
        db = { position = { showPlayerIcons = true, sharing = true } },
    }
    local world = {
        frames = {}, added = 0, created = 0, acquired = 0, released = 0, rectangles = {},
        bounds = {}, secretValues = {}, worldConversions = 0, now = 0,
        menuModifiers = {}, menuRegistrations = 0, serverNow = 1000,
        overviewPlayers = {}, rankingPlayers = {}, overviewReads = 0, rankingReads = 0,
        mapNames = { [101] = "Elwynn Forest" },
        groupUnits = {}, partyCount = 0, raidCount = 0, isRaid = false, unitNameReads = 0,
        nativeConnected = {}, nativeSubgroup = {}, nativePositionReads = 0, nativeUnitChecks = 0,
        nativeFilters = { party = true, raid = true },
    }
    local environment = setmetatable({
        CreateFromMixins = Mix,
        Mixin = Mixin,
        CreateVector2D = Vector,
        C_AddOns = { GetAddOnMetadata = function() return "test" end },
        C_PvP = { IsActiveBattlefield = function() return world.battlefield == true end },
        GetTime = function() return world.now end,
        GetServerTime = function() return world.serverNow end,
        GetNormalizedRealmName = function() return "Realm" end,
        IsInRaid = function() return world.isRaid end,
        GetNumSubgroupMembers = function() return world.partyCount end,
        GetNumGroupMembers = function() return world.isRaid and world.raidCount or world.partyCount + 1 end,
        UnitFullName = function(unit)
            world.unitNameReads = world.unitNameReads + 1
            local identity = world.groupUnits[unit]
            if identity then return identity[1], identity[2] end
        end,
        UnitIsConnected = function(unit)
            world.nativeUnitChecks = world.nativeUnitChecks + 1
            if world.nativeConnected[unit] ~= nil then return world.nativeConnected[unit] end
            return world.groupUnits[unit] ~= nil
        end,
        UnitInSubgroup = function(unit)
            if world.nativeSubgroup[unit] ~= nil then return world.nativeSubgroup[unit] end
            return world.groupUnits[unit] ~= nil
        end,
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
        C_Map = { GetMapInfo = function(mapID)
            local name = world.mapNames[mapID]
            if name then return { name = name } end
        end,
        GetPlayerMapPosition = function()
            world.nativePositionReads = world.nativePositionReads + 1
            error("Native marker suppression must not query per-unit coordinates")
        end,
        GetMapRectOnMap = function(source, target)
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
    function tooltip:ClearLines() self.title, self.lines = nil, {} end
    function tooltip:SetText(text, ...)
        self.title, self.titleColor, self.lines = text, { ... }, {}
    end
    function tooltip:AddLine(text, ...) self.lines[#self.lines + 1] = { text = text, color = { ... } } end
    function tooltip:Show() self.shown = true end
    function tooltip:Hide() self.shown, self.owner, self.hideCount = false, nil, self.hideCount + 1 end
    function tooltip:IsShown() return self.shown end
    world.tooltip, environment.GameTooltip = tooltip, tooltip
    environment.GameTooltip_SetDefaultAnchor = function(target, owner)
        target:SetOwner(owner, "ANCHOR_NONE")
    end
    world.environment, world.mapAPI = environment, environment.C_Map
    world.notificationErrors = loadNotifications(addon, environment)
    for _, file in ipairs({ "Core.lua", "Position.lua", "Roster.lua", "Ranking.lua", "PositionMap.lua" }) do
        local chunk = assert(loadfile(file))
        setfenv(chunk, environment)
        chunk("LockInTools", addon)
    end
    -- Exercise Core's display helper without starting unrelated addon features.
    addon.startupEvents:UnregisterAllEvents()
    addon.initialized = true
    world.libraryFrames = #world.frames
    function addon:GetSharedPositions() return self.positions end
    function addon:GetOverviewPlayers()
        world.overviewReads = world.overviewReads + 1
        return world.overviewPlayers
    end
    function addon:GetPlayerRanking()
        world.rankingReads = world.rankingReads + 1
        return { players = world.rankingPlayers }
    end
    -- Simulate a virtual template retaining its mixin table before map load.
    world.templateMixin = assert(environment.LockInToolsPositionPinMixin)
    world.deathTemplateMixin = environment.LockInToolsDeathPinMixin

    function world:loadNativeMap(shown)
        environment.MapCanvasDataProviderMixin = {
            OnAdded = function(self, map) self.owningMap = map end,
            OnRemoved = function(self, map)
                assert(self.owningMap == map)
                self.owningMap = nil
            end,
            GetMap = function(self) return self.owningMap end,
            OnMapChanged = function(self) self:RefreshAllData() end,
        }
        environment.MapCanvasPinMixin = {
            SetOwningMap = function(self, map) self.owningMap = map end,
            GetMap = function(self) return self.owningMap end,
            SetPosition = function(self, x, y) self.x, self.y = x, y end,
            SetScalingLimits = function() end,
            SetIgnoreGlobalPinScale = function() end,
            UseFrameLevelType = function(_, level)
                assert(level == "PIN_FRAME_LEVEL_GROUP_MEMBER" or level == "PIN_FRAME_LEVEL_CORPSE")
            end,
            OnReleased = function() world.released = world.released + 1 end,
        }
        local map = { shown = shown, id = 101, pins = {}, pool = {}, unrelatedPin = {},
            width = 1000, height = 600, zoom = 1, effectiveScale = 1, originX = 100, originY = 200 }
        local nativePin = { shown = true, mapID = 101, dataProvider = {} }
        function nativePin:IsShown() return self.shown end
        function nativePin:GetUiMapID() return self.mapID end
        function nativePin.dataProvider:ShouldShowUnit(category) return world.nativeFilters[category] end
        world.nativePin = nativePin
        function map:EnumeratePinsByTemplate(template)
            assert(template == "GroupMembersPinTemplate", "inspect only the native group marker")
            local visited = false
            return function()
                if not visited then visited = true; return world.nativePin end
            end
        end
        function map:IsShown() return self.shown end
        function map:GetMapID() return self.id end
        function map:GetCanvasScale() return self.zoom end
        function map:InstantPanAndZoom(scale, x, y, ignoreScaleRatio)
            -- Native same-scale interpolation keeps the old pan unless explicitly bypassed.
            local ratio = ignoreScaleRatio and 0 or self.zoom / scale
            x = x + ((self.panX or 0.5) - x) * ratio
            y = y + ((self.panY or 0.5) - y) * ratio
            local margin = 0.5 / scale
            self.zoom = scale
            self.panX = math.max(margin, math.min(1 - margin, x))
            self.panY = math.max(margin, math.min(1 - margin, y))
        end
        function map:AddDataProvider(provider)
            world.added = world.added + 1
            self.provider = provider
            provider:OnAdded(self)
        end
        function map:RegisterDataProviderOnUpdate(provider) self.updateProvider = provider end
        function map:UnregisterDataProviderOnUpdate(provider)
            assert(self.updateProvider == provider)
            self.updateProvider = nil
        end
        function map:RemovePin(pin)
            for index, candidate in ipairs(self.pins) do
                if candidate == pin then table.remove(self.pins, index); break end
            end
            pin:OnReleased()
            assert(pin.playerName == nil and pin.online == nil and pin.provider == nil and not pin.hovered,
                "release clears player state before returning the pin to the native pool")
            assert(pin:GetScript("OnUpdate") == nil, "released pins stop their animation callbacks")
            local pool = self.pool[pin.template]
            pool[#pool + 1] = pin
        end
        function map:RemoveAllPinsByTemplate(template)
            assert(template == POSITION_PIN or template == DEATH_PIN, "remove only LockInTools pins")
            for index = #self.pins, 1, -1 do
                local pin = self.pins[index]
                if pin.template == template then self:RemovePin(pin) end
            end
        end
        function map:AcquirePin(template, ...)
            assert(template == POSITION_PIN or template == DEATH_PIN, "acquire only LockInTools pins")
            world.acquired = world.acquired + 1
            -- Native AcquirePin expects every mixin method before it calls OnLoad.
            local mixin
            if template == POSITION_PIN then
                mixin = world.templateMixin
                assert(environment.LockInToolsPositionPinMixin == mixin)
            else
                mixin = assert(world.deathTemplateMixin)
                assert(environment.LockInToolsDeathPinMixin == mixin)
            end
            local pool = self.pool[template]
            if not pool then pool = {}; self.pool[template] = pool end
            local pin = table.remove(pool)
            if not pin then
                pin = Mix(mixin)
                pin.template = template
                pin.scripts = {}
                function pin:SetScript(script, callback) self.scripts[script] = callback end
                function pin:GetScript(script) return self.scripts[script] end
                function pin:IsMouseOver() return world.hoveredName == self.playerName end
                function pin:GetEffectiveScale() return self.effectiveScale or self:GetMap().effectiveScale end
                function pin:GetCenter()
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

    function world:fire(event, ...)
        for _, frame in ipairs(self.frames) do
            if frame.events[event] then frame.callback(frame, event, ...) end
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
            if self.map.updateProvider then self.map.updateProvider:OnUpdate() end
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
    assert(pin.Icon.texture == (online and dotTexture or ringTexture),
        "active and stale positions have distinct markers")
    for index = 1, 3 do Near(pin.Icon.vertexColor[index], color[index]) end
end

local function FindPin(testWorld, name)
    for _, candidate in ipairs(testWorld.map.pins) do
        if candidate.playerName == name then return candidate end
    end
    error("missing map pin for " .. name)
end

local function CheckTooltip(tooltip, expected, message)
    assert(tooltip.title == expected[1] and #tooltip.lines == #expected - 1, message)
    for index = 2, #expected do assert(tooltip.lines[index - 1].text == expected[index], message) end
end

local addon, world = LoadMap()
addon.positions.alice = { name = "Alice-Realm", map = 101, x = 0.25, y = 0.5 }
addon:InitializePositionMap()
local mapEvents = addon.positionMapEvents
addon:InitializePositionMap()
assert(#world.frames == world.libraryFrames and world.added == 0 and addon.positionMapEvents == mapEvents,
    "wait for native map with one owner on the shared event frame")
assert(world.menuRegistrations == 1, "register the filter once before the world map loads")
world:fire("ADDON_LOADED", "UnrelatedAddon")
assert(world.added == 0)
world:loadNativeMap(false)
world:fire("ADDON_LOADED", "Blizzard_WorldMap")
assert(world.added == 1 and #world.map.pins == 0, "attach while hidden without creating pins")
addon:InitializePositionMap()
assert(world.added == 1, "attach the provider only once")

world.map:show()
assert(#world.map.pins == 1, "opening the map displays an existing retained position")
local pin = world.map.pins[1]
assert(pin.playerName == "Alice-Realm", "pins retain the full player identity")
Near(pin.x, 0.25)
Near(pin.y, 0.5)

world.rectangles["101:100"] = { 0.1, 0.5, 0.2, 0.6 }
addon.positions.bob = { name = "Bob-Realm", map = 999, x = 0.5, y = 0.5 }
world.map:changeMap(100)
assert(#world.map.pins == 1, "omit unrelated maps while projecting a child map onto its parent")
Near(world.map.pins[1].x, 0.2)
Near(world.map.pins[1].y, 0.4)
Near(addon.positions.alice.x, 0.25)
assert(world.released == 0 and world.map.pins[1] == pin and world.map.unrelatedPin,
    "map changes reproject existing pins without releasing them or affecting other providers")

world.rectangles["102:100"] = { 0.9, 1.3, 0.1, 0.2 }
addon.positions.outside = { name = "Outside-Realm", map = 102, x = 1, y = 0.5 }
addon.positions.invalid = { name = "Invalid-Realm", map = 100, x = 0 / 0, y = 0.5 }
addon.positions.alice.x = 0.75
addon:RefreshPositionPins()
assert(#world.map.pins == 1, "new data updates existing pins and omits off-map or invalid coordinates")
Near(world.map.pins[1].x, 0.4)
assert(world.map.pins[1] == pin and world.acquired == 1, "movement retains the existing native pin")

addon.positions = {}
addon:RefreshPositionPins()
assert(#world.map.pins == 0, "an empty visible model removes pins after disabling sharing or clearing player data")
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
early:Notify("POSITIONS_CHANGED")
assert(#earlyWorld.map.pins == 0 and #earlyWorld.notificationErrors == 0,
    "cleared position data independently removes old map pins")

local filtered, filterWorld = LoadMap()
filterWorld:loadNativeMap(true)
local filteredPeer = { name = "Alice-Realm", map = 101, x = 0.25, y = 0.5, online = true }
filtered.positions.alice = filteredPeer
filtered:InitializePositionMap()
local menu = filterWorld:openMenu("MENU_WORLD_MAP_TRACKING")
assert(#menu == 5 and menu[1].kind == "native" and menu[2].kind == "divider"
    and menu[3].text == "LockInTools", "append a distinct addon section without changing native filters")
local icons, deathMarkers = menu[4], menu[5]
assert(icons.text == "Show player icons" and icons:IsSelected() and icons.enabled,
    "the world-map filter reflects the default-enabled preference")
assert(deathMarkers.text == "Show death markers" and deathMarkers:IsSelected() and deathMarkers.enabled,
    "the world-map death marker filter defaults on independently")
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
icons, deathMarkers = menu[4], menu[5]
assert(#menu == 5 and not icons:IsSelected() and deathMarkers:IsSelected(),
    "reopening reflects both preferences without duplicating checkboxes")
icons:Click()
assert(filtered.db.position.showPlayerIcons and #filterWorld.map.pins == 1 and filterWorld.map.unrelatedPin,
    "checking the filter immediately restores only addon pins")
Near(filterWorld.map.pins[1].x, 0.35)
assert(filterWorld.map.pins[1]:GetScript("OnUpdate") == nil, "restored pins snap to the latest received position")
filtered.savedDataReadOnly = true
menu = filterWorld:openMenu("MENU_WORLD_MAP_TRACKING")
icons, deathMarkers = menu[4], menu[5]
assert(not icons.enabled and not deathMarkers.enabled, "newer-schema settings disable the map checkboxes")
icons:Click()
deathMarkers:Click()
assert(filtered:GetShowPlayerIcons() and filtered:GetShowDeathMarkers() and #filterWorld.map.pins == 1,
    "disabled checkboxes preserve read-only settings")
filtered.savedDataReadOnly, filtered.initialized = false, false
menu = filterWorld:openMenu("MENU_WORLD_MAP_TRACKING")
assert(not menu[4].enabled and not menu[5].enabled, "disable the checkboxes while settings are loading")

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

local classes, classWorld = LoadMap()
classWorld:loadNativeMap(true)
classes.positions.alice = { name = "Alice-Realm", map = 101, x = 0.25, y = 0.5, online = true, class = "WARRIOR" }
classes:InitializePositionMap()
local classPin = classWorld.map.pins[1]
CheckDot(classPin, { 0.78, 0.61, 0.43 }, true)
classes.positions = { bob = { name = "Bob-Realm", map = 101, x = 0.5, y = 0.5, online = false, class = "MAGE" } }
classes:RefreshPositionPins()
assert(classWorld.map.pins[1] == classPin and classPin.playerName == "Bob-Realm",
    "pooled pins replace their player identity")
CheckDot(classPin, staleColor, false)
classes.positions.bob.online = true
classes:RefreshPositionPins()
CheckDot(classPin, { 0.25, 0.78, 0.92 }, true)
local secretClass = {}
classWorld.secretValues[secretClass] = true
for _, class in ipairs({ "UNKNOWN", secretClass }) do
    classes.positions.bob.class = class
    classes:RefreshPositionPins()
    CheckDot(classPin, fallbackColor, true)
end

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
    assert(tooltip:IsOwned(zed),
        "hovering any coincident dot shows all players in one owned tooltip")
    CheckTooltip(tooltip, { "#? - Alice", "Lv ? - Awaiting XP", "Elwynn Forest",
        "#? - Bob", "Lv ? - Awaiting XP", "Elwynn Forest - age unknown",
        "#? - Zed", "Lv ? - Awaiting XP", "Elwynn Forest" },
        "overlapping players have alphabetically sorted compact blocks without a count heading or blank lines")
    alice:OnMouseLeave()
    assert(tooltip:IsShown() and tooltip:IsOwned(zed), "another pin's leave callback cannot hide the owned tooltip")
    sharedWorld:leave(zed)

    alice.centerX, alice.centerY = 300, 440
    bob.centerX, bob.centerY = 309, 449
    zed.centerX, zed.centerY = 312, 440
    sharedWorld:hover(alice)
    CheckTooltip(tooltip, { "#? - Alice", "Lv ? - Awaiting XP", "Elwynn Forest",
        "#? - Zed", "Lv ? - Awaiting XP", "Elwynn Forest" },
        "overlap includes touching 12-pixel dots but excludes diagonal hover-rectangle overlap")
    alice.effectiveScale, alice.centerX, alice.centerY = 2, 150, 220
    bob.centerX, bob.centerY = 400, 440
    zed.effectiveScale, zed.centerX, zed.centerY = 0.5, 630, 880
    sharedWorld:advance(0.11)
    CheckTooltip(tooltip, { "#? - Alice", "Lv ? - Awaiting XP", "Elwynn Forest",
        "#? - Zed", "Lv ? - Awaiting XP", "Elwynn Forest" },
        "overlap uses screen-space centers and the sum of differently scaled dot radii")
    alice.effectiveScale, zed.effectiveScale = nil, nil
    for _, candidate in ipairs({ alice, bob, zed }) do candidate.centerX, candidate.centerY = nil, nil end
    alice.x, bob.x, zed.x = 0.2, 0.211, 0.24
    sharedWorld:advance(0.11)
    CheckTooltip(tooltip, { "#? - Alice", "Lv ? - Awaiting XP", "Elwynn Forest",
        "#? - Bob", "Lv ? - Awaiting XP", "Elwynn Forest - age unknown" },
        "rendered map geometry identifies close normalized coordinates")
    sharedWorld.map.zoom = 2
    sharedWorld:advance(0.11)
    CheckTooltip(tooltip, { "#? - Alice", "Lv ? - Awaiting XP", "Elwynn Forest" },
        "zooming separates dots without receiving new position data")
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

local function CheckCompactPlayerDetails()
    local compact, compactWorld = LoadMap()
    compactWorld:loadNativeMap(true)
    compactWorld.mapNames[102] = "Duskwood"
    local peer = { name = "Alice-Realm", map = 101, x = 0.2, y = 0.4, online = true, stamp = 800 }
    local player = { id = "alice-realm", name = "Alice-Realm", level = 30,
        xpState = "known", xp = 420, xpMax = 1000, online = true, sharing = true, map = 102, seenAt = 875 }
    compact.positions.alice = peer
    compactWorld.overviewPlayers = { player }
    for index = 1, 6 do
        compactWorld.rankingPlayers[index] = { id = "other" .. index .. "-realm",
            name = "Other" .. index .. "-Realm", rank = index, level = 40,
            xpState = "known", xp = 500, xpMax = 1000, online = true }
    end
    local ranked = {}
    for key, value in pairs(player) do ranked[key] = value end
    ranked.rank = 7
    compactWorld.rankingPlayers[7] = ranked
    compact:InitializePositionMap()
    local pin, tooltip = FindPin(compactWorld, peer.name), compactWorld.tooltip
    compactWorld:hover(pin)
    CheckTooltip(tooltip, { "#7 - Alice", "Lv 30 - 58% (580 XP)", "Elwynn Forest" },
        "map tooltip uses the full group ranking, exact missing XP and the pin's current location")
    assert(tooltip:IsOwned(pin), "compact player details keep native pin ownership")

    player.xp, ranked.xp = 421, 421
    compact:Notify("ROSTER_CHANGED")
    compactWorld:advance(0.11)
    CheckTooltip(tooltip, { "#7 - Alice", "Lv 30 - 57.9% (579 XP)", "Elwynn Forest" },
        "hover refresh reads new XP without requiring another position sample")
    player.online, ranked.online, player.xpStale, ranked.xpStale = false, false, true, true
    compact:Notify("ROSTER_CHANGED")
    compactWorld:advance(0.11)
    CheckTooltip(tooltip, { "#7 - Alice", "Lv 30 - 57.9% (579 XP)", "Elwynn Forest - 2m ago" },
        "offline players retain saved XP and show contact age rather than the older position timestamp")

    player.level, ranked.level, player.xpState, ranked.xpState, ranked.rank = 60, 60, "max", "max", 1
    compact:Notify("ROSTER_CHANGED")
    compactWorld:advance(0.11)
    CheckTooltip(tooltip, { "#1 - Alice", "Elwynn Forest - 2m ago" },
        "confirmed maximum-level players omit the level and missing-XP line")
    player.level, player.xpState, player.xp, player.xpMax = 30, "unknown", nil, nil
    compactWorld.rankingPlayers = {}
    compact:Notify("ROSTER_CHANGED")
    compactWorld:advance(0.11)
    CheckTooltip(tooltip, { "#? - Alice", "Lv 30 - Awaiting XP", "Elwynn Forest - 2m ago" },
        "missing progress uses the same compact awaiting-XP fallback as the ranking overlay")

    player.sharing = false
    compact:Notify("ROSTER_CHANGED")
    compactWorld:advance(0.11)
    CheckTooltip(tooltip, { "#? - Alice", "Lv 30 - Awaiting XP", "Not sharing - 2m ago" },
        "a peer who stopped sharing does not expose a cached location")
    player.sharing, compact.db.position.sharing = true, false
    compactWorld:advance(0.11)
    CheckTooltip(tooltip, { "#? - Alice", "Lv 30 - Awaiting XP", "Position sharing is off - 2m ago" },
        "disabling local sharing suppresses cached location details in an already-open tooltip")
    compact.db.position.sharing, player.online = true, true
    compactWorld.mapAPI.GetMapInfo = nil
    compactWorld:advance(0.11)
    CheckTooltip(tooltip, { "#? - Alice", "Lv 30 - Awaiting XP", "Map 101" },
        "missing native map names fall back safely without showing online contact ages")

    compactWorld.overviewPlayers = {}
    compact:Notify("ROSTER_CHANGED")
    peer.online = false
    compact:RefreshPositionPins()
    compactWorld:advance(0.01)
    CheckTooltip(tooltip, { "#? - Alice", "Lv ? - Awaiting XP", "Map 101 - 3m ago" },
        "retained position-only players have a safe compact fallback when roster data is unavailable")
end
CheckCompactPlayerDetails()

local function CheckTooltipLifecycle()
    local lifecycle, lifecycleWorld = LoadMap()
    local anchorOwners = {}
    lifecycleWorld.environment.GameTooltip_SetDefaultAnchor = function(tooltip, owner)
        assert(tooltip == lifecycleWorld.tooltip, "global positioning receives the native map tooltip")
        anchorOwners[#anchorOwners + 1] = owner
        tooltip:SetOwner(owner, "ANCHOR_CURSOR")
    end
    lifecycleWorld:loadNativeMap(true)
    local peer = { name = "Alice-Realm", map = 101, x = 0.2, y = 0.4, online = true, class = "MAGE" }
    lifecycle.positions.alice = peer
    lifecycle:InitializePositionMap()
    local tooltip = lifecycleWorld.tooltip
    local hovered = FindPin(lifecycleWorld, peer.name)
    lifecycleWorld:hover(hovered)
    assert(anchorOwners[1] == hovered and tooltip:IsOwned(hovered) and tooltip.anchor == "ANCHOR_CURSOR",
        "map player hover follows global tooltip positioning")
    lifecycleWorld:advance(0.11)
    assert(tooltip:IsOwned(hovered) and tooltip:IsShown() and tooltip.anchor == "ANCHOR_CURSOR",
        "live overlap refresh preserves the globally positioned tooltip")
    peer.online = false
    lifecycle:RefreshPositionPins()
    assert(tooltip:IsShown() and tooltip:IsOwned(hovered), "updating a retained pin preserves its owned tooltip")
    lifecycleWorld:advance(0.01)
    hovered = FindPin(lifecycleWorld, peer.name)
    assert(tooltip:IsShown() and tooltip:IsOwned(hovered), "hover survives an offline refresh after layout")
    CheckTooltip(tooltip, { "#? - Alice", "Lv ? - Awaiting XP", "Elwynn Forest - age unknown" },
        "restored offline hover keeps the same compact format")
    assert(#anchorOwners == 1 and tooltip.anchor == "ANCHOR_CURSOR",
        "incremental updates preserve the global anchor without dismissing or repositioning hover")
    peer.online = true
    lifecycle:RefreshPositionPins()
    lifecycleWorld:advance(0.01)
    hovered = FindPin(lifecycleWorld, peer.name)
    assert(tooltip:IsOwned(hovered), "a fresh sample preserves restored tooltip ownership")
    CheckTooltip(tooltip, { "#? - Alice", "Lv ? - Awaiting XP", "Elwynn Forest" },
        "a fresh sample preserves the compact tooltip and omits contact age for online players")
    CheckDot(hovered, { 0.25, 0.78, 0.92 }, true)

    lifecycle:RefreshPositionPins()
    local foreignOwner = {}
    tooltip:SetOwner(foreignOwner, "ANCHOR_RIGHT")
    tooltip:SetText("Unrelated tooltip")
    tooltip:Show()
    local beforeHide = tooltip.hideCount
    local beforeAnchor = #anchorOwners
    lifecycleWorld:advance(0.01)
    assert(tooltip:IsOwned(foreignOwner) and tooltip.title == "Unrelated tooltip" and tooltip.hideCount == beforeHide,
        "an existing hover loop preserves tooltips opened by another control")
    assert(#anchorOwners == beforeAnchor, "losing hover ownership cannot reposition another control's tooltip")
    hovered = FindPin(lifecycleWorld, peer.name)
    assert(hovered:GetScript("OnUpdate") == nil, "losing hover ownership leaves no idle update")
    tooltip:Hide()

    lifecycleWorld:hover(hovered)
    lifecycleWorld.map:hide()
    assert(not tooltip:IsShown() and hovered:GetScript("OnUpdate") == nil and not hovered.hovered,
        "hiding the map dismisses its owned tooltip and stops stationary hover updates")
    lifecycleWorld.map:show()
    hovered = FindPin(lifecycleWorld, peer.name)
    assert(not tooltip:IsShown(), "opening the map waits for native hover before showing player details")
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
    lifecycle:Notify("POSITIONS_CHANGED")
    assert(not tooltip:IsShown() and #lifecycleWorld.map.pins == 0 and not hovered.hovered
        and hovered.provider == nil and hovered:GetScript("OnUpdate") == nil,
        "clearing positions releases tooltip ownership and pooled player state")

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
    lifecycle:Notify("POSITIONS_CHANGED")
    assert(tooltip:IsShown() and tooltip:IsOwned(foreignOwner) and tooltip.hideCount == beforeHide,
        "map hiding, filtering and clearing positions leave unrelated tooltips intact")
end
CheckTooltipLifecycle()

local function CheckOrgrimmarProjection()
    local city, cityWorld = LoadMap()
    -- Synthetic Orgrimmar/Durotar geometry; one native world axis decreases.
    cityWorld.bounds[1454] = { -1000, -1400, 4000, 4600, continent = 1 }
    cityWorld.bounds[1411] = { -500, -2500, 2000, 6000, continent = 1 }
    cityWorld.rectangles["1454:1414"] = { 0.6, 0.64, 2 / 3, 43 / 60 }
    cityWorld:loadNativeMap(true)
    cityWorld.map.id = 1454
    local peer = { name = "Alice-Realm", map = 1454, x = 0.25, y = 0.5, online = true }
    city.positions.alice = peer
    city:InitializePositionMap()
    Near(cityWorld.map.pins[1].x, 0.25)
    Near(cityWorld.map.pins[1].y, 0.5)
    cityWorld.map:changeMap(1411)
    assert(#cityWorld.map.pins == 1,
        "Orgrimmar positions with a reversed world axis appear on Durotar")
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
Near(projectionWorld.map.pins[1].x, 0.3)
Near(projectionWorld.map.pins[1].y, 0.575)

projectionWorld.rectangles["1456:1414"] = { 0.6, 0.64, 2 / 3, 43 / 60 }
projectionWorld.map:changeMap(1414)
Near(projectionWorld.map.pins[1].x, 0.61)
Near(projectionWorld.map.pins[1].y, 83 / 120)
projectionWorld.map:changeMap(1456)
Near(projectionWorld.map.pins[1].x, 0.25)
Near(projectionWorld.map.pins[1].y, 0.5)
Near(shared.x, 0.25)
Near(shared.y, 0.5)
assert(shared.map == 1456, "map switches preserve shared source coordinates")

projectionWorld.rectangles["1456:1412"] = { 0, 0, 0, 0 }
projectionWorld.map:changeMap(1412)
Near(projectionWorld.map.pins[1].x, 0.3)
Near(projectionWorld.map.pins[1].y, 0.575)
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
-- One invalid or secret sample at each conversion stage exercises the safety boundary.
for stage, result in pairs({ source = { 1, secret }, origin = { 1, Vector(0 / 0, 1100) }, center = {} }) do
    api.GetWorldPosFromMapPos = function(mapID, position)
        local x, y = position:GetXY()
        if stage == "source" and mapID == shared.map
            or stage == "origin" and mapID == 1412 and x == 0 and y == 0
            or stage == "center" and mapID == 1412 and x == 0.5 and y == 0.5 then
            return unpack(result)
        end
        return toWorld(mapID, position)
    end
    projection.positionMapProvider:RefreshAllData()
    assert(#projectionWorld.map.pins == 0, "invalid world geometry remains hidden at " .. stage)
end
api.GetWorldPosFromMapPos = toWorld

local targetBounds = projectionWorld.bounds[1412]
for _, bounds in ipairs({ { 500, 500, 2000, 6000, continent = 1 },
    { 500, 2500, 2000, 2000, continent = 1 } }) do
    projectionWorld.bounds[1412] = bounds
    projection:RefreshPositionPins()
    assert(#projectionWorld.map.pins == 0, "zero world width or height cannot project a position")
end
projectionWorld.bounds[1412] = targetBounds
api.GetWorldPosFromMapPos = nil
projection:RefreshPositionPins()
assert(#projectionWorld.map.pins == 0, "the optional world conversion API may be unavailable")
api.GetWorldPosFromMapPos = toWorld
api.GetMapRectOnMap = rectangle

for _, invalidID in ipairs({ 0, secret }) do
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
local smooth, smoothWorld = LoadMap()
smoothWorld:loadNativeMap(true)
local moving = { name = "Alice-Realm", map = 101, x = 0.2, y = 0.4, online = true }
smooth.positions.alice = moving
smooth:InitializePositionMap()
local movingPin = FindPin(smoothWorld, moving.name)
assert(not movingPin:GetScript("OnUpdate"), "the first sample appears without animation")
moving.x = 0.24
smooth:RefreshPositionPins()
smoothWorld:advance(1)
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.22)
Near(moving.x, 0.24)
assert(movingPin:GetScript("OnUpdate"), "movement interpolates without changing shared coordinates")

moving.x = 0.28
smooth:RefreshPositionPins()
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.22)
smoothWorld:advance(1)
Near(movingPin.x, 0.25)
smooth:RefreshPositionPins()
smoothWorld:advance(1)
Near(movingPin.x, 0.28)
assert(not movingPin:GetScript("OnUpdate"), "retargeting starts at the displayed position; unchanged samples do not restart it")

moving.x, moving.online = 0.3, false
smooth:RefreshPositionPins()
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.3)
assert(not movingPin:GetScript("OnUpdate"), "offline positions snap to their retained coordinates")
moving.x, moving.online = 0.32, true
smooth:RefreshPositionPins()
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.32)
assert(not movingPin:GetScript("OnUpdate"), "reconnecting snaps to the fresh position")
moving.x = 0.7
smooth:RefreshPositionPins()
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.7)
assert(not movingPin:GetScript("OnUpdate"), "large jumps do not sweep across the map")

moving.x = 0.72
smooth:RefreshPositionPins()
smoothWorld:advance(0.5)
smoothWorld.rectangles["102:101"] = { 0, 1, 0, 1 }
moving.map, moving.x = 102, 0.74
smooth:RefreshPositionPins()
movingPin = FindPin(smoothWorld, moving.name)
Near(movingPin.x, 0.74)
assert(not movingPin:GetScript("OnUpdate"), "changing source maps discards the previous transition")

moving.x = 0.76
smooth:RefreshPositionPins()
smooth.positions = { carol = { name = "Carol-Realm", map = 101, x = 0.1, y = 0.2, online = true } }
smooth:RefreshPositionPins()
local carol = FindPin(smoothWorld, "Carol-Realm")
Near(carol.x, 0.1)
assert(not carol:GetScript("OnUpdate"), "pooled frames do not inherit another player's movement")

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

local function CheckIncrementalPins()
    local incremental, clock = LoadMap()
    clock.bounds[1456] = { 1000, 1400, 4000, 4600, continent = 1 }
    clock.bounds[1412] = { 500, 2500, 2000, 6000, continent = 1 }
    clock.bounds[13] = { 1000, 1400, 4000, 4600, continent = 2 }
    clock:loadNativeMap(true)
    clock.map.id = 1412
    for index = 1, 39 do
        incremental.positions[index] = { name = "Player" .. index .. "-Realm", map = 1456,
            x = 0.25, y = 0.5, online = true, class = "MAGE" }
    end
    incremental.positions.offMap = { name = "OffMap-Realm", map = 13, x = 0.25, y = 0.5, online = true }
    incremental:InitializePositionMap()
    local retained = {}
    for index = 1, 39 do retained[index] = FindPin(clock, "Player" .. index .. "-Realm") end
    clock:hover(retained[1])
    local acquired, released, conversions = clock.acquired, clock.released, clock.worldConversions
    for index = 1, 39 do
        incremental.positions[index].x = 0.3
        incremental:Notify("POSITIONS_CHANGED")
    end
    assert(clock.acquired == acquired and clock.released == released,
        "a round of 39 moving peers updates native pins without pool churn")
    assert(clock.worldConversions - conversions == 39 * 3,
        "movement reprojects changed peers without repeating visible or off-map projections for each report")
    for index = 1, 39 do
        assert(FindPin(clock, "Player" .. index .. "-Realm") == retained[index],
            "unrelated peer updates preserve each sender's native pin")
    end
    assert(clock.tooltip:IsOwned(retained[1]) and clock.tooltip:IsShown(),
        "overlapping hover survives movement of every peer")
    local previousMotion = retained[1].motion
    local replacement = { name = "Player1-Realm", map = 1456, x = 0.3, y = 0.5,
        online = true, class = "MAGE", stamp = 1001, positionStamp = 1001 }
    incremental.positions[1] = replacement
    conversions = clock.worldConversions
    incremental:Notify("POSITIONS_CHANGED")
    assert(retained[1].positionPeer == replacement and retained[1].motion == previousMotion
        and clock.worldConversions == conversions,
        "stationary heartbeats replace contact data without projection work or restarting interpolation")
    incremental.positions[2] = nil
    incremental:Notify("POSITIONS_CHANGED")
    assert(clock.released == released + 1 and clock.acquired == acquired
        and FindPin(clock, "Player1-Realm") == retained[1] and #clock.map.pins == 38,
        "removing one peer releases only its native pin")
    replacement.class = "WARRIOR"
    incremental:Notify("POSITIONS_CHANGED")
    CheckDot(retained[1], { 0.78, 0.61, 0.43 }, true)
    assert(clock.worldConversions == conversions, "class changes repaint without reprojecting coordinates")
    clock.bounds[1412] = { 0, 2000, 2000, 6000, continent = 1 }
    clock.map:changeMap(1412)
    Near(retained[1].x, 0.56)
    assert(not retained[1].motion.started,
        "native map-art changes reproject and snap retained pins even for an unchanged map ID")
    clock.bounds[13].continent = 1
    clock:advance(1.01)
    incremental:Notify("POSITIONS_CHANGED")
    assert(FindPin(clock, "OffMap-Realm"),
        "failed projections are retried after a bounded delay so temporarily unavailable geometry can recover")
end
CheckIncrementalPins()

local function CheckTooltipSnapshotReuse()
    local cached, clock = LoadMap()
    clock:loadNativeMap(true)
    cached.positions.alice = { name = "Alice-Realm", map = 101, x = 0.25, y = 0.5, online = true }
    cached:InitializePositionMap()
    clock:hover(FindPin(clock, "Alice-Realm"))
    local overviewReads, rankingReads = clock.overviewReads, clock.rankingReads
    for index = 1, 8 do clock:advance(0.11) end
    assert(clock.overviewReads == overviewReads and clock.rankingReads == rankingReads,
        "overlap animation and tooltip refreshes reuse one roster/ranking snapshot within a second")
    clock:advance(0.22)
    assert(clock.overviewReads == overviewReads + 1 and clock.rankingReads == rankingReads + 1,
        "tooltip metadata refreshes periodically so silent peers can expire without another report")
    cached:Notify("ROSTER_CHANGED")
    clock:advance(0.11)
    assert(clock.overviewReads == overviewReads + 2 and clock.rankingReads == rankingReads + 2,
        "roster updates invalidate the tooltip snapshot before its periodic refresh")
end
CheckTooltipSnapshotReuse()

local function CheckNativeGroupPins()
    local grouped, clock = LoadMap()
    clock:loadNativeMap(true)
    local alice = { name = "Alice-Realm", map = 101, x = 0.25, y = 0.5,
        online = true, positionAvailable = true, positionStamp = 900, stamp = 1000 }
    local otherRealm = { name = "Alice-OtherRealm", map = 101, x = 0.5, y = 0.5,
        online = true, inParty = true }
    grouped.positions = { alice = alice, otherRealm = otherRealm }
    grouped:InitializePositionMap()
    assert(#clock.map.pins == 2, "players in another group still retain their LIT pins")

    clock.groupUnits.party1, clock.partyCount = { "Alice", "" }, 1
    -- A stitched map can draw a party marker outside its underlying map even
    -- though the per-unit coordinate API returns no position for that map.
    clock:fire("GROUP_ROSTER_UPDATE")
    assert(#clock.map.pins == 1 and FindPin(clock, otherRealm.name),
        "party joins hide the matching live pin even without an underlying-map unit projection")
    assert(clock.nativePositionReads == 0, "duplicate detection does not query the per-unit coordinate API")
    assert(grouped.positions.alice == alice and grouped.positions.otherRealm == otherRealm
        and alice.x == 0.25 and alice.y == 0.5 and alice.positionStamp == 900 and alice.stamp == 1000
        and grouped.db.position.sharing,
        "deduplication retains shared positions, contact times and sharing preferences")
    local nameReads = clock.unitNameReads
    for index = 1, 8 do grouped:RefreshPositionPins() end
    clock:advance(1.1)
    assert(clock.unitNameReads == nameReads,
        "refreshes and periodic availability checks reuse native membership without scanning unit names")

    clock.groupUnits, clock.partyCount = {}, 0
    clock:fire("GROUP_ROSTER_UPDATE")
    assert(#clock.map.pins == 2 and FindPin(clock, alice.name).positionPeer == alice,
        "party departures immediately restore the retained position without requiring another report")

    clock.isRaid, clock.raidCount = true, 2
    clock.groupUnits = { raid1 = { "Self", "Realm" }, raid2 = { "Alice", "Realm" } }
    clock.nativeSubgroup.raid2 = false
    clock.nativeFilters.party = false
    clock:fire("GROUP_ROSTER_UPDATE")
    assert(#clock.map.pins == 1 and grouped:GetNativeGroupUnit(alice.name) == "raid2",
        "conversion to a raid replaces cached unit tokens and checks the raid marker category")
    clock.battlefield = true
    grouped:RefreshPositionPins()
    assert(#clock.map.pins == 2,
        "battleground home-party overrides with differing native filters preserve the fallback")
    clock.battlefield = false
    grouped:RefreshPositionPins()
    assert(#clock.map.pins == 1)
    clock.environment.C_PvP.IsActiveBattlefield = nil
    grouped:RefreshPositionPins()
    assert(#clock.map.pins == 2, "unknown battlefield state cannot guess a differently filtered native category")
    clock.environment.C_PvP.IsActiveBattlefield = function() return false end
    grouped:RefreshPositionPins()
    assert(#clock.map.pins == 1)
    clock.nativeFilters.raid = false
    grouped:RefreshPositionPins()
    assert(#clock.map.pins == 2, "hidden native raid markers retain the addon fallback")
    clock.nativeFilters.raid = true
    clock.nativeSubgroup.raid2 = true
    grouped:RefreshPositionPins()
    assert(#clock.map.pins == 2, "raid members in the player's subgroup use the party marker filter")
    clock.nativeFilters.party = true
    grouped:RefreshPositionPins()
    assert(#clock.map.pins == 1)

    for _, state in ipairs({ "unavailable", "offline" }) do
        if state == "unavailable" then alice.positionAvailable = false else alice.online = false end
        grouped:Notify("POSITION_CONTACT_CHANGED")
        assert(#clock.map.pins == 2 and FindPin(clock, alice.name).positionPeer == alice,
            "contact-only updates immediately restore a last-known position when " .. state)
        Near(FindPin(clock, alice.name).x, 0.25)
        alice.positionAvailable, alice.online = true, true
        grouped:Notify("POSITION_CONTACT_CHANGED")
        assert(#clock.map.pins == 1, "fresh contact data hides the duplicate again")
    end

    clock.nativeConnected.raid2 = false
    clock:fire("UNIT_CONNECTION", "raid2")
    assert(#clock.map.pins == 2, "native connection loss immediately restores the last-known position")
    clock.nativeConnected.raid2 = true
    clock:fire("UNIT_CONNECTION", "raid2")
    assert(#clock.map.pins == 1, "native connection recovery removes the duplicate again")

    local function CheckFallback(target, key, value, label)
        local previous = target[key]
        target[key] = value
        clock:fire("ZONE_CHANGED_NEW_AREA")
        assert(#clock.map.pins == 2, label .. " preserves the retained addon fallback")
        target[key] = previous
        clock:fire("ZONE_CHANGED_NEW_AREA")
        assert(#clock.map.pins == 1, label .. " recovery hides the duplicate")
    end
    CheckFallback(clock.nativePin, "shown", false, "A hidden native group frame")
    CheckFallback(clock.nativePin, "mapID", 100, "A native frame on another map")
    CheckFallback(clock.nativePin, "dataProvider", nil, "A missing native provider")
    CheckFallback(clock.nativePin.dataProvider, "ShouldShowUnit", nil, "A missing native filter API")
    CheckFallback(clock.nativePin.dataProvider, "ShouldShowUnit", function() error("native filter unavailable") end,
        "A failing native filter API")
    local secret = {}
    clock.secretValues[secret] = true
    CheckFallback(clock.nativeConnected, "raid2", secret, "A secret native connection state")
    CheckFallback(clock.nativeSubgroup, "raid2", secret, "A secret native subgroup state")
    CheckFallback(clock.nativePin.dataProvider, "ShouldShowUnit", function() return secret end,
        "A secret native filter state")
    CheckFallback(clock, "nativePin", nil, "An absent native group frame")
    CheckFallback(clock.map, "EnumeratePinsByTemplate", nil, "A missing native pin iterator")

    clock.mapAPI.GetPlayerMapPosition = function() error("per-unit coordinates are unavailable") end
    clock:fire("ZONE_CHANGED_NEW_AREA")
    assert(#clock.map.pins == 1, "unsupported raid coordinate queries cannot prevent duplicate suppression")
    clock.mapAPI.GetPlayerMapPosition = nil
    clock:fire("ZONE_CHANGED_NEW_AREA")
    assert(#clock.map.pins == 1, "missing per-unit coordinates cannot prevent duplicate suppression")

    clock.nativeConnected.raid2 = false
    clock:advance(1.1)
    assert(#clock.map.pins == 2, "idle native connection loss restores fallback within a bounded visible-map check")
    clock.nativeConnected.raid2 = true
    clock:advance(1.1)
    assert(#clock.map.pins == 1, "idle native connection recovery hides the duplicate without a new shared report")
    clock.map:hide()
    local unitChecks = clock.nativeUnitChecks
    nameReads = clock.unitNameReads
    clock:advance(5)
    assert(clock.nativeUnitChecks == unitChecks and clock.unitNameReads == nameReads,
        "hidden maps perform no periodic native availability or membership work")
    clock.map:show()
    assert(#clock.map.pins == 1 and #clock.notificationErrors == 0,
        "reopening applies current native availability without affecting native markers")
    local provider = grouped.positionMapProvider
    provider:OnRemoved(clock.map)
    assert(not clock.map.updateProvider and not grouped.positionMapProvider and not provider:GetMap(),
        "removing the provider unregisters its native update callback and delegates base cleanup")
end
CheckNativeGroupPins()

local function CheckNativeGroupAliases()
    local grouped, clock = LoadMap()
    clock:loadNativeMap(true)
    clock.partyCount = 1
    clock.groupUnits.party1 = { "DisplayName", "InternalRealm" }
    clock.environment.NameUtil = { GetUnmodifiedUnitFullName = function(unit)
        if unit == "party1" then return "WireName-Realm" end
    end }
    local peer = { name = "WireName-Realm", map = 101, x = 0.25, y = 0.5,
        online = true, positionAvailable = true }
    grouped.positions = { wire = peer,
        foreign = { name = "WireName-OtherRealm", map = 101, x = 0.5, y = 0.5, online = true } }
    grouped:InitializePositionMap()
    assert(#clock.map.pins == 1 and FindPin(clock, "WireName-OtherRealm")
        and grouped.positions.wire == peer,
        "wire-name aliases suppress only the grouped character, preserving other realms and shared data")
    clock.groupUnits, clock.partyCount = {}, 0
    clock:fire("GROUP_ROSTER_UPDATE")
    assert(#clock.map.pins == 2 and FindPin(clock, peer.name).positionPeer == peer,
        "leaving a native group restores an aliased player's retained pin without a new report")
end
CheckNativeGroupAliases()

local function CheckNativeRaidRefreshCost()
    local grouped, clock = LoadMap()
    clock:loadNativeMap(true)
    clock.isRaid, clock.raidCount = true, 40
    clock.groupUnits.raid1 = { "Self", "Realm" }
    for index = 1, 39 do
        clock.groupUnits["raid" .. (index + 1)] = { "Player" .. index, "Realm" }
        grouped.positions[index] = { name = "Player" .. index .. "-Realm", map = 101,
            x = 0.25, y = 0.5, online = true, positionAvailable = true }
    end
    grouped:InitializePositionMap()
    assert(#clock.map.pins == 0 and clock.nativeUnitChecks == 39 and clock.nativePositionReads == 0,
        "a full native raid replaces all 39 live peer pins without depending on per-unit coordinates")
    local nameReads, unitChecks = clock.unitNameReads, clock.nativeUnitChecks
    for index = 1, 39 do
        grouped.positions[index].x = 0.3
        grouped:Notify("POSITIONS_CHANGED")
    end
    for index = 1, 5 do clock:advance(0.1) end
    assert(clock.unitNameReads == nameReads and clock.nativeUnitChecks == unitChecks,
        "39 movement reports and frame callbacks reuse membership and native availability within a second")
    clock:advance(0.51)
    assert(clock.unitNameReads == nameReads and clock.nativeUnitChecks == unitChecks + 39,
        "native availability is checked once per unit after the bounded cache expires")
    grouped.positions[1].positionAvailable = false
    grouped:Notify("POSITION_CONTACT_CHANGED")
    assert(#clock.map.pins == 1 and FindPin(clock, "Player1-Realm"),
        "cached native availability never suppresses a newly unavailable shared-position fallback")
    assert(clock.nativeUnitChecks == unitChecks + 39 and clock.nativePositionReads == 0,
        "contact-only fallback updates retain the bounded native availability cache")
end
CheckNativeRaidRefreshCost()

local function LoadDeathMap()
    local mapped, clock = LoadMap()
    clock.life, clock.unitPositions = {}, {}
    clock.groupUnits.player = { "Self", "Realm" }
    local api = clock.environment
    api.UnitIsUnit = function(unit, other)
        return clock.groupUnits[unit] ~= nil and clock.groupUnits[unit] == clock.groupUnits[other]
    end
    api.UnitIsDead = function(unit) return clock.life[unit] == "dead" end
    api.UnitIsGhost = function(unit) return clock.life[unit] == "ghost" end
    api.UnitIsDeadOrGhost = function(unit) return api.UnitIsDead(unit) or api.UnitIsGhost(unit) end
    clock.mapAPI.GetBestMapForUnit = function(unit)
        local position = clock.unitPositions[unit]
        return position and position.map
    end
    clock.mapAPI.GetPlayerMapPosition = function(mapID, unit)
        local position = clock.unitPositions[unit]
        if position and position.map == mapID and position.x then return Vector(position.x, position.y) end
    end
    function clock:setLife(unit, state, mapID, x, y)
        self.life[unit] = state
        self.unitPositions[unit] = mapID and { map = mapID, x = x, y = y } or nil
        self:fire("UNIT_FLAGS", unit)
    end
    function clock:deathPins()
        local pins = {}
        for _, pin in ipairs(self.map.pins) do
            if pin.template == DEATH_PIN then pins[#pins + 1] = pin end
        end
        return pins
    end
    return mapped, clock
end

local function MockDeathMinimap(clock, playerX, playerY)
    local api = clock.environment
    local minimap = { radius = 100, facing = 0, visible = true }
    function minimap:GetWidth() return 200 end
    function minimap:GetHeight() return 200 end
    function minimap:IsVisible() return self.visible end
    api.Minimap = minimap
    api.C_Minimap = {
        GetViewRadius = function() return minimap.radius end,
        IsRotateMinimapIgnored = function() return minimap.ignoreRotation == true end,
    }
    api.GetCVarBool = function(name)
        assert(name == "rotateMinimap")
        return minimap.rotate == true
    end
    api.GetPlayerFacing = function() return minimap.facing end
    api.GetMinimapShape = function() return "ROUND" end
    clock.bounds[101] = { 1000, 0, 2000, 1000, continent = 1 }
    clock.unitPositions.player = { map = 101, x = playerX, y = playerY }

    local createFrame, advance = api.CreateFrame, clock.advance
    local driver, pins = nil, {}
    api.CreateFrame = function(kind, name, parent, template)
        if parent ~= minimap and (not driver or parent ~= driver) then
            return createFrame(kind, name, parent, template)
        end
        assert(kind == "Frame")
        local frame = { scripts = {}, shown = true }
        function frame:IsShown() return self.shown end
        function frame:IsVisible() return self:IsShown() and parent:IsVisible() end
        function frame:Show()
            local wasVisible = self:IsVisible()
            self.shown = true
            if not wasVisible and self:IsVisible() and self.scripts.OnShow then self.scripts.OnShow(self) end
        end
        function frame:Hide()
            local wasVisible = self:IsVisible()
            self.shown = false
            if not wasVisible then return end
            if self.scripts.OnHide then self.scripts.OnHide(self) end
            if self == driver then
                for _, pin in ipairs(pins) do
                    if pin:IsShown() and pin.scripts.OnHide then pin.scripts.OnHide(pin) end
                end
            end
        end
        function frame:SetSize() end
        function frame:SetScript(script, callback) self.scripts[script] = callback end
        function frame:ClearAllPoints() self.offsetX, self.offsetY = nil, nil end
        function frame:SetPoint(point, relative, anchor, x, y)
            assert(point == "CENTER" and relative == minimap and anchor == "CENTER")
            self.offsetX, self.offsetY = x, y
        end
        if parent == minimap then
            assert(not driver, "reuse one minimap update frame")
            driver = frame
        else
            assert(template == "LockInToolsDeathMarkerTemplate", "reuse the death marker artwork")
            pins[#pins + 1] = frame
        end
        return frame
    end
    function clock:advance(seconds)
        advance(self, seconds)
        if driver and driver:IsVisible() and driver.scripts.OnUpdate then driver.scripts.OnUpdate(driver, seconds) end
    end
    function clock:minimapPins()
        local visible = {}
        for _, pin in ipairs(pins) do
            if pin:IsVisible() then visible[#visible + 1] = pin end
        end
        return visible
    end
    return minimap
end

do
    local mapped, clock = LoadDeathMap()
    local minimap = MockDeathMinimap(clock, 0.5, 0.5)
    clock.groupUnits.party1, clock.partyCount = { "Alice", "Realm" }, 1
    mapped:InitializePositionMap()
    clock:setLife("party1", "dead", 101, 0.52, 0.47)
    local pins = clock:minimapPins()
    assert(#pins == 1 and not clock.map, "a nearby death appears on the minimap before the World Map loads")
    Near(pins[1].offsetX, 20)
    Near(pins[1].offsetY, 30)

    clock:setLife("party1", "ghost", 102, 0.8, 0.9)
    clock:advance(0.1)
    pins = clock:minimapPins()
    assert(#pins == 1, "the minimap keeps the corpse marker through spirit release")
    Near(pins[1].offsetX, 20)
    Near(pins[1].offsetY, 30)

    minimap.rotate, minimap.facing = true, math.pi / 2
    clock:advance(0.1)
    Near(pins[1].offsetX, 30)
    Near(pins[1].offsetY, -20)
    minimap.ignoreRotation, minimap.radius = true, 50
    clock:advance(0.1)
    Near(pins[1].offsetX, 40)
    Near(pins[1].offsetY, 60)

    clock.bounds[102] = clock.bounds[101]
    clock.mapAPI.GetMapGroupID = function() return 1 end
    clock.unitPositions.player.map = 102
    clock:advance(0.1)
    assert(#clock:minimapPins() == 0, "overlapping coordinates on another dungeon floor do not show the marker")
    clock.unitPositions.player.map = 101
    clock:advance(0.1)

    local pin = pins[1]
    pin.scripts.OnEnter(pin)
    local color = clock.tooltip.titleColor
    assert(clock.tooltip:IsShown() and clock.tooltip:IsOwned(pin) and clock.tooltip.title == "Alice"
        and color[1] == 1 and color[2] == 0 and color[3] == 0,
        "a minimap skull displays the same red player name")
    clock.unitPositions.player.x, clock.unitPositions.player.y = 0.48, 0.51
    clock:advance(0.1)
    assert(#clock:minimapPins() == 0 and not clock.tooltip:IsShown(),
        "a death outside the round minimap hides its marker and tooltip")
    clock.unitPositions.player.x, clock.unitPositions.player.y = 0.5, 0.5
    clock:advance(0.1)
    pins = clock:minimapPins()
    assert(#pins == 1, "moving back into range restores the marker")

    pins[1].scripts.OnEnter(pins[1])
    assert(mapped:SetShowDeathMarkers(false) and #clock:minimapPins() == 0 and not clock.tooltip:IsShown(),
        "the shared visibility setting immediately hides minimap death markers and the tooltip")
    assert(mapped:SetShowDeathMarkers(true) and #clock:minimapPins() == 1,
        "the shared visibility setting restores nearby death markers")
    clock:setLife("party1", "alive", 102, 0.8, 0.9)
    assert(#clock:minimapPins() == 0, "revival immediately clears the minimap marker")
    clock:setLife("party1", "dead", 101, 0.52, 0.47)
    assert(#clock:minimapPins() == 1, "a subsequent death creates another minimap marker")
    clock.groupUnits.party1, clock.partyCount = nil, 0
    clock:fire("GROUP_ROSTER_UPDATE")
    assert(#clock:minimapPins() == 0, "leaving the group immediately clears the minimap marker")
end

do
    local mapped, clock = LoadDeathMap()
    clock.groupUnits.party1, clock.partyCount = { "Alice", "Realm" }, 1
    mapped.db.position.sharing, mapped.db.position.keepLastKnown = false, false
    assert(mapped:GetShowDeathMarkers(), "death markers default on for a profile without the preference")
    mapped:InitializePositionMap()
    clock:setLife("party1", "dead", 101, 0.23, 0.42)
    clock:setLife("party1", "ghost", 102, 0.8, 0.9)
    clock:loadNativeMap(false)
    clock:fire("ADDON_LOADED", "Blizzard_WorldMap")
    clock.map:show()
    local pins = clock:deathPins()
    assert(#pins == 1, "a death before opening the map retains one pin through spirit release")
    Near(pins[1].x, 0.23)
    Near(pins[1].y, 0.42)

    clock:hover(pins[1])
    assert(clock.tooltip:IsShown() and clock.tooltip:IsOwned(pins[1]) and clock.tooltip.title == "Alice"
        and clock.tooltip.anchor == "ANCHOR_NONE", "a skull shows the player's display name at the default tooltip anchor")
    local color = clock.tooltip.titleColor
    assert(color[1] == 1 and color[2] == 0 and color[3] == 0, "the skull tooltip displays the name in pure red")
    clock:leave(pins[1])
    assert(not clock.tooltip:IsShown(), "leaving a skull dismisses its tooltip")
    clock:hover(pins[1])
    clock.map:hide()
    assert(not clock.tooltip:IsShown(), "closing the map dismisses the hovered skull's tooltip")
    clock.map:show()
    assert(#clock:deathPins() == 1 and not clock.tooltip:IsShown(), "reopening restores the skull without its tooltip")

    mapped.db.position.sharing = true
    mapped.positions.bob = { name = "Bob-Realm", map = 101, x = 0.4, y = 0.5, online = true }
    mapped:RefreshPositionPins()
    local deathFilter = clock:openMenu("MENU_WORLD_MAP_TRACKING")[5]
    deathFilter:Click()
    assert(not mapped:GetShowDeathMarkers() and mapped.db.position.showDeathMarkers == false
        and #clock:deathPins() == 0 and FindPin(clock, "Bob-Realm"),
        "disabling death markers hides only skulls and saves the preference")
    deathFilter = clock:openMenu("MENU_WORLD_MAP_TRACKING")[5]
    assert(not deathFilter:IsSelected(), "reopening the menu reflects the saved death marker preference")
    deathFilter:Click()
    assert(mapped:GetShowDeathMarkers() and mapped.db.position.showDeathMarkers == true)
    pins = clock:deathPins()
    assert(#pins == 1, "re-enabling death markers restores the frozen location")
    Near(pins[1].x, 0.23)
    Near(pins[1].y, 0.42)
    assert(mapped:SetShowPlayerIcons(false) and #clock.map.pins == 1 and #clock:deathPins() == 1,
        "disabling player icons keeps the death marker visible")
    assert(mapped:SetShowPlayerIcons(true))

    clock.rectangles["101:100"] = { 0.1, 0.5, 0.2, 0.6 }
    clock.map:changeMap(100)
    pins = clock:deathPins()
    assert(#pins == 1, "death pins project onto a parent map")
    Near(pins[1].x, 0.192)
    Near(pins[1].y, 0.368)
    clock.map:changeMap(102)
    assert(#clock:deathPins() == 0, "ghost movement does not place a pin on the release map")
    clock.map:changeMap(101)
    clock.nativeConnected.party1, clock.life.party1 = false, nil
    clock:fire("UNIT_CONNECTION", "party1")
    assert(#clock:deathPins() == 1, "an offline member's unavailable death state does not imply revival")
    clock.nativeConnected.party1 = true
    clock:setLife("party1", "alive", 102, 0.8, 0.9)
    assert(#clock:deathPins() == 0, "reviving after release removes the visible death pin")
    assert(mapped:SetShowDeathMarkers(false))
    clock:setLife("party1", "dead", 101, 0.6, 0.7)
    assert(#clock:deathPins() == 0, "death markers stay hidden when another player dies")
    assert(mapped:SetShowDeathMarkers(true))
    pins = clock:deathPins()
    assert(#pins == 1, "a death that occurred while markers were hidden has a captured location")
    Near(pins[1].x, 0.6)
    Near(pins[1].y, 0.7)
    clock:hover(pins[1])
    clock:setLife("party1", "alive", 101, 0.6, 0.7)
    assert(#clock:deathPins() == 0 and not clock.tooltip:IsShown(),
        "reviving before release removes the hovered death pin and its tooltip")
end

do
    local mapped, clock = LoadDeathMap()
    clock.groupUnits.party1, clock.partyCount = { "Alice", "Realm" }, 1
    clock:loadNativeMap(true)
    mapped:InitializePositionMap()
    clock:setLife("party1", "dead", 101, 0.2, 0.3)
    clock.isRaid, clock.partyCount, clock.raidCount = true, 0, 3
    clock.groupUnits.raid1 = clock.groupUnits.player
    clock.groupUnits.raid2, clock.groupUnits.party1 = clock.groupUnits.party1, nil
    clock.groupUnits.raid3 = { "Bob", "Realm" }
    clock.life.raid2 = "ghost"
    clock:fire("GROUP_ROSTER_UPDATE")
    local pins = clock:deathPins()
    assert(#pins == 1, "party to raid conversion preserves the same member's death location")
    Near(pins[1].x, 0.2)
    Near(pins[1].y, 0.3)

    clock:setLife("raid3", "dead", 101, 0.7, 0.8)
    assert(#clock:deathPins() == 2, "a second raid death displays a separate pin")
    clock:setLife("raid1", "dead", 101, 0.5, 0.6)
    assert(#clock:deathPins() == 2, "the observer's own raid unit uses the native corpse marker")
    clock.groupUnits.raid2, clock.groupUnits.raid3 = clock.groupUnits.raid3, nil
    clock.raidCount, clock.life.raid2 = 2, "dead"
    clock:fire("GROUP_ROSTER_UPDATE")
    pins = clock:deathPins()
    assert(#pins == 1, "leaving removes the correct member's pin even when another member reuses the token")
    Near(pins[1].x, 0.7)
    Near(pins[1].y, 0.8)
    clock.isRaid, clock.raidCount = false, 0
    clock.groupUnits.raid1, clock.groupUnits.raid2 = nil, nil
    clock:fire("GROUP_ROSTER_UPDATE")
    assert(#clock:deathPins() == 0, "leaving the group clears all remaining death pins")
    clock.groupUnits.party1, clock.partyCount = { "Bob", "Realm" }, 1
    clock.life.party1 = "ghost"
    clock:fire("GROUP_ROSTER_UPDATE")
    assert(#clock:deathPins() == 0, "a later group does not restore a discarded death location")
end

do
    local mapped, clock = LoadDeathMap()
    clock.groupUnits.party1, clock.partyCount = { "Alice", "Realm" }, 1
    mapped.positions.alice = { name = "Alice-Realm", map = 101, x = 0.8, y = 0.9, online = false }
    clock:loadNativeMap(true)
    mapped:InitializePositionMap()
    clock:setLife("party1", "dead", 101)
    assert(#clock:deathPins() == 0 and FindPin(clock, "Alice-Realm"),
        "a missing death position cannot turn a retained player location into a death pin")
    clock:setLife("party1", "ghost", 101, 0.4, 0.5)
    assert(#clock:deathPins() == 0, "a readable ghost position cannot substitute for the missing death position")
end

do
    local helpers = dofile("tests/support/helpers.lua")
    local original, before = LoadDeathMap()
    before.groupUnits.party1, before.partyCount = { "Alice", "Realm" }, 1
    original:InitializePositionMap()
    before:fire("PLAYER_ENTERING_WORLD", true, false)
    before:setLife("party1", "dead", 101, 0.21, 0.43)
    before:setLife("party1", "ghost", 102, 0.8, 0.9)
    before:fire("PLAYER_LOGOUT")
    local saved = helpers.copy(original.db)

    local function Restore(scenario, database)
        local mapped, clock = LoadDeathMap()
        mapped.db = helpers.copy(database or saved)
        mapped.savedDataReadOnly = scenario.readOnly
        clock.groupUnits.player[1] = scenario.observer or "Self"
        clock.serverNow = before.serverNow + (scenario.elapsed or 1)
        if scenario.life ~= "departed" then
            clock.groupUnits.party1, clock.partyCount = { "Alice", "Realm" }, 1
            clock.life.party1 = scenario.life or "ghost"
            clock.nativeConnected.party1 = scenario.connected ~= false
            clock.unitPositions.party1 = { map = 102, x = 0.8, y = 0.9 }
        end
        MockDeathMinimap(clock, 0.2, 0.4)
        clock:loadNativeMap(true)
        mapped:InitializePositionMap()
        assert(#clock:deathPins() == 0, "saved locations stay hidden until entering the world on login or reload")
        clock:fire("PLAYER_ENTERING_WORLD", scenario.initialLogin == true, scenario.reload ~= false)
        return mapped, clock
    end

    local reloaded, clock = Restore({ elapsed = 3600 })
    local pins = clock:deathPins()
    assert(#pins == 1, "UI reload restores an old death location for the still-grouped ghost")
    Near(pins[1].x, 0.21)
    Near(pins[1].y, 0.43)
    local minimapPins = clock:minimapPins()
    assert(#minimapPins == 1, "the minimap uses the same restored death location")
    Near(minimapPins[1].offsetX, 10)
    Near(minimapPins[1].offsetY, -30)
    clock:fire("PLAYER_ENTERING_WORLD", false, false)
    assert(#clock:deathPins() == 1, "a later zone entry preserves the confirmed death location")
    clock.map:changeMap(102)
    assert(#clock:deathPins() == 0, "reload does not move the marker to the ghost's current position")
    clock.map:changeMap(101)
    clock:setLife("party1", "alive", 102, 0.8, 0.9)
    assert(#clock:deathPins() == 0, "revive removes a restored death location")
    clock:fire("PLAYER_LOGOUT")
    local _, afterRevive = Restore({ elapsed = 3601 }, reloaded.db)
    assert(#afterRevive:deathPins() == 0, "a later reload cannot restore a cleared death location")

    local _, loggedIn = Restore({ initialLogin = true, reload = false, elapsed = 7200 })
    pins = loggedIn:deathPins()
    assert(#pins == 1, "fresh login restores an old death location for the still-grouped ghost")
    Near(pins[1].x, 0.21)
    Near(pins[1].y, 0.43)

    local _, zoned = Restore({ reload = false })
    assert(#zoned:deathPins() == 0, "ordinary zone entry does not restore a saved death location")

    for _, scenario in ipairs({
        { life = "alive", description = "for a member who revived" },
        { life = "departed", description = "for a member who left" },
        { connected = false, description = "for a member whose status cannot be confirmed" },
        { observer = "Other", description = "for a different observing character" },
        { readOnly = true, description = "from a newer-schema database" },
    }) do
        local mapped, rejected = Restore(scenario)
        assert(#rejected:deathPins() == 0, "skip restoring a death location " .. scenario.description)
        if scenario.readOnly then
            assert(helpers.equal(mapped.db, saved), "reload preserves newer-schema saved data")
        else
            assert(mapped.db.position.deathMarkers == nil, "entry consumes an ineligible saved snapshot")
        end
    end
end

local function CheckShowPlayerOnMap()
    local mapped, clock = LoadMap()
    local id, calls = "alice-realm", 0
    local function OpenMap(mapID)
        calls = calls + 1
        if not clock.map then
            clock:loadNativeMap(false)
            clock:fire("ADDON_LOADED", "Blizzard_WorldMap")
        end
        if clock.map:GetMapID() ~= mapID then clock.map:changeMap(mapID) end
        if not clock.map:IsShown() then clock.map:show() end
    end
    clock.mapAPI.OpenWorldMap = OpenMap
    clock.environment.OpenWorldMap = function() error("prefer the namespaced map API") end
    mapped.positions[id] = { name = "Alice-Realm", map = 102, x = 0.25, y = 0.5,
        online = false, positionAvailable = false }
    mapped:InitializePositionMap()
    local allowed, reason = mapped:GetPlayerMapActionState(id)
    assert(allowed and reason == nil and not clock.map and calls == 0,
        "checking a retained location does not open or load the world map")
    assert(mapped:ShowPlayerOnMap(id))
    local pin = FindPin(clock, "Alice-Realm")
    assert(clock.map:IsShown() and clock.map:GetMapID() == 102 and clock.added == 1 and calls == 1,
        "the map action loads native map code and opens the retained location's source map")
    Near(pin.x, 0.25)
    Near(pin.y, 0.5)
    CheckDot(pin, staleColor, false)

    mapped.positions[id] = { name = "Alice-Realm", map = 103, x = 0.7, y = 0.9, online = true }
    assert(mapped:ShowPlayerOnMap(id) and clock.map:GetMapID() == 103,
        "the action resolves the current position instead of a menu-time snapshot")
    pin = FindPin(clock, "Alice-Realm")
    Near(pin.x, 0.7)
    Near(pin.y, 0.9)
    assert(mapped.db.position.sharing and mapped.db.position.showPlayerIcons,
        "showing a location preserves sharing and visibility preferences")

    local function PinInView()
        local halfSpan = 0.5 / clock.map.zoom
        return math.abs(pin.x - clock.map.panX) <= halfSpan
            and math.abs(pin.y - clock.map.panY) <= halfSpan
    end
    clock.map.zoom, clock.map.panX, clock.map.panY = 4, 0.125, 0.125
    assert(not PinInView(), "the selected player starts outside the already-open map's zoomed viewport")
    assert(mapped:ShowPlayerOnMap(id))
    assert(clock.map:GetMapID() == 103 and clock.map:IsShown() and PinInView(),
        "showing a player on the same map immediately brings their pin inside the viewport")
    Near(clock.map.zoom, 4)
    Near(pin.x, 0.7)
    Near(pin.y, 0.9)

    local focusMap = clock.map.InstantPanAndZoom
    clock.map.InstantPanAndZoom = function() error("native viewport unavailable") end
    local focused, focusMessage = mapped:ShowPlayerOnMap(id)
    assert(not focused and focusMessage == "Could not bring this player into view. Open the world map and try again.",
        "a failed viewport update is reported instead of claiming the selected player is visible")
    clock.map.InstantPanAndZoom = focusMap

    local function Rejected(expected)
        local before = calls
        local available, disabledReason = mapped:GetPlayerMapActionState(id)
        local success, message = mapped:ShowPlayerOnMap(id)
        assert(not available and disabledReason == expected and not success and message == expected
            and calls == before, "unavailable actions explain the reason without opening a map")
    end
    mapped.db.position.showPlayerIcons = false
    Rejected("Enable 'Show player icons' in the world map filter first.")
    assert(not mapped.db.position.showPlayerIcons, "the action never enables a hidden map filter")
    mapped.db.position.showPlayerIcons = true
    mapped.positions[id] = nil
    Rejected("No shared location is available for this player.")
    for _, position in ipairs({
        { name = "Alice-Realm", map = 0, x = 0.25, y = 0.5 },
        { name = "Alice-Realm", map = 102, x = 0 / 0, y = 0.5 },
        { name = "Alice-Realm", map = 102, x = 0.25, y = 1.1 },
    }) do
        mapped.positions[id] = position
        Rejected("No shared location is available for this player.")
    end

    mapped.positions[id] = { name = "Alice-Realm", map = 102, x = 0.25, y = 0.5 }
    clock.mapAPI.OpenWorldMap = nil
    clock.environment.OpenWorldMap = OpenMap
    assert(mapped:ShowPlayerOnMap(id) and clock.map:GetMapID() == 102,
        "clients without the namespaced opener use the native global API")
    clock.environment.OpenWorldMap = nil
    Rejected("The world map is unavailable in this client.")

    local failure = "Could not show this location. Open the world map and try again."
    clock.mapAPI.OpenWorldMap = function() error("native map unavailable") end
    local success, message = mapped:ShowPlayerOnMap(id)
    assert(not success and message == failure, "native opening errors become a visible action failure")
    clock.mapAPI.OpenWorldMap = function() end
    clock.map:hide()
    success, message = mapped:ShowPlayerOnMap(id)
    assert(not success and message == failure, "a native opener that leaves the map closed is not success")
    clock.map:changeMap(103)
    clock.map:show()
    success, message = mapped:ShowPlayerOnMap(id)
    assert(not success and message == failure, "an open map showing another region is not success")
    clock.environment.WorldMapFrame = nil
    success, message = mapped:ShowPlayerOnMap(id)
    assert(not success and message == failure, "an absent native map frame is not success")
end
CheckShowPlayerOnMap()

print("PASS: map attachment/filter, player map action, compact player details, tooltip ownership, projection, movement, native death pins and pooled lifecycle")
