-- Initial setup and saved-key safety against the shared native-widget mocks.
local support = dofile("tests/support/addon.lua")
local loadAddon, settings, contains = support.loadAddon, support.settings, support.contains
local SECRET, OTHER_SECRET = support.SECRET, support.OTHER_SECRET
local loadOptions = dofile("tests/support/ui.lua")

-- Initial Content setup creates one saved key; copying and friend import live only in Settings > Group.
do
    local initial, api, initialMessages, _, initialWorld = loadAddon(nil, false)
    local generatedCalls = 0
    api.math = setmetatable({ random = function(_, maximum)
        generatedCalls = generatedCalls + 1
        return maximum == 64 and 48 or 4827
    end }, { __index = math })
    loadOptions(initial, api)
    initialWorld:initialize()
    local content = initial.contentPanel
    local initialKey = "otter-4827"
    local initialRoom = initial:GetGroupChannelName()
    assert(content and content:IsShown() and not initial.optionsPanel and not initial.welcomePanel
        and not content.ownSecret and not content.friendSecret,
        "first login opens only Content with no key-sharing form")
    assert(initial:GetGroupSecret() == initialKey and initial.db.group.secret == initialKey
        and generatedCalls == 2, "initial Content setup generates and saves one group key")
    assert(#initialWorld.joinCalls == 1 and initialWorld.joinCalls[1] == initialRoom,
        "initial group creation uses normal chat autojoin once")
    initialWorld.fire("PLAYER_LOGIN")
    assert(generatedCalls == 2 and #initialWorld.joinCalls == 1,
        "duplicate login does not regenerate the key or request another join")
    content.options:Click()
    local options = initial.optionsPanel
    assert(options:IsShown() and not content:IsVisible() and options.selectedTab == "group"
        and options.ownSecret:GetText() == initialKey,
        "Settings > Group displays the saved key for sharing")
    local unfocusedPaints = options.ownSecret.texturePaints
    options.ownSecret:SetFocus()
    assert(options.ownSecret.highlighted and options.ownSecret.texturePaints > unfocusedPaints,
        "focusing the saved key keeps copy highlighting and the native focus outline")
    options.ownSecret:ClearFocus()
    options.selectKey:Click()
    assert(options.ownSecret.focused and options.ownSecret.highlighted,
        "Select key focuses and highlights the saved key for copying")
    options.ownSecret:UserInput("accidental-edit")
    assert(options.ownSecret:GetText() == initialKey and initial:GetGroupSecret() == initialKey,
        "typing into the copy field cannot change the saved key")

    local restored, restoredApi, _, restoredEvent, restoredWorld = loadAddon(initial.db, true)
    restoredApi.math = setmetatable({ random = function()
        error("a persisted key must not be regenerated")
    end }, { __index = math })
    loadOptions(restored, restoredApi)
    restoredEvent("ADDON_LOADED", "LockInTools")
    assert(restored.ready and not restored.contentPanel and not restored.optionsPanel
        and restored:GetGroupSecret() == initialKey,
        "loading after login preserves the key without reopening completed setup")
    restoredApi.SlashCmdList.LOCKINTOOLS("welcome")
    restored.contentPanel.options:Click()
    assert(restored.optionsPanel.ownSecret:GetText() == initialKey and not restored.welcomePanel,
        "the legacy welcome command reaches the same saved key through Content and Settings")
    restored.mainPanel.CloseButton:Click()
    restoredWorld:advance(1)
    assert(restoredWorld.joinCalls[1] == initialRoom, "the saved setup key restores the same channel")

    options.secret:UserInput("   ")
    options.applyGroup:Click()
    assert(initial:GetGroupSecret() == initialKey and not options.applyGroup:IsEnabled(),
        "blank friend input disables applying without changing groups")
    options.secret.scripts.OnEnterPressed(options.secret)
    assert(options.feedback:GetText() ~= "" and options.feedback.color[1] == 1,
        "submitting blank friend input with Enter reports an error")
    options.secret:UserInput("invalid--key")
    options.applyGroup:Click()
    options.applyGroup:Click()
    assert(initial:GetGroupSecret() == initialKey and #initialWorld.leaveCalls == 0,
        "an invalid friend's key preserves the group and its transport")
    options.secret:UserInput("  OTTER-4827  ")
    options.applyGroup:Click()
    assert(initial:GetGroupSecret() == initialKey and options.applyGroup:GetText() == "Use key"
        and options.secret:GetText() == "" and #initialWorld.leaveCalls == 0 and #initialWorld.joinCalls == 1,
        "the same canonical friendly key succeeds without confirmation or transport switching")
    options.secret:UserInput("first-friend")
    options.applyGroup:Click()
    assert(initial:GetGroupSecret() == initialKey and options.applyGroup:GetText() == "Confirm switch",
        "importing a friend's key requires confirmation before changing every feature's group")
    options.secret:UserInput("other-friend")
    assert(options.applyGroup:GetText() == "Use key", "editing the friend key resets switch confirmation")
    options.applyGroup:Click()
    initialWorld:completeJoin(initialRoom, 7)
    assert(options.secret:GetText() == "other-friend" and options.applyGroup:GetText() == "Confirm switch"
        and options.ownSecret:GetText() == initialKey,
        "asynchronous chat updates preserve the friend's draft, confirmation and saved copy field")
    options.applyGroup:Click()
    assert(initial:GetGroupSecret() == "other-friend" and initial.db.group.secret == "other-friend"
        and options.ownSecret:GetText() == "other-friend" and options.secret:GetText() == "",
        "a confirmed friend key becomes the saved copy field and clears the import draft")
    assert(initialWorld.leaveCalls[1] == initialRoom
        and initialWorld.joinCalls[2] == initial:GetGroupChannelName(),
        "Group friend import uses the existing channel lifecycle")
    assert(initial:SetGroupSecret(SECRET))
    assert(options.ownSecret:GetText() == SECRET, "the saved copy field follows external group changes")
    local previousLeaves = #initialWorld.leaveCalls
    options.secret:UserInput("  " .. SECRET:lower() .. "  ")
    options.applyGroup:Click()
    assert(initial:GetGroupSecret() == SECRET and #initialWorld.leaveCalls == previousLeaves
        and options.applyGroup:GetText() == "Use key" and options.secret:GetText() == "",
        "legacy keys retain canonical same-group behavior without confirmation")
    options.secret:UserInput(OTHER_SECRET)
    options.applyGroup:Click()
    options.selectKey:Click()
    options.secret:SetFocus()
    options.parent.CloseButton:Click()
    assert(not options:IsVisible() and options.ownSecret:GetText() == "" and options.secret:GetText() == ""
        and not options.ownSecret.focused and not options.secret.focused,
        "closing Settings clears plaintext keys, drafts and focus")
    initial:OpenOptions()
    assert(initial.optionsPanel == options and options.ownSecret:GetText() == SECRET
        and options.secret:GetText() == "" and options.applyGroup:GetText() == "Use key"
        and generatedCalls == 2, "reopening Group restores only the saved key without regenerating it")
    -- Hiding UIParent fires OnHide while the child's own IsShown flag stays true.
    options.secret:UserInput(OTHER_SECRET)
    options.applyGroup:Click()
    api.UIParent:Hide()
    initial:RefreshOptions()
    assert(options:IsShown() and not options:IsVisible() and initial.mainPanel:IsShown()
        and options.ownSecret:GetText() == "" and options.secret:GetText() == ""
        and options.applyGroup:GetText() == "Use key",
        "hiding the whole interface clears keys and prevents background refresh from restoring them")
    api.UIParent:Show()
    assert(options.ownSecret:GetText() == SECRET, "showing the interface restores Group's saved copy field")
    options.tabs.chat:Click()
    initial:RefreshOptions()
    assert(options.ownSecret:GetText() == "" and options.secret:GetText() == "",
        "hidden Group fields stay empty while another settings page is active")
    assert(not contains(initialMessages, initialKey) and not contains(initialMessages, "other-friend")
        and not contains(initialMessages, SECRET) and not contains(initialMessages, OTHER_SECRET),
        "Content and Group never print either person's key to chat")
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
    manual.contentPanel.options:Click()
    local options = manual.optionsPanel
    options.secret:UserInput("manual-friend")
    options.applyGroup:Click()
    options.applyGroup:Click()
    assert(manual:GetGroupSecret() == "manual-friend" and options.ownSecret:GetText() == "manual-friend"
        and #manualWorld.joinCalls == 0 and not manual.db.chat.autoJoin,
        "Group friend import preserves disabled autojoin")

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
    failedOptions.createGroup:Click()
    assert(not failed:HasGroup() and failedOptions.secret:GetText() == "" and failedOptions.feedback:GetText() ~= "",
        "a failed Group create action preserves saved data and reports a useful error")
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
    invalid.optionsPanel.content:Click()
    invalid:OpenWelcome()
    assert(invalid.db.group.secret == "damaged secret" and not invalid.welcomePanel,
        "the compatibility alias does not replace damaged settings or create another window")

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
