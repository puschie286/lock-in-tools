local support = dofile("tests/support/addon.lua")
local loadOptions = dofile("tests/support/ui.lua")

local function Fixture(state)
    local addon, environment, _, _, world = support.loadAddon(support.settings(support.SECRET, false), false)
    world:initialize()
    local calls = { update = 0, imports = {}, selections = {} }
    function addon:GetRestedXPState() return state end
    function addon:GetRestedXPBattleTag() return "Local#1234" end
    function addon:UpdateRestedXPGuides()
        calls.update = calls.update + 1
        if calls.updateError then return false, calls.updateError end
        return true
    end
    function addon:SelectRestedXPPublisher(source)
        calls.selections[#calls.selections + 1] = source
        if calls.selectionError then return false, calls.selectionError end
        return true
    end
    function addon:ImportRestedXPPack(id, raw, source)
        calls.imports[#calls.imports + 1] = { id, raw, source }
        if calls.importError then return false, calls.importError end
        return true
    end
    loadOptions(addon, environment)
    addon:OpenOptions("restedxp")
    return addon, addon.optionsPanel, calls, environment
end

local function Details(panel, environment)
    panel.restedxpSummary.scripts.OnEnter(panel.restedxpSummary)
    local tooltip = environment.GameTooltip
    assert(tooltip.shown and tooltip.owner == panel.restedxpSummary, "guide details belong to the summary")
    return table.concat(tooltip.lines, "\n")
end

do
    local state = { installed = false, loaded = false, canUpdate = false, guides = {}, packs = {},
        publishers = {}, guideStatus = "Not installed" }
    local addon, panel, calls, environment = Fixture(state)
    assert(panel.selectedTab == "restedxp" and panel.pages.restedxp:IsVisible()
        and panel.restedxpStatus:GetText() == "Not installed",
        "RestedXP has an accessible Settings tab with explicit installation status")
    assert(not panel.restedxpUpdate:IsEnabled() and not panel.restedxpGuides
        and panel.restedxpPublishers.empty:IsShown(), "one summary replaces the individual installed guide list")
    assert(panel.restedxpPublishers.empty:GetText():find("shared automatically", 1, true),
        "empty availability explains automatic sharing without requiring a manual first export")
    assert(panel.tabs.restedxp.point[2] + panel.tabs.restedxp:GetWidth() <= 700,
        "all Settings tabs fit inside the existing window")
    state.installed, state.version, state.guideStatus = true, "4.9.1", "Not loaded"
    addon:Notify("RESTEDXP_CHANGED")
    assert(panel.restedxpStatus:GetText() == "Not loaded" and Details(panel, environment):find("4.9.1", 1, true),
        "installation stays concise and the addon version is available on hover")
    state.loaded, state.canUpdate = true, true
    state.sharingStatus = "Automatically sharing 9 imported guides."
    state.sharedInstalledGuides, state.unshareableGuides = 9, 0
    state.guides = {}
    for index = 1, 9 do
        state.guides[index] = { name = "Guide " .. index, group = "Test group", version = index, key = "guide" .. index }
    end
    state.packs = {
        { id = "test", label = "Test pack", source = "Alice-Realm", hash = "12345678fullhash", updateAvailable = true },
        { id = "second", source = "Alice-Realm", hash = "anotherhash", updateAvailable = true },
    }
    state.publishers = {
        { source = "Alice-Realm", status = "Available", canFollow = true, packCount = 2 },
        { source = "Bob-Realm", status = "Up to date", canFollow = true, selected = true },
        { source = "Carol-Realm", status = "Available", canFollow = true },
        { source = "Dana-Realm", status = "Available", canFollow = true },
        { source = "Local-Realm", status = "Shared", localPack = true, canFollow = false },
        { source = "Offline-Realm", status = "Publisher offline", canFollow = false },
    }
    state.guideStatus = "Updates available"
    addon:Notify("RESTEDXP_CHANGED")
    assert(panel.restedxpUpdate:IsEnabled()
        and panel.restedxpStatus:GetText() == "Updates available"
        and panel.restedxpPublishers.scrollbar:IsShown(), "one status covers the installed guides and publishers have a bounded list")
    local details = Details(panel, environment)
    assert(details:find("9 installed guides", 1, true) and details:find(state.sharingStatus, 1, true)
        and not details:find("Guide 1", 1, true), "counts and sharing details stay available without listing individual guides")
    assert(panel.restedxpPublishers.rows[1].name:GetText() == "Alice-Realm"
        and panel.restedxpPublishers.rows[1].detail:GetText() == "Available",
        "publisher rows show a player and a single status instead of pack names and hashes")
    state.refreshingInstalled = true
    state.busy, state.status = false, "Choose Follow beside a publisher, then use Update guides."
    state.sharingStatus = "Refreshing automatically shared guides..."
    addon:Notify("RESTEDXP_CHANGED")
    assert(Details(panel, environment):find(state.sharingStatus, 1, true)
        and Details(panel, environment):find("Choose Follow", 1, true)
        and panel.restedxpUpdate:IsEnabled() and panel.restedxpPublishers.rows[1].follow:IsEnabled(),
        "background source preparation leaves Update and Follow available while details remain accessible")
    state.busy, state.status, state.guideStatus = true, "Checking available group guides...", "Checking"
    addon:Notify("RESTEDXP_CHANGED")
    assert(not panel.restedxpUpdate:IsEnabled() and not panel.restedxpPublishers.rows[1].follow:IsEnabled()
        and panel.restedxpStatus:GetText() == "Checking",
        "foreground discovery temporarily disables actions independently of background source preparation")
    state.busy, state.status = false, nil
    state.refreshingInstalled = false
    state.sharedInstalledGuides, state.unshareableGuides = 8, 1
    state.sharingStatus = "Automatically sharing 8 guides. Complete source is unavailable for 1 guide."
    addon:Notify("RESTEDXP_CHANGED")
    assert(Details(panel, environment):find(state.sharingStatus, 1, true),
        "sharing limitations remain accessible in the status details")
    local publisherRow = panel.restedxpPublishers.rows[1]
    publisherRow.follow:Click()
    assert(#calls.selections == 1 and calls.selections[1] == "Alice-Realm",
        "Follow selects the player once for all their available guides")
    calls.selectionError = "Refresh guides to find this source again."
    publisherRow.follow:Click()
    assert(panel.feedback:GetText() == calls.selectionError, "expired publisher selections explain how to retry")
    calls.selectionError = nil
    assert(not panel.restedxpPublishers.rows[2].follow:IsEnabled()
        and panel.restedxpPublishers.rows[2].follow:GetText() == "Following", "the existing subscription is visible")
    publisherRow.follow.scripts.OnEnter(publisherRow.follow)
    panel.restedxpPublishers.scripts.OnMouseWheel(panel.restedxpPublishers, -100)
    assert(panel.restedxpPublishers.offset == 2 and not environment.GameTooltip.shown,
        "publisher scrolling clamps at the last player and clears tooltips for recycled rows")
    assert(panel.restedxpPublishers.rows[3].name:GetText() == "Local-Realm (you)"
        and not panel.restedxpPublishers.rows[3].follow:IsEnabled()
        and panel.restedxpPublishers.rows[3].follow:GetText() == "Shared",
        "locally published guides have one player row without a self-follow action")
    assert(panel.restedxpPublishers.rows[4].publisher.source == "Offline-Realm"
        and not panel.restedxpPublishers.rows[4].follow:IsEnabled()
        and panel.restedxpPublishers.rows[4].follow:GetText() == "Offline",
        "offline sources cannot be newly followed")
    panel.restedxpPublishers.scrollbar:SetValue(0)
    state.publishers[1].status = "Partly followed"
    addon:Notify("RESTEDXP_CHANGED")
    assert(panel.restedxpPublishers.rows[1].follow:IsEnabled()
        and panel.restedxpPublishers.rows[1].detail:GetText() == "Partly followed",
        "a partial subscription lets Follow select the rest of a publisher's guides")
    panel.restedxpUpdate:Click()
    assert(calls.update == 1, "Update guides triggers feature discovery and updates exactly once")
    assert(panel.feedback:GetText() == "", "accepted updates use live feature status without a permanent footer message")
    state.busy, state.status, state.guideStatus = true, "Downloading test pack (50%).", "Updating (50%)"
    addon:Notify("RESTEDXP_CHANGED")
    assert(not panel.restedxpUpdate:IsEnabled() and not panel.restedxpShare:IsEnabled()
        and panel.restedxpStatus:GetText() == "Updating (50%)", "in-progress work updates the single status and prevents duplicate actions")
    state.busy, state.status, state.guideStatus = false, "All followed guides are up to date.", "Up to date"
    addon:Notify("RESTEDXP_CHANGED")
    assert(panel.feedback:GetText() == "" and panel.restedxpUpdate:IsEnabled()
        and panel.restedxpStatus:GetText() == "Up to date",
        "completed updates display their result without stale checking feedback")
    calls.updateError = "Connect to your LIT group to check for updates."
    panel.restedxpUpdate:Click()
    assert(panel.feedback:GetText() == calls.updateError, "rejected updates retain the actionable footer error")
    calls.updateError = nil
    panel.restedxpUpdate:Click()
    assert(panel.feedback:GetText() == "", "an accepted retry clears an earlier update error")
    state.status = "Downloading test pack (50%)."
    state.busy, state.installationProblem = false, "The RestedXP importer is unavailable."
    state.guideStatus = "Unavailable"
    addon:Notify("RESTEDXP_CHANGED")
    assert(panel.restedxpStatus:GetText() == "Unavailable"
        and Details(panel, environment):find("importer is unavailable", 1, true), "compatibility problems have a concise status and detailed guidance")
    assert(Details(panel, environment):find("50%", 1, true), "compatibility guidance preserves transfer details")
    panel.tabs.chat:Click()
    assert(not environment.GameTooltip.shown, "leaving RestedXP dismisses the status details")
end

do
    local state = { installed = true, loaded = true, canUpdate = true, guides = {}, packs = {}, guideStatus = "Ready" }
    local addon, panel, calls, environment = Fixture(state)
    panel.restedxpShare:Click()
    local page = panel.pages.restedxp
    assert(page.publish:IsVisible() and not page.main:IsShown()
        and panel.restedxpBattleTag:GetText() == "Local#1234" and not panel.restedxpImport:IsEnabled(),
        "sharing opens a temporary import form with the locally available BattleTag")
    panel.restedxpPackID:UserInput("leveling")
    panel.restedxpBattleTag:UserInput("Source#5678")
    local raw = string.rep("Synthetic export text\n", 400)
    panel.restedxpExport:UserInput(raw)
    assert(panel.restedxpExport.multiline and panel.restedxpExport:GetText() == raw
        and panel.restedxpImport:IsEnabled()
        and panel.restedxpExport.parent.frameType == "ScrollFrame"
        and panel.restedxpExport.parent.scrollRectUpdates > 0,
        "large pasted exports use a native scrolling multiline field without a short edit-box limit")
    calls.importError = "Wrong source BattleTag."
    panel.restedxpImport:Click()
    assert(page.publish:IsVisible() and panel.restedxpExport:GetText() == raw
        and panel.feedback:GetText() == calls.importError, "failed validation retains the draft and explains the error")
    calls.importError = nil
    panel.restedxpImport:Click()
    local imported = calls.imports[2]
    assert(imported[1] == "leveling" and imported[2] == raw and imported[3] == "Source#5678",
        "publishing passes the pack identity, exact pasted bytes and source BattleTag to the feature")
    assert(page.main:IsVisible() and not page.publish:IsShown()
        and panel.restedxpBattleTag:GetText() == "" and panel.restedxpExport:GetText() == "",
        "successful sharing returns to availability and clears sensitive drafts")
    assert(panel.feedback:GetText() == "", "accepted imports clear prior errors and use live validation status")
    state.status = "Shared leveling (10 guides)."
    addon:Notify("RESTEDXP_CHANGED")
    assert(panel.feedback:GetText() == "" and Details(panel, environment):find("Shared leveling", 1, true),
        "completed sharing does not leave a permanent validating footer message")
    local function Draft()
        panel.restedxpShare:Click()
        panel.restedxpPackID:UserInput("test")
        panel.restedxpExport:UserInput("new export draft")
        panel.restedxpBattleTag:SetFocus()
    end
    Draft()
    addon:Notify("RESTEDXP_CHANGED")
    assert(panel.restedxpExport:GetText() == "new export draft"
        and panel.restedxpBattleTag:GetText() == "Local#1234", "background feature notifications preserve unfinished input")
    panel.tabs.chat:Click()
    assert(panel.restedxpBattleTag:GetText() == "" and panel.restedxpExport:GetText() == ""
        and not panel.restedxpBattleTag.focused, "leaving the tab clears BattleTag and guide drafts and focus")
    panel.tabs.restedxp:Click()
    Draft()
    page.back:Click()
    assert(page.main:IsVisible() and panel.restedxpPackID:GetText() == "", "Back discards the import draft")
    Draft()
    panel.parent.CloseButton:Click()
    assert(panel.restedxpBattleTag:GetText() == "" and panel.restedxpExport:GetText() == "",
        "closing the shared window clears all import fields")
    addon:OpenOptions("restedxp")
    state.readOnly = true
    addon:Notify("RESTEDXP_CHANGED")
    assert(not panel.restedxpUpdate:IsEnabled() and not panel.restedxpShare:IsEnabled()
        and not panel.restedxpBattleTag:IsEnabled(), "read-only feature state blocks saved subscriptions, imports and updates")
    assert(environment.LockInToolsDB.group.secret == support.SECRET,
        "viewing guide availability and temporary import forms leaves the shared group key unchanged")
end

print("PASS: RestedXP summary, player publishers, updates, import drafts and privacy")
