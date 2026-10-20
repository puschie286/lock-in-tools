local addonName, addon = ...

local SCHEMA_VERSION = 3

local function DefaultChatSettings()
    return { autoJoin = true }
end

addon.name = addonName
addon.version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "development"
addon.initialized = false
addon.ready = false

function addon:Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[LockInTools]|r " .. message)
end

function addon:Initialize()
    if self.initialized then
        return
    end

    local database = LockInToolsDB

    -- Preserve data from a newer release when an older addon is installed.
    if type(database) == "table"
        and type(database.schemaVersion) == "number"
        and database.schemaVersion > SCHEMA_VERSION then
        self.db = {
            schemaVersion = SCHEMA_VERSION,
            showWelcome = type(database.showWelcome) ~= "boolean" or database.showWelcome,
            chat = DefaultChatSettings(),
            group = { secret = "" },
        }
        self.savedDataReadOnly = true
    else
        if type(database) ~= "table" then
            database = {}
        end

        if type(database.showWelcome) ~= "boolean" then
            database.showWelcome = true
        end

        if type(database.chat) ~= "table" then
            database.chat = DefaultChatSettings()
        end
        if type(database.chat.autoJoin) ~= "boolean" then
            database.chat.autoJoin = true
        end
        if type(database.group) ~= "table" then
            database.group = { secret = "" }
        end
        if type(database.group.secret) ~= "string" then
            database.group.secret = ""
        end

        database.schemaVersion = SCHEMA_VERSION
        LockInToolsDB = database
        self.db = database
    end

    self.initialized = true
    self.startupEvents:UnregisterEvent("ADDON_LOADED")
    self:InitializeGroup()
    self:InitializeChat()
    self:InitializeData()
    self:InitializePositions()
    self:InitializeRoster()
    self:InitializeRanking()
    self:InitializeRestedXP()

    -- Also support loading after login through an addon manager.
    if IsLoggedIn() then
        self:OnLogin()
    end
end

function addon:OnLogin()
    if not self.initialized or self.ready then
        return
    end

    self.ready = true
    self.startupEvents:UnregisterEvent("PLAYER_LOGIN")
    self:InitializeMinimapButton()

    if self.savedDataReadOnly then
        self:Print("Saved settings belong to a newer version; preferences are read-only.")
    end

    if self.db.showWelcome then
        self:Print("Loaded. Type /lit to open Content.")
    end

    self:OnChatLogin()
    self:OnDataLogin()
    self:OnPositionLogin()
    self:OnRosterLogin()
    if self.OnRankingLogin then self:OnRankingLogin() end
    if self.db.showWelcome and not self:HasGroup() and not self.savedDataReadOnly then
        self:OpenContent()
    end
end

function addon:SetShowWelcome(enabled)
    if not self.initialized then
        self:Print("Still loading. Please try again after login.")
        return
    end

    if self.savedDataReadOnly then
        self:Print("Update LockInTools before changing saved preferences.")
        return
    end

    self.db.showWelcome = enabled
    self:Print("Login message and initial Content view " .. (enabled and "enabled." or "disabled."))
end

addon.startupEvents = addon:RegisterGameEvents({ "ADDON_LOADED" }, function(self, _, loadedAddonName)
    if loadedAddonName == addonName then self:Initialize() end
end)
addon.startupEvents:RegisterEvent("PLAYER_LOGIN", function() addon:OnLogin() end)
