-- This offline suite is never loaded by the addon.
local fixture = dofile("tests/support/addon.lua")
local loadAddon, settings = fixture.loadAddon, fixture.settings
local SECRET, OTHER_SECRET, contains = fixture.SECRET, fixture.OTHER_SECRET, fixture.contains
local loadOptions = dofile("tests/support/ui.lua")

-- Optional skins must preserve lazy Content/Settings creation and Group privacy.
local function skinFixture()
    local state = { font = "SkinFont-A.ttf", accent = { 0.2, 0.8, 0.4 }, looks = {}, shells = 0, tabs = 0 }
    local skin = {}
    function skin.Shell(window)
        state.shells = state.shells + 1
        window.skinApplied = true
    end
    for _, name in ipairs({ "Panel", "Button", "CloseButton", "EditBox", "Checkbox", "StateButtonLabel" }) do
        skin[name] = function() end
    end
    function skin.Font(region)
        local _, size, flags = region:GetFont()
        region:SetFont(state.font, size, flags)
    end
    function skin.GetAccentColor() return unpack(state.accent) end
    function skin.Tab(button)
        state.tabs = state.tabs + 1
        button.skinTabApplied = true
    end
    function skin.SetTabSelection(button, selected) button.skinTabSelected = selected end
    function skin.OnLooksChanged(callback) state.looks[#state.looks + 1] = callback end
    return skin, state
end

local function loadSkinnedOptions(registerSkin)
    local skinned, skinEnvironment, skinMessages, _, skinWorld = loadAddon(settings(SECRET, false), false)
    skinEnvironment.EllesmereUI = { RegisterSkin = registerSkin }
    skinWorld:initialize()
    loadOptions(skinned, skinEnvironment)
    return skinned, skinEnvironment, skinMessages, skinWorld
end

do
    local registration, registrations = nil, 0
    local disabled, disabledEnvironment = loadSkinnedOptions(function(name, callback)
        assert(name == "LockInTools", "the optional skin uses the addon identity")
        registrations = registrations + 1
        registration = callback
    end)
    assert(registrations == 1 and type(registration) == "function"
        and not disabled.optionsPanel and not disabled.contentPanel,
        "registering an installed but disabled skin does not construct windows")
    registration(nil)
    registration("unsupported")
    disabledEnvironment.UIParent:SetSize(640, 480)
    disabled:OpenOptions()
    disabled:OpenContent()
    local window = disabled.mainPanel
    assert(not window.skinApplied
        and window.TitleText.font[1] == "Fonts\\FRIZQT__.TTF"
        and disabled:GetGroupSecret() == SECRET and registrations == 1,
        "disabled or invalid optional skins retain a usable native window and the saved key")
    assert(window.scale > 0 and window.scale < 1
        and window:GetWidth() * window.scale <= disabledEnvironment.UIParent:GetWidth()
        and window:GetHeight() * window.scale <= disabledEnvironment.UIParent:GetHeight(),
        "the shared native window fits a viewport smaller than its preferred size")
    disabled:OpenOptions()
    disabled.optionsPanel.secret:UserInput(OTHER_SECRET)
    disabled.optionsPanel.applyGroup:Click()
    disabled.mainPanel.CloseButton:Click()
    assert(not disabled.optionsPanel:IsVisible() and disabled.optionsPanel.secret:GetText() == ""
        and disabled:GetGroupSecret() == SECRET,
        "the native title-bar close button clears drafts without confirming a group switch")
    disabledEnvironment.UIParent:SetSize(1920, 1080)
    disabled:OpenOptions()
    assert(window.scale == 1 and disabled.optionsPanel.applyGroup:GetText() == "Use key",
        "reopening on a larger viewport restores normal scale and resets confirmation")
    disabledEnvironment.UIParent:Hide()
    disabledEnvironment.UIParent:SetSize(640, 480)
    disabledEnvironment.UIParent:Show()
    assert(window.scale < 1 and disabled.optionsPanel:IsVisible(),
        "restoring the interface fits the shared window to a changed viewport")
end

do
    local skin, appearance = skinFixture()
    local early, _, earlyMessages = loadSkinnedOptions(function(_, callback) callback(skin) end)
    assert(not early.optionsPanel and not early.contentPanel and appearance.shells == 0,
        "an enabled skin callback before first use preserves lazy window creation")
    early:OpenContent()
    local content = early.contentPanel
    local window = early.mainPanel
    assert(window.skinApplied and window.TitleText.font[1] == appearance.font
        and window.TitleText.font[2] == 16 and not content.ownSecret,
        "Content receives the optional font while keeping its heading size and key-free UI")
    appearance.font = "SkinFont-B.ttf"
    appearance.accent = { 0.9, 0.3, 0.6 }
    for _, callback in ipairs(appearance.looks) do callback() end
    early:RefreshOverview()
    assert(window.TitleText.font[1] == appearance.font and not early.optionsPanel
        and content.overviewPage.rows[1].progressFill.textureColor[1] == appearance.accent[1]
        and content.overviewPage.rows[1].progressFill.textureColor[3] == appearance.accent[3],
        "live Content font and progress accent updates preserve lazy Settings creation")
    content.options:Click()
    local options = early.optionsPanel
    assert(window.skinApplied and window.TitleText.font[1] == appearance.font
        and options.positionSharing:GetCheckedTexture().vertexColor[1] == appearance.accent[1]
        and appearance.shells == 1,
        "later-created Settings uses the current font and accent without another shell")
    options.secret:UserInput(OTHER_SECRET)
    options.applyGroup:Click()
    options.secret:SetFocus()
    appearance.font = "SkinFont-C.ttf"
    appearance.accent = { 0.4, 0.6, 1 }
    for _, callback in ipairs(appearance.looks) do callback() end
    assert(window.TitleText.font[1] == appearance.font and options.secret.focused
        and options.secret:GetText() == OTHER_SECRET and options.applyGroup:GetText() == "Confirm switch"
        and options.ownSecret:GetText() == SECRET and early:GetGroupSecret() == SECRET,
        "live Settings appearance changes preserve Group focus, saved copy key and pending confirmation")
    options.tabs.position:Click()
    assert(options.tabs.position.skinTabApplied and options.tabs.position.skinTabSelected
        and not options.tabs.group.skinTabSelected and not options.tabs.chat.skinTabSelected,
        "the optional skin selects exactly the active Settings category")
    options.tabs.position.scripts.OnEnter(options.tabs.position)
    options.tabs.position.scripts.OnLeave(options.tabs.position)
    assert(options.tabs.position:GetFontString().alpha == 0,
        "selecting and hovering a skinned tab keeps its replaced native label hidden")
    for _, callback in ipairs(appearance.looks) do callback() end
    assert(options.positionSharing:GetCheckedTexture().vertexColor[1] == appearance.accent[1]
        and options.positionSharing:GetCheckedTexture().vertexColor[3] == appearance.accent[3]
        and options.selectedTab == "position" and options.pages.position:IsVisible()
        and options.tabs.position.skinTabSelected and not options.tabs.group.skinTabSelected
        and options.tabs.position:GetFontString().alpha == 0,
        "appearance updates retain the Settings page and its skin selection")
    options.content:Click()
    for _, callback in ipairs(appearance.looks) do callback() end
    assert(content:IsVisible() and not options:IsVisible() and content.pages.overview:IsVisible()
        and content.tabs.overview.skinTabApplied and content.tabs.overview.skinTabSelected
        and content.tabs.overview:GetFontString().alpha == 0 and options.ownSecret:GetText() == "",
        "restyling Content keeps Overview selected and hidden Group keys empty")
    early:OpenOptions("group")
    options.secret:UserInput(OTHER_SECRET)
    options.applyGroup:Click()
    options.parent.CloseButton:Click()
    assert(not options:IsVisible() and options.ownSecret:GetText() == "" and options.secret:GetText() == "",
        "the styled Settings close button preserves hidden-key cleanup")
    for _, callback in ipairs(appearance.looks) do callback() end
    assert(options.ownSecret:GetText() == "" and options.secret:GetText() == "",
        "restyling hidden Settings never restores cleared keys")
    early:OpenOptions()
    assert(options.ownSecret:GetText() == SECRET and options.applyGroup:GetText() == "Use key"
        and appearance.shells == 1 and #appearance.looks == 1,
        "reopening reuses one styled window and resets confirmation without registering the skin again")
    assert(not contains(earlyMessages, SECRET) and not contains(earlyMessages, OTHER_SECRET),
        "skin refresh never prints key fields")
end
do
    local registration
    local late, _, _, lateWorld = loadSkinnedOptions(function(_, callback) registration = callback end)
    late:OpenOptions()
    local options = late.optionsPanel
    options.tabs.chat:Click()
    options.autoJoin:Click()
    options.tabs.group:Click()
    options.secret:UserInput(OTHER_SECRET)
    options.applyGroup:Click()
    local skin, appearance = skinFixture()
    registration(skin)
    assert(late.mainPanel.skinApplied and late.mainPanel.TitleText.font[1] == appearance.font
        and options.secret:GetText() == OTHER_SECRET and options.applyGroup:GetText() == "Confirm switch"
        and options.autoJoin:GetChecked() and late.db.chat.autoJoin,
        "a late skin callback preserves group confirmation and applied feature preferences")
    options.applyGroup:Click()
    assert(late:GetGroupSecret() == OTHER_SECRET and options.secret:GetText() == ""
        and #lateWorld.joinCalls >= 1,
        "confirmation and key cleanup still work after skinning an open form")
end

do
    local skin, appearance = skinFixture()
    skin.SetTabSelection = nil
    local partial = loadSkinnedOptions(function(_, callback) callback(skin) end)
    partial:OpenOptions()
    local options = partial.optionsPanel
    options.tabs.chat:Click()
    for _, callback in ipairs(appearance.looks) do callback() end
    assert(appearance.tabs == 0 and not options.tabs.chat.skinTabApplied
        and options.selectedTab == "chat" and options.pages.chat:IsVisible()
        and not options.pages.group:IsVisible() and options.tabs.chat.themeTab.selected
        and options.tabs.chat:GetFontString().alpha ~= 0,
        "a skin without tab-selection support leaves native Settings categories usable")
    options.content:Click()
    local content = partial.contentPanel
    for _, callback in ipairs(appearance.looks) do callback() end
    assert(not content.tabs.overview.skinTabApplied and content.tabs.overview.themeTab.selected
        and content.tabs.overview:GetFontString().alpha ~= 0 and content.pages.overview:IsVisible(),
        "a skin without tab-selection support also leaves Content navigation usable")
end

do
    local broken = loadSkinnedOptions(function() error("optional registration failure") end)
    broken:OpenOptions()
    assert(broken.optionsPanel:IsShown() and broken:GetGroupSecret() == SECRET,
        "optional registration failure cannot block native settings")
    local throwing = {}
    for _, name in ipairs({ "Shell", "Panel", "Button", "CloseButton", "EditBox", "Checkbox",
        "StateButtonLabel", "Font", "GetAccentColor", "OnLooksChanged" }) do
        throwing[name] = function() error("optional appearance failure") end
    end
    local resilient, _, resilientMessages = loadSkinnedOptions(function(_, callback) callback(throwing) end)
    resilient:OpenOptions()
    resilient.optionsPanel.secret:UserInput(OTHER_SECRET)
    resilient.optionsPanel.applyGroup:Click()
    resilient.optionsPanel.applyGroup:Click()
    resilient.mainPanel.CloseButton:Click()
    assert(resilient:GetGroupSecret() == OTHER_SECRET and not resilient.optionsPanel:IsVisible()
        and resilient.optionsPanel.ownSecret:GetText() == "" and resilient.optionsPanel.secret:GetText() == "",
        "throwing skin methods cannot block group confirmation or hidden-key cleanup")
    assert(resilient.mainPanel.CloseButton:GetFontString().alpha ~= 0,
        "failed close-button skinning keeps the native close symbol visible")
    assert(not contains(resilientMessages, "optional appearance failure") and not contains(resilientMessages, OTHER_SECRET),
        "optional skin errors do not expose internal errors or key contents")
end

assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep test environments isolated")
print("PASS: native and optional window styling, lazy views and key privacy")
