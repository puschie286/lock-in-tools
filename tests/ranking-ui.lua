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
        and panel.TitleText:GetText() == "Player ranking" and panel.subtitle:GetText():find("Connection lost", 1, true),
        "the ranking command opens its own lazy overlay without opening Content")
    local tooltip = api.GameTooltip
    panel.help.scripts.OnEnter(panel.help)
    assert(tooltip:IsShown() and tooltip:IsOwned(panel.help) and tooltip.text == "Ranking values"
        and tooltip.lines[1]:find("Rank: higher level first", 1, true)
        and tooltip.lines[1]:find("MAX: confirmed maximum level", 1, true)
        and tooltip.lines[1]:find("Stale / ~: last saved progress", 1, true)
        and tooltip.lines[1]:find("Awaiting XP: no usable level and XP report yet", 1, true)
        and tooltip.lines[1]:find("older saved data or a level-up", 1, true),
        "the Info tooltip explains ranks, percentage, maximum level, stale values and missing XP reports")
    panel.help.scripts.OnLeave(panel.help)
    assert(not tooltip:IsShown(), "leaving Info dismisses its explanation")
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
    panel.help:Click()
    assert(tooltip:IsShown() and tooltip:IsOwned(panel.help), "Info also opens its explanation on click")
    panel.CloseButton:Click()
    assert(not panel:IsShown() and not saved.ranking.enabled and not panel.scripts.OnUpdate and not tooltip:IsShown(),
        "the overlay close button saves disabled, stops refresh work and dismisses its Info tooltip")
    ranking:Notify("ROSTER_CHANGED")
    ranking:Notify("DATA_CHANGED")
    ranking:Notify("GROUP_CHANGED")
    ranking:RefreshRankingOverlay()
    assert(not panel:IsShown() and not panel.scripts.OnUpdate,
        "status, connection and group events cannot reopen a dismissed overlay")
    command("ranking on")
    command("ranking unlock")
    assert(panel:IsVisible() and saved.ranking.enabled and not saved.ranking.locked
        and panel.header.mouseEnabled, "explicit on and unlock commands immediately show and unlock ranking")
    command("ranking lock")
    assert(saved.ranking.locked and not panel.header.mouseEnabled,
        "the explicit lock command immediately prevents header movement")
    command("ranking invalid")
    assert(saved.ranking.enabled and saved.ranking.locked and panel:IsVisible()
        and contains(messages, "Unknown command"), "invalid ranking arguments preserve visibility and placement controls")
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
        and not options.rankingEnabled:GetChecked() and options.rankingLocked:GetChecked()
        and not ranking.rankingOverlay,
        "the Ranking Settings page exposes the default-off and default-locked preferences lazily")
    assert(options.rankingHelp:GetText():find("Awaiting XP: no usable level and XP report yet", 1, true)
        and options.rankingHelp:GetText():find("Stale / ~: last saved progress", 1, true)
        and options.rankingHelp:GetText():find("XP %: progress toward the next level", 1, true),
        "Settings visibly explains the ranking values and why a character may have no rank")
    options.rankingEnabled:Click()
    local panel = ranking.rankingOverlay
    assert(saved.ranking.enabled and options.rankingEnabled:GetChecked()
        and panel:IsVisible() and options:IsVisible() and options.selectedTab == "ranking",
        "enabling from Settings immediately saves and shows the independent overlay")
    options.rankingLocked:Click()
    assert(not saved.ranking.locked and not options.rankingLocked:GetChecked()
        and panel.header.mouseEnabled and panel.lock:GetText() == "Lock",
        "the Settings lock preference immediately updates the overlay header")
    panel.lock:Click()
    assert(saved.ranking.locked and options.rankingLocked:GetChecked(),
        "locking within the overlay immediately refreshes its Settings checkbox")
    panel.CloseButton:Click()
    assert(not saved.ranking.enabled and not options.rankingEnabled:GetChecked() and options:IsVisible(),
        "closing ranking refreshes its visibility checkbox while retaining the Settings page")
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
    assert(panel.subtitle:GetText() == "Last reported standings"
        and panel.summary:GetText():find("6 ranked", 1, true)
        and panel.summary:GetText():find("2 awaiting", 1, true)
        and panel.summary:GetText():find("2 stale", 1, true),
        "the overlay labels last reported standings and separates ranked stale values from missing XP")
    assert(panel.rows[1].progress:GetText() == "~MAX" and panel.rows[1].progressTrack:IsShown()
        and panel.rows[1].progressFill:IsShown()
        and panel.rows[1].progressFill:GetWidth() == panel.rows[1].progressTrack:GetWidth()
        and panel.rows[2].progress:GetText() == "50%"
        and panel.rows[2].progressTrack:IsShown() and panel.rows[2].progressFill:IsShown()
        and panel.rows[4].progress:GetText() == "~99.9%",
        "maximum level is distinct and displayed percentages do not round near-level XP to 100 percent")
    assert(panel.rows[1].name:GetText():find("(stale)", 1, true) and panel.rows[1].alpha < 1
        and panel.rows[1].rank:GetText() == "1", "saved stale progress keeps its rank with visible stale markers")
    local fullWidth = panel.rows[2].progressTrack:GetWidth()
    assert(math.abs(panel.rows[2].progressFill:GetWidth() - fullWidth * 0.5) < 0.000001,
        "the progress fill uses the exact fraction of its track")
    players[4].xp, players[4].xpMax = 9999, 10000
    ranking:RefreshRankingOverlay()
    assert(panel.rows[4].progress:GetText() == "~99.9%",
        "progress just below a full level never rounds to 100 percent")
    players[1], own.rank = own, 1
    state.players = { own }
    ranking:Notify("ROSTER_CHANGED")
    assert(panel.rows[1].player == own and panel.rows[1].highlight:IsShown()
        and panel.rows[1].alpha == 1 and not panel.rows[1].name:GetText():find("stale", 1, true)
        and panel.rows[1].progress:GetText() == "25%"
        and not panel.ownRow:IsShown() and not panel.separator:IsShown()
        and not panel.ownRow.player and panel.ownRow.rank:GetText() == ""
        and not panel.ownRow.highlight:IsShown(),
        "a local leader is highlighted in place and clears its former separate pooled row")
    for index = 2, 5 do
        local unused = panel.rows[index]
        assert(not unused:IsShown() and not unused.player and unused.rank:GetText() == ""
            and unused.name:GetText() == "" and unused.level:GetText() == "" and unused.progress:GetText() == ""
            and not unused.progressTrack:IsShown() and not unused.progressFill:IsShown()
            and not unused.highlight:IsShown(),
            "unused pooled rows clear names, targets, ranks, progress and highlighting")
    end
    own.xp, own.xpMax, own.xpState, own.rank = nil, nil, "unavailable", nil
    state.players, state.awaiting, state.stale = {}, 1, 0
    ranking:RefreshRankingOverlay()
    assert(panel.ownRow:IsShown() and panel.ownRow.player == own
        and panel.ownRow.progress:GetText() == "Waiting for XP"
        and not panel.ownRow.rank:GetText():find("%d") and not panel.ownRow.progressTrack:IsShown(),
        "missing local XP shows Waiting for XP without inventing a numeric rank or zero progress")
    own.xp, own.xpMax, own.xpState = 250, 1000, "known"
    local cached = row("Cached", 1, 25, 500, 1000)
    cached.stale, cached.online, own.rank = true, false, 2
    state.players, state.stale, state.awaiting = { cached, own }, 1, 0
    state.connected = false
    ranking:Notify("DATA_CHANGED")
    assert(panel.subtitle:GetText() == "Connection lost — showing last reports"
        and panel.rows[1].player == cached and panel.rows[1].rank:GetText() == "1"
        and panel.rows[1].progress:GetText() == "~50%" and panel.rows[2].player == own
        and panel.rows[2].rank:GetText() == "2" and not panel.ownRow:IsShown()
        and panel.rows[2].progress:GetText() == "25%",
        "a lost connection retains saved peer ranks while local progress stays current")
    state.grouped, state.own = false, nil
    ranking:Notify("GROUP_CHANGED")
    assert(panel.empty:IsShown() and panel.empty:GetText():find("group", 1, true)
        and not panel.rows[1]:IsShown() and not panel.rows[1].player,
        "leaving the group clears all player rows while leaving the chosen overlay visible")
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
        and panel.summary:GetText():find("1 stale", 1, true) and requests == 0,
        "contact expiry preserves peer ranks and marks the last progress stale without another snapshot request")
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

-- Header movement saves account-wide placement; locked rows allow clicks through.
do
    local saved = settings(SECRET, false)
    saved.ranking = { enabled = true, locked = true,
        position = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 140, y = -90, future = "keep" } }
    local ranking, api, _, _, world = loadAddon(saved, false)
    loadOverlay(ranking, api)
    assert(not ranking.rankingOverlay, "saved visibility waits for initialization and login")
    world:initialize()
    local panel = ranking.rankingOverlay
    assert(panel and panel:IsVisible() and placed(panel, api.UIParent, "TOPLEFT", "TOPLEFT", 140, -90)
        and panel.userPlaced == false and panel.mouseEnabled == false and panel.header.mouseEnabled == false
        and not panel.scripts.OnDragStart and not panel.scripts.OnDragStop,
        "login restores saved visibility and placement with only the locked header reserving drag behavior")
    for _, entry in ipairs(panel.rows) do assert(entry.mouseEnabled == false, "ranking rows let clicks pass through") end
    panel.lock:Click()
    assert(not saved.ranking.locked and panel.header.mouseEnabled and panel.lock:GetText() == "Lock",
        "the lock control enables header-only dragging and saves its account preference")
    panel.header.scripts.OnDragStart(panel.header)
    assert(panel.moving, "dragging the unlocked header moves the overlay")
    panel:SetPoint("BOTTOMRIGHT", api.UIParent, "BOTTOMRIGHT", -120, 65)
    panel.header.scripts.OnDragStop(panel.header)
    local position = saved.ranking.position
    assert(position.point == "BOTTOMRIGHT" and position.relativePoint == "BOTTOMRIGHT"
        and position.x == -120 and position.y == 65 and position.future == "keep"
        and not position.relativeTo and not panel.moving and panel.userPlaced == false,
        "drag stop saves only an anchor and offsets while preserving unknown position fields")
    panel.lock:Click()
    panel.header.scripts.OnDragStart(panel.header)
    assert(saved.ranking.locked and not panel.moving and not panel.header.mouseEnabled,
        "a stale header callback cannot move the overlay after it is locked")
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
    loadOverlay(readonly, readonlyAPI)
    readonlyWorld:initialize()
    local readonlyPanel = readonly.rankingOverlay
    assert(readonly.savedDataReadOnly and readonlyPanel:IsVisible() and not readonlyPanel.lock:IsEnabled()
        and readonlyPanel.CloseButton:IsEnabled(),
        "a future-schema profile still permits viewing and closing while preference controls are disabled")
    readonly:OpenOptions("ranking")
    assert(not readonly.optionsPanel.rankingEnabled:IsEnabled()
        and not readonly.optionsPanel.rankingLocked:IsEnabled(),
        "future-schema Ranking Settings controls cannot change saved preferences")
    readonlyPanel:SetPoint("CENTER", readonlyAPI.UIParent, "CENTER", 20, 30)
    readonly:SaveRankingPosition()
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
    command("ranking lock")
    command("ranking unlock")
    assert(future.ranking.locked == false and readonly:GetRankingSettings().locked == false,
        "read-only slash commands cannot save or silently change the lock preference")
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
print("PASS: Player ranking overlay visibility, rendering, updates, placement and styling")
