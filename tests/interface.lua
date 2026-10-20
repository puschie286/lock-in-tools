-- This offline suite is never loaded by the addon.
local fixture = dofile("tests/support/addon.lua")
local loadAddon, settings = fixture.loadAddon, fixture.settings
local SECRET, OTHER_SECRET, contains = fixture.SECRET, fixture.OTHER_SECRET, fixture.contains
local loadOptions = dofile("tests/support/ui.lua")

-- Content and Settings are lazy views in one window, with settings-only key management.
do
    local navigation, api, _, _, navigationWorld = loadAddon(settings(SECRET, false), false)
    navigationWorld:initialize()
    loadOptions(navigation, api)
    local command = api.SlashCmdList.LOCKINTOOLS
    local function positioned(window, x, y)
        local point = window.point
        return point and point[1] == "TOPLEFT" and point[2] == api.UIParent
            and point[3] == "TOPLEFT" and point[4] == x and point[5] == y
    end
    command("options")
    local options = navigation.optionsPanel
    local window = navigation.mainPanel
    assert(options and options:IsVisible() and not navigation.contentPanel and not navigation.welcomePanel,
        "opening Settings lazily creates only its view in the shared window")
    assert(options.parent == window and window:IsVisible() and not options.TitleText and not options.CloseButton,
        "the shared window owns the title and close button")
    assert(options.selectedTab == "group" and options.tabs.group.themeTab.selected
        and not options.tabs.chat.themeTab.selected and options.pages.group:IsVisible()
        and not options.pages.chat:IsVisible() and not options.pages.position:IsVisible()
        and not options.pages.restedxp:IsVisible()
        and not options.tabs.overview and not options.pages.overview
        and not options.screenTabs and not options.selectedScreen and not options.SelectScreen,
        "Settings contains Group, Shared chat, Shared positions and RestedXP without Content navigation tabs")
    local settingsPages = 0
    for _, page in pairs(options.pages) do
        settingsPages = settingsPages + 1
        assert(page.point[1] == "TOPLEFT" and page.point[3] == -116
            and -page.point[3] + page:GetHeight() == options:GetHeight() - 20,
            "every Settings page fills the available height with a small bottom margin")
    end
    assert(settingsPages == 4 and options.content:GetText() == "Content"
        and options.content.point[1] == "TOPRIGHT" and options.content.point[3] == -12
        and options.content:GetHeight() == 32 and options.feedback.parent == options.pages.group
        and options.feedback.point[1] == "BOTTOMLEFT",
        "Settings has exactly four pages and its Content switch in the header")
    options.secret:UserInput(OTHER_SECRET)
    options.secret:SetFocus()
    options.applyGroup:Click()
    command("options")
    options.tabs.group:Click()
    options.SelectTab("unknown")
    navigation:OpenOptions("unknown")
    assert(navigation.optionsPanel == options and options.secret:GetText() == OTHER_SECRET
        and options.applyGroup:GetText() == "Confirm switch" and options.secret.focused,
        "reopening Settings and current or invalid page selections preserve pending group edits")
    options.selectKey:Click()
    window:SetPoint("TOPLEFT", api.UIParent, "TOPLEFT", 42, -70)
    options.content:Click()
    local content = navigation.contentPanel
    assert(content and content ~= options and content:IsVisible() and not options:IsVisible()
        and content.selectedTab == "overview" and content.tabs.overview.themeTab.selected
        and content.pages.overview:IsVisible() and content.options:GetText() == "Settings"
        and content.options.point[1] == "TOPRIGHT" and content.options.point[3] == -12
        and content.options:GetHeight() == 32 and window.TitleText:GetText() == "LockInTools"
        and content.parent == window and positioned(window, 42, -70),
        "Content replaces the Settings view while preserving the shared window and position")
    local contentPages = 0
    for _ in pairs(content.pages) do contentPages = contentPages + 1 end
    assert(contentPages == 1 and not content.secret and not content.ownSecret and not content.friendSecret
        and not content.createGroup and not content.joinGroup and not content.selectKey,
        "Content contains only Overview and no group-key form")
    assert(options.secret:GetText() == "" and not options.secret.focused
        and options.ownSecret:GetText() == "" and not options.ownSecret.focused
        and options.applyGroup:GetText() == "Use key" and navigation:GetGroupSecret() == SECRET,
        "opening Content clears hidden Settings key fields, focus and switch confirmation")
    navigation:RefreshOptions()
    assert(options.ownSecret:GetText() == "", "background status refresh cannot restore a hidden copy field")
    content.options:Click()
    assert(options:IsVisible() and not content:IsVisible() and options.selectedTab == "group"
        and options.ownSecret:GetText() == SECRET and window.TitleText:GetText() == "LockInTools - Settings",
        "the Settings button restores the remembered Group page and its saved copy field")
    options.leaveGroup:Click()
    options.content:Click()
    content.options:Click()
    assert(options.leaveGroup:GetText() == "Leave group" and navigation:GetGroupSecret() == SECRET,
        "changing views cancels a pending leave-group confirmation")
    options.secret:UserInput(OTHER_SECRET)
    options.secret:SetFocus()
    options.applyGroup:Click()
    options.tabs.chat:Click()
    assert(options.selectedTab == "chat" and options.pages.chat:IsVisible()
        and not options.pages.group:IsVisible() and not options.pages.position:IsVisible()
        and options.secret:GetText() == "" and not options.secret.focused
        and options.ownSecret:GetText() == "" and options.applyGroup:GetText() == "Use key"
        and options.feedback:GetText() == "",
        "leaving Group clears copying, drafts, focus and confirmation")
    navigation:RefreshOptions()
    assert(options.ownSecret:GetText() == "", "refreshing another settings page cannot reveal the saved key")
    options.autoJoin:Click()
    navigationWorld:completeJoin(navigation:GetGroupChannelName(), 9)
    assert(options.autoJoin:GetChecked() and navigation.db.chat.autoJoin and options.secret:GetText() == "",
        "status updates retain applied chat preferences without restoring keys")
    options.tabs.position:Click()
    options.positionSharing:Click()
    options.positionRetention:Click()
    options.content:Click()
    content.options:Click()
    assert(options.selectedTab == "position" and options.pages.position:IsVisible()
        and options.positionSharing:GetChecked() and not options.positionRetention:GetChecked()
        and navigation.db.position.sharing and not navigation.db.position.keepLastKnown
        and options.feedback.parent == options.pages.position,
        "Settings remembers its page and all immediately applied preferences")
    for _, entry in ipairs({ "", "content", "overview", "welcome" }) do
        command(entry)
        assert(content:IsVisible() and not options:IsVisible() and content.pages.overview:IsVisible(),
            "Content commands and the old welcome alias reuse the Content view")
        command("options")
        assert(options:IsVisible() and not content:IsVisible() and options.selectedTab == "position",
            "the options command returns to the remembered Settings page")
    end
    navigation:OpenOptions("overview")
    assert(content:IsVisible() and not options:IsVisible(), "the old Overview options route opens Content")
    navigation.minimapButton:Click("RightButton")
    assert(options:IsVisible() and not content:IsVisible() and options.selectedTab == "position",
        "minimap right-click opens Settings at its remembered page")
    navigation.minimapButton:Click("LeftButton")
    assert(content:IsVisible() and not options:IsVisible() and content.selectedTab == "overview",
        "minimap left-click opens Content with Overview")
    window.scripts.OnDragStart(window)
    window:SetPoint("TOPLEFT", api.UIParent, "TOPLEFT", 85, -45)
    content.options:Click()
    assert(positioned(window, 85, -45) and not window.moving,
        "the header switch preserves the shared dragged position and stops movement")
    window.scripts.OnDragStart(window)
    window:SetPoint("TOPLEFT", api.UIParent, "TOPLEFT", -130, -90)
    options.parent.CloseButton:Click()
    navigation.minimapButton:Click("LeftButton")
    assert(positioned(window, -130, -90) and not window.moving,
        "Content reopens at the shared position after dragging and closing Settings")
    window.scripts.OnDragStart(window)
    window:SetPoint("TOPLEFT", api.UIParent, "TOPLEFT", 180, -65)
    content.parent.CloseButton:Click()
    navigation.minimapButton:Click("RightButton")
    assert(positioned(window, 180, -65) and not window.moving,
        "Settings reopens at the shared position after dragging and closing Content")
    window.scripts.OnDragStart(window)
    window:SetPoint("TOPLEFT", api.UIParent, "TOPLEFT", 260, -110)
    window.scripts.OnDragStop(window)
    command("options")
    assert(positioned(window, 260, -110), "reopening the current Settings view does not restore an older position")
    options.content:Click()
    command("content")
    assert(positioned(window, 260, -110), "reopening Content preserves the shared position")
    assert(api.namedFrameCreations.LockInToolsWindow == 1
        and not api.namedFrameCreations.LockInToolsContent and not api.namedFrameCreations.LockInToolsOptions
        and not api.namedFrameCreations.LockInToolsWelcome and not navigation.welcomePanel
        and #api.UISpecialFrames == 2 and contains(api.UISpecialFrames, "LockInToolsWindow")
        and contains(api.UISpecialFrames, "LockInToolsOverviewActions"),
        "all navigation paths reuse one window and one Escape-closeable action menu")
end

-- The shared window persists one account-wide position without native per-character placement.
do
    local persisted = settings(SECRET, false)
    local positioning, api, _, _, positionWorld = loadAddon(persisted, false)
    positionWorld:initialize()
    loadOptions(positioning, api)
    positioning:OpenContent()
    local content = positioning.contentPanel
    local window = positioning.mainPanel
    assert(window.windowEvents and type(window.windowEvents.UnregisterAllEvents) == "function",
        "window persistence owns an independent real AceEvent subscription")
    local function placed(window, owner, point, relativePoint, x, y)
        local actualPoint, relativeTo, actualRelativePoint, actualX, actualY = window:GetPoint()
        return actualPoint == point and relativeTo == owner and actualRelativePoint == relativePoint
            and actualX == x and actualY == y
    end
    assert(not persisted.windowPosition and window.userPlaced == false
        and placed(window, api.UIParent, "CENTER", "CENTER", 0, 0),
        "opening the first window centers it without saving a default position")
    window.scripts.OnDragStart(window)
    window:SetPoint("TOPLEFT", api.UIParent, "TOPLEFT", 140, -90)
    window.scripts.OnDragStop(window)
    local saved = persisted.windowPosition
    assert(saved and saved.point == "TOPLEFT" and saved.relativePoint == "TOPLEFT"
        and saved.x == 140 and saved.y == -90 and not saved.relativeTo
        and not window.moving and window.userPlaced == false,
        "drag stop saves only an anchor and offsets and disables native per-character placement")
    saved.futureField = "keep"
    content.options:Click()
    local options = positioning.optionsPanel
    assert(options.parent == window and content.parent == window
        and placed(window, api.UIParent, "TOPLEFT", "TOPLEFT", 140, -90)
        and persisted.windowPosition == saved and saved.futureField == "keep",
        "view switching preserves the shared window position and unknown position fields")
    window.scripts.OnDragStart(window)
    window:SetPoint("BOTTOMRIGHT", api.UIParent, "BOTTOMRIGHT", -160, 75)
    options.parent.CloseButton:Click()
    assert(saved.point == "BOTTOMRIGHT" and saved.relativePoint == "BOTTOMRIGHT"
        and saved.x == -160 and saved.y == 75 and not window.moving and window.userPlaced == false,
        "closing Settings during a drag saves its latest shared position")
    positioning:OpenContent()
    assert(placed(window, api.UIParent, "BOTTOMRIGHT", "BOTTOMRIGHT", -160, 75),
        "Content follows the position saved when Settings closed")
    window.scripts.OnDragStart(window)
    window:SetPoint("TOPRIGHT", api.UIParent, "TOPRIGHT", -85, -130)
    positionWorld.fire("PLAYER_LOGOUT")
    assert(saved.point == "TOPRIGHT" and saved.relativePoint == "TOPRIGHT"
        and saved.x == -85 and saved.y == -130 and saved.futureField == "keep"
        and not window.moving and window.userPlaced == false and persisted.schemaVersion == 3,
        "logout saves a visible mid-drag position without changing the saved-data schema")
    window:SetPoint("TOPLEFT", options, "TOPLEFT", 10, 10)
    positioning:SaveWindowPosition()
    assert(saved.point == "TOPRIGHT" and saved.x == -85 and saved.y == -130,
        "an anchor relative to another frame cannot overwrite the saved window position")

    for _, firstWindow in ipairs({ "content", "settings" }) do
        local restored, restoredApi, _, _, restoredWorld = loadAddon(persisted, false)
        if firstWindow == "settings" then
            restoredApi.UnitFullName = function(unit) assert(unit == "player"); return "Alt", "Test Realm" end
            restoredApi.UnitGUID = function(unit) assert(unit == "player"); return "Player-Test-Alt" end
        end
        restoredWorld:initialize()
        loadOptions(restored, restoredApi)
        if firstWindow == "content" then restored:OpenContent() else restored:OpenOptions() end
        local first = firstWindow == "content" and restored.contentPanel or restored.optionsPanel
        assert(placed(restored.mainPanel, restoredApi.UIParent, "TOPRIGHT", "TOPRIGHT", -85, -130)
            and persisted.windowPosition == saved and saved.futureField == "keep",
            "reload and a different character restore the account-wide position with either view opening first")
        if firstWindow == "content" then first.options:Click() else first.content:Click() end
        local second = firstWindow == "content" and restored.optionsPanel or restored.contentPanel
        assert(first.parent == second.parent and second.parent == restored.mainPanel
            and placed(restored.mainPanel, restoredApi.UIParent, "TOPRIGHT", "TOPRIGHT", -85, -130),
            "switching views after reload retains the restored shared window")
    end

    for _, invalid in ipairs({ false, "bad", {},
        { point = "INVALID", relativePoint = "CENTER", x = 0, y = 0 },
        { point = "CENTER", relativePoint = "INVALID", x = 0, y = 0 },
        { point = "CENTER", relativePoint = "CENTER", x = "40", y = 0 },
        { point = "CENTER", relativePoint = "CENTER", x = 100001, y = 0 },
        { point = "CENTER", relativePoint = "CENTER", x = 0 / 0, y = 0 },
        { point = "CENTER", relativePoint = "CENTER", x = 0, y = math.huge },
        { point = "CENTER", relativePoint = "CENTER", x = -math.huge, y = 0 } }) do
        local damaged = settings(SECRET, false)
        damaged.windowPosition = invalid
        local original = {}
        if type(invalid) == "table" then
            for key, value in pairs(invalid) do original[key] = value end
        end
        local fallback, fallbackApi, _, _, fallbackWorld = loadAddon(damaged, false)
        fallbackWorld:initialize()
        loadOptions(fallback, fallbackApi)
        fallback:OpenContent()
        assert(placed(fallback.mainPanel, fallbackApi.UIParent, "CENTER", "CENTER", 0, 0)
            and damaged.windowPosition == invalid,
            "malformed saved window positions center the first window without replacing saved data")
        for key, value in pairs(original) do
            local actual = invalid[key]
            assert(actual == value or (actual ~= actual and value ~= value),
                "reading a malformed position does not rewrite any existing field")
        end
    end

    local future = settings(SECRET, false)
    future.schemaVersion = 4
    future.windowPosition = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 80, y = -60, futureField = "keep" }
    local original = future.windowPosition
    local readOnly, readOnlyApi, _, _, readOnlyWorld = loadAddon(future, false)
    readOnlyWorld:initialize()
    loadOptions(readOnly, readOnlyApi)
    readOnly:OpenContent()
    local readOnlyWindow = readOnly.mainPanel
    readOnlyWindow.scripts.OnDragStart(readOnlyWindow)
    readOnlyWindow:SetPoint("CENTER", readOnlyApi.UIParent, "CENTER", 30, 40)
    readOnlyWindow.scripts.OnDragStop(readOnlyWindow)
    readOnlyWindow.CloseButton:Click()
    readOnlyWorld.fire("PLAYER_LOGOUT")
    assert(readOnlyApi.LockInToolsDB == future and future.schemaVersion == 4
        and future.windowPosition == original and original.point == "TOPLEFT" and original.relativePoint == "TOPLEFT"
        and original.x == 80 and original.y == -60 and original.futureField == "keep",
        "drag, hide and logout preserve newer-schema account-wide window data unchanged")
end

-- Status notifications update only affected views, without duplicate overview renders.
do
    local addon, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    loadOptions(addon, api)
    addon:OpenContent()
    addon:OpenOptions()
    addon:OpenContent()
    local refreshOverview, refreshOptions = addon.RefreshOverview, addon.RefreshOptions
    local overviewCalls, optionsCalls = 0, 0
    addon.RefreshOverview = function(self)
        overviewCalls = overviewCalls + 1
        return refreshOverview(self)
    end
    addon.RefreshOptions = function(self)
        optionsCalls = optionsCalls + 1
        return refreshOptions(self)
    end
    local function check(event, expectedOverview, expectedOptions)
        overviewCalls, optionsCalls = 0, 0
        addon:Notify(event)
        assert(overviewCalls == expectedOverview and optionsCalls == expectedOptions,
            event .. " refreshes each affected view once and leaves unrelated views alone")
    end
    check("POSITIONS_CHANGED", 1, 1)
    check("CHAT_CHANGED", 0, 1)
    check("DATA_CHANGED", 0, 1)
    check("POSITION_CONTACT_CHANGED", 1, 0)
    check("ROSTER_CHANGED", 1, 0)
    check("POSITION_VISIBILITY_CHANGED", 0, 0)
    check("GROUP_CHANGED", 1, 1)
end

-- Hidden Settings avoid control writes; their existing OnShow path restores current model state.
do
    local addon, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    loadOptions(addon, api)
    addon:OpenOptions("group")
    local options = addon.optionsPanel
    options.secret:UserInput(OTHER_SECRET)
    options.applyGroup:Click()
    addon:OpenContent()
    assert(options.secret:GetText() == "" and options.ownSecret:GetText() == ""
        and options.pendingSecret == nil, "hiding Settings performs its normal key and confirmation cleanup")
    local writes = 0
    for _, widget in ipairs({ options.groupStatus, options.newKeyLabel, options.status, options.positionStatus,
        options.secret, options.ownSecret, options.applyGroup, options.createGroup, options.leaveGroup,
        options.selectKey, options.autoJoin, options.positionSharing, options.positionRetention,
        options.join, options.leave }) do
        for _, name in ipairs({ "SetText", "SetEnabled", "SetChecked" }) do
            local original = widget[name]
            widget[name] = function(self, ...)
                writes = writes + 1
                return original(self, ...)
            end
        end
    end
    assert(addon:SetChatAutoJoin(true))
    assert(addon:SetPositionSharing(true))
    assert(addon:SetPositionRetention(false))
    assert(addon:SetGroupSecret("hidden-friends"))
    world:advance(0)
    world:completeJoin(addon:GetGroupChannelName(), 17)
    world:completeJoin(addon:GetGroupDataChannelName(), 18)
    assert(writes == 0 and not options:IsVisible() and options.secret:GetText() == ""
        and options.ownSecret:GetText() == "", "background model notifications never write hidden Settings controls")
    addon:OpenOptions()
    assert(writes > 0 and options.selectedTab == "group" and options.ownSecret:GetText() == "hidden-friends"
        and options.secret:GetText() == "" and options.pendingSecret == nil
        and options.autoJoin:GetChecked() and options.positionSharing:GetChecked()
        and not options.positionRetention:GetChecked()
        and options.status:GetText() == "Status: " .. addon:GetChatStatusText(true)
        and options.positionStatus:GetText() == "Sharing: " .. addon:GetPositionStatusText(true),
        "reopening catches up saved keys, preferences and connection status without restoring an old draft")
    addon.mainPanel:Hide()
    writes = 0
    addon:LeaveChatChannel()
    assert(addon:SetPositionSharing(false))
    assert(writes == 0, "closing the whole window also suppresses background Settings writes")
    addon:OpenOptions("position")
    assert(not options.positionSharing:GetChecked()
        and options.status:GetText() == "Status: " .. addon:GetChatStatusText(true),
        "a directly requested Settings page catches up after the whole window was hidden")
end

assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep test environments isolated")
print("PASS: shared window navigation, privacy and account-wide placement")
