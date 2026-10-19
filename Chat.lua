local _, addon = ...

local RETRY_DELAYS = { 2, 4, 8, 8 }
local TERMINAL_NOTICES = {
    WRONG_PASSWORD = "The group chat password was rejected. Check that your friends use the same group secret.",
    BANNED = "You are banned from this channel.",
    YOU_KICKED = "You were removed from this channel. Use Join when you are ready to try again.",
    INVALID_NAME = "WoW rejected this channel name. Choose another name.",
    CHANNEL_FULL = "This channel is full.",
    TOO_MANY_CHANNELS = "You have joined too many channels. Leave another channel and try again.",
    THROTTLED = "WoW is limiting channel requests. Wait a moment, then use Join.",
    RESTRICTED = "Your account cannot join this channel.",
}

local function SameChannel(first, second)
    return type(first) == "string" and type(second) == "string" and first:lower() == second:lower()
end

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

function addon:RememberGroupChannelLabels()
    self.channelDisplayLabels = self.channelDisplayLabels or {}
    local chat, data = self:GetGroupChannelName(), self:GetGroupDataChannelName()
    if chat then self.channelDisplayLabels[chat:lower()] = "LockInTools" end
    if data then self.channelDisplayLabels[data:lower()] = "LockInTools Data" end
end

function addon:GetChannelDisplayName(name)
    if IsSecret(name) or type(name) ~= "string" then return name end
    return self.channelDisplayLabels and self.channelDisplayLabels[name:lower()] or name
end

function addon:InitializeChatDisplay()
    if self.chatDisplayInitialized then return end
    self.chatDisplayInitialized = true
    self:RememberGroupChannelLabels()

    -- Change only the final label. Event fields and native channel lookups also
    -- control routing and membership, so they must retain the actual names.
    if ChatFrameUtil and type(ChatFrameUtil.ResolvePrefixedChannelName) == "function" then
        local resolve = ChatFrameUtil.ResolvePrefixedChannelName
        ChatFrameUtil.ResolvePrefixedChannelName = function(name, ...)
            if not IsSecret(name) and type(name) == "string" then
                local prefix, channel = name:match("^(%d+%.%s+)(.+)$")
                if channel then
                    local label = self:GetChannelDisplayName(channel)
                    if label ~= channel then return prefix .. label end
                end
            end
            return resolve(name, ...)
        end
    end

    if type(hooksecurefunc) ~= "function" then return end
    local hookedHeaders = setmetatable({}, { __mode = "k" })
    local function hookHeader(editBox)
        local header = editBox and editBox.header
        if not header or hookedHeaders[header] or type(header.SetFormattedText) ~= "function" then return end
        hookedHeaders[header] = true
        hooksecurefunc(header, "SetFormattedText", function(target, format, id, name)
            if IsSecret(format) or format ~= CHAT_CHANNEL_SEND or IsSecret(id) then return end
            local label = self:GetChannelDisplayName(name)
            if not IsSecret(name) and label ~= name then
                -- Runs before UpdateHeader measures text and lays out the input.
                target:SetText(string.format(format, id, label))
            end
        end)
    end
    if ChatFrameUtil and type(ChatFrameUtil.ForEachChatFrame) == "function" then
        ChatFrameUtil.ForEachChatFrame(function(frame) hookHeader(frame.editBox) end)
    end
    if EventRegistry and type(EventRegistry.RegisterCallback) == "function" then
        EventRegistry:RegisterCallback("ChatFrame.OnEditBoxShow", function(_, editBox)
            hookHeader(editBox)
        end, self)
    end
end

function addon:CancelChatTimer()
    local state = self.chatState
    state.generation = state.generation + 1
    if state.timer then
        state.timer:Cancel()
        state.timer = nil
    end
end

function addon:SetChatPhase(phase, detail)
    self.chatState.phase = phase
    self.chatState.detail = detail
    self:RefreshOptions()
end

function addon:GetChatStatusText(concise)
    local state = self.chatState
    local name = self:GetGroupChannelName()
    if not name then
        return "Join a LockInTools group first."
    end
    local label = self:GetChannelDisplayName(name)
    if state.phase == "joined" then
        local channelID = GetChannelName(name)
        local text = string.format("Joined %s (/%s).", label, channelID)
        return concise and text or (text .. " Use /lit chat to write.")
    end
    if state.phase == "joining" then
        return "Joining " .. label .. "..."
    end
    if state.phase == "paused" then
        return "Left " .. label .. (concise and "." or ". Use Join to reconnect.")
    end
    return state.detail or (concise and "Not connected." or (label .. " is configured. Use Join to connect."))
end

function addon:ConfirmChatMembership()
    local state = self.chatState
    local configuredName = self:GetGroupChannelName()
    if not configuredName or state.paused or state.failed then
        return false
    end
    local channelID, canonicalName = GetChannelName(configuredName)
    if not channelID or channelID <= 0 then
        return false
    end

    local name = canonicalName or configuredName
    local alreadyDisplayed = false
    for _, displayedName in pairs(DEFAULT_CHAT_FRAME.channelList or {}) do
        if SameChannel(displayedName, name) then
            alreadyDisplayed = true
            break
        end
    end
    if not alreadyDisplayed then
        DEFAULT_CHAT_FRAME:AddChannel(name)
    end

    self:CancelChatTimer()
    state.pending = false
    state.attempts = 0
    self:SetChatPhase("joined")
    self:RefreshChatPassword()
    return true
end

function addon:RefreshChatPassword()
    local state = self.chatState
    local name = self:GetGroupChannelName()
    if not name or state.phase ~= "joined" or state.passwordSet then
        return
    end
    local playerGUID = UnitGUID("player")
    if not playerGUID or IsSecret(playerGUID) then
        return
    end
    -- Roster APIs use display-list indexes, not the local /channel number.
    for displayIndex = 1, GetNumDisplayChannels() do
        local displayName, header, _, _, count = GetChannelDisplayInfo(displayIndex)
        if not header and SameChannel(displayName, name) then
            for rosterIndex = 1, (count or 0) do
                local _, owner, moderator, guid = C_ChatInfo.GetChannelRosterInfo(displayIndex, rosterIndex)
                if not IsSecret(guid) and guid == playerGUID then
                    if not IsSecret(owner) and not IsSecret(moderator) and (owner or moderator) then
                        state.passwordSet = true
                        SetChannelPassword(name, self:GetGroupChannelPassword())
                    end
                    return
                end
            end
            return
        end
    end
end

function addon:ScheduleChatCheck(delay)
    self:CancelChatTimer()
    local state = self.chatState
    local generation = state.generation
    state.timer = C_Timer.NewTimer(delay, function()
        if state.generation ~= generation then
            return
        end
        state.timer = nil
        if not state.wanted or state.paused or state.failed then
            return
        end
        if not self:ConfirmChatMembership() then
            self:JoinChatChannel(false)
        end
    end)
end

function addon:FailChatJoin(message)
    self:CancelChatTimer()
    self.chatState.failed = true
    self.chatState.pending = false
    self.chatState.wanted = false
    self:SetChatPhase("error", message)
    self:Print(message)
end

function addon:JoinChatChannel(manual)
    if not self.ready then
        self:Print("Still loading. Please try again after login.")
        return false
    end

    local state = self.chatState
    if manual then
        self:CancelChatTimer()
        state.paused = false
        state.failed = false
        state.attempts = 0
        state.wanted = true
    end
    if not state.wanted or state.paused or state.failed then
        return false
    end

    local name = self:GetGroupChannelName()
    if not name then
        self:FailChatJoin("Enter your group's shared secret in /lit first.")
        return false
    end
    if self:ConfirmChatMembership() then
        return true
    end
    if state.attempts >= #RETRY_DELAYS then
        self:FailChatJoin("Could not join " .. self:GetChannelDisplayName(name) .. ". Check the channel and use Join to try again.")
        return false
    end

    state.attempts = state.attempts + 1
    state.pending = true
    self:SetChatPhase("joining")

    local channelType = JoinPermanentChannel(name, self:GetGroupChannelPassword(), DEFAULT_CHAT_FRAME:GetID(), 1)
    if not channelType then
        self:FailChatJoin("WoW rejected the group chat join request. Use Join to try again.")
        return false
    end
    state.ownedName = name

    -- Join completion arrives asynchronously; do not label a request as joined.
    if not state.failed and not state.paused and not self:ConfirmChatMembership() then
        self:ScheduleChatCheck(RETRY_DELAYS[state.attempts])
    end
    return true
end

function addon:LeaveChatChannel()
    if not self.initialized then
        return
    end
    self:CancelChatTimer()
    local state = self.chatState
    state.wanted = false
    state.paused = true
    state.pending = false
    state.failed = false
    state.ownedName = nil
    state.passwordSet = false
    self:SetChatPhase("paused")
    local name = self:GetGroupChannelName()
    if name then
        self:LeaveGroupChannel(name)
    end
end

function addon:SetChatAutoJoin(autoJoin)
    if not self.initialized then
        return false, "Still loading. Please try again after login."
    end
    if self.savedDataReadOnly then
        return false, "Update LockInTools before changing saved preferences."
    end

    if type(autoJoin) ~= "boolean" then
        return false, "Choose whether to automatically join on login."
    end

    local state = self.chatState
    self:CancelChatTimer()
    self.db.chat.autoJoin = autoJoin
    state.attempts = 0
    state.paused = false
    state.failed = false
    state.pending = false
    local name = self:GetGroupChannelName()
    state.wanted = autoJoin and name ~= nil
    self:SetChatPhase("idle")

    if name and not self:ConfirmChatMembership() and state.wanted and self.ready then
        self:JoinChatChannel(false)
    end
    return true
end

function addon:OnGroupChanged(previousChannelName)
    if not self.chatState then
        return
    end
    -- Retain old labels for asynchronous leave notices after a group switch.
    self:RememberGroupChannelLabels()
    self:CancelChatTimer()
    -- Leaving/changing the addon group disconnects its transport, even if WoW
    -- restored membership independently. Unrelated custom channels are retained.
    if previousChannelName then
        self:LeaveGroupChannel(previousChannelName)
    end
    self:CleanupGroupChannels()
    local state = self.chatState
    state.attempts, state.pending, state.paused, state.failed = 0, false, false, false
    state.ownedName, state.passwordSet = nil, false
    state.wanted = self:HasGroup() and self.db.chat.autoJoin
    self:SetChatPhase("idle")
    if state.wanted and self.ready then
        self:JoinChatChannel(false)
    end
end

function addon:OpenChatInput()
    if not self.ready then
        self:Print("Still loading. Please try again after login.")
        return
    end
    local state = self.chatState
    local name = self:GetGroupChannelName()
    if state.paused or state.failed or not self:ConfirmChatMembership() then
        self:Print("Join the shared channel through /lit before writing to it.")
        return
    end

    -- Blizzard clears the slash-command input after our handler returns.
    C_Timer.NewTimer(0, function()
        if name ~= self:GetGroupChannelName() or state.paused or state.failed then
            return
        end
        local channelID = GetChannelName(name)
        if not channelID or channelID <= 0 then
            self:Print("The shared channel is no longer connected. Use /lit to reconnect.")
            return
        end
        local editBox = ChatFrameUtil.OpenChat("", DEFAULT_CHAT_FRAME)
        editBox:SetChatType("CHANNEL")
        editBox:SetChannelTarget(name)
        editBox:UpdateHeader()
    end)
end

function addon:OnChatLogin()
    self:CleanupGroupChannels()
    local state = self.chatState
    state.wanted = self.db.chat.autoJoin and self:HasGroup()
    if state.wanted then
        self:SetChatPhase("joining")
        self:ScheduleChatCheck(1)
    else
        self:ConfirmChatMembership()
    end
end

function addon:InitializeChat()
    self.chatState = { phase = "idle", attempts = 0, generation = 0 }
    self:InitializeChatDisplay()
    self:InitializeGroupChannelCleanup()
    self.chatFrame = CreateFrame("Frame")
    self.chatFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    self.chatFrame:RegisterEvent("CHANNEL_UI_UPDATE")
    self.chatFrame:RegisterEvent("CHANNEL_LEFT")
    self.chatFrame:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
    self.chatFrame:RegisterEvent("CHANNEL_PASSWORD_REQUEST")
    self.chatFrame:RegisterEvent("CHANNEL_ROSTER_UPDATE")
    self.chatFrame:RegisterEvent("CHANNEL_FLAGS_UPDATED")
    self.chatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    self.chatFrame:SetScript("OnEvent", function(_, event, ...)
        local state = self.chatState
        local configuredName = self:GetGroupChannelName()
        if not self.ready or not configuredName then
            return
        end
        if event == "CHANNEL_LEFT" then
            local _, name = ...
            if SameChannel(name, configuredName) then
                -- CHANNEL_LEFT precedes removal from GetChannelName's results.
                self:CancelChatTimer()
                state.paused = true
                state.pending = false
                state.wanted = false
                state.ownedName = nil
                state.passwordSet = false
                if not state.failed then
                    self:SetChatPhase("paused")
                end
            end
        elseif event == "CHANNEL_PASSWORD_REQUEST" then
            local name = ...
            if state.pending and SameChannel(name, configuredName) then
                self:FailChatJoin(TERMINAL_NOTICES.WRONG_PASSWORD)
            end
        elseif event == "CHAT_MSG_CHANNEL_NOTICE" then
            local reason = ...
            local name = select(9, ...)
            if not SameChannel(name, configuredName) or IsSecret(reason) then
                return
            end
            if TERMINAL_NOTICES[reason] then
                self:FailChatJoin(TERMINAL_NOTICES[reason])
            elseif reason == "YOU_LEFT" then
                self:CancelChatTimer()
                state.paused = true
                state.pending = false
                state.wanted = false
                state.ownedName = nil
                state.passwordSet = false
                if not state.failed then
                    self:SetChatPhase("paused")
                end
            elseif reason == "YOU_JOINED" or reason == "YOU_CHANGED" then
                -- A native /join or password prompt can complete a rejected join.
                local channelID = GetChannelName(configuredName)
                if channelID and channelID > 0 then
                    state.failed = false
                    state.paused = false
                end
                self:ConfirmChatMembership()
            end
        elseif event == "CHANNEL_ROSTER_UPDATE" or event == "CHANNEL_FLAGS_UPDATED"
            or event == "PLAYER_REGEN_ENABLED" then
            self:RefreshChatPassword()
        elseif event == "CHANNEL_UI_UPDATE" then
            if not state.paused and not state.failed and not self:ConfirmChatMembership()
                and state.phase == "joined" and state.wanted then
                self:SetChatPhase("joining")
                self:ScheduleChatCheck(1)
            end
        elseif event == "PLAYER_ENTERING_WORLD" and state.wanted and not state.paused
            and not state.failed and not state.timer and not self:ConfirmChatMembership() then
            self:ScheduleChatCheck(1)
        end
    end)
end
