local _, addon = ...

-- RestedXP format-40000 envelope. Guide source is treated strictly as data;
-- only the installed RestedXP addon parses or executes its guide language.
local Codec = {}
addon.RestedXPCodec = Codec
Codec.MAX_DATA = 2 * 1024 * 1024
Codec.MAX_INFLATED = 16 * 1024 * 1024
local MAX_GUIDES, MAX_BLOCKS = 10000, 256
local floor, byte, char, concat = math.floor, string.byte, string.char, table.concat
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local values = {}
for index = 1, #alphabet do values[byte(alphabet, index)] = index - 1 end
local xor = {}
for a = 0, 15 do
    xor[a] = {}
    for b = 0, 15 do
        local x, y, result, place = a, b, 0, 1
        for _ = 1, 4 do
            if x % 2 ~= y % 2 then result = result + place end
            x, y, place = floor(x / 2), floor(y / 2), place * 2
        end
        xor[a][b] = result
    end
end
local function Xor(a, b)
    return xor[a % 16][b % 16] + 16 * xor[floor(a / 16)][floor(b / 16)]
end
local function Pause()
    if coroutine and coroutine.running() then coroutine.yield() end
end
local function Hash(data)
    return addon.Crypto.Hex(addon.Crypto.SHA256(data, Pause))
end
local function Base64Encode(data)
    local result = {}
    for index = 1, #data, 3 do
        local a, b, c = byte(data, index, index + 2)
        local value = a * 65536 + (b or 0) * 256 + (c or 0)
        result[#result + 1] = alphabet:sub(floor(value / 262144) + 1, floor(value / 262144) + 1)
            .. alphabet:sub(floor(value / 4096) % 64 + 1, floor(value / 4096) % 64 + 1)
            .. (b and alphabet:sub(floor(value / 64) % 64 + 1, floor(value / 64) % 64 + 1) or "=")
            .. (c and alphabet:sub(value % 64 + 1, value % 64 + 1) or "=")
        if index > 1 and index % 12288 == 1 then Pause() end
    end
    return concat(result)
end
local function Base64Decode(data)
    if #data == 0 or #data % 4 ~= 0 then return nil end
    local result = {}
    for index = 1, #data, 4 do
        local a, b, c, d = byte(data, index, index + 3)
        a, b = values[a], values[b]
        local cv, dv = values[c], values[d]
        if a == nil or b == nil or (cv == nil and c ~= 61) or (dv == nil and d ~= 61)
            or (c == 61 and d ~= 61) or ((c == 61 or d == 61) and index + 3 ~= #data)
            or (c == 61 and b % 16 ~= 0) or (d == 61 and cv and cv % 4 ~= 0) then
            return nil
        end
        local value = a * 262144 + b * 4096 + (cv or 0) * 64 + (dv or 0)
        result[#result + 1] = char(floor(value / 65536))
            .. (cv and char(floor(value / 256) % 256) or "")
            .. (dv and char(value % 256) or "")
        if index > 1 and index % 16384 == 1 then Pause() end
    end
    return concat(result)
end

local function BattleTagKey(value)
    if type(value) ~= "string" or #value > 128 then return nil end
    value = value:match("^%s*(.-)%s*$")
    if not value:match("^[^%s#]+#%d+$") then return nil end
    -- Match RestedXP's byte-oriented native Lua lower(), preserving UTF-8 bytes.
    value = value:lower()
    if #value > 16 then value = value:sub(-16) end
    local key, padding = {}, 16 - #value
    for index = 0, 15 do
        local source = (index - padding) % 16
        key[index] = source < #value and byte(value, source + 1) or 0
    end
    for index = 0, 15 do
        key[(-index) % 16] = Xor(Xor(key[(15 - index) % 16], key[(13 - index) % 16]),
            Xor(key[(12 - index) % 16], key[(10 - index) % 16]))
    end
    return key
end
local function Crypt(data, key)
    local state, result, j = {}, {}, 0
    for index = 0, 255 do state[index] = index end
    for index = 0, 255 do
        j = (j + state[index] + key[index % 16]) % 256
        state[index], state[j] = state[j], state[index]
    end
    local i = 0
    j = 0
    for index = 1, #data do
        i = (i + 1) % 256
        j = (j + state[i]) % 256
        state[i], state[j] = state[j], state[i]
        result[index] = char(Xor(byte(data, index), state[(state[i] + state[j]) % 256]))
        if index % 4096 == 0 then Pause() end
    end
    return concat(result)
end
local function Adler32(data)
    local a, b = 1, 0
    for index = 1, #data do
        a = (a + byte(data, index)) % 65521
        b = (b + a) % 65521
        if index % 16384 == 0 then Pause() end
    end
    return b * 65536 + a
end
local function Integer(value, maximum)
    if not value or not value:match("^%d+$") or #value > 10 then return nil end
    local number = tonumber(value)
    if not number or number > maximum then return nil end
    return number
end
local function Checksum(value)
    local negative = value and value:sub(1, 1) == "-"
    local number = Integer(negative and value:sub(2) or value, negative and 2147483648 or 4294967295)
    if number == nil then return nil end
    return negative and (-number) % 4294967296 or number
end
local games = {classic = true, tbc = true, wotlk = true, cata = true, mop = true,
    df = true, retail = true, forever = true}
local function Metadata(raw)
    local guide = { version = 0, subgroup = "", contentHash = Hash(raw) }
    for line in raw:gmatch("[^\r\n]+") do
        if line:match("^%s*step%s*$") or line:match("^%s*step%s+") then break end
        local field, value = line:match("^%s*#([%a]+)%s*(.-)%s*$")
        if field and games[field] then guide[field] = true end
        if field == "group" or field == "subgroup" or field == "name" then
            value = value:gsub("%s+<<.*$", "")
            if value ~= "" and (guide[field] == nil or guide[field] == "") then guide[field] = value end
        elseif field == "version" then
            local version = tonumber(value:match("^(%S+)"))
            if version and version > -math.huge and version < math.huge then guide.version = version end
        end
        guide.enabledFor = guide.enabledFor or line:match("^%s*<<%s*(.-)%s*$")
    end
    if not guide.group or not guide.name or guide.group:find("|", 1, true)
        or guide.subgroup:find("|", 1, true) or guide.name:find("|", 1, true) then
        return nil, "A guide has missing or invalid identity metadata."
    end
    guide.key = guide.group .. "|" .. guide.subgroup .. "|" .. guide.name
    return guide
end
local function Decode(raw, key)
    if type(raw) ~= "string" or #raw == 0 or #raw > Codec.MAX_DATA then
        return nil, "Guide export is empty or exceeds the 2 MiB limit."
    end
    raw = raw:gsub("%s", "")
    local countText, body, formatText = raw:match("^(%d+)|(.+)|(%d+)$")
    local count, format = Integer(countText, MAX_GUIDES), Integer(formatText, 40000)
    if not count or count == 0 or format ~= 40000 then
        return nil, "Unsupported or invalid guide export; format 40000 is required."
    end
    local inflater = LibStub and LibStub("LITLibDeflate", true)
    if not inflater or type(inflater.DecompressZlibBounded) ~= "function" then
        return nil, "The bundled guide decompression library is unavailable."
    end
    local blocks, guides, canonical, plain, offset, inflated = {}, {}, {}, {}, 1, 0
    while offset <= #body do
        if #blocks >= MAX_BLOCKS then return nil, "Guide export contains too many compressed blocks." end
        local start, finish, checksumText, mode, encoded = body:find("(%-?%d+)([^%d])([A-Za-z0-9+/=]+)%%", offset)
        if start ~= offset or mode ~= ":" then return nil, "Unsupported or malformed guide block." end
        local checksum = Checksum(checksumText)
        if checksum == nil then return nil, "Guide block checksum is invalid." end
        local compressed = Base64Decode(encoded)
        if not compressed then return nil, "Guide block has invalid Base64 encoding." end
        if key then compressed = Crypt(compressed, key) end
        local content, remaining = inflater:DecompressZlibBounded(compressed, Codec.MAX_INFLATED - inflated, Pause)
        if not content or remaining ~= 0 then
            return nil, "Cannot decompress guide data; check the source BattleTag or export."
        end
        inflated = inflated + #content
        if #content == 0 or inflated > Codec.MAX_INFLATED then return nil, "Guide export exceeds the decompressed size limit." end
        if Adler32(content) ~= checksum then return nil, "Guide block checksum does not match its content." end
        -- Empty entries are rejected, rather than silently changing the count.
        local entryStart = 1
        while entryStart <= #content do
            local delimiter = content:find("\000", entryStart, true)
            local entry = content:sub(entryStart, delimiter and delimiter - 1 or #content)
            if not entry:find("%S") then return nil, "Guide export contains an empty entry." end
            local guide, problem = Metadata(entry)
            if not guide then return nil, problem end
            guides[#guides + 1] = guide
            if #guides > count then return nil, "Guide export count does not match its content." end
            if not delimiter then break end
            entryStart = delimiter + 1
            if entryStart > #content then return nil, "Guide export contains an empty trailing entry." end
        end
        blocks[#blocks + 1] = {checksum = checksum, compressed = compressed}
        canonical[#canonical + 1] = tostring(checksum) .. ":" .. Base64Encode(compressed) .. "%"
        -- Length framing distinguishes block boundaries and embedded NUL bytes.
        plain[#plain + 1] = tostring(#content) .. ":" .. content
        offset = finish + 1
        if #blocks % 8 == 0 then Pause() end
    end
    if #guides ~= count or #blocks == 0 then return nil, "Guide export count does not match its content." end
    local data = tostring(count) .. "|" .. concat(canonical) .. "|" .. tostring(format)
    if #data > Codec.MAX_DATA then return nil, "Guide export exceeds the 2 MiB limit." end
    return {data = data, hash = Hash("LIT-RXP-1\000" .. concat(plain)), format = format,
        guides = guides, guideCount = #guides, blocks = blocks}
end

function Codec.Decode(raw, sourceBattleTag)
    local key = BattleTagKey(sourceBattleTag)
    if not key then return nil, "Enter the source BattleTag in Name#1234 form." end
    return Decode(raw, key)
end
function Codec.DecodeCanonical(data)
    return Decode(data)
end
function Codec.Encode(pack, destinationBattleTag)
    local key = BattleTagKey(destinationBattleTag)
    if not key then return nil, "The destination BattleTag is unavailable or invalid." end
    if type(pack) ~= "table" or type(pack.data) ~= "string" then return nil, "Guide package is invalid." end
    -- Revalidate persisted/transferred input; never trust cached block tables.
    local verified, problem = Decode(pack.data)
    if not verified then return nil, problem end
    local encoded = {}
    for index, block in ipairs(verified.blocks) do
        encoded[index] = tostring(block.checksum) .. ":" .. Base64Encode(Crypt(block.compressed, key)) .. "%"
    end
    return tostring(verified.guideCount) .. "|" .. concat(encoded) .. "|" .. tostring(verified.format)
end
