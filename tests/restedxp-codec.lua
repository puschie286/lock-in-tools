-- Independent RC4/zlib vectors contain only fictional guides. The codec itself
-- loads without compression, hashing, guide parsing or executable guide data.
local function Unexpected() error("The local converter must keep guide content opaque") end
local addon = { Crypto = setmetatable({}, { __index = Unexpected }) }
local env = setmetatable({ LibStub = Unexpected, loadstring = Unexpected, loadfile = Unexpected,
    dofile = Unexpected, RunScript = Unexpected, bit = false, bit32 = false }, { __index = _G })
local chunk = assert(loadfile("RestedXPCodec.lua"))
setfenv(chunk, env)
chunk("LockInTools", addon)
local codec = addon.RestedXPCodec
local source = "3|2264937395:AhsZ1dzvgtAFDamPfcMylA1hPII4MWFIhcYJIwK/5SValxoMF/N2mVQZtb+J4RjOc00SsBSPQtyeElNvpxXNJRIDEUh/Xs9jBRivS0x2hMaNd7qeS+3aXxnFSGfFNAXZPKCffVwy0HeKh1IS4S8h+iB5%1585388498:AhtnUiOsbt7HRJ/glORATDi0jtTia+HgRDXokTLEFx2wWiiLRBVvGU8giEobS3PPQ6CWw9koPuKSLrm5SnTHS3Fzxpgw2StO+Cp2pJkyx5lyxw==%|40000"
local destination = "3|2264937395:78nsYuzn1xwhXfF2HDXjGPieKk3XZfLiJmw3jAwFsRZLRwyScR8dEs1H38D/vfW8nA7rLRxJW1grdbG7mphqH06IWS5I/GDY67ge40oeEdMKpoXfR0FCMJeuwPqJ8sqWWkfEVTwzmy1HBXWhOmaQVAgZ%1585388498:78mS5ROkOxLjFMcZ9RKRwM1LmBsNP3JK55/WPjx+Qy6hij4VIvkEktZ+4jVtF569rONvXtHuJ2YnSVttd/lgcS34jv4He4T1ForHDJ9aUoz1Fg==%|40000"
assert(codec.Reencrypt(source, "Source#1234", "Destination#9876") == destination,
    "conversion matches independently generated encrypted multi-block fixtures exactly")
assert(codec.Reencrypt(destination, "Destination#9876", "Source#1234") == source)
assert(codec.Reencrypt(source, "Source#1234", "Source#1234") == source)
assert(codec.Reencrypt(" \n" .. source:gsub("%%", "%%\r\n") .. "\t", " SOURCE#1234 ", " destination#9876 ") == destination,
    "pasted whitespace and BattleTag ASCII case do not alter the native envelope")
assert(codec.Reencrypt(source:gsub("|", "||"), "Source#1234", "Destination#9876") == destination,
    "WoW-escaped separators convert like plain text")

-- Independent native vectors for opaque binary data, signed/padded checksums,
-- per-block cipher reset, long key truncation and literal UTF-8 BattleTags.
local opaque = "0003|-2030029901:LFxYQ9LpEQmaQAdb0Gekt0/jCpscFWYucHUTOQiri4ajTpWPQbKaNCw=%0000000000:LFxYQ9LpEQmaQAdb0Gekt0/jCpscFWYucHUTOQiri4ajTpWPQbKaNCw=%|40000"
local retargeted = "0003|-2030029901:B15qLBmP+7SURAShSbeV1Z+MD+p6hgrVPNzodW77M40weEHBzCM2qr8=%0000000000:B15qLBmP+7SURAShSbeV1Z+MD+p6hgrVPNzodW77M40weEHBzCM2qr8=%|40000"
assert(codec.Reencrypt(opaque, "VeryLongBattleTagName#123456", "l\195\169a#1234") == retargeted)
assert(codec.Reencrypt(retargeted, "l\195\169a#1234", "VeryLongBattleTagName#123456") == opaque)
local wrong = assert(codec.Reencrypt(source, "Wrong#1234", "Destination#9876"))
assert(wrong ~= destination and codec.Reencrypt(wrong, "Destination#9876", "Wrong#1234") == source,
    "framing cannot authenticate a source BattleTag; native RestedXP validates its decrypted content")

local function Reject(raw, from, to)
    local converted, problem = codec.Reencrypt(raw, from or "Source#1234", to or "Destination#9876")
    assert(converted == nil and type(problem) == "string" and problem ~= "", "Malformed envelope or BattleTag was accepted")
end
for _, raw in ipairs({ "", "0||40000", "10001|1:Zg==%|40000", "1|1:Zg==%|40001",
    "1|1;Zg==%|40000", "1|1:Zg==|40000", "1|1:Zg==%garbage|40000",
    "1|1:Zh==%|40000", "1|1:Zm=v%|40000", "1|4294967296:Zg==%|40000",
    "1|1:%|40000", "1|" .. string.rep("1:Zg==%", 257) .. "|40000" }) do Reject(raw) end
Reject(string.rep("x", codec.MAX_DATA + 1))
Reject("1|" .. string.rep("1", 100000) .. "|40000")
assert(codec.Reencrypt(nil, "Source#1234", "Destination#9876") == nil)
assert(codec.Reencrypt({}, "Source#1234", "Destination#9876") == nil)
for _, tag in ipairs({ "Source#", "Source#12 34", string.rep("a", 129) .. "#1" }) do
    Reject(source, tag, "Destination#9876")
    Reject(source, "Source#1234", tag)
end
assert(codec.Reencrypt(source, nil, "Destination#9876") == nil)
assert(codec.Reencrypt(source, "Source#1234", nil) == nil)

local large = "1|1:" .. string.rep("AAEC", 32768) .. "%|40000"
local result, resumes = nil, 0
local thread = coroutine.create(function() result = assert(codec.Reencrypt(large, "Source#1234", "Destination#9876")) end)
repeat
    resumes = resumes + 1
    local ok, problem = coroutine.resume(thread)
    assert(ok, problem)
    assert(resumes < 1000, "conversion completes with bounded cooperative checkpoints")
until coroutine.status(thread) == "dead"
assert(resumes > 20 and result and #result == #large,
    "large opaque conversions yield while decoding, rekeying and encoding without changing export size")
assert(codec.Reencrypt(result, "Destination#9876", "Source#1234") == large)
print("PASS: local RestedXP envelope re-encryption, opaque bytes, framing limits and cooperative conversion")
