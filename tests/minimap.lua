-- Exercise the real bundled DataBroker and DBIcon against native API mocks.
local fixtures = dofile("tests/support/addon.lua")
local loadAddon, settings = fixtures.loadAddon, fixtures.settings
local contains, SECRET = fixtures.contains, fixtures.SECRET

local function near(actual, expected)
    return type(actual) == "number" and math.abs(actual - expected) < 0.000001
end
local function at(button, parent, x, y)
    return button.point[1] == "CENTER" and button.point[2] == parent and button.point[3] == "CENTER"
        and near(button.point[4], x) and near(button.point[5], y)
end
local function library(api, name) return api.LibStub(name) end
local function drag(button, world, x, y)
    world.cursorX, world.cursorY = x, y
    button.scripts.OnDragStart(button)
    assert(button.scripts.OnUpdate, "native DBIcon drag callbacks install cursor updates")
    button.scripts.OnUpdate(button)
end

-- Registration, public broker callbacks and minimap navigation remain one entry point.
do
    local entry, api, messages, event, world = loadAddon(settings(nil, false), false)
    local brokerLibrary = library(api, "LibDataBroker-1.1")
    local icons = library(api, "LibDBIcon-1.0")
    local observer, created = {}, 0
    brokerLibrary.RegisterCallback(observer, "LibDataBroker_DataObjectCreated", function(_, name)
        if name == "LockInTools" then created = created + 1 end
    end)
    entry:InitializeMinimapButton()
    assert(not entry.minimapButton and not brokerLibrary:GetDataObjectByName("LockInTools")
        and world.minimapButtonCreations == 0, "launcher creation waits until login")
    event("ADDON_LOADED", "LockInTools")
    assert(not entry.minimapButton, "saved-variable initialization does not create the launcher")
    event("PLAYER_LOGIN")
    local button = entry.minimapButton
    local broker = brokerLibrary:GetDataObjectByName("LockInTools")
    local diagonal = (70 + icons.radius) / math.sqrt(2)
    assert(button == icons:GetMinimapButton("LockInTools") and button == api.LibDBIcon10_LockInTools
        and button.parent == api.Minimap and button.dataObject == broker and created == 1
        and broker.type == "launcher"
        and at(button, api.Minimap, -diagonal, -diagonal),
        "login registers one public broker and its real native minimap button")
    event("PLAYER_LOGIN")
    entry:InitializeMinimapButton()
    assert(world.minimapButtonCreations == 1 and created == 1
        and not entry.optionsPanel and not entry.contentPanel and not entry.welcomePanel,
        "repeated initialization reuses the launcher without building windows")

    button:Click("LeftButton")
    button:Click("RightButton")
    button:Click("MiddleButton")
    assert(world.contentOpened == 1 and world.optionsOpened == 1
        and world.overviewOpened == 0 and world.welcomeOpened == 0,
        "left-click opens Content and right-click opens Settings; other buttons do nothing")
    -- An external display can discover and use the same object, and receives real LDB updates.
    local found = 0
    for name, object in brokerLibrary:DataObjectIterator() do
        if name == "LockInTools" and object == broker then found = found + 1 end
    end
    assert(found == 1, "DataBroker displays discover exactly one addon launcher")
    broker.OnClick({}, "LeftButton")
    broker.OnClick({}, "RightButton")
    broker.OnTooltipShow(api.GameTooltip)
    assert(world.contentOpened == 2 and world.optionsOpened == 2,
        "external broker displays share navigation and tooltip callbacks")
    brokerLibrary.UnregisterAllCallbacks(observer)
    assert(not contains(messages, SECRET), "launcher and display interactions never print the group key")
end

-- Native scaled dragging, resize placement, persistence and hidden-button cleanup.
do
    local entry, api, _, _, world = loadAddon(settings(nil, false), false)
    world:initialize()
    local button, icons = entry.minimapButton, library(api, "LibDBIcon-1.0")
    api.Minimap.scale = 2
    api.Minimap:SetSize(140, 100)
    drag(button, world, (1000 + 60) * 2, (600 + 60) * 2)
    button.scripts.OnEnter(button)
    assert(not icons.tooltip:IsShown() and button.highlightLocked
        and at(button, api.Minimap, (70 + icons.radius) / math.sqrt(2), (50 + icons.radius) / math.sqrt(2)),
        "library dragging respects cursor scale and minimap dimensions while suppressing tooltip display")
    local cursorReads = world.cursorReads
    world.cursorX, world.cursorY = 0, 0
    button.scripts.OnDragStop(button)
    assert(not button.scripts.OnUpdate and not button.highlightLocked
        and near(entry.db.minimap.minimapPos, 45) and world.cursorReads == cursorReads,
        "drag stop retains the displayed position without resampling the cursor")
    api.Minimap:SetSize(200, 160)
    assert(at(button, api.Minimap, (100 + icons.radius) / math.sqrt(2), (80 + icons.radius) / math.sqrt(2)),
        "minimap resizing preserves angular placement")
    local resumed, resumedApi, _, resumedEvent, resumedWorld = loadAddon(entry.db, true)
    resumedEvent("ADDON_LOADED", "LockInTools")
    local resumedIcons = library(resumedApi, "LibDBIcon-1.0")
    assert(resumed.ready and resumedWorld.minimapButtonCreations == 1
        and at(resumed.minimapButton, resumedApi.Minimap,
            (70 + resumedIcons.radius) / math.sqrt(2), (70 + resumedIcons.radius) / math.sqrt(2)),
        "late loading restores saved account-wide placement without waiting for a second login event")

    drag(button, world, (1000 - 100) * 2, 600 * 2)
    cursorReads = world.cursorReads
    world.cursorX, world.cursorY = 0, 0
    button:Hide()
    assert(not button.scripts.OnUpdate and not button.highlightLocked and world.cursorReads == cursorReads
        and near(entry.db.minimap.minimapPos, 180) and not icons.tooltip:IsShown(),
        "hiding mid-drag stops native updates and preserves the last displayed position")
    assert(world.contentOpened == 0 and world.optionsOpened == 0,
        "dragging and hiding never open either addon screen")
end

-- Legacy storage migrates once; valid new placement wins without disturbing other settings.
do
    local saved = settings(nil, false)
    saved.minimap = { angle = -450, futureField = "keep" }
    local entry, api, _, _, world = loadAddon(saved, false)
    world:initialize()
    local icons = library(api, "LibDBIcon-1.0")
    assert(near(saved.minimap.minimapPos, 270) and saved.minimap.futureField == "keep"
        and at(entry.minimapButton, api.Minimap, 0, -(70 + icons.radius)),
        "legacy angles migrate to normalized DBIcon placement without dropping unrelated data")
    saved.minimap.minimapPos, saved.minimap.angle = 0, 180
    local preferred, preferredApi, _, _, preferredWorld = loadAddon(saved, false)
    preferredWorld:initialize()
    assert(at(preferred.minimapButton, preferredApi.Minimap,
        70 + library(preferredApi, "LibDBIcon-1.0").radius, 0),
        "current DBIcon placement takes precedence over a retained legacy angle")
    for _, invalid in ipairs({ false, "bad", { angle = "45" }, { minimapPos = "45" },
        { minimapPos = 0 / 0 }, { minimapPos = math.huge }, { minimapPos = -math.huge } }) do
        local broken = settings(nil, false)
        broken.minimap = invalid
        local repaired, repairedApi, _, _, repairedWorld = loadAddon(broken, false)
        repairedWorld:initialize()
        local diagonal = (70 + library(repairedApi, "LibDBIcon-1.0").radius) / math.sqrt(2)
        assert(at(repaired.minimapButton, repairedApi.Minimap, -diagonal, -diagonal),
            "malformed or non-finite saved positions use a safe default")
    end
end

-- The library receives a detached settings table when saved data is from the future.
do
    local future = settings(nil, false)
    future.schemaVersion = 4
    future.minimap = { minimapPos = 120, angle = 160, futureField = "keep", nested = { value = true } }
    local originalMinimap, originalNested = future.minimap, future.minimap.nested
    local entry, api, _, _, world = loadAddon(future, false)
    world:initialize()
    local button = entry.minimapButton
    assert(entry.savedDataReadOnly and button.db ~= future.minimap and entry.db ~= future,
        "read-only launcher settings share no mutable table with the saved future profile")
    button:Click("LeftButton")
    button:Click("RightButton")
    drag(button, world, 1100, 600)
    button.scripts.OnDragStop(button)
    assert(world.contentOpened == 1 and world.optionsOpened == 1 and near(button.db.minimapPos, 0)
        and at(button, api.Minimap, 70 + library(api, "LibDBIcon-1.0").radius, 0)
        and api.LockInToolsDB == future and future.schemaVersion == 4 and future.group.secret == SECRET
        and future.minimap == originalMinimap and future.minimap.nested == originalNested
        and originalMinimap.minimapPos == 120 and originalMinimap.angle == 160
        and originalMinimap.futureField == "keep" and originalNested.value,
        "read-only users can navigate and temporarily drag while the original saved profile remains untouched")
end

assert(_G.LibStub == nil and _G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil,
    "real libraries and addon fixtures stay isolated")
print("PASS: real DataBroker/DBIcon navigation, callbacks, placement migration and saved-data safety")
