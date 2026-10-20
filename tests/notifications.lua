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
    local first = addon:RegisterNotification("CHAT_CHANGED", function(event, ...)
        calls[#calls + 1] = { listener = "first", event = event, n = select("#", ...), ... }
    end)
    addon:RegisterNotification("CHAT_CHANGED", function() error("expected subscriber failure") end)
    addon:RegisterNotification("CHAT_CHANGED", function(event, ...)
        calls[#calls + 1] = { listener = "second", event = event, n = select("#", ...), ... }
    end)
    addon:Notify("CHAT_CHANGED", token, nil, false, nil)
    assert(#calls == 2 and #errors == 1 and errors[1]:find("expected subscriber failure", 1, true),
        "a failing subscriber cannot prevent other listeners on the same message")
    for _, call in ipairs(calls) do
        assert(call.event == "LockInTools:CHAT_CHANGED" and call.n == 4
            and call[1] == token and call[2] == nil and call[3] == false and call[4] == nil,
            "real message dispatch preserves its namespace and complete argument list")
    end
    first:UnregisterAllMessages()
    addon:Notify("CHAT_CHANGED")
    assert(#calls == 3 and calls[3].listener == "second" and #errors == 2,
        "unregistering one returned owner leaves independent listeners registered")
    local other, otherEnvironment = isolated()
    other:Notify("CHAT_CHANGED", "another addon environment")
    assert(#calls == 3 and otherEnvironment.LibStub ~= environment.LibStub,
        "separate mocked clients do not share real library registries or subscribers")
end

do
    local addon, _, errors = isolated()
    local calls = {}
    for _, name in ipairs({ "CHAT_CHANGED", "DATA_CHANGED" }) do
        addon:RegisterNotification(name, function(event, ...)
            calls[#calls + 1] = { event = event, n = select("#", ...), ... }
        end)
    end
    addon:BeginNotificationBatch()
    addon:Notify("CHAT_CHANGED", "old")
    addon:BeginNotificationBatch()
    addon:Notify("DATA_CHANGED", "old data")
    addon:Notify("CHAT_CHANGED", "latest", nil, false, nil)
    addon:EndNotificationBatch()
    assert(#calls == 0, "an inner batch cannot dispatch notifications before the outer operation finishes")
    addon:Notify("DATA_CHANGED", "latest data")
    addon:EndNotificationBatch()
    assert(#calls == 2 and calls[1].event == "LockInTools:CHAT_CHANGED"
        and calls[1].n == 4 and calls[1][1] == "latest" and calls[1][3] == false
        and calls[2].event == "LockInTools:DATA_CHANGED" and calls[2][1] == "latest data"
        and #errors == 0,
        "nested batches coalesce in first-seen order while retaining the latest complete payload")
end

do
    local addon, environment, errors = isolated()
    addon.initialized, addon.db = true, { group = { secret = "" } }
    for _, file in ipairs({ "Crypto.lua", "Group.lua" }) do
        local chunk = assert(loadfile(file))
        setfenv(chunk, environment)
        chunk("LockInTools", addon)
    end
    addon:InitializeGroup()
    local published = 0
    for _, name in ipairs({ "GROUP_CHANGED", "DATA_CHANGED", "CHAT_CHANGED" }) do
        addon:RegisterNotification(name, function() published = published + 1 end)
    end
    function addon:OnDataGroupChanged() self:Notify("DATA_CHANGED") end
    function addon:OnGroupChanged()
        self:Notify("CHAT_CHANGED")
        error("expected group reset failure")
    end
    local success, problem = pcall(addon.SetGroupSecret, addon, "failure-test-group")
    assert(not success and tostring(problem):find("expected group reset failure", 1, true)
        and published == 0 and #errors == 0,
        "a failed lifecycle reset propagates its error without publishing a partially cleaned group")
    addon:Notify("DATA_CHANGED")
    assert(published == 1, "a failed group reset closes its batch so later notifications still dispatch")
end

do
    local addon, _, messages, _, world = harness.loadAddon(harness.settings(harness.SECRET, true), false)
    world:initialize()
    world:advance(1)
    local oldChat, oldData = addon:GetGroupChannelName(), addon:GetGroupDataChannelName()
    world:completeJoin(oldChat, 3)
    world:completeJoin(oldData, 4)
    assert(addon:IsDataConnected())
    local received = 0
    addon:RegisterDataFeature("echo", function() received = received + 1 end)
    addon.positionState.peers.friend = { name = "Friend", map = 37, x = 0.2, y = 0.8 }
    addon.db.position.peers.friend = { name = "Friend", map = 37, x = 0.2, y = 0.8 }
    addon.rosterState.peers.friend = { name = "Friend", level = 20 }
    addon.rosterState.progress.friend = { level = 20, xpState = "known", xp = 1, xpMax = 10 }
    addon.db.roster.peers.friend = { name = "Friend", level = 20 }
    local notifications, listeners = {}, {}
    for _, name in ipairs({ "GROUP_CHANGED", "CHAT_CHANGED", "DATA_CHANGED", "POSITIONS_CHANGED", "ROSTER_CHANGED" }) do
        listeners[#listeners + 1] = addon:RegisterNotification(name, function(event, ...)
            assert(select("#", ...) == 0, "model invalidations never carry group keys")
            assert(not addon:IsDataConnected() and not addon:SendData("echo", "disconnected send")
                and not addon:ReceiveData("Friend", "1|echo|disconnected receive"),
                "subscribers cannot use the previous group's disconnected transport")
            if addon:IsGroupSwitching() then
                assert(addon:GetGroupChannelName() == oldChat and addon:GetGroupDataChannelName() == oldData
                    and next(addon:GetSharedPositions()) == nil and #addon:GetOverviewPlayers() == 0,
                    "pending views hide old peers and retain the active route until departure finishes")
            else
                assert(next(addon.positionState.peers) == nil and next(addon.db.position.peers) == nil
                    and next(addon.rosterState.peers) == nil and next(addon.rosterState.progress) == nil
                    and next(addon.db.roster.peers) == nil and not world.channels[oldChat:lower()]
                    and not world.channels[oldData:lower()],
                    "completed views observe cleared feature caches and old channel memberships")
            end
            notifications[#notifications + 1] = { event = event, pending = addon:IsGroupSwitching() }
        end)
    end
    assert(addon:SetGroupSecret("notification-friends"))
    assert(#notifications == 1 and notifications[1].event == "LockInTools:GROUP_CHANGED"
        and notifications[1].pending and addon.positionState.peers.friend
        and addon.rosterState.peers.friend and world.channels[oldChat:lower()] and world.channels[oldData:lower()],
        "the pending notification blocks old views before deferring teardown until the current callback returns")
    world:advance(0)
    assert(#notifications > 1 and notifications[#notifications].event == "LockInTools:GROUP_CHANGED"
        and not notifications[#notifications].pending
        and #world.notificationErrors == 0 and received == 0,
        "the completed group notification follows batched cleanup without exposing partial views")
    for _, listener in ipairs(listeners) do listener:UnregisterAllMessages() end
    assert(not harness.contains(messages, harness.SECRET) and not harness.contains(messages, "notification-friends"),
        "notifications never print either group's key")
    assert(world.dataJoinCalls[#world.dataJoinCalls] == addon:GetGroupDataChannelName()
        and not addon:IsDataConnected(), "group replacement waits for the new asynchronous data membership")
    world:completeJoin(addon:GetGroupDataChannelName(), 6)
    assert(addon:IsDataConnected() and addon:SendData("echo", "new connection"),
        "normal sends resume on the new group connection")
end

assert(rawget(_G, "LibStub") == nil, "test library globals stay inside their client environments")
print("PASS: real native/message dispatch, independent owners, failure isolation and ordered group cleanup")
