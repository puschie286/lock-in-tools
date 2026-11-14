-- This offline suite is never loaded by the addon.
local fixture = dofile("tests/support/addon.lua")
local loadAddon, settings = fixture.loadAddon, fixture.settings
local SECRET, contains = fixture.SECRET, fixture.contains
local loadOptions = dofile("tests/support/ui.lua")

local function clickOutside(menu, mouseButton)
    -- Programmatic Click dispatches directly in the harness; native mouse input
    -- also needs an explicit registration on the full-screen dismissal button.
    assert(contains(menu.clicks or {}, mouseButton .. "Up") or contains(menu.clicks or {}, "AnyUp"),
        "outside dismissal must register native " .. mouseButton .. " input")
    menu:Click(mouseButton)
end

-- Overview scrolls and sorts the Content roster, with guarded native actions on right-click.
do
    local overview, api, _, _, overviewWorld = loadAddon(settings(SECRET, false), false)
    local invites, requests, grouped, mayInvite = {}, {}, false, true
    api.IsInGroup = function() return grouped end
    api.UnitIsGroupLeader = function() return grouped and mayInvite end
    api.UnitIsGroupAssistant = function() return false end
    api.C_PartyInfo = {
        CanInvite = function() return mayInvite end,
        IsPartyFull = function() return false end,
        InviteUnit = function(name) invites[#invites + 1] = name end,
        RequestInviteFromUnit = function(name) requests[#requests + 1] = name end,
    }
    overviewWorld.guild = true
    local guildMembers = {}
    fixture.mockGuild(api, guildMembers)
    for index, name in ipairs({ "Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India", "Juliet" }) do
        guildMembers[index] = { name = name .. "-TestRealm", presence = api.Enum.ClubMemberPresence.Online }
    end
    overviewWorld:initialize()
    local now = api.GetServerTime()
    for index, member in ipairs(guildMembers) do
        assert(overview:ReceivePlayerStatus(member.name, {
            level = index ~= 2 and 20 + index or 0, xpState = "unavailable",
            inParty = index == 2, partyFull = false,
        }, now, 1))
    end
    local snapshotCalls, originalRequest = 0, overview.RequestData
    overview.RequestData = function(self, feature, ...)
        if feature == "status" then snapshotCalls = snapshotCalls + 1 end
        return originalRequest(self, feature, ...)
    end
    loadOptions(overview, api)
    local command = api.SlashCmdList.LOCKINTOOLS
    command("options")
    local options = overview.optionsPanel
    assert(options.selectedTab == "sharing" and not overview.contentPanel and snapshotCalls == 0,
        "opening Settings does not activate Content or request an Overview snapshot")
    command("overview")
    local content = overview.contentPanel
    local page = content.overviewPage
    assert(content.selectedTab == "overview" and content.tabs.overview:GetText() == "Rankings" and not options:IsVisible()
        and page:IsVisible() and page.active and snapshotCalls == 0,
        "the Overview command opens Rankings without requesting a snapshot")
    local ownRow = page.rows[1]
    assert(ownRow.name:GetText() == "Self" and not ownRow.actions,
        "the local player's name has no self suffix or Actions button")
    local shown = ownRow.ranking
    assert(shown:GetChecked() and page.rows[2].ranking:GetChecked(), "shared ranking entries default to shown")
    shown:Click()
    assert(not shown:GetChecked() and not overview:IsRankingPlayerShown(ownRow.playerID, true)
        and page.rows[2].ranking:GetChecked(), "hiding the local character leaves another character shown")
    ownRow:Click("RightButton")
    ownRow.scripts.OnClick(ownRow, "RightButton")
    ownRow.levelCell.scripts.OnMouseUp(ownRow.levelCell, "RightButton")
    assert(not page.actionMenu:IsShown() and #invites == 0 and #requests == 0,
        "right-clicking the local row or its Level cell cannot open actions for self")
    overview:RefreshOverview()
    local function openMenu(index)
        local row = page.rows[index]
        assert(row.frameType == "Button" and row.mouseEnabled and contains(row.clicks, "RightButtonUp"),
            "Overview rows register native right-click input")
        row:Click("RightButton")
        assert(page.actionMenu:IsShown() and page.actionMenu.playerID == row.playerID
            and page.actionMenu.anchor == row,
            "the context menu is anchored to its selected player")
        return page.actionMenu
    end
    page.rows[2]:Click()
    local cell = page.rows[2].levelCell
    cell.scripts.OnEnter(cell)
    cell.scripts.OnMouseUp(cell, "LeftButton")
    assert(api.GameTooltip:IsOwned(cell) and api.GameTooltip:IsShown() and not page.actionMenu:IsShown(),
        "left clicks leave player actions closed and preserve Level hover details")
    cell.scripts.OnMouseUp(cell, "RightButton")
    assert(page.actionMenu:IsShown() and page.actionMenu.playerID == page.rows[2].playerID
        and page.actionMenu.anchor == page.rows[2] and not api.GameTooltip:IsShown(),
        "right-clicking the mouse-enabled Level cell opens its row's menu and dismisses XP details")
    page.rows[2]:Click("RightButton")
    assert(page.actionMenu:IsShown() and page.actionMenu.playerID == page.rows[2].playerID,
        "right-clicking the selected player keeps its menu open")
    page.actionMenu:Hide()
    for _, mouseButton in ipairs({ "RightButton", "LeftButton" }) do
        local menu = openMenu(2)
        menu.party.scripts.OnEnter(menu.party)
        assert(not api.GameTooltip:IsShown() and overview.activePlayerActionMenu == menu,
            "the open Overview context menu shows no action tooltip")
        clickOutside(menu, mouseButton)
        assert(not menu:IsShown() and not menu.playerID and not menu.anchor
            and not overview.activePlayerActionMenu and not api.GameTooltip:IsShown()
            and #invites == 0 and #requests == 0,
            "an outside " .. mouseButton .. " cancels Overview actions without a party action")
    end
    local menu = openMenu(2)
    assert(menu.party:IsShown() and menu.party.action == "invite" and menu.party:GetText() == "Invite"
        and not menu.showMap and menu.menu:GetHeight() == 44,
        "a solo peer offers one party action labelled Invite")
    menu.party:Click()
    menu = openMenu(3)
    assert(menu.party:IsShown() and menu.party.action == "request" and menu.party:GetText() == "Request to join",
        "a grouped peer offers Request to join in the same party entry")
    menu.party:Click()
    assert(#invites == 1 and invites[1] == "Alpha" and #requests == 1 and requests[1] == "Bravo",
        "overview clicks invoke the real guarded actions with local native names")
    -- Open while allowed, then change native eligibility before clicking.
    mayInvite = true
    menu = openMenu(2)
    mayInvite = false
    menu.party:Click()
    assert(#invites == 1 and content.feedback:GetText() ~= "",
        "an enabled stale menu item cannot bypass the action-time permission check")
    page.rows[2]:Click("RightButton")
    assert(not menu:IsShown() and not menu.playerID, "an unavailable party action leaves the menu closed")
    mayInvite = true
    menu = openMenu(2)
    assert(menu:IsShown() and menu.playerID == "alpha-testrealm" and menu.party:IsShown()
        and menu.party.action == "invite",
        "a refresh preserves the selected player and updates an open menu's eligibility")
    grouped, mayInvite = true, false
    overview:RefreshOverview()
    assert(menu.party:IsShown() and menu.party.action == "suggest" and menu.party:GetText() == "Suggest Invite",
        "an open party entry changes to Suggest Invite for a member without invite permission")
    menu.party:Click()
    assert(#invites == 2 and invites[2] == "Alpha" and #requests == 1,
        "Suggest Invite uses the native invitation path for the selected player")
    menu = openMenu(2)
    mayInvite = true
    overview:RefreshOverview()
    assert(menu.party:IsShown() and menu.party.action == "invite" and menu.party:GetText() == "Invite",
        "gaining invitation permission updates the same menu entry to Invite")
    menu = openMenu(3)
    assert(menu.party:IsShown() and not menu.party:IsEnabled() and not menu.party.action
        and menu.party:GetText() == "Already in another group",
        "another group's player has a disabled informational party row")
    menu.party:Click()
    menu.party.scripts.OnClick(menu.party, "LeftButton")
    assert(#invites == 2 and #requests == 1, "the informational row cannot perform a party action even through a stale callback")
    menu = openMenu(3)
    grouped = false
    overview:RefreshOverview()
    assert(menu.party:IsShown() and menu.party:IsEnabled() and menu.party.action == "request"
        and menu.party:GetText() == "Request to join", "leaving our group replaces information with the join action")
    grouped = true
    overview:RefreshOverview()
    assert(overview:ReceivePlayerStatus("Bravo-TestRealm", {
        level = 0, xpState = "unavailable", inParty = false, partyFull = false,
    }, now, 2))
    assert(menu.party:IsEnabled() and menu.party.action == "invite" and menu.party:GetText() == "Invite",
        "a fresh report that the peer left their group replaces information with Invite")
    assert(overview:ReceivePlayerStatus("Bravo-TestRealm", {
        level = 0, xpState = "unavailable", inParty = true, partyFull = false,
    }, now, 3))
    grouped = false
    page:SetOffset(1)
    assert(not menu:IsShown() and page.offset == 1 and page.rows[1].playerID == "alpha-testrealm"
        and page.scrollbar:GetValue() == 1,
        "scrolling recycles the self row for a peer and dismisses the old menu")
    assert(shown:GetChecked(), "a recycled Rankings checkbox adopts the newly visible character's setting")
    openMenu(1)
    page.scripts.OnMouseWheel(page, -1)
    assert(page.offset > 1, "mouse wheel down moves through the roster")
    page:SetOffset(999)
    assert(page.offset == 3 and page.rows[1].playerID == "charlie-testrealm"
        and page.rows[8].playerID == "juliet-testrealm",
        "scrolling to the end reveals the last player without an extra page")
    page.scrollbar:SetValue(0)
    page.rows[1]:Click("RightButton")
    assert(page.offset == 0 and page.rows[1].playerID == "self-testrealm" and not menu:IsShown(),
        "dragging the scrollbar back to self prevents the recycled row from opening actions")
    page.scripts.OnMouseWheel(page, 1)
    assert(page.offset == 0, "mouse wheel up clamps at the first player")

    openMenu(2)
    page.headers.name:Click()
    assert(not menu:IsShown() and page.sortKey == "name" and not page.sortDescending
        and page.offset == 0 and page.rows[1].playerID == "alpha-testrealm",
        "clicking a column sorts ascending and dismisses the selected player's menu")
    page:SetOffset(3)
    page.rows[8]:Click("RightButton")
    assert(page.rows[8].playerID == "self-testrealm" and not menu:IsShown(),
        "self remains in ordinary name order without an action menu after sorting")
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
    assert(not page.headers.region and not page.rows[1].position,
        "Rankings has no shared region column")
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
    assert(not menu:IsShown() and not menu.playerID and snapshotCalls == 0,
        "contact expiry dismisses the unavailable action without requesting status")
    assert(page.rows[1].seen:GetText() == "1m ago", "offline rows retain the last-seen age")
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
    assert(options.selectedTab == "sharing"
        and options.pages.sharing:IsVisible() and not page.active and not page.scripts.OnUpdate
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
    overview.rosterState.peers[page.rows[1].playerID].lastReceived = api.GetTime()
    openMenu(1)
    for index = #guildMembers, 1, -1 do guildMembers[index] = nil end
    overviewWorld.fire("GUILD_ROSTER_UPDATE", false)
    assert(page.offset == 0 and page.rows[1].playerID == "self-testrealm"
        and not page.rows[2]:IsShown() and not page.rows[2].playerID and not page.scrollbar:IsShown()
        and not menu:IsShown() and not page.empty:IsShown(),
        "live roster removal clamps scrolling, removes old row targets and closes obsolete menus")
    page.rows[2].scripts.OnClick(page.rows[2], "RightButton")
    page.rows[2].levelCell.scripts.OnMouseUp(page.rows[2].levelCell, "RightButton")
    assert(not menu:IsShown(), "late row and Level clicks cannot reopen actions for a removed player")
    overviewWorld.guild = false
    overviewWorld.fire("PLAYER_GUILD_UPDATE", "player")
    assert(page.empty:IsShown() and not page.rows[1]:IsShown() and not page.rows[1].playerID,
        "leaving every native sharing context hides the disconnected roster")
end

-- Content shows current guild membership and combines it with native friends in Rankings.
do
    local addon, api, _, fire, world = loadAddon(settings(SECRET, false), false)
    local members = {}
    fixture.mockGuild(api, members)
    local requests = 0
    api.C_GuildInfo.GuildRoster = function() requests = requests + 1 end
    local presence = api.Enum.ClubMemberPresence
    members[1] = { name = "Peer-TestRealm", level = 22, presence = presence.Online }
    members[2] = { name = "Offline-TestRealm", level = 31, presence = presence.Offline }
    members[3] = { name = "Self-TestRealm", level = 12, presence = presence.Online, isSelf = true }
    local friends = { { id = "pal-testrealm", name = "Pal-TestRealm", level = 28, online = true } }
    function addon:GetFriendsPlayers() return friends end
    world.guild = true
    world:initialize()
    local now = api.GetServerTime()
    assert(addon:ReceivePlayerStatus("Peer-TestRealm", { level = 22, xp = 50, xpMax = 100, xpState = "known" }, now, 1))
    assert(addon:ReceivePlayerStatus("Former-TestRealm", { level = 24, xp = 25, xpMax = 100, xpState = "known" }, now, 1))
    loadOptions(addon, api)
    assert(requests == 0, "guild roster requests wait for a roster tab to open")
    addon:OpenContent()
    local content = addon.contentPanel
    local rankings, guild = content.pages.overview, content.pages.guild
    local function rowsByID(page)
        local rows = {}
        for _, row in ipairs(page.rows) do
            if row:IsVisible() then
                assert(row.playerID and not rows[row.playerID], "each character has one visible row")
                rows[row.playerID] = row
            end
        end
        return rows
    end
    local combined = rowsByID(rankings)
    assert(combined["self-testrealm"] and combined["peer-testrealm"].progress:GetText() == "50%"
        and combined["offline-testrealm"].level:GetText() == "31"
        and combined["pal-testrealm"].level:GetText() == "28" and not combined["pal-testrealm"].ranking:GetChecked()
        and not combined["former-testrealm"], "Rankings combines eligible rows and retains reported XP and overlay defaults")
    combined["pal-testrealm"].ranking:Click()
    assert(addon:IsRankingPlayerShown("pal-testrealm", false), "Rankings can opt a native friend into the overlay")
    local peerCell = combined["peer-testrealm"].levelCell
    peerCell.scripts.OnEnter(peerCell)
    content.tabs.guild:Click()
    local guildRows = rowsByID(guild)
    assert(content.selectedTab == "guild" and guild.active and not rankings.active and not api.GameTooltip:IsShown()
        and guildRows["self-testrealm"] and guildRows["peer-testrealm"].progress:GetText() == "50%"
        and guildRows["offline-testrealm"] and not guildRows["offline-testrealm"].ranking:IsEnabled()
        and not guildRows["pal-testrealm"] and not guildRows["former-testrealm"] and requests == 1,
        "Guild opens independently, dismisses the prior tooltip and lists only current guild members")
    table.remove(members, 1)
    fire("CLUB_MEMBER_REMOVED", 100, 1)
    guildRows = rowsByID(guild)
    assert(not guildRows["peer-testrealm"] and addon.rosterState.peers["peer-testrealm"] and guildRows["offline-testrealm"],
        "a membership change immediately removes the row while preserving the stored report")
    assert(addon:SetDataChannelEnabled("guild", false))
    assert(rowsByID(guild)["offline-testrealm"], "native guild membership is visible with Guild sharing disabled")
    world.guild = false
    fire("PLAYER_GUILD_UPDATE", "player")
    assert(guild.empty:IsShown() and not next(rowsByID(guild)), "the Guild tab clears when the local character leaves")
    content.tabs.overview:Click()
    combined = rowsByID(rankings)
    assert(combined["self-testrealm"] and combined["pal-testrealm"] and not combined["offline-testrealm"]
        and not guild.active and #world.notificationErrors == 0, "Rankings keeps native friends after leaving the guild")
end

-- Friends uses the native player snapshot even with no sharing context.
do
    local addon, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    local friends, shared, reads = {}, {}, 0
    function addon:GetFriendsPlayers()
        reads = reads + 1
        return friends
    end
    function addon:GetOverviewPlayers() return shared end
    loadOptions(addon, api)
    addon:OpenContent()
    local content = addon.contentPanel
    local overview, page = content.pages.overview, content.pages.friends
    assert(overview.active and overview.empty:IsShown() and not page:IsShown())
    content.tabs.friends:Click()
    assert(content.selectedTab == "friends" and page:IsVisible() and page.empty:IsShown()
        and not page.scripts.OnUpdate and not overview.active and not overview.scripts.OnUpdate,
        "Friends has its own empty view and only the selected page does live UI work")
    friends = {
        { id = "ada-ironwood", aliasID = "ada ironwood-testrealm", name = "Ada-Ironwood", displayName = "Ada Ironwood",
            level = 22, zone = "Westfall", online = true },
        { id = "brin-testrealm", name = "Brin", level = 31, online = false },
        { id = "cora-testrealm", name = "Cora" },
    }
    for index = 1, 7 do
        friends[#friends + 1] = { id = "friend" .. index, name = "Friend " .. index, level = 40 + index, online = true }
    end
    addon:Notify("FRIENDS_CHANGED")
    assert(not page.empty:IsShown() and page.scrollbar:IsShown()
        and page.rows[1].name:GetText() == "Ada Ironwood" and page.rows[1].level:GetText() == "22"
        and page.rows[1].zone:GetText() == "Westfall" and page.rows[1].status:GetText() == "Online"
        and page.rows[2].status:GetText() == "Offline" and page.rows[2].zone:GetText() == "—"
        and page.rows[3].status:GetText() == "Unknown" and page.rows[3].level:GetText() == "—",
        "native friend rows preserve surnames, known level and zone, and three distinct presence states")
    local ranking = page.rows[1].ranking
    assert(not ranking:GetChecked() and not page.rows[2].ranking:GetChecked())
    ranking:Click()
    assert(ranking:GetChecked() and not page.rows[2].ranking:GetChecked()
        and addon:IsRankingPlayerShown("ada-ironwood", false), "clicking Shown opts in only its friend")
    page.scrollbar:SetValue(2)
    assert(page.rows[8].name:GetText() == "Friend 7" and page.offset == 2 and not ranking:GetChecked(),
        "a pooled checkbox adopts the visible friend's saved selection on scroll")
    ranking:Click()
    assert(addon:IsRankingPlayerShown("cora-testrealm", false) and addon:IsRankingPlayerShown("ada-ironwood", false)
        and not addon:IsRankingPlayerShown("brin-testrealm", false),
        "the reused checkbox targets the current friend even before a level is available")
    page.headers.level:Click()
    assert(page.offset == 0 and page.rows[1].name:GetText() == "Ada Ironwood" and ranking:GetChecked())
    ranking:Click()
    assert(not addon:IsRankingPlayerShown("ada-ironwood", false) and addon:IsRankingPlayerShown("cora-testrealm", false),
        "unchecking one friend leaves another friend's ranking inclusion selected")
    page.headers.level:Click()
    assert(page.rows[1].name:GetText() == "Friend 7" and friends[1].id == "ada-ironwood",
        "Friends sorts levels numerically without mutating the shared snapshot")
    page.headers.status:Click()
    page:SetOffset(2)
    assert(page.rows[8].status:GetText() == "Unknown" and page.rows[7].status:GetText() == "Offline",
        "status sorts online first by default and leaves unknown status last")

    shared = { { id = "ada ironwood-testrealm" }, { id = "brin-testrealm" } }
    addon:Notify("ROSTER_CHANGED")
    assert(page.offset == 0 and not page.scrollbar:IsShown() and #friends == 10
        and page.rows[8].playerID == "cora-testrealm" and page.rows[8].ranking:GetChecked(),
        "shared IDs and surname aliases disappear from Friends while selected native-only rows remain editable")
    for _, row in ipairs(page.rows) do
        assert(row.playerID ~= "ada-ironwood" and row.playerID ~= "brin-testrealm")
    end
    shared = {}
    addon:Notify("ROSTER_CHANGED")
    assert(page.scrollbar:IsShown(), "friends reappear when their Rankings entries are removed")

    content.options:Click()
    local hiddenReads = reads
    friends = { friends[2] }
    addon:Notify("FRIENDS_CHANGED")
    assert(reads == hiddenReads, "native updates do not rebuild a hidden Friends page")
    addon.optionsPanel.content:Click()
    assert(content.selectedTab == "friends" and page:IsVisible() and page.offset == 0
        and page.rows[1].name:GetText() == "Brin" and not ranking:GetChecked()
        and not page.rows[2]:IsShown() and not page.rows[2].playerID
        and not page.scrollbar:IsShown(), "returning to Friends refreshes rows and clamps the scroll offset")
    api.SlashCmdList.LOCKINTOOLS("overview")
    assert(content.selectedTab == "overview" and overview.active and not page:IsVisible(),
        "the Overview command selects Rankings even after viewing Friends")
end

-- Newer saved profiles display existing selections and disable editing.
do
    local saved = settings(SECRET, false)
    saved.schemaVersion, saved.ranking = 5, { includedFriends = { ["ada-ironwood"] = true } }
    local addon, api, _, _, world = loadAddon(saved, false)
    world:initialize()
    function addon:GetFriendsPlayers() return { { id = "ada-ironwood", name = "Ada Ironwood", level = 22 } } end
    loadOptions(addon, api)
    addon:OpenContent("friends")
    local ranking = addon.contentPanel.pages.friends.rows[1].ranking
    assert(ranking:GetChecked() and not ranking:IsEnabled())
    ranking:SetChecked(false)
    ranking.scripts.OnClick(ranking)
    assert(ranking:GetChecked() and saved.ranking.includedFriends["ada-ironwood"] == true,
        "the checkbox restores the saved selection when a write is rejected")
end

-- Player actions also work on independent surfaces without opening Content.
do
    local actions, api, _, _, world = loadAddon(settings(SECRET, false), false)
    api.C_PartyInfo = {
        CanInvite = function() return true end,
        IsPartyFull = function() return false end,
        InviteUnit = function() end,
        RequestInviteFromUnit = function() end,
    }
    api.GameTooltip_SetDefaultAnchor = function(tooltip, owner)
        tooltip:SetOwner(owner, "ANCHOR_CURSOR")
    end
    local scroll = 0
    world.guild = true
    world:initialize()
    assert(actions:ReceivePlayerStatus("Alpha-TestRealm", {
        level = 21, xpState = "unavailable", inParty = false, partyFull = false,
    }, api.GetServerTime(), 1))
    loadOptions(actions, api)
    local firstParent = api.CreateFrame("Frame", nil, api.UIParent)
    local secondParent = api.CreateFrame("Frame", nil, api.UIParent)
    api.UIParent:SetScale(0.8)
    firstParent:SetScale(0.5)
    world.cursorX, world.cursorY = 720, 480
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
    local point, relativeTo, relativePoint, x, y = menu.menu:GetPoint()
    assert(point == "TOPLEFT" and relativeTo == menu and relativePoint == "BOTTOMLEFT"
        and x == 1800 and y == 1200 and menu.menu.clamped,
        "player menus open at the cursor using inherited window and UI scale with screen clamping")
    local tooltip = api.GameTooltip
    assert(menu.party:IsShown() and menu.party.action == "invite" and not menu.showMap,
        "independent menus offer the available party action")
    menu.party.scripts.OnEnter(menu.party)
    assert(not tooltip:IsShown(), "player actions have no hover tooltip")
    menu.party.scripts.OnLeave(menu.party)
    world.cursorX, world.cursorY = 960, 640
    menu:Refresh()
    local _, _, _, refreshedX, refreshedY = menu.menu:GetPoint()
    assert(refreshedX == x and refreshedY == y,
        "live refresh keeps an open menu at the original click position")
    assert(not tooltip:IsShown(), "refreshing player actions does not create a tooltip")
    menu.menu.mouseOver = true
    world.fire("GLOBAL_MOUSE_UP", "LeftButton")
    local _, _, _, leftX, leftY = menu.menu:GetPoint()
    assert(leftX == x and leftY == y, "left mouse releases do not reposition the menu")
    world.fire("GLOBAL_MOUSE_UP", "RightButton")
    local _, _, _, reopenedX, reopenedY = menu.menu:GetPoint()
    assert(menu:IsShown() and menu.playerID == "alpha-testrealm" and menu.anchor == anchor
        and actions.activePlayerActionMenu == menu and reopenedX == 2400 and reopenedY == 1600,
        "right-clicking inside a menu reopens the same player's actions at the current cursor")
    menu.party:Click("RightButton")
    world.fire("GLOBAL_MOUSE_UP", "RightButton")
    assert(menu:IsShown() and menu.playerID == "alpha-testrealm",
        "right clicks on the party entry preserve the menu without running the action")
    menu.menu.mouseOver = false
    otherMenu:Open("alpha-testrealm", otherAnchor)
    local _, otherRelativeTo, _, otherX, otherY = otherMenu.menu:GetPoint()
    assert(otherRelativeTo == otherMenu and otherX == 1200 and otherY == 800,
        "opening another surface uses the current cursor and that window's effective scale")
    assert(not menu:IsShown() and not menu.playerID and not menu.anchor and not api.GameTooltip.shown
        and otherMenu:IsShown() and actions.activePlayerActionMenu == otherMenu,
        "opening a player menu dismisses the other surface without showing a tooltip")
    otherMenu:Open("alpha-testrealm", otherAnchor)
    assert(otherMenu:IsShown() and actions.activePlayerActionMenu == otherMenu,
        "opening the same player again keeps its menu available")
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
        { id = "alpha", name = "Alpha-Stone", displayName = "Alpha Stone", level = 24,
            xp = 420, xpMax = 1000, xpState = "known", online = true },
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
    loadOptions(progressAddon, api)
    progressAddon.GetContentRankingPlayers = function()
        local copy = {}
        for _, player in ipairs(players) do copy[#copy + 1] = player end
        return copy
    end
    progressAddon.RequestData = function() snapshots = snapshots + 1 end
    progressAddon:OpenContent()
    local content, tooltip = progressAddon.contentPanel, api.GameTooltip
    local page = content.overviewPage
    local row = page.rows[1]
    assert(row.level:GetText() == "24" and row.progress:GetText() == "42%"
        and row.progressTrack:IsShown() and row.progressFill:IsShown()
        and math.abs(row.progressFill:GetWidth() - row.progressTrack:GetWidth() * 0.42) < 0.000001,
        "known XP displays the numeric level, floored percentage and proportional thin fill")
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
    assert(tooltip.shown and tooltip.owner == row.levelCell and tooltip.text == "Alpha Stone — level 24"
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
print("PASS: Rankings, Guild and Friends navigation, scrolling, sorting, actions and progress")
