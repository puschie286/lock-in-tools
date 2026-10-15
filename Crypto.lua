local _, addon = ...

-- Small, dependency-free SHA-256, HMAC-SHA-256 and HKDF-SHA-256 implementation.
-- Algorithms: FIPS 180-4, RFC 2104 and RFC 5869. Tests include published vectors.
-- This supplies hashing/authentication, not encryption or random generation.
local Crypto = {}
addon.Crypto = Crypto

local floor, char, byte = math.floor, string.char, string.byte
local concat, rep = table.concat, string.rep
local UINT32 = 4294967296.0
local native = bit or bit32
local band, bxor

if native then
    band = function(a, b) return native.band(a, b) % UINT32 end
    bxor = function(a, b) return native.bxor(a, b) % UINT32 end
else
    -- Exact-integer fallback for offline tests and clients without bit libraries.
    -- Work in four-bit chunks; Lua 5.1 doubles represent every intermediate.
    local andTable, xorTable = {}, {}
    for a = 0, 15 do
        andTable[a], xorTable[a] = {}, {}
        for b = 0, 15 do
            local x, y, intersection, difference, place = a, b, 0, 0, 1
            for _ = 1, 4 do
                local xb, yb = x % 2, y % 2
                if xb == 1 and yb == 1 then intersection = intersection + place end
                if xb ~= yb then difference = difference + place end
                x, y, place = floor(x / 2), floor(y / 2), place * 2
            end
            andTable[a][b], xorTable[a][b] = intersection, difference
        end
    end
    local function operate(a, b, lookup)
        local result, place = 0.0, 1.0
        for _ = 1, 8 do
            result = result + lookup[a % 16][b % 16] * place
            a, b, place = floor(a / 16), floor(b / 16), place * 16
        end
        return result
    end
    band = function(a, b) return operate(a, b, andTable) end
    bxor = function(a, b) return operate(a, b, xorTable) end
end

local function shiftRight(value, bits) return floor(value / 2 ^ bits) end
local function rotateRight(value, bits)
    return shiftRight(value, bits) + (value % 2 ^ bits) * 2 ^ (32 - bits)
end
local function xor3(a, b, c) return bxor(bxor(a, b), c) end
local function wordBytes(value)
    return char(floor(value / 16777216) % 256, floor(value / 65536) % 256,
        floor(value / 256) % 256, value % 256)
end

local ROUND = {
    1116352408.0, 1899447441.0, 3049323471.0, 3921009573.0, 961987163.0, 1508970993.0, 2453635748.0, 2870763221.0,
    3624381080.0, 310598401.0, 607225278.0, 1426881987.0, 1925078388.0, 2162078206.0, 2614888103.0, 3248222580.0,
    3835390401.0, 4022224774.0, 264347078.0, 604807628.0, 770255983.0, 1249150122.0, 1555081692.0, 1996064986.0,
    2554220882.0, 2821834349.0, 2952996808.0, 3210313671.0, 3336571891.0, 3584528711.0, 113926993.0, 338241895.0,
    666307205.0, 773529912.0, 1294757372.0, 1396182291.0, 1695183700.0, 1986661051.0, 2177026350.0, 2456956037.0,
    2730485921.0, 2820302411.0, 3259730800.0, 3345764771.0, 3516065817.0, 3600352804.0, 4094571909.0, 275423344.0,
    430227734.0, 506948616.0, 659060556.0, 883997877.0, 958139571.0, 1322822218.0, 1537002063.0, 1747873779.0,
    1955562222.0, 2024104815.0, 2227730452.0, 2361852424.0, 2428436474.0, 2756734187.0, 3204031479.0, 3329325298.0,
}

function Crypto.SHA256(message)
    assert(type(message) == "string", "SHA256 requires a string")
    local length = #message
    local bitLength = length * 8.0
    message = message .. char(128) .. rep(char(0), (55 - length) % 64)
        .. wordBytes(floor(bitLength / UINT32)) .. wordBytes(bitLength % UINT32)
    local h0, h1, h2, h3 = 1779033703.0, 3144134277.0, 1013904242.0, 2773480762.0
    local h4, h5, h6, h7 = 1359893119.0, 2600822924.0, 528734635.0, 1541459225.0
    local w = {}
    for offset = 1, #message, 64 do
        for i = 0, 15 do
            local a, b, c, d = byte(message, offset + i * 4, offset + i * 4 + 3)
            w[i] = a * 16777216.0 + b * 65536.0 + c * 256.0 + d
        end
        for i = 16, 63 do
            local a, b = w[i - 15], w[i - 2]
            local s0 = xor3(rotateRight(a, 7), rotateRight(a, 18), shiftRight(a, 3))
            local s1 = xor3(rotateRight(b, 17), rotateRight(b, 19), shiftRight(b, 10))
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % UINT32
        end
        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
        for i = 0, 63 do
            local sigma1 = xor3(rotateRight(e, 6), rotateRight(e, 11), rotateRight(e, 25))
            local choose = bxor(band(e, f), band(UINT32 - 1 - e, g))
            local t1 = (h + sigma1 + choose + ROUND[i + 1] + w[i]) % UINT32
            local sigma0 = xor3(rotateRight(a, 2), rotateRight(a, 13), rotateRight(a, 22))
            local majority = xor3(band(a, b), band(a, c), band(b, c))
            local t2 = (sigma0 + majority) % UINT32
            h, g, f, e, d, c, b, a = g, f, e, (d + t1) % UINT32, c, b, a, (t1 + t2) % UINT32
        end
        h0, h1, h2, h3 = (h0 + a) % UINT32, (h1 + b) % UINT32, (h2 + c) % UINT32, (h3 + d) % UINT32
        h4, h5, h6, h7 = (h4 + e) % UINT32, (h5 + f) % UINT32, (h6 + g) % UINT32, (h7 + h) % UINT32
    end
    return wordBytes(h0) .. wordBytes(h1) .. wordBytes(h2) .. wordBytes(h3)
        .. wordBytes(h4) .. wordBytes(h5) .. wordBytes(h6) .. wordBytes(h7)
end

function Crypto.Hex(value)
    assert(type(value) == "string", "Hex requires a string")
    return (value:gsub(".", function(character) return string.format("%02x", byte(character)) end))
end

function Crypto.Unhex(value)
    if type(value) ~= "string" or #value % 2 ~= 0 or value:find("[^%da-fA-F]") then
        return nil
    end
    return (value:gsub("..", function(pair) return char(tonumber(pair, 16)) end))
end

function Crypto.HMACSHA256(key, message)
    assert(type(key) == "string" and type(message) == "string", "HMAC requires string arguments")
    if #key > 64 then key = Crypto.SHA256(key) end
    key = key .. rep(char(0), 64 - #key)
    local inner, outer = {}, {}
    for i = 1, 64 do
        inner[i], outer[i] = char(bxor(byte(key, i), 0x36)), char(bxor(byte(key, i), 0x5c))
    end
    return Crypto.SHA256(concat(outer) .. Crypto.SHA256(concat(inner) .. message))
end

function Crypto.HKDFSHA256(inputKey, salt, info, length)
    assert(type(inputKey) == "string" and type(salt) == "string" and type(info) == "string",
        "HKDF requires string arguments")
    assert(type(length) == "number" and length >= 0 and length <= 255 * 32 and length == floor(length),
        "HKDF output length is invalid")
    local extracted = Crypto.HMACSHA256(salt, inputKey)
    local result, previous = {}, ""
    for index = 1, math.ceil(length / 32) do
        previous = Crypto.HMACSHA256(extracted, previous .. info .. char(index))
        result[index] = previous
    end
    return concat(result):sub(1, length)
end

-- Avoid an early return on the first differing byte. Lua/VM execution does not
-- offer a guarantee of constant-time behavior, so do not claim one.
function Crypto.Equal(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    local difference = #a == #b and 0 or 1
    for index = 1, math.max(#a, #b) do
        difference = difference + bxor(byte(a, index) or 0, byte(b, index) or 0)
    end
    return difference == 0
end
