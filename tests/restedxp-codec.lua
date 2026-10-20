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
assert(pack.guides[1].sourceHash and #pack.guides[1].sourceHash == 64)
assert(pack.guides[2].contentHash == "1bc430429bd1535a8ace6c7f94afd50db600162d80f82a17e2a78bd75437863c")
assert(pack.guides[3].contentHash == "bcb59d61521defa0b4506a07d6d5fdac12040787b34cf395989b9f9ecd50bf9f")
assert(codec.Encode(pack, "Destination#9876") == destination)
assert(assert(codec.Decode(destination, "Destination#9876")).data == canonical)
assert(assert(codec.DecodeCanonical(canonical)).hash == expectedHash)
assert(assert(codec.DecodeCanonical(canonical:gsub("2264937395:", "-2030029901:", 1))).hash == expectedHash)
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
Reject(canonical:gsub("2264937395:", "-2147483649:", 1))
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

-- Native CacheGuide writes raw Deflate and an account-specific comment. Its
-- whitespace/comment normalization must not create updates on every import.
local function NativeCache(raw, account)
    raw = raw:gsub("%s-[\r\n]+%s*", "\n")
        :gsub("[\t ][\t ]+", " "):gsub("%-%-[^\n]*", "")
    return (deflate:CompressDeflate("--" .. (account or "123456789") .. "\n" .. raw))
end
local conditional = "\r\n  -- Fictional guide comment\r\n#classic\r\n<< Horde\r\n"
    .. "#group  Synthetic\r\n#name Conditional\r\n#version 3\r\nstep << Mage\r\n"
    .. "  .note   Fictional branch << Troll -- Local comment\r\n\r\n"
local normalized = assert(codec.NormalizeSource(conditional))
assert(not normalized:find("--", 1, true) and normalized:find("<< Horde", 1, true)
    and normalized:find("step << Mage", 1, true) and normalized:find("<< Troll", 1, true))
assert(codec.NormalizeSource(normalized) == normalized)
local cached = NativeCache(conditional)
assert(codec.DecodeCachedSource(cached) == normalized)
assert(codec.DecodeCachedSource(NativeCache(conditional, "987654321")) == normalized)
for _ = 1, 5 do
    cached = NativeCache(assert(deflate:DecompressDeflate(cached)))
    assert(codec.DecodeCachedSource(cached) == normalized, "Native import changed stable source identity")
end
local metadata = assert(codec.SourceMetadata(conditional))
assert(metadata.key == "Synthetic||Conditional" and metadata.enabledFor == "Horde"
    and metadata.version == 3 and metadata.sourceHash == codec.SourceHash(normalized))
local original = assert(codec.DecodeCanonical(Canonical(conditional)))
assert(original.guides[1].sourceHash == metadata.sourceHash
    and original.guides[1].contentHash ~= metadata.sourceHash)
local otherVariant = normalized:gsub("<< Mage", "<< Warrior")
local sources = assert(codec.FromSources({conditional, otherVariant, normalized}))
assert(sources.guideCount == 2 and #sources.guides == 2, "Distinct conditional sources were discarded")
local reordered = assert(codec.FromSources({otherVariant, "--12345\n" .. normalized}))
assert(sources.data == reordered.data and sources.hash == reordered.hash, "Cache order changed pack identity")
local restoredSources = assert(codec.DecodeCanonical(sources.data))
assert(restoredSources.hash == sources.hash)
for index, sourceGuide in ipairs(restoredSources.guides) do
    assert(sourceGuide.contentHash == sourceGuide.sourceHash
        and sourceGuide.sourceHash == sources.guides[index].sourceHash)
end
assert(assert(codec.Decode(assert(codec.Encode(sources, "Player#1234")), "Player#1234")).hash == sources.hash)
for _, sourceGuide in ipairs(sources.guides) do
    assert(sourceGuide.contentHash == sourceGuide.sourceHash)
end
local function RejectSources(list)
    local result, problem = codec.FromSources(list)
    assert(not result and type(problem) == "string")
end
RejectSources({})
RejectSources({false})
RejectSources({"-- Comments only"})
RejectSources({guide .. "\000" .. guide})
RejectSources({"#version 3\nstep\n.note Missing identity"})
local tooMany = {}
for index = 1, 10001 do tooMany[index] = guide end
RejectSources(tooMany)
assert(codec.DecodeCachedSource(cached .. "extra") == nil)
assert(codec.DecodeCachedSource(cached:sub(1, -3)) == nil)
assert(codec.DecodeCachedSource(string.char(255)) == nil)
assert(codec.DecodeCachedSource(cached, 8) == nil)
local rawRepeated = deflate:CompressDeflate(string.rep("x", 20000))
local rawInflated, rawStatus = deflate:DecompressDeflateBounded(rawRepeated, 19999)
assert(rawInflated == nil and rawStatus == -18)
assert(deflate:DecompressDeflateBounded(rawRepeated, 20000) == string.rep("x", 20000))
local rawStored = deflate:CompressDeflate(string.rep("a", 5000), {level = 0})
assert(deflate:DecompressDeflateBounded(rawStored, 4999) == nil)
codec.MAX_INFLATED = #guide - 1
RejectSources({guide})
assert(codec.DecodeCachedSource(NativeCache(guide)) == nil)
codec.MAX_INFLATED = oldLimit
local oldDataLimit = codec.MAX_DATA
codec.MAX_DATA = 40
RejectSources({guide})
codec.MAX_DATA = oldDataLimit

-- Large single guides also cooperate while compression crosses Deflate blocks.
local rebuilt, resumed = nil, 0
local building = coroutine.create(function()
    rebuilt = assert(codec.FromSources({guide .. string.rep(".note Test\n", 8000)}))
end)
while coroutine.status(building) ~= "dead" do
    local success, problem = coroutine.resume(building)
    assert(success, problem)
    resumed = resumed + 1
end
assert(resumed > 10 and assert(codec.DecodeCanonical(rebuilt.data)).hash == rebuilt.hash)

-- Installed sharing transports native cache strings as opaque compressed bytes.
-- The publisher and transfer reader must not inspect, hash or rebuild content.
local oldSHA, oldNormalize = addon.Crypto.SHA256, codec.NormalizeSource
local oldInflate, oldCompress = deflate.DecompressDeflateBounded, deflate.CompressZlibCooperative
local function UnexpectedContentWork() error("Opaque transfer inspected guide content") end
addon.Crypto.SHA256, codec.NormalizeSource = UnexpectedContentWork, UnexpectedContentWork
deflate.DecompressDeflateBounded, deflate.CompressZlibCooperative = UnexpectedContentWork, UnexpectedContentWork
local opaqueBytes = { "Not a Deflate stream\000\255", "Second\r\nopaque cache" }
local opaquePack = assert(codec.FromCachedSources(opaqueBytes))
local opaqueRead = assert(codec.DecodeCachedPack(opaquePack.data))
local expectedGuides = { { id = "z|:guide", version = 2.5 }, { id = "a\000\195\169", version = -1e30 } }
local manifestPack = assert(codec.FromCachedSources(opaqueBytes, expectedGuides))
local manifestRead = assert(codec.DecodeCachedPack(manifestPack.data))
assert(manifestPack.data:sub(1, 6) == "LITC2|" and codec.IsCachedPack(manifestPack.data))
assert(manifestRead.expectedGuides[1].id == expectedGuides[2].id
    and manifestRead.expectedGuides[1].version == expectedGuides[2].version
    and manifestRead.expectedGuides[2].id == expectedGuides[1].id
    and manifestRead.expectedGuides[2].version == expectedGuides[1].version)
assert(manifestRead.cachedSources[1] == opaqueBytes[1] and manifestRead.cachedSources[2] == opaqueBytes[2])
assert(assert(codec.FromCachedSources(opaqueBytes, { expectedGuides[2], expectedGuides[1] })).data == manifestPack.data,
    "Metadata enumeration order changed the manifest framing")
assert(opaqueRead.expectedGuides == nil)
assert(codec.IsCachedPack(opaquePack.data) and not codec.IsCachedPack(canonical))
assert(opaquePack.cacheFormat and opaqueRead.cacheFormat and opaqueRead.format == 40000
    and opaqueRead.guideCount == 2 and opaqueRead.hash == nil and opaqueRead.guides == nil)
for index, compressed in ipairs(opaqueBytes) do
    assert(opaquePack.cachedSources[index] == compressed and opaqueRead.cachedSources[index] == compressed)
end
addon.Crypto.SHA256, codec.NormalizeSource = oldSHA, oldNormalize
deflate.DecompressDeflateBounded, deflate.CompressZlibCooperative = oldInflate, oldCompress

local function RejectCached(data)
    local result, problem = codec.DecodeCachedPack(data)
    assert(not result and type(problem) == "string")
end
RejectCached("")
RejectCached("LITC3|1|Zg==%")
RejectCached("LITC1|0|")
RejectCached("LITC1|10001|Zg==%")
RejectCached("LITC1|1|")
RejectCached("LITC1|2|Zg==%")
RejectCached("LITC1|1|Zg==%Zg==%")
RejectCached("LITC1|1|Zg==")
RejectCached("LITC1|1|%")
RejectCached("LITC1|1|Zh==%")
RejectCached("LITC1|1|Zm9=%")
RejectCached("LITC1|1|Zg==%extra")
RejectCached(string.rep("x", codec.MAX_DATA + 1))
local function WithManifest(raw)
    return "LITC2|1|" .. Base64(raw) .. "|Zg==%"
end
assert(assert(codec.DecodeCachedPack(WithManifest("1|1:a1:1"))).expectedGuides[1].version == 1)
RejectCached("LITC2|1||Zg==%")
RejectCached("LITC2|1|Zh==|Zg==%")
RejectCached(WithManifest("0|"))
RejectCached(WithManifest("10001|"))
RejectCached(WithManifest("1|0:1:1"))
RejectCached(WithManifest("1|4097:" .. string.rep("a", 4097) .. "1:1"))
RejectCached(WithManifest("1|1:a2:+1"))
RejectCached(WithManifest("1|1:a3:NaN"))
RejectCached(WithManifest("1|1:a3:inf"))
RejectCached(WithManifest("1|1:a33:" .. string.rep("1", 33)))
RejectCached(WithManifest("1|1:a1:"))
RejectCached(WithManifest("1|1:a1:1trailing"))
RejectCached(WithManifest("2|1:a1:11:a1:1"))
assert(codec.FromCachedSources({}) == nil and codec.FromCachedSources({ false }) == nil
    and codec.FromCachedSources({ "" }) == nil and codec.FromCachedSources(tooMany) == nil)
assert(codec.FromCachedSources(opaqueBytes, {}) == nil)
assert(codec.FromCachedSources(opaqueBytes, { { id = "", version = 1 } }) == nil)
assert(codec.FromCachedSources(opaqueBytes, { { id = string.rep("a", 4097), version = 1 } }) == nil)
assert(codec.FromCachedSources(opaqueBytes, { { id = "a", version = "1" } }) == nil)
assert(codec.FromCachedSources(opaqueBytes, { { id = "a", version = 0 / 0 } }) == nil)
assert(codec.FromCachedSources(opaqueBytes, { { id = "a", version = math.huge } }) == nil)
assert(codec.FromCachedSources(opaqueBytes, { { id = "a", version = 1 }, { id = "a", version = 1 } }) == nil)
assert(codec.FromCachedSources(opaqueBytes, tooMany) == nil)
codec.MAX_DATA = 20
assert(codec.FromCachedSources(opaqueBytes) == nil)
assert(codec.FromCachedSources(opaqueBytes, expectedGuides) == nil)
RejectCached(opaquePack.data)
codec.MAX_DATA = oldDataLimit

-- Decode native RC4/zlib envelopes separately from the codec's metadata reader.
-- This also verifies conversion of sources the native guide parser must reject.
local function RefXor(a, b)
    local result, place = 0, 1
    for _ = 1, 8 do
        if a % 2 ~= b % 2 then result = result + place end
        a, b, place = math.floor(a / 2), math.floor(b / 2), place * 2
    end
    return result
end
local function RefBase64Decode(encoded)
    local digits, result = {}, {}
    for index = 1, #alphabet do digits[alphabet:sub(index, index)] = index - 1 end
    for index = 1, #encoded, 4 do
        local a, b, c, d = encoded:sub(index, index), encoded:sub(index + 1, index + 1),
            encoded:sub(index + 2, index + 2), encoded:sub(index + 3, index + 3)
        local value = digits[a] * 262144 + digits[b] * 4096 + (digits[c] or 0) * 64 + (digits[d] or 0)
        result[#result + 1] = string.char(math.floor(value / 65536))
            .. (c ~= "=" and string.char(math.floor(value / 256) % 256) or "")
            .. (d ~= "=" and string.char(value % 256) or "")
    end
    return table.concat(result)
end
local function RefDecrypt(compressed, tag)
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
    local i, bytes = 0, {}
    j = 0
    for index = 1, #compressed do
        i = (i + 1) % 256
        j = (j + state[i]) % 256
        state[i], state[j] = state[j], state[i]
        bytes[index] = string.char(RefXor(compressed:byte(index), state[(state[i] + state[j]) % 256]))
    end
    return table.concat(bytes)
end
local function NativePlain(exportText, tag)
    local count, body = exportText:match("^(%d+)|(.+)|40000$")
    assert(count and body)
    local contents = {}
    for checksum, encoded in body:gmatch("(%d+):([^%%]+)%%") do
        local compressed = RefDecrypt(RefBase64Decode(encoded), tag)
        local raw, remaining = deflate:DecompressZlib(compressed)
        assert(raw and remaining == 0 and deflate:Adler32(raw) == tonumber(checksum))
        contents[#contents + 1] = raw
    end
    assert(#contents > 0)
    return table.concat(contents, "\000"), tonumber(count), #contents
end
local referencePlain = deflate:DecompressZlib(pack.blocks[1].compressed) .. "\000"
    .. deflate:DecompressZlib(pack.blocks[2].compressed)
assert(NativePlain(source, "Source#1234") == referencePlain, "Reference native decoder disagrees with independent fixtures")
local exactRaw = "#classic\r\n#group Synthetic\r\n#name Exact cache\r\n#version 3\r\n"
    .. "step << Mage\r\n  .note   Keep spacing -- Keep comment\r\n"
local exactCaches = { (deflate:CompressDeflate("--123456789\n" .. exactRaw)),
    (deflate:CompressDeflate("--987654321\r\n" .. conditional)) }
local exactPack = assert(codec.FromCachedSources(exactCaches))
local nativeExport = assert(codec.EncodeCached(exactPack, "Recipient#9876"))
local rawConverted, convertedCount = NativePlain(nativeExport, "Recipient#9876")
assert(convertedCount == 2 and rawConverted == exactRaw .. "\000" .. conditional,
    "Native conversion changed source bytes beyond the leading account marker")
local manifestedExact = assert(codec.FromCachedSources(exactCaches, expectedGuides))
local manifestedExport = assert(codec.EncodeCached(manifestedExact, "Recipient#9876"))
assert(NativePlain(manifestedExport, "Recipient#9876") == rawConverted,
    "Expected metadata changed native guide source conversion")
assert(codec.EncodeCached(exactPack, "Recipient") == nil and codec.EncodeCached({}, "Recipient#9876") == nil)
assert(codec.EncodeCached(opaquePack, "Recipient#9876") == nil)
local malformedGuide = "No guide metadata\n.note Let the native importer validate this source\n"
local malformedPack = assert(codec.FromCachedSources({ (deflate:CompressDeflate("--123\n" .. malformedGuide)) }))
local malformedExport = assert(codec.EncodeCached(malformedPack, "Recipient#9876"))
assert(NativePlain(malformedExport, "Recipient#9876") == malformedGuide)
assert(codec.Decode(malformedExport, "Recipient#9876") == nil, "Fixture must require native semantic validation")
codec.MAX_INFLATED = #exactRaw - 1
assert(codec.EncodeCached(exactPack, "Recipient#9876") == nil)
codec.MAX_INFLATED = oldLimit
local trailingCache = assert(codec.FromCachedSources({ exactCaches[1] .. "trailing" }))
assert(codec.EncodeCached(trailingCache, "Recipient#9876") == nil)
print("restedxp-codec: passed")
