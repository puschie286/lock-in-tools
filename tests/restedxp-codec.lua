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
for _, pasted in ipairs({ source:gsub("|", "||"), source:gsub("|", "||||"),
    source:gsub("^(%d+)|", "%1||"), (source:gsub("|40000$", "||40000")) }) do
    local converted, problem = codec.Reencrypt(pasted, "Source#1234", "Destination#9876")
    assert(converted == destination, "WoW-escaped export separators must convert like plain text: " .. tostring(problem))
end

local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function RefBase64(data)
    local bits, result = "", {}
    for index = 1, #data do
        local value = data:byte(index)
        for place = 7, 0, -1 do bits = bits .. math.floor(value / 2 ^ place) % 2 end
    end
    local original = #bits
    bits = bits .. string.rep("0", (6 - #bits % 6) % 6)
    for index = 1, #bits, 6 do
        local digit = tonumber(bits:sub(index, index + 5), 2) + 1
        result[#result + 1] = alphabet:sub(digit, digit)
    end
    return table.concat(result) .. string.rep("=", (3 - original / 8 % 3) % 3)
end
local function RefXor(a, b)
    local result, place = 0, 1
    for _ = 1, 8 do
        if a % 2 ~= b % 2 then result = result + place end
        a, b, place = math.floor(a / 2), math.floor(b / 2), place * 2
    end
    return result
end
local function RefCrypt(data, tag)
    tag = tag:lower():sub(-16)
    local padded, key, state, j = string.rep("\000", 16 - #tag) .. tag, {}, {}, 0
    for index = 0, 15 do key[index] = padded:byte(index + 1) end
    for index = 0, 15 do
        key[(-index) % 16] = RefXor(RefXor(key[(15 - index) % 16], key[(13 - index) % 16]),
            RefXor(key[(12 - index) % 16], key[(10 - index) % 16]))
    end
    for index = 0, 255 do state[index] = index end
    for index = 0, 255 do
        j = (j + state[index] + key[index % 16]) % 256
        state[index], state[j] = state[j], state[index]
    end
    local i, result = 0, {}
    j = 0
    for index = 1, #data do
        i = (i + 1) % 256
        j = (j + state[i]) % 256
        state[i], state[j] = state[j], state[i]
        result[index] = string.char(RefXor(data:byte(index), state[(state[i] + state[j]) % 256]))
    end
    return table.concat(result)
end
local bytes = {}
for index = 0, 255 do bytes[#bytes + 1] = string.char(index) end
local opaque = table.concat(bytes) .. "--123456789\nerror('guide data must not execute')\000not a zlib stream"
local function ReferenceExport(tag)
    local encoded = RefBase64(RefCrypt(opaque, tag))
    return "0003|-2030029901:" .. encoded .. "%0000000000:" .. encoded .. "%|40000"
end
local cases = {
    { "Source#1234", "Recipient#9876" },
    { "VeryLongBattleTagName#123456", "AnotherLongBattleTag#999999" },
    { "L\195\137A#5678", "l\195\169a#1234" },
}
for _, tags in ipairs(cases) do
    local original, expected = ReferenceExport(tags[1]), ReferenceExport(tags[2])
    assert(codec.Reencrypt(original, tags[1], tags[2]) == expected,
        "independent native byte keys preserve arbitrary compressed bytes and reset RC4 per block")
    assert(codec.Reencrypt(expected, tags[2], tags[1]) == original,
        "counts, signed checksums, zero padding and block boundaries survive conversion exactly")
end
local wrong = assert(codec.Reencrypt(source, "Wrong#1234", "Destination#9876"))
assert(wrong ~= destination and codec.Reencrypt(wrong, "Destination#9876", "Wrong#1234") == source,
    "framing cannot authenticate a source BattleTag; native RestedXP validates its decrypted content")

local function Reject(raw, from, to)
    local converted, problem = codec.Reencrypt(raw, from or "Source#1234", to or "Destination#9876")
    assert(converted == nil and type(problem) == "string" and problem ~= "", "Malformed envelope or BattleTag was accepted")
end
for _, raw in ipairs({ "", " ", "0||40000", "0|1:Zg==%|40000", "10001|1:Zg==%|40000",
    "-1|1:Zg==%|40000", "1|1:Zg==%|40001", "1|1:Zg==%", "1|1;Zg==%|40000",
    "1|1:Zg==|40000", "1|1:Zg==%garbage|40000", "1|1:Zg==%%|40000",
    "1|1:Zh==%|40000", "1|1:Zm9=%|40000", "1|1:=m9v%|40000", "1|1:Zm=v%|40000",
    "1|1:Zm9v=%|40000", "1|4294967296:Zg==%|40000", "1|-2147483649:Zg==%|40000",
    "1|1:%|40000", "1|" .. string.rep("1:Zg==%", 257) .. "|40000" }) do Reject(raw) end
Reject(string.rep("x", codec.MAX_DATA + 1))
Reject("1|" .. string.rep("1", 100000) .. "|40000")
assert(codec.Reencrypt(nil, "Source#1234", "Destination#9876") == nil)
assert(codec.Reencrypt({}, "Source#1234", "Destination#9876") == nil)
for _, tag in ipairs({ "", "Source", "Source#", "Source#12 34", "#1234", "A#1#2", string.rep("a", 129) .. "#1" }) do
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
for field in pairs(codec) do assert(field == "MAX_DATA" or field == "Reencrypt", "Obsolete sharing or source-parsing API remains") end
print("PASS: local RestedXP envelope re-encryption, opaque bytes, framing limits and cooperative conversion")
