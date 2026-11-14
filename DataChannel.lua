local _, addon = ...

local CHANNEL_OPTIONS = { guild = true, friends = true }
local FRIENDS_PREFIX, COMPACT_GUILD_PREFIX = "LITF", "LITG"
local PREFIX_RETRY_DELAY = 30
local FRIEND_SEND_GAP, FRIEND_PROBE_INTERVAL, FRIEND_TIMEOUT = 0.5, 30, 90
local NATIVE_CONTACT_TIMEOUT = 45

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function NativeMembership(api)
    if type(api) ~= "function" then return false end
    local ok, member = pcall(api)
    return ok and not IsSecret(member) and member == true
end

local function CanUseData(self)
    return self.initialized == true and self.ready == true and not self.savedDataReadOnly
        and not self.dataState.stopped
end

local function Enabled(self)
    return self:GetDataChannelEnabled("guild") or self:GetDataChannelEnabled("friends")
end

function addon:GetFriendsDataPrefix()
    return FRIENDS_PREFIX
end

function addon:GetCompactGuildDataPrefix()
    return COMPACT_GUILD_PREFIX
end

function addon:GetDataChannelEnabled(channel)
    if IsSecret(channel) or type(channel) ~= "string" or not CHANNEL_OPTIONS[channel] then return false end
    local database = self.savedDataReadOnly and type(LockInToolsDB) == "table" and LockInToolsDB or self.db
    local settings = type(database) == "table" and database.data
    local channels = type(settings) == "table" and settings.channels
    return type(channels) ~= "table" or channels[channel] ~= false
end

function addon:HasGuild()
    return NativeMembership(IsInGuild)
end

function addon:HasDataGroup()
    return (self:GetDataChannelEnabled("guild") and self:HasGuild())
        or (self.dataState and self.dataState.routes.FRIENDS == true)
end

local function FriendSendAPI(friend, distribution)
    local battleNet = C_BattleNet and C_BattleNet.SendGameData
    if distribution ~= "WHISPER" and friend.gameAccountID and type(battleNet) == "function" then
        return battleNet, "BATTLENET", friend.gameAccountID
    end
    if distribution ~= "BATTLENET" and friend.whisper then
        return C_ChatInfo.SendAddonMessage, "WHISPER", friend.whisper
    end
end

local function HasNativeContact(state, peer, now)
    local legacy, compact = peer.nativeContact.GUILD, peer.nativeContact.COMPACT_GUILD
    return (state.guildLegacyActive and not state.sendFailures.GUILD and legacy
            and now - legacy < NATIVE_CONTACT_TIMEOUT)
        or (state.guildCompactActive and not state.sendFailures.COMPACT_GUILD and compact
            and now - compact < NATIVE_CONTACT_TIMEOUT)
end

local function Confirmed(peer, distribution, now)
    local heardAt = peer.friendContact[distribution]
    return heardAt and now - heardAt < FRIEND_TIMEOUT
end

local function ConfirmedRoute(peer, now)
    if not peer.battleNetRetryAt and Confirmed(peer, "BATTLENET", now) then return "BATTLENET" end
    if Confirmed(peer, "WHISPER", now) then return "WHISPER" end
end

local function CancelFriendTimer(state, key)
    if state[key] then state[key]:Cancel(); state[key] = nil end
end

local function ResetFriendMessages(state)
    CancelFriendTimer(state, "friendProbeTimer")
    CancelFriendTimer(state, "friendSendTimer")
    state.friends, state.friendOutbox = {}, {}
end

local ScheduleFriendSend

local function QueueFriendMessage(self, peer, message, kind, distribution)
    if not FriendSendAPI(peer.friend, distribution) then return false end
    local outbox = self.dataState.friendOutbox
    -- New snapshots replace queued snapshots. Acknowledgments must go back on
    -- each transport that received a hello.
    local beforeSnapshot
    for index, packet in ipairs(outbox) do
        if packet.peer == peer and packet.kind == kind
            and (kind == "snapshot" or packet.distribution == distribution) then
            packet.message, packet.distribution = message, distribution
            return true
        end
        if kind == "ack" and packet.peer == peer and packet.kind == "snapshot" then beforeSnapshot = index end
    end
    table.insert(outbox, beforeSnapshot or #outbox + 1,
        { peer = peer, message = message, kind = kind, distribution = distribution })
    ScheduleFriendSend(self)
    return true
end

ScheduleFriendSend = function(self)
    local state = self.dataState
    if state.friendSendTimer or #state.friendOutbox == 0 then return end
    state.friendSendTimer = C_Timer.NewTimer(FRIEND_SEND_GAP, function()
        state.friendSendTimer = nil
        while #state.friendOutbox > 0 do
            local packet = table.remove(state.friendOutbox, 1)
            local peer, now = packet.peer, GetTime()
            local route = packet.distribution or ConfirmedRoute(peer, now)
            if state.friends[peer.friend.id] == peer
                and (packet.kind == "ack" or not HasNativeContact(state, peer, now))
                and (packet.kind ~= "snapshot" or (route and Confirmed(peer, route, now))) then
                local api, distribution, target = FriendSendAPI(peer.friend, route)
                if api then
                    local prefix, ok, result = self:GetFriendsDataPrefix()
                    if distribution == "BATTLENET" then ok, result = pcall(api, target, prefix, packet.message)
                    else ok, result = pcall(api, prefix, packet.message, "WHISPER", target) end
                    local failure = self:GetDataSendFailure(ok, result)
                    if packet.kind == "hello" then
                        peer.probeAt, peer.probeRoute = now, distribution
                        peer.pendingProbes[distribution] = not failure and now or nil
                    end
                    if distribution == "BATTLENET" and (failure or peer.battleNetRetryAt) then
                        if not peer.battleNetRetryAt or packet.kind == "hello" then
                            peer.battleNetRetryAt = now + FRIEND_PROBE_INTERVAL
                        end
                        if failure then peer.pendingProbes.BATTLENET = nil end
                        if failure and peer.friend.whisper then
                            if not Confirmed(peer, "WHISPER", now) then
                                QueueFriendMessage(self, peer, "1|H", "hello", "WHISPER")
                            elseif packet.kind == "snapshot" then
                                local newerSnapshot
                                for _, pending in ipairs(state.friendOutbox) do
                                    if pending.peer == peer and pending.kind == "snapshot" then
                                        newerSnapshot = true
                                        break
                                    end
                                end
                                if not newerSnapshot then QueueFriendMessage(self, peer, packet.message, "snapshot") end
                            end
                        end
                    end
                    -- An outbound success alone does not confirm that the Battle.net route recovered.
                    if distribution == "BATTLENET" and peer.battleNetRetryAt then
                        failure = failure or peer.sendFailures.BATTLENET
                    end
                    if peer.sendFailures[distribution] ~= failure then
                        peer.sendFailures[distribution] = failure
                        self:Notify("DATA_CHANGED")
                    end
                    break
                end
            end
        end
        ScheduleFriendSend(self)
    end)
end

local function ScheduleFriendProbe(self)
    local state = self.dataState
    if state.friendProbeTimer or not next(state.friends) then return end
    state.friendProbeTimer = C_Timer.NewTimer(FRIEND_PROBE_INTERVAL, function()
        state.friendProbeTimer = nil
        self:RefreshDataRoutes()
        self:Notify("DATA_CHANGED")
    end)
end

local function RefreshDataFriends(self)
    local state = self.dataState
    local friends = self:GetDataChannelEnabled("friends") and self.GetDataFriends and self:GetDataFriends()
    if not friends or not next(friends) then ResetFriendMessages(state); return false end
    local previous, current, now = state.friends, {}, GetTime()
    state.friends = current
    local active, added = false, false
    for id, friend in pairs(friends) do
        if FriendSendAPI(friend) then
            local peer = previous[id]
            if not peer or peer.friend.gameAccountID ~= friend.gameAccountID or peer.friend.whisper ~= friend.whisper
                or peer.friend.guid ~= friend.guid or peer.friend.realm ~= friend.realm then
                peer = { nativeContact = {}, friendContact = {}, sendFailures = {}, pendingProbes = {} }
            end
            peer.friend, current[id] = friend, peer
            if not state.guildLegacyActive then peer.nativeContact.GUILD = nil end
            if not state.guildCompactActive then peer.nativeContact.COMPACT_GUILD = nil end
            local native = HasNativeContact(state, peer, now)
            local route = not native and ConfirmedRoute(peer, now) or nil
            if not native then
                if peer.battleNetRetryAt and now >= peer.battleNetRetryAt then
                    QueueFriendMessage(self, peer, "1|H", "hello", "BATTLENET")
                elseif not peer.probeAt or now - math.max(peer.probeAt,
                    route and peer.friendContact[route] or 0) >= FRIEND_PROBE_INTERVAL then
                    local fallback = friend.whisper and (peer.battleNetRetryAt or peer.probeRoute == "BATTLENET") and "WHISPER"
                    if route or fallback or not peer.battleNetRetryAt then
                        local _, distribution = FriendSendAPI(friend, route or fallback)
                        QueueFriendMessage(self, peer, "1|H", "hello", distribution)
                    end
                end
            end
            added = added or (route ~= nil and route ~= peer.directRoute)
            peer.directRoute = route
            active = active or (not native and (route ~= nil or Confirmed(peer, "BATTLENET", now)))
        end
    end
    for index = #state.friendOutbox, 1, -1 do
        local peer = state.friendOutbox[index].peer
        if current[peer.friend.id] ~= peer then table.remove(state.friendOutbox, index) end
    end
    ScheduleFriendProbe(self)
    return active, added
end

function addon:SendFriendsStatusSnapshot(message)
    if not self:IsDataConnected() or not self.dataState.routes.FRIENDS then return false end
    if not self:IsDataFrame(message) then return false end
    local state, queued, now = self.dataState, false, GetTime()
    for _, candidate in pairs(state.friends) do
        if ConfirmedRoute(candidate, now) and not HasNativeContact(state, candidate, now) then
            queued = QueueFriendMessage(self, candidate, message, "snapshot") or queued
        end
    end
    return queued
end

function addon:DiscardQueuedFriendsBurnedStatus()
    local state, discarded = self.dataState, false
    for index = #state.friendOutbox, 1, -1 do
        local packet = state.friendOutbox[index]
        if packet.kind == "snapshot" then
            local snapshot = self:DecodeFriendsStatus(packet.message)
            if snapshot and snapshot.fields[12] ~= nil then
                table.remove(state.friendOutbox, index)
                discarded = true
            end
        end
    end
    if discarded then self:RequestDataStatusSnapshot(false, true) end
    if #state.friendOutbox == 0 then CancelFriendTimer(state, "friendSendTimer") end
end

function addon:GetFriendsDataSendFailure()
    local failure
    for _, peer in pairs(self.dataState.friends) do
        for _, reason in pairs(peer.sendFailures) do
            if not failure or reason < failure then failure = reason end
        end
    end
    return failure
end

function addon:InitializeDataChannel()
    local state = self.dataState
    state.routes, state.friends, state.friendOutbox = {}, {}, {}
    local prefixResults = Enum and Enum.RegisterAddonMessagePrefixResult
    local sendResults = Enum and Enum.SendAddonMessageResult
    state.nativeAvailable = C_ChatInfo and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function"
        and type(C_ChatInfo.SendAddonMessage) == "function" and prefixResults and sendResults
        and prefixResults.Success ~= nil and prefixResults.DuplicatePrefix ~= nil and sendResults.Success ~= nil
        or false
    self.dataEvents = self:RegisterGameEvents({ "CHAT_MSG_ADDON", "BN_CHAT_MSG_ADDON", "PLAYER_ENTERING_WORLD",
        "PLAYER_GUILD_UPDATE", "PLAYER_LOGOUT" }, self.OnDataEvent)
    self:RegisterNotification("FRIEND_DATA_CHANGED", function()
        self:RefreshDataRoutes()
        self:Notify("DATA_CHANGED")
    end)
end

function addon:IsDataConnected()
    local state = self.dataState
    return state ~= nil and CanUseData(self) and state.connected
end

function addon:RefreshDataRoutes()
    local state, routes = self.dataState, {}
    local connected, guildBefore = state.connected, state.routes.GUILD
    state.routes = routes
    state.guildLegacyActive, state.guildCompactActive = false, false
    local friendAdded
    if CanUseData(self) and state.nativeStarted and state.nativeAvailable then
        if self:GetDataChannelEnabled("guild") and self:HasGuild() then
            state.guildLegacyActive, state.guildCompactActive = state.prefixRegistered, state.compactGuildPrefixRegistered
            if state.guildLegacyActive or state.guildCompactActive then routes.GUILD = true end
        end
        if state.friendsPrefixRegistered then
            local active
            active, friendAdded = RefreshDataFriends(self)
            if active then routes.FRIENDS = true end
        end
    else ResetFriendMessages(state) end
    if not state.guildLegacyActive then state.sendFailures.GUILD = nil end
    if not state.guildCompactActive then state.sendFailures.COMPACT_GUILD = nil end
    -- Keep the status session while any existing route remains active.
    self:SetDataConnected(next(routes) ~= nil)
    if connected and state.connected and self.RequestDataStatusSnapshot then
        local guildAdded = routes.GUILD and not guildBefore
        if guildAdded or friendAdded then
            self:RequestDataStatusSnapshot(guildAdded, friendAdded)
        end
    end
    return routes
end

function addon:CancelDataTimer()
    local state = self.dataState
    if state.timer then state.timer:Cancel(); state.timer = nil end
end

local function RegisterDataPrefix(prefix)
    local ok, result = pcall(C_ChatInfo.RegisterAddonMessagePrefix, prefix)
    local results = Enum.RegisterAddonMessagePrefixResult
    return ok and not IsSecret(result) and (result == results.Success or result == results.DuplicatePrefix)
end

function addon:StartDataMessages()
    local state = self.dataState
    if state and CanUseData(self) and state.nativeStarted then
        self:CancelDataTimer()
        state.detail = nil
        if Enabled(self) then
            if not state.nativeAvailable then
                state.detail = "The native addon messaging API is unavailable."
            else
                local failed = {}
                if self:GetDataChannelEnabled("guild") then
                    if not state.prefixRegistered then
                        state.prefixRegistered = RegisterDataPrefix(self:GetDataPrefix())
                        if not state.prefixRegistered then failed[#failed + 1] = "legacy guild" end
                    end
                    if not state.compactGuildPrefixRegistered then
                        state.compactGuildPrefixRegistered = RegisterDataPrefix(self:GetCompactGuildDataPrefix())
                        if not state.compactGuildPrefixRegistered then failed[#failed + 1] = "compact guild" end
                    end
                end
                if self:GetDataChannelEnabled("friends") and not state.friendsPrefixRegistered then
                    state.friendsPrefixRegistered = RegisterDataPrefix(self:GetFriendsDataPrefix())
                    if not state.friendsPrefixRegistered then failed[#failed + 1] = "Friends" end
                end
                if #failed > 0 then
                    state.detail = "Could not register " .. table.concat(failed, " and ")
                        .. " messages. Retrying automatically."
                    state.timer = C_Timer.NewTimer(PREFIX_RETRY_DELAY, function()
                        state.timer = nil
                        self:StartDataMessages()
                    end)
                end
            end
        end
        self:RefreshDataRoutes()
    end
    self:Notify("DATA_CHANGED")
end

function addon:SetDataChannelEnabled(channel, enabled)
    if not self.initialized or type(self.db) ~= "table" then return false, "Still loading. Please try again after login." end
    if self.savedDataReadOnly then return false, "Saved preferences are read-only." end
    if IsSecret(channel) or type(channel) ~= "string" or not CHANNEL_OPTIONS[channel]
        or IsSecret(enabled) or type(enabled) ~= "boolean" then return false, "Choose a data channel and on or off." end
    local previous = self:GetDataChannelEnabled(channel)
    if type(self.db.data) ~= "table" then self.db.data = {} end
    if type(self.db.data.channels) ~= "table" then self.db.data.channels = {} end
    self.db.data.channels[channel] = enabled
    if previous == enabled then return true end
    self:StartDataMessages()
    return true
end

function addon:OnDataLogin()
    self:NotifyDataConnection()
    self.dataState.nativeStarted = true
    self:StartDataMessages()
end

function addon:OnDataEvent(event, ...)
    local state = self.dataState
    if event == "PLAYER_LOGOUT" then
        self:CancelDataTimer()
        ResetFriendMessages(state)
        state.stopped, state.routes, state.sendFailures = true, {}, {}
        state.guildLegacyActive, state.guildCompactActive = false, false
        self:SetDataConnected(false)
        return
    end
    if not CanUseData(self) then return end
    if event == "CHAT_MSG_ADDON" or event == "BN_CHAT_MSG_ADDON" then
        local prefix, message, distribution, sender = ...
        if IsSecret(prefix) or IsSecret(message) or IsSecret(distribution) or IsSecret(sender)
            or type(message) ~= "string" then return end
        if event == "BN_CHAT_MSG_ADDON" or distribution == "WHISPER" then
            if not state.friendsPrefixRegistered or prefix ~= self:GetFriendsDataPrefix() then return end
            return self:OnFriendDataMessage(message, sender, event == "BN_CHAT_MSG_ADDON" and "BATTLENET" or "WHISPER")
        end
        if distribution ~= "GUILD" or type(sender) ~= "string"
            or not self:IsDataConnected() or not state.routes.GUILD then return end
        local compact = prefix == self:GetCompactGuildDataPrefix() and state.guildCompactActive
        if not compact and (prefix ~= self:GetDataPrefix() or not state.guildLegacyActive) then return end
        local friend, id
        if self.FindDataFriend then friend, id = self:FindDataFriend(sender) end
        local peer = id and state.friends[id]
        if peer and self:IsValidDataStatusFrame(message, compact) then
            -- The guild route can deliver even if the status decoder has
            -- already seen this revision over another route.
            peer.nativeContact[compact and "COMPACT_GUILD" or "GUILD"] = GetTime()
        end
        if compact then return self:OnCompactGuildDataMessage(friend and friend.name or sender, message, sender) end
        return self:OnDataMessage(friend and friend.name or sender, message, sender)
    else
        if event == "PLAYER_GUILD_UPDATE" then
            local unit = ...
            if not IsSecret(unit) and (unit == nil or unit == "player") then
                for _, peer in pairs(state.friends) do peer.nativeContact.GUILD, peer.nativeContact.COMPACT_GUILD = nil, nil end
            end
        end
        self:RefreshDataRoutes()
        self:Notify("DATA_CHANGED")
    end
end

function addon:OnFriendDataMessage(message, sender, distribution)
    local state, peer = self.dataState
    if not self:GetDataChannelEnabled("friends") then return end
    if distribution == "BATTLENET" and type(sender) == "number" then
        for _, candidate in pairs(state.friends) do
            if candidate.friend.gameAccountID == sender then peer = candidate; break end
        end
    elseif distribution == "WHISPER" and self.FindDataFriend then
        local friend, id = self:FindDataFriend(sender)
        if friend and friend.whisper then peer = state.friends[id] end
    end
    if not peer or not FriendSendAPI(peer.friend, distribution) or self:IsDataSelf(peer.friend.name) then return end
    local now = GetTime()
    if message == "1|H" or message == "1|A" then
        local recovered
        if message == "1|H" then
            if not QueueFriendMessage(self, peer, "1|A", "ack", distribution) then return end
        elseif not peer.pendingProbes[distribution]
            or now - peer.pendingProbes[distribution] >= FRIEND_PROBE_INTERVAL then return
        else
            peer.pendingProbes[distribution] = nil
            if distribution == "BATTLENET" and peer.battleNetRetryAt then
                peer.battleNetRetryAt, peer.sendFailures.BATTLENET = nil, nil
                recovered = true
            end
        end
        local newlyConfirmed = not Confirmed(peer, distribution, now)
        peer.friendContact[distribution] = now
        if newlyConfirmed or recovered then
            self:RefreshDataRoutes()
            self:Notify("DATA_CHANGED")
        end
    elseif Confirmed(peer, distribution, now) and self:IsDataConnected() then
        local ok, accepted = pcall(self.ReceiveFriendsStatusSnapshot, self, peer.friend.name, message)
        if not ok then return false end
        if accepted then peer.friendContact[distribution] = now end
        return accepted
    end
end

function addon:GetDataStatusText()
    if not self.dataState then return "Still loading." end
    if self.savedDataReadOnly then return "Saved preferences are read-only." end
    if not Enabled(self) then return "All data channels are disabled." end
    local state, routes = self.dataState, {}
    if state.routes.GUILD then routes[#routes + 1] = "guild" end
    if state.routes.FRIENDS then routes[#routes + 1] = "friends" end
    local status
    if #routes == 0 then
        status = state.detail or "Waiting for an enabled guild or Friends route."
    else
        status = "Data routes: " .. table.concat(routes, ", ") .. "."
        if state.detail then status = status .. " " .. state.detail end
    end
    local failures = self:GetDataSendStatusText()
    return failures ~= "" and (status .. " " .. failures) or status
end
