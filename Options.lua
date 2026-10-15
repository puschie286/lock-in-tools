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

local function CreateOptionsPanel()
    local panel = CreateFrame("Frame", "LockInToolsOptions", UIParent, "BasicFrameTemplateWithInset")
    panel:SetSize(580, 590)
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
    panel.groupStatus:SetWidth(540)
    panel.groupStatus:SetJustifyH("LEFT")

    local introduction = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    introduction:SetPoint("TOPLEFT", 20, -102)
    introduction:SetWidth(540)
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
    privacyHint:SetWidth(540)
    privacyHint:SetJustifyH("LEFT")
    privacyHint:SetText("Share the same key with your friends.")

    local chatHeading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    chatHeading:SetPoint("TOPLEFT", 20, -300)
    chatHeading:SetText("Shared chat")

    local chatIntroduction = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    chatIntroduction:SetPoint("TOPLEFT", 20, -330)
    chatIntroduction:SetWidth(540)
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
    panel.status:SetWidth(540)
    panel.status:SetJustifyH("LEFT")

    panel.save = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.save:SetSize(150, 26)
    panel.save:SetPoint("TOPLEFT", 20, -453)
    panel.save:SetText("Save chat settings")
    panel.save:SetScript("OnClick", function()
        SaveChatSettings(panel)
    end)

    panel.join = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.join:SetSize(118, 26)
    panel.join:SetPoint("LEFT", panel.save, "RIGHT", 10, 0)
    panel.join:SetText("Join chat")
    panel.join:SetScript("OnClick", function()
        SetFeedback(panel)
        addon:JoinChatChannel(true)
        addon:RefreshOptions()
    end)

    panel.leave = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.leave:SetSize(118, 26)
    panel.leave:SetPoint("LEFT", panel.join, "RIGHT", 10, 0)
    panel.leave:SetText("Leave chat")
    panel.leave:SetScript("OnClick", function()
        SetFeedback(panel)
        addon:LeaveChatChannel()
        addon:RefreshOptions()
    end)

    local chatHint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    chatHint:SetPoint("TOPLEFT", 20, -492)
    chatHint:SetWidth(540)
    chatHint:SetJustifyH("LEFT")
    chatHint:SetText("Use /lit chat to write. Leaving chat keeps your LockInTools group.")

    panel.feedback = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    panel.feedback:SetPoint("TOPLEFT", 20, -526)
    panel.feedback:SetWidth(540)
    panel.feedback:SetJustifyH("LEFT")

    panel:SetScript("OnShow", function()
        ResetConfirmation(panel)
        HideSecret(panel, true)
        panel.autoJoin:SetChecked(addon.db.chat.autoJoin)
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
    local panel = self.optionsPanel
    if not panel or not self.initialized then
        return
    end

    panel.groupStatus:SetText("Group: " .. self:GetGroupStatusText())
    panel.status:SetText("Status: " .. self:GetChatStatusText())

    -- Status events must preserve any secret or chat preference being edited.
    local editable = not self.savedDataReadOnly
    local hasGroup = self:HasGroup()
    panel.secret:SetEnabled(editable)
    panel.applyGroup:SetEnabled(editable)
    panel.createGroup:SetEnabled(editable)
    panel.toggleSecret:SetEnabled(editable)
    panel.leaveGroup:SetEnabled(editable and hasGroup)
    panel.autoJoin:SetEnabled(editable)
    panel.save:SetEnabled(editable)
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
