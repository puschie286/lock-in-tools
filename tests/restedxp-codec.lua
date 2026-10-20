-- Independent zlib/RC4 reference fixtures contain only fictional test guides.
-- Expected strings and hashes were generated with Python 3 hashlib/zlib and
-- a separate byte-oriented implementation of the documented key schedule.
local addon = {}
local env = setmetatable({bit = false, bit32 = false}, {__index = _G})
local function Load(path)
    local chunk = assert(loadfile(path))
    setfenv(chunk, env)
    chunk("LockInTools", addon)
end
Load("Libs/LibStub/LibStub.lua")
Load("Libs/LibDeflate/LibDeflate.lua")
Load("Crypto.lua")
Load("RestedXPCodec.lua")
local codec, deflate = addon.RestedXPCodec, env.LibStub("LITLibDeflate")
local source = "3|2264937395:AhsZ1dzvgtAFDamPfcMylA1hPII4MWFIhcYJIwK/5SValxoMF/N2mVQZtb+J4RjOc00SsBSPQtyeElNvpxXNJRIDEUh/Xs9jBRivS0x2hMaNd7qeS+3aXxnFSGfFNAXZPKCffVwy0HeKh1IS4S8h+iB5%1585388498:AhtnUiOsbt7HRJ/glORATDi0jtTia+HgRDXokTLEFx2wWiiLRBVvGU8giEobS3PPQ6CWw9koPuKSLrm5SnTHS3Fzxpgw2StO+Cp2pJkyx5lyxw==%|40000"
local destination = "3|2264937395:78nsYuzn1xwhXfF2HDXjGPieKk3XZfLiJmw3jAwFsRZLRwyScR8dEs1H38D/vfW8nA7rLRxJW1grdbG7mphqH06IWS5I/GDY67ge40oeEdMKpoXfR0FCMJeuwPqJ8sqWWkfEVTwzmy1HBXWhOmaQVAgZ%1585388498:78mS5ROkOxLjFMcZ9RKRwM1LmBsNP3JK55/WPjx+Qy6hij4VIvkEktZ+4jVtF569rONvXtHuJ2YnSVttd/lgcS34jv4He4T1ForHDJ9aUoz1Fg==%|40000"
local canonical = "3|2264937395:eJxTTs5JLC7OTOZSTi/KLy1Q8PEMUQiuzCvJSC0BCRaXJkHEQ1KLS7iU8xJzUxUMdU0V3DKLQPyy1KLizPw8BXOu4pLUAi699PySfAVDHSDkYlDGbzLYqODU5Py8FIQ5hkZQgxKTk1MLShQMuQCHADOz%1585388498:eJwtyTEKwCAMBdA9pwi49xiFQqfWC4gGDdgo+h16+y5963NDELSSy6Otzufh+X4NRaCRr/8sPMK+6Eg0IZ02axDeNUKbhcqQCc5Lk9AHXn8b0g==%|40000"
local otherCompression = "3|2264937395:eAEBoABf/yNjbGFzc2ljCiNncm91cCBMSVQgU3ludGhldGljCiNzdWJncm91cCBUZXN0CiNuYW1lIDEtNSBGaXJzdAojdmVyc2lvbiA3CnN0ZXAKLmdvdG8gMSwxLDEKACNjbGFzc2ljCiNncm91cCBMSVQgU3ludGhldGljCiNuYW1lIFNlY29uZAojdmVyc2lvbiAxMgpzdGVwCi5hY2NlcHQgMQqHADOz%1585388498:eAEBUACv/yNyZXRhaWwKI2dyb3VwIExJVCBTeW50aGV0aWMgUmV0YWlsCiNuYW1lIFRoaXJkCnN0ZXAKLm5vdGUgRmljdGlvbmFsIHRlc3QgZ3VpZGUKXn8b0g==%|40000"
local expectedHash = "6c0efe3a1317d4021e7e7ae6e7866fe4b6271b968b74d4e1dd5971442b2d822b"
local function Reject(raw, tag)
    local pack, problem
    if tag then pack, problem = codec.Decode(raw, tag) else pack, problem = codec.DecodeCanonical(raw) end
    assert(pack == nil and type(problem) == "string" and problem ~= "", "Malformed export was accepted")
end

local pack = assert(codec.Decode(source, "Source#1234"))
assert(pack.data == canonical and pack.hash == expectedHash and pack.format == 40000 and pack.guideCount == 3)
assert(#pack.guides == 3 and #pack.blocks == 2)
assert(pack.guides[1].key == "LIT Synthetic|Test|1-5 First" and pack.guides[1].version == 7)
assert(pack.guides[1].classic and pack.guides[3].retail and pack.guides[3].version == 0)
assert(pack.guides[1].contentHash == "f83129ac0ae706e90fc44b5c8573b3dd43944e2d982b7a419e7a555e39d10498")
assert(pack.guides[2].contentHash == "1bc430429bd1535a8ace6c7f94afd50db600162d80f82a17e2a78bd75437863c")
assert(pack.guides[3].contentHash == "bcb59d61521defa0b4506a07d6d5fdac12040787b34cf395989b9f9ecd50bf9f")
assert(codec.Encode(pack, "Destination#9876") == destination)
assert(assert(codec.Decode(destination, "Destination#9876")).data == canonical)
assert(assert(codec.DecodeCanonical(canonical)).hash == expectedHash)
assert(assert(codec.DecodeCanonical(otherCompression)).hash == expectedHash, "Compression level changed content identity")
assert(assert(codec.Decode(" \n" .. source .. "\r\n", "  SOURCE#1234  ")).data == canonical)
Reject(source, "Wrong#1234")
Reject(source, "Source")
Reject(source, "Source#")
Reject(source, "Source#12 34")
Reject("", "Source#1234")
Reject("0||40000")
Reject(canonical:gsub("^3|", "2|"))
Reject(canonical:gsub("^3|", "4|"))
Reject(canonical:gsub("|40000$", "|40001"))
Reject(canonical:gsub("|40000$", ""))
Reject(canonical:gsub("2264937395:", "2264937394:", 1))
Reject(canonical:gsub("2264937395:", "4294967296:", 1))
Reject(canonical:gsub("2264937395:", "-2264937395:", 1))
Reject(canonical:gsub(":", ";", 1))
Reject(canonical .. "garbage")
Reject(canonical:gsub("|40000$", "garbage|40000"))
Reject("1|1:Zg==garbage%|40000")
Reject("1|1:Zh==%|40000") -- Nonzero Base64 padding bits.
Reject("1|1:Zm9=%|40000")
Reject("1|1:=m9v%|40000")
Reject("1|1:Zm=v%|40000")
Reject("1|1:Zm9v=%|40000")
Reject(string.rep("x", codec.MAX_DATA + 1))
local failed, reason = codec.Encode({data = "invalid"}, "Destination#9876")
assert(failed == nil and reason)

local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function Base64(bytes)
    local result = {}
    for index = 1, #bytes, 3 do
        local a, b, c = string.byte(bytes, index, index + 2)
        local bits = a * 65536 + (b or 0) * 256 + (c or 0)
        local function Digit(shift) local digit = math.floor(bits / shift) % 64 + 1; return alphabet:sub(digit, digit) end
        result[#result + 1] = Digit(262144) .. Digit(4096) .. (b and Digit(64) or "=") .. (c and Digit(1) or "=")
    end
    return table.concat(result)
end
local function Canonical(content, count, appended)
    return (count or 1) .. "|" .. string.format("%.0f", deflate:Adler32(content)) .. ":"
        .. Base64(deflate:CompressZlib(content) .. (appended or "")) .. "%|40000"
end
local guide = "#classic\n#group Synthetic\n#name Test\n#version 3\nstep\n.note Fictional\n"
Reject(Canonical(guide, 1, "trailing bytes"))
Reject(Canonical(guide .. "\000", 1))
Reject(Canonical("\000" .. guide, 2))
Reject(Canonical(guide .. "\000\000" .. guide, 2))
Reject(Canonical("#version 1\nstep\n.note Missing identity"))
Reject(Canonical(""))

-- Byte-preserving Unicode round trips and identity changes use only synthetic
-- text. Native Lua lower() leaves non-ASCII UTF-8 bytes intact, like RestedXP.
local unicode = guide:gsub("#name Test", "#name T\195\169st")
local unicodePack = assert(codec.DecodeCanonical(Canonical(unicode)))
local export = assert(codec.Encode(unicodePack, "l\195\169a#5678"))
assert(assert(codec.Decode(export, "l\195\169a#5678")).data == unicodePack.data)
local changed = assert(codec.DecodeCanonical(Canonical(guide:gsub("Fictional", "Changed"))))
assert(changed.hash ~= assert(codec.DecodeCanonical(Canonical(guide))).hash)

-- Bound enforcement happens inside the private inflater before output exceeds
-- its budget, including repeated runs, stored blocks, and cumulative blocks.
local repeated = deflate:CompressZlib(string.rep("x", 20000))
local inflated, status = deflate:DecompressZlibBounded(repeated, 19999)
assert(inflated == nil and status == -18)
assert(deflate:DecompressZlibBounded(repeated, 20000) == string.rep("x", 20000))
local stored = deflate:CompressZlib(string.rep("a", 5000), {level = 0})
assert(deflate:DecompressZlibBounded(stored, 4999) == nil)
local oldLimit = codec.MAX_INFLATED
codec.MAX_INFLATED = 10
Reject(canonical)
codec.MAX_INFLATED = oldLimit

-- Jobs cooperate across frames without pcall crossing a Lua 5.1 yield.
local large = assert(codec.DecodeCanonical(Canonical(guide .. string.rep(".note Test\n", 1800))))
local progress, completed = 0, nil
local thread = coroutine.create(function() completed = assert(codec.Encode(large, "Player#1234")) end)
while coroutine.status(thread) ~= "dead" do
    local success, problem = coroutine.resume(thread)
    assert(success, problem)
    if coroutine.status(thread) ~= "dead" then progress = progress + 1 end
end
assert(progress > 0 and completed)
assert(assert(codec.Decode(completed, "Player#1234")).hash == large.hash)
print("restedxp-codec: passed")
