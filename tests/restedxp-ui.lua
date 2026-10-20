local support = dofile("tests/support/addon.lua")
local loadOptions = dofile("tests/support/ui.lua")

local function Fixture(state, noGroup)
    local saved = noGroup and { schemaVersion = 3, showWelcome = false, chat = { autoJoin = false } }
        or support.settings(support.SECRET, false)
    local addon, environment, _, _, world = support.loadAddon(saved, false)
    world:initialize()
    if state.sourceBattleTag ~= nil then
        assert(addon:SetRestedXPSourceBattleTag(state.sourceBattleTag))
    end
    local calls = {}
    local getState = addon.GetRestedXPState
    function addon:GetRestedXPState()
        state.sourceBattleTag = getState(self).sourceBattleTag
        return state
    end
    function addon:ImportRestedXPString(raw, source)
        calls[#calls + 1] = { raw = raw, source = source }
        if calls.importError then return false, calls.importError end
        return true
    end
    loadOptions(addon, environment)
    addon:OpenOptions("restedxp")
    return addon, addon.optionsPanel, calls, environment, world
end

local function Export(panel)
    return panel.pages.restedxp.GetExport()
end

local function Paste(panel, raw)
    panel.restedxpExport:Paste(raw)
    panel.restedxpExport:AdvanceFrame(0.11)
end

local function AssertContentNotRendered(panel, snippet)
    local visited = 0
    local function Inspect(widget, alpha)
        alpha = alpha * (widget.alpha or 1)
        if widget:IsVisible() and alpha > 0 then
            local text = widget:GetText()
            assert(not text:find(snippet, 1, true), "pasted content must never appear in a visible label, button or field")
            visited = visited + 1
        end
        for _, child in ipairs(widget.children) do Inspect(child, alpha) end
    end
    Inspect(panel.parent, 1)
    assert(visited > 10, "content privacy checks inspect the visible form and its labels")
end

do
    local state = { installed = false, loaded = false, canImport = false }
    local addon, panel, calls = Fixture(state)
    assert(panel.selectedTab == "restedxp" and panel.pages.restedxp:IsVisible()
        and panel.restedxpNotice:GetText():find("RestedXP is required", 1, true),
        "the import tab explains the missing required addon")
    assert(not panel.restedxpImport:IsEnabled() and panel.restedxpBattleTag:GetText() == ""
        and not panel.restedxpPublishers and not panel.restedxpUpdate and not panel.restedxpShare
        and not panel.restedxpCancel and not panel.restedxpPackID and not panel.restedxpDestination
        and not panel.restedxpClear,
        "the helper contains only source identity, pasted import text and Import")
    local partial = "  OriginalOwner#  "
    panel.restedxpBattleTag:UserInput(partial)
    assert(addon.db.restedxp.sourceBattleTag == partial and #calls == 0,
        "source edits are remembered exactly without importing, even when RestedXP is missing")
    panel.tabs.chat:Click()
    assert(addon.db.restedxp.sourceBattleTag == partial and panel.restedxpBattleTag:GetText() == "",
        "programmatic field clearing on hide leaves the saved source untouched")
    panel.tabs.restedxp:Click()
    assert(panel.restedxpBattleTag:GetText() == partial and panel.restedxpExport:GetText() == "",
        "returning to the tab restores incomplete source input without guide text")
    panel.restedxpBattleTag:UserInput("")
    assert(addon.db.restedxp == nil, "explicitly deleting the source clears its saved preference")
    panel.parent.CloseButton:Click()
    addon:OpenOptions("restedxp")
    assert(panel.restedxpBattleTag:GetText() == "" and addon:GetRestedXPState().sourceBattleTag == "",
        "reopening the window retains an explicitly cleared source")
    state.installed, state.problem = true, "Enable RestedXP to import guides."
    addon:Notify("RESTEDXP_CHANGED")
    assert(panel.restedxpNotice:GetText() == state.problem and not panel.restedxpImport:IsEnabled(),
        "an installed but unavailable native importer has a small actionable notice")
    state.loaded, state.compatible, state.canImport, state.problem = true, true, true, nil
    addon:Notify("RESTEDXP_CHANGED")
    assert(panel.restedxpNotice:GetText() == "" and not panel.restedxpImport:IsEnabled(),
        "a ready native importer needs no installed-version summary and still requires a complete draft")
end

do
    local state = { installed = true, loaded = true, compatible = true, canImport = true }
    local addon, panel, calls, environment, world = Fixture(state, true)
    assert(not addon:HasGroup(), "the local import fixture has no LIT group")
    local guideSends, dataSends, statusSends = #(world.guideSends or {}), #world.dataSends, #world.statusSends
    panel.restedxpBattleTag:UserInput("   ")
    assert(addon.db.restedxp.sourceBattleTag == "   ", "whitespace input is remembered while it is being edited")
    Paste(panel, "draft")
    assert(not panel.restedxpImport:IsEnabled(), "a source BattleTag is required for an encrypted export")
    panel.restedxpBattleTag:UserInput("SourceOwner#5678")
    local raw = "1|MiXeD+Case/Export==%|40000\n" .. string.rep("Large pasted import text\n", 400)
    Paste(panel, raw)
    assert(panel.restedxpImport:IsEnabled() and panel.restedxpExport.multiline
        and Export(panel) == raw and panel.restedxpExport:GetText() == ""
        and panel.restedxpExportStatus:GetText() == #raw .. " bytes loaded.",
        "a large multiline import has an exact buffered draft and only a byte count without a group")
    calls.importError = "The source BattleTag cannot read this export."
    panel.restedxpImport:Click()
    assert(#calls == 1 and calls[1].raw == raw and calls[1].source == "SourceOwner#5678"
        and panel.feedback:GetText() == calls.importError
        and panel.restedxpBattleTag:GetText() == "SourceOwner#5678" and Export(panel) == raw
        and addon.db.restedxp.sourceBattleTag == "SourceOwner#5678",
        "the backend receives exact case-preserving input and a rejected import retains its draft")
    calls.importError = nil
    panel.restedxpImport:Click()
    assert(#calls == 2 and panel.feedback:GetText() == "" and Export(panel) == raw,
        "accepted conversion clears an earlier error while retaining the draft")
    state.busy, state.canImport, state.status = true, false, "Converting import string..."
    addon:Notify("RESTEDXP_CHANGED")
    assert(not panel.restedxpImport:IsEnabled() and not panel.restedxpBattleTag:IsEnabled()
        and not panel.restedxpExport:IsEnabled() and not panel.restedxpPaste:IsEnabled()
        and not panel.restedxpClearExport:IsEnabled() and panel.feedback:GetText() == state.status
        and Export(panel) == raw,
        "local conversion prevents duplicate submissions and shows one progress line")
    state.busy, state.canImport, state.error, state.status = false, true, true, "The import string could not be converted."
    addon:Notify("RESTEDXP_CHANGED")
    assert(panel.restedxpImport:IsEnabled() and panel.feedback:GetText() == state.status
        and Export(panel) == raw and panel.restedxpBattleTag:GetText() == "SourceOwner#5678",
        "an asynchronous failure leaves the original input available for correction")
    state.error, state.status = false, "Passed the converted string to RestedXP."
    addon:Notify("RESTEDXP_CHANGED")
    assert(panel.feedback:GetText() == state.status and Export(panel) == raw,
        "native handoff is reported without claiming that guides were installed")
    panel.restedxpClearExport:Click()
    assert(not panel.restedxpImport:IsEnabled() and Export(panel) == ""
        and not panel.restedxpClearExport:IsEnabled()
        and panel.restedxpExportStatus:GetText() == "No export loaded (0 bytes)."
        and panel.restedxpBattleTag:GetText() == "SourceOwner#5678"
        and addon.db.restedxp.sourceBattleTag == "SourceOwner#5678",
        "clearing an export resets the byte count and import action without changing the saved source")
    Paste(panel, raw)
    panel.restedxpBattleTag:SetFocus()
    panel.tabs.chat:Click()
    assert(panel.restedxpBattleTag:GetText() == "" and panel.restedxpExport:GetText() == "" and Export(panel) == ""
        and not panel.restedxpBattleTag.focused and addon.db.restedxp.sourceBattleTag == "SourceOwner#5678",
        "leaving the tab clears temporary input and focus while retaining the source preference")
    panel.tabs.restedxp:Click()
    panel.restedxpBattleTag:UserInput("OriginalOwner#9999")
    Paste(panel, raw)
    panel.parent.CloseButton:Click()
    assert(panel.restedxpBattleTag:GetText() == "" and panel.restedxpExport:GetText() == "" and Export(panel) == ""
        and addon.db.restedxp.sourceBattleTag == "OriginalOwner#9999",
        "closing the window clears rendered input and guide contents while retaining the source preference")
    addon:OpenOptions("restedxp")
    assert(panel.restedxpBattleTag:GetText() == "OriginalOwner#9999" and Export(panel) == "",
        "reopening the window restores the edited source without requiring a successful import")
    state.readOnly = true
    addon:Notify("RESTEDXP_CHANGED")
    assert(not panel.restedxpImport:IsEnabled() and not panel.restedxpBattleTag:IsEnabled()
        and not panel.restedxpExport:IsEnabled() and not panel.restedxpPaste:IsEnabled()
        and not panel.restedxpClearExport:IsEnabled(), "read-only backend state blocks import actions")
    assert(#(world.guideSends or {}) == guideSends and #world.dataSends == dataSends and #world.statusSends == statusSends,
        "viewing and using the local import form initiates no group communication")
    local function ContainsDraft(value)
        if type(value) ~= "table" then return value == raw end
        for _, child in pairs(value) do if ContainsDraft(child) then return true end end
        return false
    end
    assert(not ContainsDraft(environment.LockInToolsDB), "the UI persists the source preference without pasted guide text")
end

do
    local state = { installed = true, loaded = true, compatible = true, canImport = true,
        sourceBattleTag = "RememberedOwner#1234" }
    local addon, panel, calls, environment = Fixture(state, true)
    assert(panel.restedxpBattleTag:GetText() == "RememberedOwner#1234" and panel.restedxpExport:GetText() == "",
        "opening the import helper prefills the saved source without restoring guide text")
    local edited, raw = "EditedOwner#9876", "CaseSensitive+Unsaved/Export=="
    panel.restedxpBattleTag:UserInput(edited)
    assert(addon.db.restedxp.sourceBattleTag == edited and #calls == 0,
        "editing replaces the saved source immediately before any import")
    Paste(panel, raw)
    addon:OpenOptions("restedxp")
    assert(panel.restedxpBattleTag:GetText() == edited and Export(panel) == raw,
        "opening an already visible import tab retains the current draft")
    calls.importError = "This source cannot read the export."
    panel.restedxpImport:Click()
    assert(calls[1].source == edited and addon:GetRestedXPState().sourceBattleTag == edited
        and panel.restedxpBattleTag:GetText() == edited and Export(panel) == raw,
        "a rejected import retains the already saved edited source")
    state.busy, state.canImport, state.status = true, false, "Converting import string..."
    addon:Notify("RESTEDXP_CHANGED")
    state.busy, state.canImport, state.error, state.status = false, true, true, "Conversion failed."
    addon:Notify("RESTEDXP_CHANGED")
    assert(panel.restedxpBattleTag:GetText() == edited and Export(panel) == raw,
        "asynchronous progress and failure keep the edited source and guide draft")
    panel.tabs.chat:Click()
    assert(panel.restedxpBattleTag:GetText() == "" and panel.restedxpExport:GetText() == "" and Export(panel) == "",
        "leaving the tab clears rendered source and guide text")
    panel.tabs.restedxp:Click()
    assert(panel.restedxpBattleTag:GetText() == edited and panel.restedxpExport:GetText() == "",
        "returning to the tab restores the source saved before the rejected import")
    panel.restedxpBattleTag:UserInput(edited)
    Paste(panel, raw)
    calls.importError = nil
    panel.restedxpImport:Click()
    assert(addon:SetRestedXPSourceBattleTag("ChangedOwner#5555"))
    state.error, state.status = false, "Passed the converted string to RestedXP."
    addon:Notify("RESTEDXP_CHANGED")
    assert(panel.restedxpBattleTag:GetText() == edited and Export(panel) == raw,
        "a newly remembered source from the backend does not overwrite the visible draft")
    panel.parent.CloseButton:Click()
    assert(panel.restedxpBattleTag:GetText() == "" and panel.restedxpExport:GetText() == "" and Export(panel) == "",
        "closing the window clears the rendered inputs")
    addon:OpenOptions("restedxp")
    assert(panel.restedxpBattleTag:GetText() == "ChangedOwner#5555" and panel.restedxpExport:GetText() == "",
        "reopening the window prefills the backend's latest remembered source")
    local function ContainsDraft(value)
        if type(value) ~= "table" then return value == raw end
        for _, child in pairs(value) do if ContainsDraft(child) then return true end end
        return false
    end
    assert(not ContainsDraft(environment.LockInToolsDB), "editing and submitting the form never saves guide text")
end

do
    local addon, panel, calls, environment, world = Fixture({ installed = false, loaded = false, canImport = false }, true)
    local source = "  UnfinishedOwner#  "
    panel.restedxpBattleTag:UserInput(source)
    Paste(panel, "Unsaved+Guide/Export==")
    local persisted = environment.LockInToolsDB
    world.fire("PLAYER_LOGOUT")
    local reloaded, reloadEnvironment, _, _, reloadWorld = support.loadAddon(persisted, false)
    reloadWorld:initialize()
    loadOptions(reloaded, reloadEnvironment)
    reloaded:OpenOptions("restedxp")
    local reloadPanel = reloaded.optionsPanel
    assert(#calls == 0 and reloadEnvironment.LockInToolsDB == persisted
        and reloadPanel.restedxpBattleTag:GetText() == source
        and reloadPanel.restedxpExport:GetText() == "" and Export(reloadPanel) == "",
        "an unsubmitted partial source survives logout cleanup and addon reload while guide text is discarded")
    reloadPanel.restedxpBattleTag:UserInput("")
    reloadWorld.fire("PLAYER_LOGOUT")
    local cleared, clearedEnvironment, _, _, clearedWorld = support.loadAddon(persisted, true)
    clearedWorld:initialize()
    loadOptions(cleared, clearedEnvironment)
    cleared:OpenOptions("restedxp")
    assert(cleared.optionsPanel.restedxpBattleTag:GetText() == "" and persisted.restedxp == nil,
        "explicitly clearing the source also survives logout cleanup and addon reload")
end

do
    local futureSource = { sourceBattleTag = "FutureOwner#1234", futureField = "keep" }
    local future = { schemaVersion = 4, showWelcome = false, restedxp = futureSource }
    local addon, environment, _, _, world = support.loadAddon(future, false)
    world:initialize()
    loadOptions(addon, environment)
    addon:OpenOptions("restedxp")
    local panel = addon.optionsPanel
    assert(addon.savedDataReadOnly and not panel.restedxpBattleTag:IsEnabled()
        and not panel.restedxpImport:IsEnabled() and not panel.restedxpPaste:IsEnabled()
        and not panel.restedxpClearExport:IsEnabled() and not addon:SetRestedXPSourceBattleTag("Replacement#9999"),
        "newer-schema settings disable source edits and reject preference writes")
    panel.parent.CloseButton:Click()
    addon:OpenOptions("restedxp")
    world.fire("PLAYER_LOGOUT")
    assert(environment.LockInToolsDB == future and future.schemaVersion == 4 and future.restedxp == futureSource
        and futureSource.sourceBattleTag == "FutureOwner#1234" and futureSource.futureField == "keep",
        "opening, hiding and logout cleanup preserve the entire newer-schema source namespace")
end

do
    local state = { installed = true, loaded = true, compatible = true, canImport = true }
    local _, panel, calls = Fixture(state, true)
    local edit = panel.restedxpExport
    panel.restedxpBattleTag:UserInput("SourceOwner#5678")
    assert(panel.restedxpPaste:GetText() == "Paste export" and panel.restedxpPaste:IsEnabled()
        and not panel.restedxpClearExport:IsEnabled()
        and panel.restedxpExportStatus:GetText() == "No export loaded (0 bytes)."
        and edit:IsVisible() and edit.alpha == 0 and edit.mouseEnabled == false
        and edit:GetWidth() == 1 and edit:GetHeight() == 1 and edit:GetMaxBytes() == 1,
        "the form starts empty with an accessible paste button and an invisible bounded capture field")
    panel.restedxpPaste:Click()
    assert(edit.focused and panel.restedxpPaste:GetText() == "Press Ctrl+V",
        "the paste button directs clipboard input into the invisible capture field")
    edit:Paste("First|chunk\r\n")
    assert(Export(panel) == "" and not panel.restedxpImport:IsEnabled() and #edit:GetText() <= 1
        and panel.restedxpExportStatus:GetText() == "Receiving export..." and panel.restedxpClearExport:IsEnabled(),
        "the full clipboard chunk is buffered separately while the field receives input")
    panel.restedxpImport:Click()
    assert(#calls == 0, "receiving a paste cannot start an import")
    edit:AdvanceFrame(0.06)
    edit:Paste("Second\tchunk")
    edit:AdvanceFrame(0.06)
    assert(Export(panel) == "" and not panel.restedxpImport:IsEnabled(),
        "another clipboard chunk restarts the settling delay")
    edit:AdvanceFrame(0.05)
    local raw = "First|chunk\r\nSecond\tchunk"
    assert(Export(panel) == raw and panel.restedxpImport:IsEnabled()
        and edit:GetText() == ""
        and panel.restedxpExportStatus:GetText() == #raw .. " bytes loaded.",
        "settled chunks retain exact bytes while the form displays only a byte count")
    AssertContentNotRendered(panel, "First|chunk")
    edit:ClearFocus()
    assert(edit:GetMaxBytes() == 1 and Export(panel) == raw and panel.restedxpPaste:GetText() == "Paste export",
        "releasing clipboard focus retains the complete draft and restores the paste prompt")
    panel.restedxpPaste:Click()
    assert(Export(panel) == raw, "clicking the paste button does not discard a completed draft")
    edit:Paste("Replacement|draft\n")
    assert(Export(panel) == "" and not panel.restedxpImport:IsEnabled(),
        "the first new character replaces the previous draft and blocks submission until settled")
    edit.scripts.OnEscapePressed(edit)
    assert(not edit.focused and Export(panel) == "Replacement|draft\n"
        and edit:GetText() == "" and not edit:GetScript("OnUpdate")
        and panel.restedxpPaste:GetText() == "Paste export",
        "Escape releases focus and finalizes the replacement without losing bytes")
    edit:AdvanceFrame(1)
    panel.restedxpImport:Click()
    assert(#calls == 1 and calls[1].raw == "Replacement|draft\n",
        "submitting after Escape forwards the complete replacement while its contents remain undisplayed")
end

do
    local state = { installed = true, loaded = true, compatible = true, canImport = true }
    local addon, panel, calls = Fixture(state, true)
    local edit, source = panel.restedxpExport, "RememberedOwner#1234"
    panel.restedxpBattleTag:UserInput(source)
    local originalSetText = edit.SetText
    function edit:SetText(text)
        assert(text == "", "captured guide content must never be copied back into native text storage")
        return originalSetText(self, text)
    end
    local raw = "UNIQUE_PRIVATE_EXPORT|cFFFF0000|Hguide:123|hPrivate guide|h|r\r\n\tUTF8=\195\169\228\184\173=="
    panel.restedxpPaste:Click()
    edit:Paste(raw, #raw)
    assert(panel.restedxpExportStatus:GetText() == "Receiving export..." and Export(panel) == "",
        "an in-flight export displays a receiving state rather than its contents")
    AssertContentNotRendered(panel, "UNIQUE_PRIVATE_EXPORT")
    AssertContentNotRendered(panel, "Private guide")
    edit:ClearFocus()
    assert(Export(panel) == raw and edit:GetText() == ""
        and panel.restedxpExportStatus:GetText() == #raw .. " bytes loaded."
        and not edit:GetScript("OnUpdate") and panel.restedxpClearExport:IsEnabled(),
        "focus loss finalizes markup, CRLF and multi-byte input with the exact byte count")
    AssertContentNotRendered(panel, "UNIQUE_PRIVATE_EXPORT")
    AssertContentNotRendered(panel, "Private guide")
    panel.restedxpImport:Click()
    assert(#calls == 1 and calls[1].raw == raw, "status-only capture imports literal markup and UTF-8 without altering bytes")
    panel.restedxpClearExport:Click()
    assert(Export(panel) == "" and panel.restedxpExportStatus:GetText() == "No export loaded (0 bytes)."
        and not panel.restedxpClearExport:IsEnabled() and not panel.restedxpImport:IsEnabled()
        and panel.restedxpBattleTag:GetText() == source and addon.db.restedxp.sourceBattleTag == source,
        "clearing a loaded export retains only its saved source")
    edit:Paste("UNIQUE_ABANDONED_EXPORT\r\n")
    edit:AdvanceFrame(0.06)
    assert(panel.restedxpClearExport:IsEnabled(), "Clear is available during clipboard capture")
    panel.restedxpClearExport:Click()
    assert(Export(panel) == "" and edit:GetText() == "" and not edit.focused
        and not edit:GetScript("OnUpdate") and panel.restedxpPaste:GetText() == "Paste export"
        and panel.restedxpExportStatus:GetText() == "No export loaded (0 bytes).",
        "clearing an in-flight paste cancels capture, focus and pending updates immediately")
    edit:AdvanceFrame(1)
    assert(Export(panel) == "" and not panel.restedxpImport:IsEnabled() and #calls == 1,
        "a cleared partial paste never reappears or becomes importable")
    AssertContentNotRendered(panel, "UNIQUE_ABANDONED_EXPORT")
    Paste(panel, "Fresh+replacement==")
    panel.restedxpImport:Click()
    assert(#calls == 2 and calls[2].raw == "Fresh+replacement==" and calls[2].source == source,
        "the next paste after Clear contains only the replacement and retains the source identity")
end

do
    local maximum = 2 * 1024 * 1024
    local state = { installed = true, loaded = true, compatible = true, canImport = true }
    local _, panel, calls = Fixture(state, true)
    local edit = panel.restedxpExport
    panel.restedxpBattleTag:UserInput("SourceOwner#5678")
    function edit:GetNumLines() error("bulk paste must not measure or expand the native EditBox") end
    local widgetCalls = 0
    for _, entry in ipairs({ { edit, "GetText" }, { edit, "SetText" }, { edit, "SetScript" },
        { edit, "SetMaxBytes" }, { panel.restedxpExportStatus, "SetText" },
        { panel.restedxpBattleTag, "GetText" }, { panel.restedxpImport, "SetEnabled" } }) do
        local widget, method = entry[1], entry[2]
        local original = widget[method]
        widget[method] = function(self, ...)
            widgetCalls = widgetCalls + 1
            return original(self, ...)
        end
    end
    for _, raw in ipairs({ string.rep("A", maximum), "A" .. string.rep("\n", maximum - 2) .. "B" }) do
        edit:Paste(raw:sub(1, 1))
        local initialCalls = widgetCalls
        edit:Paste(raw:sub(2))
        assert(widgetCalls == initialCalls and not edit:GetScript("OnTextChanged"),
            "millions of individual character callbacks receive no repeated widget calls or text-change callbacks")
        assert(#edit:GetText() <= 1 and Export(panel) == "" and not panel.restedxpImport:IsEnabled(),
            "even the largest per-character clipboard paste stays out of native text rendering")
        edit:AdvanceFrame(0.11)
        assert(Export(panel) == raw and edit:GetText() == ""
            and panel.restedxpExportStatus:GetText() == #raw .. " bytes loaded."
            and edit.maxNativeTextBytes <= 1 and edit:GetMaxBytes() == 1
            and edit.alpha == 0 and edit:GetWidth() == 1 and edit:GetHeight() == 1,
            "2 MiB ASCII and newline-heavy drafts display only their byte count and keep native storage at one byte")
        assert(not edit:GetScript("OnTextChanged"), "settled pastes never enable native text-change processing")
        local previous = #calls
        panel.restedxpImport:Click()
        assert(#calls == previous + 1 and calls[#calls].raw == raw,
            "a maximum-size draft reaches import byte-for-byte while the field stores no export text")
    end
    local previous = #calls
    edit:Paste(string.rep("B", maximum + 1))
    edit:AdvanceFrame(0.11)
    assert(Export(panel) == "" and not panel.restedxpImport:IsEnabled()
        and panel.restedxpExportStatus:GetText() == "Export is larger than 2 MiB. Paste a smaller export."
        and edit.maxNativeTextBytes <= 1,
        "an oversized clipboard chunk is explicitly rejected without rendering or accepting a truncated draft")
    panel.restedxpImport:Click()
    assert(#calls == previous, "oversized text cannot be submitted")
    edit:Paste(string.rep("C", maximum))
    edit:AdvanceFrame(0.05)
    edit:Paste("D")
    edit:AdvanceFrame(0.11)
    assert(Export(panel) == "" and not panel.restedxpImport:IsEnabled()
        and panel.restedxpExportStatus:GetText() == "Export is larger than 2 MiB. Paste a smaller export.",
        "the size limit applies to all clipboard chunks together")
    edit:Paste(string.rep("E", maximum - 1), maximum)
    edit:Paste("\195\169", 2)
    local rejectedCalls = widgetCalls
    edit:Paste(string.rep("Z", 32768))
    assert(widgetCalls == rejectedCalls,
        "characters after the first overflow are discarded without repeated native calls")
    edit:AdvanceFrame(0.11)
    assert(Export(panel) == "" and not panel.restedxpImport:IsEnabled()
        and panel.restedxpExportStatus:GetText() == "Export is larger than 2 MiB. Paste a smaller export.",
        "the byte limit rejects a multi-byte callback crossing the boundary without accepting a partial character")
    Paste(panel, "Valid+retry/export==")
    assert(Export(panel) == "Valid+retry/export==" and panel.restedxpImport:IsEnabled(),
        "a new paste recovers from an oversized draft without retaining rejected chunks")
    panel.restedxpImport:Click()
    assert(#calls == previous + 1 and calls[#calls].raw == "Valid+retry/export==",
        "retry imports only the replacement draft")
    Paste(panel, " \r\n\t ")
    assert(not panel.restedxpImport:IsEnabled(), "a buffered whitespace-only draft cannot be imported")
end

do
    local state = { installed = true, loaded = true, compatible = true, canImport = true }
    local _, panel, calls = Fixture(state, true)
    local edit = panel.restedxpExport
    panel.restedxpBattleTag:UserInput("SourceOwner#5678")
    local raw = string.rep("Ab|CD\r\n\t09+/", 700) .. "Tail=\195\169"
    Paste(panel, raw)
    assert(#raw > 8192 and #raw % 4096 ~= 0 and Export(panel) == raw,
        "nonuniform input preserves order across staging boundaries and excludes stale entries after its final partial block")
    Paste(panel, "x")
    assert(Export(panel) == "x" and edit:GetText() == ""
        and panel.restedxpExportStatus:GetText() == "1 bytes loaded.",
        "a short replacement retains no staging blocks from the preceding paste")
    local callbackChunk = "Case|Sensitive\195\169\n+Chunk=="
    edit:Paste(callbackChunk, #callbackChunk)
    edit:AdvanceFrame(0.11)
    assert(Export(panel) == callbackChunk and edit:GetText() == ""
        and panel.restedxpExportStatus:GetText() == #callbackChunk .. " bytes loaded.",
        "a complete multi-byte callback is preserved alongside ordinary per-character input")
    panel.restedxpImport:Click()
    assert(#calls == 1 and calls[1].raw == callbackChunk,
        "the backend receives the whole replacement after staging and callback-size changes")
end

do
    local state = { installed = true, loaded = true, compatible = true, canImport = true }
    local addon, panel, calls, _, world = Fixture(state, true)
    local guideSends, dataSends, statusSends = #(world.guideSends or {}), #world.dataSends, #world.statusSends
    local raw = "Native+Progress/Export=="
    panel.restedxpBattleTag:UserInput("ProgressOwner#1234")
    Paste(panel, raw)
    panel.restedxpImport:Click()
    assert(#calls == 1, "the native progress fixture submits one local import")
    local function Progress(current)
        state.phase, state.busy, state.canImport, state.error = "importing", true, false, false
        state.current, state.total = current, 10
        state.status = "Importing guides: " .. current .. "/10 (" .. current * 10 .. "%)"
        addon:Notify("RESTEDXP_CHANGED")
        assert(panel.feedback:GetText() == state.status and not panel.restedxpImport:IsEnabled()
            and not panel.restedxpBattleTag:IsEnabled() and not panel.restedxpPaste:IsEnabled()
            and not panel.restedxpClearExport:IsEnabled(),
            "native guide progress is visible while all draft-changing actions remain disabled")
    end
    Progress(0)
    assert(Export(panel) == raw, "starting native guide import retains the submitted draft")
    Progress(4)
    assert(Export(panel) == raw, "live guide counts refresh without replacing the submitted draft")
    panel.tabs.chat:Click()
    assert(Export(panel) == "", "leaving the progress tab still clears the temporary export")
    panel.tabs.restedxp:Click()
    assert(panel.feedback:GetText() == state.status and not panel.restedxpPaste:IsEnabled()
        and panel.restedxpBattleTag:GetText() == "ProgressOwner#1234" and Export(panel) == "",
        "returning to the tab restores native progress and the saved source without restoring guide text")
    panel.parent.CloseButton:Click()
    state.current, state.status = 8, "Importing guides: 8/10 (80%)"
    addon:Notify("RESTEDXP_CHANGED")
    addon:OpenOptions("restedxp")
    assert(panel.feedback:GetText() == state.status and not panel.restedxpImport:IsEnabled()
        and not panel.restedxpPaste:IsEnabled() and Export(panel) == "",
        "a native import keeps progressing while the window is closed and is shown on reopening")
    Progress(10)
    panel.restedxpImport:Click()
    assert(#calls == 1 and state.phase == "importing" and not panel.restedxpPaste:IsEnabled(),
        "the final guide count alone does not complete the import or release actions")
    state.phase, state.busy, state.canImport, state.status = "completed", false, true, "Guide import completed."
    addon:Notify("RESTEDXP_CHANGED")
    assert(panel.feedback:GetText() == state.status and panel.restedxpBattleTag:IsEnabled()
        and panel.restedxpPaste:IsEnabled() and not panel.restedxpImport:IsEnabled()
        and not panel.restedxpClearExport:IsEnabled(),
        "explicit native completion releases the form and still requires a new export after reopening")
    for _, phase in ipairs({ "failed", "cancelled" }) do
        Paste(panel, raw)
        panel.restedxpImport:Click()
        local submitted = #calls
        Progress(3)
        state.phase, state.busy, state.canImport, state.error = phase, false, true, phase == "failed"
        state.status = phase == "failed" and "Guide import failed." or "Guide import cancelled."
        addon:Notify("RESTEDXP_CHANGED")
        assert(panel.feedback:GetText() == state.status and panel.restedxpImport:IsEnabled()
            and panel.restedxpBattleTag:IsEnabled() and panel.restedxpPaste:IsEnabled()
            and panel.restedxpClearExport:IsEnabled() and Export(panel) == raw
            and panel.restedxpBattleTag:GetText() == "ProgressOwner#1234" and #calls == submitted,
            "native failure or cancellation releases actions and retains the draft for correction or retry")
    end
    assert(#(world.guideSends or {}) == guideSends and #world.dataSends == dataSends and #world.statusSends == statusSends,
        "native progress, completion, failure and reopening initiate no group communication")
end

for _, closeWindow in ipairs({ false, true }) do
    local state = { installed = true, loaded = true, compatible = true, canImport = true }
    local addon, panel, calls = Fixture(state, true)
    local edit = panel.restedxpExport
    panel.restedxpBattleTag:UserInput("SourceOwner#5678")
    edit:Paste("Abandoned|chunk\n")
    edit:AdvanceFrame(0.06)
    if closeWindow then panel.parent.CloseButton:Click() else panel.tabs.chat:Click() end
    assert(Export(panel) == "" and edit:GetText() == "" and not edit.focused and not edit:GetScript("OnUpdate"),
        "leaving the page cancels a focused in-flight paste and clears its temporary buffer")
    assert(not edit:GetScript("OnTextChanged"), "cancelled pastes never enable native text-change processing")
    edit:AdvanceFrame(1)
    addon:OpenOptions("restedxp")
    assert(Export(panel) == "" and edit:GetText() == "" and not panel.restedxpImport:IsEnabled() and #calls == 0,
        "reopening the page cannot restore a cancelled paste")
    panel.restedxpBattleTag:UserInput("SourceOwner#5678")
    Paste(panel, "Fresh+draft==")
    panel.restedxpImport:Click()
    assert(#calls == 1 and calls[1].raw == "Fresh+draft==",
        "a later paste contains no chunks from a previously closed draft")
end

print("PASS: local RestedXP import form, invisible native paste capture, byte counts, remembered source, exact input, native progress, errors and draft privacy")
