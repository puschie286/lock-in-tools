local _, addon = ...
local TIMEOUT = 90
local CLASSES = {
    WARRIOR = true, PALADIN = true, HUNTER = true, ROGUE = true, PRIEST = true,
    SHAMAN = true, MAGE = true, WARLOCK = true, DRUID = true,
}

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function ClassToken(value)
    if not IsSecret(value) and type(value) == "string" and CLASSES[value] then return value end
end

local function Number(value, maximum)
    return not IsSecret(value) and type(value) == "number" and value >= 0
        and value <= maximum and value == math.floor(value)
end

local function Identity(name, fallbackRealm)
    if IsSecret(name) or type(name) ~= "string" or name == "" or #name > 128
        or name:find("[|%c]") then return nil end
    local character, realm = name:match("^([^%-]+)%-(.+)$")
    if not character then
        if name:find("-", 1, true) then return nil end
        character, realm = name, fallbackRealm or GetNormalizedRealmName()
    end
    if IsSecret(realm) or type(realm) ~= "string" or realm == "" then return nil end
    realm = realm:gsub("%s", "")
    if realm == "" then return nil end
    return (character .. "-" .. realm):lower()
end

local function SavedName(name, id)
    if IsSecret(id) or type(id) ~= "string" then return nil end
    -- The saved ID owns the realm; login APIs may not be ready or may now refer
    -- to another character's realm in this account-wide profile.
    local realm = id:match("^[^%-]+%-(.+)$")
    if not realm or Identity(id, realm) ~= id or Identity(name, realm) ~= id then return nil end
    return name:find("-", 1, true) and name or (name .. "-" .. realm)
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
        and not self.savedDataReadOnly and self:HasDataGroup()
end

local function Refresh(self)
    self:Notify("ROSTER_CHANGED")
end

local function NativeNumber(callback, maximum, ...)
    if type(callback) ~= "function" then return nil end
    local ok, value = pcall(callback, ...)
    if ok and Number(value, maximum) then return value end
end

local function NativeGroupRealm()
    if type(GetNormalizedRealmName) ~= "function" then return nil end
    local ok, realm = pcall(GetNormalizedRealmName)
    if not ok or IsSecret(realm) or type(realm) ~= "string" or realm == ""
        or realm:find("[|%c]") then return nil end
    realm = realm:gsub("%s", "")
    return realm ~= "" and realm or nil
end

local function NativeGroupIdentity(name, realm)
    if IsSecret(name) or type(name) ~= "string" then return nil end
    -- A short name belongs only to our cached local realm, never to the first
    -- matching character on another realm in the native roster.
    if not name:find("-", 1, true) then
        if IsSecret(realm) or type(realm) ~= "string" or realm == "" then return nil end
        name = name .. "-" .. realm
    end
    return Identity(name)
end

local function NativeGroupUnitID(unit, fallbackRealm)
    if type(UnitFullName) ~= "function" then return nil end
    local ok, name, realm = pcall(UnitFullName, unit)
    if not ok or IsSecret(realm) or (realm ~= nil and type(realm) ~= "string") then return nil end
    if realm == nil or realm == "" then realm = fallbackRealm end
    return NativeGroupIdentity(name, realm), name
end

local function CacheNativeGroupUnit(units, ambiguous, id, unit)
    if not id or ambiguous[id] then return end
    if units[id] then
        units[id], ambiguous[id] = nil, true
    else
        units[id] = unit
    end
end

function addon:GetNativeGroupUnit(name)
    self:InitializeNativeGroupMembership()
    local state = self.nativeGroupMembership
    local id = NativeGroupIdentity(name, state.realm)
    return id and state.units[id] or nil
end

function addon:GetNativeGroupMemberID(unit)
    local state = self.nativeGroupMembership
    if not state then return nil end
    local id, name = NativeGroupUnitID(unit, state.realm)
    if id and state.units[id] == unit then return id, name end
end

function addon:GetNativePlayerID()
    return NativeGroupUnitID("player", NativeGroupRealm())
end

function addon:RefreshNativeGroupMembership()
    if not self.nativeGroupMembership then self:InitializeNativeGroupMembership(); return end
    local state, units, ambiguous = self.nativeGroupMembership, {}, {}
    state.realm = NativeGroupRealm()
    local ok, inRaid
    if type(IsInRaid) == "function" then ok, inRaid = pcall(IsInRaid) end
    -- Only native roster data can identify units in our current group.
    if ok and not IsSecret(inRaid) and type(inRaid) == "boolean" then
        local count = inRaid and NativeNumber(GetNumGroupMembers, 40)
            or (not inRaid and NativeNumber(GetNumSubgroupMembers, 4))
        if count then
            for index = 1, count do
                local unit = (inRaid and "raid" or "party") .. index
                CacheNativeGroupUnit(units, ambiguous, NativeGroupUnitID(unit, state.realm), unit)
            end
        end
    end
    state.units = units
    self:Notify("NATIVE_GROUP_CHANGED")
end

function addon:InitializeNativeGroupMembership()
    if self.nativeGroupMembership then return end
    self.nativeGroupMembership = { units = {} }
    self:RegisterGameEvents({ "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD",
        "UNIT_NAME_UPDATE" }, function(self, event, unit)
        if event == "UNIT_NAME_UPDATE" then
            if IsSecret(unit) or type(unit) ~= "string"
                or (unit ~= "player" and not unit:match("^party%d+$") and not unit:match("^raid%d+$")) then return end
        end
        self:RefreshNativeGroupMembership()
    end)
    self:RefreshNativeGroupMembership()
end

local STATUS_FLAGS = { "inParty", "canInvite", "partyFull" }

local function SavePeer(self, id, peer)
    if self.savedDataReadOnly then return end
    local saved = { name = SavedName(peer.name, id), level = peer.level, seenAt = peer.seenAt, class = peer.class }
    for _, name in ipairs(STATUS_FLAGS) do saved[name] = peer[name] end
    local progress = self.rosterState.progress[id]
    if progress and progress.level == peer.level then
        saved.xp, saved.xpMax = progress.xp, progress.xpMax
        saved.xpState, saved.xpUpdatedAt = progress.xpState, progress.xpUpdatedAt
    end
    self.db.roster.peers[id] = saved
end

local function RestoreProgress(saved)
    local kind = saved.xpState
    if not Number(saved.xpUpdatedAt, 9999999999)
        or (kind ~= "known" and kind ~= "max" and kind ~= "unavailable") then return nil end
    if kind ~= "unavailable" and (not saved.level or saved.level <= 0) then return nil end
    if kind == "known" and (not Number(saved.xp, 9999999999)
        or not Number(saved.xpMax, 9999999999) or saved.xpMax == 0 or saved.xp > saved.xpMax) then return nil end
    return { level = saved.level, xp = kind == "known" and saved.xp or nil,
        xpMax = kind == "known" and saved.xpMax or nil, xpState = kind,
        xpUpdatedAt = saved.xpUpdatedAt, disconnected = true }
end

local function SaveLocalStatus(self, status)
    if not Active(self) then return end
    local name = SelfName()
    local id = name and Identity(name)
    if not id then return end
    local state, now = self.rosterState, GetServerTime()
    local previous, level = state.progress[id], status.level > 0 and status.level or nil
    local updatedAt = previous and previous.xpUpdatedAt
    if not previous or previous.disconnected or previous.level ~= level or previous.xpState ~= status.xpState
        or previous.xp ~= status.xp or previous.xpMax ~= status.xpMax then updatedAt = now end
    state.progress[id] = { level = level, xp = status.xp, xpMax = status.xpMax,
        xpState = status.xpState, xpUpdatedAt = updatedAt, disconnected = false }
    local peer = { name = name, level = level, seenAt = now, class = status.class, statusSynchronized = true }
    for _, flag in ipairs(STATUS_FLAGS) do peer[flag] = status[flag] end
    state.peers[id] = peer
    SavePeer(self, id, peer)
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
        partyFull = NativeBoolean(C_PartyInfo and C_PartyInfo.IsPartyFull) }
    if type(UnitClass) == "function" then
        local ok, _, class = pcall(UnitClass, "player")
        if ok then result.class = ClassToken(class) end
    end
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
    SaveLocalStatus(self, result)
    return result
end

function addon:ReceivePlayerStatus(sender, fields, stamp, sequence, metadata)
    if not Active(self) or not self:IsDataConnected() or not Identity(sender)
        or self:IsDataSelf(sender) then return false end
    local id, state = Identity(sender), self.rosterState
    local function Reject()
        -- A valid protocol frame may still contain invalid player data.
        -- Retain the last good values visibly stale until a valid report arrives.
        if state.peers[id] then
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
    for _, name in ipairs(STATUS_FLAGS) do
        local value = fields[name]
        if IsSecret(value) or (value ~= nil and type(value) ~= "boolean") then return Reject() end
        flags[name] = value
    end
    local kind = fields.xpState
    if IsSecret(kind) then return Reject() end
    if not Number(level, 1000) or not Number(stamp, 9999999999) or not Number(sequence, 999999999)
        or (kind ~= "known" and kind ~= "max" and kind ~= "unavailable") then return Reject() end
    if kind == "known" and (level == 0 or not Number(xp, 9999999999)
        or not Number(maximum, 9999999999) or maximum == 0 or xp > maximum) then return Reject() end
    if kind == "max" and level == 0 then return Reject() end
    local previous, peer = state.progress[id], state.peers[id]
    -- The shared protocol validates sessions and ordering. Direct callers retain ordering.
    if previous and previous.stamp and not metadata
        and (stamp < previous.stamp or (stamp == previous.stamp and sequence <= previous.sequence)) then
        return false
    end
    level = level > 0 and level or nil
    if kind ~= "known" then xp, maximum = nil, nil end
    local now = GetServerTime()
    local session = metadata and metadata.session
    local updatedAt = previous and previous.xpUpdatedAt
    if not previous or previous.level ~= level or previous.xpState ~= kind
        or previous.xp ~= xp or previous.xpMax ~= maximum
        or previous.disconnected or previous.session ~= session or not peer or not peer.lastReceived
        or GetTime() - peer.lastReceived >= TIMEOUT then updatedAt = now end
    state.progress[id] = { level = level, xp = xp, xpMax = maximum, xpState = kind, xpUpdatedAt = updatedAt,
        stamp = stamp, sequence = sequence, session = session, disconnected = false }
    if not peer then
        peer = { name = sender }
        state.peers[id] = peer
    end
    peer.level, peer.seenAt, peer.lastReceived = level, now, GetTime()
    peer.inParty, peer.canInvite, peer.partyFull = flags.inParty, flags.canInvite, flags.partyFull
    peer.class = ClassToken(fields.class) or peer.class
    peer.statusSynchronized = true
    SavePeer(self, id, peer)
    Refresh(self)
    return true
end

function addon:InitializeRoster()
    if self.rosterState then return end
    local settings = not self.savedDataReadOnly and type(self.db.roster) == "table" and self.db.roster or {}
    if not self.savedDataReadOnly then self.db.roster = settings end
    if type(settings.peers) ~= "table" then settings.peers = {} end
    self.rosterState = { peers = {}, progress = {} }
    for id, saved in pairs(settings.peers) do
        local name = type(saved) == "table" and SavedName(saved.name, id)
        if name and Number(saved.seenAt, 9999999999)
            and (saved.level == nil or Number(saved.level, 1000)) then
            local peer = { name = name, level = saved.level, seenAt = saved.seenAt, class = ClassToken(saved.class),
                statusSynchronized = false }
            for _, flag in ipairs(STATUS_FLAGS) do
                if type(saved[flag]) == "boolean" then peer[flag] = saved[flag] end
            end
            self.rosterState.peers[id] = peer
            self.rosterState.progress[id] = RestoreProgress(saved)
            SavePeer(self, id, peer)
        else
            settings.peers[id] = nil
        end
    end
    self:RegisterDataStatusProvider("player", function()
        if Active(self) then return LocalStatus(self) end
    end, function(sender, fields, stamp, sequence, metadata)
        return self:ReceivePlayerStatus(sender, fields, stamp, sequence, metadata)
    end, function(connected)
        -- Keep last reported values, but never carry live contact or wire ordering
        -- into another connection. Only a fresh status can synchronize a peer.
        for _, progress in pairs(self.rosterState.progress) do
            progress.disconnected = true
            progress.stamp, progress.sequence, progress.session = nil, nil, nil
        end
        for _, peer in pairs(self.rosterState.peers) do
            peer.lastReceived, peer.statusSynchronized = nil, false
        end
        Refresh(self)
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

function addon:OnRosterLogout()
    if not self.rosterState then return end
    if Active(self) then LocalStatus(self) end
    self.rosterState.stopped = true
end

-- Rows cover discovered characters, not every guild/group member or distinct person.
-- Progress is reported, not independently verified; online means recent contact,
-- so contact expiry cannot confirm a logout.
function addon:GetOverviewPlayers(includeSoloSelf)
    if not self.initialized or not self.rosterState then return {} end
    local hasDataGroup = self:HasDataGroup()
    if not hasDataGroup and not includeSoloSelf then return {} end
    local rows = {}
    local function Add(id, peer, isSelf)
        local row = { id = id, name = peer.name, level = peer.level, seenAt = peer.seenAt, isSelf = isSelf,
            online = isSelf or (self:IsDataConnected() and peer.lastReceived ~= nil and GetTime() - peer.lastReceived < TIMEOUT),
            inParty = peer.inParty, canInvite = peer.canInvite, partyFull = peer.partyFull, class = peer.class,
            statusSynchronized = peer.statusSynchronized }
        local progress = isSelf and self.rosterState.localStatus or self.rosterState.progress[id]
        row.xpState, row.xpStale = "unavailable", false
        if progress then
            row.xpStale = not isSelf and (not row.online or progress.disconnected == true) or false
            if progress.level == row.level then
                row.xp, row.xpMax, row.xpState = progress.xp, progress.xpMax, progress.xpState
            end
        end
        rows[#rows + 1] = row
    end
    local name = self.ready and SelfName()
    local ownID = name and Identity(name)
    if ownID then
        local status = LocalStatus(self)
        local level = status.level
        Add(ownID, { name = name, level = level > 0 and level or nil, seenAt = GetServerTime(),
            inParty = status.inParty, canInvite = status.canInvite, partyFull = status.partyFull,
            class = status.class }, true)
    end
    if not hasDataGroup then return rows end
    for id, peer in pairs(self.rosterState.peers) do
        if id ~= ownID and not self:IsDataSelf(peer.name) then Add(id, peer, false) end
    end
    table.sort(rows, function(left, right)
        if left.isSelf ~= right.isSelf then return left.isSelf == true end
        if left.online ~= right.online then return left.online == true end
        return left.id < right.id
    end)
    return rows
end

function addon:GetOverviewActionState(id)
    local result = { invite = false, suggest = false, request = false }
    local row
    for _, candidate in ipairs(self:GetOverviewPlayers()) do if candidate.id == id then row = candidate; break end end
    local reason
    if not Active(self) then reason = "After login, join a guild, party or raid with sharing enabled."
    elseif not row then reason = "This player is no longer available."
    elseif row.isSelf then reason = "This is your character."
    elseif not row.online then reason = "No recent contact with this player."
    elseif row.statusSynchronized == false then reason = "Waiting for this player's current status."
    elseif NativeBoolean(UnitInParty, row.name) or NativeBoolean(UnitInRaid, row.name) then
        reason = "Already in your party or raid."
    end
    if reason then
        result.inviteReason, result.suggestReason, result.requestReason = reason, reason, reason
        return result
    end
    local inviteReason
    if not C_PartyInfo or type(C_PartyInfo.InviteUnit) ~= "function" then
        inviteReason = "Invitations are unavailable in this client."
    elseif NativeBoolean(C_PartyInfo.IsPartyFull) then inviteReason = "Your party or raid is full."
    elseif row.inParty == nil then inviteReason = "This player's party status is unavailable."
    elseif row.inParty then
        inviteReason = "This player is already grouped."
        if Grouped() then result.partyInfo = "Already in another group" end
    elseif Grouped() and not NativeBoolean(UnitIsGroupLeader, "player")
        and not NativeBoolean(UnitIsGroupAssistant, "player") then result.suggest = true
    elseif NativeBoolean(C_PartyInfo.CanInvite) then result.invite = true
    else inviteReason = "You cannot invite players right now." end
    if not result.invite then result.inviteReason = inviteReason or "You cannot invite players right now." end
    if not result.suggest then result.suggestReason = inviteReason or "You cannot suggest an invitation right now." end
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
    if action ~= "invite" and action ~= "suggest" and action ~= "request" then return false, "Unknown party action." end
    local state = self:GetOverviewActionState(id)
    if not state[action] then return false, state[action .. "Reason"] end
    local row
    for _, candidate in ipairs(self:GetOverviewPlayers()) do if candidate.id == id then row = candidate; break end end
    if not row then return false, "This player is no longer available." end
    local target = row.name
    local character, realm = target:match("^([^%-]+)%-(.+)$")
    local localRealm = NativeGroupRealm()
    -- Match native party-menu naming without shortening foreign realms or surnames.
    if realm and localRealm and realm:gsub("%s", ""):lower() == localRealm:lower() then target = character end
    -- WoW routes InviteUnit from an ordinary member as a suggestion to the leader.
    local callback = action == "request" and C_PartyInfo.RequestInviteFromUnit or C_PartyInfo.InviteUnit
    local ok = pcall(callback, target)
    if not ok then return false, "WoW could not process this party action. Try again." end
    return true, "Party action requested. Watch WoW's invitation notices for the result."
end
