local _, addon = ...

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
    local panel = CreateFrame("Frame", "LockInToolsOptions", UIParent, "BasicFrameTemplateWithInset")
    panel:SetSize(800, 590)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("DIALOG")
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:Hide()
    panel.TitleText:SetText("LockInTools")

    local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    heading:SetPoint("TOPLEFT", 20, -42)
    heading:SetText("Group")

    panel.groupStatus = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    panel.groupStatus:SetPoint("TOPLEFT", 20, -72)
    panel.groupStatus:SetWidth(760)
    panel.groupStatus:SetJustifyH("LEFT")

    local introduction = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    introduction:SetPoint("TOPLEFT", 20, -102)
    introduction:SetWidth(760)
    introduction:SetJustifyH("LEFT")
    introduction:SetText("Use the same key as your friends. Your group applies to every LockInTools feature.")

    local secretLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    secretLabel:SetPoint("TOPLEFT", 20, -146)
    secretLabel:SetText("Group key")

    panel.secret = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    panel.secret:SetPoint("TOPLEFT", 25, -169)
    panel.secret:SetSize(410, 26)
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

    panel.applyGroup = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.applyGroup:SetSize(110, 26)
    panel.applyGroup:SetPoint("TOPLEFT", 447, -169)
    panel.applyGroup:SetText("Use key")
    panel.applyGroup:SetScript("OnClick", function()
        ApplyGroup(panel)
    end)

    panel.createGroup = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.createGroup:SetSize(118, 26)
    panel.createGroup:SetPoint("TOPLEFT", 20, -208)
    panel.createGroup:SetText("Create group")
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

    panel.toggleSecret = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.toggleSecret:SetSize(118, 26)
    panel.toggleSecret:SetPoint("LEFT", panel.createGroup, "RIGHT", 10, 0)
    panel.toggleSecret:SetText("Show key")
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

    panel.leaveGroup = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.leaveGroup:SetSize(118, 26)
    panel.leaveGroup:SetPoint("LEFT", panel.toggleSecret, "RIGHT", 10, 0)
    panel.leaveGroup:SetText("Leave group")
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

    local privacyHint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    privacyHint:SetPoint("TOPLEFT", 20, -249)
    privacyHint:SetWidth(760)
    privacyHint:SetJustifyH("LEFT")
    privacyHint:SetText("Share the same key with your friends.")

    local chatHeading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    chatHeading:SetPoint("TOPLEFT", 20, -300)
    chatHeading:SetText("Shared chat")

    local chatIntroduction = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    chatIntroduction:SetPoint("TOPLEFT", 20, -330)
    chatIntroduction:SetWidth(360)
    chatIntroduction:SetJustifyH("LEFT")
    chatIntroduction:SetText("Your group selects its shared channel automatically. Friends must be on the same realm and faction.")

    panel.autoJoin = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    panel.autoJoin:SetPoint("TOPLEFT", 16, -374)
    panel.autoJoin:SetSize(28, 28)
    local autoJoinLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    autoJoinLabel:SetPoint("LEFT", panel.autoJoin, "RIGHT", 2, 0)
    autoJoinLabel:SetText("Automatically join shared chat on login")

    panel.status = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    panel.status:SetPoint("TOPLEFT", 20, -417)
    panel.status:SetWidth(360)
    panel.status:SetJustifyH("LEFT")

    panel.save = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.save:SetSize(130, 26)
    panel.save:SetPoint("TOPLEFT", 20, -453)
    panel.save:SetText("Save chat settings")
    panel.save:SetScript("OnClick", function()
        SaveChatSettings(panel)
    end)

    panel.join = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.join:SetSize(90, 26)
    panel.join:SetPoint("LEFT", panel.save, "RIGHT", 10, 0)
    panel.join:SetText("Join chat")
    panel.join:SetScript("OnClick", function()
        SetFeedback(panel)
        addon:JoinChatChannel(true)
        addon:RefreshOptions()
    end)

    panel.leave = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.leave:SetSize(90, 26)
    panel.leave:SetPoint("LEFT", panel.join, "RIGHT", 10, 0)
    panel.leave:SetText("Leave chat")
    panel.leave:SetScript("OnClick", function()
        SetFeedback(panel)
        addon:LeaveChatChannel()
        addon:RefreshOptions()
    end)

    local chatHint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    chatHint:SetPoint("TOPLEFT", 20, -492)
    chatHint:SetWidth(360)
    chatHint:SetJustifyH("LEFT")
    chatHint:SetText("Use /lit chat to write. Leaving chat keeps your LockInTools group.")

    local positionHeading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    positionHeading:SetPoint("TOPLEFT", 420, -300)
    positionHeading:SetText("Shared positions")

    local positionIntroduction = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    positionIntroduction:SetPoint("TOPLEFT", 420, -330)
    positionIntroduction:SetWidth(360)
    positionIntroduction:SetJustifyH("LEFT")
    positionIntroduction:SetText("See your friends on the world map. Keep their last-known positions when they go offline.")

    panel.positionSharing = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    panel.positionSharing:SetPoint("TOPLEFT", 416, -374)
    panel.positionSharing:SetSize(28, 28)
    local positionSharingLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    positionSharingLabel:SetPoint("LEFT", panel.positionSharing, "RIGHT", 2, 0)
    positionSharingLabel:SetText("Enable position sharing")

    panel.positionRetention = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    panel.positionRetention:SetPoint("TOPLEFT", 416, -408)
    panel.positionRetention:SetSize(28, 28)
    local positionRetentionLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    positionRetentionLabel:SetPoint("LEFT", panel.positionRetention, "RIGHT", 2, 0)
    positionRetentionLabel:SetText("Keep last-known positions")

    panel.positionStatus = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    panel.positionStatus:SetPoint("TOPLEFT", 420, -450)
    panel.positionStatus:SetWidth(360)
    panel.positionStatus:SetJustifyH("LEFT")

    panel.savePosition = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.savePosition:SetSize(170, 26)
    panel.savePosition:SetPoint("TOPLEFT", 420, -492)
    panel.savePosition:SetText("Save position settings")
    panel.savePosition:SetScript("OnClick", function()
        SavePositionSettings(panel)
    end)

    panel.feedback = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    panel.feedback:SetPoint("TOPLEFT", 20, -526)
    panel.feedback:SetWidth(760)
    panel.feedback:SetJustifyH("LEFT")

    panel:SetScript("OnShow", function()
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
    local panel = CreateFrame("Frame", "LockInToolsWelcome", UIParent, "BasicFrameTemplateWithInset")
    panel:SetSize(560, 440)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("DIALOG")
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:Hide()
    panel.TitleText:SetText("LockInTools")

    local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    heading:SetPoint("TOPLEFT", 24, -44)
    heading:SetText("Welcome to LockInTools")

    local introduction = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    introduction:SetPoint("TOPLEFT", 24, -78)
    introduction:SetWidth(512)
    introduction:SetJustifyH("LEFT")
    introduction:SetText("Playing together starts with the same key. Share yours, or enter a friend's key below.")

    local ownLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    ownLabel:SetPoint("TOPLEFT", 24, -133)
    ownLabel:SetText("Your secret key")

    panel.ownSecret = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    panel.ownSecret:SetPoint("TOPLEFT", 29, -157)
    panel.ownSecret:SetSize(385, 28)
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

    panel.selectKey = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.selectKey:SetPoint("TOPLEFT", 426, -157)
    panel.selectKey:SetSize(110, 28)
    panel.selectKey:SetText("Select key")
    panel.selectKey:SetScript("OnClick", function()
        panel.ownSecret:SetFocus()
        panel.ownSecret:HighlightText()
        SetFeedback(panel, "Press Ctrl+C to copy your key, then share it with your friends.", false)
    end)

    local copyHint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    copyHint:SetPoint("TOPLEFT", 24, -197)
    copyHint:SetWidth(512)
    copyHint:SetJustifyH("LEFT")
    copyHint:SetText("This key is saved. Select it and press Ctrl+C to copy it.")

    local friendLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    friendLabel:SetPoint("TOPLEFT", 24, -241)
    friendLabel:SetText("Have a friend's key?")

    panel.friendSecret = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    panel.friendSecret:SetPoint("TOPLEFT", 29, -265)
    panel.friendSecret:SetSize(385, 28)
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

    panel.joinGroup = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.joinGroup:SetPoint("TOPLEFT", 426, -265)
    panel.joinGroup:SetSize(110, 28)
    panel.joinGroup:SetText("Join friend")
    panel.joinGroup:SetScript("OnClick", function()
        JoinFriend(panel)
    end)

    panel.feedback = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    panel.feedback:SetPoint("TOPLEFT", 24, -309)
    panel.feedback:SetWidth(512)
    panel.feedback:SetJustifyH("LEFT")

    local realmHint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    realmHint:SetPoint("TOPLEFT", 24, -357)
    realmHint:SetText("Shared chat works with friends on the same realm and faction.")

    panel.options = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.options:SetPoint("TOPLEFT", 24, -391)
    panel.options:SetSize(140, 26)
    panel.options:SetText("More options")
    panel.options:SetScript("OnClick", function()
        panel:Hide()
        addon:OpenOptions()
    end)

    panel.done = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.done:SetPoint("TOPLEFT", 426, -391)
    panel.done:SetSize(110, 26)
    panel.done:SetText("Done")
    panel.done:SetScript("OnClick", function()
        panel:Hide()
    end)

    panel:SetScript("OnShow", function()
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
