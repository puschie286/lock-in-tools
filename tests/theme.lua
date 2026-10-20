-- This offline suite is never loaded by the addon.
local fixture = dofile("tests/support/addon.lua")
local loadAddon, settings = fixture.loadAddon, fixture.settings
local SECRET, OTHER_SECRET, contains = fixture.SECRET, fixture.OTHER_SECRET, fixture.contains
local loadOptions = dofile("tests/support/ui.lua")

-- Native styling stays usable with another UI addon installed, on small screens and across views.
do
    local native, api, messages, _, world = loadAddon(settings(SECRET, false), false)
    local registrations = 0
    api.EllesmereUI = { RegisterSkin = function() registrations = registrations + 1; error("unused skin") end }
    world:initialize()
    loadOptions(native, api)
    assert(registrations == 0 and not native.optionsPanel and not native.contentPanel,
        "installing another UI addon neither registers a skin nor constructs native windows")
    api.UIParent:SetSize(640, 480)
    native:OpenContent()
    local window, content = native.mainPanel, native.contentPanel
    assert(window.TitleText.font[1] == "Fonts\\FRIZQT__.TTF" and window.TitleText.font[2] == 16
        and window.CloseButton:GetFontString():GetText() ~= "" and not content.ownSecret,
        "the native window keeps its readable title, close symbol and key-free Content view")
    assert(window.scale > 0 and window.scale < 1
        and window:GetWidth() * window.scale <= api.UIParent:GetWidth()
        and window:GetHeight() * window.scale <= api.UIParent:GetHeight(),
        "the shared window fits a viewport smaller than its preferred size")
    content.options:Click()
    local options = native.optionsPanel
    local checked = options.positionSharing:GetCheckedTexture().vertexColor
    assert(checked[1] == 0.27 and checked[2] == 0.65 and checked[3] == 1,
        "native checkmarks use the same blue accent as player progress")
    options.tabs.position:Click()
    local tab = options.tabs.position
    tab.scripts.OnEnter(tab)
    tab.scripts.OnLeave(tab)
    assert(tab.themeTab.selected and not options.tabs.group.themeTab.selected
        and not options.tabs.chat.themeTab.selected and tab:GetFontString().alpha == 1
        and options.pages.position:IsVisible(),
        "hovering keeps the native tab label visible and exactly one category selected")
    options.tabs.group:Click()
    assert(not options.applyGroup:IsEnabled() and options.applyGroup:GetFontString().alpha == 0.5,
        "an empty draft has a visibly disabled native action")
    options.secret:UserInput(OTHER_SECRET)
    assert(options.applyGroup:IsEnabled() and options.applyGroup:GetFontString().alpha == 1,
        "typing a draft restores the action label without replacing its native styling")
    local paints = options.secret.texturePaints
    options.secret:SetFocus()
    assert(options.secret.focused and options.secret.texturePaints > paints,
        "focusing the native edit box updates its border")
    options.applyGroup:Click()
    options.content:Click()
    assert(content:IsVisible() and not options:IsVisible() and content.tabs.overview.themeTab.selected
        and content.tabs.overview:GetFontString().alpha == 1 and not options.secret.focused
        and options.secret:GetText() == "" and options.ownSecret:GetText() == ""
        and native:GetGroupSecret() == SECRET,
        "switching views preserves native navigation and clears focused keys and unconfirmed drafts")
    api.UIParent:SetSize(1920, 1080)
    native:OpenOptions()
    assert(native.mainPanel == window and window.scale == 1 and options.applyGroup:GetText() == "Use key",
        "reopening on a larger viewport reuses the window, restores scale and resets confirmation")
    options.secret:UserInput(OTHER_SECRET)
    options.applyGroup:Click()
    window.CloseButton:Click()
    assert(not options:IsVisible() and options.secret:GetText() == "" and options.ownSecret:GetText() == ""
        and native:GetGroupSecret() == SECRET, "the native close button clears keys without switching groups")
    native:OpenOptions()
    api.UIParent:Hide()
    api.UIParent:SetSize(640, 480)
    api.UIParent:Show()
    assert(window.scale < 1 and options:IsVisible(),
        "restoring the interface fits the shared window to a changed viewport")
    assert(registrations == 0 and not contains(messages, SECRET) and not contains(messages, OTHER_SECRET),
        "native windows never invoke optional skins or print key fields")
end

-- Future-schema profiles retain readable native controls while blocking preference changes.
do
    local saved = settings(SECRET, false)
    saved.schemaVersion = 4
    local readonly, api, _, _, world = loadAddon(saved, false)
    world:initialize()
    loadOptions(readonly, api)
    readonly:OpenOptions()
    local options = readonly.optionsPanel
    assert(not options.secret:IsEnabled() and options.secret.color[1] == 0.60
        and not options.applyGroup:IsEnabled() and options.applyGroup:GetFontString().alpha == 0.5
        and readonly.mainPanel.TitleText.color[1] == 0.96 and readonly.mainPanel.CloseButton:IsEnabled()
        and saved.group.secret == SECRET,
        "read-only native edits are visibly muted while the heading and close control stay usable and saved keys stay intact")
    options.tabs.chat:Click()
    assert(options.tabs.chat.themeTab.selected and not options.tabs.group.themeTab.selected
        and not options.autoJoin:IsEnabled() and saved.schemaVersion == 4,
        "read-only navigation selects native tabs without enabling edits or changing the saved schema")
end

assert(_G.LockInToolsDB == nil and _G.SLASH_LOCKINTOOLS1 == nil, "keep test environments isolated")
print("PASS: native window styling, responsive views, controls and key privacy")
