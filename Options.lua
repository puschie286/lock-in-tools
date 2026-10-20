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

local function HidePageTooltips(page)
    for _, widget in ipairs(page.tooltipOwners or {}) do HideTooltip(widget) end
end

local function OptionTooltip(page, widget, title, description)
    page.tooltipOwners = page.tooltipOwners or {}
    page.tooltipOwners[#page.tooltipOwners + 1] = widget
    if widget.SetMotionScriptsWhileDisabled then widget:SetMotionScriptsWhileDisabled(true) end
    widget:HookScript("OnEnter", function()
        if not GameTooltip then return end
        GameTooltip:SetOwner(widget, "ANCHOR_RIGHT")
        GameTooltip:SetText(title)
        local text = type(description) == "function" and description() or description
        GameTooltip:AddLine(text, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    widget:HookScript("OnLeave", function() HideTooltip(widget) end)
    widget:HookScript("OnHide", function() HideTooltip(widget) end)
end

local function PreferenceLabel(page, checkbox, text, description)
    local button = CreateFrame("Button", nil, page)
    button:SetPoint("LEFT", checkbox, "RIGHT", 2, 0)
    button:SetSize(360, 28)
    local label = UI:Label(page, text, 13)
    label:SetPoint("LEFT", button, "LEFT", 0, 0)
    button:SetScript("OnClick", function() if checkbox:IsEnabled() then checkbox:Click() end end)
    hooksecurefunc(checkbox, "SetEnabled", function(_, enabled)
        button:SetEnabled(enabled)
        label:SetAlpha(enabled and 1 or 0.5)
    end)
    checkbox.labelButton = button
    OptionTooltip(page, checkbox, text, description)
    OptionTooltip(page, button, text, description)
end

local function RefreshKeyAction(panel)
    local hasDraft = panel.secret:GetText():find("%S") ~= nil
    local editable = not addon.savedDataReadOnly
    panel.applyGroup:SetEnabled(editable and hasDraft)
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
    panel.themeOwner = window
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

local function ResetConfirmation(panel)
    panel.pendingSecret = nil
    panel.confirmLeave = false
    panel.applyGroup:SetText("Use key")
    panel.leaveGroup:SetText("Leave group")
end

local function ClearKeyDraft(panel)
    panel.secret:ClearFocus()
    panel.secret:SetText("")
end

local function ClearGroupKeys(panel)
    HidePageTooltips(panel.pages.group)
    ClearKeyDraft(panel)
    panel.pages.group.showingKeys = false
    panel.ownSecret:SetText("")
    panel.ownSecret:ClearFocus()
    ResetConfirmation(panel)
end

local function ApplyGroup(panel)
    local secret = panel.secret:GetText():match("^%s*(.-)%s*$")
    if secret:match("^%s*$") then
        SetFeedback(panel, "Enter a group key first.", true)
        return
    end

    if addon:HasGroup() and secret:lower() ~= addon:GetGroupSecret():lower()
        and panel.pendingSecret ~= secret then
        ResetConfirmation(panel)
        panel.pendingSecret = secret
        panel.applyGroup:SetText("Confirm switch")
        SetFeedback(panel, "Click Confirm switch to change your group for all LockInTools features.", true)
        return
    end

    local success, message = addon:SetGroupSecret(secret)
    if not success then
        ResetConfirmation(panel)
        SetFeedback(panel, message or "Unable to save the group key.", true)
        return
    end

    ResetConfirmation(panel)
    ClearKeyDraft(panel)
    SetFeedback(panel, "Group saved.", false)
end

local function BindPreference(panel, checkbox, getter, setter)
    checkbox:SetScript("OnClick", function(button)
        local success, message = setter(addon, button:GetChecked() and true or false)
        if not success then button:SetChecked(getter()) end
        SetFeedback(panel, success and "" or (message or "Unable to change this setting."), not success)
    end)
end

local function GuideText(value)
    return tostring(value or ""):gsub("|", "||")
end

local function RestedXPList(parent, y, count, rowHeight, makeRow, render)
    local list = CreateFrame("Frame", nil, parent)
    list.themeOwner = parent.themeOwner
    list:SetPoint("TOPLEFT", 16, -y)
    list:SetSize(648, count * rowHeight)
    list.offset, list.rows = 0, {}
    list.empty = UI:Label(list, "", 12, "muted")
    list.empty:SetPoint("TOPLEFT", 0, -4)
    list.empty:SetSize(616, rowHeight * count)
    for index = 1, count do
        local row = CreateFrame("Frame", nil, list)
        row.themeOwner = list.themeOwner
        row:SetPoint("TOPLEFT", 0, -(index - 1) * rowHeight)
        row:SetSize(620, rowHeight)
        makeRow(row)
        list.rows[index] = row
    end
    local scrollbar = CreateFrame("Slider", nil, list)
    list.scrollbar = scrollbar
    scrollbar:SetPoint("TOPRIGHT", 0, 0)
    scrollbar:SetSize(14, count * rowHeight)
    scrollbar:SetOrientation("VERTICAL")
    scrollbar:SetValueStep(1)
    scrollbar:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    scrollbar:GetThumbTexture():SetSize(20, 24)
    function list:Refresh(entries)
        self.entries = entries or {}
        self.maxOffset = math.max(0, #self.entries - count)
        self.offset = math.max(0, math.min(self.offset, self.maxOffset))
        self.refreshing = true
        scrollbar:SetMinMaxValues(0, math.max(1, self.maxOffset))
        scrollbar:SetValue(self.offset)
        self.refreshing = false
        if self.maxOffset > 0 then scrollbar:Show() else scrollbar:Hide() end
        if #self.entries == 0 then self.empty:Show() else self.empty:Hide() end
        for index, row in ipairs(self.rows) do
            local entry = self.entries[self.offset + index]
            if entry then render(row, entry); row:Show() else row:Hide() end
        end
    end
    local function SetOffset(value)
        for _, row in ipairs(list.rows) do
            HideTooltip(row)
            if row.follow then HideTooltip(row.follow) end
        end
        list.offset = math.max(0, math.min(math.floor(value + 0.5), list.maxOffset or 0))
        list:Refresh(list.entries)
    end
    scrollbar:SetScript("OnValueChanged", function(_, value)
        if not list.refreshing then SetOffset(value) end
    end)
    list:EnableMouseWheel(true)
    scrollbar:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta) SetOffset(list.offset - delta) end)
    scrollbar:SetScript("OnMouseWheel", function(_, delta) SetOffset(list.offset - delta) end)
    return list
end

local function CreateRestedXPPage(panel)
    local page = UI:Section(panel, 20, 116, 680, 414, "RestedXP")
    panel.pages.restedxp = page
    local main = CreateFrame("Frame", nil, page)
    main.themeOwner = page.themeOwner
    main:SetAllPoints(page)
    page.main = main
    local publish = CreateFrame("Frame", nil, page)
    publish.themeOwner = page.themeOwner
    publish:SetAllPoints(page)
    publish:Hide()
    page.publish = publish

    panel.restedxpStatus = UI:Label(main, "", 12, "muted")
    panel.restedxpStatus:SetPoint("TOPLEFT", 16, -48)
    panel.restedxpStatus:SetSize(648, 36)
    local installed = UI:Label(main, "Installed guides", 13)
    installed:SetPoint("TOPLEFT", 16, -90)
    panel.restedxpGuides = RestedXPList(main, 112, 4, 23, function(row)
        row:EnableMouse(true)
        row.name = UI:Label(row, "", 12)
        row.name:SetPoint("TOPLEFT", 0, -3)
        row.name:SetSize(536, 20)
        row.version = UI:Label(row, "", 12, "muted")
        row.version:SetPoint("TOPRIGHT", 0, -3)
        row.version:SetSize(76, 20)
        OptionTooltip(page, row, "Installed guide", function()
            local guide = row.guide
            if not guide then return "" end
            return GuideText(guide.name or guide.key) .. "\n" .. GuideText(guide.group)
                .. (guide.subgroup and guide.subgroup ~= "" and (" / " .. GuideText(guide.subgroup)) or "")
                .. "\n" .. (tonumber(guide.version or 0) == 0 and "Unversioned" or ("Version " .. GuideText(guide.version)))
        end)
    end, function(row, guide)
        row.guide = guide
        local group = guide.group and guide.group ~= "" and (GuideText(guide.group) .. " / ") or ""
        row.name:SetText(group .. GuideText(guide.name or guide.key))
        row.version:SetText(tonumber(guide.version or 0) == 0 and "Unversioned" or ("v" .. GuideText(guide.version)))
    end)
    panel.restedxpGuides.empty:SetText("No installed guides found.")

    local available = UI:Label(main, "Group packs and publishers", 13)
    available:SetPoint("TOPLEFT", 16, -216)
    panel.restedxpPacks = RestedXPList(main, 238, 2, 40, function(row)
        row.name = UI:Label(row, "", 12)
        row.name:SetPoint("TOPLEFT", 0, 0)
        row.name:SetSize(514, 19)
        row.detail = UI:Label(row, "", 11, "muted")
        row.detail:SetPoint("TOPLEFT", 0, -18)
        row.detail:SetSize(514, 18)
        row.follow = UI:Button(row, "Follow")
        row.follow:SetPoint("TOPRIGHT", 0, -2)
        row.follow:SetSize(96, 30)
        row.follow:SetScript("OnClick", function()
            if not row.pack then return end
            local success, message = addon:SelectRestedXPPack(row.pack.id, row.pack.source)
            SetFeedback(panel, success and "Publisher selected. Click Update guides to download." or message, not success)
            addon:RefreshOptions()
        end)
        OptionTooltip(page, row.follow, "Follow publisher",
            "Choose this group member as the source for this pack. Future updates follow their published content. "
                .. "Only follow a publisher whose guides you trust.")
    end, function(row, pack)
        row.pack = pack
        local title = GuideText(pack.label or pack.id)
        if pack.label and pack.label ~= pack.id then title = title .. " (" .. GuideText(pack.id) .. ")" end
        row.name:SetText(title)
        local status = pack.updateAvailable and "Update available" or pack.status
            or (pack.installed and "Installed" or "Available")
        row.detail:SetText(GuideText(pack.source or "You") .. " | " .. GuideText(status)
            .. (pack.hash and (" | " .. GuideText(pack.hash:sub(1, 8))) or ""))
        local canFollow = pack.source ~= nil and not pack.localPack and pack.canFollow ~= false
        row.follow:SetText(pack.selected and "Following"
            or (pack.localPack or not pack.source) and "Shared" or canFollow and "Follow" or "Cached")
        row.follow:SetEnabled(not page.readOnly and not page.busy and canFollow and not pack.selected)
    end)
    panel.restedxpPacks.empty:SetText("No shared packs found. Update guides checks online group members.")
    panel.restedxpUpdate = UI:Button(main, "Update guides", "primary")
    panel.restedxpUpdate:SetPoint("TOPLEFT", 16, -338)
    panel.restedxpUpdate:SetSize(160, 32)
    panel.restedxpUpdate:SetScript("OnClick", function()
        local success, message = addon:UpdateRestedXPGuides()
        SetFeedback(panel, success and "Checking available guide updates..." or message, not success)
        addon:RefreshOptions()
    end)
    OptionTooltip(page, panel.restedxpUpdate, "Update guides",
        "Discover available group packs and install changed content from publishers you follow. "
            .. "Guide versions are displayed above; pack content identifies changes.")
    panel.restedxpShare = UI:Button(main, "Share export")
    panel.restedxpShare:SetPoint("TOPRIGHT", -16, -12)
    panel.restedxpShare:SetSize(128, 28)

    local packLabel = UI:Label(publish, "Pack ID", 12, "muted")
    packLabel:SetPoint("TOPLEFT", 16, -52)
    panel.restedxpPackID = UI:EditBox(publish)
    panel.restedxpPackID:SetPoint("TOPLEFT", 16, -74)
    panel.restedxpPackID:SetSize(300, 30)
    panel.restedxpPackID:SetMaxLetters(40)
    OptionTooltip(page, panel.restedxpPackID, "Pack ID",
        "Choose a short name using letters, numbers, hyphens or underscores. "
            .. "Use the same ID when publishing updated content so followers receive the update.")
    local tagLabel = UI:Label(publish, "Export's source BattleTag", 12, "muted")
    tagLabel:SetPoint("TOPLEFT", 332, -52)
    panel.restedxpBattleTag = UI:EditBox(publish)
    panel.restedxpBattleTag:SetPoint("TOPLEFT", 332, -74)
    panel.restedxpBattleTag:SetSize(332, 30)
    panel.restedxpBattleTag:SetMaxLetters(128)
    OptionTooltip(page, panel.restedxpBattleTag, "Export's source BattleTag",
        "Enter the BattleTag this export was created for. It is used only to read this export; "
            .. "each recipient uses their own BattleTag locally.")
    local exportLabel = UI:Label(publish, "Paste a RestedXP export (Ctrl+V)", 12, "muted")
    exportLabel:SetPoint("TOPLEFT", 16, -120)
    local scroll = CreateFrame("ScrollFrame", nil, publish)
    scroll:SetPoint("TOPLEFT", 16, -142)
    scroll:SetSize(622, 164)
    panel.restedxpExport = UI:EditBox(publish)
    panel.restedxpExport:SetParent(scroll)
    panel.restedxpExport:SetMultiLine(true)
    panel.restedxpExport:SetMaxLetters(2 * 1024 * 1024)
    panel.restedxpExport:SetSize(620, 164)
    panel.restedxpExport:SetTextInsets(10, 10, 8, 8)
    scroll:SetScrollChild(panel.restedxpExport)
    local exportScroll = CreateFrame("Slider", nil, publish)
    exportScroll:SetPoint("TOPLEFT", 648, -142)
    exportScroll:SetSize(14, 164)
    exportScroll:SetOrientation("VERTICAL")
    exportScroll:SetValueStep(16)
    exportScroll:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    exportScroll:GetThumbTexture():SetSize(20, 24)
    exportScroll:SetMinMaxValues(0, 0)
    exportScroll:SetScript("OnValueChanged", function(_, value) scroll:SetVerticalScroll(value) end)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        exportScroll:SetValue(exportScroll:GetValue() - delta * 32)
    end)
    local function RefreshDraft()
        panel.restedxpImport:SetEnabled(not page.readOnly and not page.busy
            and panel.restedxpPackID:GetText():find("%S") ~= nil
            and panel.restedxpBattleTag:GetText():find("%S") ~= nil
            and panel.restedxpExport:GetText():find("%S") ~= nil)
    end
    for _, edit in ipairs({ panel.restedxpPackID, panel.restedxpBattleTag, panel.restedxpExport }) do
        edit:SetScript("OnEscapePressed", function(widget) widget:ClearFocus() end)
        edit:SetScript("OnTextChanged", RefreshDraft)
    end
    panel.restedxpExport:HookScript("OnTextChanged", function(edit)
        local _, fontSize = edit:GetFont()
        edit:SetHeight(math.max(164, edit:GetNumLines() * ((fontSize or 14) + 2) + 16))
        scroll:UpdateScrollChildRect()
        exportScroll:SetMinMaxValues(0, math.max(0, edit:GetHeight() - scroll:GetHeight()))
    end)
    panel.restedxpExport:SetScript("OnCursorChanged", function(_, _, y, _, height)
        local top, bottom = -y, -y + height
        local offset = scroll:GetVerticalScroll()
        if top < offset then exportScroll:SetValue(top)
        elseif bottom > offset + scroll:GetHeight() then exportScroll:SetValue(bottom - scroll:GetHeight()) end
    end)
    panel.restedxpImport = UI:Button(publish, "Import & share", "primary")
    panel.restedxpImport:SetPoint("TOPLEFT", 16, -338)
    panel.restedxpImport:SetSize(160, 32)
    local function ClearDraft()
        for _, edit in ipairs({ panel.restedxpPackID, panel.restedxpBattleTag, panel.restedxpExport }) do
            edit:ClearFocus()
            edit:SetText("")
        end
        exportScroll:SetValue(0)
    end
    page.ClearDraft = ClearDraft
    panel.restedxpImport:SetScript("OnClick", function()
        local success, message = addon:ImportRestedXPPack(panel.restedxpPackID:GetText(),
            panel.restedxpExport:GetText(), panel.restedxpBattleTag:GetText())
        if success then
            ClearDraft()
            publish:Hide()
            main:Show()
        end
        SetFeedback(panel, success and "Validating export before sharing..." or message, not success)
        addon:RefreshOptions()
    end)
    local back = UI:Button(publish, "Back")
    page.back = back
    back:SetPoint("TOPRIGHT", -16, -12)
    back:SetSize(96, 28)
    back:SetScript("OnClick", function()
        ClearDraft()
        publish:Hide()
        main:Show()
        SetFeedback(panel)
    end)
    panel.restedxpShare:SetScript("OnClick", function()
        main:Hide()
        publish:Show()
        if type(addon.GetRestedXPBattleTag) == "function" then
            panel.restedxpBattleTag:SetText(addon:GetRestedXPBattleTag() or "")
        end
        panel.restedxpPackID:SetFocus()
        SetFeedback(panel)
        RefreshDraft()
    end)
    page.RefreshDraft = RefreshDraft
    page:SetScript("OnHide", function()
        ClearDraft()
        publish:Hide()
        main:Show()
    end)
    RefreshDraft()
end

local function RefreshRestedXP(panel)
    local page = panel.pages.restedxp
    if not page or not page:IsVisible() then return end
    local state = type(addon.GetRestedXPState) == "function" and addon:GetRestedXPState() or {}
    page.readOnly, page.busy = addon.savedDataReadOnly or state.readOnly, state.busy
    local status = not state.installed and "RestedXP is not installed."
        or (state.loaded and "RestedXP is installed" or "RestedXP is installed but not loaded")
            .. (state.version and (" (" .. GuideText(state.version) .. ")") or "") .. "."
    if state.installationProblem then status = status .. " " .. GuideText(state.installationProblem) end
    if state.status and state.status ~= "" then status = status .. "\n" .. GuideText(state.status) end
    panel.restedxpStatus:SetText(status)
    panel.restedxpGuides:Refresh(state.guides)
    panel.restedxpPacks:Refresh(state.packs)
    panel.restedxpUpdate:SetEnabled(not page.readOnly and not page.busy and state.canUpdate == true)
    panel.restedxpShare:SetEnabled(not page.readOnly and not page.busy)
    for _, edit in ipairs({ panel.restedxpPackID, panel.restedxpBattleTag, panel.restedxpExport }) do
        edit:SetEnabled(not page.readOnly and not page.busy)
    end
    page.RefreshDraft()
end

local function CreateOptionsPanel()
    local panel = CreateView()
    panel.tabs, panel.pages = {}, {}
    local group = UI:Section(panel, 20, 116, 680, 414, "Your group")
    panel.pages.group = group

    panel.groupStatus = UI:Label(group, "", 13, "muted")
    panel.groupStatus:SetPoint("TOPLEFT", 16, -46)
    panel.groupStatus:SetWidth(648)

    panel.groupInfo = UI:Button(group, "Group info")
    panel.groupInfo:SetPoint("TOPRIGHT", -16, -12)
    panel.groupInfo:SetSize(100, 28)
    OptionTooltip(group, panel.groupInfo, "Group info", function()
        local text = "One key connects all your characters and every LockInTools feature.\n\n"
            .. "Friends must be on the same realm and faction."
        local fingerprint = addon:GetGroupFingerprint()
        if addon:IsGroupSwitching() then
            text = text .. "\n\nLeaving the previous group before connecting."
        elseif fingerprint then
            text = text .. "\n\nGroup ID: " .. fingerprint
                .. "\nCompare this ID with a friend to check that you share a group."
        end
        return text
    end)

    local introduction = UI:Label(group, "Share your key or use a friend's to connect.", 14)
    introduction:SetPoint("TOPLEFT", 16, -74)
    introduction:SetWidth(648)

    local ownLabel = UI:Label(group, "Share your key", 13, "muted")
    ownLabel:SetPoint("TOPLEFT", 16, -108)

    panel.ownSecret = UI:EditBox(group)
    panel.ownSecret:SetPoint("TOPLEFT", 16, -132)
    panel.ownSecret:SetSize(500, 34)
    panel.ownSecret:SetAutoFocus(false)
    panel.ownSecret:SetScript("OnTextChanged", function(editBox)
        local secret = group.showingKeys and addon:GetGroupSecret() or ""
        if editBox:GetText() ~= secret then editBox:SetText(secret) end
    end)
    panel.ownSecret:SetScript("OnEditFocusGained", function(editBox) editBox:HighlightText() end)
    panel.ownSecret:SetScript("OnEscapePressed", function(editBox) editBox:ClearFocus() end)
    panel.ownSecret:SetScript("OnEnterPressed", function(editBox) editBox:ClearFocus() end)

    panel.selectKey = UI:Button(group, "Select key")
    panel.selectKey:SetPoint("TOPLEFT", 528, -132)
    panel.selectKey:SetSize(132, 34)
    panel.selectKey:SetScript("OnClick", function()
        panel.ownSecret:SetFocus()
        panel.ownSecret:HighlightText()
    end)
    OptionTooltip(group, panel.ownSecret, "Your saved key",
        "Share this key with friends to invite them. This field is for copying; it cannot change your group.")
    OptionTooltip(group, panel.selectKey, "Select key", "Select your saved key, then press Ctrl+C to copy it.")

    local copyHint = UI:Label(group, "Select key, then press Ctrl+C to copy.", 12, "muted")
    copyHint:SetPoint("TOPLEFT", 16, -174)

    panel.newKeyLabel = UI:Label(group, "Join a group", 13, "muted")
    panel.newKeyLabel:SetPoint("TOPLEFT", 16, -216)

    panel.secret = UI:EditBox(group)
    panel.secret:SetPoint("TOPLEFT", 16, -240)
    panel.secret:SetSize(500, 34)
    panel.secret:SetAutoFocus(false)
    panel.secret:SetScript("OnEscapePressed", function(editBox)
        editBox:ClearFocus()
    end)
    panel.secret:SetScript("OnEnterPressed", function()
        ApplyGroup(panel)
    end)
    panel.secret:SetScript("OnTextChanged", function(_, userInput)
        RefreshKeyAction(panel)
        if userInput then
            ResetConfirmation(panel)
            SetFeedback(panel)
        end
    end)

    panel.applyGroup = UI:Button(group, "Use key", "primary")
    panel.applyGroup:SetSize(132, 34)
    panel.applyGroup:SetPoint("TOPLEFT", 528, -240)
    panel.applyGroup:SetScript("OnClick", function()
        ApplyGroup(panel)
    end)
    OptionTooltip(group, panel.secret, "Group key", "Enter a friend's key, or generate a key for a new group.")
    OptionTooltip(group, panel.applyGroup, "Use key",
        "Save the entered key for every LockInTools feature. Switching groups requires confirmation.")

    panel.createGroup = UI:Button(group, "Generate key")
    panel.createGroup:SetSize(132, 30)
    panel.createGroup:SetPoint("TOPLEFT", 16, -286)
    panel.createGroup:SetScript("OnClick", function()
        ResetConfirmation(panel)
        local key, message = addon:GenerateGroupKey()
        if not key then
            SetFeedback(panel, message or "Unable to create a group key.", true)
            return
        end

        panel.secret:SetText(key)
        panel.secret:SetFocus()
        panel.secret:HighlightText()
        SetFeedback(panel, "New key ready. Click Use key to save it.", false)
    end)
    OptionTooltip(group, panel.createGroup, "Generate key",
        "Prepare a key for a new group. Your current group stays active until you choose Use key and confirm any switch.")

    panel.leaveGroup = UI:Button(group, "Leave group", "danger")
    panel.leaveGroup:SetSize(132, 30)
    panel.leaveGroup:SetPoint("TOPRIGHT", -20, -336)
    panel.leaveGroup:SetScript("OnClick", function()
        if not panel.confirmLeave then
            ResetConfirmation(panel)
            panel.confirmLeave = true
            panel.leaveGroup:SetText("Confirm leave")
            SetFeedback(panel, "Click Confirm leave to remove this group from every LockInTools feature.", true)
            return
        end

        local success, message = addon:LeaveGroup()
        ResetConfirmation(panel)
        if not success then
            SetFeedback(panel, message or "Unable to leave the group.", true)
            return
        end

        ClearKeyDraft(panel)
        SetFeedback(panel, "Group removed. You can rejoin with its key.", false)
    end)
    OptionTooltip(group, panel.leaveGroup, "Leave group",
        "Remove this group from every LockInTools feature and clear its cached players. You can rejoin with the same key. Confirmation is required.")

    group:SetScript("OnShow", function()
        group.showingKeys = true
        addon:RefreshOptions()
    end)
    group:SetScript("OnHide", function() ClearGroupKeys(panel) end)

    local chat = UI:Section(panel, 20, 116, 680, 414, "Shared chat")
    panel.pages.chat = chat
    local chatIntroduction = UI:Label(chat,
        "Chat with your group in WoW. Use /lit chat to write.", 14)
    chatIntroduction:SetPoint("TOPLEFT", 16, -50)
    chatIntroduction:SetWidth(648)

    panel.autoJoin = UI:Checkbox(chat)
    panel.autoJoin:SetPoint("TOPLEFT", 12, -94)
    panel.autoJoin:SetSize(28, 28)
    BindPreference(panel, panel.autoJoin, function() return addon.db.chat.autoJoin end, addon.SetChatAutoJoin)
    PreferenceLabel(chat, panel.autoJoin, "Join automatically on login",
        "Join your group's chat when you log in. Enabling this also connects now; disabling it keeps an existing chat connection.")

    panel.chatStatusHelp = CreateFrame("Frame", nil, chat)
    panel.chatStatusHelp:SetPoint("TOPLEFT", 16, -142)
    panel.chatStatusHelp:SetSize(648, 36)
    panel.chatStatusHelp:EnableMouse(true)
    panel.status = UI:Label(chat, "", 12, "muted")
    panel.status:SetPoint("TOPLEFT", panel.chatStatusHelp, "TOPLEFT", 0, 0)
    panel.status:SetWidth(648)
    OptionTooltip(chat, panel.chatStatusHelp, "Chat status", function() return addon:GetChatStatusText() end)

    panel.join = UI:Button(chat, "Join chat")
    panel.join:SetSize(96, 32)
    panel.join:SetPoint("TOPLEFT", 16, -190)
    panel.join:SetScript("OnClick", function()
        SetFeedback(panel)
        addon:JoinChatChannel(true)
    end)
    OptionTooltip(chat, panel.join, "Join chat",
        "Connect or retry your group's chat channel. Friends need the same group key, realm and faction. This does not change your login preference.")

    panel.leave = UI:Button(chat, "Leave chat")
    panel.leave:SetSize(96, 32)
    panel.leave:SetPoint("LEFT", panel.join, "RIGHT", 8, 0)
    panel.leave:SetScript("OnClick", function()
        SetFeedback(panel)
        addon:LeaveChatChannel()
    end)
    OptionTooltip(chat, panel.leave, "Leave chat",
        "Leave chat and pause reconnection for this session. Your group, position sharing and login preference stay unchanged.")

    local position = UI:Section(panel, 20, 116, 680, 414, "Shared positions")
    panel.pages.position = position
    local positionIntroduction = UI:Label(position,
        "Share locations with your group on the world map.", 14)
    positionIntroduction:SetPoint("TOPLEFT", 16, -50)
    positionIntroduction:SetWidth(648)

    panel.positionSharing = UI:Checkbox(position)
    panel.positionSharing:SetPoint("TOPLEFT", 12, -94)
    panel.positionSharing:SetSize(28, 28)
    BindPreference(panel, panel.positionSharing, function() return addon.db.position.sharing end,
        addon.SetPositionSharing)
    PreferenceLabel(position, panel.positionSharing, "Enable position sharing",
        "Send and receive your group's locations. Turning this off hides player icons and stops position exchange.\n\n"
            .. "Friends need the same group key, realm and faction. Shared chat can stay disconnected.")

    panel.positionRetention = UI:Checkbox(position)
    panel.positionRetention:SetPoint("TOPLEFT", 12, -130)
    panel.positionRetention:SetSize(28, 28)
    BindPreference(panel, panel.positionRetention, function() return addon.db.position.keepLastKnown end,
        addon.SetPositionRetention)
    PreferenceLabel(position, panel.positionRetention, "Keep last-known positions",
        "Keep the last location across reloads and characters. Gray offline markers mean no position update for at least 60 seconds.\n\n"
            .. "Turning this off removes stale locations and stops saving them.")

    panel.positionStatusHelp = CreateFrame("Frame", nil, position)
    panel.positionStatusHelp:SetPoint("TOPLEFT", 16, -178)
    panel.positionStatusHelp:SetSize(648, 36)
    panel.positionStatusHelp:EnableMouse(true)
    panel.positionStatus = UI:Label(position, "", 12, "muted")
    panel.positionStatus:SetPoint("TOPLEFT", panel.positionStatusHelp, "TOPLEFT", 0, 0)
    panel.positionStatus:SetWidth(648)
    OptionTooltip(position, panel.positionStatusHelp, "Position status", function()
        return addon:GetPositionStatusText() .. "\n\nTo hide player icons while sharing continues, use the world map's LockInTools filter."
    end)

    CreateRestedXPPage(panel)

    for _, page in pairs(panel.pages) do
        local tooltipPage = page
        page:HookScript("OnHide", function() HidePageTooltips(tooltipPage) end)
        page.feedback = UI:Label(page, "", 13)
        page.feedback:SetPoint("BOTTOMLEFT", 16, 16)
        page.feedback:SetSize(648, 26)
    end

    local function SelectTab(name)
        if not panel.pages[name] then return end
        if panel.selectedTab == name then return end
        if panel.selectedTab == "group" then
            ClearGroupKeys(panel)
        end
        panel.selectedTab = name
        panel.feedback = panel.pages[name].feedback
        for category, page in pairs(panel.pages) do
            if category == name then page:Show() else page:Hide() end
            UI:SetTabSelected(panel.tabs[category], category == name)
        end
        group.showingKeys = name == "group" and panel:IsVisible()
        SetFeedback(panel)
        addon:RefreshOptions()
    end
    panel.SelectTab = SelectTab
    local categories = { { "group", "Group", 116 }, { "chat", "Shared chat", 148 },
        { "position", "Shared positions", 166 }, { "restedxp", "RestedXP", 136 } }
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
    SelectTab("group")

    panel.content = UI:Button(panel, "Content")
    panel.content:SetPoint("TOPRIGHT", -54, -12)
    panel.content:SetSize(110, 32)
    panel.content:SetScript("OnClick", function() addon:OpenContent() end)

    panel:SetScript("OnShow", function()
        ResetConfirmation(panel)
        ClearKeyDraft(panel)
        group.showingKeys = panel.selectedTab == "group"
        panel.autoJoin:SetChecked(addon.db.chat.autoJoin)
        panel.positionSharing:SetChecked(addon.db.position.sharing)
        panel.positionRetention:SetChecked(addon.db.position.keepLastKnown)
        SetFeedback(panel)
        addon:RefreshOptions()
    end)
    panel:SetScript("OnHide", function()
        for _, page in pairs(panel.pages) do HidePageTooltips(page) end
        ClearGroupKeys(panel)
    end)

    UI:Finish(addon.mainPanel)
    return panel
end

function addon:RefreshOptions()
    local panel = self.optionsPanel
    if not panel or not panel:IsVisible() or not self.initialized then
        return
    end

    local hasGroup, switching = self:HasGroup(), self:IsGroupSwitching()
    panel.groupStatus:SetText(switching and "Leaving previous group..." or hasGroup and "Group configured"
        or (self.invalidGroupSecret and "Saved key needs replacing" or "No group yet"))
    panel.newKeyLabel:SetText(hasGroup and "Use a different key" or "Join a group")
    panel.status:SetText("Status: " .. self:GetChatStatusText(true))
    panel.positionStatus:SetText("Sharing: " .. self:GetPositionStatusText(true))

    local secret = panel.pages.group.showingKeys and self:GetGroupSecret() or ""
    if panel.ownSecret:GetText() ~= secret then panel.ownSecret:SetText(secret) end
    panel.ownSecret:SetEnabled(secret ~= "")
    panel.selectKey:SetEnabled(secret ~= "")

    -- Status events must preserve the group key being edited.
    local editable = not self.savedDataReadOnly
    panel.secret:SetEnabled(editable)
    RefreshKeyAction(panel)
    panel.createGroup:SetEnabled(editable)
    panel.leaveGroup:SetEnabled(editable and hasGroup)
    panel.autoJoin:SetEnabled(editable)
    panel.positionSharing:SetEnabled(editable)
    panel.positionRetention:SetEnabled(editable)
    panel.join:SetEnabled(self.ready and hasGroup and not switching)
    panel.leave:SetEnabled(self.ready and hasGroup and not switching)
    RefreshRestedXP(panel)
    if not editable then
        ClearKeyDraft(panel)
        SetFeedback(panel, "Update LockInTools before changing saved preferences.", true)
    elseif self.invalidGroupSecret and panel.selectedTab == "group" then
        SetFeedback(panel, "Your saved key is invalid. Enter a friend's key or generate a new one.", true)
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

local function CreateContentPanel()
    local panel = CreateView()
    panel.tabs, panel.pages = {}, {}
    panel.selectedTab = "overview"
    addon:CreateOverviewPage(panel)

    panel.tabs.overview = UI:Button(panel, "Overview", "tab")
    panel.tabs.overview:SetPoint("TOPLEFT", 20, -66)
    panel.tabs.overview:SetSize(130, 34)
    UI:SetTabSelected(panel.tabs.overview, true)
    panel.SelectTab = function(name)
        if name == "overview" then panel.overviewPage:Activate() end
    end
    panel.tabs.overview:SetScript("OnClick", function() panel.SelectTab("overview") end)

    panel.options = UI:Button(panel, "Settings")
    panel.options:SetPoint("TOPRIGHT", -54, -12)
    panel.options:SetSize(110, 32)
    panel.options:SetScript("OnClick", function() addon:OpenOptions() end)

    panel:SetScript("OnShow", function()
        SetFeedback(panel)
        addon:RefreshContent()
        panel.overviewPage:Activate()
    end)
    panel:SetScript("OnHide", function()
        panel.overviewPage:Deactivate()
    end)
    UI:Finish(addon.mainPanel)
    return panel
end

local function RefreshContentFeedback(self)
    local panel = self.contentPanel
    if not panel or not self.initialized then return end
    if self.savedDataReadOnly then
        SetFeedback(panel, "Update LockInTools before changing saved preferences.", true)
    elseif self.invalidGroupSecret then
        SetFeedback(panel, "Your saved key is invalid. Open Settings > Group to replace it.", true)
    end
end

function addon:RefreshContent()
    if not self.contentPanel or not self.initialized then return end
    self:RefreshOverview()
    RefreshContentFeedback(self)
end

function addon:OpenContent()
    if not self.initialized then
        self:Print("Still loading. Please try again after login.")
        return
    end

    local problem
    if not self:HasGroup() and not self.invalidGroupSecret and not self.savedDataReadOnly then
        local key
        key, problem = self:GenerateGroupKey()
        if key then
            local success
            success, problem = self:SetGroupSecret(key)
            if success then problem = nil end
        end
    end

    if not self.contentPanel then self.contentPanel = CreateContentPanel() end
    ShowPanel(self.contentPanel)
    self:RefreshContent()
    if problem then SetFeedback(self.contentPanel, problem, true) end
end

-- Keep the old command/API entry point without retaining a separate welcome view.
function addon:OpenWelcome()
    self:OpenContent()
end

for _, notification in ipairs({ "GROUP_CHANGED", "CHAT_CHANGED", "DATA_CHANGED", "POSITIONS_CHANGED", "RESTEDXP_CHANGED" }) do
    addon:RegisterNotification(notification, function() addon:RefreshOptions() end)
end
addon:RegisterNotification("GROUP_CHANGED", function() RefreshContentFeedback(addon) end)
