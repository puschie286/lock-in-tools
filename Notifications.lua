local _, addon = ...
local AceEvent = LibStub("AceEvent-3.0")
local bus = AceEvent:Embed({})
local PREFIX = "LockInTools:"

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
    bus:SendMessage(PREFIX .. name, ...)
end
