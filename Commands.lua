local _, addon = ...

function addon:ShowHelp()
    self:Print("/lit or /lit content - Open Content and your player overview.")
    self:Print("/lit options - Open Settings for your group and features.")
    self:Print("/lit overview - Show group players and party actions.")
    self:Print("/lit ranking [on|off|lock|unlock] - Toggle or arrange the player ranking overlay.")
    self:Print("/lit rxp [import] - Open the local RestedXP import helper.")
    self:Print("/lit rxp cleanup - Remove old RestedXP data from LockInTools settings.")
    self:Print("/lit help - Show commands.")
    self:Print("/lit chat - Write in the shared channel.")
    self:Print("/lit join or /lit leave - Join or leave the shared channel.")
    self:Print("/lit data join or /lit data leave - Retry or briefly disconnect shared data; it reconnects automatically.")
    self:Print("/lit status - Show addon and client information.")
    self:Print("/lit welcome on|off - Enable or disable the login message and initial Content view.")
end

function addon:ShowStatus()
    self:Print("Version " .. self.version .. " - " .. (self.ready and "ready." or "loading."))

    local version, build, _, interfaceVersion = GetBuildInfo()
    self:Print(string.format("Client %s (build %s), interface %s.", version, build, interfaceVersion))

    if self.initialized then
        local settingsState = self.savedDataReadOnly and "read-only" or "available"
        self:Print("Saved settings " .. settingsState .. "; initial Content view "
            .. (self.db.showWelcome and "on." or "off."))
        self:Print("Group: " .. self:GetGroupStatusText())
        self:Print("Shared chat: " .. self:GetChatStatusText())
        self:Print("Group data: " .. self:GetDataStatusText())
        self:Print("Shared positions: " .. self:GetPositionStatusText())
    end
end

function addon:HandleRankingCommand(argument)
    if not self.initialized or not self.ready then
        self:Print("Still loading. Please try again after login.")
        return
    end
    local settings = self:GetRankingSettings()
    local success, message
    if argument == "lock" or argument == "unlock" then
        success, message = self:SetRankingLocked(argument == "lock")
    else
        local enabled = argument == "on" or (argument == "" and not (settings.enabled and not self.rankingOverlayDismissed))
        if self.savedDataReadOnly and settings.enabled then
            -- A read-only saved overlay can still be dismissed/reopened for this session.
            self.rankingOverlayDismissed = not enabled
            self:Notify("RANKING_CHANGED")
            success = true
        else success, message = self:SetRankingEnabled(enabled) end
    end
    if not success then self:Print(message or "Unable to change the ranking overlay.") end
end

function addon:HandleRestedXPCommand(argument)
    if argument ~= "" and argument ~= "import" and argument ~= "cleanup" then
        self:Print("Unknown command. Type /lit help for commands.")
        return
    end
    if not self.initialized or not self.ready then
        self:Print("Still loading. Please try again after login.")
        return
    end
    if argument == "cleanup" then
        local _, message = self:CleanupRestedXPData()
        self:Print(message)
    else self:OpenOptions("restedxp") end
end

function addon:HandleCommand(message)
    local command, argument = (message or ""):match("^%s*(%S*)%s*(.-)%s*$")
    command = command:lower()
    argument = argument:lower()

    if (command == "" or command == "content") and argument == "" then
        self:OpenContent()
    elseif command == "welcome" and argument == "" then
        self:OpenWelcome()
    elseif command == "options" and argument == "" then
        self:OpenOptions()
    elseif command == "overview" and argument == "" then
        self:OpenOverview()
    elseif command == "ranking" and (argument == "" or argument == "on" or argument == "off"
        or argument == "lock" or argument == "unlock") then
        self:HandleRankingCommand(argument)
    elseif command == "rxp" or command == "restedxp" then
        self:HandleRestedXPCommand(argument)
    elseif command == "help" and argument == "" then
        self:ShowHelp()
    elseif command == "chat" and argument == "" then
        self:OpenChatInput()
    elseif command == "join" and argument == "" then
        self:JoinChatChannel(true)
    elseif command == "leave" and argument == "" then
        self:LeaveChatChannel()
    elseif command == "status" and argument == "" then
        self:ShowStatus()
    elseif command == "data" and (argument == "join" or argument == "leave") then
        local _, problem
        if argument == "join" then _, problem = self:JoinDataChannel(true)
        else _, problem = self:LeaveDataChannel() end
        self:Print(problem or self:GetDataStatusText())
    elseif command == "welcome" and (argument == "on" or argument == "off") then
        self:SetShowWelcome(argument == "on")
    else
        self:Print("Unknown command. Type /lit help for commands.")
    end
end

SLASH_LOCKINTOOLS1 = "/lit"
SlashCmdList["LOCKINTOOLS"] = function(message)
    addon:HandleCommand(message)
end
