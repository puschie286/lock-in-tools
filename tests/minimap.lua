-- This harness is never loaded by the addon.
local fixtures = dofile("tests/support/addon.lua")
local loadAddon = fixtures.loadAddon
local settings = fixtures.settings
local contains = fixtures.contains
local SECRET = fixtures.SECRET
local OTHER_SECRET = fixtures.OTHER_SECRET

-- Native minimap entry point, account-wide placement and saved-data safety.
do
    local function near(actual, expected)
        return type(actual) == "number" and math.abs(actual - expected) < 0.000001
    end
    local function at(button, parent, x, y)
        return button.point[1] == "CENTER" and button.point[2] == parent and button.point[3] == "CENTER"
            and near(button.point[4], x) and near(button.point[5], y)
    end
    local entry, api, entryMessages, entryEvent, entryWorld = loadAddon(settings(nil, false), false)
    entry:InitializeMinimapButton()
    assert(not entry.minimapButton and entryWorld.minimapButtonCreations == 0,
        "the minimap button waits until login")
    entryEvent("ADDON_LOADED", "LockInTools")
    assert(not entry.minimapButton and not entry.db.minimap,
        "saved-variable initialization does not create a button or minimap settings")
    entryEvent("PLAYER_LOGIN")
    local button = entry.minimapButton
    local diagonal = 78 / math.sqrt(2)
    assert(button and entryWorld.minimapButtonCreations == 1
        and api.LockInToolsMinimapButton == button and button.parent == api.Minimap
        and at(button, api.Minimap, -diagonal, -diagonal),
        "login creates one native button at the default minimap position")
    assert(button.width == 31 and button.height == 31 and button.strata == "MEDIUM" and button.level == 18
        and button.clicks[1] == "LeftButtonUp" and button.clicks[2] == "RightButtonUp"
        and button.drags[1] == "LeftButton" and not button.drags[2],
        "the native button registers both click actions and left-button dragging")
    entryEvent("PLAYER_LOGIN")
    entry:InitializeMinimapButton()
    assert(entryWorld.minimapButtonCreations == 1 and #api.Minimap.hooks == 1
        and not entry.optionsPanel and not entry.contentPanel and not entry.welcomePanel and not entry.db.minimap,
        "repeated login and initialization reuse the button without building windows or saving defaults")
    button:Click("LeftButton")
    button:Click("RightButton")
    button:Click("MiddleButton")
    assert(entryWorld.contentOpened == 1 and entryWorld.optionsOpened == 1
        and entryWorld.overviewOpened == 0 and entryWorld.welcomeOpened == 0,
        "left-click opens Content and right-click opens Settings while other clicks do nothing")
    button.scripts.OnEnter(button)
    assert(api.GameTooltip.shown and api.GameTooltip.owner == button and api.GameTooltip.anchor == "ANCHOR_LEFT"
        and api.GameTooltip.text == "LockInTools" and #api.GameTooltip.lines == 2
        and api.GameTooltip.lines[1] == "Left-click: Content" and api.GameTooltip.lines[2] == "Right-click: Settings",
        "hover labels the two screen shortcuts without a drag note")
    button.scripts.OnLeave(button)
    assert(not api.GameTooltip.shown)

    api.Minimap.scale = 2
    api.Minimap:SetSize(140, 100)
    entryWorld.cursorX, entryWorld.cursorY = (1000 + 78) * 2, (600 + 58) * 2
    button.scripts.OnDragStart(button)
    button.scripts.OnEnter(button)
    assert(button.scripts.OnUpdate and not api.GameTooltip.shown,
        "dragging installs cursor updates and suppresses the tooltip")
    button.scripts.OnUpdate(button)
    assert(at(button, api.Minimap, 78 / math.sqrt(2), 58 / math.sqrt(2)) and not entry.db.minimap,
        "dragging accounts for minimap scale and unequal radii without saving intermediate positions")
    local cursorReads = entryWorld.cursorReads
    entryWorld.cursorX, entryWorld.cursorY = 0, 0
    button.scripts.OnDragStop(button)
    assert(not button.scripts.OnUpdate and near(entry.db.minimap.angle, 45)
        and entryWorld.cursorReads == cursorReads
        and entryWorld.contentOpened == 1 and entryWorld.optionsOpened == 1 and entryWorld.welcomeOpened == 0,
        "drag stop saves the last displayed angle without a cursor resample or opening a window")
    api.Minimap:SetSize(200, 160)
    assert(at(button, api.Minimap, 108 / math.sqrt(2), 88 / math.sqrt(2)),
        "minimap resizing refreshes the saved angular placement")
    local resumed, resumedApi, _, resumedEvent, resumedWorld = loadAddon(entry.db, true)
    resumedEvent("ADDON_LOADED", "LockInTools")
    assert(resumed.ready and resumedWorld.minimapButtonCreations == 1
        and at(resumed.minimapButton, resumedApi.Minimap, diagonal, diagonal),
        "late loading restores account-wide placement during login initialization")

    entryWorld.cursorX, entryWorld.cursorY = (1000 - 108) * 2, 600 * 2
    button.scripts.OnDragStart(button)
    button.scripts.OnUpdate(button)
    cursorReads = entryWorld.cursorReads
    entryWorld.cursorX, entryWorld.cursorY = 0, 0
    button:Hide()
    assert(not button.scripts.OnUpdate and near(entry.db.minimap.angle, 180)
        and entryWorld.cursorReads == cursorReads and not api.GameTooltip.shown,
        "hiding mid-drag saves the displayed position and stops updates without sampling a hidden cursor")
    assert(not contains(entryMessages, SECRET), "minimap interaction never prints the group key")

    for _, invalid in ipairs({ false, "bad", { angle = "45" }, { angle = 0 / 0 },
        { angle = math.huge }, { angle = -math.huge } }) do
        local saved = settings(nil, false)
        saved.minimap = invalid
        local originalAngle = type(invalid) == "table" and invalid.angle
        local repaired, repairedApi, _, _, repairedWorld = loadAddon(saved, false)
        repairedWorld:initialize()
        assert(at(repaired.minimapButton, repairedApi.Minimap, -diagonal, -diagonal)
            and saved.minimap == invalid,
            "invalid and non-finite saved positions fall back without replacing their saved field")
        if type(invalid) == "table" then
            assert(invalid.angle == originalAngle or (invalid.angle ~= invalid.angle and originalAngle ~= originalAngle),
                "reading an invalid angle does not rewrite it")
        end
    end
    local normalizedSettings = settings(nil, false)
    normalizedSettings.minimap = { angle = -450, futureField = "keep" }
    local normalized, normalizedApi, _, _, normalizedWorld = loadAddon(normalizedSettings, false)
    normalizedWorld:initialize()
    assert(at(normalized.minimapButton, normalizedApi.Minimap, 0, -78)
        and normalizedSettings.minimap.angle == -450 and normalizedSettings.minimap.futureField == "keep",
        "finite saved angles normalize for placement while preserving saved data")

    local squareSettings = settings(nil, false)
    squareSettings.minimap = { angle = 45 }
    local square, squareApi, _, _, squareWorld = loadAddon(squareSettings, false)
    squareWorld.minimapShape = "SQUARE"
    squareWorld:initialize()
    assert(at(square.minimapButton, squareApi.Minimap, 78, 78),
        "square minimaps project diagonal placement onto their rim")
    squareWorld.minimapShape = "CORNER-TOPLEFT"
    squareApi.Minimap:SetSize(140, 140)
    assert(at(square.minimapButton, squareApi.Minimap, diagonal, diagonal),
        "other minimap shapes retain the circular placement fallback")

    local futureSettings = settings(nil, false)
    futureSettings.schemaVersion = 4
    futureSettings.minimap = { angle = 120, futureField = "keep" }
    local originalMinimap = futureSettings.minimap
    local readOnly, readOnlyApi, _, _, readOnlyWorld = loadAddon(futureSettings, false)
    readOnlyWorld:initialize()
    local readOnlyButton = readOnly.minimapButton
    readOnlyButton:Click("LeftButton")
    readOnlyButton:Click("RightButton")
    readOnlyWorld.cursorX, readOnlyWorld.cursorY = 1078, 600
    readOnlyButton.scripts.OnDragStart(readOnlyButton)
    readOnlyButton.scripts.OnUpdate(readOnlyButton)
    readOnlyButton.scripts.OnDragStop(readOnlyButton)
    assert(readOnlyWorld.contentOpened == 1 and readOnlyWorld.optionsOpened == 1 and readOnlyWorld.welcomeOpened == 0
        and at(readOnlyButton, readOnlyApi.Minimap, 78, 0)
        and readOnlyApi.LockInToolsDB == futureSettings and futureSettings.minimap == originalMinimap
        and originalMinimap.angle == 120 and originalMinimap.futureField == "keep"
        and futureSettings.schemaVersion == 4 and not readOnly.db.minimap,
        "read-only profiles permit button access and temporary dragging without writing any minimap settings")
end


assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep test environments isolated")
print("PASS: native minimap button, navigation, dragging and saved-data safety")
