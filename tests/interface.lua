-- Shared-window behavior; rendering and labels are checked in the native client.
local fixture = dofile("tests/support/addon.lua")
local loadAddon, settings = fixture.loadAddon, fixture.settings
local SECRET, contains = fixture.SECRET, fixture.contains
local loadOptions = dofile("tests/support/ui.lua")

-- Navigation reuses one lazy window for native sharing settings and Content.
do
    local addon, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    loadOptions(addon, api)
    local command = api.SlashCmdList.LOCKINTOOLS
    command("options")
    local options, window = addon.optionsPanel, addon.mainPanel
    assert(options:IsVisible() and not addon.contentPanel and options.selectedTab == "sharing")
    command("options")
    addon:OpenOptions("unknown")
    assert(options.selectedTab == "sharing")
    options.content:Click()
    local content = addon.contentPanel
    assert(content:IsVisible() and not options:IsVisible()
        and content.parent == window and options.parent == window and content.pages.overview:IsVisible())
    assert(not options.tabs.group and not options.tabs.chat and not options.secret and not options.autoJoin)
    content.options:Click()
    assert(options:IsVisible() and not content:IsVisible())
    assert(not options.positionSharing and not options.positionRetention
        and options.dataChannels.guild:IsVisible() and options.dataChannels.friends:IsVisible()
        and options.rankingEnabled:IsVisible() and options.rankingBurningEffect:IsVisible()
        and options.rankingTransparencySlider:IsVisible() and options.playerDataCleanup:IsVisible()
        and options.clearPlayerData:IsVisible() and not options.dataChannels.global and not options.dataChannels.party,
        "General contains Guild and Friends sharing, ranking and player data preferences")
    options.content:Click()
    content.options:Click()
    assert(options.selectedTab == "sharing" and options.pages.sharing:IsVisible())
    for _, entry in ipairs({ "sharing", "position", "data", "ranking", "playerData" }) do
        addon:OpenOptions("restedxp")
        addon:OpenOptions(entry)
        assert(options.selectedTab == "sharing" and options.pages.sharing:IsVisible(),
            "existing settings page links open the combined controls")
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

    saved.schemaVersion = 5
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
    assert(readonlyApi.LockInToolsDB == saved and saved.schemaVersion == 5
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
    for _, entry in ipairs({ { "DATA_CHANGED", 1, 1 }, { "RESTEDXP_CHANGED", 0, 1 },
        { "ROSTER_CHANGED", 1, 0 } }) do
        overviewCalls, optionsCalls = 0, 0
        addon:Notify(entry[1])
        assert(overviewCalls == entry[2] and optionsCalls == entry[3])
    end
    local options, writes = addon.optionsPanel, 0
    for _, widget in ipairs({ options.dataChannels.guild, options.dataChannels.friends }) do
        for _, name in ipairs({ "SetText", "SetEnabled", "SetChecked" }) do
            local original = widget[name]
            widget[name] = function(self, ...) writes = writes + 1; return original(self, ...) end
        end
    end
    assert(addon:SetDataChannelEnabled("guild", false) and addon:SetDataChannelEnabled("friends", false))
    assert(writes == 0)
    addon:OpenOptions()
    assert(writes > 0 and not options.dataChannels.guild:GetChecked() and not options.dataChannels.friends:GetChecked(),
        "reopening catches up native sharing preferences changed while hidden")
end

-- The Friends table and overlay consume the same native observation without a sharing route.
do
    local addon, api, _, fire, world = loadAddon(settings(), false)
    local friend = { clientProgram = "WoW", wowProjectID = 18, isInCurrentRegion = true,
        isOnline = true, isAppearOffline = false, characterName = "Dara Stone", characterLevel = 18,
        areaName = "Elwynn Forest" }
    local other = { clientProgram = "WoW", wowProjectID = 18, isInCurrentRegion = true,
        isOnline = true, isAppearOffline = false, characterName = "Vela Ash", characterLevel = 28 }
    api.WOW_PROJECT_CAMELOT, api.BNET_CLIENT_WOW = 18, "WoW"
    api.WOW_PROJECT_ID = api.WOW_PROJECT_CAMELOT
    api.BNConnected = function() return true end
    api.BNGetNumFriends = function() return 2 end
    api.C_BattleNet = {
        GetFriendAccountInfo = function(index) return { bnetAccountID = index, appearOffline = false } end,
        GetFriendNumGameAccounts = function() return 1 end,
        GetFriendGameAccountInfo = function(index) return index == 1 and friend or other end,
    }
    local guildMembers = {}
    fixture.mockGuild(api, guildMembers)
    guildMembers[1] = { name = "Dara-Stone", level = 19, presence = api.Enum.ClubMemberPresence.Online }
    world:initialize()
    loadOptions(addon, api)
    addon:OpenContent()
    local content = addon.contentPanel
    content.tabs.friends:Click()
    local row, otherRow = unpack(content.pages.friends.rows, 1, 2)
    assert(content.tabs.overview:GetText() == "Rankings")
    assert(row.name:GetText() == "Dara Stone" and row.level:GetText() == "18" and row.status:GetText() == "Online")
    assert(addon:SetRankingEnabled(true))
    local overlay = addon.rankingOverlay
    assert(not overlay.rows[1]:IsShown(), "native friend data is opt-in for ranking")
    row.ranking:Click()
    assert(row.ranking:GetChecked() and not otherRow.ranking:GetChecked()
        and addon:IsRankingPlayerShown("dara-stone", false) and overlay.rows[1].name:GetText() == "Dara Stone"
        and overlay.rows[1].progress:GetText() == "XP unavailable")
    assert(#addon:GetPlayerRanking().players == 2, "one selected friend ranks alongside the local character")
    friend.characterLevel, friend.areaName = 19, "Westfall"
    fire("BN_FRIEND_INFO_CHANGED", 1)
    assert(row.level:GetText() == "19" and row.zone:GetText() == "Westfall"
        and overlay.rows[1].level:GetText() == "19", "native friend events update both visible views")
    assert(not addon:IsDataConnected() and #world.dataSends == 0 and #world.statusSends == 0)

    world.guild = true
    fire("PLAYER_GUILD_UPDATE", "player")
    local sharedName = "Dara Stone-OtherRealm"
    assert(addon:ReceivePlayerStatus(sharedName, { level = 19, xp = 50, xpMax = 100, xpState = "known" }, 1, 1))
    assert(row.name:GetText() == "Vela Ash" and not otherRow:IsShown(),
        "a shared surname alias removes the duplicate while Friends is visible")
    local standings = addon:GetPlayerRanking().players
    assert(#standings == 2 and standings[1].id == sharedName:lower() and standings[1].xp == 50,
        "different realm suffixes still produce one ranked friend with shared XP")
    content.tabs.overview:Click()
    local rankingRows = content.pages.overview.rows
    local sharedRow = rankingRows[2]
    assert(sharedRow.playerID == sharedName:lower() and sharedRow.ranking:GetChecked()
        and sharedRow.name:GetText() == "Dara Stone" and sharedRow.progress:GetText() == "50%"
        and rankingRows[3].name:GetText() == "Vela Ash" and not rankingRows[4]:IsShown(),
        "Rankings shows one shared guild friend with XP alongside the native-only friend")
    sharedRow.ranking:Click()
    assert(not sharedRow.ranking:GetChecked() and #addon:GetPlayerRanking().players == 1,
        "unchecking the shared row also excludes its native friend entry")
    content.tabs.guild:Click()
    local guildRows = content.pages.guild.rows
    assert(guildRows[2].playerID == sharedName:lower() and not guildRows[2].ranking:GetChecked()
        and guildRows[2].name:GetText() == "Dara Stone" and not guildRows[3]:IsShown(),
        "Guild uses the same identity and visibility setting for a guild friend")
    content.tabs.friends:Click()
    assert(row.name:GetText() == "Vela Ash" and not otherRow:IsShown(), "an unchecked shared player stays in Rankings")
    world.guild = false
    fire("PLAYER_GUILD_UPDATE", "player")
    assert(row.name:GetText() == "Dara Stone" and not row.ranking:GetChecked(),
        "the same visibility choice follows the character back to Friends")
    assert(#world.notificationErrors == 0)
end

print("PASS: shared window navigation, placement and view refreshes")
