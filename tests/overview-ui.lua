-- This offline suite is never loaded by the addon.
local fixture = dofile("tests/support/addon.lua")
local loadAddon, settings = fixture.loadAddon, fixture.settings
local SECRET, OTHER_SECRET, contains = fixture.SECRET, fixture.OTHER_SECRET, fixture.contains
local loadOptions = dofile("tests/support/ui.lua")

-- Overview scrolls and sorts the Content roster, with guarded native actions in a dropdown.
do
    local overview, api, _, _, overviewWorld = loadAddon(settings(SECRET, false), false)
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
        assert(overview:ReceivePlayerStatus(name .. "-TestRealm", {
            level = name ~= "Bravo" and 20 + index or 0, xpState = "unavailable",
            inParty = name == "Bravo", partyFull = false,
        }, now, 1))
    end
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
        and overview:GetGroupSecret() == SECRET,
        "overview command opens Content and clears group-key drafts and confirmation")
    local ownRow = page.rows[1]
    assert(ownRow.name:GetText() == "Self" and not ownRow.actions:IsEnabled(),
        "the local player's name has no self suffix and its Actions trigger is disabled")
    ownRow.actions:Click()
    ownRow.actions.scripts.OnClick(ownRow.actions)
    ownRow.actions:SetEnabled(true)
    ownRow.actions:Click()
    assert(not page.actionMenu:IsShown() and #invites == 0 and #requests == 0,
        "disabled, programmatic and stale enabled triggers cannot open actions for self")
    overview:RefreshOverview()
    local function openMenu(index)
        local row = page.rows[index]
        row.actions:Click()
        assert(page.actionMenu:IsShown() and page.actionMenu.playerID == row.playerID
            and page.actionMenu.anchor == row,
            "the actions dropdown is anchored to its selected player")
        return page.actionMenu
    end
    local menu = openMenu(2)
    assert(menu.invite:IsEnabled() and not menu.request:IsEnabled(),
        "an ungrouped peer offers an invite but explains the unavailable join request")
    menu.invite:Click()
    menu = openMenu(3)
    assert(not menu.invite:IsEnabled() and menu.request:IsEnabled(),
        "a grouped peer offers a join request instead of an invite")
    menu.request:Click()
    assert(#invites == 1 and invites[1] == "Alpha-TestRealm" and #requests == 1 and requests[1] == "Bravo-TestRealm",
        "overview clicks invoke the real guarded native actions with complete names")
    -- Open while allowed, then change native eligibility before clicking.
    mayInvite = true
    menu = openMenu(2)
    mayInvite = false
    menu.invite:Click()
    assert(#invites == 1 and content.feedback:GetText() ~= "",
        "an enabled stale dropdown item cannot bypass the action-time permission check")
    menu = openMenu(2)
    assert(not menu.invite:IsEnabled() and menu.invite.reason,
        "reopening a menu refreshes disabled action state and its explanation")
    mayInvite = true
    overview:RefreshOverview()
    assert(menu:IsShown() and menu.playerID == "alpha-testrealm" and menu.invite:IsEnabled(),
        "a refresh preserves the selected player and updates an open menu's eligibility")
    page:SetOffset(1)
    assert(not menu:IsShown() and page.offset == 1 and page.rows[1].playerID == "alpha-testrealm"
        and page.rows[1].actions:IsEnabled() and page.scrollbar:GetValue() == 1,
        "scrolling recycles the self row for a peer with Actions enabled and dismisses the old menu")
    openMenu(1)
    page.scripts.OnMouseWheel(page, -1)
    assert(page.offset > 1, "mouse wheel down moves through the roster")
    page:SetOffset(999)
    assert(page.offset == 3 and page.rows[1].playerID == "charlie-testrealm"
        and page.rows[8].playerID == "juliet-testrealm",
        "scrolling to the end reveals the last player without an extra page")
    page.scrollbar:SetValue(0)
    assert(page.offset == 0 and page.rows[1].playerID == "self-testrealm" and not page.rows[1].actions:IsEnabled(),
        "dragging the scrollbar back to self disables the recycled row's Actions trigger")
    page.scripts.OnMouseWheel(page, 1)
    assert(page.offset == 0, "mouse wheel up clamps at the first player")

    openMenu(2)
    page.headers.name:Click()
    assert(not menu:IsShown() and page.sortKey == "name" and not page.sortDescending
        and page.offset == 0 and page.rows[1].playerID == "alpha-testrealm",
        "clicking a column sorts ascending and dismisses the selected player's menu")
    page:SetOffset(3)
    assert(page.rows[8].playerID == "self-testrealm" and not page.rows[8].actions:IsEnabled(),
        "self remains in ordinary name order with Actions disabled after sorting")
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
    assert(page.rows[1].playerID == "alpha-testrealm" and page.rows[2].playerID == "charlie-testrealm",
        "region sorting uses shared map names before missing regions")
    overview.rosterState.peers["alpha-testrealm"].seenAt = now - 20
    overview.rosterState.peers["bravo-testrealm"].seenAt = now - 10
    page.headers.seen:Click()
    assert(page.rows[1].playerID == "charlie-testrealm", "contact sorting starts with the most recent peer")
    page.headers.seen:Click()
    assert(page.rows[1].playerID == "alpha-testrealm", "contact sorting can show oldest contacts first")
    page.headers.name:Click()
    menu = openMenu(1)
    overviewWorld:advance(90)
    assert(page.scripts.OnUpdate, "only the active overview page installs an age refresh")
    page.scripts.OnUpdate(page, 1)
    assert(menu:IsShown() and menu.playerID == "alpha-testrealm" and not menu.invite:IsEnabled()
        and snapshotCalls == 0, "contact expiry disables actions without changing menu identity or requesting status")
    assert(page.rows[1].position:GetText() == "Elwynn Forest",
        "offline region labels show the saved location without a prefix")
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
    assert(page.empty:IsShown() and not page.rows[1]:IsShown(), "pending departure immediately hides the old roster")
    overviewWorld:advance(0)
    assert(page.empty:IsShown()
        and not page.rows[1]:IsShown() and not page.rows[1].playerID,
        "leaving the global group clears the overview while it remains open")
end

-- Player actions also work on independent surfaces without opening Content.
do
    local actions, api, _, _, world = loadAddon(settings(SECRET, false), false)
    api.GameTooltip_SetDefaultAnchor = function(tooltip, owner)
        tooltip:SetOwner(owner, "ANCHOR_CURSOR")
    end
    local scroll = 0
    world:initialize()
    world:completeJoin(actions:GetGroupDataChannelName(), 7)
    assert(actions:ReceivePlayerStatus("Alpha-TestRealm", {
        level = 21, xpState = "unavailable", inParty = false, partyFull = false,
    }, api.GetServerTime(), 1))
    loadOptions(actions, api)
    local firstParent = api.CreateFrame("Frame", nil, api.UIParent)
    local secondParent = api.CreateFrame("Frame", nil, api.UIParent)
    local anchor = api.CreateFrame("Frame", nil, firstParent)
    local otherAnchor = api.CreateFrame("Frame", nil, secondParent)
    local menu = actions:CreatePlayerActionMenu(firstParent, "LockInToolsTestPlayerActions", nil,
        function(delta) scroll = scroll + delta end)
    local otherMenu = actions:CreatePlayerActionMenu(secondParent, "LockInToolsTestOtherActions")
    assert(not actions.contentPanel and not menu:IsShown() and not otherMenu:IsShown(),
        "independent player menus do not create or open Content")
    menu:Open("self-testrealm", anchor)
    assert(not menu:IsShown() and not menu.playerID and not actions.activePlayerActionMenu,
        "the shared menu rejects self targets before selecting or showing actions")
    menu:Open("alpha-testrealm", anchor)
    local tooltip = api.GameTooltip
    assert(not menu.request:IsEnabled(), "an unavailable action still exposes hover help")
    menu.request.scripts.OnEnter(menu.request)
    assert(tooltip:IsShown() and tooltip:IsOwned(menu.request) and tooltip.anchor == "ANCHOR_CURSOR",
        "disabled player-action help follows global tooltip positioning")
    menu.invite.scripts.OnEnter(menu.invite)
    menu.request.scripts.OnLeave(menu.request)
    menu:Refresh()
    assert(tooltip:IsShown() and tooltip:IsOwned(menu.invite) and tooltip.anchor == "ANCHOR_CURSOR",
        "enabled action help keeps global positioning across refresh and another owner's leave")
    otherMenu:Open("alpha-testrealm", otherAnchor)
    assert(not menu:IsShown() and not menu.playerID and not menu.anchor and not api.GameTooltip.shown
        and otherMenu:IsShown() and actions.activePlayerActionMenu == otherMenu,
        "opening a player menu dismisses the other surface and its owned tooltip")
    otherMenu:Open("alpha-testrealm", otherAnchor)
    assert(not otherMenu:IsShown() and not actions.activePlayerActionMenu,
        "opening the same player again toggles the menu closed")
    menu:Open("alpha-testrealm", anchor)
    assert(contains(api.UISpecialFrames, menu.name), "menus register for native Escape dismissal")
    api[menu.name]:Hide()
    assert(not menu.playerID and not menu.anchor, "native Escape dismissal clears the selected target")
    menu:Open("alpha-testrealm", anchor)
    menu.scripts.OnMouseWheel(menu, -1)
    assert(not menu:IsShown() and scroll == -1, "wheel dismissal preserves the owner's scrolling callback")
    menu:Open("alpha-testrealm", anchor)
    firstParent:Hide()
    firstParent:Show()
    assert(not menu:IsShown() and not menu.playerID and not actions.activePlayerActionMenu,
        "hiding and reopening a parent cannot restore a stale action target")
    otherMenu:Open("alpha-testrealm", otherAnchor)
    otherMenu.scripts.OnMouseWheel(otherMenu, 1)
    assert(not otherMenu:IsShown(), "independent menus without scrolling still dismiss on the wheel")
end

-- Level progress fits the pooled Overview rows and explains exact values without requesting on each refresh.
do
    local progressAddon, api, _, _, progressWorld = loadAddon(settings(SECRET, false), false)
    local anchorOwners = {}
    api.GameTooltip_SetDefaultAnchor = function(tooltip, owner)
        anchorOwners[#anchorOwners + 1] = owner
        tooltip:SetOwner(owner, "ANCHOR_CURSOR")
    end
    progressWorld:initialize()
    local now, snapshots = api.GetServerTime(), 0
    local players = {
        { id = "alpha", name = "Alpha-Other Realm", level = 24, xp = 420, xpMax = 1000, xpState = "known", online = true },
        { id = "bravo", name = "Bravo", level = 24, xp = 0, xpMax = 1000, xpState = "known", online = true },
        { id = "charlie", name = "Charlie", level = 24, xp = 999, xpMax = 1000, xpState = "known", online = true },
        { id = "delta", name = "Delta", level = 60, xpState = "max", online = false },
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
    assert(row.level:GetText() == "24" and row.progress:GetText() == "42%"
        and row.progressTrack:IsShown() and row.progressFill:IsShown()
        and math.abs(row.progressFill:GetWidth() - row.progressTrack:GetWidth() * 0.42) < 0.000001,
        "known XP displays the numeric level, floored percentage and proportional thin fill")
    assert(row.progress.point[1] == "LEFT" and row.progress.point[2] == row.level
        and row.progress.point[3] == "RIGHT" and row.progress.point[4] == 6 and row.progress.point[5] == 0
        and row.progress.justifyH == "RIGHT" and row.progress:GetHeight() == 12
        and row.level:GetWidth() + row.progress.point[4] + row.progress:GetWidth() <= row.levelCell:GetWidth(),
        "the percentage is right aligned beside the level value on the same horizontal line within the Level column")
    assert(row.name:GetWidth() == 124 and page.headers.name:GetWidth() == 124
        and page.headers.level.point[2] == 148 and row.levelCell.point[2] == 132
        and row.levelCell:GetWidth() == 80
        and page.headers.region.point[2] == 236 and page.headers.region:GetWidth() == 196
        and row.position.point[2] == 220 and row.position:GetWidth() == 196
        and row.progressTrack:GetWidth() == 36 and row.progressTrack.point[3] == -24,
        "a shorter Name column gives Region more room while keeping the Level cell and XP bar dimensions")
    assert(page.rows[2].progress:GetText() == "0%" and page.rows[2].progressTrack:IsShown()
        and not page.rows[2].progressFill:IsShown() and page.rows[3].progress:GetText() == "99%",
        "zero XP shows an empty track and near-level XP never rounds up to 100 percent")
    assert(page.rows[4].progress:GetText() == "MAX" and page.rows[4].progress.alpha == 0.55
        and not page.rows[4].progressTrack:IsShown()
        and not page.rows[4].progressFill:IsShown()
        and page.rows[5].progress:GetText() == "—" and not page.rows[5].progressTrack:IsShown()
        and page.rows[6].level:GetText() == "—" and page.rows[6].progress:GetText() == "",
        "maximum level, unavailable XP and unknown level have distinct states without an ordinary XP bar")
    assert(page.rows[7].progress:GetText() == "50%" and page.rows[8].progress:GetText() == "75%"
        and page.rows[7].progress.alpha == 0.55 and page.rows[8].progress.alpha == 0.55
        and page.rows[7].progressFill.textureColor[4] == 0.35
        and page.rows[8].progressFill.textureColor[4] == 0.35,
        "stale and offline progress omit the tilde while retaining dimmed percentages and bars")
    row.levelCell.scripts.OnEnter(row.levelCell)
    assert(tooltip.shown and tooltip.owner == row.levelCell
        and tooltip.lines[1] == "XP: 420 / 1000" and tooltip.lines[2] == "To next level: 580 XP"
        and #tooltip.lines == 2, "the whole Level cell explains exact XP and remaining XP without report details")
    assert(#anchorOwners == 1 and anchorOwners[1] == row.levelCell and tooltip.anchor == "ANCHOR_CURSOR",
        "Overview progress follows the global tooltip position")
    progressWorld:advance(13)
    page.scripts.OnUpdate(page, 1)
    assert(#tooltip.lines == 2 and tooltip.lines[1] == "XP: 420 / 1000"
        and row.progress:GetText() == "42%" and snapshots == 0,
        "refreshing remote progress does not add report details, mark unchanged XP stale or request status")
    assert(#anchorOwners == 2 and anchorOwners[2] == row.levelCell and tooltip.anchor == "ANCHOR_CURSOR",
        "live Overview refresh honors the global tooltip positioning hook")
    row.levelCell.scripts.OnLeave(row.levelCell)
    assert(not tooltip.shown, "leaving the Level cell dismisses progress details")
    page:SetOffset(2)
    assert(not tooltip.shown and page.rows[1].playerID == "charlie" and page.rows[1].progress:GetText() == "99%"
        and page.rows[7].playerID == "india" and page.rows[7].progress:GetText() == "20%",
        "scrolling dismisses old tooltips and keeps unchanged online progress current")
    page.rows[1].levelCell.scripts.OnEnter(page.rows[1].levelCell)
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
