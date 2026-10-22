local support = dofile("tests/support/addon.lua")
local loadOptions = dofile("tests/support/ui.lua")

local function Fixture(state, skin)
    local addon, environment, _, _, world = support.loadAddon({ schemaVersion = 3,
        showWelcome = false, chat = { autoJoin = false } }, false)
    world:initialize()
    local calls, getState = {}, addon.GetRestedXPState
    function addon:GetRestedXPState()
        state.sourceBattleTag = getState(self).sourceBattleTag
        return state
    end
    function addon:ImportRestedXPString(raw, source)
        calls[#calls + 1] = { raw = raw, source = source }
        return not calls.importError, calls.importError
    end
    if skin then
        function addon:GetRestedXPSkinState() return skin end
        for _, preference in ipairs({
            { "enabled", "IsRestedXPSkinEnabled", "SetRestedXPSkinEnabled", "skinChanges" },
            { "chromeHidden", "IsRestedXPChromeHidden", "SetRestedXPChromeHidden", "chromeChanges" },
        }) do
            local field, getter, setter, changes = unpack(preference)
            calls[changes] = {}
            addon[getter] = function() return skin[field] == true end
            addon[setter] = function(self, enabled)
                calls[changes][#calls[changes] + 1] = enabled
                if calls.skinError then return false, calls.skinError end
                skin[field] = enabled
                self:Notify("RESTEDXP_SKIN_CHANGED")
                return true
            end
        end
        calls.transparencyChanges = {}
        function addon:GetRestedXPBackgroundTransparency() return skin.backgroundTransparency or 0 end
        function addon:SetRestedXPBackgroundTransparency(value)
            calls.transparencyChanges[#calls.transparencyChanges + 1] = value
            if calls.skinError then return false, calls.skinError end
            skin.backgroundTransparency = value
            self:Notify("RESTEDXP_SKIN_CHANGED")
            return true
        end
    end
    loadOptions(addon, environment)
    addon:OpenOptions("restedxp")
    return addon, addon.optionsPanel, calls, environment, world
end

local function Export(panel) return panel.pages.restedxp.GetExport() end
local function Paste(panel, raw)
    panel.restedxpExport:Paste(raw)
    panel.restedxpExport:AdvanceFrame(0.11)
end

local function AssertPrivate(panel, snippet)
    local function Inspect(widget, alpha)
        alpha = alpha * (widget.alpha or 1)
        if widget:IsVisible() and alpha > 0 then
            assert(not widget:GetText():find(snippet, 1, true), "guide contents must never be visible")
        end
        for _, child in ipairs(widget.children) do Inspect(child, alpha) end
    end
    Inspect(panel.parent, 1)
end

-- One form lifecycle covers availability, remembered input, retry and busy state.
do
    local state = { installed = false, loaded = false, canImport = false }
    local addon, panel, calls, environment, world = Fixture(state)
    local guideSends, dataSends, statusSends = #world.guideSends, #world.dataSends, #world.statusSends
    assert(not addon:HasGroup() and not panel.restedxpImport:IsEnabled())
    panel.restedxpBattleTag:UserInput("  UnfinishedOwner#  ")
    assert(addon.db.restedxp.sourceBattleTag == "  UnfinishedOwner#  " and #calls == 0)
    panel.tabs.sharing:Click()
    panel.tabs.restedxp:Click()
    assert(panel.restedxpBattleTag:GetText() == "  UnfinishedOwner#  " and Export(panel) == "")
    panel.restedxpBattleTag:UserInput("")
    assert(addon.db.restedxp == nil, "deleting the source clears its preference")
    state.installed, state.loaded, state.compatible, state.canImport = true, true, true, true
    addon:Notify("RESTEDXP_CHANGED")
    local raw = "Private+CaseSensitive/Export=="
    Paste(panel, raw)
    assert(not panel.restedxpImport:IsEnabled(), "an export still requires a source")
    panel.restedxpBattleTag:UserInput("SourceOwner#5678")
    calls.importError = "conversion failed"
    panel.restedxpImport:Click()
    assert(#calls == 1 and calls[1].raw == raw and calls[1].source == "SourceOwner#5678"
        and Export(panel) == raw and panel.restedxpImport:IsEnabled(), "rejection retains the exact draft")
    calls.importError = nil
    panel.restedxpImport:Click()
    state.busy, state.canImport = true, false
    addon:Notify("RESTEDXP_CHANGED")
    assert(not panel.restedxpImport:IsEnabled() and not panel.restedxpBattleTag:IsEnabled()
        and not panel.restedxpPaste:IsEnabled() and not panel.restedxpClearExport:IsEnabled())
    panel.restedxpImport:Click()
    assert(#calls == 2 and Export(panel) == raw, "busy imports cannot be submitted again")
    state.busy, state.canImport, state.error = false, true, true
    addon:Notify("RESTEDXP_CHANGED")
    assert(panel.restedxpImport:IsEnabled() and Export(panel) == raw, "failure permits retry")
    assert(addon:SetRestedXPSourceBattleTag("ChangedOwner#5555"))
    addon:Notify("RESTEDXP_CHANGED")
    assert(panel.restedxpBattleTag:GetText() == "SourceOwner#5678" and Export(panel) == raw,
        "backend preference changes cannot replace a visible draft")
    panel.parent.CloseButton:Click()
    assert(Export(panel) == "" and panel.restedxpExport:GetText() == "")
    addon:OpenOptions("restedxp")
    assert(panel.restedxpBattleTag:GetText() == "ChangedOwner#5555" and Export(panel) == "")
    local function ContainsDraft(value)
        if type(value) ~= "table" then return value == raw end
        for _, child in pairs(value) do if ContainsDraft(child) then return true end end
        return false
    end
    assert(not ContainsDraft(environment.LockInToolsDB), "only the source preference is persisted")
    assert(#world.guideSends == guideSends and #world.dataSends == dataSends and #world.statusSends == statusSends,
        "local imports initiate no group communication")
end

-- Skin preferences stay independent of native guide availability and import work.
do
    local state = { installed = false, loaded = false, canImport = false }
    local skin = { enabled = false, available = false, status = "RestedXP is not loaded." }
    local addon, panel, calls = Fixture(state, skin)
    local checkbox = panel.restedxpSkinEnabled
    local chrome = panel.restedxpChromeHidden
    for _, control in ipairs({ checkbox, chrome }) do
        assert(control:IsEnabled() and control.labelButton:IsEnabled() and not control:GetChecked(),
            "appearance preferences default off and can be configured before RestedXP is available")
    end
    chrome.labelButton:Click()
    assert(skin.chromeHidden and not skin.enabled and calls.chromeChanges[1] == true,
        "header visibility remains independent of the combined skin preference")
    checkbox:Click()
    assert(skin.enabled and checkbox:GetChecked() and calls.skinChanges[1] == true)
    panel.restedxpBattleTag:UserInput("SourceOwner#5678")
    Paste(panel, "Retained+draft==")
    state.installed, state.loaded, state.busy = true, true, true
    skin.available, skin.pending, skin.status = true, true, "The appearance will update after combat."
    addon:Notify("RESTEDXP_SKIN_CHANGED")
    assert(checkbox:IsEnabled() and checkbox.labelButton:IsEnabled() and chrome:IsEnabled()
        and not panel.restedxpImport:IsEnabled()
        and panel.restedxpSkinStatus:GetText() == skin.status,
        "skin state updates independently while native imports are busy")
    checkbox.labelButton:Click()
    chrome:Click()
    assert(not skin.enabled and not checkbox:GetChecked() and calls.skinChanges[2] == false
        and not skin.chromeHidden and not chrome:GetChecked() and calls.chromeChanges[2] == false
        and Export(panel) == "Retained+draft==" and panel.restedxpBattleTag:GetText() == "SourceOwner#5678",
        "all appearance preferences remain independent during imports and preserve the draft")
    calls.skinError = "The saved preference could not be changed."
    for _, control in ipairs({ checkbox, chrome }) do
        control:Click()
        assert(not control:GetChecked() and panel.feedback:GetText() == calls.skinError,
            "rejected appearance changes restore the saved value and explain the failure")
    end
    skin.enabled, skin.active, skin.pending, skin.status = true, true, false, "The appearance is active."
    skin.chromeHidden = true
    addon:Notify("RESTEDXP_SKIN_CHANGED")
    assert(checkbox:GetChecked() and chrome:GetChecked()
        and panel.restedxpSkinStatus:GetText() == skin.status,
        "external appearance changes refresh every visible preference and status")
end

do
    local state = { installed = false, loaded = false, canImport = false }
    local skin = {}
    local addon, panel, calls = Fixture(state, skin)
    local slider = panel.restedxpTransparencySlider
    assert(slider:IsEnabled() and slider:GetValue() == 0 and #calls.transparencyChanges == 0,
        "transparency defaults to zero and remains configurable without RestedXP")
    addon:RefreshOptions()
    addon:Notify("RESTEDXP_SKIN_CHANGED")
    assert(#calls.transparencyChanges == 0, "programmatic slider refreshes never write a preference")
    slider:SetValue(24.6)
    assert(slider:GetValue() == 25 and skin.backgroundTransparency == 25
        and calls.transparencyChanges[1] == 25 and #calls.transparencyChanges == 1
        and not skin.enabled and not skin.chromeHidden,
        "the slider rounds to whole percentages and applies independently without recursion")
    slider:SetValue(25.2)
    assert(slider:GetValue() == 25 and #calls.transparencyChanges == 1,
        "rounding back to the saved percentage does not repeat the write")
    slider:SetValue(104)
    assert(slider:GetValue() == 100 and skin.backgroundTransparency == 100)
    slider:SetValue(-4)
    assert(slider:GetValue() == 0 and skin.backgroundTransparency == 0, "slider input stays within zero to one hundred")
    panel.restedxpBattleTag:UserInput("SourceOwner#5678")
    Paste(panel, "Retained+opacity+draft==")
    state.busy = true
    addon:Notify("RESTEDXP_CHANGED")
    slider:SetValue(40)
    assert(slider:IsEnabled() and skin.backgroundTransparency == 40
        and Export(panel) == "Retained+opacity+draft==" and panel.restedxpBattleTag:GetText() == "SourceOwner#5678",
        "busy native imports cannot disable transparency changes or lose their draft")
    calls.skinError = "The saved preference could not be changed."
    slider:SetValue(60)
    assert(slider:GetValue() == 40 and skin.backgroundTransparency == 40 and panel.feedback:GetText() == calls.skinError,
        "rejected transparency changes restore the saved value and explain the failure")
    local writes = #calls.transparencyChanges
    skin.backgroundTransparency = 82
    addon:Notify("RESTEDXP_SKIN_CHANGED")
    assert(slider:GetValue() == 82 and #calls.transparencyChanges == writes,
        "external transparency changes update the slider without writing back")
end

do
    local futureSource = { sourceBattleTag = "FutureOwner#1234", futureField = "keep" }
    local future = { schemaVersion = 4, showWelcome = false, restedxp = futureSource }
    local addon, environment, _, _, world = support.loadAddon(future, false)
    world:initialize()
    local skinChanges = 0
    function addon:IsRestedXPSkinEnabled() return true end
    function addon:GetRestedXPSkinState() return { enabled = true } end
    function addon:SetRestedXPSkinEnabled() skinChanges = skinChanges + 1; return true end
    addon.IsRestedXPChromeHidden = addon.IsRestedXPSkinEnabled
    addon.SetRestedXPChromeHidden = addon.SetRestedXPSkinEnabled
    function addon:GetRestedXPBackgroundTransparency() return 61 end
    function addon:SetRestedXPBackgroundTransparency() skinChanges = skinChanges + 1; return true end
    loadOptions(addon, environment)
    addon:OpenOptions("restedxp")
    local panel = addon.optionsPanel
    assert(addon.savedDataReadOnly and not panel.restedxpBattleTag:IsEnabled()
        and not panel.restedxpImport:IsEnabled() and not panel.restedxpPaste:IsEnabled()
        and not panel.restedxpClearExport:IsEnabled())
    for _, control in ipairs({ panel.restedxpSkinEnabled, panel.restedxpChromeHidden }) do
        assert(control:GetChecked() and not control:IsEnabled() and not control.labelButton:IsEnabled())
        control:Click()
        control.labelButton:Click()
    end
    assert(not panel.restedxpTransparencySlider:IsEnabled() and panel.restedxpTransparencySlider:GetValue() == 61)
    panel.restedxpTransparencySlider:SetValue(12)
    assert(panel.restedxpTransparencySlider:GetValue() == 61, "read-only transparency stays at the saved value")
    assert(skinChanges == 0, "read-only skin controls cannot change saved preferences")
    panel.parent.CloseButton:Click()
    world.fire("PLAYER_LOGOUT")
    assert(environment.LockInToolsDB == future and future.restedxp == futureSource
        and futureSource.sourceBattleTag == "FutureOwner#1234" and futureSource.futureField == "keep",
        "newer-schema settings remain untouched by the form and logout cleanup")
end

do
    local _, panel, calls = Fixture({ installed = true, loaded = true, compatible = true, canImport = true })
    local edit = panel.restedxpExport
    panel.restedxpBattleTag:UserInput("SourceOwner#5678")
    panel.restedxpPaste:Click()
    assert(edit.focused and edit.alpha == 0 and edit:GetMaxBytes() == 1)
    edit:Paste("First|chunk\r\n")
    edit:AdvanceFrame(0.06)
    edit:Paste("Second\tchunk")
    edit:AdvanceFrame(0.06)
    panel.restedxpImport:Click()
    assert(Export(panel) == "" and not panel.restedxpImport:IsEnabled() and #calls == 0,
        "clipboard chunks restart the settling delay and cannot be submitted early")
    edit:AdvanceFrame(0.05)
    assert(Export(panel) == "First|chunk\r\nSecond\tchunk" and edit:GetText() == "")
    AssertPrivate(panel, "First|chunk")
    local raw = "UNIQUE_PRIVATE_EXPORT|cFFFF0000|Hguide:123|hPrivate guide|h|r\r\n\tUTF8=\195\169\228\184\173=="
    local originalSetText = edit.SetText
    function edit:SetText(text)
        assert(text == "", "guide contents must never be copied into native text storage")
        return originalSetText(self, text)
    end
    edit:Paste(raw, #raw)
    AssertPrivate(panel, "UNIQUE_PRIVATE_EXPORT")
    edit:ClearFocus()
    assert(Export(panel) == raw and edit:GetText() == "" and not edit:GetScript("OnUpdate"))
    AssertPrivate(panel, "Private guide")
    panel.restedxpImport:Click()
    assert(#calls == 1 and calls[1].raw == raw, "focus loss submits exact literal bytes")
    panel.restedxpClearExport:Click()
    assert(Export(panel) == "" and not panel.restedxpImport:IsEnabled()
        and panel.restedxpBattleTag:GetText() == "SourceOwner#5678")
    edit:Paste("Abandoned|chunk\n")
    panel.restedxpClearExport:Click()
    edit:AdvanceFrame(1)
    assert(Export(panel) == "" and not edit.focused and not edit:GetScript("OnUpdate"),
        "Clear also cancels an unsettled paste")
    Paste(panel, "Fresh+replacement==")
    panel.restedxpImport:Click()
    assert(#calls == 2 and calls[2].raw == "Fresh+replacement==")
end

-- A newline-heavy maximum export exercises rendering cost and bounded storage.
do
    local maximum = 2 * 1024 * 1024
    local _, panel, calls = Fixture({ installed = true, loaded = true, compatible = true, canImport = true })
    local edit = panel.restedxpExport
    panel.restedxpBattleTag:UserInput("SourceOwner#5678")
    function edit:GetNumLines() error("bulk paste must not measure the native EditBox") end
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
    local raw = "A" .. string.rep("\n", maximum - 2) .. "B"
    edit:Paste(raw:sub(1, 1))
    local initialCalls = widgetCalls
    edit:Paste(raw:sub(2))
    assert(widgetCalls == initialCalls and not edit:GetScript("OnTextChanged"),
        "millions of character callbacks do not repeat widget work")
    edit:AdvanceFrame(0.11)
    assert(Export(panel) == raw and edit:GetText() == "" and edit.maxNativeTextBytes <= 1)
    panel.restedxpImport:Click()
    assert(#calls == 1 and calls[1].raw == raw, "the byte limit itself remains importable")
    edit:Paste(string.rep("E", maximum - 1), maximum)
    edit:Paste("\195\169", 2)
    local rejectedCalls = widgetCalls
    edit:Paste(string.rep("Z", 32768))
    assert(widgetCalls == rejectedCalls, "overflow discards further bytes without repeated native work")
    edit:AdvanceFrame(0.11)
    assert(Export(panel) == "" and not panel.restedxpImport:IsEnabled() and edit.maxNativeTextBytes <= 1,
        "a multibyte callback crossing the limit rejects the whole draft")
    panel.restedxpImport:Click()
    assert(#calls == 1)
    local replacement = string.rep("Ab|CD\r\n\t09+/", 700) .. "Tail=\195\169"
    Paste(panel, replacement)
    assert(Export(panel) == replacement, "a retry preserves order across staging blocks and the partial tail")
    Paste(panel, "x")
    panel.restedxpImport:Click()
    assert(#calls == 2 and calls[2].raw == "x", "short replacements contain no stale staging bytes")
    Paste(panel, " \r\n\t ")
    assert(not panel.restedxpImport:IsEnabled())
end

for _, closeWindow in ipairs({ false, true }) do
    local addon, panel, calls = Fixture({ installed = true, loaded = true, compatible = true, canImport = true })
    local edit = panel.restedxpExport
    panel.restedxpBattleTag:UserInput("SourceOwner#5678")
    edit:Paste("Abandoned|chunk\n")
    edit:AdvanceFrame(0.06)
    if closeWindow then panel.parent.CloseButton:Click() else panel.tabs.sharing:Click() end
    assert(Export(panel) == "" and edit:GetText() == "" and not edit.focused and not edit:GetScript("OnUpdate"),
        "leaving the page cancels an in-flight paste")
    edit:AdvanceFrame(1)
    addon:OpenOptions("restedxp")
    assert(Export(panel) == "" and not panel.restedxpImport:IsEnabled() and #calls == 0)
    Paste(panel, "Fresh+draft==")
    panel.restedxpImport:Click()
    assert(#calls == 1 and calls[1].raw == "Fresh+draft==", "reopening cannot revive discarded chunks")
end

print("PASS: local RestedXP form, independent skin preference, buffered paste, size limits and privacy")
