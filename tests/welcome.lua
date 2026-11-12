-- Initial Content uses native sharing without a separate group setup step.
local support = dofile("tests/support/addon.lua")
local loadAddon, settings = support.loadAddon, support.settings
local loadOptions = dofile("tests/support/ui.lua")
local copy = dofile("tests/support/helpers.lua").copy

-- Solo, guild, party and raid first logins open the same usable player overview.
for _, membership in ipairs({ "solo", "guild", "grouped", "raid" }) do
    local addon, api, _, _, world = loadAddon(nil, false)
    if membership ~= "solo" then world[membership] = true end
    loadOptions(addon, api)
    world:initialize()
    local content = addon.contentPanel
    assert(content:IsVisible() and not addon.optionsPanel and addon.db.setupComplete == true)
    assert(addon:IsDataConnected() == (membership ~= "solo"),
        "sharing follows native membership without key generation")
    assert(not addon.db.group and not addon.db.chat and not addon.db.data.channels.global
        and #world.joinCalls == 0 and #world.dataJoinCalls == 0,
        "initial Content never configures or joins a custom channel")
    if membership == "solo" then
        assert(#addon:GetOverviewPlayers() == 0 and content.overviewPage.empty:IsShown(),
            "solo Content explains that native guild, party or raid sharing is needed")
    else
        assert(#addon:GetOverviewPlayers() == 1 and content.overviewPage.rows[1].playerID == "self-testrealm")
    end
    if membership ~= "solo" then
        local presence = assert(world.statusSends[1])
        local distribution = membership == "guild" and "GUILD" or membership == "raid" and "RAID" or "PARTY"
        assert(presence.distribution == distribution)
        world.fire("CHAT_MSG_ADDON", presence.prefix, presence.message, distribution, "NativeFriend")
        assert(#addon:GetOverviewPlayers() == 2 and content.overviewPage.rows[2].playerID == "nativefriend-testrealm",
            "first-login Content discovers players over the current native route")
    end
    world.fire("PLAYER_LOGIN")
    content:Hide()
    addon:OpenContent()
    assert(content:IsVisible() and addon.contentPanel == content)
    api.UIParent:Hide()
    assert(content:IsShown() and not content:IsVisible())
    api.UIParent:Show()
    assert(content:IsVisible())

    local restored, restoredAPI, _, _, restoredWorld = loadAddon(copy(addon.db), false)
    loadOptions(restored, restoredAPI)
    restoredWorld:initialize()
    assert(not restored.contentPanel and restored.db.setupComplete == true,
        "completed first-login Content stays dismissed across reloads")
end

-- Native channel opt-outs stay saved through first-login Content and reopening.
do
    local profile = settings("legacy-friends", true)
    profile.showWelcome = true
    profile.data = { channels = { party = false, guild = false, global = true } }
    local addon, api, _, _, world = loadAddon(profile, false)
    world.guild, world.grouped = true, true
    loadOptions(addon, api)
    world:initialize()
    assert(addon.contentPanel:IsVisible() and not addon:IsDataConnected()
        and not addon:GetDataChannelEnabled("party") and not addon:GetDataChannelEnabled("guild")
        and not addon.db.group and not addon.db.chat and not addon.db.data.channels.global,
        "first opening preserves native sharing opt-outs and removes obsolete settings")
    addon.contentPanel:Hide()
    addon:OpenContent()
    assert(not addon:IsDataConnected() and #world.joinCalls == 0 and #world.dataJoinCalls == 0)
end

-- Welcome off defers Content creation until a command opens the overview.
do
    local profile = settings("", false)
    local addon, api, _, _, world = loadAddon(profile, false)
    loadOptions(addon, api)
    world:initialize()
    assert(not addon.contentPanel and not addon.optionsPanel)
    api.SlashCmdList.LOCKINTOOLS("")
    assert(addon.contentPanel:IsVisible() and addon.db.setupComplete == true
        and not addon.db.group and #world.joinCalls == 0 and #world.dataJoinCalls == 0)
end

-- Future-schema profiles allow viewing Content while saved preferences stay untouched.
do
    local profile = { schemaVersion = 5, showWelcome = true, setupComplete = false, important = "keep",
        group = { secret = support.SECRET }, chat = { autoJoin = false } }
    local addon, api, _, _, world = loadAddon(profile, false)
    loadOptions(addon, api)
    world:initialize()
    assert(addon.savedDataReadOnly and not addon.contentPanel and not addon.optionsPanel,
        "future schemas do not automatically start initial setup")
    addon:OpenWelcome()
    addon.contentPanel.options:Click()
    local options = addon.optionsPanel
    assert(options.selectedTab == "sharing" and not options.playerDataCleanup:IsEnabled()
        and not options.dataChannels.party:IsEnabled() and not options.dataChannels.guild:IsEnabled())
    assert(api.LockInToolsDB == profile and profile.schemaVersion == 5
        and profile.group.secret == support.SECRET and profile.important == "keep"
        and profile.setupComplete == false and profile.showWelcome and not profile.chat.autoJoin
        and #world.joinCalls == 0 and #world.dataJoinCalls == 0,
        "viewing read-only Content and Settings leaves the original profile untouched")
end

assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep test environments isolated")
print("PASS: native first-login Content, reload behavior, channel opt-outs and saved-data safety")
