local _, addon = ...

-- Retarget the format-40000 RC4 envelope without opening its compressed guide
-- data. RestedXP owns decompression, content checks and native guide parsing.
local Codec = { MAX_DATA = 2 * 1024 * 1024 }
addon.RestedXPCodec = Codec
local MAX_GUIDES, MAX_BLOCKS = 10000, 256
local floor, byte, char, concat = math.floor, string.byte, string.char, table.concat
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local values, xor = {}, {}
for index = 1, #alphabet do values[byte(alphabet, index)] = index - 1 end
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
local function Flush(parts, buffer)
    parts[#parts + 1] = concat(buffer)
    return {}
end
local function Base64Encode(data)
    local parts, buffer = {}, {}
    for index = 1, #data, 3 do
        local a, b, c = byte(data, index, index + 2)
        local value = a * 65536 + (b or 0) * 256 + (c or 0)
        buffer[#buffer + 1] = alphabet:sub(floor(value / 262144) + 1, floor(value / 262144) + 1)
            .. alphabet:sub(floor(value / 4096) % 64 + 1, floor(value / 4096) % 64 + 1)
            .. (b and alphabet:sub(floor(value / 64) % 64 + 1, floor(value / 64) % 64 + 1) or "=")
            .. (c and alphabet:sub(value % 64 + 1, value % 64 + 1) or "=")
        if #buffer == 4096 then buffer = Flush(parts, buffer); Pause() end
    end
    Flush(parts, buffer)
    return concat(parts)
end
local function Base64Decode(data)
    if #data == 0 or #data % 4 ~= 0 then return nil end
    local parts, buffer = {}, {}
    for index = 1, #data, 4 do
        local a, b, c, d = byte(data, index, index + 3)
        a, b = values[a], values[b]
        local cv, dv = values[c], values[d]
        if a == nil or b == nil or (cv == nil and c ~= 61) or (dv == nil and d ~= 61)
            or (c == 61 and d ~= 61) or ((c == 61 or d == 61) and index + 3 ~= #data)
            or (c == 61 and b % 16 ~= 0) or (d == 61 and cv and cv % 4 ~= 0) then return nil end
        local value = a * 262144 + b * 4096 + (cv or 0) * 64 + (dv or 0)
        buffer[#buffer + 1] = char(floor(value / 65536))
            .. (cv and char(floor(value / 256) % 256) or "") .. (dv and char(value % 256) or "")
        if #buffer == 4096 then buffer = Flush(parts, buffer); Pause() end
    end
    Flush(parts, buffer)
    return concat(parts)
end
local function BattleTagKey(value)
    if type(value) ~= "string" or #value > 128 then return nil end
    value = value:match("^%s*(.-)%s*$")
    if not value:match("^[^%s#]+#%d+$") then return nil end
    -- Native Lua lower() operates on bytes, including UTF-8 BattleTags.
    value = value:lower():sub(-16)
    local padded, key = string.rep("\000", 16 - #value) .. value, {}
    for index = 0, 15 do key[index] = byte(padded, index + 1) end
    for index = 0, 15 do
        key[(-index) % 16] = Xor(Xor(key[(15 - index) % 16], key[(13 - index) % 16]),
            Xor(key[(12 - index) % 16], key[(10 - index) % 16]))
    end
    return key
end
local function RC4State(key)
    local state, j = {}, 0
    for index = 0, 255 do state[index] = index end
    for index = 0, 255 do
        j = (j + state[index] + key[index % 16]) % 256
        state[index], state[j] = state[j], state[index]
    end
    return state
end
local function Rekey(data, sourceKey, destinationKey)
    local source, destination = RC4State(sourceKey), RC4State(destinationKey)
    local parts, buffer, i, sj, dj = {}, {}, 0, 0, 0
    for index = 1, #data do
        i = (i + 1) % 256
        sj, dj = (sj + source[i]) % 256, (dj + destination[i]) % 256
        source[i], source[sj] = source[sj], source[i]
        destination[i], destination[dj] = destination[dj], destination[i]
        buffer[#buffer + 1] = char(Xor(Xor(byte(data, index), source[(source[i] + source[sj]) % 256]),
            destination[(destination[i] + destination[dj]) % 256]))
        if #buffer == 4096 then buffer = Flush(parts, buffer); Pause() end
    end
    Flush(parts, buffer)
    return concat(parts)
end
local function Integer(value, maximum)
    if not value or not value:match("^%d+$") or #value > 10 then return nil end
    local number = tonumber(value)
    return number and number <= maximum and number or nil
end
local function ValidChecksum(value)
    local negative = value:sub(1, 1) == "-"
    return Integer(negative and value:sub(2) or value, negative and 2147483648 or 4294967295) ~= nil
end

function Codec.Reencrypt(raw, sourceBattleTag, destinationBattleTag)
    local sourceKey, destinationKey = BattleTagKey(sourceBattleTag), BattleTagKey(destinationBattleTag)
    if not sourceKey then return nil, "Enter the source BattleTag in Name#1234 form." end
    if not destinationKey then return nil, "The destination BattleTag is unavailable or invalid." end
    if type(raw) ~= "string" or #raw == 0 or #raw > Codec.MAX_DATA then
        return nil, "Guide export is empty or exceeds the 2 MiB limit."
    end
    -- WoW text fields can escape a literal pipe as ||. Pipes are framing only
    -- (never Base64 data), so normalize them before splitting the envelope.
    raw = raw:gsub("%s", ""):gsub("|+", "|")
    local countText, body, formatText = raw:match("^(%d+)|(.+)|(%d+)$")
    local count = Integer(countText, MAX_GUIDES)
    if not count or count == 0 or formatText ~= "40000" then
        return nil, "Unsupported or invalid guide export; format 40000 is required."
    end
    local blocks, offset = {}, 1
    while offset <= #body do
        if #blocks >= MAX_BLOCKS then return nil, "Guide export contains too many compressed blocks." end
        local separator = body:find(":", offset, true)
        if not separator or separator - offset > 11 then return nil, "Malformed guide export block." end
        local checksum = body:sub(offset, separator - 1)
        if not ValidChecksum(checksum) then return nil, "Malformed guide export block." end
        local finish = body:find("%", separator + 1, true)
        if not finish then return nil, "Malformed guide export block." end
        local encoded = body:sub(separator + 1, finish - 1)
        local encrypted = Base64Decode(encoded)
        if not encrypted then return nil, "Guide block has invalid Base64 encoding." end
        blocks[#blocks + 1] = checksum .. ":" .. Base64Encode(Rekey(encrypted, sourceKey, destinationKey)) .. "%"
        offset = finish + 1
        Pause()
    end
    if #blocks == 0 then return nil, "Guide export contains no compressed blocks." end
    return countText .. "|" .. concat(blocks) .. "|40000"
end
