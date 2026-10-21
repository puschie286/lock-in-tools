-- Shared-window behavior; rendering and labels are checked in the native client.
local fixture = dofile("tests/support/addon.lua")
local loadAddon, settings = fixture.loadAddon, fixture.settings
local SECRET, OTHER_SECRET, contains = fixture.SECRET, fixture.OTHER_SECRET, fixture.contains
local loadOptions = dofile("tests/support/ui.lua")

-- Navigation reuses one lazy window and clears hidden key drafts and confirmations.
do
    local addon, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    loadOptions(addon, api)
    local command = api.SlashCmdList.LOCKINTOOLS
    command("options")
    local options, window = addon.optionsPanel, addon.mainPanel
    assert(options:IsVisible() and not addon.contentPanel)
    options.secret:UserInput(OTHER_SECRET)
    options.secret:SetFocus()
    options.applyGroup:Click()
    command("options")
    addon:OpenOptions("unknown")
    assert(options.secret:GetText() == OTHER_SECRET and options.pendingSecret == OTHER_SECRET)
    options.content:Click()
    local content = addon.contentPanel
    assert(content:IsVisible() and not options:IsVisible()
        and content.parent == window and options.parent == window and content.pages.overview:IsVisible())
    assert(not content.secret and not content.ownSecret and not content.createGroup)
    addon:RefreshOptions()
    assert(options.secret:GetText() == "" and options.ownSecret:GetText() == ""
        and not options.secret.focused and not options.pendingSecret and addon:GetGroupSecret() == SECRET,
        "hidden Settings never retain keys or apply a pending switch")
    content.options:Click()
    assert(options:IsVisible() and not content:IsVisible() and options.ownSecret:GetText() == SECRET)
    options.tabs.sharing:Click()
    assert(options.autoJoin:IsVisible() and options.positionSharing:IsVisible()
        and options.positionRetention:IsVisible()
        and options.dataChannels.party:IsVisible() and options.dataChannels.guild:IsVisible()
        and options.dataChannels.global:IsVisible(), "Sharing brings chat, positions and data settings together")
    assert(not options.tabs.chat and not options.tabs.position and not options.tabs.data,
        "chat, positions and data have one navigation entry")
    options.content:Click()
    content.options:Click()
    assert(options.selectedTab == "sharing" and options.pages.sharing:IsVisible())
    for _, entry in ipairs({ "chat", "position", "data" }) do
        addon:OpenOptions("group")
        addon:OpenOptions(entry)
        assert(options.selectedTab == "sharing" and options.pages.sharing:IsVisible(),
            "existing sharing page links still open the combined settings")
    end
    for _, entry in ipairs({ "", "content", "overview", "welcome" }) do
        command(entry)
        assert(content:IsVisible() and not options:IsVisible())
    end
    assert(api.namedFrameCreations.LockInToolsWindow == 1
        and contains(api.UISpecialFrames, "LockInToolsWindow"), "one shared Escape-closeable window")
end

local function placed(window, owner, point, x, y)
    local actual, relativeTo, relativePoint, actualX, actualY = window:GetPoint()
    return actual == point and relativePoint == point and relativeTo == owner and actualX == x and actualY == y
end

-- Window placement persists account-wide, including a close during dragging.
do
    local saved = settings(SECRET, false)
    local addon, api, _, _, world = loadAddon(saved, false)
    world:initialize()
    loadOptions(addon, api)
    addon:OpenContent()
    local window = addon.mainPanel
    assert(not saved.windowPosition and placed(window, api.UIParent, "CENTER", 0, 0))
    window.scripts.OnDragStart(window)
    window:SetPoint("TOPLEFT", api.UIParent, "TOPLEFT", 140, -90)
    window.scripts.OnDragStop(window)
    local position = saved.windowPosition
    position.futureField = "keep"
    assert(position.x == 140 and position.y == -90 and not position.relativeTo and not window.userPlaced)
    addon.contentPanel.options:Click()
    assert(placed(window, api.UIParent, "TOPLEFT", 140, -90))
    window.scripts.OnDragStart(window)
    window:SetPoint("TOPRIGHT", api.UIParent, "TOPRIGHT", -85, -130)
    window.CloseButton:Click()
    assert(position.point == "TOPRIGHT" and position.x == -85 and position.y == -130 and not window.moving)
    window:SetPoint("TOPLEFT", addon.optionsPanel, "TOPLEFT", 10, 10)
    addon:SaveWindowPosition()
    assert(position.point == "TOPRIGHT" and position.x == -85, "invalid frame-relative anchors cannot overwrite placement")

    local restored, restoredApi, _, _, restoredWorld = loadAddon(saved, false)
    restoredApi.UnitFullName = function() return "Alt", "Test Realm" end
    restoredWorld:initialize()
    loadOptions(restored, restoredApi)
    restored:OpenOptions()
    restored.optionsPanel.content:Click()
    assert(placed(restored.mainPanel, restoredApi.UIParent, "TOPRIGHT", -85, -130)
        and saved.windowPosition == position and position.futureField == "keep",
        "a different character restores the shared position with either view")

    for _, invalid in ipairs({ false, { point = "INVALID", relativePoint = "CENTER", x = 0, y = 0 },
        { point = "CENTER", relativePoint = "CENTER", x = math.huge, y = 0 } }) do
        local damaged = settings(SECRET, false)
        damaged.windowPosition = invalid
        local fallback, fallbackApi, _, _, fallbackWorld = loadAddon(damaged, false)
        fallbackWorld:initialize()
        loadOptions(fallback, fallbackApi)
        fallback:OpenContent()
        assert(placed(fallback.mainPanel, fallbackApi.UIParent, "CENTER", 0, 0)
            and damaged.windowPosition == invalid)
    end

    saved.schemaVersion = 4
    local readonly, readonlyApi, _, _, readonlyWorld = loadAddon(saved, false)
    readonlyWorld:initialize()
    loadOptions(readonly, readonlyApi)
    readonly:OpenContent()
    local readonlyWindow = readonly.mainPanel
    readonlyWindow.scripts.OnDragStart(readonlyWindow)
    readonlyWindow:SetPoint("CENTER", readonlyApi.UIParent, "CENTER", 30, 40)
    readonlyWindow.scripts.OnDragStop(readonlyWindow)
    readonlyWindow.CloseButton:Click()
    readonlyWorld.fire("PLAYER_LOGOUT")
    assert(readonlyApi.LockInToolsDB == saved and saved.schemaVersion == 4
        and saved.windowPosition == position and position.point == "TOPRIGHT"
        and position.x == -85 and position.y == -130 and position.futureField == "keep",
        "drag, close and logout preserve future-schema placement")
end

-- Notifications refresh only affected views; hidden Settings catch up on reopening.
do
    local addon, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    loadOptions(addon, api)
    addon:OpenContent()
    addon:OpenOptions()
    addon:OpenContent()
    local refreshOverview, refreshOptions = addon.RefreshOverview, addon.RefreshOptions
    local overviewCalls, optionsCalls = 0, 0
    addon.RefreshOverview = function(self) overviewCalls = overviewCalls + 1; return refreshOverview(self) end
    addon.RefreshOptions = function(self) optionsCalls = optionsCalls + 1; return refreshOptions(self) end
    for _, entry in ipairs({ { "POSITIONS_CHANGED", 1, 1 }, { "CHAT_CHANGED", 0, 1 },
        { "ROSTER_CHANGED", 1, 0 }, { "GROUP_CHANGED", 1, 1 } }) do
        overviewCalls, optionsCalls = 0, 0
        addon:Notify(entry[1])
        assert(overviewCalls == entry[2] and optionsCalls == entry[3])
    end
    local options, writes = addon.optionsPanel, 0
    for _, widget in ipairs({ options.secret, options.ownSecret, options.autoJoin, options.positionSharing }) do
        for _, name in ipairs({ "SetText", "SetEnabled", "SetChecked" }) do
            local original = widget[name]
            widget[name] = function(self, ...) writes = writes + 1; return original(self, ...) end
        end
    end
    assert(addon:SetChatAutoJoin(true) and addon:SetPositionSharing(true))
    assert(addon:SetGroupSecret("hidden-friends"))
    world:advance(0)
    assert(writes == 0 and options.ownSecret:GetText() == "")
    addon:OpenOptions()
    assert(writes > 0 and options.ownSecret:GetText() == "hidden-friends"
        and options.secret:GetText() == "" and options.autoJoin:GetChecked() and options.positionSharing:GetChecked(),
        "reopening catches up model state without restoring an old draft")
end

print("PASS: shared window navigation, key privacy, placement and view refreshes")
