local _, addon = ...

function addon:ShowHelp()
    self:Print("/lit or /lit welcome - Show your key and connect with friends.")
    self:Print("/lit options - Open group and feature options.")
    self:Print("/lit help - Show commands.")
    self:Print("/lit chat - Write in the shared channel.")
    self:Print("/lit join or /lit leave - Join or leave the shared channel.")
    self:Print("/lit data join or /lit data leave - Reconnect or leave shared feature data.")
    self:Print("/lit status - Show addon and client information.")
    self:Print("/lit welcome on|off - Enable or disable the login message and initial welcome screen.")
end

function addon:ShowStatus()
    self:Print("Version " .. self.version .. " - " .. (self.ready and "ready." or "loading."))

    local version, build, _, interfaceVersion = GetBuildInfo()
    self:Print(string.format("Client %s (build %s), interface %s.", version, build, interfaceVersion))

    if self.initialized then
        local settingsState = self.savedDataReadOnly and "read-only" or "available"
        self:Print("Saved settings " .. settingsState .. "; login welcome "
            .. (self.db.showWelcome and "on." or "off."))
        self:Print("Group: " .. self:GetGroupStatusText())
        self:Print("Shared chat: " .. self:GetChatStatusText())
        self:Print("Group data: " .. self:GetDataStatusText())
        self:Print("Shared positions: " .. self:GetPositionStatusText())
    end
end

function addon:HandleCommand(message)
    local command, argument = (message or ""):match("^%s*(%S*)%s*(.-)%s*$")
    command = command:lower()
    argument = argument:lower()

    if (command == "" or command == "welcome") and argument == "" then
        self:OpenWelcome()
    elseif command == "options" and argument == "" then
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
