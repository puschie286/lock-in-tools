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
        return true
    end
    function addon:SelectRestedXPPack(id, source)
        calls.selections[#calls.selections + 1] = { id, source }
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

do
    local state = { installed = false, loaded = false, canUpdate = false, guides = {}, packs = {} }
    local addon, panel, calls = Fixture(state)
    assert(panel.selectedTab == "restedxp" and panel.pages.restedxp:IsVisible()
        and panel.restedxpStatus:GetText():find("not installed", 1, true),
        "RestedXP has an accessible Settings tab with explicit installation status")
    assert(not panel.restedxpUpdate:IsEnabled() and panel.restedxpGuides.empty:IsShown()
        and panel.restedxpPacks.empty:IsShown(), "unavailable updates and empty lists remain understandable")
    assert(panel.tabs.restedxp.point[2] + panel.tabs.restedxp:GetWidth() <= 700,
        "all Settings tabs fit inside the existing window")
    state.installed, state.version = true, "4.9.1"
    addon:Notify("RESTEDXP_CHANGED")
    assert(panel.restedxpStatus:GetText():find("not loaded", 1, true)
        and panel.restedxpStatus:GetText():find("4.9.1", 1, true),
        "an installed but unloaded addon is distinguished from an absent addon")
    state.loaded, state.canUpdate = true, true
    state.guides = {}
    for index = 1, 9 do
        state.guides[index] = { name = "Guide " .. index, group = "Test group", version = index, key = "guide" .. index }
    end
    state.packs = {
        { id = "test", label = "Test pack", source = "Alice-Realm", hash = "12345678fullhash", updateAvailable = true },
        { id = "test", source = "Bob-Realm", hash = "anotherhash", selected = true, installed = true },
        { id = "mine", source = "Local-Realm", hash = "localhash", localPack = true },
        { id = "offline", source = "Offline-Realm", hash = "cachedhash", canFollow = false },
    }
    addon:Notify("RESTEDXP_CHANGED")
    assert(panel.restedxpUpdate:IsEnabled()
        and panel.restedxpGuides.rows[1].name:GetText() == "Test group / Guide 1"
        and panel.restedxpGuides.rows[1].version:GetText() == "v1"
        and panel.restedxpGuides.scrollbar:IsShown(), "installed guide names and versions render in a bounded list")
    panel.restedxpGuides.scripts.OnMouseWheel(panel.restedxpGuides, -100)
    assert(panel.restedxpGuides.offset == 5 and panel.restedxpGuides.rows[4].version:GetText() == "v9",
        "wheel scrolling reaches every installed guide and clamps to the last row")
    panel.restedxpGuides.scrollbar:SetValue(0)
    assert(panel.restedxpGuides.rows[1].version:GetText() == "v1", "the native scrollbar updates visible guide rows")
    local packRow = panel.restedxpPacks.rows[1]
    assert(packRow.detail:GetText():find("Alice-Realm", 1, true)
        and packRow.detail:GetText():find("Update available", 1, true)
        and packRow.detail:GetText():find("12345678", 1, true),
        "pack availability identifies its publisher and content independently of guide versions")
    packRow.follow:Click()
    assert(#calls.selections == 1 and calls.selections[1][1] == "test"
        and calls.selections[1][2] == "Alice-Realm", "following explicitly selects the displayed publisher")
    assert(not panel.restedxpPacks.rows[2].follow:IsEnabled()
        and panel.restedxpPacks.rows[2].follow:GetText() == "Following", "the existing subscription is visible")
    panel.restedxpPacks.scrollbar:SetValue(1)
    assert(panel.restedxpPacks.rows[1].pack.source == "Bob-Realm"
        and not panel.restedxpPacks.rows[2].follow:IsEnabled()
        and panel.restedxpPacks.rows[2].follow:GetText() == "Shared",
        "locally published packs show shared status without an invalid self-follow action")
    panel.restedxpPacks.scrollbar:SetValue(2)
    assert(panel.restedxpPacks.rows[2].pack.source == "Offline-Realm"
        and not panel.restedxpPacks.rows[2].follow:IsEnabled()
        and panel.restedxpPacks.rows[2].follow:GetText() == "Cached",
        "cached sources without a live offer cannot be newly followed")
    state.guides[1].version = 0
    addon:Notify("RESTEDXP_CHANGED")
    assert(panel.restedxpGuides.rows[1].version:GetText() == "Unversioned",
        "the missing-version sentinel is displayed as unversioned")
    panel.restedxpUpdate:Click()
    assert(calls.update == 1, "Update guides triggers feature discovery and updates exactly once")
    state.busy, state.status = true, "Downloading test pack (50%)."
    addon:Notify("RESTEDXP_CHANGED")
    assert(not panel.restedxpUpdate:IsEnabled() and not panel.restedxpShare:IsEnabled()
        and panel.restedxpStatus:GetText():find("50%", 1, true), "in-progress work updates status and prevents duplicate actions")
    state.busy, state.installationProblem = false, "The RestedXP importer is unavailable."
    addon:Notify("RESTEDXP_CHANGED")
    assert(panel.restedxpStatus:GetText():find("importer is unavailable", 1, true), "adapter compatibility problems are visible")
    assert(panel.restedxpStatus:GetText():find("50%", 1, true), "compatibility guidance does not conceal guide transfer status")
end

do
    local state = { installed = true, loaded = true, canUpdate = true, guides = {}, packs = {} }
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

print("PASS: RestedXP Settings status, guide versions, publisher selection, updates, import drafts and privacy")
