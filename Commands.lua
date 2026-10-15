local _, addon = ...

function addon:ShowHelp()
    self:Print("/lit - Open group and feature options.")
    self:Print("/lit help - Show commands.")
    self:Print("/lit chat - Write in the shared channel.")
    self:Print("/lit join or /lit leave - Join or leave the shared channel.")
    self:Print("/lit status - Show addon and client information.")
    self:Print("/lit welcome on|off - Show or hide the login message.")
end

function addon:ShowStatus()
    self:Print("Version " .. self.version .. " - " .. (self.ready and "ready." or "loading."))

    local version, build, _, interfaceVersion = GetBuildInfo()
    self:Print(string.format("Client %s (build %s), interface %s.", version, build, interfaceVersion))

    if self.initialized then
        local settingsState = self.savedDataReadOnly and "read-only" or "available"
        self:Print("Saved settings " .. settingsState .. "; login message "
            .. (self.db.showWelcome and "on." or "off."))
        self:Print("Group: " .. self:GetGroupStatusText())
        self:Print("Shared chat: " .. self:GetChatStatusText())
    end
end

function addon:HandleCommand(message)
    local command, argument = (message or ""):match("^%s*(%S*)%s*(.-)%s*$")
    command = command:lower()
    argument = argument:lower()

    if (command == "" or command == "options") and argument == "" then
        self:OpenOptions()
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
