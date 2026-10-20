local _, addon = ...
local TIMEOUT = 90

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function Number(value, maximum)
    return not IsSecret(value) and type(value) == "number" and value >= 0
        and value <= maximum and value == math.floor(value)
end

local function Identity(name)
    if IsSecret(name) or type(name) ~= "string" or name == "" or #name > 128
        or name:find("[|%c]") then return nil end
    local character, realm = name:match("^([^%-]+)%-(.+)$")
    if not character then character, realm = name, GetNormalizedRealmName() end
    if IsSecret(realm) or type(realm) ~= "string" or realm == "" then return nil end
    return (character .. "-" .. realm:gsub("%s", "")):lower()
end

local function SelfName()
    if NameUtil and type(NameUtil.GetUnmodifiedUnitFullName) == "function" then
        local ok, name = pcall(NameUtil.GetUnmodifiedUnitFullName, "player")
        if ok and Identity(name) then return name end
    end
    local name, realm = UnitFullName("player")
    if IsSecret(name) or IsSecret(realm) or type(name) ~= "string" or name == "" then return nil end
    if type(realm) == "string" and realm ~= "" then name = name .. "-" .. realm:gsub("%s", "") end
    if Identity(name) then return name end
end

local function NativeBoolean(callback, ...)
    if type(callback) ~= "function" then return false end
    local ok, value = pcall(callback, ...)
    return ok and not IsSecret(value) and value and true or false
end

local function Grouped()
    return NativeBoolean(IsInGroup) or NativeBoolean(IsInRaid)
end

local function Active(self)
    return self.initialized and self.ready and self.rosterState and not self.rosterState.stopped
        and not self.savedDataReadOnly and self:HasGroup()
end

local function Refresh(self)
    self:Notify("ROSTER_CHANGED")
end

local function NativeNumber(callback, maximum, ...)
    if type(callback) ~= "function" then return nil end
    local ok, value = pcall(callback, ...)
    if ok and Number(value, maximum) then return value end
end

local function LocalStatus(self)
    local state = self.rosterState
    local nativeLevel = NativeNumber(UnitLevel, 1000, "player") or 0
    if state.pendingLevel and nativeLevel >= state.pendingLevel and state.xpUpdateAfterLevel then
        state.pendingLevel, state.waitingForXP, state.xpUpdateAfterLevel = nil, nil, nil
    end
    local level = state.pendingLevel and math.max(nativeLevel, state.pendingLevel) or nativeLevel
    local result = { level = level, xpState = "unavailable", inParty = Grouped(),
        canInvite = NativeBoolean(C_PartyInfo and C_PartyInfo.CanInvite),
        partyFull = NativeBoolean(C_PartyInfo and C_PartyInfo.IsPartyFull),
        sharing = self.db.position and self.db.position.sharing == true or false }
    local maximumLevel = NativeNumber(GetMaxPlayerLevel, 1000)
    if level > 0 and maximumLevel and maximumLevel > 0 and level >= maximumLevel then
        result.xpState = "max"
    elseif level > 0 and nativeLevel == level and not state.waitingForXP then
        local xp = NativeNumber(UnitXP, 9999999999, "player")
        local maximum = NativeNumber(UnitXPMax, 9999999999, "player")
        if xp and maximum and maximum > 0 and xp <= maximum then
            result.xp, result.xpMax, result.xpState = xp, maximum, "known"
        end
    end
    state.localStatus = result
    return result
end

local function SavePeer(self, id, peer)
    if self.savedDataReadOnly then return end
    self.db.roster.peers[id] = { name = peer.name, level = peer.level, seenAt = peer.seenAt }
end

function addon:ReceivePlayerStatus(sender, fields, stamp, sequence, metadata)
    if not Active(self) or not self:IsDataConnected() or not Identity(sender)
        or self:IsDataSelf(sender) then return false end
    local id, state = Identity(sender), self.rosterState
    local function Reject()
        -- Transport coherence does not prove that this consumer accepted the
        -- merged player data. Retain the last good values visibly stale.
        if metadata and (metadata.kind == "full" or metadata.kind == "delta") and state.peers[id] then
            state.peers[id].statusSynchronized = false
            if state.progress[id] then state.progress[id].disconnected = true end
            Refresh(self)
        end
        return false
    end
    if type(fields) ~= "table" then return Reject() end
    local function FieldNumber(value)
        if not IsSecret(value) and (type(value) == "string" or type(value) == "number") then return tonumber(value) end
    end
    local level, xp, maximum = FieldNumber(fields.level), FieldNumber(fields.xp), FieldNumber(fields.xpMax)
    local flags = {}
    for _, name in ipairs({ "inParty", "canInvite", "partyFull", "sharing" }) do
        local value = fields[name]
        if IsSecret(value) then return Reject() end
        if value == true or value == "true" then flags[name] = true
        elseif value == false or value == "false" then flags[name] = false
        elseif value ~= nil then return Reject() end
    end
    local kind = fields.xpState
    if IsSecret(kind) then return Reject() end
    if not Number(level, 1000) or not Number(stamp, 9999999999) or not Number(sequence, 999999999)
        or (kind ~= "known" and kind ~= "max" and kind ~= "unavailable") then return Reject() end
    if kind == "known" and (level == 0 or not Number(xp, 9999999999)
        or not Number(maximum, 9999999999) or maximum == 0 or xp > maximum) then return Reject() end
    if kind == "max" and level == 0 then return Reject() end
    local previous, peer = state.progress[id], state.peers[id]
    -- The shared protocol validates sessions/revisions, including requested full
    -- snapshots of an unchanged revision. Direct callers retain ordering.
    if previous and not metadata
        and (stamp < previous.stamp or (stamp == previous.stamp and sequence <= previous.sequence)) then
        return false
    end
    local now = GetServerTime()
    local updatedAt = previous and previous.xpUpdatedAt
    if not previous or previous.level ~= (level > 0 and level or nil) or previous.xpState ~= kind
        or previous.xp ~= (kind == "known" and xp or nil) or previous.xpMax ~= (kind == "known" and maximum or nil)
        or not metadata or metadata.kind == "full" then updatedAt = now end
    state.progress[id] = { level = level > 0 and level or nil, xp = kind == "known" and xp or nil,
        xpMax = kind == "known" and maximum or nil, xpState = kind, xpUpdatedAt = updatedAt,
        stamp = stamp, sequence = sequence,
        disconnected = metadata and metadata.coherent == false or false }
    if not peer then
        peer = { name = sender }
        state.peers[id] = peer
    end
    peer.level, peer.seenAt, peer.lastReceived = level > 0 and level or nil, now, GetTime()
    peer.inParty, peer.canInvite, peer.partyFull, peer.sharing = flags.inParty, flags.canInvite, flags.partyFull, flags.sharing
    peer.statusSynchronized = not metadata or metadata.coherent ~= false
    SavePeer(self, id, peer)
    Refresh(self)
    return true
end

function addon:ReceivePlayerContact(sender, stamp, metadata)
    if not Active(self) or not self:IsDataConnected() or not Identity(sender)
        or self:IsDataSelf(sender) or not Number(stamp, 9999999999) then return false end
    local id = Identity(sender)
    local peer, progress = self.rosterState.peers[id], self.rosterState.progress[id]
    if not peer then return false end
    peer.seenAt, peer.lastReceived = GetServerTime(), GetTime()
    if metadata and metadata.coherent == false then
        if progress then progress.disconnected = true end
        peer.statusSynchronized = false
    end
    SavePeer(self, id, peer)
    Refresh(self)
    return true
end

function addon:InitializeRoster()
    if self.rosterState then return end
    local settings = not self.savedDataReadOnly and type(self.db.roster) == "table" and self.db.roster or {}
    if not self.savedDataReadOnly then self.db.roster = settings end
    local fingerprint = self:GetGroupFingerprint()
    if settings.groupFingerprint ~= fingerprint or type(settings.peers) ~= "table" then settings.peers = {} end
    settings.groupFingerprint = fingerprint
    self.rosterState = { peers = {}, progress = {} }
    for id, saved in pairs(settings.peers) do
        if type(saved) == "table" and Identity(saved.name) == id and Number(saved.seenAt, 9999999999)
            and (saved.level == nil or Number(saved.level, 1000)) then
            self.rosterState.peers[id] = { name = saved.name, level = saved.level, seenAt = saved.seenAt }
        else
            settings.peers[id] = nil
        end
    end
    self:RegisterDataStatusProvider("player", function()
        if Active(self) then return LocalStatus(self) end
    end, function(sender, fields, stamp, sequence, metadata)
        return self:ReceivePlayerStatus(sender, fields, stamp, sequence, metadata)
    end, function(connected)
        if connected then self.rosterState.progress = {}
        else
            for _, progress in pairs(self.rosterState.progress) do progress.disconnected = true end
            for _, peer in pairs(self.rosterState.peers) do peer.lastReceived = nil end
        end
        Refresh(self)
    end, function(sender, stamp, metadata)
        return self:ReceivePlayerContact(sender, stamp, metadata)
    end)
    self.rosterEvents = self:RegisterGameEvents({ "PLAYER_LEVEL_UP", "GROUP_ROSTER_UPDATE", "PARTY_LEADER_CHANGED",
        "PLAYER_XP_UPDATE", "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT" }, function(self, event, value)
        if event == "PLAYER_LOGOUT" then self:OnRosterLogout(); return end
        local state = self.rosterState
        if event == "PLAYER_LEVEL_UP" and Number(value, 1000) and value > 0 then
            state.waitingForXP = not (state.localStatus and state.localStatus.level == value
                and state.localStatus.xpState == "known")
            state.pendingLevel, state.xpUpdateAfterLevel = state.waitingForXP and value or nil, nil
        elseif event == "PLAYER_XP_UPDATE" then
            if value ~= nil and value ~= "player" then return end
            local level = NativeNumber(UnitLevel, 1000, "player")
            if state.pendingLevel then state.xpUpdateAfterLevel = true end
            if level and (not state.pendingLevel or level >= state.pendingLevel) then
                state.pendingLevel, state.waitingForXP, state.xpUpdateAfterLevel = nil, nil, nil
            end
        elseif event == "PLAYER_ENTERING_WORLD" then
            state.pendingLevel, state.waitingForXP, state.xpUpdateAfterLevel = nil, nil, nil
        end
        if Active(self) then LocalStatus(self) end
        Refresh(self)
    end)
end

function addon:OnRosterLogin()
    if Active(self) then LocalStatus(self) end
    Refresh(self)
end

function addon:OnRosterGroupChanged()
    local state = self.rosterState
    if not state then return end
    state.peers, state.progress = {}, {}
    if not self.savedDataReadOnly then
        self.db.roster.peers, self.db.roster.groupFingerprint = {}, self:GetGroupFingerprint()
    end
    Refresh(self)
end

function addon:OnRosterLogout()
    if not self.rosterState then return end
    self.rosterState.stopped = true
end

function addon:GetOverviewPlayers()
    if not self.initialized or not self:HasGroup() or not self.rosterState then return {} end
    local rows, byID = {}, {}
    local function Add(id, peer, isSelf)
        local row = { id = id, name = peer.name, level = peer.level, seenAt = peer.seenAt, isSelf = isSelf,
            online = isSelf or (self:IsDataConnected() and peer.lastReceived ~= nil and GetTime() - peer.lastReceived < TIMEOUT),
            inParty = peer.inParty, canInvite = peer.canInvite, partyFull = peer.partyFull, sharing = peer.sharing,
            statusSynchronized = peer.statusSynchronized }
        local progress = isSelf and LocalStatus(self) or self.rosterState.progress[id]
        row.xpState, row.xpStale = "unavailable", false
        if progress then
            row.xpUpdatedAt = isSelf and GetServerTime() or progress.xpUpdatedAt
            row.xpStale = not isSelf and (not row.online or progress.disconnected == true) or false
            if progress.level == row.level then
                row.xp, row.xpMax, row.xpState = progress.xp, progress.xpMax, progress.xpState
            end
        end
        rows[#rows + 1], byID[id] = row, row
        return row
    end
    local name = self.ready and SelfName()
    local ownID = name and Identity(name)
    if ownID then
        local status = LocalStatus(self)
        local level, sharing = status.level, status.sharing
        local row = Add(ownID, { name = name, level = level > 0 and level or nil, seenAt = GetServerTime(),
            inParty = status.inParty, canInvite = status.canInvite, partyFull = status.partyFull, sharing = sharing }, true)
        if sharing and C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition then
            local map = C_Map.GetBestMapForUnit("player")
            if Number(map, 1000000) and map > 0 then
                local position = C_Map.GetPlayerMapPosition(map, "player")
                if not IsSecret(position) and position then
                    local x, y = position:GetXY()
                    if not IsSecret(x) and not IsSecret(y) and type(x) == "number" and type(y) == "number"
                        and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                        row.map, row.x, row.y, row.positionStamp, row.positionAvailable = map, x, y, GetServerTime(), true
                    end
                end
            end
        end
    end
    for id, peer in pairs(self.rosterState.peers) do
        if id ~= ownID and not self:IsDataSelf(peer.name) then Add(id, peer, false) end
    end
    for id, position in pairs(self.GetSharedPositions and self:GetSharedPositions() or {}) do
        if id ~= ownID and not self:IsDataSelf(position.name) then
            local row = byID[id] or Add(id, { name = position.name, seenAt = position.stamp }, false)
            row.map, row.x, row.y = position.map, position.x, position.y
            row.positionStamp = position.positionStamp
            row.positionAvailable = position.positionAvailable == true and position.online == true and row.sharing ~= false
            -- Position discovery provides no party eligibility metadata.
            if not self.rosterState.peers[id] then row.online = self:IsDataConnected() and position.online == true end
        end
    end
    table.sort(rows, function(left, right)
        if left.isSelf ~= right.isSelf then return left.isSelf == true end
        if left.online ~= right.online then return left.online == true end
        return left.id < right.id
    end)
    return rows
end

function addon:GetOverviewActionState(id)
    local result = { invite = false, request = false }
    local row
    for _, candidate in ipairs(self:GetOverviewPlayers()) do if candidate.id == id then row = candidate; break end end
    local reason
    if not Active(self) then reason = "Join a writable LockInTools group after login first."
    elseif not row then reason = "This player is no longer available."
    elseif row.isSelf then reason = "This is your character."
    elseif not row.online then reason = "No recent contact with this player."
    elseif row.statusSynchronized == false then reason = "Waiting for this player's current status."
    elseif NativeBoolean(UnitInParty, row.name) or NativeBoolean(UnitInRaid, row.name) then
        reason = "Already in your party or raid."
    end
    if reason then result.inviteReason, result.requestReason = reason, reason; return result end
    if not C_PartyInfo or type(C_PartyInfo.InviteUnit) ~= "function" then
        result.inviteReason = "Invitations are unavailable in this client."
    elseif not NativeBoolean(C_PartyInfo.CanInvite) then result.inviteReason = "You cannot invite players right now."
    elseif NativeBoolean(C_PartyInfo.IsPartyFull) then result.inviteReason = "Your party or raid is full."
    elseif row.inParty == nil then result.inviteReason = "This player's party status is unavailable."
    elseif row.inParty then result.inviteReason = "This player is already grouped."
    else result.invite = true end
    if not C_PartyInfo or type(C_PartyInfo.RequestInviteFromUnit) ~= "function" then
        result.requestReason = "Join requests are unavailable in this client."
    elseif Grouped() then result.requestReason = "Leave your current party before requesting to join another."
    elseif not row.inParty then result.requestReason = "No active party is known for this player."
    elseif row.partyFull == nil then result.requestReason = "Their party capacity is unavailable."
    elseif row.partyFull then result.requestReason = "Their party or raid is full."
    else result.request = true end
    return result
end

function addon:PerformOverviewAction(id, action)
    if action ~= "invite" and action ~= "request" then return false, "Unknown party action." end
    local state = self:GetOverviewActionState(id)
    if not state[action] then return false, state[action .. "Reason"] end
    local row
    for _, candidate in ipairs(self:GetOverviewPlayers()) do if candidate.id == id then row = candidate; break end end
    if not row then return false, "This player is no longer available." end
    local callback = action == "invite" and C_PartyInfo.InviteUnit or C_PartyInfo.RequestInviteFromUnit
    local ok = pcall(callback, row.name)
    if not ok then return false, "WoW could not process this party action. Try again." end
    return true, "Party action requested. Watch WoW's invitation notices for the result."
end
