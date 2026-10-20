-- Core Settings interactions; shared widgets are mocked offline.
local support = dofile("tests/support/addon.lua")
local loadAddon, settings, contains = support.loadAddon, support.settings, support.contains
local SECRET, OTHER_SECRET = support.SECRET, support.OTHER_SECRET
local loadOptions = dofile("tests/support/ui.lua")

-- Drafting, applying and leaving a group require explicit actions and never print keys.
do
    local addon, api, messages, _, world = loadAddon(settings("", false), false)
    world:initialize()
    loadOptions(addon, api)
    assert(not addon.optionsPanel and not addon.mainPanel)
    api.SlashCmdList.LOCKINTOOLS("options")
    local panel = addon.optionsPanel
    assert(panel:IsVisible() and not panel.join:IsEnabled() and not panel.leave:IsEnabled())
    panel.createGroup:Click()
    local generated = panel.secret:GetText()
    assert(generated:match("^[a-z]+%-%d%d%d%d$") and not addon:HasGroup(),
        "generation produces a draft without joining")
    panel.secret:UserInput(" \t ")
    assert(not panel.applyGroup:IsEnabled())
    panel.secret:UserInput("  " .. SECRET:lower() .. "  ")
    panel.applyGroup:Click()
    assert(addon:GetGroupSecret() == SECRET and panel.ownSecret:GetText() == SECRET
        and panel.secret:GetText() == "" and not panel.applyGroup:IsEnabled()
        and #world.joinCalls == 0, "applying saves the identity independently of chat autojoin")

    panel.tabs.chat:Click()
    panel.join:Click()
    panel.tabs.group:Click()
    panel.secret:UserInput(OTHER_SECRET)
    world:completeJoin(addon:GetGroupChannelName(), 9)
    assert(panel.secret:GetText() == OTHER_SECRET and not panel.autoJoin:GetChecked(),
        "asynchronous status updates preserve drafts and preferences")
    panel.secret:UserInput("invalid--key")
    panel.applyGroup:Click()
    panel.applyGroup:Click()
    assert(addon:GetGroupSecret() == SECRET and panel.feedback:GetText() ~= "")

    panel.secret:UserInput(OTHER_SECRET)
    panel.applyGroup:Click()
    assert(addon:GetGroupSecret() == SECRET and panel.pendingSecret == OTHER_SECRET)
    panel.secret:UserInput("replacement-friend")
    assert(not panel.pendingSecret, "editing a draft cancels its previous confirmation")
    panel.applyGroup:Click()
    assert(addon:GetGroupSecret() == SECRET and panel.pendingSecret == "replacement-friend")
    panel.secret:UserInput(OTHER_SECRET)
    panel.applyGroup:Click()
    panel.selectKey:Click()
    assert(panel.secret:GetText() == OTHER_SECRET and panel.pendingSecret == OTHER_SECRET,
        "copying the saved key preserves the pending draft")
    panel.applyGroup:Click()
    world:advance(0)
    assert(addon:GetGroupSecret() == OTHER_SECRET and panel.secret:GetText() == ""
        and panel.ownSecret:GetText() == OTHER_SECRET)

    panel.secret:UserInput(SECRET)
    panel.secret:SetFocus()
    addon.mainPanel:Hide()
    assert(panel.secret:GetText() == "" and panel.ownSecret:GetText() == ""
        and not panel.secret.focused, "closing clears keys and draft focus")
    addon:OpenOptions()
    panel.leaveGroup:Click()
    assert(addon:HasGroup(), "leaving also requires confirmation")
    panel.leaveGroup:Click()
    world:advance(0)
    assert(not addon:HasGroup() and not panel.join:IsEnabled() and not panel.leave:IsEnabled())
    for _, key in ipairs({ SECRET, OTHER_SECRET, generated }) do
        assert(not contains(messages, key), "group actions never print keys")
    end
end

-- Refreshing controls does not save; each user click applies its preference once.
do
    local addon, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    local calls = {}
    for _, name in ipairs({ "SetChatAutoJoin", "SetPositionSharing", "SetPositionRetention" }) do
        local setter, name = addon[name], name
        calls[name] = 0
        addon[name] = function(self, ...)
            calls[name] = calls[name] + 1
            return setter(self, ...)
        end
    end
    loadOptions(addon, api)
    addon:OpenOptions("position")
    local panel = addon.optionsPanel
    panel.autoJoin:SetChecked(true)
    panel.positionSharing:SetChecked(true)
    panel.positionRetention:SetChecked(false)
    addon:RefreshOptions()
    assert(not addon.db.chat.autoJoin and not addon.db.position.sharing and addon.db.position.keepLastKnown)
    for _, count in pairs(calls) do assert(count == 0) end
    addon.mainPanel:Hide()
    addon:OpenOptions()
    panel.autoJoin:Click()
    panel.positionSharing:Click()
    panel.positionRetention:Click()
    addon.mainPanel:Hide()
    addon:OpenOptions()
    assert(panel.autoJoin:GetChecked() and panel.positionSharing:GetChecked()
        and not panel.positionRetention:GetChecked())
    assert(addon.db.chat.autoJoin and addon.db.position.sharing and not addon.db.position.keepLastKnown)
    for _, count in pairs(calls) do assert(count == 1) end
end

-- Future-schema profiles allow navigation while every editing path preserves saved data.
do
    local saved = { schemaVersion = 4, showWelcome = false, important = "keep",
        group = { secret = SECRET }, chat = { autoJoin = false } }
    local addon, api, _, _, world = loadAddon(saved, false)
    world:initialize()
    loadOptions(addon, api)
    addon:OpenOptions()
    local panel = addon.optionsPanel
    for _, control in ipairs({ panel.secret, panel.applyGroup, panel.createGroup,
        panel.autoJoin, panel.positionSharing, panel.positionRetention }) do
        assert(not control:IsEnabled())
    end
    for _, preference in ipairs({ { panel.autoJoin, addon.db.chat, "autoJoin" },
        { panel.positionSharing, addon.db.position, "sharing" },
        { panel.positionRetention, addon.db.position, "keepLastKnown" } }) do
        local control, model, key = unpack(preference)
        local previous = model[key]
        control:SetChecked(not previous)
        control.scripts.OnClick(control)
        assert(model[key] == previous and control:GetChecked() == previous,
            "even a directly invoked callback cannot write read-only preferences")
    end
    panel.tabs.chat:Click()
    panel.content:Click()
    for _, event in ipairs({ "GROUP_CHANGED", "CHAT_CHANGED", "DATA_CHANGED", "POSITIONS_CHANGED" }) do
        addon:Notify(event)
    end
    assert(panel.secret:GetText() == "" and panel.ownSecret:GetText() == "")
    addon.contentPanel.options:Click()
    assert(panel.selectedTab == "chat" and not panel.autoJoin:IsEnabled())
    assert(api.LockInToolsDB == saved and saved.schemaVersion == 4 and saved.important == "keep"
        and saved.group.secret == SECRET and not saved.chat.autoJoin)
end

-- Every settings help path uses the global anchor and retains owner-based cleanup.
do
    local addon, api, _, _, world = loadAddon(settings("", false), false)
    world:initialize()
    loadOptions(addon, api)
    api.GameTooltip_SetDefaultAnchor = function(tooltip, owner)
        tooltip:SetOwner(owner, "ANCHOR_CURSOR")
    end
    addon:OpenOptions("group")
    local panel, tooltip = addon.optionsPanel, api.GameTooltip
    panel.groupInfo.scripts.OnEnter(panel.groupInfo)
    assert(tooltip:IsShown() and tooltip:IsOwned(panel.groupInfo) and tooltip.anchor == "ANCHOR_CURSOR",
        "Settings help follows the global tooltip position")
    panel.tabs.chat:Click()
    assert(not tooltip:IsShown(), "switching settings pages dismisses globally positioned help")
    assert(not panel.join:IsEnabled(), "a groupless profile has a disabled Join control")
    for _, widget in ipairs({ panel.autoJoin, panel.autoJoin.labelButton, panel.join }) do
        widget.scripts.OnEnter(widget)
        assert(tooltip:IsShown() and tooltip:IsOwned(widget) and tooltip.anchor == "ANCHOR_CURSOR",
            "checkboxes, labels and disabled control help share global tooltip positioning")
        widget.scripts.OnLeave(widget)
        assert(not tooltip:IsShown(), "leaving each control dismisses its own help")
    end
    panel.tabs.restedxp:Click()
    panel.restedxpBattleTag.scripts.OnEnter(panel.restedxpBattleTag)
    assert(tooltip:IsOwned(panel.restedxpBattleTag) and tooltip.anchor == "ANCHOR_CURSOR",
        "RestedXP input help also follows global positioning")
    addon.mainPanel:Hide()
    assert(not tooltip:IsShown(), "closing Settings dismisses its globally positioned tooltip")
    addon:OpenOptions("group")
    local foreignOwner = {}
    tooltip:SetOwner(foreignOwner, "ANCHOR_CURSOR")
    tooltip:Show()
    addon.mainPanel:Hide()
    assert(tooltip:IsShown() and tooltip:IsOwned(foreignOwner),
        "closing Settings preserves a tooltip owned by another control")
end

print("PASS: Settings group lifecycle, preference callbacks, read-only settings and key privacy")
