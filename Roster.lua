local _, addon = ...
local HEARTBEAT, TIMEOUT, TICK, SNAPSHOT_COOLDOWN = 30, 90, 5, 10

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
    if self.RefreshOverview then self:RefreshOverview() end
end

local function LocalMetadata(self)
    local level = type(UnitLevel) == "function" and UnitLevel("player") or 0
    if not Number(level, 1000) then level = 0 end
    return level, Grouped(), NativeBoolean(C_PartyInfo and C_PartyInfo.CanInvite),
        NativeBoolean(C_PartyInfo and C_PartyInfo.IsPartyFull), self.db.position and self.db.position.sharing == true
end

local function Encode(self)
    local state = self.rosterState
    state.sequence = state.sequence + 1
    local level, grouped, invite, full, sharing = LocalMetadata(self)
    return string.format("1|%d|%d|%d|%d|%d|%d|%d", GetServerTime(), state.sequence,
        level, grouped and 1 or 0, invite and 1 or 0, full and 1 or 0, sharing and 1 or 0)
end

local function SavePeer(self, id, peer)
    if self.savedDataReadOnly then return end
    self.db.roster.peers[id] = { name = peer.name, level = peer.level, seenAt = peer.seenAt }
end

local function Decode(payload)
    if IsSecret(payload) or type(payload) ~= "string" or #payload > 160 then return nil end
    local stamp, sequence, level, grouped, invite, full, sharing = payload:match(
        "^1|(%d+)|(%d+)|(%d+)|([01])|([01])|([01])|([01])$")
    stamp, sequence, level = tonumber(stamp), tonumber(sequence), tonumber(level)
    if not Number(stamp, 9999999999) or not Number(sequence, 999999999)
        or not Number(level, 1000) then return nil end
    return stamp, sequence, level, grouped == "1", invite == "1", full == "1", sharing == "1"
end

function addon:ReceiveRoster(sender, payload)
    if not Active(self) or not self:IsDataConnected() or not Identity(sender)
        or self:IsDataSelf(sender) then return false end
    local stamp, sequence, level, grouped, invite, full, sharing = Decode(payload)
    if not stamp then return false end
    local id, state = Identity(sender), self.rosterState
    local previous = state.peers[id]
    if previous and previous.stamp and (stamp < previous.stamp
        or (stamp == previous.stamp and sequence <= previous.sequence)) then return false end
    local peer = { name = sender, level = level > 0 and level or nil, stamp = stamp, sequence = sequence,
        seenAt = GetServerTime(), lastReceived = GetTime(), inParty = grouped,
        canInvite = invite, partyFull = full, sharing = sharing }
    state.peers[id] = peer
    SavePeer(self, id, peer)
    Refresh(self)
    return true
end

function addon:RequestRosterSnapshot()
    if not Active(self) or not self:IsDataConnected() then return false end
    local state = self.rosterState
    if state.lastSnapshot and GetTime() - state.lastSnapshot < SNAPSHOT_COOLDOWN then return false end
    state.lastSnapshot = GetTime()
    return self:RequestData("roster", Encode(self))
end

function addon:InitializeRoster()
    if self.rosterState then return end
    local settings = not self.savedDataReadOnly and type(self.db.roster) == "table" and self.db.roster or {}
    if not self.savedDataReadOnly then self.db.roster = settings end
    local fingerprint = self:GetGroupFingerprint()
    if settings.groupFingerprint ~= fingerprint or type(settings.peers) ~= "table" then settings.peers = {} end
    settings.groupFingerprint = fingerprint
    self.rosterState = { peers = {}, sequence = 0, generation = 0 }
    for id, saved in pairs(settings.peers) do
        if type(saved) == "table" and Identity(saved.name) == id and Number(saved.seenAt, 9999999999)
            and (saved.level == nil or Number(saved.level, 1000)) then
            self.rosterState.peers[id] = { name = saved.name, level = saved.level, seenAt = saved.seenAt }
        else
            settings.peers[id] = nil
        end
    end
    self:RegisterDataRequest("roster", function(sender, payload)
        if not Active(self) or not self:IsDataConnected() or not Identity(sender)
            or self:IsDataSelf(sender) or not Decode(payload) then return nil end
        -- A snapshot can arrive after a newer broadcast; still answer discovery.
        self:ReceiveRoster(sender, payload)
        return Encode(self)
    end, function(sender, payload) return self:ReceiveRoster(sender, payload) end)
    self:RegisterDataFeature("roster", function(sender, payload) return self:ReceiveRoster(sender, payload) end,
        function(connected)
            local state = self.rosterState
            state.lastSent, state.lastSnapshot = nil, nil
            if not connected then
                for _, peer in pairs(state.peers) do peer.lastReceived = nil end
            elseif Active(self) then
                self:RosterTick()
                self:RequestRosterSnapshot()
            end
            Refresh(self)
        end)
    self.rosterFrame = CreateFrame("Frame")
    for _, event in ipairs({ "PLAYER_LEVEL_UP", "GROUP_ROSTER_UPDATE", "PARTY_LEADER_CHANGED",
        "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT" }) do self.rosterFrame:RegisterEvent(event) end
    self.rosterFrame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_LOGOUT" then self:OnRosterLogout(); return end
        if Active(self) then self:RosterTick(true) end
    end)
end

function addon:UpdateRosterTimer()
    local state = self.rosterState
    if not state then return end
    state.generation = state.generation + 1
    if state.timer then state.timer:Cancel(); state.timer = nil end
    if not Active(self) then return end
    local generation = state.generation
    local function Tick()
        if generation ~= state.generation or not Active(self) then return end
        state.timer = nil
        self:RosterTick()
        if generation == state.generation and Active(self) then state.timer = C_Timer.NewTimer(TICK, Tick) end
    end
    state.timer = C_Timer.NewTimer(TICK, Tick)
end

function addon:RosterTick(force)
    if not Active(self) then return end
    local state = self.rosterState
    local level, grouped, invite, full, sharing = LocalMetadata(self)
    local metadata = table.concat({ level, grouped and 1 or 0, invite and 1 or 0, full and 1 or 0, sharing and 1 or 0 }, "|")
    if self:IsDataConnected() and (force or metadata ~= state.lastMetadata or not state.lastSent
        or GetTime() - state.lastSent >= HEARTBEAT) then
        if self:SendData("roster", Encode(self)) then state.lastSent, state.lastMetadata = GetTime(), metadata end
    end
    Refresh(self)
end

function addon:OnRosterLogin()
    self:UpdateRosterTimer()
    self:RosterTick()
    self:RequestRosterSnapshot()
end

function addon:OnRosterGroupChanged()
    local state = self.rosterState
    if not state then return end
    state.peers, state.lastSent, state.lastSnapshot, state.lastMetadata = {}, nil, nil, nil
    if not self.savedDataReadOnly then
        self.db.roster.peers, self.db.roster.groupFingerprint = {}, self:GetGroupFingerprint()
    end
    self:UpdateRosterTimer()
    Refresh(self)
end

function addon:OnRosterLogout()
    if not self.rosterState then return end
    self.rosterState.stopped = true
    self:UpdateRosterTimer()
end

function addon:GetOverviewPlayers()
    if not self.initialized or not self:HasGroup() or not self.rosterState then return {} end
    local rows, byID = {}, {}
    local function Add(id, peer, isSelf)
        local row = { id = id, name = peer.name, level = peer.level, seenAt = peer.seenAt, isSelf = isSelf,
            online = isSelf or (self:IsDataConnected() and peer.lastReceived ~= nil and GetTime() - peer.lastReceived < TIMEOUT),
            inParty = peer.inParty, canInvite = peer.canInvite, partyFull = peer.partyFull, sharing = peer.sharing }
        rows[#rows + 1], byID[id] = row, row
        return row
    end
    local name = self.ready and SelfName()
    local ownID = name and Identity(name)
    if ownID then
        local level, grouped, invite, full, sharing = LocalMetadata(self)
        local row = Add(ownID, { name = name, level = level > 0 and level or nil, seenAt = GetServerTime(),
            inParty = grouped, canInvite = invite, partyFull = full, sharing = sharing }, true)
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
            -- Old clients still supply useful positions, but no party eligibility metadata.
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
    elseif NativeBoolean(UnitInParty, row.name) or NativeBoolean(UnitInRaid, row.name) then
        reason = "Already in your party or raid."
    end
    if reason then result.inviteReason, result.requestReason = reason, reason; return result end
    if not C_PartyInfo or type(C_PartyInfo.InviteUnit) ~= "function" then
        result.inviteReason = "Invitations are unavailable in this client."
    elseif not NativeBoolean(C_PartyInfo.CanInvite) then result.inviteReason = "You cannot invite players right now."
    elseif NativeBoolean(C_PartyInfo.IsPartyFull) then result.inviteReason = "Your party or raid is full."
    elseif row.inParty then result.inviteReason = "This player is already grouped."
    else result.invite = true end
    if not C_PartyInfo or type(C_PartyInfo.RequestInviteFromUnit) ~= "function" then
        result.requestReason = "Join requests are unavailable in this client."
    elseif Grouped() then result.requestReason = "Leave your current party before requesting to join another."
    elseif not row.inParty then result.requestReason = "No active party is known for this player."
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
