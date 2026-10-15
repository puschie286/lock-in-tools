-- Published known-answer vectors exercise algorithms independently of addon logic.
local function loadModule(file, addon, environment)
    local chunk, problem
    if setfenv then
        chunk, problem = loadfile(file)
        assert(chunk, problem)
        setfenv(chunk, environment)
    else
        chunk, problem = loadfile(file, "t", environment)
        assert(chunk, problem)
    end
    chunk("LockInTools", addon)
end

local function newAddon(saved)
    -- Use the exact-integer fallback even if the test interpreter has bit32.
    local environment = setmetatable({ bit = false, bit32 = false }, { __index = _G })
    local addon = { db = saved or { group = { secret = "" } }, initialized = true }
    addon.changes, addon.refreshes = {}, 0
    function addon:OnGroupChanged(oldChannel)
        self.changes[#self.changes + 1] = { oldChannel = oldChannel, newChannel = self:GetGroupChannelName() }
    end
    function addon:RefreshOptions() self.refreshes = self.refreshes + 1 end
    loadModule("Crypto.lua", addon, environment)
    loadModule("Group.lua", addon, environment)
    addon:InitializeGroup()
    return addon, environment
end

local addon = newAddon()
local crypto = addon.Crypto
local function verifyCryptoVectors(crypto)
local function sha(text) return crypto.Hex(crypto.SHA256(text)) end
local function hmac(key, text) return crypto.Hex(crypto.HMACSHA256(key, text)) end
local function unhex(text) return assert(crypto.Unhex(text)) end

-- FIPS 180-4 / NIST SHA-256 examples and Python hashlib boundary answers.
assert(sha("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
assert(sha("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
assert(sha("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
    == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
for _, answer in ipairs({
    { 55, "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318" },
    { 56, "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a" },
    { 63, "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34" },
    { 64, "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb" },
    { 65, "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0" },
    { 128, "6836cf13bac400e9105071cd6af47084dfacad4e5e302c94bfed24e013afb73e" },
}) do assert(sha(string.rep("a", answer[1])) == answer[2], "SHA padding boundary failed") end
local binary = {}
for i = 0, 255 do binary[#binary + 1] = string.char(i) end
assert(sha(table.concat(binary)) == "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880")

-- RFC 4231 cases 1, 2, 3, 6, 7, including keys longer than the block size.
assert(hmac(string.rep(string.char(0x0b), 20), "Hi There")
    == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
assert(hmac("Jefe", "what do ya want for nothing?")
    == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
assert(hmac(string.rep(string.char(0xaa), 20), string.rep(string.char(0xdd), 50))
    == "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe")
assert(hmac(string.rep(string.char(0xaa), 131), "Test Using Larger Than Block-Size Key - Hash Key First")
    == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
assert(hmac(string.rep(string.char(0xaa), 131),
    "This is a test using a larger than block-size key and a larger than block-size data. "
    .. "The key needs to be hashed before being used by the HMAC algorithm.")
    == "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2")

-- RFC 5869 appendix A.1 and A.3, including multi-block HKDF output.
assert(crypto.Hex(crypto.HKDFSHA256(string.rep(string.char(0x0b), 22),
    unhex("000102030405060708090a0b0c"), unhex("f0f1f2f3f4f5f6f7f8f9"), 42))
    == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
assert(crypto.Hex(crypto.HKDFSHA256(string.rep(string.char(0x0b), 22), "", "", 42))
    == "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")
assert(crypto.HKDFSHA256("key", "salt", "info", 0) == "")
assert(not pcall(crypto.HKDFSHA256, "key", "salt", "info", 8161), "reject HKDF counter overflow")
assert(crypto.Unhex("x0") == nil and crypto.Unhex("a") == nil)
assert(crypto.Hex(unhex("00AAff")) == "00aaff")
assert(crypto.Equal("a\000b", "a\000b") and not crypto.Equal("a\000b", "a\000c"))
assert(not crypto.Equal("a", "aa") and not crypto.Equal(nil, ""))
end
verifyCryptoVectors(crypto)

local CODE = "LIT1-" .. string.rep("0123456789abcdef", 4)
assert(not addon:HasGroup() and addon:GetGroupSecret() == "")
assert(addon:GetGroupChannelName() == nil and addon:GetGroupChannelPassword() == nil)
assert(not addon:VerifyGroupMessage("position", "hello", string.rep("0", 64)))
assert(addon:SignGroupMessage("position", "hello") == nil)
assert(addon:SetGroupSecret("  " .. CODE:upper() .. "\n"))
assert(addon:GetGroupSecret() == CODE and addon.db.group.secret == CODE)
assert(#addon.changes == 1 and addon.refreshes == 1 and addon.changes[1].oldChannel == nil)
assert(addon:GetGroupFingerprint() == "37bb8a61a5dde1eaa8242d56", "independent Python HKDF identity")
assert(addon:GetGroupChannelName() == "LIT6f0529e89668b8cbe44179db4331", "independent Python HKDF channel")
assert(addon:GetGroupChannelPassword() == "22a0a8ee96f8cf6976f2fbb45a1cff1", "independent Python HKDF password")
assert(crypto.Hex(addon:GetGroupAuthenticationKey("position"))
    == "ded815a69beca727d099b824915311e50f2416614f70b6a5a09a61ff0a1d7c9d", "independent per-feature key")
assert(#addon:GetGroupChannelName() == 31 and #addon:GetGroupChannelPassword() == 31)
assert(not addon:GetGroupStatusText():find(CODE, 1, true), "status must not disclose the secret")
local payload = "map:37,x:0.5,y:0.4"
local tag = addon:SignGroupMessage("position", payload)
assert(tag == "133a759b107a2d803ed02b4cb4c65c895a1a6249393b473e5c503b1d03c23065", "independent Python HMAC")
assert(addon:VerifyGroupMessage("position", payload, tag))
assert(not addon:VerifyGroupMessage("activity", payload, tag), "tags are feature-scoped")
assert(not addon:VerifyGroupMessage("position", payload .. "!", tag), "reject payload tampering")
assert(not addon:VerifyGroupMessage("position", payload, "f" .. tag:sub(2)), "reject tag tampering")
assert(not addon:VerifyGroupMessage("position", payload, tag:upper()), "require canonical wire tags")
assert(not addon:VerifyGroupMessage("position", payload, {}))
assert(addon:SignGroupMessage("bad|feature", payload) == nil and addon:SignGroupMessage("position", false) == nil)

local friend = newAddon({ group = { secret = CODE } })
assert(friend:GetGroupFingerprint() == addon:GetGroupFingerprint(), "same secret means same group")
assert(friend:VerifyGroupMessage("position", payload, tag), "another matching client can verify")
assert(addon:SetGroupSecret(CODE) and #addon.changes == 1, "saving the same secret is idempotent")
for _, bad in ipairs({ "", "LIT1-1234", "-password", "LIT2-" .. CODE:sub(6), CODE .. "a", "LIT1-" .. string.rep("g", 64) }) do
    local ok, problem = addon:SetGroupSecret(bad)
    assert(not ok and type(problem) == "string" and (#bad == 0 or not problem:find(bad, 1, true)), "generic invalid-secret error")
    assert(addon:GetGroupSecret() == CODE and #addon.changes == 1, "invalid input preserves group")
end
assert(not addon:SetGroupSecret(false))
local oldChannel = addon:GetGroupChannelName()
local replacement = "LIT1-" .. string.rep("ab", 32)
assert(addon:SetGroupSecret(replacement))
assert(addon.changes[2].oldChannel == oldChannel and addon.changes[2].newChannel ~= oldChannel)
assert(addon:GetGroupFingerprint() ~= friend:GetGroupFingerprint())
assert(not addon:VerifyGroupMessage("position", payload, tag), "old credential cannot authenticate in new group")
assert(addon:LeaveGroup())
assert(not addon:HasGroup() and addon.db.group.secret == "" and #addon.changes == 3)
assert(addon:LeaveGroup() and #addon.changes == 3, "leaving twice is idempotent")

friend.savedDataReadOnly = true
assert(not friend:SetGroupSecret(replacement) and not friend:LeaveGroup())
assert(friend:GetGroupSecret() == CODE and friend.db.group.secret == CODE and #friend.changes == 0)
friend.savedDataReadOnly = false
friend.initialized = false
assert(not friend:SetGroupSecret(replacement) and not friend:LeaveGroup())
local damaged = newAddon({ group = { secret = "damaged secret" } })
assert(not damaged:HasGroup() and damaged.invalidGroupSecret)
assert(damaged.db.group.secret == "damaged secret", "initialization preserves damaged input")
assert(not damaged:GetGroupStatusText():find("damaged secret", 1, true))
assert(damaged:LeaveGroup() and damaged.db.group.secret == "" and not damaged.invalidGroupSecret)
for _, malformed in ipairs({ {}, { group = false }, { group = { secret = false } } }) do
    local repaired = newAddon(malformed)
    assert(not repaired:HasGroup())
end

-- Friendly keys are short convenience identifiers, not security credentials.
local friendly, friendlyEnvironment = newAddon({ group = { secret = CODE } })
local rngCalls = {}
local function setGenerator(generator)
    friendlyEnvironment.math = setmetatable({
        random = generator or false,
        randomseed = function() error("Never reseed the game's random generator") end,
    }, { __index = math })
end
setGenerator(function(minimum, maximum)
    rngCalls[#rngCalls + 1] = { minimum, maximum }
    return #rngCalls == 1 and 48 or 4827
end)
local generated, generationError = friendly:GenerateGroupKey()
assert(generated == "otter-4827" and generationError == nil, "generate a short word and four digits")
assert(#rngCalls == 2 and rngCalls[1][1] == 1 and rngCalls[1][2] == 64
    and rngCalls[2][1] == 0 and rngCalls[2][2] == 9999, "use bounded ordinary game randomness")
assert(friendly:GetGroupSecret() == CODE and friendly.db.group.secret == CODE
    and #friendly.changes == 0, "generating must not change current group membership")
setGenerator(function(minimum) return minimum end)
assert(friendly:GenerateGroupKey() == "acorn-0000", "preserve leading zeroes")
setGenerator(function(_, maximum) return maximum end)
assert(friendly:GenerateGroupKey() == "willow-9999", "include the final word and number")

-- Missing, failing and malformed randomness returns a generic error, never a
-- partial identifier or a mutation to the player's current group.
for _, broken in ipairs({
    false,
    function() error("private RNG failure detail") end,
    function() return 0 end,
    function() return 65 end,
    function() return 1.5 end,
    function() return "1" end,
    function() return 0 / 0 end,
    function() return math.huge end,
    function(_, maximum) return maximum == 64 and 1 or -1 end,
    function(_, maximum) return maximum == 64 and 1 or 10000 end,
    function(_, maximum) return maximum == 64 and 1 or 1.5 end,
    function(_, maximum) if maximum == 64 then return 1 end error("private RNG failure detail") end,
}) do
    setGenerator(broken)
    local key, problem = friendly:GenerateGroupKey()
    assert(key == nil and type(problem) == "string" and problem:find("group key", 1, true))
    assert(not problem:find("private RNG", 1, true), "do not disclose generator error internals")
    assert(friendly:GetGroupSecret() == CODE and #friendly.changes == 0)
end
setGenerator(function() error("Read-only and loading states must not invoke the generator") end)
friendly.savedDataReadOnly = true
assert(friendly:GenerateGroupKey() == nil)
friendly.savedDataReadOnly, friendly.initialized = false, false
assert(friendly:GenerateGroupKey() == nil)
friendly.initialized = true

assert(friendly:SetGroupSecret("  OTTER-4827\t\n"))
assert(friendly:GetGroupSecret() == "otter-4827" and friendly.db.group.secret == "otter-4827")
assert(friendly:GetGroupFingerprint() == "892fb25f6482a9ae4d88db5a", "independent Python friendly-key identity")
assert(friendly:GetGroupChannelName() == "LITf1088cf5362800f753087303ca83", "independent Python friendly-key channel")
assert(friendly:GetGroupChannelPassword() == "cc5dbee79558d0044df45d4e3139637", "independent Python friendly-key password")
assert(crypto.Hex(friendly:GetGroupAuthenticationKey("position"))
    == "c0143983055ed0d7ad7013a589d9a46d476e7365a3edf4322301a0a3f140714e")
assert(friendly:SignGroupMessage("position", payload)
    == "5c2933b19208be2f8cd997990476367c50a1a26ab0eaf0ea9668517ae6d8ff49")
assert(not friendly:VerifyGroupMessage("position", payload, tag), "legacy tags cannot authenticate in a friendly-key group")
assert(friendly.changes[1].oldChannel == "LIT6f0529e89668b8cbe44179db4331")
assert(friendly:SetGroupSecret("OTTER-4827") and #friendly.changes == 1, "canonical resaving is idempotent")
local matching = newAddon({ group = { secret = "Otter-4827" } })
assert(matching:GetGroupSecret() == "otter-4827", "normalize saved friendly keys during initialization")
assert(matching:GetGroupFingerprint() == friendly:GetGroupFingerprint())
assert(matching:VerifyGroupMessage("position", payload, friendly:SignGroupMessage("position", payload)))
assert(friendly:LeaveGroup() and not friendly:HasGroup(), "friendly groups use the existing leave lifecycle")
for _, valid in ipairs({ "abc", "123", "MY-FRIENDS", "a-b", "0123456789", string.rep("z", 40) }) do
    assert(friendly:SetGroupSecret(valid), "accept letters, digits and single interior hyphens")
end
local savedFriendly = friendly:GetGroupSecret()
local friendlyChanges = #friendly.changes
for _, invalid in ipairs({
    "", "ab", string.rep("a", 41), "-abc", "abc-", "abc--def", "has space", "has\ttab",
    "has\nnewline", "has/slash", "has_underscore", "has.dot", "has|pipe", "café", "lit1-abc", "LIT1-short",
}) do
    local ok, problem = friendly:SetGroupSecret(invalid)
    assert(not ok and type(problem) == "string" and problem:find("group key", 1, true), "reject malformed friendly keys")
    assert(friendly:GetGroupSecret() == savedFriendly and #friendly.changes == friendlyChanges)
end
local damagedLegacy = newAddon({ group = { secret = "lit1-short" } })
assert(not damagedLegacy:HasGroup() and damagedLegacy.invalidGroupSecret, "reserve the complete legacy prefix")
assert(damagedLegacy:GetGroupStatusText():find("group key", 1, true))

-- If this interpreter supports native bitwise syntax, also test WoW's signed
-- bit-library route. The syntax is in a string to remain loadable under Lua 5.1.
local compile = loadstring or load
local nativeChunk = compile("local function signed(x) if x>=2147483648.0 then return x-4294967296.0 else return x end end; "
    .. "return { band = function(a,b) return signed(a) & signed(b) end, bxor = function(a,b) return signed(a) ~ signed(b) end }")
if nativeChunk then
    local nativeAddon, nativeEnvironment = newAddon()
    nativeEnvironment.bit = nativeChunk()
    loadModule("Crypto.lua", nativeAddon, nativeEnvironment)
    verifyCryptoVectors(nativeAddon.Crypto)
end
print("Group crypto vectors, credential derivation, isolation and lifecycle checks passed.")
