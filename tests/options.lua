-- Focused Settings callbacks; the shared mocks are never loaded by the addon.
local support = dofile("tests/support/addon.lua")
local loadAddon, settings, contains = support.loadAddon, support.settings, support.contains
local SECRET, OTHER_SECRET = support.SECRET, support.OTHER_SECRET
local loadOptions = dofile("tests/support/ui.lua")

-- Group help supplements readable key fields without exposing keys or interrupting confirmation.
do
    local groupAddon, api, _, _, groupWorld = loadAddon(settings(SECRET, false), false)
    groupWorld:initialize()
    loadOptions(groupAddon, api)
    groupAddon:OpenOptions()
    local options, tooltip = groupAddon.optionsPanel, api.GameTooltip
    local function hover(widget)
        widget.scripts.OnEnter(widget)
        assert(tooltip.shown and tooltip.owner == widget, "group controls show their own help on hover")
        local text = tooltip.text .. "\n" .. table.concat(tooltip.lines, "\n")
        assert(not text:find(SECRET, 1, true) and not text:find(OTHER_SECRET, 1, true),
            "group tooltips never include a saved or entered key")
        return text
    end
    local info = hover(options.groupInfo)
    assert(info:find("characters", 1, true) and info:find("every LockInTools feature", 1, true)
        and info:find("same realm and faction", 1, true)
        and info:find("Group ID: " .. groupAddon:GetGroupFingerprint(), 1, true),
        "Group info explains scope and sharing limits with a public identifier instead of the key")
    options.groupInfo.scripts.OnLeave(options.groupInfo)
    assert(not tooltip.shown, "leaving a help control dismisses its tooltip")
    options.secret:UserInput(" \t ")
    assert(not options.applyGroup:IsEnabled(), "whitespace drafts cannot be applied")
    options.secret:UserInput(OTHER_SECRET)
    assert(options.applyGroup:IsEnabled() and options.secret:GetText() == OTHER_SECRET
        and not options.toggleSecret, "entered keys stay readable without a reveal control")
    for _, widget in ipairs({ options.ownSecret, options.selectKey, options.secret,
        options.applyGroup, options.createGroup, options.leaveGroup }) do
        hover(widget)
        widget.scripts.OnHide(widget)
        assert(not tooltip.shown, "hiding a group control dismisses its tooltip")
    end
    options.applyGroup:Click()
    local confirmation = options.feedback:GetText()
    options.selectKey:Click()
    hover(options.applyGroup)
    assert(options.applyGroup:GetText() == "Confirm switch" and options.feedback:GetText() == confirmation
        and options.secret:GetText() == OTHER_SECRET and groupAddon:GetGroupSecret() == SECRET,
        "copying the saved key and reading help preserve the draft and pending switch warning")
    options.tabs.chat:Click()
    assert(not tooltip.shown and options.secret:GetText() == "" and options.ownSecret:GetText() == ""
        and options.applyGroup:GetText() == "Use key", "leaving Group clears keys, confirmation and owned help")
    options.tabs.group:Click()
    hover(options.groupInfo)
    options.content:Click()
    assert(not tooltip.shown, "switching to Content dismisses Group help")
    groupAddon:OpenOptions("group")
    hover(options.selectKey)
    options.parent.CloseButton:Click()
    assert(not tooltip.shown and options.ownSecret:GetText() == "", "closing Settings clears keys and help")
    groupAddon:OpenOptions("group")
    tooltip:SetOwner(options.tabs.chat, "ANCHOR_RIGHT")
    tooltip:Show()
    options.groupInfo.scripts.OnLeave(options.groupInfo)
    options:Hide()
    assert(tooltip.shown, "group cleanup preserves a tooltip owned by another control")
    tooltip:Hide()
    groupAddon:OpenOptions("group")
    assert(groupAddon:LeaveGroup())
    assert(not hover(options.groupInfo):find("Group ID:", 1, true),
        "Group info reflects leaving the group without retaining its identifier")
    options:Hide()
end

-- Chat and position labels are usable click targets; help preserves preferences.
do
    local preferences, api, _, _, preferenceWorld = loadAddon(settings(SECRET, false), false)
    preferenceWorld:initialize()
    loadOptions(preferences, api)
    preferences:OpenOptions("chat")
    local options, tooltip = preferences.optionsPanel, api.GameTooltip
    local function hover(widget)
        widget.scripts.OnEnter(widget)
        assert(tooltip.shown and tooltip.owner == widget, "option help belongs to the hovered control")
        return table.concat(tooltip.lines, "\n")
    end
    assert(hover(options.autoJoin.labelButton):find("disabling it keeps an existing chat connection", 1, true))
    options.autoJoin.labelButton:Click()
    assert(options.autoJoin:GetChecked() and preferences.db.chat.autoJoin and #preferenceWorld.joinCalls == 1,
        "clicking the autojoin label applies once and connects immediately")
    local room = preferences:GetGroupChannelName()
    preferenceWorld:completeJoin(room, 9)
    assert(options.status:GetText():find("Joined", 1, true)
        and not options.status:GetText():find("/lit chat", 1, true)
        and hover(options.chatStatusHelp):find("/lit chat", 1, true),
        "chat keeps concise status on the page and complete details in its tooltip")
    options.autoJoin.labelButton:Click()
    assert(not options.autoJoin:GetChecked() and not preferences.db.chat.autoJoin
        and preferences.chatState.phase == "joined" and #preferenceWorld.leaveCalls == 0,
        "disabling autojoin through its label retains current membership")
    assert(hover(options.leave):find("pause reconnection for this session", 1, true))
    options.tabs.position:Click()
    assert(not tooltip.shown, "leaving Shared chat dismisses its help")
    preferenceWorld:completeJoin(preferences:GetGroupDataChannelName(), 7)
    options.positionSharing.labelButton:Click()
    assert(options.positionSharing:GetChecked() and preferences.db.position.sharing
        and preferences.db.position.keepLastKnown and preferences.db.position.showTrails
        and not preferences.db.chat.autoJoin, "sharing's label changes only its own preference")
    assert(options.positionStatus:GetText() == "Sharing: On."
        and hover(options.positionStatusHelp):find("every 2 seconds", 1, true)
        and tooltip.lines[1]:find("world map's LockInTools filter", 1, true),
        "healthy position status is concise while timing and map-filter help remain available")
    options.positionRetention.labelButton:Click()
    do
        local state = preferences.positionState
        local timer, generation = state.timer, state.generation
        local sample, stamp, succeeded = state.lastSentSample, state.lastSentAt, state.lastSendSucceeded
        local discovery, attempts = state.classRequestPending, state.classRequestAttempts
        local joins, sends = #preferenceWorld.dataJoinCalls, #preferenceWorld.dataSends
        options.positionTrails.labelButton:Click()
        assert(state.timer == timer and state.generation == generation and state.lastSentSample == sample
            and state.lastSentAt == stamp and state.lastSendSucceeded == succeeded
            and state.classRequestPending == discovery and state.classRequestAttempts == attempts
            and #preferenceWorld.dataJoinCalls == joins and #preferenceWorld.dataSends == sends,
            "changing trail visibility preserves sampling, suppression, discovery and transport")
    end
    assert(not options.positionRetention:GetChecked() and not preferences.db.position.keepLastKnown
        and not options.positionTrails:GetChecked() and not preferences.db.position.showTrails
        and preferences.db.position.sharing,
        "retention and trails labels apply independent settings")
    assert(not options.positionTrailLength
        and hover(options.positionTrails.labelButton):find("10 seconds", 1, true)
        and not preferences.db.position.showTrails,
        "trail help explains the fixed duration without a length editor or changing visibility")
    options.tabs.chat:Click()
    assert(not tooltip.shown and not preferences.db.position.showTrails,
        "leaving Shared positions clears help and preserves its preferences")
    hover(options.join)
    options.content:Click()
    assert(not tooltip.shown, "switching windows dismisses Shared chat help")
    preferences:OpenOptions("position")
    preferences.savedDataReadOnly = true
    preferences:RefreshOptions()
    for _, checkbox in ipairs({ options.autoJoin, options.positionSharing,
        options.positionRetention, options.positionTrails }) do
        local checked = checkbox:GetChecked()
        assert(not checkbox:IsEnabled() and not checkbox.labelButton:IsEnabled(),
            "read-only settings disable the checkbox and its label together")
        checkbox.labelButton:Click()
        assert(checkbox:GetChecked() == checked, "disabled label clicks cannot change read-only preferences")
    end
    hover(options.positionSharing.labelButton)
    assert(options.feedback:GetText():find("Update LockInTools", 1, true),
        "help stays accessible without replacing the read-only notice")
    options.parent.CloseButton:Click()
    assert(not tooltip.shown, "closing Settings dismisses Shared positions help")
end

do
local uiAddon, uiEnvironment, uiMessages, _, uiWorld = loadAddon(settings("", false), false)
uiWorld:initialize()
loadOptions(uiAddon, uiEnvironment)
assert(uiAddon.optionsPanel == nil and uiAddon.mainPanel == nil, "build the window and options only when requested")
uiEnvironment.SlashCmdList.LOCKINTOOLS("options")
local panel = uiAddon.optionsPanel
assert(panel and panel:IsShown(), "/lit options opens the actual options panel")
assert(panel.secret:GetText() == "" and not panel.toggleSecret and panel.autoJoin:GetChecked() == false)
assert(panel.positionSharing:GetChecked() == false and panel.positionRetention:GetChecked() == true,
    "position sharing starts off with last-known retention enabled")
assert(panel.positionTrails:GetChecked() == true and not panel.positionTrailLength,
    "trails default on without a duration editor")
assert(panel.save == nil and panel.savePosition == nil, "feature preferences need no Save settings buttons")
assert(not panel.join:IsEnabled() and not panel.leave:IsEnabled(), "no group means no join/leave buttons")
assert(uiEnvironment.UISpecialFrames[1] == "LockInToolsWindow", "Escape can close the native panel")
panel.createGroup:Click()
local generatedDraft = panel.secret:GetText()
assert(generatedDraft:match("^[a-z]+%-%d%d%d%d$")
    and panel.secret.focused and panel.secret.highlighted, "Generate key fills a readable draft ready to copy")
assert(not uiAddon:HasGroup() and uiAddon.db.group.secret == "" and #uiWorld.joinCalls == 0,
    "generating a key does not join or replace a group before Use key")
assert(panel.applyGroup:GetText() == "Use key" and panel.applyGroup:IsEnabled())
panel.secret:SetText("  " .. SECRET:lower() .. "  ")
panel.applyGroup:Click()
assert(uiAddon:GetGroupSecret() == SECRET and uiAddon.db.chat.autoJoin == false,
    "import saves shared identity independently from feature settings")
assert(panel.secret:GetText() == "" and panel.secret.focusCleared)
assert(#uiWorld.joinCalls == 0 and panel.join:IsEnabled() and panel.leave:IsEnabled())
assert(panel.secret:GetText() == "" and not panel.applyGroup:IsEnabled()
    and panel.ownSecret:GetText() == SECRET, "the saved key stays in its copy field instead of refilling an empty draft")
panel.tabs.chat:Click()
panel.join:Click()
panel.tabs.group:Click()
panel.secret:SetText(OTHER_SECRET)
uiWorld:completeJoin(uiAddon:GetGroupChannelName(), 9)
assert(panel.secret:GetText() == OTHER_SECRET and panel.autoJoin:GetChecked() == false,
    "asynchronous status updates preserve key drafts and immediately applied preferences")
assert(panel.positionSharing:GetChecked() == false and panel.positionRetention:GetChecked() == true
    and panel.positionTrails:GetChecked() == true and uiAddon.db.position.showTrails
    and not uiAddon.db.position.sharing and uiAddon.db.position.keepLastKnown,
    "asynchronous status updates retain applied position preferences")
assert(panel.positionStatus:GetText() == "Sharing: " .. uiAddon:GetPositionStatusText(true),
    "position status reflects the current sharing state")
assert(panel.status:GetText():find("Joined", 1, true), "status reflects confirmed membership")
panel.secret:SetText("invalid--key")
panel.applyGroup:Click()
panel.applyGroup:Click()
assert(uiAddon:GetGroupSecret() == SECRET and not uiAddon.db.chat.autoJoin,
    "invalid input preserves group and feature preferences")
assert(panel.feedback:GetText() ~= "" and panel.feedback.color[1] == 1)
panel.secret:SetText(OTHER_SECRET)
panel.tabs.chat:Click()
panel.join:Click()
assert(uiWorld.joinCalls[#uiWorld.joinCalls] == uiAddon:GetGroupChannelName() and panel.secret:GetText() == "",
    "Join uses the saved group after navigating away clears the key draft")
panel.leave:Click()
assert(uiWorld.leaveCalls[#uiWorld.leaveCalls] == uiAddon:GetGroupChannelName() and uiAddon:HasGroup(), "chat leave retains group")
panel.tabs.group:Click()
panel.secret:SetText(OTHER_SECRET)
panel.applyGroup:Click()
assert(uiAddon:GetGroupSecret() == SECRET and panel.applyGroup:GetText() == "Confirm switch")
panel.applyGroup:Click()
assert(uiAddon:GetGroupSecret() == OTHER_SECRET and panel.secret:GetText() == "",
    "switch confirms before changing every feature's group")
assert(panel.ownSecret:GetText() == OTHER_SECRET)
panel.secret:UserInput(SECRET)
panel.secret:SetFocus()
uiAddon.mainPanel:Hide()
assert(panel.secret:GetText() == "" and panel.ownSecret:GetText() == "" and not panel.secret.focused,
    "closing clears readable keys and draft focus")
uiAddon:OpenOptions()
assert(uiAddon.optionsPanel == panel and panel.secret:GetText() == "")
assert(panel.positionSharing:GetChecked() == false and panel.positionRetention:GetChecked() == true
    and panel.positionTrails:GetChecked() == true
    and not panel.autoJoin:GetChecked(), "closing and reopening retains immediately applied preferences")
panel.tabs.chat:Click()
panel.tabs.group:Click()
panel.secret:SetText(SECRET)
panel.secret.scripts.OnEnterPressed(panel.secret)
assert(uiAddon:GetGroupSecret() == OTHER_SECRET, "Enter also requires switch confirmation")
panel.secret:SetText(OTHER_SECRET)
panel.secret.scripts.OnTextChanged(panel.secret, true)
panel.applyGroup:Click()
assert(uiAddon:GetGroupSecret() == OTHER_SECRET and not uiAddon.db.chat.autoJoin,
    "using a secret preserves the independently applied feature preference")
panel.createGroup:Click()
local replacementDraft = panel.secret:GetText()
assert(replacementDraft:match("^[a-z]+%-%d%d%d%d$") and uiAddon:GetGroupSecret() == OTHER_SECRET,
    "Create leaves the configured group intact while drafting a replacement")
panel.applyGroup:Click()
assert(uiAddon:GetGroupSecret() == OTHER_SECRET and panel.applyGroup:GetText() == "Confirm switch")
panel.applyGroup:Click()
assert(uiAddon:GetGroupSecret() == replacementDraft and panel.secret:GetText() == "",
    "generated key uses the same confirmation and clears after applying")
panel.leaveGroup:Click()
assert(uiAddon:HasGroup() and panel.leaveGroup:GetText() == "Confirm leave")
panel.leaveGroup:Click()
assert(not uiAddon:HasGroup() and not panel.join:IsEnabled() and not panel.leave:IsEnabled())
assert(not contains(uiMessages, SECRET) and not contains(uiMessages, OTHER_SECRET))
assert(not contains(uiMessages, generatedDraft) and not contains(uiMessages, replacementDraft))
end

do
local newer = { schemaVersion = 4, showWelcome = false, important = "keep",
    group = { secret = SECRET }, chat = { autoJoin = false } }
local readOnly, readOnlyEnvironment, _, _, readOnlyWorld = loadAddon(newer, false)
readOnlyWorld:initialize()
loadOptions(readOnly, readOnlyEnvironment)
readOnly:OpenOptions()
assert(not readOnly.optionsPanel.secret:IsEnabled()
    and not readOnly.optionsPanel.applyGroup:IsEnabled()
    and not readOnly.optionsPanel.createGroup:IsEnabled()
    and not readOnly.optionsPanel.autoJoin:IsEnabled()
    and not readOnly.optionsPanel.positionSharing:IsEnabled()
    and not readOnly.optionsPanel.positionRetention:IsEnabled()
    and not readOnly.optionsPanel.positionTrails:IsEnabled()
    and not readOnly.optionsPanel.save and not readOnly.optionsPanel.savePosition,
    "read-only settings disable every immediately applied preference")
assert(readOnly.optionsPanel.feedback:GetText():find("Update LockInTools", 1, true))
readOnly.optionsPanel.tabs.chat:Click()
assert(readOnly.optionsPanel.feedback:GetText():find("Update LockInTools", 1, true)
    and not readOnly.optionsPanel.autoJoin:IsEnabled(), "category changes retain the read-only notice and disabled edits")
readOnly.optionsPanel.content:Click()
assert(readOnly.contentPanel.pages.overview:IsVisible() and not readOnly.optionsPanel:IsShown()
    and readOnly.contentPanel.feedback:GetText():find("Update LockInTools", 1, true),
    "Content retains the newer-schema read-only notice")
readOnly.contentPanel.options:Click()
assert(readOnly.optionsPanel.selectedTab == "chat" and not readOnly.optionsPanel.autoJoin:IsEnabled()
    and readOnly.optionsPanel.feedback:GetText():find("Update LockInTools", 1, true),
    "returning to Settings restores its page without enabling read-only edits")

end

-- Programmatic refreshes never save preferences, including profiles with an obsolete duration.
do
    local oldSettings = settings(SECRET, false)
    oldSettings.position = { sharing = false, keepLastKnown = true, showTrails = true, trailLength = 27 }
    local direct, directEnvironment, _, _, directWorld = loadAddon(oldSettings, false)
    directWorld:initialize()
    local trailCalls, setTrails = 0, direct.SetShowPositionTrails
    direct.SetShowPositionTrails = function(self, ...)
        trailCalls = trailCalls + 1
        return setTrails(self, ...)
    end
    loadOptions(direct, directEnvironment)
    direct:OpenOptions()
    local options = direct.optionsPanel
    options.tabs.position:Click()
    options.positionSharing:SetChecked(true)
    options.positionRetention:SetChecked(false)
    options.positionTrails:SetChecked(false)
    options.autoJoin:SetChecked(true)
    direct:RefreshOptions()
    assert(trailCalls == 0 and direct.db.position.trailLength == 27
        and not direct.db.position.sharing and direct.db.position.keepLastKnown
        and direct.db.position.showTrails and not direct.db.chat.autoJoin,
        "loading and programmatically updating controls never applies preferences")
    direct.mainPanel:Hide()
    direct:OpenOptions()
    assert(trailCalls == 0 and not options.positionTrailLength
        and not options.positionSharing:GetChecked() and options.positionRetention:GetChecked()
        and options.positionTrails:GetChecked() and not options.autoJoin:GetChecked(),
        "reopening restores saved values without invoking setters")
    options.positionTrails:Click()
    direct:RefreshOptions()
    assert(trailCalls == 1 and not direct.db.position.showTrails and direct.db.position.trailLength == 27,
        "a trail toggle applies once and leaves the obsolete saved duration untouched")
    options.tabs.chat:Click()
    options.tabs.position:Click()
    direct.mainPanel:Hide()
    direct:OpenOptions()
    assert(trailCalls == 1 and not options.positionTrails:GetChecked()
        and direct.db.position.trailLength == 27,
        "navigation and reopening retain trail visibility without applying or repairing a duration")

    direct.savedDataReadOnly = true
    direct:RefreshOptions()
    for _, preference in ipairs({ { options.autoJoin, direct.db.chat, "autoJoin" },
        { options.positionSharing, direct.db.position, "sharing" },
        { options.positionRetention, direct.db.position, "keepLastKnown" },
        { options.positionTrails, direct.db.position, "showTrails" } }) do
        local control, saved, name = unpack(preference)
        local previous = saved[name]
        control:SetChecked(not previous)
        control.scripts.OnClick(control)
        assert(saved[name] == previous and control:GetChecked() == previous
            and options.feedback.color[1] == 1,
            "rejected immediate changes restore the saved checkbox and report the read-only error")
    end
    assert(direct.db.position.trailLength == 27,
        "read-only checkbox rejection preserves the obsolete saved duration")
end


assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep test environments isolated")
print("PASS: Settings group lifecycle, preference callbacks, help, read-only settings and secret cleanup")

