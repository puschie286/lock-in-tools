-- Initial setup and saved-key safety against the shared native-widget mocks.
local support = dofile("tests/support/addon.lua")
local loadAddon, settings, contains = support.loadAddon, support.settings, support.contains
local SECRET, OTHER_SECRET = support.SECRET, support.OTHER_SECRET
local loadOptions = dofile("tests/support/ui.lua")

-- First setup generates once; reload and UI hiding preserve the key without exposing drafts.
do
    local addon, api, messages, _, world = loadAddon(nil, false)
    local generated = 0
    api.math = setmetatable({ random = function(_, maximum)
        generated = generated + 1
        return maximum == 64 and 48 or 4827
    end }, { __index = math })
    loadOptions(addon, api)
    world:initialize()
    assert(addon.contentPanel:IsVisible() and not addon.optionsPanel)
    assert(addon:GetGroupSecret() == "otter-4827" and generated == 2 and #world.joinCalls == 1)
    local room = addon:GetGroupChannelName()
    world.fire("PLAYER_LOGIN")
    assert(generated == 2 and #world.joinCalls == 1)
    addon.contentPanel.options:Click()
    local options = addon.optionsPanel
    options.selectKey:Click()
    assert(options.ownSecret.focused and options.ownSecret.highlighted)
    options.ownSecret:UserInput("accidental-edit")
    assert(options.ownSecret:GetText() == "otter-4827" and addon:GetGroupSecret() == "otter-4827",
        "the copy field cannot change the saved key")

    options.secret:UserInput(OTHER_SECRET)
    options.applyGroup:Click()
    -- UIParent hiding leaves a child's IsShown flag true while firing OnHide.
    api.UIParent:Hide()
    addon:RefreshOptions()
    assert(options:IsShown() and not options:IsVisible()
        and options.secret:GetText() == "" and options.ownSecret:GetText() == "" and not options.pendingSecret)
    api.UIParent:Show()
    assert(options.ownSecret:GetText() == "otter-4827" and addon:GetGroupSecret() == "otter-4827")

    local restored, restoredApi, _, restoredEvent, restoredWorld = loadAddon(addon.db, true)
    restoredApi.math = setmetatable({ random = function() error("persisted keys must not be regenerated") end },
        { __index = math })
    loadOptions(restored, restoredApi)
    restoredEvent("ADDON_LOADED", "LockInTools")
    restoredWorld:advance(1)
    assert(restored.ready and not restored.contentPanel and restored:GetGroupSecret() == "otter-4827"
        and restoredWorld.joinCalls[1] == room)
    assert(not contains(messages, "otter-4827") and not contains(messages, OTHER_SECRET))
end

-- Manual Content setup respects autojoin; Group import remains available after generation failure.
do
    local manual, api, _, _, manualWorld = loadAddon(settings("", false), false)
    loadOptions(manual, api)
    manualWorld:initialize()
    assert(not manual.contentPanel and not manual.optionsPanel, "welcome off suppresses automatic Content setup")
    api.SlashCmdList.LOCKINTOOLS("")
    assert(manual:HasGroup() and #manualWorld.joinCalls == 0,
        "manually opening Content saves a key while respecting disabled autojoin")
    local failed, failedApi, failedMessages, _, failedWorld = loadAddon(nil, false)
    local attempts = 0
    failedApi.math = setmetatable({ random = function()
        attempts = attempts + 1
        error("private generator failure")
    end }, { __index = math })
    loadOptions(failed, failedApi)
    failedWorld:initialize()
    assert(failed.contentPanel and failed.contentPanel:IsShown() and not failed:HasGroup()
        and failed.db.group.secret == "" and failed.contentPanel.feedback:GetText() ~= "",
        "initial generation failure leaves Content usable and saved group data empty")
    failed:RefreshOptions()
    assert(attempts == 1, "status refresh does not retry failed key generation")
    failed.contentPanel.options:Click()
    local failedOptions = failed.optionsPanel
    assert(failedOptions.secret:IsEnabled() and not failedOptions.applyGroup:IsEnabled()
        and failedOptions.ownSecret:GetText() == "", "Group import remains available after generation failure")
    failedOptions.secret:UserInput("friend-4827")
    failedOptions.applyGroup:Click()
    assert(failed:GetGroupSecret() == "friend-4827" and failedOptions.ownSecret:GetText() == "friend-4827"
        and #failedWorld.joinCalls == 1, "a friend's key saves immediately when no group exists")
    assert(not contains(failedMessages, "private generator failure") and not contains(failedMessages, "friend-4827"))
end

-- Content and Group preserve damaged and newer-schema saved data.
do
    local invalidSettings = settings("damaged secret", false)
    invalidSettings.showWelcome = true
    local invalid, api, _, _, invalidWorld = loadAddon(invalidSettings, false)
    api.math = setmetatable({ random = function()
        error("damaged stored keys must not be replaced")
    end }, { __index = math })
    loadOptions(invalid, api)
    invalidWorld:initialize()
    assert(invalid.invalidGroupSecret and invalid.db.group.secret == "damaged secret"
        and invalid.contentPanel:IsShown() and not invalid.optionsPanel and #invalidWorld.joinCalls == 0,
        "initial Content preserves an invalid saved key for explicit repair")
    invalid.contentPanel.options:Click()
    assert(invalid.optionsPanel.ownSecret:GetText() == "" and invalid.optionsPanel.secret:IsEnabled(),
        "Group permits explicit repair without exposing the invalid saved key")
    local futureSettings = { schemaVersion = 4, showWelcome = true, important = "keep",
        group = { secret = SECRET }, chat = { autoJoin = false } }
    local future, futureApi, _, _, futureWorld = loadAddon(futureSettings, false)
    futureApi.math = setmetatable({ random = function()
        error("read-only preferences must not generate a key")
    end }, { __index = math })
    loadOptions(future, futureApi)
    futureWorld:initialize()
    assert(future.savedDataReadOnly and not future.contentPanel and not future.optionsPanel,
        "newer schemas do not automatically start Content setup")
    future:OpenWelcome()
    future.contentPanel.options:Click()
    local options = future.optionsPanel
    assert(not options.secret:IsEnabled() and not options.applyGroup:IsEnabled()
        and not options.createGroup:IsEnabled() and options.ownSecret:GetText() == "",
        "read-only Group disables saved edits and leaves the copy field empty")
    options.applyGroup:Click()
    assert(futureApi.LockInToolsDB == futureSettings and futureSettings.schemaVersion == 4
        and futureSettings.group.secret == SECRET and futureSettings.important == "keep"
        and futureSettings.showWelcome and not futureSettings.chat.autoJoin and #futureWorld.joinCalls == 0,
        "opening read-only Content and Group leaves the original saved data untouched")
end


assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep test environments isolated")
print("PASS: initial Content setup, key stability, import recovery and saved-data safety")
