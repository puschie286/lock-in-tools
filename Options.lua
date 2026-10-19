local _, addon = ...
local UI = addon.Theme
local WINDOW_POINTS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}
local positionFrame

local function ValidWindowPosition(position)
    local function ValidOffset(value)
        return type(value) == "number" and value == value and math.abs(value) <= 100000
    end
    return type(position) == "table" and WINDOW_POINTS[position.point] == true
        and WINDOW_POINTS[position.relativePoint] == true
        and ValidOffset(position.x) and ValidOffset(position.y)
end

function addon:SaveWindowPosition(panel)
    panel = panel or self.activePanel
    if not panel or panel ~= self.activePanel then return end
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
    panel:HookScript("OnDragStop", function() addon:SaveWindowPosition(panel) end)
    panel:HookScript("OnHide", function() addon:SaveWindowPosition(panel) end)
    if not positionFrame then
        positionFrame = CreateFrame("Frame")
        positionFrame:RegisterEvent("PLAYER_LOGOUT")
        positionFrame:SetScript("OnEvent", function() addon:SaveWindowPosition() end)
    end
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

local function ShowPanel(panel)
    local previous = addon.activePanel
    UI:Fit(panel)
    if previous and previous ~= panel then
        previous:StopMovingOrSizing()
        local point, relativeTo, relativePoint, x, y = previous:GetPoint()
        panel:ClearAllPoints()
        panel:SetPoint(point, relativeTo, relativePoint, x, y)
        previous:Hide()
    elseif not previous then
        local position = addon.db.windowPosition
        panel:ClearAllPoints()
        if ValidWindowPosition(position) then
            panel:SetPoint(position.point, UIParent, position.relativePoint, position.x, position.y)
        else
            panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end
    end
    addon.activePanel = panel
    panel:Show()
    panel:Raise()
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
    addon:RefreshOptions()
end

local function BindPreference(panel, checkbox, getter, setter)
    checkbox:SetScript("OnClick", function(button)
        local success, message = setter(addon, button:GetChecked() and true or false)
        if not success then button:SetChecked(getter()) end
        SetFeedback(panel, success and "" or (message or "Unable to change this setting."), not success)
        addon:RefreshOptions()
    end)
end

local function ApplyTrailLength(panel, finish)
    if not panel.trailLengthEdited then return end
    local enabled, savedLength = addon:GetPositionTrailSettings()
    local length = tonumber(panel.positionTrailLength:GetText())
    local success, message = true
    if length ~= savedLength then
        success, message = addon:SetPositionTrailSettings(enabled, length)
    end
    if finish then
        panel.trailLengthEdited = nil
        local _, currentLength = addon:GetPositionTrailSettings()
        panel.positionTrailLength:SetText(tostring(currentLength))
    end
    SetFeedback(panel, success and "" or (message or "Unable to change the trail length."), not success)
    addon:RefreshOptions()
end

local function CreateOptionsPanel()
    local panel = UI:Window("LockInToolsOptions", 720, 550)
    panel.TitleText:SetText("LockInTools - Settings")
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
        if fingerprint then
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
        addon:RefreshOptions()
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
        addon:RefreshOptions()
    end)
    OptionTooltip(chat, panel.join, "Join chat",
        "Connect or retry your group's chat channel. Friends need the same group key, realm and faction. This does not change your login preference.")

    panel.leave = UI:Button(chat, "Leave chat")
    panel.leave:SetSize(96, 32)
    panel.leave:SetPoint("LEFT", panel.join, "RIGHT", 8, 0)
    panel.leave:SetScript("OnClick", function()
        SetFeedback(panel)
        addon:LeaveChatChannel()
        addon:RefreshOptions()
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

    panel.positionTrails = UI:Checkbox(position)
    panel.positionTrails:SetPoint("TOPLEFT", 12, -166)
    panel.positionTrails:SetSize(28, 28)
    BindPreference(panel, panel.positionTrails, function() return addon:GetPositionTrailSettings() end,
        function(self, enabled)
            local _, length = self:GetPositionTrailSettings()
            return self:SetPositionTrailSettings(enabled, length)
        end)
    PreferenceLabel(position, panel.positionTrails, "Show movement trails",
        "Draw fading paths behind moving players. Trails are temporary, shown only on your map, and are not saved or shared.")

    local trailLengthLabel = UI:Label(position, "Trail length", 13, "muted")
    trailLengthLabel:SetPoint("TOPLEFT", 42, -216)
    panel.positionTrailLength = UI:EditBox(position)
    panel.positionTrailLength:SetPoint("TOPLEFT", 166, -206)
    panel.positionTrailLength:SetSize(84, 32)
    panel.positionTrailLength:SetAutoFocus(false)
    panel.positionTrailLength:SetNumeric(true)
    panel.positionTrailLength:SetScript("OnEscapePressed", function(editBox) editBox:ClearFocus() end)
    panel.positionTrailLength:SetScript("OnEnterPressed", function(editBox)
        ApplyTrailLength(panel, true)
        editBox:ClearFocus()
    end)
    panel.positionTrailLength:SetScript("OnEditFocusLost", function() ApplyTrailLength(panel, true) end)
    panel.positionTrailLength:SetScript("OnTextChanged", function(_, userInput)
        if userInput then
            panel.trailLengthEdited = true
            ApplyTrailLength(panel, false)
        end
    end)
    OptionTooltip(position, panel.positionTrailLength, "Trail length",
        "How long movement trails remain visible. Enter a whole number from 1 to 30 seconds. You can set this while trails are off.")
    local trailLengthHint = UI:Label(position, "seconds (1–30)", 12, "muted")
    trailLengthHint:SetPoint("LEFT", panel.positionTrailLength, "RIGHT", 12, 0)

    panel.positionStatusHelp = CreateFrame("Frame", nil, position)
    panel.positionStatusHelp:SetPoint("TOPLEFT", 16, -266)
    panel.positionStatusHelp:SetSize(648, 36)
    panel.positionStatusHelp:EnableMouse(true)
    panel.positionStatus = UI:Label(position, "", 12, "muted")
    panel.positionStatus:SetPoint("TOPLEFT", panel.positionStatusHelp, "TOPLEFT", 0, 0)
    panel.positionStatus:SetWidth(648)
    OptionTooltip(position, panel.positionStatusHelp, "Position status", function()
        return addon:GetPositionStatusText() .. "\n\nTo hide player icons while sharing continues, use the world map's LockInTools filter."
    end)

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
        elseif panel.selectedTab == "position" then
            ApplyTrailLength(panel, true)
            panel.positionTrailLength:ClearFocus()
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
    local categories = { { "group", "Group", 134 }, { "chat", "Shared chat", 152 },
        { "position", "Shared positions", 172 } }
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
        UI:Fit(panel)
        ResetConfirmation(panel)
        ClearKeyDraft(panel)
        group.showingKeys = panel.selectedTab == "group"
        panel.autoJoin:SetChecked(addon.db.chat.autoJoin)
        panel.positionSharing:SetChecked(addon.db.position.sharing)
        panel.positionRetention:SetChecked(addon.db.position.keepLastKnown)
        local showTrails, trailLength = addon:GetPositionTrailSettings()
        panel.positionTrails:SetChecked(showTrails)
        panel.trailLengthEdited = nil
        panel.positionTrailLength:SetText(tostring(trailLength))
        SetFeedback(panel)
        addon:RefreshOptions()
    end)
    panel:SetScript("OnHide", function()
        for _, page in pairs(panel.pages) do HidePageTooltips(page) end
        ClearGroupKeys(panel)
        ApplyTrailLength(panel, true)
        panel.positionTrailLength:ClearFocus()
        panel:StopMovingOrSizing()
    end)

    tinsert(UISpecialFrames, "LockInToolsOptions")
    TrackWindowPosition(panel)
    UI:Finish(panel)
    return panel
end

function addon:RefreshOptions()
    self:RefreshContent()
    local panel = self.optionsPanel
    if not panel or not self.initialized then
        return
    end

    local hasGroup = self:HasGroup()
    panel.groupStatus:SetText(hasGroup and "Group configured"
        or (self.invalidGroupSecret and "Saved key needs replacing" or "No group yet"))
    panel.newKeyLabel:SetText(hasGroup and "Use a different key" or "Join a group")
    panel.status:SetText("Status: " .. self:GetChatStatusText(true))
    panel.positionStatus:SetText("Sharing: " .. self:GetPositionStatusText(true))

    local secret = panel.pages.group.showingKeys and self:GetGroupSecret() or ""
    if panel.ownSecret:GetText() ~= secret then panel.ownSecret:SetText(secret) end
    panel.ownSecret:SetEnabled(secret ~= "")
    panel.selectKey:SetEnabled(secret ~= "")

    -- Status events must preserve the group key and trail-length text being edited.
    local editable = not self.savedDataReadOnly
    panel.secret:SetEnabled(editable)
    RefreshKeyAction(panel)
    panel.createGroup:SetEnabled(editable)
    panel.leaveGroup:SetEnabled(editable and hasGroup)
    panel.autoJoin:SetEnabled(editable)
    panel.positionSharing:SetEnabled(editable)
    panel.positionRetention:SetEnabled(editable)
    panel.positionTrails:SetEnabled(editable)
    panel.positionTrailLength:SetEnabled(editable)
    panel.join:SetEnabled(self.ready and hasGroup)
    panel.leave:SetEnabled(self.ready and hasGroup)
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

    if self.contentPanel then self.contentPanel:Hide() end
    if not self.optionsPanel then
        self.optionsPanel = CreateOptionsPanel()
    end

    if category then self.optionsPanel.SelectTab(category) end
    ShowPanel(self.optionsPanel)
end

local function CreateContentPanel()
    local panel = UI:Window("LockInToolsContent", 720, 550)
    panel.TitleText:SetText("LockInTools")
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
        UI:Fit(panel)
        SetFeedback(panel)
        addon:RefreshContent()
        panel.overviewPage:Activate()
    end)
    panel:SetScript("OnHide", function()
        panel.overviewPage:Deactivate()
        panel:StopMovingOrSizing()
    end)
    tinsert(UISpecialFrames, "LockInToolsContent")
    TrackWindowPosition(panel)
    UI:Finish(panel)
    return panel
end

function addon:RefreshContent()
    local panel = self.contentPanel
    if not panel or not self.initialized then return end
    self:RefreshOverview()
    if self.savedDataReadOnly then
        SetFeedback(panel, "Update LockInTools before changing saved preferences.", true)
    elseif self.invalidGroupSecret then
        SetFeedback(panel, "Your saved key is invalid. Open Settings > Group to replace it.", true)
    end
end

function addon:OpenContent()
    if not self.initialized then
        self:Print("Still loading. Please try again after login.")
        return
    end

    if self.optionsPanel then self.optionsPanel:Hide() end
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
