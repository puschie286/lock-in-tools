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

local function NotifyChanged(self, previousChannel)
    if self.OnGroupChanged then self:OnGroupChanged(previousChannel) end
    if self.RefreshOptions then self:RefreshOptions() end
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

function addon:SetGroupSecret(input)
    local allowed, problem = CanChange(self)
    if not allowed then return false, problem end
    local code, secret = ParseSecret(input)
    if not code then
        return false, "Enter a group key with 3 to 40 letters, digits or single hyphens; start and end with a letter or digit."
    end
    if self.groupState and self.groupState.code == code then return true end
    local previousChannel = self:GetGroupChannelName()
    local derived = DeriveGroup(code, secret)
    self.db.group = type(self.db.group) == "table" and self.db.group or {}
    self.db.group.secret = code
    self.groupState = derived
    self.invalidGroupSecret = false
    NotifyChanged(self, previousChannel)
    return true
end

function addon:LeaveGroup()
    local allowed, problem = CanChange(self)
    if not allowed then return false, problem end
    if not self.groupState and not self.invalidGroupSecret then return true end
    local previousChannel = self:GetGroupChannelName()
    self.db.group = type(self.db.group) == "table" and self.db.group or {}
    self.db.group.secret = ""
    self.groupState = nil
    self.invalidGroupSecret = false
    NotifyChanged(self, previousChannel)
    return true
end

function addon:HasGroup() return self.groupState ~= nil end
function addon:GetGroupSecret() return self.groupState and self.groupState.code or "" end
function addon:GetGroupFingerprint() return self.groupState and self.groupState.fingerprint end
function addon:GetGroupChannelName() return self.groupState and self.groupState.channelName end
function addon:GetGroupChannelPassword() return self.groupState and self.groupState.channelPassword end

function addon:GetGroupStatusText()
    if self.groupState then return self.groupState.fingerprint end
    if self.invalidGroupSecret then return "Stored group key is invalid. Enter a valid group key." end
    return "No group configured. Enter the same group key as your friends."
end

local function ValidFeature(feature)
    return type(feature) == "string" and #feature <= 64 and feature:match("^[a-z][a-z0-9_.-]*$")
end

-- For future transports: authenticate a feature's exact serialized bytes. The
-- transport must separately validate sender IDs, freshness and replay counters.
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
