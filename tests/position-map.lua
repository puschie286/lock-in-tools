-- Mock native MapCanvas and minimap callbacks. Verify actual rendering in game.
local helpers = dofile("tests/support/helpers.lua")
local loadNotifications = dofile("tests/support/notifications.lua")
local DEATH_PIN = "LockInToolsDeathPinTemplate"

local function Mixin(target, ...)
    for index = 1, select("#", ...) do
        for key, value in pairs(select(index, ...)) do target[key] = value end
    end
    return target
end

local function Vector(x, y)
    return { x = x, y = y, GetXY = function(self) return self.x, self.y end }
end

local function Near(actual, expected)
    assert(math.abs(actual - expected) < 0.000001)
end

local function LoadDeathMap()
    local mapped = { db = { position = {} } }
    local clock = {
        frames = {}, added = 0, rectangles = {}, bounds = {}, menuModifiers = {}, menuRegistrations = 0,
        serverNow = 1000,
        groupUnits = { player = { "Self", "Realm" } }, partyCount = 0, raidCount = 0,
        isRaid = false, nativeConnected = {}, life = {}, unitPositions = {},
    }
    local api = setmetatable({
        C_AddOns = { GetAddOnMetadata = function() return "test" end },
        Mixin = Mixin,
        CreateFromMixins = function(...) return Mixin({}, ...) end,
        CreateVector2D = Vector,
        GetServerTime = function() return clock.serverNow end,
        GetNormalizedRealmName = function() return "Realm" end,
        IsInRaid = function() return clock.isRaid end,
        GetNumSubgroupMembers = function() return clock.partyCount end,
        GetNumGroupMembers = function() return clock.isRaid and clock.raidCount or clock.partyCount + 1 end,
        UnitFullName = function(unit)
            local identity = clock.groupUnits[unit]
            if identity then return unpack(identity) end
        end,
        UnitIsUnit = function(unit, other)
            return clock.groupUnits[unit] ~= nil and clock.groupUnits[unit] == clock.groupUnits[other]
        end,
        UnitIsConnected = function(unit)
            if clock.nativeConnected[unit] ~= nil then return clock.nativeConnected[unit] end
            return clock.groupUnits[unit] ~= nil
        end,
        UnitIsDead = function(unit) return clock.life[unit] == "dead" end,
        UnitIsGhost = function(unit) return clock.life[unit] == "ghost" end,
        UnitIsDeadOrGhost = function(unit) return clock.life[unit] == "dead" or clock.life[unit] == "ghost" end,
        Menu = { ModifyMenu = function(tag, callback)
            clock.menuRegistrations = clock.menuRegistrations + 1
            assert(not clock.menuModifiers[tag], "register each menu modifier only once")
            clock.menuModifiers[tag] = callback
        end },
        C_Map = {
            GetBestMapForUnit = function(unit)
                local position = clock.unitPositions[unit]
                return position and position.map
            end,
            GetPlayerMapPosition = function(mapID, unit)
                local position = clock.unitPositions[unit]
                if position and position.map == mapID and position.x then return Vector(position.x, position.y) end
            end,
            GetMapRectOnMap = function(source, target)
                local rectangle = clock.rectangles[source .. ":" .. target]
                if rectangle then return unpack(rectangle) end
            end,
            GetWorldPosFromMapPos = function(source, position)
                local bounds = clock.bounds[source]
                if bounds then
                    local x, y = position:GetXY()
                    return bounds.continent, Vector(bounds[3] + y * (bounds[4] - bounds[3]),
                        bounds[1] + x * (bounds[2] - bounds[1]))
                end
            end,
        },
        CreateFrame = function(kind)
            assert(kind == "Frame")
            local frame = { events = {} }
            function frame:RegisterEvent(event) self.events[event] = true end
            function frame:UnregisterEvent(event) self.events[event] = nil end
            function frame:SetScript(script, callback)
                assert(script == "OnEvent")
                self.callback = callback
            end
            clock.frames[#clock.frames + 1] = frame
            return frame
        end,
    }, { __index = _G })
    local tooltip = { shown = false }
    function tooltip:SetOwner(owner, anchor) self.owner, self.anchor = owner, anchor end
    function tooltip:IsOwned(owner) return self.owner == owner end
    function tooltip:SetText(text, ...) self.title, self.titleColor = text, { ... } end
    function tooltip:Show() self.shown = true end
    function tooltip:Hide() self.shown, self.owner = false, nil end
    function tooltip:IsShown() return self.shown end
    clock.tooltip, api.GameTooltip = tooltip, tooltip
    api.GameTooltip_SetDefaultAnchor = function(target, owner) target:SetOwner(owner, "ANCHOR_NONE") end
    clock.environment, clock.mapAPI = api, api.C_Map
    loadNotifications(mapped, api)
    for _, file in ipairs({ "Core.lua", "Roster.lua", "PositionMap.lua" }) do
        helpers.loadModule(file, mapped, api)
    end
    mapped.startupEvents:UnregisterAllEvents()
    mapped.initialized = true
    clock.libraryFrames = #clock.frames
    local deathMixin = assert(api.LockInToolsDeathPinMixin)

    function clock:loadNativeMap(shown)
        api.MapCanvasDataProviderMixin = {
            OnAdded = function(self, map) self.owningMap = map end,
            GetMap = function(self) return self.owningMap end,
            OnMapChanged = function(self) self:RefreshAllData() end,
        }
        api.MapCanvasPinMixin = {
            GetMap = function(self) return self.owningMap end,
            SetPosition = function(self, x, y) self.x, self.y = x, y end,
            SetScalingLimits = function() end,
            SetIgnoreGlobalPinScale = function() end,
            UseFrameLevelType = function(_, level) assert(level == "PIN_FRAME_LEVEL_CORPSE") end,
            OnReleased = function() end,
        }
        local map = { shown = shown, id = 101, pins = {}, pool = {} }
        function map:IsShown() return self.shown end
        function map:GetMapID() return self.id end
        function map:AddDataProvider(provider)
            clock.added = clock.added + 1
            self.provider = provider
            provider:OnAdded(self)
        end
        function map:RemoveAllPinsByTemplate(template)
            assert(template == DEATH_PIN, "remove only LockInTools death pins")
            for index = #self.pins, 1, -1 do
                local pin = table.remove(self.pins, index)
                pin:OnReleased()
                assert(pin.playerName == nil, "release clears the death pin's tooltip name")
                self.pool[#self.pool + 1] = pin
            end
        end
        function map:AcquirePin(template, ...)
            assert(template == DEATH_PIN, "acquire only LockInTools death pins")
            assert(api.LockInToolsDeathPinMixin == deathMixin, "retain the XML mixin when attaching the map")
            local pin = table.remove(self.pool)
            if not pin then
                pin = Mixin({ owningMap = self }, deathMixin)
                pin:OnLoad()
            end
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
        self.map, api.WorldMapFrame = map, map
    end

    function clock:fire(event, ...)
        for _, frame in ipairs(self.frames) do
            if frame.events[event] then frame.callback(frame, event, ...) end
        end
    end
    function clock:openMenu(tag)
        local root = { entries = { { kind = "native" } } }
        function root:CreateDivider() self.entries[#self.entries + 1] = { kind = "divider" } end
        function root:CreateTitle(text) self.entries[#self.entries + 1] = { kind = "title", text = text } end
        function root:CreateCheckbox(text, isSelected, toggle)
            local checkbox = { kind = "checkbox", text = text, IsSelected = isSelected }
            function checkbox:SetEnabled(enabled) self.enabled = enabled end
            function checkbox:Click() if self.enabled then toggle() end end
            self.entries[#self.entries + 1] = checkbox
            return checkbox
        end
        local modifier = self.menuModifiers[tag]
        if modifier then modifier({}, root) end
        return root.entries
    end
    function clock:setLife(unit, state, mapID, x, y)
        self.life[unit] = state
        self.unitPositions[unit] = mapID and { map = mapID, x = x, y = y } or nil
        self:fire("UNIT_FLAGS", unit)
    end
    function clock:deathPins() return self.map.pins end
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

    local createFrame = api.CreateFrame
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
    mapped:InitializeDeathMarkers()
    local mapEvents = mapped.positionMapEvents
    mapped:InitializeDeathMarkers()
    assert(clock.added == 0 and clock.menuRegistrations == 1 and #clock.frames == clock.libraryFrames
        and mapped.positionMapEvents == mapEvents, "register the filter and wait for the world map once")
    local menu = clock:openMenu("MENU_WORLD_MAP_TRACKING")
    assert(#menu == 4 and menu[1].kind == "native" and menu[2].kind == "divider"
        and menu[3].kind == "title" and menu[3].text == "LockInTools",
        "extend the native menu with the addon section and one checkbox")
    local filter = menu[4]
    assert(filter.text == "Show death markers" and filter:IsSelected() and filter.enabled,
        "death markers default on in world map tracking")
    assert(#clock:openMenu("MENU_MINIMAP_TRACKING") == 1, "leave other map menus alone")
    mapped.savedDataReadOnly = true
    filter = clock:openMenu("MENU_WORLD_MAP_TRACKING")[4]
    assert(not filter.enabled, "newer-schema settings disable the checkbox")
    filter:Click()
    assert(mapped:GetShowDeathMarkers() and mapped.db.position.showDeathMarkers == nil,
        "a read-only click does not change saved data")
    mapped.savedDataReadOnly, mapped.initialized = false, false
    assert(not clock:openMenu("MENU_WORLD_MAP_TRACKING")[4].enabled, "disable the checkbox until settings load")

    clock:loadNativeMap(false)
    clock:fire("ADDON_LOADED", "Blizzard_WorldMap")
    mapped:InitializeDeathMarkers()
    assert(clock.added == 1 and #clock:deathPins() == 0, "attach once to a late-loading, hidden map")
end

do
    local mapped, clock = LoadDeathMap()
    local nativeMenu = clock.environment.Menu
    clock.environment.Menu = nil
    clock:loadNativeMap(true)
    mapped:InitializeDeathMarkers()
    mapped:InitializeDeathMarkers()
    assert(clock.added == 1 and clock.menuRegistrations == 0 and #clock.frames == clock.libraryFrames,
        "the map attaches once while waiting for the menu API")
    clock.environment.Menu = {}
    clock:fire("ADDON_LOADED", "Blizzard_Menu")
    assert(clock.menuRegistrations == 0, "an unavailable menu registration function is safe")
    clock.environment.Menu = nativeMenu
    clock:fire("ADDON_LOADED", "Blizzard_Menu")
    clock:fire("ADDON_LOADED", "Blizzard_Menu")
    mapped:InitializeDeathMarkers()
    assert(clock.added == 1 and clock.menuRegistrations == 1 and not clock.frames[1].events.ADDON_LOADED,
        "late menu loading registers once and stops listening without duplicating the provider")
end

do
    local mapped, clock = LoadDeathMap()
    local minimap = MockDeathMinimap(clock, 0.5, 0.5)
    clock.groupUnits.party1, clock.partyCount = { "Alice", "Realm" }, 1
    mapped:InitializeDeathMarkers()
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
    mapped:InitializeDeathMarkers()
    clock:setLife("party1", "dead", 101, 0.23, 0.42)
    clock:setLife("party1", "ghost", 102, 0.8, 0.9)
    clock:loadNativeMap(false)
    clock:fire("ADDON_LOADED", "Blizzard_WorldMap")
    clock.map:show()
    local pins = clock:deathPins()
    assert(#pins == 1, "a death before opening the map retains one pin through spirit release")
    Near(pins[1].x, 0.23)
    Near(pins[1].y, 0.42)

    pins[1]:OnMouseEnter()
    assert(clock.tooltip:IsShown() and clock.tooltip:IsOwned(pins[1]) and clock.tooltip.title == "Alice"
        and clock.tooltip.anchor == "ANCHOR_NONE", "a skull shows the player's display name at the default tooltip anchor")
    local color = clock.tooltip.titleColor
    assert(color[1] == 1 and color[2] == 0 and color[3] == 0, "the skull tooltip displays the name in pure red")
    pins[1]:OnMouseLeave()
    assert(not clock.tooltip:IsShown(), "leaving a skull dismisses its tooltip")
    pins[1]:OnMouseEnter()
    clock.map:hide()
    assert(not clock.tooltip:IsShown(), "closing the map dismisses the hovered skull's tooltip")
    clock.map:show()
    assert(#clock:deathPins() == 1 and not clock.tooltip:IsShown(), "reopening restores the skull without its tooltip")

    local deathFilter = clock:openMenu("MENU_WORLD_MAP_TRACKING")[4]
    deathFilter:Click()
    assert(not mapped:GetShowDeathMarkers() and mapped.db.position.showDeathMarkers == false
        and #clock:deathPins() == 0, "disabling death markers hides skulls and saves the preference")
    deathFilter = clock:openMenu("MENU_WORLD_MAP_TRACKING")[4]
    assert(not deathFilter:IsSelected(), "reopening the menu reflects the saved death marker preference")
    deathFilter:Click()
    assert(mapped:GetShowDeathMarkers() and mapped.db.position.showDeathMarkers == true)
    pins = clock:deathPins()
    assert(#pins == 1, "re-enabling death markers restores the frozen location")
    Near(pins[1].x, 0.23)
    Near(pins[1].y, 0.42)

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
    pins[1]:OnMouseEnter()
    clock:setLife("party1", "alive", 101, 0.6, 0.7)
    assert(#clock:deathPins() == 0 and not clock.tooltip:IsShown(),
        "reviving before release removes the hovered death pin and its tooltip")
end

do
    local mapped, clock = LoadDeathMap()
    clock.groupUnits.party1, clock.partyCount = { "Alice", "Realm" }, 1
    clock:loadNativeMap(true)
    mapped:InitializeDeathMarkers()
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
    clock:loadNativeMap(true)
    mapped:InitializeDeathMarkers()
    clock:setLife("party1", "dead", 101)
    assert(#clock:deathPins() == 0, "a death with unavailable coordinates has no death pin")
    clock:setLife("party1", "ghost", 101, 0.4, 0.5)
    assert(#clock:deathPins() == 0, "a readable ghost position cannot substitute for the missing death position")
end

do
    local original, before = LoadDeathMap()
    before.groupUnits.party1, before.partyCount = { "Alice", "Realm" }, 1
    original:InitializeDeathMarkers()
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
        mapped:InitializeDeathMarkers()
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

print("PASS: native group death markers, map attachment and tracking, projection, tooltips, minimap, and restoration")
