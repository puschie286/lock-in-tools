local _, addon = ...
local Crypto = addon.Crypto
local SALT = "LockInTools/group/v1"
local GROUP_WORDS = {
    "acorn", "amber", "apple", "aspen", "badger", "basil", "beach", "birch",
    "bloom", "brook", "cedar", "cherry", "cloud", "clover", "cocoa", "coral",
    "crane", "daisy", "delta", "dune", "eagle", "ember", "fern", "finch",
    "fjord", "flora", "fox", "frost", "gecko", "grove", "hazel", "heron",
    "holly", "honey", "ivy", "jade", "kiwi", "lake", "lark", "lemon",
    "lilac", "lotus", "maple", "melon", "mint", "moss", "olive", "otter",
    "panda", "peach", "pearl", "pine", "plum", "poppy", "raven", "reed",
    "river", "robin", "sage", "seal", "sky", "snow", "tiger", "willow",
}

local function ParseSecret(code)
    if type(code) ~= "string" then return nil end
    local normalized = code:match("^%s*(.-)%s*$"):lower()
    -- Preserve existing groups byte-for-byte. Reserve the old prefix so a
    -- damaged legacy code can never silently become a different friendly key.
    if normalized:sub(1, 5) == "lit1-" then
        local hex = normalized:match("^lit1%-(%x+)$")
        if not hex or #hex ~= 64 then return nil end
        return "LIT1-" .. hex, Crypto.Unhex(hex)
    end
    if #normalized < 3 or #normalized > 40 or normalized:find("--", 1, true)
        or not normalized:match("^[a-z0-9][a-z0-9%-]*[a-z0-9]$") then
        return nil
    end
    return normalized, "LockInTools/group-key/v1/" .. normalized
end

local function DeriveGroup(code, secret)
    -- Stable, domain-separated derivatives. The secret itself is never sent.
    local function derive(purpose)
        return Crypto.HKDFSHA256(secret, SALT, "LockInTools/v1/" .. purpose, 32)
    end
    return {
        code = code,
        fingerprint = Crypto.Hex(derive("identity")):sub(1, 24),
        channelName = "LIT" .. Crypto.Hex(derive("chat/channel")):sub(1, 28),
        channelPassword = Crypto.Hex(derive("chat/password")):sub(1, 31),
        dataChannelName = "LITDATA" .. Crypto.Hex(derive("data/channel")):sub(1, 24),
        dataChannelPassword = Crypto.Hex(derive("data/password")):sub(1, 31),
        authenticationKey = derive("authentication"),
    }
end

local function CanChange(self)
    if not self.initialized or type(self.db) ~= "table" then
        return false, "Still loading. Please try again after login."
    end
    if self.savedDataReadOnly then
        return false, "Update LockInTools before changing the group."
    end
    return true
end

local function BatchChanges(self, apply)
    self:BeginNotificationBatch()
    local ok, problem = pcall(apply)
    self:EndNotificationBatch(not ok)
    if not ok then error(problem, 0) end
end

local function NotifyChanged(self, previousChannel)
    -- Before login there is no active processing or membership to drain.
    BatchChanges(self, function()
        if self.OnDataGroupChanged then self:OnDataGroupChanged() end
        if self.OnGroupChanged then self:OnGroupChanged(previousChannel) end
        if self.OnPositionGroupChanged then self:OnPositionGroupChanged() end
        if self.OnRosterGroupChanged then self:OnRosterGroupChanged() end
        self:Notify("GROUP_CHANGED")
    end)
end

function addon:GenerateGroupKey()
    local allowed, problem = CanChange(self)
    if not allowed then return nil, problem end
    -- Friendly group labels, deliberately using ordinary game randomness.
    -- This is a convenience identifier; it is not a security credential.
    local generator = math.random
    local failure = "Unable to create a group key. Enter a short key of your choice."
    if type(generator) ~= "function" then return nil, failure end
    local okWord, wordIndex = pcall(generator, 1, #GROUP_WORDS)
    if not okWord or type(wordIndex) ~= "number" or wordIndex ~= math.floor(wordIndex)
        or wordIndex < 1 or wordIndex > #GROUP_WORDS then
        return nil, failure
    end
    local okDigits, digits = pcall(generator, 0, 9999)
    if not okDigits or type(digits) ~= "number" or digits ~= math.floor(digits)
        or digits < 0 or digits > 9999 then
        return nil, failure
    end
    return GROUP_WORDS[wordIndex] .. "-" .. string.format("%04d", digits), nil
end

function addon:InitializeGroup()
    self.groupState = nil
    self.groupSwitch = nil
    self.invalidGroupSecret = false
    if type(self.db.group) ~= "table" then self.db.group = { secret = "" } end
    local stored = self.db.group.secret
    if stored == nil or stored == "" then
        self.db.group.secret = ""
        return
    end
    local code, secret = ParseSecret(stored)
    if not code then
        -- Preserve invalid stored input so an update cannot silently erase it.
        self.invalidGroupSecret = true
        return
    end
    self.groupState = DeriveGroup(code, secret)
    if not self.savedDataReadOnly then self.db.group.secret = code end
end

function addon:IsGroupSwitching()
    return self.groupSwitch ~= nil
end

function addon:ScheduleGroupSwitchCheck(delay)
    local transition = self.groupSwitch
    if not transition then return end
    if transition.timer then transition.timer:Cancel() end
    local timer
    timer = C_Timer.NewTimer(delay, function()
        if self.groupSwitch ~= transition or transition.timer ~= timer then return end
        transition.timer = nil
        self:ContinueGroupSwitch()
    end)
    transition.timer = timer
end

function addon:ContinueGroupSwitch()
    local transition = self.groupSwitch
    if not transition then return end
    if not transition.started then
        -- Run on the next event-loop turn: the callback that requested the
        -- change finishes before its transport and queued work are discarded.
        transition.started = true
        BatchChanges(self, function()
            if self.ResetDataForGroupSwitch then self:ResetDataForGroupSwitch() end
            if self.ResetChatForGroupSwitch then self:ResetChatForGroupSwitch() end
            if self.UpdatePositionTimer then self:UpdatePositionTimer() end
            if transition.chat then self:LeaveGroupChannel(transition.chat) end
            if transition.data then self:LeaveGroupChannel(transition.data) end
            transition.nextLeaveAt = GetTime() + 5
        end)
    end

    local function joined(name)
        if not name or not GetChannelName then return false end
        local id = GetChannelName(name)
        return id and id > 0
    end
    local chatJoined, dataJoined = joined(transition.chat), joined(transition.data)
    if chatJoined or dataJoined then
        -- Notices can precede cache removal. Poll membership and repeat a failed
        -- leave at a low rate; never join a replacement while either remains.
        if GetTime() >= transition.nextLeaveAt then
            transition.nextLeaveAt = GetTime() + 5
            if chatJoined then self:LeaveGroupChannel(transition.chat) end
            if dataJoined then self:LeaveGroupChannel(transition.data) end
        end
        self:ScheduleGroupSwitchCheck(1)
        return
    end

    if transition.timer then transition.timer:Cancel() end
    self.groupState = transition.target
    self.groupSwitch = nil
    BatchChanges(self, function()
        if self.OnPositionGroupChanged then self:OnPositionGroupChanged() end
        if self.OnRosterGroupChanged then self:OnRosterGroupChanged() end
        if self.ResumeDataAfterGroupSwitch then self:ResumeDataAfterGroupSwitch()
        elseif self.OnDataGroupChanged then self:OnDataGroupChanged() end
        if self.ResumeChatAfterGroupSwitch then self:ResumeChatAfterGroupSwitch()
        elseif self.OnGroupChanged then self:OnGroupChanged(transition.chat) end
        self:Notify("GROUP_CHANGED")
    end)
end

local function RequestGroup(self, target)
    self.invalidGroupSecret = false
    if not self.ready or (not self.groupState and not self.groupSwitch) then
        local previousChannel = self:GetGroupChannelName()
        self.groupState = target
        NotifyChanged(self, previousChannel)
    elseif self.groupSwitch then
        -- Changes are rare. One pending destination is enough: the latest
        -- request wins while the original memberships finish leaving.
        self.groupSwitch.target = target
        self:Notify("GROUP_CHANGED")
    else
        if not self.groupChannelCleanupEvents and self.RegisterGameEvents then
            self:InitializeGroupChannelCleanup()
        end
        self.groupSwitch = { target = target, chat = self:GetGroupChannelName(),
            data = self:GetGroupDataChannelName() }
        self:ScheduleGroupSwitchCheck(0)
        self:Notify("GROUP_CHANGED")
    end
end

function addon:SetGroupSecret(input)
    local allowed, problem = CanChange(self)
    if not allowed then return false, problem end
    local code, secret = ParseSecret(input)
    if not code then
        return false, "Enter a group key with 3 to 40 letters, digits or single hyphens; start and end with a letter or digit."
    end
    if self:GetGroupSecret() == code then return true end
    local derived = DeriveGroup(code, secret)
    self.db.group = type(self.db.group) == "table" and self.db.group or {}
    self.db.group.secret = code
    RequestGroup(self, derived)
    return true
end

function addon:LeaveGroup()
    local allowed, problem = CanChange(self)
    if not allowed then return false, problem end
    if not self.groupSwitch and not self.groupState and not self.invalidGroupSecret then return true end
    self.db.group = type(self.db.group) == "table" and self.db.group or {}
    self.db.group.secret = ""
    RequestGroup(self, nil)
    return true
end

function addon:HasGroup() return self.groupState ~= nil end
function addon:GetGroupSecret()
    if self.groupSwitch then return self.groupSwitch.target and self.groupSwitch.target.code or "" end
    return self.groupState and self.groupState.code or ""
end
function addon:GetGroupFingerprint() return self.groupState and self.groupState.fingerprint end
function addon:GetGroupChannelName() return self.groupState and self.groupState.channelName end
function addon:GetGroupChannelPassword() return self.groupState and self.groupState.channelPassword end
function addon:GetGroupDataChannelName() return self.groupState and self.groupState.dataChannelName end
function addon:GetGroupDataChannelPassword() return self.groupState and self.groupState.dataChannelPassword end

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function ForEachChatFrame(callback)
    if ChatFrameUtil and type(ChatFrameUtil.ForEachChatFrame) == "function" then
        ChatFrameUtil.ForEachChatFrame(callback)
    elseif DEFAULT_CHAT_FRAME then
        callback(DEFAULT_CHAT_FRAME)
    end
end

function addon:IsObsoleteGroupChannel(name)
    if IsSecret(name) or type(name) ~= "string" or #name ~= 31 then return false end
    local normalized = name:lower()
    -- Match the complete generated namespace, never arbitrary LIT-prefixed rooms.
    if not normalized:match("^lit%x+$") and not normalized:match("^litdata%x+$") then return false end
    if self.groupSwitch and self.groupSwitch.started then return true end
    local chat, data = self:GetGroupChannelName(), self:GetGroupDataChannelName()
    return (not chat or normalized ~= chat:lower()) and (not data or normalized ~= data:lower())
end

function addon:LeaveGroupChannel(name)
    if IsSecret(name) or type(name) ~= "string" or name == "" then return end
    -- Leaving membership alone can retain saved chat-window subscriptions.
    ForEachChatFrame(function(frame)
        if type(frame.RemoveChannel) == "function" then pcall(frame.RemoveChannel, frame, name) end
    end)
    if type(LeaveChannelByName) == "function" then pcall(LeaveChannelByName, name) end
end

function addon:CleanupGroupChannels()
    if not self.ready or self.savedDataReadOnly then return end
    local obsolete = {}
    local function collect(name)
        if self:IsObsoleteGroupChannel(name) then obsolete[name:lower()] = name end
    end
    if type(GetChannelList) == "function" then
        local function collectJoined(...)
            for index = 2, select("#", ...), 3 do collect(select(index, ...)) end
        end
        collectJoined(GetChannelList())
    end
    ForEachChatFrame(function(frame)
        for _, name in pairs(frame.channelList or {}) do collect(name) end
    end)
    -- Snapshot first: native leaves can renumber channels and mutate frame lists.
    for _, name in pairs(obsolete) do self:LeaveGroupChannel(name) end
end

function addon:InitializeGroupChannelCleanup()
    if self.groupChannelCleanupEvents then return end
    self.groupChannelCleanupEvents = self:RegisterGameEvents({ "CHAT_MSG_CHANNEL_NOTICE", "CHANNEL_LEFT",
        "CHANNEL_UI_UPDATE", "PLAYER_ENTERING_WORLD", "UPDATE_CHAT_WINDOWS", "PLAYER_LOGOUT" }, function(self, event, ...)
        if event == "PLAYER_LOGOUT" then
            local transition = self.groupSwitch
            if transition and transition.timer then transition.timer:Cancel() end
            self.groupSwitch = nil
            if self.chatState then self.chatState.stopped = true end
            if self.ResetChatForGroupSwitch then self:ResetChatForGroupSwitch() end
            return
        end
        if not self.ready or self.savedDataReadOnly then return end
        local transition = self.groupSwitch
        if transition then
            -- Native leave events can run before their membership cache changes.
            -- Recheck on a later turn, after the native event finishes processing.
            local name = event == "CHANNEL_LEFT" and select(2, ...) or select(9, ...)
            if event == "CHANNEL_UI_UPDATE" or event == "PLAYER_ENTERING_WORLD"
                or (not IsSecret(name) and type(name) == "string"
                    and ((transition.chat and name:lower() == transition.chat:lower())
                        or (transition.data and name:lower() == transition.data:lower()))) then
                self:ScheduleGroupSwitchCheck(0)
            end
        end
        if event == "CHAT_MSG_CHANNEL_NOTICE" then
            local reason, name = ..., select(9, ...)
            if not IsSecret(reason) and (reason == "YOU_JOINED" or reason == "YOU_CHANGED")
                and self:IsObsoleteGroupChannel(name) then
                -- An abandoned asynchronous join may finish after the group changes.
                self:LeaveGroupChannel(name)
            end
        elseif event == "UPDATE_CHAT_WINDOWS" then
            if self.groupChannelCleanupScheduled then return end
            self.groupChannelCleanupScheduled = true
            C_Timer.After(0, function()
                self.groupChannelCleanupScheduled = nil
                self:CleanupGroupChannels()
            end)
        elseif event == "PLAYER_ENTERING_WORLD" then
            self:CleanupGroupChannels()
        end
    end)
end

function addon:GetGroupStatusText()
    if self:IsGroupSwitching() then return "Leaving previous group..." end
    if self.groupState then return self.groupState.fingerprint end
    if self.invalidGroupSecret then return "Stored group key is invalid. Enter a valid group key." end
    return "No group configured. Enter the same group key as your friends."
end

local function ValidFeature(feature)
    return type(feature) == "string" and #feature <= 64 and feature:match("^[a-z][a-z0-9_.-]*$")
end

-- Optional helpers authenticate a feature's exact serialized bytes. Features
-- choose their own data handling; the shared data pipeline does not sign packets.
-- All members share authority; these tags do not distinguish one member from another.
function addon:GetGroupAuthenticationKey(feature)
    if not self.groupState or not ValidFeature(feature) then return nil end
    return Crypto.HKDFSHA256(self.groupState.authenticationKey, SALT,
        "LockInTools/v1/message/" .. feature, 32)
end

function addon:SignGroupMessage(feature, payload)
    if type(payload) ~= "string" then return nil end
    local key = self:GetGroupAuthenticationKey(feature)
    if not key then return nil end
    return Crypto.Hex(Crypto.HMACSHA256(key, payload))
end

function addon:VerifyGroupMessage(feature, payload, tag)
    if type(tag) ~= "string" or #tag ~= 64 or tag:find("[^0-9a-f]") then return false end
    local expected = self:SignGroupMessage(feature, payload)
    return expected ~= nil and Crypto.Equal(expected, tag)
end
