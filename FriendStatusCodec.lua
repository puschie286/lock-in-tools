local _, addon = ...

local OPCODE, MAX_FRAME_BYTES = "S", 255
local MAX_STAMP, MAX_REVISION = 9999999999, 999999999
local MAX_INTEGER, MAX_FIELD_ID = 9007199254740991, 65535
local MAX_SESSION_LENGTH, MAX_SESSION_MILLIS = 32, 2147483646
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

-- The alphabet carries five data bits per character. Its upper half marks a
-- continuation. The field mask's slots are permanent; new IDs use extensions.
local SLOT_IDS = { 1, 2, 3, 4, 10, 11, 12 }
local SLOT_BITS, DIGITS = {}, {}
for index, id in ipairs(SLOT_IDS) do SLOT_BITS[id] = 2 ^ (index - 1) end
for index = 1, #ALPHABET do DIGITS[ALPHABET:sub(index, index)] = index - 1 end

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function Integer(value, minimum, maximum)
    return not IsSecret(value) and type(value) == "number" and value >= minimum and value <= maximum and value % 1 == 0
end

local function Session(value)
    return not IsSecret(value) and type(value) == "string" and #value <= MAX_SESSION_LENGTH
        and value:match("^[a-zA-Z0-9_-]+$")
end

local function FieldValue(value)
    return not IsSecret(value) and type(value) == "string" and #value <= MAX_FRAME_BYTES
        and not value:find("[^ -~]")
end

local function WriteNumber(parts, value)
    repeat
        local digit = value % 32
        value = math.floor(value / 32)
        local index = digit + (value > 0 and 33 or 1)
        parts[#parts + 1] = ALPHABET:sub(index, index)
    until value == 0
end

local function ReadNumber(reader, maximum)
    local value, place = 0, 1
    repeat
        local digit = DIGITS[reader.frame:sub(reader.index, reader.index)]
        if not digit then return nil end
        reader.index = reader.index + 1
        local payload = digit % 32
        -- Check the contribution before multiplying to stay in the exact
        -- integer range of Lua 5.1 doubles, even with malformed input.
        if payload > math.floor((maximum - value) / place) then return nil end
        value = value + payload * place
        if digit < 32 then
            if place == 1 or payload > 0 then return value end
            return nil
        end
        place = place * 32
    until place > maximum
end

local function WriteString(parts, value)
    WriteNumber(parts, #value)
    parts[#parts + 1] = value
end

local function ReadString(reader, maximum)
    local length = ReadNumber(reader, maximum)
    if not length or length > #reader.frame - reader.index + 1 then return nil end
    local value = reader.frame:sub(reader.index, reader.index + length - 1)
    reader.index = reader.index + length
    return value
end

local function Decimal(value, maximum)
    if #value > 16 or not value:match("^%d+$") or (#value > 1 and value:sub(1, 1) == "0") then return nil end
    local number = tonumber(value)
    if Integer(number, 0, maximum) and string.format("%.0f", number) == value then return number end
end

local function Hex(value, maximum)
    if #value > 9 then return nil end
    -- Split the only supported wider hexadecimal value before decoding on
    -- runtimes where tonumber(text, 16) saturates at 32 bits.
    local number = tonumber(value:sub(-8), 16)
    if #value == 9 then number = number + tonumber(value:sub(1, 1), 16) * 4294967296 end
    if Integer(number, 0, maximum) and (#value == 1 or value:sub(1, 1) ~= "0") then return number end
end

local function WriteHex(value)
    -- Format the upper and lower pieces independently on 32-bit Lua runtimes.
    local high = math.floor(value / 4294967296)
    if high == 0 then return string.format("%x", value) end
    return string.format("%x%08x", high, value % 4294967296)
end

local function SessionParts(session)
    local epoch, millis, sequence = session:match("^([0-9a-f]+)%-([0-9a-f]+)%-(%d+)$")
    if not epoch then return nil end
    epoch, millis, sequence = Hex(epoch, MAX_STAMP), Hex(millis, MAX_SESSION_MILLIS), Decimal(sequence, MAX_INTEGER)
    if epoch and millis and sequence and sequence >= 1 then return epoch, millis, sequence end
end

-- Zero introduces a printable ASCII literal. Keep the even length tag so
-- existing ASCII frames retain their wire representation.
local function WriteValue(parts, value)
    local number = Decimal(value, MAX_INTEGER - 1)
    if number then
        WriteNumber(parts, number + 1)
    else
        WriteNumber(parts, 0)
        WriteNumber(parts, #value * 2)
        parts[#parts + 1] = value
    end
end

local function ReadValue(reader)
    local number = ReadNumber(reader, MAX_INTEGER)
    if not number then return nil end
    if number > 0 then return string.format("%.0f", number - 1) end
    local tag = ReadNumber(reader, 2 * MAX_FRAME_BYTES)
    if not tag or tag % 2 ~= 0 then return nil end
    local length = tag / 2
    if length > #reader.frame - reader.index + 1 then return nil end
    local value = reader.frame:sub(reader.index, reader.index + length - 1)
    reader.index = reader.index + length
    if not Decimal(value, MAX_INTEGER - 1) then return value end
end

function addon:EncodeFriendsStatus(message)
    if IsSecret(message) or type(message) ~= "table" or not Session(message.session)
        or not Integer(message.stamp, 0, MAX_STAMP) or not Integer(message.revision, 1, MAX_REVISION)
        or IsSecret(message.fields) or type(message.fields) ~= "table" then return nil end
    local fields, mask, extra, count = message.fields, 0, {}, 0
    for id, value in pairs(fields) do
        count = count + 1
        if count > MAX_FRAME_BYTES or not Integer(id, 1, MAX_FIELD_ID) or not FieldValue(value) then return nil end
        if SLOT_BITS[id] then mask = mask + SLOT_BITS[id]
        else extra[#extra + 1] = id end
    end
    table.sort(extra)

    -- After the opcode, the header's low flags select a literal or generated
    -- session and an optional tail of ascending extension ID/value pairs.
    local epoch, millis, sequence = SessionParts(message.session)
    local parts = { OPCODE }
    WriteNumber(parts, (epoch and 0 or 1) + (#extra > 0 and 2 or 0))
    if epoch then
        WriteNumber(parts, epoch)
        WriteNumber(parts, millis)
        WriteNumber(parts, sequence)
        local delta = message.stamp - epoch
        WriteNumber(parts, delta >= 0 and 2 * delta or -2 * delta - 1)
    else
        WriteString(parts, message.session)
        WriteNumber(parts, message.stamp)
    end
    WriteNumber(parts, message.revision)
    WriteNumber(parts, mask)
    for _, id in ipairs(SLOT_IDS) do
        if fields[id] ~= nil then WriteValue(parts, fields[id]) end
    end
    for _, id in ipairs(extra) do
        WriteNumber(parts, id)
        WriteValue(parts, fields[id])
    end
    local frame = table.concat(parts)
    if #frame <= MAX_FRAME_BYTES then return frame end
end

function addon:DecodeFriendsStatus(frame)
    if IsSecret(frame) or type(frame) ~= "string" or #frame > MAX_FRAME_BYTES
        or frame:sub(1, 1) ~= OPCODE or frame:find("[^ -~]") then return nil end
    local reader = { frame = frame, index = 2 }
    local flags = ReadNumber(reader, 3)
    if not flags then return nil end
    local session, stamp
    if flags % 2 == 0 then
        local epoch = ReadNumber(reader, MAX_STAMP)
        local millis = ReadNumber(reader, MAX_SESSION_MILLIS)
        local sequence = ReadNumber(reader, MAX_INTEGER)
        local delta = ReadNumber(reader, 2 * MAX_STAMP)
        if not epoch or not millis or not sequence or sequence < 1 or not delta then return nil end
        stamp = epoch + (delta % 2 == 0 and delta / 2 or -(delta + 1) / 2)
        session = WriteHex(epoch) .. "-" .. WriteHex(millis) .. "-" .. string.format("%.0f", sequence)
    else
        session = ReadString(reader, MAX_SESSION_LENGTH)
        stamp = ReadNumber(reader, MAX_STAMP)
        if not session or SessionParts(session) then return nil end
    end
    local revision = ReadNumber(reader, MAX_REVISION)
    local mask = ReadNumber(reader, 127)
    if not Session(session) or not Integer(stamp, 0, MAX_STAMP) or not revision or revision < 1 or not mask then return nil end

    local fields = {}
    for _, id in ipairs(SLOT_IDS) do
        if mask % 2 == 1 then
            local value = ReadValue(reader)
            if value == nil then return nil end
            fields[id] = value
        end
        mask = math.floor(mask / 2)
    end
    if flags >= 2 then
        local previous = 0
        repeat
            local id = ReadNumber(reader, MAX_FIELD_ID)
            if not id or id <= previous or SLOT_BITS[id] then return nil end
            local value = ReadValue(reader)
            if value == nil then return nil end
            fields[id], previous = value, id
        until reader.index > #frame
    end
    if reader.index ~= #frame + 1 then return nil end
    return { session = session, stamp = stamp, revision = revision, fields = fields }
end
