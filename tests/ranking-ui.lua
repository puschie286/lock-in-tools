-- This offline suite is never loaded by the addon.
local fixture = dofile("tests/support/addon.lua")
local loadAddon, settings = fixture.loadAddon, fixture.settings
local SECRET, OTHER_SECRET, contains = fixture.SECRET, fixture.OTHER_SECRET, fixture.contains
local loadOptions = dofile("tests/support/ui.lua")

local function loadOverlay(addon, environment)
    loadOptions(addon, environment)
    if addon.RefreshRankingOverlay then return end
    local chunk, problem
    if setfenv then
        chunk, problem = loadfile("RankingOverlay.lua")
        assert(chunk, problem)
        setfenv(chunk, environment)
    else
        chunk, problem = loadfile("RankingOverlay.lua", "t", environment)
        assert(chunk, problem)
    end
    chunk("LockInTools", addon)
end

local function placed(window, parent, point, relativePoint, x, y)
    local anchor, relativeTo, relativeAnchor, actualX, actualY = window:GetPoint()
    return anchor == point and relativeTo == parent and relativeAnchor == relativePoint
        and actualX == x and actualY == y
end

local function row(id, rank, level, xp, maximum, isSelf)
    return { id = id, name = id, rank = rank, level = level, xp = xp, xpMax = maximum,
        xpState = xp and "known" or "max", online = true, isSelf = isSelf }
end

local function tooltipText(tooltip)
    return (tooltip.text or "") .. "\n" .. table.concat(tooltip.lines, "\n")
end

-- Visibility is independent of the main window and dismissal survives subsequent data events.
do
    local saved = settings(SECRET, false)
    local ranking, api, messages, _, world = loadAddon(saved, false)
    world:initialize()
    loadOverlay(ranking, api)
    local command = api.SlashCmdList.LOCKINTOOLS
    ranking:RefreshRankingOverlay()
    assert(not ranking.rankingOverlay and not ranking.mainPanel and not ranking:GetRankingSettings().enabled,
        "ranking starts disabled without constructing either window")
    command("ranking")
    local panel = ranking.rankingOverlay
    assert(panel and panel:IsVisible() and saved.ranking.enabled and not ranking.mainPanel
        and panel.TitleText:GetText() == "Player Rankings (XP)"
        and not panel.help and not panel.lock and not panel.columnHeaders and not panel.subtitle,
        "the ranking command opens its own lazy overlay without opening Content")
    local tooltip = api.GameTooltip
    assert(not panel.header.scripts.OnEnter and not panel.header.scripts.OnLeave,
        "the overlay header has no tooltip handlers")
    command("options")
    local main = ranking.mainPanel
    assert(main:IsVisible() and panel:IsVisible(), "Settings and ranking can be visible independently")
    command("ranking")
    assert(not panel:IsShown() and not panel.scripts.OnUpdate and main:IsVisible() and not saved.ranking.enabled,
        "toggling ranking off saves its preference without closing Settings")
    command("ranking")
    assert(ranking.rankingOverlay == panel and panel:IsVisible() and main:IsVisible(),
        "reopening ranking reuses its window and leaves Settings visible")
    main.CloseButton:Click()
    assert(panel:IsVisible(), "closing the main window leaves the overlay visible")
    panel.CloseButton.scripts.OnEnter(panel.CloseButton)
    panel.CloseButton:Click()
    assert(not panel:IsShown() and not saved.ranking.enabled and not panel.scripts.OnUpdate and not tooltip:IsShown(),
        "the overlay close button saves disabled, stops refresh work and dismisses its help")
    ranking:Notify("ROSTER_CHANGED")
    ranking:Notify("DATA_CHANGED")
    ranking:Notify("GROUP_CHANGED")
    ranking:RefreshRankingOverlay()
    assert(not panel:IsShown() and not panel.scripts.OnUpdate,
        "status, connection and group events cannot reopen a dismissed overlay")
    command("ranking on")
    assert(panel:IsVisible() and saved.ranking.enabled and panel.header.mouseEnabled,
        "the explicit on command immediately shows ranking with its Shift-drag header available")
    command("ranking invalid")
    assert(saved.ranking.enabled and saved.ranking.locked and panel:IsVisible()
        and contains(messages, "Unknown command"), "invalid ranking arguments preserve visibility and saved preferences")
    command("ranking off")
    assert(not saved.ranking.enabled and not panel:IsShown(), "the explicit off command hides and persists ranking")
    assert(not contains(messages, SECRET) and not contains(messages, OTHER_SECRET),
        "ranking visibility never logs group keys")
end

-- Settings controls apply overlay preferences immediately without changing the active view.
do
    local saved = settings(SECRET, false)
    local ranking, api, _, _, world = loadAddon(saved, false)
    world:initialize()
    loadOverlay(ranking, api)
    ranking:OpenOptions("ranking")
    local options = ranking.optionsPanel
    assert(options.selectedTab == "ranking" and options.pages.ranking:IsVisible()
        and not options.rankingEnabled:GetChecked() and not options.rankingLocked
        and not ranking.rankingOverlay,
        "the Ranking Settings page exposes the default-off preference without a separate lock control")
    local tooltip = api.GameTooltip
    options.rankingInfo.scripts.OnEnter(options.rankingInfo)
    assert(not options.rankingHelp and tooltip:IsShown() and tooltip:IsOwned(options.rankingInfo)
        and tooltip.lines[1]:find("Awaiting XP: no usable level and XP report yet", 1, true)
        and tooltip.lines[1]:find("Stale / ~: last saved progress", 1, true)
        and tooltip.lines[1]:find("XP %: progress toward the next level", 1, true),
        "Ranking info explains values and missing reports without a permanent text block")
    options.tabs.group:Click()
    assert(not tooltip:IsShown(), "leaving Ranking dismisses its help without creating the overlay")
    options.tabs.ranking:Click()
    options.rankingEnabled.labelButton:Click()
    local panel = ranking.rankingOverlay
    assert(saved.ranking.enabled and options.rankingEnabled:GetChecked()
        and panel:IsVisible() and options:IsVisible() and options.selectedTab == "ranking",
        "enabling from Settings immediately saves and shows the independent overlay")
    assert(panel.header.mouseEnabled and not panel.lock,
        "enabling ranking makes Shift movement available without another control")
    panel.CloseButton.scripts.OnEnter(panel.CloseButton)
    assert(tooltip:IsOwned(panel.CloseButton) and tooltip.text == "Hide ranking"
        and tooltip.lines[1]:find("/lit ranking", 1, true), "close help explains how to reopen ranking")
    panel.CloseButton:Click()
    assert(not saved.ranking.enabled and not options.rankingEnabled:GetChecked() and options:IsVisible()
        and not tooltip:IsShown(),
        "closing ranking refreshes its visibility checkbox while retaining the Settings page")
    options.rankingInfo.scripts.OnEnter(options.rankingInfo)
    ranking.mainPanel.CloseButton:Click()
    assert(not tooltip:IsShown(), "closing Settings dismisses Ranking info")
end

-- Five pooled leaders and a separate local row preserve actual ranks and progress states.
do
    local ranking, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    loadOverlay(ranking, api)
    local own = row("Self", 6, 24, 250, 1000, true)
    local players = {
        row("Alpha", 1, 60), row("Bravo", 2, 25, 500, 1000),
        row("Charlie", 2, 25, 1, 2), row("Delta", 4, 24, 999, 1000),
        row("Echo", 5, 24, 500, 1000), own,
    }
    players[1].name, own.name = "Alpha-RemoteRealm", "Self-HomeRealm"
    local state = { players = players, own = own, connected = true, grouped = true,
        awaiting = 2, stale = 2, inactive = 4 }
    players[1].stale, players[4].stale = true, true
    ranking.GetPlayerRanking = function() return state end
    assert(ranking:SetRankingEnabled(true))
    local panel = ranking.rankingOverlay
    assert(#panel.rows == 5 and panel.rows[1].player == players[1] and panel.rows[5].player == players[5]
        and panel.rows[1].rank:GetText() == "1" and panel.rows[2].rank:GetText() == "2"
        and panel.rows[3].rank:GetText() == "2" and panel.rows[4].rank:GetText() == "4"
        and panel.ownRow:IsShown() and panel.ownRow.player == own and panel.ownRow.rank:GetText() == "6"
        and panel.separator:IsShown() and panel.ownRow.highlight:IsShown(),
        "the top five retain tie ranks and a lower local player has its actual rank in a highlighted separate row")
    assert(panel.rows[1].name:GetText() == "Alpha" and panel.ownRow.name:GetText() == "Self (you)"
        and players[1].name == "Alpha-RemoteRealm" and own.name == "Self-HomeRealm",
        "leader and separate local rows hide realms without changing their source names")
    assert(not panel.subtitle and not panel.columnHeaders and not panel.summary
        and panel.rows[1].point[3] == -34,
        "the first player starts directly beneath the title without headings, a subtitle or a count footer")
    local compactTop, compactHeight = panel.rows[1].point[3], panel:GetHeight()
    state.connected = false
    ranking:RefreshRankingOverlay()
    assert(panel.rows[1].point[3] == compactTop and panel:GetHeight() == compactHeight,
        "losing connection preserves the full-height player area without adding a notice above it")
    state.connected = true
    ranking:RefreshRankingOverlay()
    assert(panel.rows[1].point[3] == compactTop and panel:GetHeight() == compactHeight,
        "reconnecting preserves the compact row position and overlay height")
    assert(panel.rows[1].progress:GetText() == "~MAX" and panel.rows[1].progressTrack:IsShown()
        and panel.rows[1].progressFill:IsShown()
        and panel.rows[1].progressFill:GetWidth() == panel.rows[1].progressTrack:GetWidth()
        and panel.rows[2].progress:GetText() == "50%"
        and panel.rows[2].progressTrack:IsShown() and panel.rows[2].progressFill:IsShown()
        and panel.rows[4].progress:GetText() == "~99.9%",
        "maximum level is distinct and displayed percentages do not round near-level XP to 100 percent")
    assert(panel.rows[1].name:GetText() == "Alpha"
        and not panel.rows[1].status
        and panel.rows[1].alpha < 1
        and panel.rows[1].rank:GetText() == "1", "saved progress keeps its rank and stale styling without a status label")
    players[1].name = "Longcharactername-Longrealmname"
    ranking:RefreshRankingOverlay()
    assert(panel.rows[1].name:GetText() == "Longcharactername"
        and not panel.rows[1].status and panel.rows[1].progress:GetText() == "~MAX",
        "realm-free long names preserve the XP indicator without a separate stale label")
    local fullWidth = panel.rows[2].progressTrack:GetWidth()
    assert(math.abs(panel.rows[2].progressFill:GetWidth() - fullWidth * 0.5) < 0.000001,
        "the progress fill uses the exact fraction of its track")
    players[4].xp, players[4].xpMax = 9999, 10000
    ranking:RefreshRankingOverlay()
    assert(panel.rows[4].progress:GetText() == "~99.9%",
        "progress just below a full level never rounds to 100 percent")
    players[1], own.rank = own, 1
    state.players = { own }
    state.stale, state.awaiting = 0, 0
    ranking:Notify("ROSTER_CHANGED")
    assert(panel.rows[1].player == own and panel.rows[1].highlight:IsShown()
        and panel.rows[1].name:GetText() == "Self (you)"
        and panel.rows[1].alpha == 1 and not panel.rows[1].name:GetText():find("stale", 1, true)
        and not panel.rows[1].status
        and panel.rows[1].progress:GetText() == "25%"
        and not panel.ownRow:IsShown() and not panel.separator:IsShown()
        and not panel.ownRow.player and panel.ownRow.rank:GetText() == ""
        and not panel.ownRow.highlight:IsShown(),
        "a local leader is highlighted in place and clears its former separate pooled row")
    for index = 2, 5 do
        local unused = panel.rows[index]
        assert(not unused:IsShown() and not unused.player and unused.rank:GetText() == ""
            and unused.name:GetText() == "" and unused.level:GetText() == "" and unused.progress:GetText() == ""
            and not unused.status
            and not unused.progressTrack:IsShown() and not unused.progressFill:IsShown()
            and not unused.highlight:IsShown(),
            "unused pooled rows clear names, targets, ranks, progress and highlighting")
    end
    own.xp, own.xpMax, own.xpState, own.rank = nil, nil, "unavailable", nil
    state.players, state.awaiting, state.stale = {}, 1, 0
    ranking:RefreshRankingOverlay()
    assert(panel.ownRow:IsShown() and panel.ownRow.player == own
        and panel.ownRow.progress:GetText() == "Waiting for XP"
        and not panel.empty:IsShown() and not panel.separator:IsShown()
        and panel.ownRow.point[3] == panel.rows[1].point[3]
        and not panel.ownRow.rank:GetText():find("%d") and not panel.ownRow.progressTrack:IsShown(),
        "missing local XP uses the first row without duplicate empty messages or an invented rank")
    own.xp, own.xpMax, own.xpState = 250, 1000, "known"
    local cached = row("Cached", 1, 25, 500, 1000)
    cached.stale, cached.online, own.rank = true, false, 2
    state.players, state.stale, state.awaiting = { cached, own }, 1, 0
    state.connected = false
    ranking:Notify("DATA_CHANGED")
    assert(panel.rows[1].point[3] == -34 and panel.rows[1].player == cached and panel.rows[1].rank:GetText() == "1"
        and panel.rows[1].progress:GetText() == "~50%" and panel.rows[2].player == own
        and panel.rows[2].rank:GetText() == "2" and not panel.ownRow:IsShown()
        and panel.rows[2].progress:GetText() == "25%",
        "a lost connection retains saved peer ranks while local progress stays current")
    state.grouped, state.own = false, nil
    ranking:Notify("GROUP_CHANGED")
    assert(panel.empty:IsShown() and panel.empty:GetText():find("group", 1, true)
        and not panel.rows[1]:IsShown() and not panel.rows[1].player,
        "leaving the group clears all player rows while leaving the chosen overlay visible")
    assert(not panel.columnHeaders and panel.empty.point[3] == -38,
        "empty standings use the space immediately below the title without column headings")
end

-- Real roster events update local XP immediately; quiet peers keep their rank using stale progress.
do
    local ranking, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    world:completeJoin(ranking:GetGroupDataChannelName(), 7)
    loadOverlay(ranking, api)
    assert(ranking:ReceivePlayerStatus("Alpha-TestRealm", {
        level = 24, xp = 400, xpMax = 1000, xpState = "known",
    }, api.GetServerTime(), 1))
    local requests, originalRequest = 0, ranking.RequestData
    ranking.RequestData = function(self, feature, ...)
        requests = requests + 1
        return originalRequest(self, feature, ...)
    end
    assert(ranking:SetRankingEnabled(true))
    local panel = ranking.rankingOverlay
    assert(panel.rows[1].player.id == "alpha-testrealm" and panel.rows[2].player.isSelf
        and panel.rows[2].progress:GetText() == "0%" and panel.scripts.OnUpdate,
        "production roster data reaches the overlay without requiring Content")
    world.xp = 250
    world.fire("PLAYER_XP_UPDATE", "player")
    assert(panel.rows[2].progress:GetText() == "25%",
        "the real XP event refreshes local progress immediately without waiting for the UI tick")
    world.now = world.now + 90
    panel.scripts.OnUpdate(panel, 1)
    assert(panel.rows[1].player.id == "alpha-testrealm" and panel.rows[1].rank:GetText() == "1"
        and panel.rows[1].progress:GetText() == "~40%" and panel.rows[2].player.isSelf
        and panel.rows[1].alpha < 1 and not panel.rows[1].status and requests == 0,
        "contact expiry preserves peer ranks and stale styling without a label or another snapshot request")
    assert(ranking:ReceivePlayerStatus("Alpha-TestRealm", {
        level = 24, xp = 400, xpMax = 1000, xpState = "known",
    }, api.GetServerTime(), 2))
    assert(panel.rows[1].progress:GetText() == "40%" and panel.rows[1].alpha == 1
        and not panel.rows[1].name:GetText():find("stale", 1, true),
        "a fresh valid report clears the stale marker without changing equal progress")
    api.UIParent:Hide()
    assert(panel:IsShown() and not panel:IsVisible() and not panel.scripts.OnUpdate,
        "hiding the native interface stops overlay refresh work without changing its preference")
    api.UIParent:Show()
    assert(panel:IsVisible() and panel.scripts.OnUpdate and ranking:GetRankingSettings().enabled,
        "restoring the interface resumes refreshes for the enabled overlay")
    panel.CloseButton:Click()
    assert(not panel.scripts.OnUpdate and not ranking:GetRankingSettings().enabled,
        "explicitly closing removes the visible-only timer")
end

-- Hover details use the same permitted position data as the roster, and refresh
-- only while the pooled row still identifies the player under the pointer.
do
    local ranking, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    loadOverlay(ranking, api)
    ranking.db.position.sharing = true
    local own = row("Self", 6, 24, 250, 1000, true)
    local players = {
        row("Alpha", 1, 30, 420, 1000), row("Bravo", 2, 29, 175, 2000),
        row("Charlie", 3, 28), row("Delta", 4, 27, 50, 1000),
        row("Echo", 5, 26, 50, 1000), own,
    }
    players[1].name, own.name = "Alpha-RemoteRealm", "Self-HomeRealm"
    players[1].map, players[1].positionAvailable = 37, true
    players[1].seenAt, players[1].positionStamp = api.GetServerTime(), api.GetServerTime() - 300
    players[1].xpUpdatedAt = api.GetServerTime() - 30
    players[2].map, players[2].positionAvailable = 38, false
    players[2].stale, players[2].xpStale, players[2].online = true, true, false
    players[2].seenAt, players[2].xpUpdatedAt = api.GetServerTime() - 120, api.GetServerTime() - 150
    players[2].positionStamp = api.GetServerTime() - 300
    players[4].sharing, players[4].map = false, 37
    local lookups = {}
    api.C_Map.GetMapInfo = function(map)
        lookups[#lookups + 1] = map
        assert(map == 37 or map == 38, "hover must only resolve a map exposed by the roster")
        return { name = map == 37 and "Elwynn Forest" or "Westfall" }
    end
    local state = { players = players, own = own, connected = true, grouped = true }
    ranking.GetPlayerRanking = function() return state end
    assert(ranking:SetRankingEnabled(true))
    local panel, tooltip = ranking.rankingOverlay, api.GameTooltip
    local first = panel.rows[1]
    first.scripts.OnEnter(first)
    local text = tooltipText(tooltip)
    assert(tooltip:IsShown() and tooltip:IsOwned(first) and text:find("Alpha", 1, true)
        and tooltip.text == "Alpha — level 30" and not text:find("RemoteRealm", 1, true)
        and text:find("30", 1, true) and text:find("420", 1, true)
        and text:find("1000", 1, true) and text:find("580", 1, true)
        and text:find("Elwynn Forest", 1, true)
        and text:find("Contact: Active", 1, true)
        and not text:find("Location last reported", 1, true)
        and not text:find("XP value last updated", 1, true)
        and not text:find("Stale progress", 1, true),
        "hovering a leader shows exact progress, shared region and active contact without data-update labels")
    players[1].xp = 500
    ranking:RefreshRankingOverlay()
    text = tooltipText(tooltip)
    assert(tooltip:IsShown() and tooltip:IsOwned(first)
        and text:find("500", 1, true) and not text:find("420", 1, true)
        and not text:find("580", 1, true),
        "fresh progress for the same hovered identity updates exact XP and remaining XP")
    players[1].map = 38
    ranking:Notify("POSITIONS_CHANGED")
    assert(tooltip:IsShown() and tooltipText(tooltip):find("Westfall", 1, true)
        and not tooltipText(tooltip):find("Elwynn Forest", 1, true),
        "a shared position change updates details for the same hovered player")
    local beforeLocalOff = #lookups
    ranking.db.position.sharing = false
    ranking:RefreshRankingOverlay()
    assert(tooltipText(tooltip):find("Position sharing is off", 1, true) and #lookups == beforeLocalOff
        and not tooltipText(tooltip):find("Westfall", 1, true),
        "turning local position sharing off hides cached peer locations without another map lookup")
    ranking.db.position.sharing = true
    first.scripts.OnLeave(first)
    assert(not tooltip:IsShown(), "leaving a player dismisses their details")
    local stale = panel.rows[2]
    stale.scripts.OnEnter(stale)
    text = tooltipText(tooltip)
    assert(text:find("175", 1, true) and text:find("2000", 1, true)
        and text:find("1825", 1, true) and text:find("Westfall", 1, true)
        and text:find("Last contact: 2m ago", 1, true)
        and not text:find("Location last reported", 1, true)
        and not text:find("XP value last updated", 1, true)
        and not text:find("Stale progress", 1, true),
        "offline hover retains exact saved XP, region and last contact without data-update or stale labels")
    panel.rows[3].scripts.OnEnter(panel.rows[3])
    text = tooltipText(tooltip)
    assert(text:lower():find("maximum level", 1, true) and not text:find("To next level", 1, true),
        "maximum-level details do not invent an XP requirement")
    local beforePrivate = #lookups
    panel.rows[4].scripts.OnEnter(panel.rows[4])
    text = tooltipText(tooltip)
    assert(text:find("Not sharing", 1, true) and #lookups == beforePrivate
        and not text:find("Elwynn Forest", 1, true) and not text:find("Westfall", 1, true),
        "a player who does not share position has no map lookup or previously hovered location leak")
    panel.rows[5].scripts.OnEnter(panel.rows[5])
    assert(tooltipText(tooltip):find("No position", 1, true),
        "a missing position is distinguished from disabled position sharing")
    panel.ownRow.scripts.OnEnter(panel.ownRow)
    assert(tooltip:IsOwned(panel.ownRow) and tooltipText(tooltip):find("250", 1, true)
        and tooltipText(tooltip):find("750", 1, true)
        and tooltip.text == "Self — level 24" and not tooltipText(tooltip):find("HomeRealm", 1, true),
        "the separate local rank shows exact XP details with a realm-free player name")
    own.xp, own.xpMax, own.xpState, own.rank = nil, nil, "unavailable", nil
    state.players = { players[1], players[2], players[3], players[4], players[5] }
    ranking:RefreshRankingOverlay()
    text = tooltipText(tooltip)
    assert(tooltip:IsShown() and tooltip:IsOwned(panel.ownRow)
        and text:find("Awaiting XP", 1, true) and text:lower():find("report", 1, true)
        and not text:find("250", 1, true) and not text:find("750", 1, true),
        "missing progress explains awaiting XP without retaining the previous exact values")
    panel.ownRow.scripts.OnLeave(panel.ownRow)
    first.scripts.OnEnter(first)
    state.players[1], state.players[2] = state.players[2], state.players[1]
    ranking:RefreshRankingOverlay()
    assert(not tooltip:IsShown() and first.player.id == "Bravo",
        "reusing a pooled row for a new ranked player dismisses old hover details")
    first.scripts.OnEnter(first)
    state.players, state.own = {}, nil
    ranking:RefreshRankingOverlay()
    assert(not tooltip:IsShown() and not first:IsShown() and not first.player,
        "removing a hovered player clears the pooled row and its details")
end

-- Ranking shares the roster's guarded native party actions without constructing
-- Content. The selected identity is discarded whenever its row is reused.
do
    local saved = settings(SECRET, false)
    local ranking, api, messages, _, world = loadAddon(saved, false)
    local invites, requests, mayInvite, grouped = {}, {}, true, false
    local shiftDown = false
    api.IsShiftKeyDown = function() return shiftDown end
    api.IsInGroup = function() return grouped end
    api.C_PartyInfo = {
        CanInvite = function() return mayInvite end,
        IsPartyFull = function() return false end,
        InviteUnit = function(name) invites[#invites + 1] = name end,
        RequestInviteFromUnit = function(name) requests[#requests + 1] = name end,
    }
    world:initialize()
    world:completeJoin(ranking:GetGroupDataChannelName(), 7)
    for index, name in ipairs({ "Alpha", "Bravo", "Charlie", "Delta", "Echo" }) do
        assert(ranking:ReceivePlayerStatus(name .. "-TestRealm", {
            level = 30 - index, xp = 400, xpMax = 1000, xpState = "known",
            inParty = name == "Bravo", canInvite = true, partyFull = false, sharing = true,
        }, api.GetServerTime(), 1))
    end
    loadOverlay(ranking, api)
    assert(ranking:SetRankingEnabled(true))
    local panel, tooltip = ranking.rankingOverlay, api.GameTooltip
    assert(not panel.actionMenu and not ranking.mainPanel and not ranking.contentPanel,
        "showing ranking does not allocate an action menu or the main interface")
    local first = panel.rows[1]
    assert(first.name:GetText() == "Alpha" and first.player.name == "Alpha-TestRealm"
        and first.playerID == "alpha-testrealm",
        "ranking labels omit realms while action targets retain the complete player identity")
    first:Click()
    assert(not panel.actionMenu and #invites == 0 and #requests == 0,
        "left clicks do not invoke addon player actions")
    local function openMenu(entry)
        entry:Click("RightButton")
        local menu = panel.actionMenu
        assert(menu and menu:IsShown() and menu.playerID == entry.player.id and menu.anchor == entry,
            "right clicking a player opens the action list for that row's current identity")
        return menu
    end
    first.scripts.OnEnter(first)
    local menu = openMenu(first)
    assert(not tooltip:IsShown() and menu.invite:GetText() == "Invite"
        and menu.request:GetText() == "Request to join" and menu.invite:IsEnabled()
        and not menu.request:IsEnabled() and not ranking.mainPanel and not ranking.contentPanel,
        "right clicking dismisses hover details and offers the roster's actions independently of Content")
    menu.invite:Click()
    assert(#invites == 1 and invites[1] == "Alpha-TestRealm" and not menu:IsShown(),
        "the ranking invite uses the production permission check and complete player name")
    menu = openMenu(panel.rows[2])
    assert(not menu.invite:IsEnabled() and menu.request:IsEnabled(),
        "a grouped player offers a request to join instead of another invitation")
    menu.request:Click()
    assert(#requests == 1 and requests[1] == "Bravo-TestRealm" and not menu:IsShown(),
        "the ranking join item calls the real guarded native action")
    menu = openMenu(first)
    mayInvite = false
    menu.invite:Click()
    assert(#invites == 1 and not menu:IsShown(),
        "native invitation permission is checked again at action time")
    menu = openMenu(first)
    assert(not menu.invite:IsEnabled() and menu.invite.reason == "You cannot invite players right now.",
        "reopening the menu recalculates eligibility and its disabled reason")
    menu.invite.scripts.OnEnter(menu.invite)
    assert(tooltip:IsShown() and tooltip.text == menu.invite.reason,
        "disabled ranking actions explain their reason on hover")
    mayInvite = true
    ranking:RefreshRankingOverlay()
    assert(menu:IsShown() and menu.invite:IsEnabled(), "refreshing an open menu updates current action permissions")
    menu:Click()
    assert(not menu:IsShown() and not menu.playerID and not menu.anchor and not tooltip:IsShown(),
        "clicking outside the menu clears its selected identity and disabled-action tooltip")
    menu = openMenu(first)
    assert(menu.name and api[menu.name] == menu and contains(api.UISpecialFrames, menu.name),
        "the native Escape-dismiss list contains the ranking action menu")
    -- WoW's Escape handler hides the named special frame.
    api[menu.name]:Hide()
    assert(not menu:IsShown() and not menu.playerID and not menu.anchor,
        "native Escape dismissal clears menu targets")
    menu = openMenu(first)
    first:Click("RightButton")
    assert(not menu:IsShown(), "right clicking the same selected player toggles their action list closed")
    assert(panel.ownRow:IsShown() and panel.ownRow.player.isSelf,
        "a local player below the leaders still has an interactive separate row")
    menu = openMenu(panel.ownRow)
    assert(not menu.invite:IsEnabled() and not menu.request:IsEnabled()
        and menu.invite.reason == "This is your character.", "the local player's actions explain their disabled state")
    menu:Hide()
    menu = openMenu(first)
    first.scripts.OnEnter(first)
    assert(ranking:ReceivePlayerStatus("Bravo-TestRealm", {
        level = 31, xp = 400, xpMax = 1000, xpState = "known",
        inParty = true, canInvite = true, partyFull = false,
    }, api.GetServerTime(), 2))
    assert(first.player.id == "bravo-testrealm" and not menu:IsShown() and not tooltip:IsShown(),
        "a rank reorder closes menu and hover details before a row can target another player")
    -- Alpha is now the second leader. Contact expiry retains its rank but not permission.
    local alpha = panel.rows[2]
    menu = openMenu(alpha)
    world.now = world.now + 90
    panel.scripts.OnUpdate(panel, 1)
    assert(menu:IsShown() and not menu.invite:IsEnabled() and not menu.request:IsEnabled()
        and menu.invite.reason == "No recent contact with this player.",
        "offline players keep their ranking while current action eligibility becomes disabled")
    menu.invite.scripts.OnEnter(menu.invite)
    assert(tooltip.text == "No recent contact with this player.", "offline action help explains the stale contact")
    alpha.scripts.OnEnter(alpha)
    shiftDown = true
    panel.header.scripts.OnDragStart(panel.header, "LeftButton")
    assert(not menu:IsShown() and not tooltip:IsShown(), "moving the overlay clears action menus and hover details")
    panel.header.scripts.OnDragStop(panel.header)
    shiftDown = false
    menu = openMenu(alpha)
    alpha.scripts.OnEnter(alpha)
    api.UIParent:Hide()
    assert(not menu:IsShown() and not tooltip:IsShown(), "hiding the native interface dismisses ranking interactions")
    api.UIParent:Show()
    menu = openMenu(alpha)
    alpha.scripts.OnEnter(alpha)
    panel.CloseButton:Click()
    assert(not menu:IsShown() and not tooltip:IsShown(), "closing ranking dismisses its menu and player details")
    assert(ranking:SetRankingEnabled(true))
    menu = openMenu(panel.rows[2])
    panel.rows[2].scripts.OnEnter(panel.rows[2])
    shiftDown = true
    panel.rows[2].scripts.OnDragStart(panel.rows[2], "LeftButton")
    panel:SetPoint("TOPLEFT", api.UIParent, "TOPLEFT", 145, -75)
    assert(panel.moving and panel.dragHandle == panel.rows[2], "a player row owns its active Shift drag")
    assert(ranking:LeaveGroup())
    assert(not menu:IsShown() and not tooltip:IsShown() and not panel.rows[1]:IsShown()
        and not panel.moving and not panel.dragHandle
        and saved.ranking.position.point == "TOPLEFT" and saved.ranking.position.x == 145
        and saved.ranking.position.y == -75,
        "removing a dragged player after a group change stops and saves movement and clears old interactions")
    assert(not contains(messages, SECRET) and not contains(messages, OTHER_SECRET),
        "ranking action feedback never logs group credentials")
end

-- Shift movement saves account-wide placement without disabling player interaction.
do
    local saved = settings(SECRET, false)
    saved.ranking = { enabled = true, locked = true,
        position = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 140, y = -90, future = "keep" } }
    local ranking, api, _, _, world = loadAddon(saved, false)
    local shiftDown = false
    api.IsShiftKeyDown = function() return shiftDown end
    loadOverlay(ranking, api)
    assert(not ranking.rankingOverlay, "saved visibility waits for initialization and login")
    world:initialize()
    local panel = ranking.rankingOverlay
    assert(panel and panel:IsVisible() and placed(panel, api.UIParent, "TOPLEFT", "TOPLEFT", 140, -90)
        and panel.userPlaced == false and panel.mouseEnabled == false and panel.header.mouseEnabled
        and not panel.scripts.OnDragStart and not panel.scripts.OnDragStop,
        "login restores saved placement and enables Shift movement even with a legacy locked preference")
    for _, entry in ipairs(panel.rows) do
        assert(entry.frameType == "Button" and entry.mouseEnabled and entry.clicks[1] == "RightButtonUp"
            and #entry.clicks == 1 and entry.drags[1] == "LeftButton",
            "ranking rows reserve right clicks while allowing Shift-left-drag and hover details")
    end
    local originalPosition = saved.ranking.position
    panel.header.scripts.OnDragStart(panel.header, "LeftButton")
    panel.header.scripts.OnDragStop(panel.header)
    assert(not panel.moving and saved.ranking.position == originalPosition and originalPosition.x == 140,
        "a drag without Shift neither moves the overlay nor changes its saved placement")
    shiftDown = true
    panel.header.scripts.OnDragStart(panel.header, "RightButton")
    assert(not panel.moving, "Shift-right-drag does not move the overlay")
    panel.CloseButton.scripts.OnEnter(panel.CloseButton)
    panel.header.scripts.OnDragStart(panel.header, "LeftButton")
    assert(panel.moving and not api.GameTooltip:IsShown(), "Shift-dragging the header moves the overlay and clears visible help")
    panel:SetPoint("BOTTOMRIGHT", api.UIParent, "BOTTOMRIGHT", -120, 65)
    panel.header.scripts.OnDragStop(panel.header)
    local position = saved.ranking.position
    assert(position.point == "BOTTOMRIGHT" and position.relativePoint == "BOTTOMRIGHT"
        and position.x == -120 and position.y == 65 and position.future == "keep"
        and not position.relativeTo and not panel.moving and panel.userPlaced == false,
        "drag stop saves only an anchor and offsets while preserving unknown position fields")
    shiftDown = false
    panel.header.scripts.OnDragStart(panel.header, "LeftButton")
    assert(saved.ranking.locked and not panel.moving and panel.header.mouseEnabled,
        "releasing Shift immediately prevents the next drag without changing legacy settings")
    shiftDown = true
    panel.rows[1].scripts.OnDragStart(panel.rows[1], "LeftButton")
    assert(panel.moving, "Shift-dragging a player row moves the same overlay")
    panel.rows[1].scripts.OnDragStop(panel.rows[1])
    assert(not panel.moving and saved.ranking.locked, "row drag stop saves placement without rewriting the legacy lock field")
    local restored, restoredAPI, _, _, restoredWorld = loadAddon(saved, false)
    restoredWorld:initialize()
    assert(not restored.rankingOverlay, "login without widget support safely defers overlay creation")
    loadOverlay(restored, restoredAPI)
    restored:RefreshRankingOverlay()
    assert(restored.rankingOverlay:IsVisible()
        and placed(restored.rankingOverlay, restoredAPI.UIParent, "BOTTOMRIGHT", "BOTTOMRIGHT", -120, 65),
        "an enabled overlay created after login restores its saved account-wide position")
end

-- Malformed anchors use a usable default; future-schema settings remain untouched.
do
    local damaged = settings(SECRET, false)
    damaged.ranking = { enabled = true, locked = false,
        position = { point = "BAD", relativePoint = "CENTER", x = 0 / 0, y = 4 } }
    local ranking, api, _, _, world = loadAddon(damaged, false)
    loadOverlay(ranking, api)
    world:initialize()
    local panel = ranking.rankingOverlay
    local point, owner, relative, x, y = panel:GetPoint()
    assert(owner == api.UIParent and point ~= "BAD" and relative ~= "BAD"
        and type(x) == "number" and x == x and type(y) == "number" and y == y,
        "damaged saved placement falls back to a valid finite native anchor")
    local future = settings(SECRET, false)
    future.schemaVersion = 99
    future.ranking = { enabled = true, locked = false,
        position = { point = "TOPRIGHT", relativePoint = "TOPRIGHT", x = -80, y = -70 }, future = "keep" }
    local originalPosition = future.ranking.position
    local readonly, readonlyAPI, _, _, readonlyWorld = loadAddon(future, false)
    readonlyAPI.IsShiftKeyDown = function() return true end
    loadOverlay(readonly, readonlyAPI)
    readonlyWorld:initialize()
    local readonlyPanel = readonly.rankingOverlay
    assert(readonly.savedDataReadOnly and readonlyPanel:IsVisible() and readonlyPanel.header.mouseEnabled
        and not readonlyPanel.lock and readonlyPanel.CloseButton:IsEnabled(),
        "a future-schema profile permits viewing, temporary Shift movement and closing")
    -- A future profile intentionally has no active group. Exercise a stale row
    -- callback against the production action guard without reading its schema.
    local readonlyPlayer = row("Future", 1, 24, 200, 1000)
    readonly.GetPlayerRanking = function()
        return { players = { readonlyPlayer }, connected = false, grouped = true }
    end
    readonly:RefreshRankingOverlay()
    readonlyPanel.rows[1]:Click("RightButton")
    local readonlyMenu = readonlyPanel.actionMenu
    assert(readonlyMenu and readonlyMenu:IsShown(), "future-schema profiles permit viewing the action list")
    assert(not readonlyMenu.invite:IsEnabled() and not readonlyMenu.request:IsEnabled(),
        "read-only ranking party actions remain unavailable")
    assert(readonlyMenu.invite.reason == "Join a writable LockInTools group after login first.",
        "read-only ranking actions use the roster's disabled explanation: " .. tostring(readonlyMenu.invite.reason))
    readonlyMenu:Hide()
    readonlyPanel.CloseButton.scripts.OnEnter(readonlyPanel.CloseButton)
    assert(readonlyAPI.GameTooltip.lines[1]:find("for this session", 1, true)
        and readonlyAPI.GameTooltip.lines[1]:find("/lit ranking", 1, true)
        and not readonlyAPI.GameTooltip.lines[1]:find("Settings", 1, true),
        "read-only close help points to the available session command")
    readonly:OpenOptions("ranking")
    assert(not readonly.optionsPanel.rankingEnabled:IsEnabled() and not readonly.optionsPanel.rankingLocked,
        "future-schema Ranking Settings cannot change saved visibility and have no lock preference")
    readonly.optionsPanel.rankingInfo.scripts.OnEnter(readonly.optionsPanel.rankingInfo)
    assert(readonly.optionsPanel.rankingInfo:IsEnabled() and readonlyAPI.GameTooltip:IsShown(),
        "read-only settings keep ranking explanations available")
    readonlyPanel.header.scripts.OnDragStart(readonlyPanel.header, "LeftButton")
    assert(readonlyPanel.moving, "Shift movement remains available for a read-only profile")
    readonlyPanel:SetPoint("CENTER", readonlyAPI.UIParent, "CENTER", 20, 30)
    readonlyPanel.header.scripts.OnDragStop(readonlyPanel.header)
    readonlyPanel.CloseButton:Click()
    readonly:Notify("ROSTER_CHANGED")
    readonly:Notify("DATA_CHANGED")
    assert(not readonlyPanel:IsShown() and not readonlyPanel.scripts.OnUpdate
        and future.ranking.enabled and future.ranking.locked == false and future.ranking.future == "keep"
        and future.ranking.position == originalPosition and originalPosition.x == -80 and originalPosition.y == -70
        and future.schemaVersion == 99,
        "read-only movement and session dismissal never write settings or allow notifications to reopen the overlay")
    local command = readonlyAPI.SlashCmdList.LOCKINTOOLS
    command("ranking on")
    assert(readonlyPanel:IsVisible()
        and placed(readonlyPanel, readonlyAPI.UIParent, "CENTER", "CENTER", 20, 30),
        "a read-only saved overlay can reopen for the session at its temporary position")
    command("ranking off")
    readonly:Notify("RANKING_CHANGED")
    assert(not readonlyPanel:IsShown() and future.ranking.enabled,
        "explicit read-only off stays dismissed without rewriting saved visibility")
    command("ranking")
    assert(readonlyPanel:IsVisible() and future.ranking.enabled and future.schemaVersion == 99,
        "the read-only toggle reopens the session overlay while preserving the future profile")
end

-- Ranking retains native colors and fonts while fitting independently of the main window.
do
    local ranking, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    loadOverlay(ranking, api)
    assert(not ranking.rankingOverlay, "native styling preserves lazy ranking creation")
    api.UIParent:SetSize(300, 250)
    local own = row("Self", 1, 24, 250, 1000, true)
    ranking.GetPlayerRanking = function() return { players = { own }, own = own, connected = true, grouped = true } end
    assert(ranking:SetRankingEnabled(true))
    local panel = ranking.rankingOverlay
    assert(panel.TitleText.font[1] == "Fonts\\FRIZQT__.TTF"
        and panel.scale > 0 and panel.scale < 1
        and panel:GetWidth() * panel.scale <= api.UIParent:GetWidth()
        and panel:GetHeight() * panel.scale <= api.UIParent:GetHeight(),
        "the overlay keeps its native font and fits a small viewport independently")
    local accent = panel.rows[1].progressFill.textureColor
    assert(accent[1] == 0.27 and accent[2] == 0.65 and accent[3] == 1
        and panel.rows[1].progress:GetText() == "25%",
        "ranking progress uses the fixed native blue accent")
    api.UIParent:SetSize(1920, 1080)
    ranking:RefreshRankingOverlay()
    assert(panel.scale == 1 and ranking.rankingOverlay == panel,
        "the native overlay restores normal scale on a larger viewport without recreating its window")
end

assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep ranking test environments isolated")
print("PASS: Player ranking overlay visibility, rendering, hover details, actions, updates and placement")
