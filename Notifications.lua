local _, addon = ...
local AceEvent = LibStub("AceEvent-3.0")
local bus = AceEvent:Embed({})
local PREFIX = "LockInTools:"
local depth, pending, order = 0, {}, {}

function addon:RegisterGameEvents(events, callback)
    local listener = AceEvent:Embed({})
    -- Bind here to avoid Lua 5.1's compatibility vararg shadowing CallbackHandler's optional arg.
    local function OnEvent(...) callback(self, ...) end
    for _, event in ipairs(events) do listener:RegisterEvent(event, OnEvent) end
    return listener
end

function addon:RegisterNotification(name, callback)
    -- Separate owners let several views subscribe to the same message.
    local listener = AceEvent:Embed({})
    listener:RegisterMessage(PREFIX .. name, callback)
    return listener
end

function addon:Notify(name, ...)
    if depth > 0 then
        if not pending[name] then order[#order + 1] = name end
        pending[name] = { n = select("#", ...), ... }
        return
    end
    bus:SendMessage(PREFIX .. name, ...)
end

function addon:BeginNotificationBatch()
    depth = depth + 1
end

function addon:EndNotificationBatch(discard)
    assert(depth > 0, "No notification batch is open")
    if discard then pending, order = {}, {} end
    depth = depth - 1
    if depth > 0 then return end
    local messages, names = pending, order
    pending, order = {}, {}
    for _, name in ipairs(names) do
        local args = messages[name]
        bus:SendMessage(PREFIX .. name, unpack(args, 1, args.n))
    end
end
