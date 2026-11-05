-- Exercise the real AceEvent/CallbackHandler dispatcher and addon batching.
local loadNotifications = dofile("tests/support/notifications.lua")
local harness = dofile("tests/support/addon.lua")

local function isolated()
    local addon, environment = {}, setmetatable({}, { __index = _G })
    local errors = loadNotifications(addon, environment, true)
    return addon, environment, errors
end

do
    local addon, environment, errors = isolated()
    local calls, token = {}, {}
    local first = addon:RegisterGameEvents({ "TEST_SHARED", "TEST_OTHER" }, function(self, event, ...)
        assert(self == addon, "native events bind addon self without CallbackHandler's optional argument")
        calls[#calls + 1] = { listener = "first", event = event, n = select("#", ...), ... }
    end)
    local second = addon:RegisterGameEvents({ "TEST_SHARED" }, function(self, event, ...)
        assert(self == addon)
        calls[#calls + 1] = { listener = "second", event = event, n = select("#", ...), ... }
    end)
    local frame = environment.LibStub("AceEvent-3.0").frame
    assert(first ~= second and frame.events.TEST_SHARED and frame.events.TEST_OTHER,
        "independent owners register their native events on the actual shared AceEvent frame")
    frame.onEvent(frame, "TEST_SHARED", token, nil, false, nil)
    assert(#calls == 2 and #errors == 0)
    for _, call in ipairs(calls) do
        assert(call.event == "TEST_SHARED" and call.n == 4 and call[1] == token
            and call[2] == nil and call[3] == false and call[4] == nil,
            "native event dispatch preserves the event and complete argument list")
    end
    first:UnregisterEvent("TEST_SHARED")
    frame.onEvent(frame, "TEST_SHARED")
    assert(#calls == 3 and calls[3].listener == "second" and frame.events.TEST_SHARED,
        "unregistering one owner preserves other subscribers to the same native event")
    second:UnregisterAllEvents()
    assert(not frame.events.TEST_SHARED and frame.events.TEST_OTHER,
        "native registration ends only when its final owner unregisters")
    frame.onEvent(frame, "TEST_OTHER")
    assert(#calls == 4 and calls[4].listener == "first" and calls[4].event == "TEST_OTHER",
        "unregistering a single event preserves the owner's other native events")
    local survived = 0
    addon:RegisterGameEvents({ "TEST_FAILURE" }, function() error("expected native event failure") end)
    addon:RegisterGameEvents({ "TEST_FAILURE" }, function() survived = survived + 1 end)
    frame.onEvent(frame, "TEST_FAILURE")
    assert(survived == 1 and #errors == 1 and errors[1]:find("expected native event failure", 1, true),
        "a failing native event subscriber cannot stop independent owners")
end

do
    local addon, environment = {}, setmetatable({}, { __index = _G })
    local errors = loadNotifications(addon, environment)
    local survived = 0
    addon:RegisterGameEvents({ "TEST_FAILURE" }, function() error("expected strict fixture failure") end)
    addon:RegisterGameEvents({ "TEST_FAILURE" }, function() survived = survived + 1 end)
    local frame = environment.LibStub("AceEvent-3.0").frame
    local ok, problem = pcall(frame.onEvent, frame, "TEST_FAILURE")
    assert(not ok and survived == 1 and #errors == 1
        and tostring(problem):find("expected strict fixture failure", 1, true),
        "normal fixtures surface isolated native handler errors after all owners finish dispatching")
end

do
    local addon, environment, errors = isolated()
    local calls, token = {}, {}
    local first = addon:RegisterNotification("DATA_CHANGED", function(event, ...)
        calls[#calls + 1] = { listener = "first", event = event, n = select("#", ...), ... }
    end)
    addon:RegisterNotification("DATA_CHANGED", function() error("expected subscriber failure") end)
    addon:RegisterNotification("DATA_CHANGED", function(event, ...)
        calls[#calls + 1] = { listener = "second", event = event, n = select("#", ...), ... }
    end)
    addon:Notify("DATA_CHANGED", token, nil, false, nil)
    assert(#calls == 2 and #errors == 1 and errors[1]:find("expected subscriber failure", 1, true),
        "a failing subscriber cannot prevent other listeners on the same message")
    for _, call in ipairs(calls) do
        assert(call.event == "LockInTools:DATA_CHANGED" and call.n == 4
            and call[1] == token and call[2] == nil and call[3] == false and call[4] == nil,
            "real message dispatch preserves its namespace and complete argument list")
    end
    first:UnregisterAllMessages()
    addon:Notify("DATA_CHANGED")
    assert(#calls == 3 and calls[3].listener == "second" and #errors == 2,
        "unregistering one returned owner leaves independent listeners registered")
    local other, otherEnvironment = isolated()
    other:Notify("DATA_CHANGED", "another addon environment")
    assert(#calls == 3 and otherEnvironment.LibStub ~= environment.LibStub,
        "separate mocked clients do not share real library registries or subscribers")
end

-- Subscribers see a disconnected native transport before sending is possible.
do
    local addon, _, _, _, world = harness.loadAddon(harness.settings(), false)
    world.guild = true
    world:initialize()
    local received, notices = 0, 0
    assert(addon:RegisterDataFeature("echo", function() received = received + 1 end))
    assert(addon:IsDataConnected())
    addon:RegisterNotification("DATA_CHANGED", function()
        notices = notices + 1
        assert(not addon:IsDataConnected() and not addon:SendData("echo", "disconnected"))
        assert(not addon:OnDataEvent("CHAT_MSG_ADDON", addon:GetDataPrefix(), "1|echo|blocked", "GUILD", "Friend"))
    end)
    world.guild = false
    world.fire("PLAYER_GUILD_UPDATE")
    assert(notices > 0 and received == 0 and #world.notificationErrors == 0)
end

assert(rawget(_G, "LibStub") == nil, "test library globals stay inside their client environments")
print("PASS: real native/message dispatch, independent owners and failure isolation")