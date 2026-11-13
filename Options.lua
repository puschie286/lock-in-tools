local _, addon = ...
local UI = addon.Theme
local WINDOW_POINTS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}
local function ValidWindowPosition(position)
    local function ValidOffset(value)
        return type(value) == "number" and value == value and math.abs(value) <= 100000
    end
    return type(position) == "table" and WINDOW_POINTS[position.point] == true
        and WINDOW_POINTS[position.relativePoint] == true
        and ValidOffset(position.x) and ValidOffset(position.y)
end

function addon:SaveWindowPosition()
    local panel = self.mainPanel
    if not panel then return end
    panel:StopMovingOrSizing()
    panel:SetUserPlaced(false)
    if not self.initialized or self.savedDataReadOnly then return end

    local point, relativeTo, relativePoint, x, y = panel:GetPoint()
    local position = { point = point, relativePoint = relativePoint, x = x, y = y }
    if (relativeTo and relativeTo ~= UIParent) or not ValidWindowPosition(position) then return end
    if type(self.db.windowPosition) ~= "table" then self.db.windowPosition = {} end
    local saved = self.db.windowPosition
    saved.point, saved.relativePoint, saved.x, saved.y = point, relativePoint, x, y
end

local function TrackWindowPosition(panel)
    panel:SetUserPlaced(false)
    panel:HookScript("OnDragStop", function() addon:SaveWindowPosition() end)
    panel:HookScript("OnHide", function() addon:SaveWindowPosition() end)
    panel.windowEvents = addon:RegisterGameEvents({ "PLAYER_LOGOUT" }, addon.SaveWindowPosition)
end

local function SetFeedback(panel, message, isError)
    panel.feedback:SetText(message or "")
    if isError then
        panel.feedback:SetTextColor(1, 0.35, 0.35)
    else
        panel.feedback:SetTextColor(0.4, 1, 0.4)
    end
end

local function HideTooltip(widget)
    if GameTooltip and GameTooltip:IsOwned(widget) then GameTooltip:Hide() end
end

local function OptionTooltip(widget, title, description)
    if widget.SetMotionScriptsWhileDisabled then widget:SetMotionScriptsWhileDisabled(true) end
    widget:HookScript("OnEnter", function()
        if not GameTooltip then return end
        GameTooltip_SetDefaultAnchor(GameTooltip, widget)
        GameTooltip:SetText(title)
        local text = type(description) == "function" and description() or description
        GameTooltip:AddLine(text, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    widget:HookScript("OnLeave", function() HideTooltip(widget) end)
    widget:HookScript("OnHide", function() HideTooltip(widget) end)
end

local function PreferenceLabel(page, checkbox, text, description, width)
    local button = CreateFrame("Button", nil, page)
    button:SetPoint("LEFT", checkbox, "RIGHT", 2, 0)
    button:SetSize(width or 360, 28)
    local label = UI:Label(page, text, 13)
    label:SetPoint("LEFT", button, "LEFT", 0, 0)
    button:SetScript("OnClick", function() if checkbox:IsEnabled() then checkbox:Click() end end)
    hooksecurefunc(checkbox, "SetEnabled", function(_, enabled)
        button:SetEnabled(enabled)
        label:SetAlpha(enabled and 1 or 0.5)
    end)
    checkbox.labelButton = button
    OptionTooltip(checkbox, text, description)
    OptionTooltip(button, text, description)
end

local function CreateView()
    local window = addon.mainPanel
    if not window then
        window = UI:Window("LockInToolsWindow", 720, 550)
        addon.mainPanel = window
        local position = addon.db.windowPosition
        if ValidWindowPosition(position) then
            window:ClearAllPoints()
            window:SetPoint(position.point, UIParent, position.relativePoint, position.x, position.y)
        else
            window:ClearAllPoints()
            window:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end
        TrackWindowPosition(window)
        window:SetScript("OnShow", function() UI:Fit(window) end)
        tinsert(UISpecialFrames, "LockInToolsWindow")
    end
    local panel = CreateFrame("Frame", nil, window)
    panel:SetAllPoints(window)
    panel:Hide()
    return panel
end

local function ShowPanel(panel)
    local window = addon.mainPanel
    if window.currentView then addon:SaveWindowPosition() end
    if window.currentView and window.currentView ~= panel then window.currentView:Hide() end
    window.currentView = panel
    window.TitleText:SetText(panel == addon.optionsPanel and "LockInTools - Settings" or "LockInTools")
    UI:Fit(window)
    panel:Show()
    window:Show()
    window:Raise()
end

local function BindPreference(panel, checkbox, getter, setter)
    checkbox:SetScript("OnClick", function(button)
        local success, message = setter(addon, button:GetChecked() and true or false)
        if not success then button:SetChecked(getter()) end
        SetFeedback(panel, success and "" or (message or "Unable to change this setting."), not success)
    end)
end

local function CreateTransparencyControl(panel, page, prefix, title, getter, setter)
    local help = CreateFrame("Frame", nil, page)
    panel[prefix .. "TransparencyHelp"] = help
    help:SetSize(308, 20)
    help:EnableMouse(true)
    local label = UI:Label(help, title, 12)
    label:SetPoint("TOPLEFT", 0, 0)
    local valueLabel = UI:Label(help, "0%", 12, "muted")
    panel[prefix .. "TransparencyValue"] = valueLabel
    valueLabel:SetPoint("TOPRIGHT", 0, 0)
    local slider = CreateFrame("Slider", nil, page)
    panel[prefix .. "TransparencySlider"] = slider
    slider:SetSize(296, 20)
    slider:SetOrientation("HORIZONTAL")
    slider:EnableMouse(true)
    slider:SetMinMaxValues(0, 100)
    slider:SetValueStep(1)
    if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT", 0, 0)
    track:SetPoint("RIGHT", 0, 0)
    track:SetHeight(4)
    track:SetColorTexture(0.025, 0.035, 0.05, 1)
    local thumb = slider:CreateTexture(nil, "ARTWORK")
    thumb:SetSize(10, 18)
    thumb:SetColorTexture(UI:GetAccentColor())
    slider:SetThumbTexture(thumb)
    local function ShowTransparency(value)
        page.updatingTransparency = true
        slider:SetValue(value)
        valueLabel:SetText(string.format("%d%%", value))
        page.updatingTransparency = nil
    end
    page.RefreshTransparency = function()
        local editable = not addon.savedDataReadOnly
        slider:SetEnabled(editable)
        help:SetAlpha(editable and 1 or 0.5)
        thumb:SetAlpha(editable and 1 or 0.5)
        ShowTransparency(getter())
    end
    slider:SetScript("OnValueChanged", function(widget, value)
        if page.updatingTransparency then return end
        local saved = getter()
        if not widget:IsEnabled() or addon.savedDataReadOnly then ShowTransparency(saved); return end
        value = math.min(100, math.max(0, math.floor(value + 0.5)))
        ShowTransparency(value)
        if value == saved then return end
        local success, message = setter(value)
        ShowTransparency(getter())
        SetFeedback(panel, success and "" or (message or "Unable to change this setting."), not success)
    end)
    return help, slider
end

local function CreateDataControls(panel, page)
    panel.dataChannels = {}
    local heading = UI:Label(page, "Data channels", 14, "heading")
    heading:SetPoint("TOPLEFT", 16, -52)

    local channels = {
        { "guild", "Guild", "Send and receive data with players in your guild." },
        { "friends", "Friends", "Share data with online WoW or Battle.net friends in your Forever realm pool."
            .. " Both players need LockInTools and Friends sharing enabled." },
    }
    for index, entry in ipairs(channels) do
        local channel = entry[1]
        local checkbox = UI:Checkbox(page)
        checkbox:SetPoint("TOPLEFT", 12, -78 - (index - 1) * 30)
        checkbox:SetSize(28, 28)
        panel.dataChannels[channel] = checkbox
        BindPreference(panel, checkbox, function() return addon:GetDataChannelEnabled(channel) end,
            function(_, enabled) return addon:SetDataChannelEnabled(channel, enabled) end)
        PreferenceLabel(page, checkbox, entry[2], entry[3]
            .. " Turning this off stops sending and receiving through this channel.\n\n"
            .. "Changes apply immediately and save across reloads and characters.", 260)
    end
end

local function GuideText(value)
    return tostring(value or ""):gsub("|", "||")
end

local RESTEDXP_APPEARANCE_PREFERENCES = {
    { field = "restedxpSkinEnabled", getter = "IsRestedXPSkinEnabled", setter = "SetRestedXPSkinEnabled",
        label = "Use LockInTools skin",
        description = "Apply the LockInTools theme, flat styling and modern controls." },
    { field = "restedxpChromeHidden", getter = "IsRestedXPChromeHidden", setter = "SetRestedXPChromeHidden",
        label = "Hide header and footer",
        description = "Right-click the scrollbar for guides; use /rxp for settings." },
}

local function CreateRestedXPPage(panel)
    local page = UI:Section(panel, 20, 116, 680, 414, "RestedXP")
    panel.pages.restedxp = page
    panel.restedxpNotice = UI:Label(page, "", 12, "muted")
    panel.restedxpNotice:SetPoint("TOPLEFT", 16, -46)
    panel.restedxpNotice:SetSize(648, 28)

    local exportLabel = UI:Label(page, "Guide export (Player#1234)", 12, "muted")
    exportLabel:SetPoint("TOPLEFT", 16, -80)
    panel.restedxpPaste = UI:Button(page, "Paste export")
    panel.restedxpPaste:SetPoint("TOPLEFT", 16, -100)
    panel.restedxpPaste:SetSize(148, 32)
    -- A focused EditBox is still required for native Ctrl+V. Keep it shown but
    -- transparent, with no visible text or surface; only the byte count is shown.
    panel.restedxpExport = CreateFrame("EditBox", nil, page)
    panel.restedxpExport:SetPoint("TOPLEFT", panel.restedxpPaste, "TOPLEFT", 0, 0)
    panel.restedxpExport:SetFontObject("GameFontHighlight")
    panel.restedxpExport:SetAutoFocus(false)
    panel.restedxpExport:SetMultiLine(true)
    panel.restedxpExport:SetMaxBytes(1)
    panel.restedxpExport:SetSize(1, 1)
    panel.restedxpExport:SetAlpha(0)
    panel.restedxpExport:EnableMouse(false)
    panel.restedxpExportStatus = UI:Label(page, "No export loaded (0 bytes).", 12, "muted")
    panel.restedxpExportStatus:SetPoint("TOPLEFT", 180, -100)
    panel.restedxpExportStatus:SetSize(380, 32)
    panel.restedxpClearExport = UI:Button(page, "Clear")
    panel.restedxpClearExport:SetPoint("TOPLEFT", 572, -100)
    panel.restedxpClearExport:SetSize(92, 32)
    local pasteHint = UI:Label(page, "Click Paste export, then press Ctrl+V. Pasting again replaces the loaded export.", 12, "muted")
    pasteHint:SetPoint("TOPLEFT", 16, -140)
    pasteHint:SetSize(648, 28)

    panel.restedxpImport = UI:Button(page, "Import", "primary")
    panel.restedxpImport:SetPoint("TOPLEFT", 16, -176)
    panel.restedxpImport:SetSize(128, 32)

    for index, preference in ipairs(RESTEDXP_APPEARANCE_PREFERENCES) do
        local getter, setter = preference.getter, preference.setter
        local checkbox = UI:Checkbox(page)
        panel[preference.field] = checkbox
        checkbox:SetPoint("TOPLEFT", 12, -222 - (index - 1) * 32)
        checkbox:SetSize(28, 28)
        BindPreference(panel, checkbox,
            function() return addon[getter](addon) == true end,
            function(_, enabled) return addon[setter](addon, enabled) end)
        PreferenceLabel(page, checkbox, preference.label, preference.description, 276)
    end

    local help, slider = CreateTransparencyControl(panel, page, "restedxp", "Transparency",
        function() return addon:GetRestedXPBackgroundTransparency() end,
        function(value) return addon:SetRestedXPBackgroundTransparency(value) end)
    help:SetPoint("TOPLEFT", 356, -226)
    slider:SetPoint("TOPLEFT", 360, -254)
    local transparencyHelp = "Fade LockInTools theme backgrounds and borders without fading text."
    OptionTooltip(panel.restedxpTransparencyHelp, "Transparency", transparencyHelp)
    OptionTooltip(slider, "Transparency", transparencyHelp)

    local raw, buffer, bufferSize, quietTime, oversized = "", nil, 0, 0, false
    local pending, pendingCount, blockCount = nil, 0, 0
    local maxData, concat = addon.RestedXPCodec.MAX_DATA, table.concat
    local StartPaste
    local function RefreshDraft()
        local hasExport = raw:find("%S") ~= nil
        panel.restedxpImport:SetEnabled(page.canImport and not page.readOnly and not page.busy
            and buffer == nil and hasExport)
        panel.restedxpPaste:SetEnabled(not page.readOnly and not page.busy)
        panel.restedxpClearExport:SetEnabled(not page.readOnly and not page.busy
            and (buffer ~= nil or raw ~= "" or oversized))
    end
    local function ShowExportStatus()
        panel.restedxpExportStatus:SetText(oversized and "Export is larger than 2 MiB. Paste a smaller export."
            or raw ~= "" and string.format("%d bytes loaded.", #raw)
            or "No export loaded (0 bytes).")
    end
    local function FinishPaste()
        if not buffer then return end
        panel.restedxpExport:SetScript("OnUpdate", nil)
        if not oversized then
            if pendingCount > 0 then buffer[blockCount + 1] = concat(pending, "", 1, pendingCount) end
            raw = concat(buffer)
        end
        buffer, bufferSize = nil, 0
        pending, pendingCount, blockCount = nil, 0, 0
        panel.restedxpExport:SetScript("OnChar", StartPaste)
        panel.restedxpExport:ClearFocus()
        ShowExportStatus()
        RefreshDraft()
    end
    panel.restedxpExport:SetScript("OnEscapePressed", function(edit) edit:ClearFocus() end)
    -- Match RestedXP's bulk-paste handling: OnChar receives input beyond the
    -- native byte limit. Keep the export in Lua without rendering its contents;
    -- laying out a multi-megabyte EditBox can crash the client before Import.
    panel.restedxpExport:HookScript("OnEditFocusGained", function(edit)
        edit:SetText("")
        panel.restedxpPaste:SetText("Press Ctrl+V")
    end)
    panel.restedxpExport:HookScript("OnEditFocusLost", function(edit)
        if buffer then FinishPaste() end
        edit:SetText("")
        panel.restedxpPaste:SetText("Paste export")
    end)
    panel.restedxpPaste:SetScript("OnClick", function() panel.restedxpExport:SetFocus() end)
    local function DiscardCharacter()
        quietTime = 0
    end
    -- WoW can deliver one OnChar per pasted character. Keep this hot path free
    -- of widget calls and repeated draft checks, and reuse a small staging array
    -- instead of retaining millions of table entries until the paste completes.
    local function CaptureCharacter(edit, character)
        quietTime, bufferSize = 0, bufferSize + #character
        if bufferSize > maxData then
            oversized, buffer, pending = true, {}, nil
            pendingCount, blockCount = 0, 0
            edit:SetScript("OnChar", DiscardCharacter)
            return
        end
        pendingCount = pendingCount + 1
        pending[pendingCount] = character
        if pendingCount == 4096 then
            blockCount = blockCount + 1
            buffer[blockCount] = concat(pending, "", 1, pendingCount)
            pendingCount = 0
        end
    end
    StartPaste = function(edit, character)
        if page.readOnly or page.busy or type(character) ~= "string" or character == "" then return end
        raw, buffer, bufferSize, oversized, page.actionError = "", {}, 0, false, nil
        pending, pendingCount, blockCount = {}, 0, 0
        panel.restedxpExportStatus:SetText("Receiving export...")
        RefreshDraft()
        edit:SetScript("OnChar", CaptureCharacter)
        edit:SetScript("OnUpdate", function(_, elapsed)
            quietTime = quietTime + elapsed
            if quietTime >= 0.1 then FinishPaste() end
        end)
        CaptureCharacter(edit, character)
    end
    panel.restedxpExport:SetScript("OnChar", StartPaste)
    local function ClearExport()
        panel.restedxpExport:SetScript("OnUpdate", nil)
        raw, buffer, bufferSize, oversized = "", nil, 0, false
        pending, pendingCount, blockCount = nil, 0, 0
        panel.restedxpExport:SetScript("OnChar", StartPaste)
        panel.restedxpExport:ClearFocus()
        panel.restedxpExport:SetText("")
        ShowExportStatus()
        RefreshDraft()
    end
    panel.restedxpClearExport:SetScript("OnClick", ClearExport)
    page.RefreshDraft = RefreshDraft
    page.GetExport = function() return raw end
    panel.restedxpImport:SetScript("OnClick", function()
        if buffer then return end
        local success, message = addon:ImportRestedXPString(raw)
        page.actionError = not success and (message or "Unable to import this RestedXP string.") or nil
        addon:RefreshOptions()
    end)
    page:SetScript("OnHide", function() page.actionError = nil; ClearExport() end)
    RefreshDraft()
end

local function RefreshRestedXP(panel)
    local page = panel.pages.restedxp
    if not page or not page:IsVisible() then return end
    local state = addon:GetRestedXPState()
    page.readOnly, page.busy, page.canImport = addon.savedDataReadOnly or state.readOnly, state.busy, state.canImport == true
    local notice = not state.installed and "RestedXP is required. Install and enable RestedXP to import guides."
        or state.problem or (not state.loaded and "Enable RestedXP to import guides.") or ""
    panel.restedxpNotice:SetText(GuideText(notice))
    for _, preference in ipairs(RESTEDXP_APPEARANCE_PREFERENCES) do
        panel[preference.field]:SetChecked(addon[preference.getter](addon) == true)
        panel[preference.field]:SetEnabled(not addon.savedDataReadOnly)
    end
    page.RefreshTransparency()
    panel.restedxpExport:SetEnabled(not page.readOnly and not page.busy)
    page.RefreshDraft()
    SetFeedback(panel, page.actionError or state.status, page.actionError ~= nil or state.error == true)
end


local function CreateOptionsPanel()
    local panel = CreateView()
    panel.tabs, panel.pages = {}, {}
    local sharing = UI:Section(panel, 20, 116, 680, 414, "General")
    panel.pages.sharing = sharing
    CreateDataControls(panel, sharing)

    local rankingHeading = UI:Label(sharing, "Player ranking", 14, "heading")
    rankingHeading:SetPoint("TOPLEFT", 16, -174)

    panel.rankingEnabled = UI:Checkbox(sharing)
    panel.rankingEnabled:SetPoint("TOPLEFT", 12, -200)
    panel.rankingEnabled:SetSize(28, 28)
    BindPreference(panel, panel.rankingEnabled, function() return addon:GetRankingSettings().enabled end,
        addon.SetRankingEnabled)
    PreferenceLabel(sharing, panel.rankingEnabled, "Show ranking overlay",
        "Show the top five characters, plus your own rank when outside the top five.\n\n"
            .. "This preference saves across reloads and characters.", 260)

    panel.rankingHideInCombat = UI:Checkbox(sharing)
    panel.rankingHideInCombat:SetPoint("TOPLEFT", 12, -236)
    panel.rankingHideInCombat:SetSize(28, 28)
    BindPreference(panel, panel.rankingHideInCombat, function() return addon:GetRankingSettings().hideInCombat end,
        addon.SetRankingHideInCombat)
    PreferenceLabel(sharing, panel.rankingHideInCombat, "Hide ranking overlay in combat",
        "Temporarily hide the overlay while you are in combat. It returns after combat if enabled.\n\n"
            .. "This preference saves across reloads and characters.", 260)

    panel.rankingBurningEffect = UI:Checkbox(sharing)
    panel.rankingBurningEffect:SetPoint("TOPLEFT", 12, -272)
    panel.rankingBurningEffect:SetSize(28, 28)
    BindPreference(panel, panel.rankingBurningEffect, function() return addon:GetRankingSettings().burningEffect end,
        addon.SetRankingBurningEffect)
    PreferenceLabel(sharing, panel.rankingBurningEffect, "Enable burning effect",
        "Add bright glow and animated flames to both burned meters at 70% and above. Turn this off to hide the effect.\n\n"
            .. "This preference saves across reloads and characters.", 260)

    local help, slider = CreateTransparencyControl(panel, sharing, "ranking", "Background transparency",
        function() return addon:GetRankingSettings().backgroundTransparency or 0 end,
        function(value) return addon:SetRankingBackgroundTransparency(value) end)
    help:SetPoint("TOPLEFT", 16, -316)
    slider:SetPoint("TOPLEFT", 20, -344)
    local transparencyHelp = "Fade the ranking overlay's background and border while keeping player rows and meters readable.\n\n"
        .. "Changes apply immediately and save across reloads and characters."
    OptionTooltip(panel.rankingTransparencyHelp, "Background transparency", transparencyHelp)
    OptionTooltip(slider, "Background transparency", transparencyHelp)

    local playerDataHeading = UI:Label(sharing, "Player data", 14, "heading")
    playerDataHeading:SetPoint("TOPLEFT", 356, -52)

    panel.playerDataCleanup = UI:Checkbox(sharing)
    panel.playerDataCleanup:SetPoint("TOPLEFT", 352, -78)
    panel.playerDataCleanup:SetSize(28, 28)
    BindPreference(panel, panel.playerDataCleanup, function() return addon:GetPlayerDataCleanupEnabled() end,
        addon.SetPlayerDataCleanupEnabled)
    PreferenceLabel(sharing, panel.playerDataCleanup, "Remove player data after 10 days",
        "Remove history for players not seen for 10 days. Enabled by default.\n\n"
            .. "Enabling this cleans up now; cleanup also runs periodically. This preference saves across reloads and characters.", 260)

    panel.clearPlayerData = UI:Button(sharing, "Clear all player data", "danger")
    panel.clearPlayerData:SetPoint("TOPLEFT", 356, -122)
    panel.clearPlayerData:SetSize(188, 32)
    local function ResetPlayerDataConfirmation()
        panel.confirmClearPlayerData = false
        panel.clearPlayerData:SetText("Clear all player data")
    end
    panel.clearPlayerData:SetScript("OnClick", function()
        if addon.savedDataReadOnly then
            SetFeedback(panel, "Update LockInTools before changing saved preferences.", true)
            return
        end
        if not panel.confirmClearPlayerData then
            panel.confirmClearPlayerData = true
            panel.clearPlayerData:SetText("Confirm clear")
            SetFeedback(panel, "Click Confirm clear to remove all saved player history.", true)
            return
        end
        local success, message = addon:ClearPlayerData()
        ResetPlayerDataConfirmation()
        SetFeedback(panel, success and "Player data cleared. Active players can appear again as updates arrive."
            or (message or "Unable to clear player data."), not success)
    end)
    OptionTooltip(panel.clearPlayerData, "Clear all player data",
        "Remove all cached player history. Confirmation is required.\n\n"
            .. "Active players can appear again through fresh updates, and your current character remains visible. "
            .. "Your preferences and personal Burned status stay saved.")
    sharing:SetScript("OnHide", ResetPlayerDataConfirmation)

    CreateRestedXPPage(panel)

    for _, page in pairs(panel.pages) do
        page.feedback = UI:Label(page, "", 13)
        page.feedback:SetPoint("BOTTOMLEFT", 16, 16)
        page.feedback:SetSize(648, 26)
    end

    local function SelectTab(name)
        -- Keep existing callers of the former pages opening the combined controls.
        if name == "position" or name == "data" or name == "ranking" or name == "playerData" then name = "sharing" end
        if not panel.pages[name] then return end
        if panel.selectedTab == name then return end
        panel.selectedTab = name
        panel.feedback = panel.pages[name].feedback
        for category, page in pairs(panel.pages) do
            if category == name then page:Show() else page:Hide() end
            UI:SetTabSelected(panel.tabs[category], category == name)
        end
        SetFeedback(panel)
        addon:RefreshOptions()
    end
    panel.SelectTab = SelectTab
    local categories = { { "sharing", "General", 104 }, { "restedxp", "RestedXP", 110 } }
    local tabX = 20
    for _, category in ipairs(categories) do
        local name = category[1]
        local tab = UI:Button(panel, category[2], "tab")
        tab:SetPoint("TOPLEFT", tabX, -66)
        tab:SetSize(category[3], 34)
        tab:SetScript("OnClick", function() SelectTab(name) end)
        panel.tabs[name] = tab
        tabX = tabX + category[3] + 10
    end
    SelectTab("sharing")

    panel.content = UI:Button(panel, "Content")
    panel.content:SetPoint("TOPRIGHT", -54, -12)
    panel.content:SetSize(110, 32)
    panel.content:SetScript("OnClick", function() addon:OpenContent() end)

    panel:SetScript("OnShow", function()
        SetFeedback(panel)
        addon:RefreshOptions()
    end)
    return panel
end

function addon:RefreshOptions()
    local panel = self.optionsPanel
    if not panel or not panel:IsVisible() or not self.initialized then
        return
    end

    local editable = not self.savedDataReadOnly
    panel.playerDataCleanup:SetChecked(self:GetPlayerDataCleanupEnabled())
    panel.playerDataCleanup:SetEnabled(editable)
    panel.clearPlayerData:SetEnabled(editable)
    for channel, checkbox in pairs(panel.dataChannels) do
        checkbox:SetChecked(self:GetDataChannelEnabled(channel))
        checkbox:SetEnabled(editable)
    end
    local ranking = self:GetRankingSettings()
    panel.rankingEnabled:SetChecked(ranking.enabled and not self.rankingOverlayDismissed)
    panel.rankingEnabled:SetEnabled(editable)
    panel.rankingHideInCombat:SetChecked(ranking.hideInCombat)
    panel.rankingHideInCombat:SetEnabled(editable)
    panel.rankingBurningEffect:SetChecked(ranking.burningEffect)
    panel.rankingBurningEffect:SetEnabled(editable)
    panel.pages.sharing.RefreshTransparency()
    RefreshRestedXP(panel)
    if not editable then
        SetFeedback(panel, "Update LockInTools before changing saved preferences.", true)
    end
end

function addon:OpenOptions(category)
    if category == "overview" then self:OpenOverview(); return end
    if not self.initialized then
        self:Print("Still loading. Please try again after login.")
        return
    end

    if not self.optionsPanel then
        self.optionsPanel = CreateOptionsPanel()
    end

    if category then self.optionsPanel.SelectTab(category) end
    ShowPanel(self.optionsPanel)
end

local function RefreshContentFeedback(panel)
    if addon.savedDataReadOnly then
        SetFeedback(panel, "Update LockInTools before changing saved preferences.", true)
    end
end

local function CreateContentPanel()
    local panel = CreateView()
    panel.tabs, panel.pages = {}, {}
    addon:CreateOverviewPage(panel)
    addon:CreateFriendsPage(panel)

    panel.SelectTab = function(name)
        local page, previous = panel.pages[name], panel.selectedTab
        if not page or previous == name then return end
        if previous then
            panel.pages[previous]:Hide()
            UI:SetTabSelected(panel.tabs[previous], false)
        end
        panel.selectedTab, panel.feedback = name, page.feedback
        SetFeedback(panel)
        RefreshContentFeedback(panel)
        UI:SetTabSelected(panel.tabs[name], true)
        page:Show()
    end
    for index, entry in ipairs({ { "overview", "Rankings" }, { "friends", "Friends" } }) do
        local name = entry[1]
        local tab = UI:Button(panel, entry[2], "tab")
        tab:SetPoint("TOPLEFT", 20 + (index - 1) * 140, -66)
        tab:SetSize(130, 34)
        tab:SetScript("OnClick", function() panel.SelectTab(name) end)
        panel.tabs[name] = tab
        panel.pages[name]:Hide()
    end
    panel.SelectTab("overview")

    panel.options = UI:Button(panel, "Settings")
    panel.options:SetPoint("TOPRIGHT", -54, -12)
    panel.options:SetSize(110, 32)
    panel.options:SetScript("OnClick", function() addon:OpenOptions() end)

    panel:SetScript("OnShow", function()
        SetFeedback(panel)
        RefreshContentFeedback(panel)
    end)
    return panel
end

function addon:RefreshContent()
    local panel = self.contentPanel
    if not panel or not self.initialized then return end
    if panel.selectedTab == "friends" then self:RefreshFriends() else self:RefreshOverview() end
    RefreshContentFeedback(panel)
end

function addon:OpenContent(tab)
    if not self.initialized then
        self:Print("Still loading. Please try again after login.")
        return
    end

    if not self.contentPanel then self.contentPanel = CreateContentPanel() end
    if tab then self.contentPanel.SelectTab(tab) end
    ShowPanel(self.contentPanel)
    self:RefreshContent()
    if not self.savedDataReadOnly then
        self.db.setupComplete = true
    end
end

-- Keep the old command/API entry point without retaining a separate welcome view.
function addon:OpenWelcome()
    self:OpenContent()
end

for _, notification in ipairs({ "DATA_CHANGED", "RESTEDXP_CHANGED", "RESTEDXP_SKIN_CHANGED", "RANKING_CHANGED" }) do
    addon:RegisterNotification(notification, function() addon:RefreshOptions() end)
end
