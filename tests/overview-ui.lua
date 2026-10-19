-- This offline suite is never loaded by the addon.
local fixture = dofile("tests/support/addon.lua")
local loadAddon, settings = fixture.loadAddon, fixture.settings
local SECRET, OTHER_SECRET, contains = fixture.SECRET, fixture.OTHER_SECRET, fixture.contains
local loadOptions = dofile("tests/support/ui.lua")

-- Overview scrolls and sorts the Content roster, with guarded native actions in a dropdown.
do
    local overview, api, _, overviewEvent, overviewWorld = loadAddon(settings(SECRET, false), false)
    local invites, requests, grouped, mayInvite = {}, {}, false, true
    api.IsInGroup = function() return grouped end
    api.C_PartyInfo = {
        CanInvite = function() return mayInvite end,
        IsPartyFull = function() return false end,
        InviteUnit = function(name) invites[#invites + 1] = name end,
        RequestInviteFromUnit = function(name) requests[#requests + 1] = name end,
    }
    api.C_Map.GetMapInfo = function(map)
        assert(map == 37 or map == 38)
        return { name = map == 37 and "Elwynn Forest" or "Westfall" }
    end
    overviewWorld:initialize()
    overviewWorld:completeJoin(overview:GetGroupDataChannelName(), 7)
    local now = api.GetServerTime()
    for index, name in ipairs({ "Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India", "Juliet" }) do
        overviewEvent("CHAT_MSG_ADDON", overview:GetDataPrefix(),
            "1|status|3|F|peer-" .. name:lower() .. "|" .. now .. "|1|1="
            .. (name == "Bravo" and 0 or 20 + index) .. "|4=unavailable|5="
            .. (name == "Bravo" and "true" or "false") .. "|6=true|7=false|8="
            .. (name == "Alpha" and "true" or "false"),
            "CHANNEL", name .. "-TestRealm", nil, 0, 7, overview:GetGroupDataChannelName())
    end
    overviewEvent("CHAT_MSG_ADDON", overview:GetDataPrefix(),
        "1|status|3|D|peer-alpha|" .. now .. "|2|1|65000=value|2=420|3=1000|4=known",
        "CHANNEL", "Alpha-TestRealm", nil, 0, 7, overview:GetGroupDataChannelName())
    local positions = {
        ["alpha-testrealm"] = { name = "Alpha-TestRealm", map = 37, x = 0.25, y = 0.75,
            stamp = now, positionStamp = now - 120, positionAvailable = true, online = true },
        ["charlie-testrealm"] = { name = "Charlie-TestRealm", map = 38,
            stamp = now, positionStamp = now - 180, positionAvailable = false, online = true },
    }
    overview.GetSharedPositions = function() return positions end
    local snapshotCalls, originalRequest = 0, overview.RequestData
    overview.RequestData = function(self, feature, ...)
        if feature == "status" then snapshotCalls = snapshotCalls + 1 end
        return originalRequest(self, feature, ...)
    end
    loadOptions(overview, api)
    local command = api.SlashCmdList.LOCKINTOOLS
    command("options")
    local options = overview.optionsPanel
    assert(options.selectedTab == "group" and not overview.contentPanel and snapshotCalls == 0,
        "opening Settings does not activate Content or request an Overview snapshot")
    options.secret:UserInput(OTHER_SECRET)
    options.secret:SetFocus()
    options.applyGroup:Click()
    command("overview")
    local content = overview.contentPanel
    local page = content.overviewPage
    assert(content.selectedTab == "overview" and not options:IsVisible()
        and page:IsVisible() and page.active and snapshotCalls == 0
        and options.secret:GetText() == "" and not options.secret.focused
        and options.applyGroup:GetText() == "Use key" and overview:GetGroupSecret() == SECRET,
        "overview command opens Content and clears group-key drafts and confirmation")
    command("overview")
    command("content")
    content.tabs.overview:Click()
    overview:OpenOptions("overview")
    assert(page.active and page.scripts.OnUpdate and snapshotCalls == 0,
        "reopening Content or selecting its current Overview page does not request status")
    assert(not page.summary and not page.previous and not page.next and not page.pagination and not page.pageNumber
        and #page.rows == 8 and page.offset == 0 and not page.sortKey
        and page.rows[1].name:GetText():find("(you)", 1, true)
        and page.rows[8].playerID == "golf-testrealm" and not page.empty:IsShown(),
        "overview has eight reusable rows without the summary line or paging controls")
    local minimum, maximum = page.scrollbar:GetMinMaxValues()
    assert(page.scrollbar:IsShown() and minimum == 0 and maximum == 3 and page.scrollbar:GetValue() == 0,
        "the native scrollbar exposes all eleven players through a bounded row offset")
    assert(page.rows[2].name:GetText() == "Alpha-TestRealm" and page.rows[2].level:GetText() == "21"
        and page.rows[2].progress:GetText() == "· 42%" and page.rows[2].progressFill:IsShown()
        and page.rows[2].position:GetText() == "Elwynn Forest" and page.rows[2].seen:GetText() == "Active"
        and page.rows[3].level:GetText() == "—" and page.rows[5].position:GetText() == "Not sharing"
        and page.rows[4].position:GetText() == "Last: Westfall" and page.rows[4].seen:GetText() == "Active",
        "status reaches level progress, and region labels omit ages while active players show only Active")
    for _, row in ipairs(page.rows) do
        assert(row.actions:IsEnabled() and not row.invite and not row.request,
            "each row has one dropdown trigger instead of individual action buttons")
    end
    local function openMenu(index)
        local row = page.rows[index]
        row.actions:Click()
        assert(page.actionMenu:IsShown() and page.actionMenu.playerID == row.playerID
            and page.actionMenu.anchor == row,
            "the actions dropdown is anchored to its selected player")
        return page.actionMenu
    end
    local menu = openMenu(1)
    assert(not menu.invite:IsEnabled() and not menu.request:IsEnabled(),
        "the local player's menu explains unavailable actions")
    menu.invite.scripts.OnEnter(menu.invite)
    assert(api.GameTooltip.shown and api.GameTooltip.text == "This is your character.",
        "disabled actions explain their reason on hover")
    menu.invite.scripts.OnLeave(menu.invite)
    assert(not api.GameTooltip.shown)
    menu:Click()
    assert(not menu:IsShown(), "clicking outside the dropdown dismisses it")
    menu = openMenu(2)
    assert(menu.invite:IsEnabled() and not menu.request:IsEnabled(),
        "an ungrouped peer offers an invite but explains the unavailable join request")
    menu.invite:Click()
    menu = openMenu(3)
    assert(not menu.invite:IsEnabled() and menu.request:IsEnabled(),
        "a grouped peer offers a join request instead of an invite")
    menu.request:Click()
    assert(#invites == 1 and invites[1] == "Alpha-TestRealm" and #requests == 1 and requests[1] == "Bravo-TestRealm"
        and content.feedback:GetText():find("invitation notices", 1, true),
        "overview clicks invoke the real guarded native actions with complete names")
    -- Open while allowed, then change native eligibility before clicking.
    mayInvite = true
    menu = openMenu(2)
    mayInvite = false
    menu.invite:Click()
    assert(#invites == 1
        and content.feedback:GetText() == "You cannot invite players right now.",
        "an enabled stale dropdown item cannot bypass the action-time permission check")
    menu = openMenu(2)
    assert(not menu.invite:IsEnabled() and menu.invite.reason == "You cannot invite players right now.",
        "reopening a menu refreshes disabled action state and its explanation")
    mayInvite = true
    overview:RefreshOverview()
    assert(menu:IsShown() and menu.playerID == "alpha-testrealm" and menu.invite:IsEnabled(),
        "a refresh preserves the selected player and updates an open menu's eligibility")
    page:SetOffset(1)
    assert(not menu:IsShown() and page.offset == 1 and page.rows[1].playerID == "alpha-testrealm"
        and page.scrollbar:GetValue() == 1,
        "moving the scroll offset dismisses the menu and keeps the native scrollbar synchronized")
    page.scripts.OnMouseWheel(page, -1)
    assert(page.offset > 1, "mouse wheel down moves through the roster")
    page:SetOffset(999)
    assert(page.offset == 3 and page.rows[1].playerID == "charlie-testrealm"
        and page.rows[8].playerID == "juliet-testrealm",
        "scrolling to the end reveals the last player without an extra page")
    page.scrollbar:SetValue(0)
    assert(page.offset == 0 and page.rows[1].playerID == "self-testrealm",
        "dragging the scrollbar updates visible row targets")
    page.scripts.OnMouseWheel(page, 1)
    assert(page.offset == 0, "mouse wheel up clamps at the first player")

    openMenu(2)
    page.headers.name:Click()
    assert(not menu:IsShown() and page.sortKey == "name" and not page.sortDescending
        and page.offset == 0 and page.rows[1].playerID == "alpha-testrealm",
        "clicking a column sorts ascending and dismisses the selected player's menu")
    page:SetOffset(3)
    assert(page.rows[8].playerID == "self-testrealm", "explicit name sorting includes self in normal name order")
    page.headers.name:Click()
    assert(page.sortDescending and page.offset == 0 and page.rows[1].playerID == "self-testrealm"
        and page.rows[2].playerID == "juliet-testrealm", "clicking the same column reverses sorting and resets scrolling")
    page.headers.level:Click()
    assert(not page.sortDescending and page.rows[1].playerID == "self-testrealm"
        and page.rows[2].playerID == "alpha-testrealm", "levels sort numerically ascending")
    page:SetOffset(3)
    assert(page.rows[8].playerID == "bravo-testrealm", "unknown levels follow known levels when sorting ascending")
    page.headers.level:Click()
    assert(page.sortDescending and page.rows[1].playerID == "juliet-testrealm", "levels sort numerically descending")
    page:SetOffset(3)
    assert(page.rows[8].playerID == "bravo-testrealm", "unknown levels remain last when sorting descending")
    page.headers.region:Click()
    assert(not page.sortDescending and page.rows[1].playerID == "alpha-testrealm"
        and page.rows[2].playerID == "charlie-testrealm" and page.rows[3].playerID == "bravo-testrealm",
        "regions sort by name with missing regions after known values and stable player-ID ties")
    page.headers.region:Click()
    assert(page.sortDescending and page.rows[1].playerID == "charlie-testrealm"
        and page.rows[2].playerID == "alpha-testrealm" and page.rows[3].playerID == "bravo-testrealm",
        "reverse region sorting keeps missing regions last and preserves deterministic ties")
    -- Vary contact ages without changing transport eligibility or position freshness.
    overview.rosterState.peers["alpha-testrealm"].seenAt = now - 20
    overview.rosterState.peers["bravo-testrealm"].seenAt = now - 10
    overview.rosterState.peers["charlie-testrealm"].seenAt = nil
    page.headers.seen:Click()
    assert(page.sortDescending and page.rows[1].playerID == "delta-testrealm"
        and page.rows[2].playerID == "echo-testrealm", "last seen starts with the most recent contacts and stable ties")
    page:SetOffset(3)
    assert(page.rows[8].playerID == "charlie-testrealm", "unknown contact ages sort after known recent contacts")
    page.headers.seen:Click()
    assert(not page.sortDescending and page.rows[1].playerID == "alpha-testrealm"
        and page.rows[2].playerID == "bravo-testrealm", "last seen can be reversed to oldest contacts first")
    page:SetOffset(3)
    assert(page.rows[8].playerID == "charlie-testrealm", "unknown contact ages stay last in either sort direction")
    page.headers.name:Click()
    -- Ascending names put Alpha first and provide a stable anchor for live age updates.
    menu = openMenu(1)
    assert(page.rows[1].seen:GetText() == "Active" and page.rows[1].position:GetText() == "Elwynn Forest",
        "an active contact with an older seen timestamp still shows only Active and the region name")
    overviewWorld:advance(90)
    assert(page.scripts.OnUpdate, "only the active overview page installs an age refresh")
    page.scripts.OnUpdate(page, 1)
    assert(page.rows[1].position:GetText() == "Last: Elwynn Forest"
        and page.rows[1].seen:GetText() == "1m ago" and snapshotCalls == 0
        and menu:IsShown() and menu.playerID == "alpha-testrealm" and not menu.invite:IsEnabled()
        and menu.invite.reason == "No recent contact with this player.",
        "offline rows show only elapsed contact age, retain the region without age and do not request status")
    api.UIParent:Hide()
    assert(content:IsShown() and page:IsShown() and not page:IsVisible()
        and not page.active and not page.scripts.OnUpdate and not menu:IsShown(),
        "hiding the interface deactivates the visible Overview view and dismisses its menu")
    api.UIParent:Show()
    assert(content:IsVisible() and page.active and page.scripts.OnUpdate and snapshotCalls == 0
        and not menu:IsShown(),
        "restoring the interface resumes Overview without reopening its menu or requesting status")
    content.parent.CloseButton:Click()
    assert(not overview.mainPanel:IsShown() and content:IsShown() and not content:IsVisible()
        and not page.active and not page.scripts.OnUpdate and not menu:IsShown(),
        "closing the shared window stops live Overview work and dismisses its action menu")
    command("options")
    assert(options.selectedTab == "group"
        and options.pages.group:IsVisible() and not page.active and not page.scripts.OnUpdate
        and snapshotCalls == 0,
        "opening Settings does not reactivate the hidden Content page")
    options.content:Click()
    assert(content.selectedTab == "overview" and page.active and snapshotCalls == 0,
        "returning to Content reactivates Overview without requesting another status snapshot")
    content.options:Click()
    options.tabs.chat:Click()
    assert(options.selectedTab == "chat"
        and not page.active and not page.scripts.OnUpdate,
        "opening Settings deactivates Overview and stops its age updates")
    overview:OpenOptions("unknown")
    assert(options.selectedTab == "chat" and options.pages.chat:IsVisible() and snapshotCalls == 0,
        "invalid settings page names preserve the selected page without activating Content")
    command("overview")
    assert(snapshotCalls == 0 and content.selectedTab == "overview" and content:IsVisible()
        and not options:IsVisible())
    page:SetOffset(999)
    openMenu(1)
    positions, overview.rosterState.peers = {}, {}
    overview:RefreshOverview()
    assert(page.offset == 0 and page.rows[1].playerID == "self-testrealm"
        and not page.rows[2]:IsShown() and not page.rows[2].playerID and not page.scrollbar:IsShown()
        and not menu:IsShown() and not page.empty:IsShown(),
        "live roster removal clamps scrolling, removes old row targets and closes obsolete menus")
    assert(overview:LeaveGroup())
    assert(page.empty:IsShown() and page.empty:GetText():find("Choose a group key", 1, true)
        and not page.rows[1]:IsShown() and not page.rows[1].playerID,
        "leaving the global group clears the overview while it remains open")
end

-- The local player's progress is read directly and has no remote-report age.
do
    local localAddon, api, _, _, localWorld = loadAddon(settings(SECRET, false), false)
    localWorld:initialize()
    loadOptions(localAddon, api)
    localAddon:OpenContent()
    local page, tooltip = localAddon.contentPanel.overviewPage, api.GameTooltip
    local row = page.rows[1]
    row.levelCell.scripts.OnEnter(row.levelCell)
    assert(row.levelCell.player.isSelf and tooltip.lines[1] == "XP: 0 / 1000"
        and tooltip.lines[2] == "To next level: 1000 XP" and #tooltip.lines == 2,
        "local progress details show exact live XP without a Last reported label")
    localWorld:advance(1.2)
    localWorld.xp = 250
    localWorld.fire("PLAYER_XP_UPDATE", "player")
    page.scripts.OnUpdate(page, 1)
    assert(tooltip.lines[1] == "XP: 250 / 1000" and tooltip.lines[2] == "To next level: 750 XP"
        and #tooltip.lines == 2,
        "refreshing live local progress updates XP without adding a flickering report age")
end

-- Level progress fits the pooled Overview rows and explains exact values without requesting on each refresh.
do
    local progressAddon, api, _, _, progressWorld = loadAddon(settings(SECRET, false), false)
    progressWorld:initialize()
    local now, snapshots = api.GetServerTime(), 0
    local players = {
        { id = "alpha", name = "Alpha", level = 24, xp = 420, xpMax = 1000, xpState = "known", online = true },
        { id = "bravo", name = "Bravo", level = 24, xp = 0, xpMax = 1000, xpState = "known", online = true },
        { id = "charlie", name = "Charlie", level = 24, xp = 999, xpMax = 1000, xpState = "known", online = true },
        { id = "delta", name = "Delta", level = 60, xpState = "max", online = true },
        { id = "echo", name = "Echo", level = 24, xpState = "unavailable", online = true },
        { id = "foxtrot", name = "Foxtrot", xpState = "unavailable", online = true },
        { id = "golf", name = "Golf", level = 24, xp = 500, xpMax = 1000, xpState = "known", online = true, xpStale = true },
        { id = "hotel", name = "Hotel", level = 24, xp = 750, xpMax = 1000, xpState = "known", online = false },
        { id = "india", name = "India", level = 24, xp = 200, xpMax = 1000, xpState = "known", online = true },
        { id = "juliet", name = "Juliet", level = 25, xp = 800, xpMax = 1000, xpState = "known", online = true },
    }
    for _, player in ipairs(players) do player.xpUpdatedAt = now end
    players[9].xpUpdatedAt = now - 50000
    progressAddon.GetOverviewPlayers = function()
        local copy = {}
        for _, player in ipairs(players) do copy[#copy + 1] = player end
        return copy
    end
    progressAddon.RequestData = function() snapshots = snapshots + 1 end
    loadOptions(progressAddon, api)
    progressAddon:OpenContent()
    local content, tooltip = progressAddon.contentPanel, api.GameTooltip
    local page = content.overviewPage
    local row = page.rows[1]
    assert(#page.rows == 8 and page:GetWidth() == 680 and row:GetHeight() == 40
        and page.headers.level:GetWidth() == 80 and page.headers.region:GetWidth() == 156
        and row.position:GetWidth() == 156 and row.position.point[2] == 260
        and row.seen.point[2] == 424 and row.actions.point[2] == 520,
        "level progress widens Level and moves Region while preserving row count, panel size and later columns")
    assert(row.level:GetText() == "24" and row.progress:GetText() == "· 42%"
        and row.progressTrack:IsShown() and row.progressFill:IsShown()
        and math.abs(row.progressFill:GetWidth() - 76 * 0.42) < 0.000001,
        "known XP displays the numeric level, floored percentage and proportional thin fill")
    assert(page.rows[2].progress:GetText() == "· 0%" and page.rows[2].progressTrack:IsShown()
        and not page.rows[2].progressFill:IsShown() and page.rows[3].progress:GetText() == "· 99%",
        "zero XP shows an empty track and near-level XP never rounds up to 100 percent")
    assert(page.rows[4].progress:GetText() == "· MAX" and not page.rows[4].progressTrack:IsShown()
        and not page.rows[4].progressFill:IsShown()
        and page.rows[5].progress:GetText() == "· —" and not page.rows[5].progressTrack:IsShown()
        and page.rows[6].level:GetText() == "—" and page.rows[6].progress:GetText() == "",
        "maximum level, unavailable XP and unknown level have distinct states without an ordinary XP bar")
    assert(page.rows[7].progress:GetText() == "· ~50%" and page.rows[7].progress.alpha == 0.55
        and page.rows[7].progressFill.textureColor[4] == 0.35
        and page.rows[8].progress:GetText() == "· ~75%",
        "explicit stale progress and inactive players have a visible marker and subdued fill")
    progressAddon.Theme.skin = { GetAccentColor = function() return 0.8, 0.2, 0.4 end }
    progressAddon:RefreshOverview()
    assert(row.progressFill.textureColor[1] == 0.8 and row.progressFill.textureColor[3] == 0.4,
        "visible progress uses the current optional skin accent")
    progressAddon.Theme.skin.GetAccentColor = function() return 0 / 0, 0.2, 0.4 end
    progressAddon:RefreshOverview()
    assert(row.progressFill.textureColor[1] == 0.27, "nonfinite skin accents safely fall back to native colors")
    progressWorld.secretValue = 0.8
    progressAddon.Theme.skin.GetAccentColor = function() return 0.8, 0.2, 0.4 end
    progressAddon:RefreshOverview()
    assert(row.progressFill.textureColor[1] == 0.27, "secret skin colors do not enter progress arithmetic")
    progressAddon.Theme.skin, progressWorld.secretValue = nil, nil
    row.levelCell.scripts.OnEnter(row.levelCell)
    assert(tooltip.shown and tooltip.owner == row.levelCell and tooltip.text == "Alpha — level 24"
        and tooltip.lines[1] == "XP: 420 / 1000" and tooltip.lines[2] == "To next level: 580 XP"
        and #tooltip.lines == 2, "the whole Level cell explains exact XP and remaining XP without report details")
    progressWorld:advance(13)
    page.scripts.OnUpdate(page, 1)
    assert(#tooltip.lines == 2 and tooltip.lines[1] == "XP: 420 / 1000"
        and row.progress:GetText() == "· 42%" and snapshots == 0,
        "refreshing remote progress does not add report details, mark unchanged XP stale or request status")
    row.levelCell.scripts.OnLeave(row.levelCell)
    assert(not tooltip.shown, "leaving the Level cell dismisses progress details")
    page.rows[4].levelCell.scripts.OnEnter(page.rows[4].levelCell)
    assert(tooltip.lines[1] == "Maximum level" and #tooltip.lines == 1,
        "maximum-level details do not invent zero required XP or add report details")
    page.rows[5].levelCell.scripts.OnEnter(page.rows[5].levelCell)
    assert(tooltip.lines[1] == "Level progress unavailable" and #tooltip.lines == 1,
        "unknown XP is explained without report details")
    page.rows[7].levelCell.scripts.OnEnter(page.rows[7].levelCell)
    assert(tooltip.lines[1] == "XP: 500 / 1000" and tooltip.lines[2] == "To next level: 500 XP"
        and #tooltip.lines == 2, "stale progress tooltips show only XP and remaining XP")
    page:SetOffset(2)
    assert(not tooltip.shown and page.rows[1].playerID == "charlie" and page.rows[1].progress:GetText() == "· 99%"
        and page.rows[7].playerID == "india" and page.rows[7].progress:GetText() == "· 20%"
        and page.rows[7].progressFill.textureColor[4] == 1,
        "scrolling dismisses old tooltips, resets pooled progress styling and keeps old unchanged online reports current")
    page.rows[1].levelCell.scripts.OnEnter(page.rows[1].levelCell)
    page.headers.level:Click()
    assert(not tooltip.shown and page.rows[1].playerID == "alpha", "sorting dismisses progress tooltips and keeps numeric level ordering")
    page:SetOffset(2)
    assert(page.rows[8].playerID == "foxtrot", "unknown levels remain after known levels when sorting ascending")
    page.headers.level:Click()
    page:SetOffset(2)
    assert(page.rows[8].playerID == "foxtrot", "unknown levels remain last when sorting descending")
    page:SetOffset(0)
    page.rows[1].levelCell.scripts.OnEnter(page.rows[1].levelCell)
    content.options:Click()
    assert(not tooltip.shown and not page.active, "leaving Content dismisses progress details and stops live work")
    progressAddon.optionsPanel.content:Click()
    assert(snapshots == 0, "returning to Content reuses status instead of requesting another snapshot")
    row = page.rows[1]
    row.levelCell.scripts.OnEnter(row.levelCell)
    players = {}
    progressAddon:RefreshOverview()
    assert(not tooltip.shown and not row:IsShown() and not row.levelCell.player and row.progress:GetText() == ""
        and not row.progressTrack:IsShown() and not row.progressFill:IsShown(),
        "removing a player clears the pooled cell, progress textures and any owned tooltip")
end

assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep test environments isolated")
print("PASS: Overview navigation, scrolling, sorting, actions and progress")
