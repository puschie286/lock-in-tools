-- Core Settings interactions; shared widgets are mocked offline.
local support = dofile("tests/support/addon.lua")
local loadAddon, settings = support.loadAddon, support.settings
local SECRET = support.SECRET
local loadOptions = dofile("tests/support/ui.lua")

-- General Settings combine sharing, ranking and player data without status summaries.
do
    local addon, api, _, _, world = loadAddon(settings("", false), false)
    world:initialize()
    loadOptions(addon, api)
    api.SlashCmdList.LOCKINTOOLS("options")
    local panel = addon.optionsPanel
    assert(panel:IsVisible() and panel.selectedTab == "sharing")
    assert(not panel.dataChannels.party and panel.dataChannels.guild:IsEnabled() and panel.dataChannels.friends:IsEnabled())
    for _, control in ipairs({ panel.dataChannels.guild, panel.dataChannels.friends,
        panel.rankingEnabled,
        panel.rankingBurningEffect, panel.rankingTransparencySlider,
        panel.playerDataCleanup, panel.clearPlayerData }) do
        assert(control:IsVisible(), "all general preferences are available on one page")
    end
    assert(panel.tabs.sharing and panel.tabs.restedxp and not panel.tabs.ranking and not panel.tabs.playerData
        and not panel.pages.ranking and not panel.pages.playerData,
        "ranking and player data no longer require separate menus")
    assert(not panel.dataStatus and not panel.dataStatusHelp, "route summary lines are absent")
    assert(not panel.positionSharing and not panel.positionRetention
        and not panel.positionStatus and not panel.positionStatusHelp,
        "position sharing has no Settings controls")
    assert(not panel.rankingIncludeFriends, "friend ranking inclusion is controlled on each Friends row")
    assert(not panel.tabs.group and not panel.secret and not panel.autoJoin
        and not panel.join and not panel.leave and not panel.dataChannels.global,
        "the removed global group and chat have no settings controls")
    assert(#world.joinCalls == 0 and #world.dataJoinCalls == 0,
        "opening Settings never joins a custom channel")
end
-- Refreshing controls does not save; each user click applies its preference once.
do
    local addon, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    local calls, setter = 0, addon.SetRankingBurningEffect
    addon.SetRankingBurningEffect = function(self, enabled)
        calls = calls + 1
        return setter(self, enabled)
    end
    loadOptions(addon, api)
    addon:OpenOptions("ranking")
    local panel = addon.optionsPanel
    assert(panel.rankingBurningEffect:GetChecked())
    panel.rankingBurningEffect:SetChecked(false)
    addon:RefreshOptions()
    assert(addon:GetRankingSettings().burningEffect and panel.rankingBurningEffect:GetChecked() and calls == 0)
    addon.mainPanel:Hide()
    addon:OpenOptions()
    panel.rankingBurningEffect:Click()
    addon.mainPanel:Hide()
    addon:OpenOptions()
    assert(not panel.rankingBurningEffect:GetChecked() and calls == 1)
    assert(not addon.db.ranking.enabled and not addon.db.ranking.burningEffect,
        "The effect preference stays editable and persists independently of overlay visibility")
end

-- Ranking transparency applies live, without refresh writes or changes to other preferences.
do
    local addon, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    local calls, setter, failure = 0, addon.SetRankingBackgroundTransparency, nil
    addon.SetRankingBackgroundTransparency = function(self, value)
        calls = calls + 1
        if failure then return false, failure end
        return setter(self, value)
    end
    loadOptions(addon, api)
    addon:OpenOptions("ranking")
    local panel = addon.optionsPanel
    local slider = panel.rankingTransparencySlider
    assert(slider:IsEnabled() and slider:GetValue() == 0 and panel.rankingTransparencyValue:GetText() == "0%"
        and calls == 0, "ranking transparency defaults to zero without saving while creating the controls")
    addon:RefreshOptions()
    addon:Notify("RANKING_CHANGED")
    assert(calls == 0, "ranking refresh and notifications do not save transparency")
    slider:SetValue(24.6)
    assert(slider:GetValue() == 25 and addon:GetRankingSettings().backgroundTransparency == 25
        and panel.rankingTransparencyValue:GetText() == "25%" and calls == 1
        and not addon:GetRankingSettings().enabled and addon:GetRankingSettings().burningEffect,
        "dragging rounds to a whole percentage, saves once and leaves overlay toggles unchanged")
    slider:SetValue(25.2)
    assert(slider:GetValue() == 25 and calls == 1,
        "dragging within the saved percentage does not save it again")
    slider:SetValue(104)
    assert(slider:GetValue() == 100 and addon:GetRankingSettings().backgroundTransparency == 100)
    slider:SetValue(-4)
    assert(slider:GetValue() == 0 and addon:GetRankingSettings().backgroundTransparency == 0,
        "ranking transparency stays within zero to one hundred")
    slider:SetValue(47)
    failure = "Unable to save transparency."
    slider:SetValue(60)
    assert(slider:GetValue() == 47 and addon:GetRankingSettings().backgroundTransparency == 47
        and panel.feedback:GetText() == failure,
        "rejected transparency changes restore the saved value and show the error")
    failure = nil
    local writes = calls
    addon.db.ranking.backgroundTransparency = 82
    addon:Notify("RANKING_CHANGED")
    assert(slider:GetValue() == 82 and panel.rankingTransparencyValue:GetText() == "82%" and calls == writes,
        "external transparency changes refresh the slider without writing back")
    addon.mainPanel:Hide()
    addon:OpenOptions("ranking")
    assert(slider:GetValue() == 82 and calls == writes, "reopening Settings retains transparency without saving")
    local reloaded, reloadedAPI, _, _, reloadedWorld = loadAddon(api.LockInToolsDB, false)
    reloadedWorld:initialize()
    loadOptions(reloaded, reloadedAPI)
    reloaded:OpenOptions("ranking")
    assert(reloaded.optionsPanel.rankingTransparencySlider:GetValue() == 82
        and reloaded:GetRankingSettings().backgroundTransparency == 82,
        "ranking transparency survives a saved-variable reload")
end

-- Data channels default on; checkbox and label actions save once and survive reloads.
do
    local saved = settings(SECRET, false)
    saved.data = { channels = { party = true, guild = true } }
    local addon, api, _, _, world = loadAddon(saved, false)
    world:initialize()
    assert(api.LockInToolsDB.data.channels.friends == true and api.LockInToolsDB.data.channels.party == nil,
        "upgraded profiles enable Friends sharing and remove the retired party preference")
    local calls, setter = { guild = 0, friends = 0 }, addon.SetDataChannelEnabled
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
    world.guild = true
    world.fire("PLAYER_GUILD_UPDATE")
    for channel, checkbox in pairs(panel.dataChannels) do
        assert(checkbox:IsVisible() and checkbox:GetChecked() and calls[channel] == 0,
            "route availability changes preserve visible preferences without saving")
    end
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

-- Player cleanup saves on user actions; clearing data requires a fresh confirmation.
do
    local addon, api, _, _, world = loadAddon(settings(SECRET, false), false)
    world:initialize()
    local writes, clears, setter = 0, 0, addon.SetPlayerDataCleanupEnabled
    addon.SetPlayerDataCleanupEnabled = function(self, enabled)
        writes = writes + 1
        return setter(self, enabled)
    end
    addon.ClearPlayerData = function() clears = clears + 1; return true end
    loadOptions(addon, api)
    addon:OpenOptions("playerData")
    local panel = addon.optionsPanel
    assert(panel.playerDataCleanup:GetChecked() and panel.playerDataCleanup:IsEnabled()
        and panel.clearPlayerData:IsEnabled())
    panel.playerDataCleanup:SetChecked(false)
    addon:RefreshOptions()
    assert(panel.playerDataCleanup:GetChecked() and writes == 0,
        "refreshing the cleanup control does not save")
    panel.playerDataCleanup.labelButton:Click()
    assert(not addon:GetPlayerDataCleanupEnabled() and not panel.playerDataCleanup:GetChecked() and writes == 1)
    addon.mainPanel:Hide()
    addon:OpenOptions("playerData")
    assert(not panel.playerDataCleanup:GetChecked() and writes == 1)

    panel.clearPlayerData:Click()
    assert(clears == 0 and panel.confirmClearPlayerData)
    addon:Notify("DATA_CHANGED")
    assert(panel.confirmClearPlayerData, "live notifications preserve an outstanding clear confirmation")
    panel.tabs.restedxp:Click()
    panel.tabs.sharing:Click()
    assert(not panel.confirmClearPlayerData, "changing tabs cancels clear confirmation")
    panel.clearPlayerData:Click()
    assert(clears == 0 and panel.confirmClearPlayerData)
    addon.mainPanel:Hide()
    addon:OpenOptions("playerData")
    assert(not panel.confirmClearPlayerData, "closing Settings cancels clear confirmation")
    panel.clearPlayerData:Click()
    panel.clearPlayerData:Click()
    assert(clears == 1 and not panel.confirmClearPlayerData and panel.feedback:GetText() ~= "")
    addon.ClearPlayerData = function() clears = clears + 1; return false, "Clear rejected" end
    panel.clearPlayerData:Click()
    panel.clearPlayerData:Click()
    assert(clears == 2 and not panel.confirmClearPlayerData and panel.feedback:GetText() == "Clear rejected",
        "failed clearing resets confirmation and displays the returned error")

    local reloaded, reloadedAPI, _, _, reloadedWorld = loadAddon(api.LockInToolsDB, false)
    reloadedWorld:initialize()
    loadOptions(reloaded, reloadedAPI)
    reloaded:OpenOptions("playerData")
    assert(not reloaded:GetPlayerDataCleanupEnabled() and not reloaded.optionsPanel.playerDataCleanup:GetChecked(),
        "the cleanup opt-out survives a saved-variable reload")
end

-- Future-schema profiles allow navigation while every editing path preserves saved data.
do
    local saved = { schemaVersion = 5, showWelcome = false, important = "keep",
        group = { secret = SECRET }, chat = { autoJoin = false },
        data = { channels = { party = false, guild = true, friends = false, global = false } } }
    local addon, api, _, _, world = loadAddon(saved, false)
    world:initialize()
    local transparencyWrites = 0
    addon.SetRankingBackgroundTransparency = function() transparencyWrites = transparencyWrites + 1; return true end
    loadOptions(addon, api)
    addon:OpenOptions()
    local panel = addon.optionsPanel
    for _, control in ipairs({ panel.rankingBurningEffect,
        panel.rankingTransparencySlider, panel.playerDataCleanup, panel.clearPlayerData }) do
        assert(not control:IsEnabled())
    end
    panel.rankingTransparencySlider:SetValue(42)
    assert(panel.rankingTransparencySlider:GetValue() == 0 and transparencyWrites == 0,
        "even a directly invoked slider callback cannot save read-only ranking transparency")
    local cleanup = addon:GetPlayerDataCleanupEnabled()
    panel.playerDataCleanup:SetChecked(not cleanup)
    panel.playerDataCleanup.scripts.OnClick(panel.playerDataCleanup)
    assert(addon:GetPlayerDataCleanupEnabled() == cleanup and panel.playerDataCleanup:GetChecked() == cleanup)
    local clearCalls = 0
    addon.ClearPlayerData = function() clearCalls = clearCalls + 1; return true end
    panel.clearPlayerData.scripts.OnClick(panel.clearPlayerData)
    assert(clearCalls == 0 and not panel.confirmClearPlayerData,
        "a directly invoked clear callback cannot begin confirmation in read-only mode")
    local effect, previous = panel.rankingBurningEffect, addon:GetRankingSettings().burningEffect
    effect:SetChecked(not previous)
    effect.scripts.OnClick(effect)
    assert(addon:GetRankingSettings().burningEffect == previous and effect:GetChecked() == previous,
        "even a directly invoked callback cannot write read-only preferences")
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
    for _, event in ipairs({ "DATA_CHANGED", "RANKING_CHANGED" }) do
        addon:Notify(event)
    end
    addon.contentPanel.options:Click()
    assert(panel.selectedTab == "sharing" and not panel.rankingBurningEffect:IsEnabled())
    assert(api.LockInToolsDB == saved and saved.schemaVersion == 5 and saved.important == "keep"
        and saved.group.secret == SECRET and not saved.chat.autoJoin and saved.ranking == nil
        and not saved.data.channels.party and saved.data.channels.guild
        and not saved.data.channels.friends and not saved.data.channels.global)
end

-- Every settings help path uses the global anchor and retains owner-based cleanup.
do
    local addon, api, _, _, world = loadAddon(settings("", false), false)
    world:initialize()
    loadOptions(addon, api)
    api.GameTooltip_SetDefaultAnchor = function(tooltip, owner)
        tooltip:SetOwner(owner, "ANCHOR_CURSOR")
    end
    addon:OpenOptions("sharing")
    local panel, tooltip = addon.optionsPanel, api.GameTooltip
    panel.dataChannels.guild.scripts.OnEnter(panel.dataChannels.guild)
    assert(tooltip:IsShown() and tooltip:IsOwned(panel.dataChannels.guild) and tooltip.anchor == "ANCHOR_CURSOR",
        "Settings help follows the global tooltip position")
    panel.tabs.restedxp:Click()
    assert(not tooltip:IsShown(), "switching settings pages dismisses globally positioned help")
    panel.tabs.sharing:Click()
    panel.playerDataCleanup:SetEnabled(false)
    for _, widget in ipairs({ panel.dataChannels.guild, panel.dataChannels.guild.labelButton, panel.playerDataCleanup }) do
        widget.scripts.OnEnter(widget)
        assert(tooltip:IsShown() and tooltip:IsOwned(widget) and tooltip.anchor == "ANCHOR_CURSOR",
            "checkboxes, labels and disabled control help share global tooltip positioning")
        widget.scripts.OnLeave(widget)
        assert(not tooltip:IsShown(), "leaving each control dismisses its own help")
    end
    for _, widget in ipairs({ panel.rankingBurningEffect, panel.rankingBurningEffect.labelButton }) do
        widget.scripts.OnEnter(widget)
        assert(tooltip:IsShown() and tooltip:IsOwned(widget) and tooltip.anchor == "ANCHOR_CURSOR"
            and tooltip.lines[1]:find("70%%") and tooltip.lines[1]:find("both burned meters"),
            "Burning effect help explains its threshold and both meters using the shared tooltip")
        widget.scripts.OnLeave(widget)
        assert(not tooltip:IsShown())
    end
    for _, widget in ipairs({ panel.rankingTransparencyHelp, panel.rankingTransparencySlider }) do
        widget.scripts.OnEnter(widget)
        assert(tooltip:IsShown() and tooltip:IsOwned(widget) and tooltip.anchor == "ANCHOR_CURSOR",
            "ranking transparency help uses global tooltip positioning")
        widget.scripts.OnLeave(widget)
        assert(not tooltip:IsShown())
    end
    for _, widget in ipairs({ panel.dataChannels.guild, panel.dataChannels.guild.labelButton,
        panel.dataChannels.friends.labelButton }) do
        widget.scripts.OnEnter(widget)
        assert(tooltip:IsShown() and tooltip:IsOwned(widget) and tooltip.anchor == "ANCHOR_CURSOR",
            "data controls use the shared tooltip position")
        widget.scripts.OnLeave(widget)
        assert(not tooltip:IsShown())
    end
    panel.tabs.restedxp:Click()
    panel.restedxpTransparencyHelp.scripts.OnEnter(panel.restedxpTransparencyHelp)
    assert(tooltip:IsOwned(panel.restedxpTransparencyHelp) and tooltip.anchor == "ANCHOR_CURSOR",
        "RestedXP appearance help also follows global positioning")
    addon.mainPanel:Hide()
    assert(not tooltip:IsShown(), "closing Settings dismisses its globally positioned tooltip")
    addon:OpenOptions("sharing")
    local foreignOwner = {}
    tooltip:SetOwner(foreignOwner, "ANCHOR_CURSOR")
    tooltip:Show()
    addon.mainPanel:Hide()
    assert(tooltip:IsShown() and tooltip:IsOwned(foreignOwner),
        "closing Settings preserves a tooltip owned by another control")
end

print("PASS: native sharing and player data controls, preference callbacks and read-only settings")
