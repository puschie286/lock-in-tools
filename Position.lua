local _, addon = ...
local INTERVAL, PEER_TIMEOUT = 2, 60
local CLASS_REQUEST_LIMIT = 3
local CLASSES = {
    WARRIOR = true, PALADIN = true, HUNTER = true, ROGUE = true, PRIEST = true,
    SHAMAN = true, MAGE = true, WARLOCK = true, DRUID = true,
}

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function Number(value, minimum, maximum, integer)
    return not IsSecret(value) and type(value) == "number" and value >= minimum and value <= maximum
        and (not integer or value == math.floor(value))
end

local function ClassToken(value)
    if not IsSecret(value) and type(value) == "string" and CLASSES[value] then return value end
end

local function SenderName(name, fallbackRealm)
    if IsSecret(name) or type(name) ~= "string" or name == "" then return nil end
    local character, realm = name:match("^([^%-]+)%-(.+)$")
    if not character then
        if name:find("-", 1, true) then return nil end
        character, realm = name, fallbackRealm or GetNormalizedRealmName()
    end
    if IsSecret(realm) or type(realm) ~= "string" then return nil end
    realm = realm:gsub("%s", "")
    if realm == "" then return nil end
    return (character .. "-" .. realm):lower()
end

local function SavedName(name, id)
    if IsSecret(id) or type(id) ~= "string" then return nil end
    -- The saved ID owns the realm; login APIs may be unavailable or belong to another realm.
    local realm = id:match("^[^%-]+%-(.+)$")
    if not realm or SenderName(id, realm) ~= id or SenderName(name, realm) ~= id then return nil end
    return name:find("-", 1, true) and name or (name .. "-" .. realm)
end

local function NativeSelfName()
    if not NameUtil or type(NameUtil.GetUnmodifiedUnitFullName) ~= "function" then return nil end
    local ok, name = pcall(NameUtil.GetUnmodifiedUnitFullName, "player")
    if ok then return SenderName(name) end
end

local function Active(self)
    return self.positionState and self.ready and self:HasGroup()
        and not (self.IsGroupSwitching and self:IsGroupSwitching())
        and self.db.position.sharing and not self.savedDataReadOnly
end

local function ClassPayload()
    if not UnitClass then return nil end
    local _, class = UnitClass("player")
    class = ClassToken(class)
    if class then return string.format("1|C|%d|%s", GetServerTime(), class) end
end

local function IsClassMessage(payload)
    if IsSecret(payload) or type(payload) ~= "string" then return false end
    local stamp, class = payload:match("^1|C|(%d+)|([A-Z]+)$")
    return Number(tonumber(stamp), 0, 9999999999, true) and ClassToken(class) ~= nil
end

local function RequestClasses(self)
    local state = self.positionState
    if not Active(self) or not self:IsDataConnected() or not state.classRequestPending then return end
    local payload = ClassPayload()
    if not payload then return end
    state.classRequestAttempts = state.classRequestAttempts + 1
    if self:RequestData("position-class", payload) or state.classRequestAttempts >= CLASS_REQUEST_LIMIT then
        state.classRequestPending = false
    end
end

local function Refresh(self)
    self:Notify("POSITIONS_CHANGED")
end

local function SavePeer(self, sender)
    if self.savedDataReadOnly then return end
    local peer = self.positionState.peers[sender]
    if self.db.position.keepLastKnown and peer then
        self.db.position.peers[sender] = {
            name = SavedName(peer.name, sender), map = peer.map, x = peer.x, y = peer.y,
            stamp = peer.stamp, class = peer.class,
            positionStamp = peer.positionStamp,
        }
    else
        self.db.position.peers[sender] = nil
    end
end

local function ExpirePeers(self)
    local changed = false
    for sender, peer in pairs(self.positionState.peers) do
        if not peer.lastReceived or GetTime() - peer.lastReceived >= PEER_TIMEOUT then
            if not self.db.position.keepLastKnown then
                self.positionState.peers[sender] = nil
                changed = true
            elseif peer.online then
                -- Silence means no signal, not proof that the player logged out.
                peer.online = false
                changed = true
            end
        end
    end
    return changed
end

local function ResetSendState(self)
    local state = self.positionState
    state.lastSentSample, state.lastSendSucceeded, state.sample = nil, nil, nil
    state.classRequestPending, state.classRequestAttempts = true, 0
end

function addon:InitializePositions()
    local settings = self.db.position
    if type(settings) ~= "table" then settings = {}; self.db.position = settings end
    if type(settings.sharing) ~= "boolean" then settings.sharing = false end
    if type(settings.keepLastKnown) ~= "boolean" then settings.keepLastKnown = true end
    if type(settings.showPlayerIcons) ~= "boolean" then settings.showPlayerIcons = true end
    if type(settings.peers) ~= "table" then settings.peers = {} end
    local fingerprint = self:GetGroupFingerprint()
    if settings.groupFingerprint ~= fingerprint or not settings.keepLastKnown then settings.peers = {} end
    settings.groupFingerprint = fingerprint
    self.positionState = { peers = {}, latest = {}, classes = {}, generation = 0 }
    for sender, peer in pairs(settings.peers) do
        local name = type(peer) == "table" and SavedName(peer.name, sender)
        if name
            and Number(peer.map, 1, 1000000, true) and Number(peer.x, 0, 1) and Number(peer.y, 0, 1)
            and Number(peer.stamp, 0, 9999999999, true) then
            self.positionState.peers[sender] = {
                name = name, map = peer.map, x = peer.x, y = peer.y, stamp = peer.stamp,
                online = false, class = ClassToken(peer.class),
                -- Old activity stamps may follow an unavailable-position update.
                positionStamp = Number(peer.positionStamp, 0, peer.stamp, true) and peer.positionStamp or nil,
                positionAvailable = false,
            }
            self.positionState.latest[sender] = peer.stamp
            if ClassToken(peer.class) then
                self.positionState.classes[sender] = { class = peer.class, stamp = peer.stamp }
            end
            if not self.savedDataReadOnly then peer.name = name end
        else
            settings.peers[sender] = nil
        end
    end
    self:RegisterDataRequest("position-class", function(sender, payload)
        if not Active(self) or not IsClassMessage(payload) then return nil end
        -- The request teaches existing peers the newcomer's class too.
        self:ReceivePosition(sender, payload)
        return ClassPayload()
    end, function(sender, payload)
        return IsClassMessage(payload) and self:ReceivePosition(sender, payload)
    end)
    self:RegisterDataFeature("position", function(sender, payload)
        return self:ReceivePosition(sender, payload)
    end, function(connected)
        ResetSendState(self)
        if connected then RequestClasses(self) end
        Refresh(self)
    end)
    if self.InitializePositionMap then self:InitializePositionMap() end
end

function addon:GetSharedPositions()
    if not Active(self) then return {} end
    return self.positionState.peers
end

function addon:UpdatePositionTimer()
    local state = self.positionState
    state.generation = state.generation + 1
    if state.timer then state.timer:Cancel(); state.timer = nil end
    if not Active(self) then return end
    local generation = state.generation
    local function Tick()
        if state.generation ~= generation or not Active(self) then return end
        state.timer = nil
        self:PositionTick()
        if state.generation == generation and Active(self) then
            state.timer = C_Timer.NewTimer(INTERVAL, Tick)
        end
    end
    state.timer = C_Timer.NewTimer(INTERVAL, Tick)
end

function addon:OnPositionLogin()
    self:UpdatePositionTimer()
    RequestClasses(self)
    Refresh(self)
end

local function CanChange(self, enabled)
    if not self.initialized or not self.positionState then return false, "Still loading. Please try again after login." end
    if self.savedDataReadOnly then return false, "Update LockInTools before changing saved preferences." end
    if type(enabled) ~= "boolean" then return false, "Choose on or off." end
    return true
end

function addon:GetShowPlayerIcons()
    return not self.db or type(self.db.position) ~= "table" or self.db.position.showPlayerIcons ~= false
end

function addon:SetShowPlayerIcons(enabled)
    local allowed, message = CanChange(self, enabled)
    if not allowed then return false, message end
    self.db.position.showPlayerIcons = enabled
    self:Notify("POSITION_VISIBILITY_CHANGED")
    return true
end

function addon:SetPositionSharing(enabled)
    local allowed, message = CanChange(self, enabled)
    if not allowed then return false, message end
    if self.db.position.sharing ~= enabled then ResetSendState(self) end
    self.db.position.sharing = enabled
    if enabled then
        ExpirePeers(self)
        RequestClasses(self)
    end
    self:UpdatePositionTimer()
    Refresh(self)
    return true
end

function addon:SetPositionRetention(enabled)
    local allowed, message = CanChange(self, enabled)
    if not allowed then return false, message end
    self.db.position.keepLastKnown = enabled
    self.db.position.peers = {}
    ExpirePeers(self)
    if enabled then
        for sender in pairs(self.positionState.peers) do SavePeer(self, sender) end
    end
    Refresh(self)
    return true
end

function addon:OnPositionGroupChanged()
    if not self.positionState then return end
    self.positionState.peers, self.positionState.latest, self.positionState.classes = {}, {}, {}
    ResetSendState(self)
    self.db.position.peers = {}
    self.db.position.groupFingerprint = self:GetGroupFingerprint()
    self:UpdatePositionTimer()
    Refresh(self)
end

local function Sample()
    if not C_Map or not C_Map.GetBestMapForUnit or not C_Map.GetPlayerMapPosition then return nil end
    local map = C_Map.GetBestMapForUnit("player")
    if not Number(map, 1, 1000000, true) then return nil end
    local position = C_Map.GetPlayerMapPosition(map, "player")
    if IsSecret(position) or not position then return nil end
    local x, y = position:GetXY()
    if not Number(x, 0, 1) or not Number(y, 0, 1) then return nil end
    return map, x, y
end

local function CurrentSample(self)
    local state, stamp = self.positionState, GetServerTime()
    if not state.sample or state.sample.stamp ~= stamp then
        local map, x, y = Sample()
        state.sample = {
            stamp = stamp,
            value = map and string.format("P|%d|%.5f|%.5f", map, x, y) or "U",
            snapshot = map and string.format("P,%d,%d,%.5f,%.5f", stamp, map, x, y)
                or string.format("U,%d", stamp),
        }
    end
    return state.sample
end

function addon:GetPositionSnapshot()
    if not Active(self) then return nil end
    return CurrentSample(self).snapshot
end

function addon:PositionSnapshotSent(snapshot)
    if not Active(self) then return end
    local kind, fields = snapshot:match("^([PU]),%d+(.*)$")
    local state = self.positionState
    local changed = state.lastSendSucceeded ~= true
    state.lastSentSample, state.lastSendSucceeded = kind .. fields:gsub(",", "|"), true
    if changed then Refresh(self) end
end

function addon:ReceivePositionSnapshot(sender, snapshot)
    if IsSecret(snapshot) or type(snapshot) ~= "string" or snapshot:find("|", 1, true)
        or (snapshot:sub(1, 2) ~= "P," and snapshot:sub(1, 2) ~= "U,") then return false end
    return self:ReceivePosition(sender, "1|" .. snapshot:gsub(",", "|"))
end

function addon:PositionTick()
    if not Active(self) then return end
    local changed = ExpirePeers(self)
    local state = self.positionState
    if self:IsDataConnected() then
        local sample = CurrentSample(self)
        -- Compare serialized coordinates without the ever-changing timestamp.
        if state.lastSendSucceeded == false or sample.value ~= state.lastSentSample then
            local payload = "1|" .. sample.snapshot:gsub(",", "|")
            -- Keep only this sample: failed sends retry current data, never a backlog.
            local succeeded = self:SendData("position", payload)
            if state.lastSendSucceeded ~= succeeded then changed = true end
            state.lastSendSucceeded = succeeded
            if succeeded then state.lastSentSample = sample.value end
        end
        RequestClasses(self)
    end
    if changed then Refresh(self) end
end

function addon:ReceivePosition(sender, payload)
    if not Active(self) or IsSecret(payload) or type(payload) ~= "string" or #payload > 255 then return false end
    local canonical = SenderName(sender)
    local ownName, ownRealm = UnitFullName("player")
    if IsSecret(ownName) or IsSecret(ownRealm) then return false end
    local own = ownName and SenderName(ownRealm and ownRealm ~= "" and (ownName .. "-" .. ownRealm) or ownName)
    if not canonical or canonical == own or canonical == NativeSelfName() then return false end
    local fields = {}
    for value in (payload .. "|"):gmatch("([^|]*)|") do fields[#fields + 1] = value end
    local kind, stamp = fields[2], tonumber(fields[3])
    local map, x, y = tonumber(fields[4]), tonumber(fields[5]), tonumber(fields[6])
    local class = ClassToken(fields[4])
    if fields[1] ~= "1" or not Number(stamp, 0, 9999999999, true)
        or not ((kind == "P" and #fields == 6 and Number(map, 1, 1000000, true)
            and Number(x, 0, 1) and Number(y, 0, 1)) or (kind == "U" and #fields == 3)
            or (kind == "C" and #fields == 4 and class)) then return false end
    local state = self.positionState
    if kind == "C" then
        local previous = state.classes[canonical]
        if previous and stamp <= previous.stamp then return false end
        state.classes[canonical] = { class = class, stamp = stamp }
        local peer = state.peers[canonical]
        if peer then
            local changed = peer.class ~= class
            peer.class = class
            SavePeer(self, canonical)
            if changed then Refresh(self) end
        end
        return true
    end
    if state.latest[canonical] and stamp <= state.latest[canonical] then return false end
    state.latest[canonical] = stamp
    local wasOnline = state.peers[canonical] and state.peers[canonical].online
    if kind == "P" then
        state.peers[canonical] = {
            name = sender, map = map, x = x, y = y, stamp = stamp, lastReceived = GetTime(), online = true,
            class = state.classes[canonical] and state.classes[canonical].class,
            positionStamp = stamp, positionAvailable = true,
        }
    elseif self.db.position.keepLastKnown then
        local peer = state.peers[canonical]
        if peer then
            peer.stamp, peer.lastReceived, peer.online = stamp, GetTime(), true
            peer.positionAvailable = false
        end
    else
        state.peers[canonical] = nil
    end
    SavePeer(self, canonical)
    if kind == "P" or not self.db.position.keepLastKnown
        or (state.peers[canonical] and wasOnline ~= true) then
        Refresh(self)
    else
        self:Notify("POSITION_CONTACT_CHANGED")
    end
    return true
end

function addon:GetPositionStatusText(concise)
    if self.savedDataReadOnly then return "Saved preferences are read-only." end
    if not self.db.position.sharing then return "Off." end
    if not self:HasGroup() then return "Join a LockInTools group first." end
    if not self:IsDataConnected() then return "On. Waiting for a group connection." end
    if self.positionState.lastSendSucceeded == false then return "On. Group connection unavailable." end
    return concise and "On." or "On. Movement checks every 2 seconds; idle refresh with player status."
end
