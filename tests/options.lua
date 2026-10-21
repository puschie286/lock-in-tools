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

    panel.tabs.sharing:Click()
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
    for _, name in ipairs({ "SetChatAutoJoin", "SetPositionSharing", "SetPositionRetention", "SetRankingBurningEffect" }) do
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
    assert(panel.positionSharing:GetChecked(), "Position sharing defaults on in Settings")
    panel.positionSharing:SetChecked(false)
    panel.positionRetention:SetChecked(false)
    panel.rankingBurningEffect:SetChecked(false)
    addon:RefreshOptions()
    assert(not addon.db.chat.autoJoin and addon.db.position.sharing
        and addon.db.position.keepLastKnown
        and addon:GetRankingSettings().burningEffect and panel.rankingBurningEffect:GetChecked())
    for _, count in pairs(calls) do assert(count == 0) end
    addon.mainPanel:Hide()
    addon:OpenOptions()
    panel.autoJoin:Click()
    panel.positionSharing:Click()
    panel.positionRetention:Click()
    panel.rankingBurningEffect:Click()
    addon.mainPanel:Hide()
    addon:OpenOptions()
    assert(panel.autoJoin:GetChecked() and not panel.positionSharing:GetChecked()
        and not panel.positionRetention:GetChecked() and not panel.rankingBurningEffect:GetChecked())
    assert(addon.db.chat.autoJoin and not addon.db.position.sharing and not addon.db.position.keepLastKnown)
    assert(not addon.db.ranking.enabled and not addon.db.ranking.burningEffect,
        "The effect preference stays editable and persists independently of overlay visibility")
    for _, count in pairs(calls) do assert(count == 1) end
end

-- Data channels default on; checkbox and label actions save once and survive reloads.
do
    local addon, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    local calls, setter = { party = 0, guild = 0, global = 0 }, addon.SetDataChannelEnabled
    addon.SetDataChannelEnabled = function(self, channel, enabled)
        calls[channel] = calls[channel] + 1
        return setter(self, channel, enabled)
    end
    loadOptions(addon, api)
    addon:OpenOptions("data")
    local panel = addon.optionsPanel
    for _, checkbox in pairs(panel.dataChannels) do
        assert(checkbox:GetChecked() and checkbox:IsEnabled(), "every data channel defaults on in Settings")
        checkbox:SetChecked(false)
    end
    addon:Notify("DATA_CHANGED")
    for channel, checkbox in pairs(panel.dataChannels) do
        assert(checkbox:GetChecked() and calls[channel] == 0,
            "data notifications refresh preferences without saving them")
    end
    local previousStatus = panel.dataStatus:GetText()
    world.guild = true
    world.fire("PLAYER_GUILD_UPDATE")
    assert(panel.dataStatus:GetText() == addon:GetDataStatusText() and panel.dataStatus:GetText() ~= previousStatus,
        "the Sharing page reflects live route availability")
    for channel, checkbox in pairs(panel.dataChannels) do
        checkbox:Click()
        assert(not addon:GetDataChannelEnabled(channel) and not checkbox:GetChecked() and calls[channel] == 1)
        checkbox.labelButton:Click()
        assert(addon:GetDataChannelEnabled(channel) and checkbox:GetChecked() and calls[channel] == 2,
            "clicking a data channel label uses the same preference action")
        checkbox.labelButton:Click()
        assert(not addon:GetDataChannelEnabled(channel) and calls[channel] == 3)
    end
    addon.mainPanel:Hide()
    addon:OpenOptions("data")
    for _, checkbox in pairs(panel.dataChannels) do assert(not checkbox:GetChecked()) end

    local reloaded, reloadedAPI, _, _, reloadedWorld = loadAddon(api.LockInToolsDB, false)
    reloadedWorld:initialize()
    loadOptions(reloaded, reloadedAPI)
    reloaded:OpenOptions("data")
    for channel, checkbox in pairs(reloaded.optionsPanel.dataChannels) do
        assert(not checkbox:GetChecked() and not reloaded:GetDataChannelEnabled(channel),
            "data channel choices survive a saved-variable reload")
    end
end

-- Future-schema profiles allow navigation while every editing path preserves saved data.
do
    local saved = { schemaVersion = 4, showWelcome = false, important = "keep",
        group = { secret = SECRET }, chat = { autoJoin = false },
        data = { channels = { party = false, guild = true, global = false } } }
    local addon, api, _, _, world = loadAddon(saved, false)
    world:initialize()
    loadOptions(addon, api)
    addon:OpenOptions()
    local panel = addon.optionsPanel
    for _, control in ipairs({ panel.secret, panel.applyGroup, panel.createGroup,
        panel.autoJoin, panel.positionSharing, panel.positionRetention, panel.rankingBurningEffect }) do
        assert(not control:IsEnabled())
    end
    for _, preference in ipairs({ { panel.autoJoin, addon.db.chat, "autoJoin" },
        { panel.positionSharing, addon.db.position, "sharing" },
        { panel.positionRetention, addon.db.position, "keepLastKnown" },
        { panel.rankingBurningEffect, addon:GetRankingSettings(), "burningEffect" } }) do
        local control, model, key = unpack(preference)
        local previous = model[key]
        control:SetChecked(not previous)
        control.scripts.OnClick(control)
        assert(model[key] == previous and control:GetChecked() == previous,
            "even a directly invoked callback cannot write read-only preferences")
    end
    panel.tabs.sharing:Click()
    for channel, checkbox in pairs(panel.dataChannels) do
        local previous = addon:GetDataChannelEnabled(channel)
        assert(not checkbox:IsEnabled() and not checkbox.labelButton:IsEnabled())
        checkbox.labelButton:Click()
        assert(addon:GetDataChannelEnabled(channel) == previous)
        checkbox:SetChecked(not previous)
        checkbox.scripts.OnClick(checkbox)
        assert(addon:GetDataChannelEnabled(channel) == previous and checkbox:GetChecked() == previous,
            "direct data channel callbacks preserve read-only settings and reset their checkboxes")
    end
    panel.tabs.sharing:Click()
    panel.content:Click()
    for _, event in ipairs({ "GROUP_CHANGED", "CHAT_CHANGED", "DATA_CHANGED", "POSITIONS_CHANGED", "RANKING_CHANGED" }) do
        addon:Notify(event)
    end
    assert(panel.secret:GetText() == "" and panel.ownSecret:GetText() == "")
    addon.contentPanel.options:Click()
    assert(panel.selectedTab == "sharing" and not panel.autoJoin:IsEnabled())
    assert(api.LockInToolsDB == saved and saved.schemaVersion == 4 and saved.important == "keep"
        and saved.group.secret == SECRET and not saved.chat.autoJoin and saved.ranking == nil
        and not saved.data.channels.party and saved.data.channels.guild and not saved.data.channels.global)
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
    panel.tabs.sharing:Click()
    assert(not tooltip:IsShown(), "switching settings pages dismisses globally positioned help")
    assert(not panel.join:IsEnabled(), "a groupless profile has a disabled Join control")
    for _, widget in ipairs({ panel.autoJoin, panel.autoJoin.labelButton, panel.join }) do
        widget.scripts.OnEnter(widget)
        assert(tooltip:IsShown() and tooltip:IsOwned(widget) and tooltip.anchor == "ANCHOR_CURSOR",
            "checkboxes, labels and disabled control help share global tooltip positioning")
        widget.scripts.OnLeave(widget)
        assert(not tooltip:IsShown(), "leaving each control dismisses its own help")
    end
    panel.tabs.ranking:Click()
    for _, widget in ipairs({ panel.rankingBurningEffect, panel.rankingBurningEffect.labelButton }) do
        widget.scripts.OnEnter(widget)
        assert(tooltip:IsShown() and tooltip:IsOwned(widget) and tooltip.anchor == "ANCHOR_CURSOR"
            and tooltip.lines[1]:find("70%%") and tooltip.lines[1]:find("both burned meters"),
            "Burning effect help explains its threshold and both meters using the shared tooltip")
        widget.scripts.OnLeave(widget)
        assert(not tooltip:IsShown())
    end
    panel.tabs.sharing:Click()
    for _, widget in ipairs({ panel.dataChannels.party, panel.dataChannels.guild.labelButton, panel.dataStatusHelp }) do
        widget.scripts.OnEnter(widget)
        assert(tooltip:IsShown() and tooltip:IsOwned(widget) and tooltip.anchor == "ANCHOR_CURSOR",
            "data controls and status use the shared tooltip position")
        widget.scripts.OnLeave(widget)
        assert(not tooltip:IsShown())
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

print("PASS: Settings group lifecycle, data channel controls, preference callbacks, read-only settings and key privacy")
