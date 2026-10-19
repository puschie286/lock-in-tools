local _, addon = ...
local UI = addon.Theme

local function SetFeedback(panel, message, isError)
    panel.feedback:SetText(message or "")
    if isError then
        panel.feedback:SetTextColor(1, 0.35, 0.35)
    else
        panel.feedback:SetTextColor(0.4, 1, 0.4)
    end
end

local function ResetConfirmation(panel)
    panel.pendingSecret = nil
    panel.confirmLeave = false
    panel.applyGroup:SetText("Use key")
    panel.leaveGroup:SetText("Leave group")
end

local function HideSecret(panel, clear)
    panel.secret:SetPassword(true)
    panel.showingSecret = false
    panel.toggleSecret:SetText("Show key")
    panel.secret:ClearFocus()
    if clear then
        panel.secret:SetText("")
    end
end

local function ApplyGroup(panel)
    local secret = panel.secret:GetText()
    if secret:match("^%s*$") then
        SetFeedback(panel, "Enter a group key first.", true)
        return
    end

    if addon:HasGroup() and secret ~= addon:GetGroupSecret()
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
    HideSecret(panel, true)
    SetFeedback(panel, "Group saved. Share the same key with your friends.", false)
    addon:RefreshOptions()
end

local function SaveChatSettings(panel)
    local success, message = addon:SetChatAutoJoin(panel.autoJoin:GetChecked() and true or false)
    if not success then
        SetFeedback(panel, message or "Unable to save chat settings.", true)
        return
    end

    SetFeedback(panel, "Chat settings saved.", false)
    addon:RefreshOptions()
end

local function SavePositionSettings(panel)
    local success, message = addon:SetPositionRetention(panel.positionRetention:GetChecked() and true or false)
    if not success then
        SetFeedback(panel, message or "Unable to save position settings.", true)
        return
    end

    success, message = addon:SetPositionSharing(panel.positionSharing:GetChecked() and true or false)
    if not success then
        SetFeedback(panel, message or "Unable to save position settings.", true)
        return
    end

    SetFeedback(panel, "Position settings saved.", false)
    addon:RefreshOptions()
end

local function CreateOptionsPanel()
    local panel = UI:Window("LockInToolsOptions", 720, 550)
    panel.tabs, panel.pages = {}, {}
    local group = UI:Section(panel, 20, 116, 680, 300, "Your group")
    panel.pages.group = group

    panel.groupStatus = UI:Label(group, "", 13, "muted")
    panel.groupStatus:SetPoint("TOPLEFT", 16, -46)
    panel.groupStatus:SetWidth(648)

    local introduction = UI:Label(group,
        "Use the same key as your friends. Your group applies to every LockInTools feature.", 14)
    introduction:SetPoint("TOPLEFT", 16, -76)
    introduction:SetWidth(648)

    local secretLabel = UI:Label(group, "Group key", 13, "muted")
    secretLabel:SetPoint("TOPLEFT", 16, -109)

    panel.secret = UI:EditBox(group)
    panel.secret:SetPoint("TOPLEFT", 16, -132)
    panel.secret:SetSize(500, 34)
    panel.secret:SetAutoFocus(false)
    panel.secret:SetPassword(true)
    panel.secret:SetScript("OnEscapePressed", function(editBox)
        editBox:ClearFocus()
    end)
    panel.secret:SetScript("OnEnterPressed", function()
        ApplyGroup(panel)
    end)
    panel.secret:SetScript("OnTextChanged", function(_, userInput)
        if userInput then
            ResetConfirmation(panel)
            SetFeedback(panel)
        end
    end)

    panel.applyGroup = UI:Button(group, "Use key", "primary")
    panel.applyGroup:SetSize(132, 34)
    panel.applyGroup:SetPoint("TOPLEFT", 528, -132)
    panel.applyGroup:SetScript("OnClick", function()
        ApplyGroup(panel)
    end)

    panel.createGroup = UI:Button(group, "Create group")
    panel.createGroup:SetSize(132, 30)
    panel.createGroup:SetPoint("TOPLEFT", 16, -180)
    panel.createGroup:SetScript("OnClick", function()
        ResetConfirmation(panel)
        local key, message = addon:GenerateGroupKey()
        if not key then
            SetFeedback(panel, message or "Unable to create a group key.", true)
            return
        end

        panel.secret:SetText(key)
        panel.secret:SetPassword(false)
        panel.showingSecret = true
        panel.toggleSecret:SetText("Hide key")
        panel.secret:SetFocus()
        panel.secret:HighlightText()
        SetFeedback(panel, "New key ready. Click Use key to save it, then share it with your friends.", false)
    end)

    panel.toggleSecret = UI:Button(group, "Show key")
    panel.toggleSecret:SetSize(132, 30)
    panel.toggleSecret:SetPoint("LEFT", panel.createGroup, "RIGHT", 10, 0)
    panel.toggleSecret:SetScript("OnClick", function()
        ResetConfirmation(panel)
        if panel.showingSecret then
            HideSecret(panel, false)
            SetFeedback(panel)
            return
        end

        if panel.secret:GetText() == "" then
            panel.secret:SetText(addon:GetGroupSecret())
        end
        if panel.secret:GetText() == "" then
            SetFeedback(panel, "Create a group or enter a key from a friend first.", true)
            return
        end

        panel.showingSecret = true
        panel.secret:SetPassword(false)
        panel.toggleSecret:SetText("Hide key")
        panel.secret:SetFocus()
        panel.secret:HighlightText()
        SetFeedback(panel, "Press Ctrl+C to copy the key for your friends.", false)
    end)

    panel.leaveGroup = UI:Button(group, "Leave group", "danger")
    panel.leaveGroup:SetSize(132, 30)
    panel.leaveGroup:SetPoint("LEFT", panel.toggleSecret, "RIGHT", 10, 0)
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

        HideSecret(panel, true)
        SetFeedback(panel, "Group removed. You can rejoin with its key.", false)
        addon:RefreshOptions()
    end)

    local privacyHint = UI:Label(group, "Share the same key with your friends.", 12, "muted")
    privacyHint:SetPoint("TOPLEFT", 16, -224)
    privacyHint:SetWidth(648)

    local chat = UI:Section(panel, 20, 116, 680, 300, "Shared chat")
    panel.pages.chat = chat
    local chatIntroduction = UI:Label(chat,
        "Your group selects its shared channel automatically. Friends must be on the same realm and faction.", 13, "muted")
    chatIntroduction:SetPoint("TOPLEFT", 16, -50)
    chatIntroduction:SetWidth(648)

    panel.autoJoin = UI:Checkbox(chat)
    panel.autoJoin:SetPoint("TOPLEFT", 12, -102)
    panel.autoJoin:SetSize(28, 28)
    local autoJoinLabel = UI:Label(chat, "Automatically join shared chat on login", 13)
    autoJoinLabel:SetPoint("LEFT", panel.autoJoin, "RIGHT", 2, 0)

    panel.status = UI:Label(chat, "", 12, "muted")
    panel.status:SetPoint("TOPLEFT", 16, -148)
    panel.status:SetWidth(648)

    panel.save = UI:Button(chat, "Save chat settings", "primary")
    panel.save:SetSize(148, 32)
    panel.save:SetPoint("TOPLEFT", 16, -208)
    panel.save:SetScript("OnClick", function()
        SaveChatSettings(panel)
    end)

    panel.join = UI:Button(chat, "Join chat")
    panel.join:SetSize(96, 32)
    panel.join:SetPoint("LEFT", panel.save, "RIGHT", 8, 0)
    panel.join:SetScript("OnClick", function()
        SetFeedback(panel)
        addon:JoinChatChannel(true)
        addon:RefreshOptions()
    end)

    panel.leave = UI:Button(chat, "Leave chat")
    panel.leave:SetSize(96, 32)
    panel.leave:SetPoint("LEFT", panel.join, "RIGHT", 8, 0)
    panel.leave:SetScript("OnClick", function()
        SetFeedback(panel)
        addon:LeaveChatChannel()
        addon:RefreshOptions()
    end)

    local chatHint = UI:Label(chat,
        "Use /lit chat to write. Leaving chat keeps your LockInTools group.", 12, "muted")
    chatHint:SetPoint("TOPLEFT", 16, -254)
    chatHint:SetWidth(648)

    local position = UI:Section(panel, 20, 116, 680, 300, "Shared positions")
    panel.pages.position = position
    local positionIntroduction = UI:Label(position,
        "See your friends on the world map. Keep their last-known positions when they go offline.", 13, "muted")
    positionIntroduction:SetPoint("TOPLEFT", 16, -50)
    positionIntroduction:SetWidth(648)

    panel.positionSharing = UI:Checkbox(position)
    panel.positionSharing:SetPoint("TOPLEFT", 12, -102)
    panel.positionSharing:SetSize(28, 28)
    local positionSharingLabel = UI:Label(position, "Enable position sharing", 13)
    positionSharingLabel:SetPoint("LEFT", panel.positionSharing, "RIGHT", 2, 0)

    panel.positionRetention = UI:Checkbox(position)
    panel.positionRetention:SetPoint("TOPLEFT", 12, -138)
    panel.positionRetention:SetSize(28, 28)
    local positionRetentionLabel = UI:Label(position, "Keep last-known positions", 13)
    positionRetentionLabel:SetPoint("LEFT", panel.positionRetention, "RIGHT", 2, 0)

    panel.positionStatus = UI:Label(position, "", 12, "muted")
    panel.positionStatus:SetPoint("TOPLEFT", 16, -180)
    panel.positionStatus:SetWidth(648)

    panel.savePosition = UI:Button(position, "Save position settings", "primary")
    panel.savePosition:SetSize(184, 32)
    panel.savePosition:SetPoint("TOPLEFT", 16, -244)
    panel.savePosition:SetScript("OnClick", function()
        SavePositionSettings(panel)
    end)

    panel.feedback = UI:Label(panel, "", 13)
    panel.feedback:SetPoint("TOPLEFT", 24, -434)
    panel.feedback:SetWidth(672)

    local function SelectTab(name)
        if panel.selectedTab == name then return end
        if panel.selectedTab == "group" then
            HideSecret(panel, true)
            ResetConfirmation(panel)
        end
        panel.selectedTab = name
        for category, page in pairs(panel.pages) do
            if category == name then page:Show() else page:Hide() end
            UI:SetTabSelected(panel.tabs[category], category == name)
        end
        SetFeedback(panel)
        addon:RefreshOptions()
    end
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

    panel.welcome = UI:Button(panel, "Back to welcome")
    panel.welcome:SetPoint("TOPLEFT", 24, -492)
    panel.welcome:SetSize(160, 34)
    panel.welcome:SetScript("OnClick", function() addon:OpenWelcome() end)

    panel:SetScript("OnShow", function()
        UI:Fit(panel)
        ResetConfirmation(panel)
        HideSecret(panel, true)
        panel.autoJoin:SetChecked(addon.db.chat.autoJoin)
        panel.positionSharing:SetChecked(addon.db.position.sharing)
        panel.positionRetention:SetChecked(addon.db.position.keepLastKnown)
        SetFeedback(panel)
        addon:RefreshOptions()
    end)
    panel:SetScript("OnHide", function()
        HideSecret(panel, true)
        ResetConfirmation(panel)
        panel:StopMovingOrSizing()
    end)

    tinsert(UISpecialFrames, "LockInToolsOptions")
    UI:Finish(panel)
    return panel
end

function addon:RefreshOptions()
    self:RefreshWelcome()
    local panel = self.optionsPanel
    if not panel or not self.initialized then
        return
    end

    panel.groupStatus:SetText("Group: " .. self:GetGroupStatusText())
    panel.status:SetText("Status: " .. self:GetChatStatusText())
    panel.positionStatus:SetText("Status: " .. self:GetPositionStatusText())

    -- Status events must preserve the group key and feature preferences being edited.
    local editable = not self.savedDataReadOnly
    local hasGroup = self:HasGroup()
    panel.secret:SetEnabled(editable)
    panel.applyGroup:SetEnabled(editable)
    panel.createGroup:SetEnabled(editable)
    panel.toggleSecret:SetEnabled(editable)
    panel.leaveGroup:SetEnabled(editable and hasGroup)
    panel.autoJoin:SetEnabled(editable)
    panel.save:SetEnabled(editable)
    panel.positionSharing:SetEnabled(editable)
    panel.positionRetention:SetEnabled(editable)
    panel.savePosition:SetEnabled(editable)
    panel.join:SetEnabled(self.ready and hasGroup)
    panel.leave:SetEnabled(self.ready and hasGroup)
    if not editable then
        HideSecret(panel, true)
        SetFeedback(panel, "Update LockInTools before changing saved preferences.", true)
    end
end

function addon:OpenOptions()
    if not self.initialized then
        self:Print("Still loading. Please try again after login.")
        return
    end

    if self.welcomePanel then self.welcomePanel:Hide() end
    if not self.optionsPanel then
        self.optionsPanel = CreateOptionsPanel()
    end

    self.optionsPanel:Show()
    self.optionsPanel:Raise()
end

local function ResetWelcomeConfirmation(panel)
    panel.pendingSecret = nil
    panel.joinGroup:SetText("Join friend")
end

local function JoinFriend(panel)
    local secret = panel.friendSecret:GetText():match("^%s*(.-)%s*$")
    if secret == "" then
        ResetWelcomeConfirmation(panel)
        SetFeedback(panel, "Enter your friend's key first.", true)
        return
    end

    if addon:HasGroup() and secret:lower() ~= addon:GetGroupSecret():lower()
        and panel.pendingSecret ~= secret then
        ResetWelcomeConfirmation(panel)
        panel.pendingSecret = secret
        panel.joinGroup:SetText("Confirm switch")
        SetFeedback(panel, "Click Confirm switch to use your friend's key for all LockInTools features.", true)
        return
    end

    local success, message = addon:SetGroupSecret(secret)
    ResetWelcomeConfirmation(panel)
    if not success then
        SetFeedback(panel, message or "Unable to save your friend's key.", true)
        return
    end

    panel.friendSecret:SetText("")
    panel.friendSecret:ClearFocus()
    SetFeedback(panel, "Key saved. You and your friends now use the same group.", false)
    addon:RefreshOptions()
end

local function CreateWelcomePanel()
    local panel = UI:Window("LockInToolsWelcome", 620, 550)
    local heading = UI:Label(panel, "Welcome to LockInTools", 22, "heading")
    heading:SetPoint("TOPLEFT", 24, -76)

    local introduction = UI:Label(panel,
        "Playing together starts with the same key. Share yours, or enter a friend's key below.", 14, "muted")
    introduction:SetPoint("TOPLEFT", 24, -114)
    introduction:SetWidth(572)

    local own = UI:Section(panel, 20, 170, 580, 112, "Your secret key")
    panel.ownSecret = UI:EditBox(own)
    panel.ownSecret:SetPoint("TOPLEFT", 16, -43)
    panel.ownSecret:SetSize(410, 34)
    panel.ownSecret:SetAutoFocus(false)
    panel.ownSecret:SetPassword(false)
    -- Keep the saved key selectable for copying without accepting edits.
    panel.ownSecret:SetScript("OnTextChanged", function(editBox)
        local secret = panel.showingKeys and addon:GetGroupSecret() or ""
        if editBox:GetText() ~= secret then
            editBox:SetText(secret)
        end
    end)
    panel.ownSecret:SetScript("OnEditFocusGained", function(editBox)
        editBox:HighlightText()
    end)
    panel.ownSecret:SetScript("OnEscapePressed", function(editBox)
        editBox:ClearFocus()
    end)
    panel.ownSecret:SetScript("OnEnterPressed", function(editBox)
        editBox:ClearFocus()
    end)

    panel.selectKey = UI:Button(own, "Select key", "primary")
    panel.selectKey:SetPoint("TOPLEFT", 438, -43)
    panel.selectKey:SetSize(126, 34)
    panel.selectKey:SetScript("OnClick", function()
        panel.ownSecret:SetFocus()
        panel.ownSecret:HighlightText()
        SetFeedback(panel, "Press Ctrl+C to copy your key, then share it with your friends.", false)
    end)

    local copyHint = UI:Label(own,
        "This key is saved. Select it and press Ctrl+C to copy it.", 12, "muted")
    copyHint:SetPoint("TOPLEFT", 16, -86)
    copyHint:SetWidth(548)

    local friend = UI:Section(panel, 20, 294, 580, 96, "Have a friend's key?")
    panel.friendSecret = UI:EditBox(friend)
    panel.friendSecret:SetPoint("TOPLEFT", 16, -43)
    panel.friendSecret:SetSize(410, 34)
    panel.friendSecret:SetAutoFocus(false)
    panel.friendSecret:SetScript("OnEscapePressed", function(editBox)
        editBox:ClearFocus()
    end)
    panel.friendSecret:SetScript("OnEnterPressed", function()
        JoinFriend(panel)
    end)
    panel.friendSecret:SetScript("OnTextChanged", function(_, userInput)
        if userInput then
            ResetWelcomeConfirmation(panel)
            SetFeedback(panel)
        end
    end)

    panel.joinGroup = UI:Button(friend, "Join friend", "primary")
    panel.joinGroup:SetPoint("TOPLEFT", 438, -43)
    panel.joinGroup:SetSize(126, 34)
    panel.joinGroup:SetScript("OnClick", function()
        JoinFriend(panel)
    end)

    panel.feedback = UI:Label(panel, "", 13)
    panel.feedback:SetPoint("TOPLEFT", 24, -406)
    panel.feedback:SetWidth(572)

    local realmHint = UI:Label(panel, "", 12, "muted")
    realmHint:SetPoint("TOPLEFT", 24, -452)
    realmHint:SetWidth(572)
    realmHint:SetText("Shared chat works with friends on the same realm and faction.")

    panel.options = UI:Button(panel, "More options")
    panel.options:SetPoint("TOPLEFT", 24, -492)
    panel.options:SetSize(148, 34)
    panel.options:SetScript("OnClick", function()
        addon:OpenOptions()
    end)

    panel.done = UI:Button(panel, "Done", "primary")
    panel.done:SetPoint("TOPLEFT", 458, -492)
    panel.done:SetSize(138, 34)
    panel.done:SetScript("OnClick", function()
        panel:Hide()
    end)

    panel:SetScript("OnShow", function()
        UI:Fit(panel)
        panel.showingKeys = true
        ResetWelcomeConfirmation(panel)
        SetFeedback(panel)
        addon:RefreshWelcome()
    end)
    panel:SetScript("OnHide", function()
        panel.showingKeys = false
        panel.ownSecret:SetText("")
        panel.ownSecret:ClearFocus()
        panel.friendSecret:SetText("")
        panel.friendSecret:ClearFocus()
        ResetWelcomeConfirmation(panel)
        SetFeedback(panel)
        panel:StopMovingOrSizing()
    end)

    tinsert(UISpecialFrames, "LockInToolsWelcome")
    UI:Finish(panel)
    return panel
end

function addon:RefreshWelcome()
    local panel = self.welcomePanel
    if not panel or not panel.showingKeys or not self.initialized then
        return
    end

    local secret = self:GetGroupSecret()
    if panel.ownSecret:GetText() ~= secret then
        panel.ownSecret:SetText(secret)
    end
    panel.ownSecret:SetEnabled(secret ~= "")
    panel.selectKey:SetEnabled(secret ~= "")
    panel.friendSecret:SetEnabled(not self.savedDataReadOnly)
    panel.joinGroup:SetEnabled(not self.savedDataReadOnly)
    if self.savedDataReadOnly then
        panel.friendSecret:SetText("")
        panel.friendSecret:ClearFocus()
        ResetWelcomeConfirmation(panel)
        SetFeedback(panel, "Update LockInTools before changing saved preferences.", true)
    elseif self.invalidGroupSecret then
        SetFeedback(panel, "Your saved key is invalid. Enter a friend's key, or use More options to create a group.", true)
    end
end

function addon:OpenWelcome()
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

    if not self.welcomePanel then
        self.welcomePanel = CreateWelcomePanel()
    end
    self.welcomePanel:Show()
    self.welcomePanel:Raise()
    self:RefreshWelcome()
    if problem then SetFeedback(self.welcomePanel, problem, true) end
end
