local _, addon = ...
local CONTACT_TIMEOUT = 90

local function Number(value, maximum)
    return not (issecretvalue and issecretvalue(value)) and type(value) == "number"
        and value == value and value >= 0 and value <= maximum and value % 1 == 0
end

local function Active(self)
    return self.initialized and self.ready and self.burnedState and not self.burnedState.stopped
        and not self.savedDataReadOnly and self:HasGroup() and not self:IsGroupSwitching()
end

local function Refresh(self)
    self:Notify("BURNED_CHANGED")
end

local function CancelExpiry(state)
    if state.timer then state.timer:Cancel(); state.timer = nil end
end

local function ResetPeers(self)
    CancelExpiry(self.burnedState)
    self.burnedState.peers = {}
    Refresh(self)
end

local function ScheduleExpiry(self)
    local state, earliest = self.burnedState
    CancelExpiry(state)
    for _, peer in pairs(state.peers) do
        local expires = peer.receivedAt + CONTACT_TIMEOUT
        if not earliest or expires < earliest then earliest = expires end
    end
    if not earliest then return end
    state.timer = C_Timer.NewTimer(math.max(0, earliest - GetTime()), function()
        state.timer = nil
        local changed, now = false, GetTime()
        for id, peer in pairs(state.peers) do
            if now - peer.receivedAt >= CONTACT_TIMEOUT then state.peers[id], changed = nil, true end
        end
        ScheduleExpiry(self)
        if changed then Refresh(self) end
    end)
end

function addon:GetBurnedStatus()
    return self.burnedState and self.burnedState.value or 0
end

function addon:SetBurnedStatus(value)
    if not self.initialized or not self.burnedState then return false, "Still loading. Please try again after login." end
    if self.savedDataReadOnly then return false, "Update LockInTools before changing saved preferences." end
    if (issecretvalue and issecretvalue(value)) or type(value) ~= "number" or value ~= value
        or value < 0 or value > 100 then return false, "Choose a burned status from 0 to 100%." end
    value = math.floor(value + 0.5)
    if self.burnedState.value == value then return true end
    self.burnedState.value, self.db.burned.status = value, value
    Refresh(self)
    -- The shared status scheduler coalesces dragging and retains its send limit.
    if self.ready then self:DataStatusTick() end
    return true
end

function addon:ReceiveBurnedStatus(sender, fields, stamp, sequence, metadata)
    if not Active(self) or not self:IsDataConnected()
        or (issecretvalue and issecretvalue(sender)) or type(sender) ~= "string"
        or sender == "" or #sender > 128 or sender:find("[|%c]") then return false end
    local id, isSelf = self:GetDataSenderIdentity(sender)
    if not id or isSelf or not Number(stamp, 9999999999) or not Number(sequence, 999999999) then return false end
    local state, previous = self.burnedState, self.burnedState.peers[id]
    -- The shared protocol orders complete snapshots. Direct callers retain the
    -- same monotonic stamp/sequence protection as other status consumers.
    if previous and not metadata and (stamp < previous.stamp
        or (stamp == previous.stamp and sequence <= previous.sequence)) then return false end
    local value = type(fields) == "table" and fields.burned
    if not (issecretvalue and issecretvalue(value)) and type(value) == "string"
        and value:match("^%d+$") and #value <= 3 then value = tonumber(value) end
    if not Number(value, 100) then
        -- A complete snapshot without a supported value withdraws the old one;
        -- older clients and invalid values must never become an implicit zero.
        if previous then state.peers[id] = nil; ScheduleExpiry(self); Refresh(self) end
        return false
    end
    state.peers[id] = { value = value, receivedAt = GetTime(), stamp = stamp, sequence = sequence }
    ScheduleExpiry(self)
    Refresh(self)
    return true
end

function addon:GetGroupBurnedStatus()
    if not Active(self) or not self:IsDataConnected() then return { average = nil, count = 0 } end
    local total, count, now = self:GetBurnedStatus(), 1, GetTime()
    for _, peer in pairs(self.burnedState.peers) do
        if now - peer.receivedAt < CONTACT_TIMEOUT then total, count = total + peer.value, count + 1 end
    end
    return { average = total / count, count = count }
end

function addon:InitializeBurned()
    if self.burnedState then return end
    local database = self.savedDataReadOnly and type(LockInToolsDB) == "table" and LockInToolsDB or self.db
    local saved = type(database.burned) == "table" and database.burned or {}
    local value = Number(saved.status, 100) and saved.status or 0
    if not self.savedDataReadOnly then
        self.db.burned = saved
        saved.status = value
    end
    -- Only the personal value is saved. Peer reports are live contact, never an
    -- account-wide cache that could leak between characters or groups.
    self.burnedState = { value = value, peers = {} }
    self:RegisterDataStatusProvider("burned", function()
        if Active(self) then return { burned = self:GetBurnedStatus() } end
    end, function(sender, fields, stamp, sequence, metadata)
        return self:ReceiveBurnedStatus(sender, fields, stamp, sequence, metadata)
    end, function() ResetPeers(self) end)
    self:RegisterNotification("GROUP_CHANGED", function() ResetPeers(self) end)
    self.burnedEvents = self:RegisterGameEvents({ "PLAYER_LOGOUT" }, function(self)
        self.burnedState.stopped = true
        ResetPeers(self)
    end)
end
