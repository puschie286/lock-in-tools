-- Shared feature routing uses mocked native guild and friend addon messages.
local loadNotifications = dofile("tests/support/notifications.lua")
local helpers = dofile("tests/support/helpers.lua")
local loadModule, copy, equal = helpers.loadModule, helpers.copy, helpers.equal

local function newAddon(saved, readOnly, native)
    native = native or {}
    local world = {
        now = 0, epoch = 2000000000, timers = {}, sent = {}, messages = {}, frames = {},
        nativeSends = {}, prefixCalls = {},
        sendResult = 0, sendCalls = 0, sendAttempts = {},
        guild = native.guild ~= false, party = native.party == true, raid = native.raid == true,
        friends = native.friends or {}, groupMembers = native.groupMembers or {},
    }
    world.sent = world.nativeSends
    -- Most fixtures pin the legacy envelope. Dedicated compact cases register both formats.
    if not native.compact then world.prefixResults = { LITG = 2 } end
    local environment = setmetatable({
        GetTime = function() return world.now end,
        GetServerTime = function() return world.epoch + math.floor(world.now) end,
        GetNormalizedRealmName = function() return "TestRealm" end,
        IsInGuild = function() return world.guild end,
        IsInGroup = function() return world.party or world.raid end,
        IsInRaid = function() return world.raid end,
        UnitFullName = function(unit)
            if unit == "player" then return native.playerName or "Self", "Test Realm" end
            local member = world.groupMembers[tonumber(unit:match("%d+$"))]
            if member then return member.name, member.realm end
        end,
        GetNumSubgroupMembers = function() return world.party and #world.groupMembers or 0 end,
        GetNumGroupMembers = function() return world.raid and #world.groupMembers or 0 end,
        JoinTemporaryChannel = function() error("Native data must never join a custom channel") end,
        LeaveChannelByName = function() error("Native data must never leave a custom channel") end,
        CreateFrame = function(kind)
            assert(kind == "Frame")
            local frame = { events = {} }
            function frame:RegisterEvent(event) self.events[event] = true end
            function frame:UnregisterEvent(event) self.events[event] = nil end
            function frame:SetScript(script, callback) assert(script == "OnEvent"); self.callback = callback end
            world.frames[#world.frames + 1] = frame
            return frame
        end,
        C_Timer = { NewTimer = function(delay, callback)
            local timer = { at = world.now + delay, callback = callback }
            function timer:Cancel() self.cancelled = true end
            world.timers[#world.timers + 1] = timer
            return timer
        end },
    }, { __index = _G })
    environment._G = environment
    environment.C_Timer.After = environment.C_Timer.NewTimer
    environment.Enum = {
        RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1, InvalidPrefix = 2 },
        SendAddonMessageResult = { Success = 0, NotInGuild = 10, AddOnMessageLockdown = 11 },
    }
    local function send(prefix, message, distribution, target)
        world.sendCalls = world.sendCalls + 1
        local packet = { prefix = prefix, message = message, distribution = distribution, target = target, at = world.now }
        world.sendAttempts[#world.sendAttempts + 1] = packet
        if world.sendThrows or (world.routeThrows and world.routeThrows[distribution])
            or (world.prefixSendThrows and world.prefixSendThrows[prefix]) then
            error(world.sendError or "Native send unavailable")
        end
        world.nativeSends[#world.nativeSends + 1] = packet
        local result = world.prefixSendResults and world.prefixSendResults[prefix]
        if result == nil then result = world.routeResults and world.routeResults[distribution] end
        if result ~= nil then return result end
        return world.sendResult
    end
    environment.C_ChatInfo = {
        RegisterAddonMessagePrefix = function(prefix)
            world.prefixCalls[#world.prefixCalls + 1] = prefix
            if world.prefixThrows then error("Prefix registration unavailable") end
            return world.prefixResults and world.prefixResults[prefix] or world.prefixResult or 0
        end,
        SendAddonMessage = function(prefix, message, distribution, target)
            if distribution == "WHISPER" then
                assert(type(target) == "string" and target ~= "", "Addon whispers target one character")
            else
                assert(distribution == "GUILD", "Shared data broadcasts only through guild")
                assert(target == nil, "Native broadcast routes have no channel target")
            end
            return send(prefix, message, distribution, target)
        end,
    }
    environment.C_BattleNet = { SendGameData = function(target, prefix, message)
        assert(type(target) == "number", "Battle.net messages target a game account ID")
        return send(prefix, message, "BATTLENET", target)
    end }
    local addon = { db = saved or { schemaVersion = 4 }, initialized = true, ready = false,
        savedDataReadOnly = readOnly }
    function addon:Print(message) world.messages[#world.messages + 1] = message end
    world.notificationErrors = loadNotifications(addon, environment)
    function addon:RefreshOptions() end
    for _, file in ipairs({ "DataChannel.lua", "Data.lua", "FriendStatusCodec.lua", "DataStatus.lua" }) do
        loadModule(file, addon, environment)
    end
    function addon:GetDataFriends() return world.friends end
    function addon:FindDataFriend(sender)
        if type(sender) ~= "string" then return end
        for id, friend in pairs(world.friends) do
            if sender == friend.name or sender == friend.whisper or sender == id then
                return friend, id
            end
        end
    end
    if native.configure then native.configure(environment, world) end
    addon:InitializeData()
    world.environment, world.addon = environment, addon
    function world:fire(event, ...)
        for _, frame in ipairs(self.frames) do
            if frame.events[event] then frame.callback(frame, event, ...) end
        end
    end
    function world:login()
        addon.ready = true
        addon:OnDataLogin()
    end
    function world:incoming(message, sender, metadata)
        metadata = metadata or {}
        return self:fire("CHAT_MSG_ADDON", metadata.prefix or addon:GetDataPrefix(), message,
            metadata.distribution or "GUILD", sender)
    end
    function world:incomingFriend(message, sender, prefix)
        prefix = prefix or addon:GetFriendsDataPrefix()
        if type(sender) == "number" then
            self:fire("BN_CHAT_MSG_ADDON", prefix, message, "WHISPER", sender)
        else
            self:incoming(message, sender, { distribution = "WHISPER", prefix = prefix })
        end
    end
    function world:connect(accepted)
        self.sendResult, self.sendThrows = accepted == false and 11 or 0, accepted == "throw"
        if self.previousMembership then
            self.party, self.raid, self.guild = unpack(self.previousMembership)
            self.previousMembership = nil
        end
        if not addon.dataState.nativeStarted then self:login()
        else self:fire("PLAYER_GUILD_UPDATE", "player") end
    end
    function world:disconnect()
        self.previousMembership = { self.party, self.raid, self.guild }
        self.party, self.raid, self.guild = false, false, false
        self:fire("PLAYER_GUILD_UPDATE", "player")
    end
    function addon:ReceiveData(sender, message, distribution)
        return self:OnDataEvent("CHAT_MSG_ADDON", self:GetDataPrefix(), message, distribution or "GUILD", sender)
    end
    function world:activeTimers(includeRegistration)
        local count = 0
        for _, timer in ipairs(self.timers) do
            if not timer.cancelled and (includeRegistration or timer ~= addon.dataState.timer) then count = count + 1 end
        end
        return count
    end
    function world:advance(seconds)
        local target, callbacks = self.now + seconds, 0
        while true do
            local nextIndex, nextTimer
            for index, entry in ipairs(self.timers) do
                if not entry.cancelled and entry.at <= target
                    and (not nextTimer or entry.at < nextTimer.at) then nextIndex, nextTimer = index, entry end
            end
            if not nextTimer then break end
            table.remove(self.timers, nextIndex)
            self.now, callbacks = nextTimer.at, callbacks + 1
            assert(callbacks < 200, "Shared data must not create an unbounded timer loop")
            nextTimer.callback(nextTimer)
        end
        self.now = target
    end
    return addon, world
end

-- Features share one envelope and prefix while keeping their handlers independent.
local addon, world = newAddon()
local database = copy(addon.db)
local incoming, connectionChanges = {}, {}
assert(addon:GetDataPrefix() == "LockInToolsData")
assert(addon:RegisterDataFeature("echo", function(sender, payload)
    incoming[#incoming + 1] = { sender = sender, payload = payload }
end, function(connected) connectionChanges[#connectionChanges + 1] = connected end))
assert(#connectionChanges == 1 and connectionChanges[1] == false)
assert(not addon:IsDataConnected() and not addon:SendData("echo", "before login"))
addon.ready = true
assert(not addon:SendData("echo", "without membership"))
assert(not addon:ReceiveData("Friend", "1|echo|before connection"))
world:connect()
assert(addon:IsDataConnected() and connectionChanges[#connectionChanges] == true)
assert(addon:SendData("echo", "a|b||c"))
assert(#world.sent == 1 and world.sent[1].prefix == "LockInToolsData" and world.sent[1].message == "1|echo|a|b||c")
assert(addon:ReceiveData("Friend-Test Realm", world.sent[1].message))
assert(#incoming == 1 and incoming[1].sender == "Friend-Test Realm" and incoming[1].payload == "a|b||c",
    "Route only the envelope and preserve the actual sender and complete feature payload")
local other = 0
assert(addon:RegisterDataFeature("other-feature_1", function(sender, payload)
    assert(sender == "Other" and payload == "separate")
    other = other + 1
    return true
end))
assert(addon:ReceiveData("Other", "1|other-feature_1|separate"))
assert(other == 1 and #incoming == 1)
assert(not addon:RegisterDataFeature("echo", function() error("Duplicate replaced the original") end))
assert(addon:ReceiveData("Friend", "1|echo|original handler"))
assert(#incoming == 2)

-- Validate routing identifiers and the native 255-byte message budget.
for _, feature in ipairs({ "", "Upper", "with.dot", "bad|name", "_start", string.rep("a", 33) }) do
    assert(not addon:RegisterDataFeature(feature, function() end))
end
assert(not addon:RegisterDataFeature("missing_handler", nil))
assert(not addon:RegisterDataFeature("invalid_notice", function() end, false))
assert(addon:RegisterDataFeature(string.rep("a", 32), function() end))
local maximumPayload = string.rep("x", 255 - #"1|echo|")
assert(addon:SendData("echo", maximumPayload) and #world.sent[#world.sent].message == 255)
assert(not addon:SendData("echo", maximumPayload .. "x"))
assert(addon:ReceiveData("Friend", "1|echo|" .. maximumPayload))
local receivedBefore = #incoming
for _, message in ipairs({
    "2|echo|wrong version", "1|unknown|missing handler", "1|echo", "1||missing feature",
    "1|Upper|bad identifier", "echo|missing version", "1|Q", "1|Q|", "1|R", "1|R|",
    "1|Q|echo|request|streaming feature", "1|R|echo|request|self-testrealm|streaming feature",
}) do
    assert(not addon:ReceiveData("Friend", message))
end
world:incoming("1|echo|unrelated", "Friend", { prefix = "OTHER" })
world:incoming("1|echo|unrelated", "Friend", { distribution = "WHISPER" })
assert(#incoming == receivedBefore)
assert(not addon:SendData("unregistered", "payload") and not addon:SendData("echo", false))
assert(not addon:SendData("echo", "native\000separator"))
addon.ready = false
assert(not addon:IsDataConnected() and not addon:SendData("echo", "not ready")
    and not addon:ReceiveData("Friend", "1|echo|not ready"))
addon.ready = true

-- Feature acceptance and connection callbacks cannot break neighboring features.
assert(addon:RegisterDataFeature("declined", function() return false end))
assert(addon:RegisterDataFeature("broken", function() error("Feature error") end))
assert(not addon:ReceiveData("Friend", "1|declined|payload"))
assert(not addon:ReceiveData("Friend", "1|broken|payload"))
assert(addon:ReceiveData("Friend", "1|echo|still working"))
local notified = {}
assert(addon:RegisterDataFeature("bad_notice", function() end, function() error("Notice error") end))
assert(addon:RegisterDataFeature("good_notice", function() end, function(connected)
    notified[#notified + 1] = connected
end))
assert(notified[#notified] == true, "A late subscriber receives the current connection state")
local previousNotices = #connectionChanges
world:disconnect()
world:connect()
assert(#connectionChanges == previousNotices + 2 and notified[#notified] == true,
    "A native reconnect notifies features of departure and connection")
world:disconnect()
assert(not addon:IsDataConnected() and notified[#notified] == false)
assert(not addon:SendData("echo", "disconnected") and not addon:ReceiveData("Friend", "1|echo|disconnected"))

-- Failed native sends never queue payloads for a later connection.
world:connect(false)
assert(not addon:SendData("echo", "failed payload"))
world:connect("throw")
assert(not addon:SendData("echo", "raised payload"))
local attempts = #world.sent
world:connect()
assert(#world.sent == attempts, "Reconnecting must not flush failed or disconnected messages")
assert(addon:SendData("echo", "current payload") and #world.sent == attempts + 1)
assert(world.sent[#world.sent].message == "1|echo|current payload")
assert(equal(addon.db, database), "The communication helper must not persist its runtime state")

-- Newer saved profiles remain untouched and cannot send or receive.
do
    local saved = { schemaVersion = 99, custom = { untouched = true },
        data = { channels = { party = false, future = "preserved" } } }
    local original = copy(saved)
    local peer = { id = "bob-fern", name = "Bob-Fern", displayName = "Bob Fern", gameAccountID = 42 }
    local current, clock = newAddon(saved, true, { guild = true, friends = { [peer.id] = peer } })
    current:RegisterDataFeature("echo", function() error("Read-only dispatch") end)
    clock:connect()
    assert(not current:IsDataConnected() and not current:SendData("echo", "payload")
        and not current:ReceiveData("Friend", "1|echo|payload", "GUILD"))
    assert(not current:SetDataChannelEnabled("guild", true) and not current:SetDataChannelEnabled("friends", true))
    clock:incomingFriend("1|H", 42)
    clock:advance(30)
    assert(equal(saved, original) and #clock.sent == 0 and #clock.prefixCalls == 0)
end

-- Real channel fan-out: every client sees the request and response broadcasts, including its own echoes.
local function newRequestBus(beforeConnect)
    local bus = { clients = {}, queue = {}, delivered = 0 }
    function bus:add(name, now)
        local current, clock = newAddon(nil, false, { playerName = name })
        local client = { addon = current, world = clock, name = name, requests = {}, responses = {} }
        bus.clients[#bus.clients + 1] = client
        assert(current:RegisterDataRequest("snapshot", function(sender, payload)
            client.requests[#client.requests + 1] = { sender = sender, payload = payload }
            return name .. "|" .. payload
        end, function(sender, payload)
            client.responses[#client.responses + 1] = { sender = sender, payload = payload }
        end))
        local nativeSend = clock.environment.C_ChatInfo.SendAddonMessage
        clock.environment.C_ChatInfo.SendAddonMessage = function(prefix, message, distribution, target)
            local result = nativeSend(prefix, message, distribution, target)
            if result == 0 then
                bus.queue[#bus.queue + 1] = { sender = name .. "-TestRealm", message = message,
                    distribution = distribution }
            end
            return result
        end
        if beforeConnect then beforeConnect(client) end
        clock:login()
        return client
    end
    function bus:pump()
        while #self.queue > 0 do
            local packet = table.remove(self.queue, 1)
            self.delivered = self.delivered + 1
            assert(self.delivered < 100, "A snapshot must not trigger response/request loops")
            for _, client in ipairs(self.clients) do
                if client.addon.dataState.routes[packet.distribution] then
                    client.world:incoming(packet.message, packet.sender, { distribution = packet.distribution })
                end
            end
        end
    end
    for _, name in ipairs({ "Alice", "Bob", "Carol" }) do bus:add(name) end
    return bus
end

do
    local bus = newRequestBus()
    local alice, bob, carol = unpack(bus.clients)
    local accepted, aliceID = alice.addon:RequestData("snapshot", "a|b||c")
    local bobAccepted, bobID = bob.addon:RequestData("snapshot", "bob")
    assert(accepted and bobAccepted and aliceID == bobID,
        "Different clients may independently generate the same request identifier")
    bus:pump()
    assert(#alice.requests == 1 and #bob.requests == 1 and #carol.requests == 2,
        "Each peer answers each request once and ignores its own echo")
    assert(#alice.responses == 2 and #bob.responses == 2 and #carol.responses == 0,
        "Only the original requester receives answers, even when another pending request has the same ID")
    assert(alice.responses[1].payload == "Bob|a|b||c" and alice.responses[2].payload == "Carol|a|b||c",
        "Snapshot framing preserves the whole payload, including pipes")
    local sent = #alice.world.nativeSends + #bob.world.nativeSends + #carol.world.nativeSends
    assert(sent == 6, "Two requests produce exactly four peer responses without extra announcements")
    local request = alice.world.nativeSends[1].message
    bob.world:incoming(request, "ALICE-Test Realm", { id = 7 })
    local response = bob.world.nativeSends[2].message
    alice.world:incoming(response, "BOB-Test Realm", { id = 7 })
    bus:pump()
    assert(#bob.requests == 1 and #alice.responses == 2,
        "Requester and responder duplicate detection normalizes names and realm whitespace")
    for _, client in ipairs(bus.clients) do client.world:advance(35) end
    assert(#alice.world.nativeSends + #bob.world.nativeSends + #carol.world.nativeSends == sent,
        "Snapshot requests and replies do not schedule periodic rebroadcasts")
end

local function requestFixture(onRequest, onResponse, native)
    local current, clock = newAddon(nil, false, native or { playerName = "Self" })
    clock:login()
    assert(current:RegisterDataRequest("snapshot", onRequest or function() return "own" end, onResponse or function() end))
    return current, clock
end

-- Request and response handlers receive the complete body after their own headers.
do
    local requests, responses = {}, {}
    local current, clock = requestFixture(function(_, payload)
        requests[#requests + 1] = payload
        return payload
    end, function(_, payload) responses[#responses + 1] = payload end)
    for index, payload in ipairs({ "", "|a||b|1|Q|snapshot|nested|" }) do
        local accepted, id = current:RequestData("snapshot", payload)
        assert(accepted and clock.sent[#clock.sent].message == "1|Q|snapshot|" .. id .. "|" .. payload)
        local peerID = "opaque-" .. index
        assert(current:ReceiveData("Friend", "1|Q|snapshot|" .. peerID .. "|" .. payload))
        assert(requests[index] == payload)
        assert(clock.sent[#clock.sent].message == "1|R|snapshot|" .. peerID .. "|friend-testrealm|" .. payload)
        assert(current:ReceiveData("Friend", "1|R|snapshot|" .. id .. "|self-testrealm|" .. payload))
        assert(responses[index] == payload, "An empty or nested response body must survive request correlation")
    end
end

do
    local requests, responses = 0, {}
    local current, clock = requestFixture(function(_, payload) requests = requests + 1; return payload end,
        function(sender, payload) responses[#responses + 1] = { sender = sender, payload = payload } end,
        { configure = function(environment)
            environment.NameUtil = { GetUnmodifiedUnitFullName = function() return "Native-Test Realm" end }
        end })
    assert(not current:RegisterDataRequest("snapshot", function() error("Duplicate replacement") end, function() end))
    for _, name in ipairs({ "", "Upper", "bad|name", string.rep("a", 33) }) do
        assert(not current:RegisterDataRequest(name, function() end, function() end))
    end
    assert(not current:RegisterDataRequest("missing", nil, function() end))
    assert(not current:RegisterDataRequest("missing", function() end, false))
    assert(not current:RequestData("missing", "") and not current:RequestData("snapshot", nil))
    assert(current:IsDataSelf("SELF-TestRealm") and current:IsDataSelf("Native-TestRealm"))
    local accepted, id = current:RequestData("snapshot", "")
    assert(accepted)
    local prefix = "1|R|snapshot|" .. id .. "|"
    for _, frame in ipairs({
        prefix .. "other-testrealm|wrong target", "1|R|other|" .. id .. "|self-testrealm|wrong feature",
        "1|R|snapshot|unrelated-session-1|self-testrealm|old session", "1|R|snapshot|not-issued|self-testrealm|unsolicited",
    }) do
        assert(not current:ReceiveData("Friend-TestRealm", frame))
    end
    assert(not current:ReceiveData("Self-Test Realm", prefix .. "self-testrealm|self"))
    assert(not current:ReceiveData("Native-TestRealm", prefix .. "self-testrealm|native self"))
    assert(not current:ReceiveData("Self-TestRealm", "1|Q|snapshot|self-request|echo"))
    assert(not current:ReceiveData("Native-Test Realm", "1|Q|snapshot|native-request|echo"))
    assert(requests == 0 and #responses == 0)
    assert(current:ReceiveData("Friend", prefix .. "native-testrealm|a|b||c"))
    assert(not current:ReceiveData("FRIEND-Test Realm", prefix .. "native-testrealm|duplicate"))
    assert(#responses == 1 and responses[1].sender == "Friend" and responses[1].payload == "a|b||c")
    clock:advance(10)
    assert(not current:ReceiveData("LateFriend", prefix .. "self-testrealm|expired"),
        "The response window is closed at ten seconds even without another request")
    assert(#responses == 1)
end

-- Both kinds of frames obey the same NUL and byte limits as streaming data.
do
    local response, requests, responses = "", 0, 0
    local current, clock = requestFixture(function() requests = requests + 1; return response end,
        function() responses = responses + 1 end)
    local accepted, id = current:RequestData("snapshot", "")
    assert(accepted and #id <= 32)
    local requestHeader = "1|Q|snapshot|" .. id .. "|"
    local maximumPayload = string.rep("x", 255 - #requestHeader)
    assert(current:RequestData("snapshot", maximumPayload) and #clock.nativeSends[#clock.nativeSends].message == 255)
    local sent = #clock.nativeSends
    assert(not current:RequestData("snapshot", maximumPayload .. "x") and not current:RequestData("snapshot", "bad\000data"))
    assert(#clock.nativeSends == sent)
    for _, frame in ipairs({
        "1|Q|snapshot||payload", "1|Q|snapshot|bad.id|payload", "1|Q|snapshot|" .. string.rep("x", 33) .. "|payload",
        "1|Q|Upper|id|payload", "1|Q|" .. string.rep("a", 33) .. "|id|payload", "1|Q|missing|id|payload",
        "1|Q|snapshot|id",
        "1|R|snapshot||self-testrealm|payload", "1|R|snapshot|bad.id|self-testrealm|payload",
        "1|R|snapshot|id||payload", "1|R|snapshot|id|self-testrealm", "2|Q|snapshot|id|payload",
    }) do
        assert(not current:ReceiveData("Friend", frame), frame)
    end
    assert(requests == 0 and responses == 0 and #clock.nativeSends == sent)
    local header = "1|R|snapshot|maximum|friend-testrealm|"
    response = string.rep("x", 255 - #header)
    assert(current:ReceiveData("Friend", "1|Q|snapshot|maximum|"))
    assert(#clock.nativeSends[#clock.nativeSends].message == 255)
    sent = #clock.nativeSends
    response = response .. "xx"
    assert(not current:ReceiveData("Friend", "1|Q|snapshot|oversized|"))
    response = "bad\000data"
    assert(not current:ReceiveData("Friend", "1|Q|snapshot|nul|"))
    assert(#clock.nativeSends == sent, "Invalid replies are rejected before the native send")
    local marker = {}
    clock.environment.issecretvalue = function(value) return rawequal(value, marker) end
    assert(not current:RegisterDataRequest(marker, function() end, function() end))
    assert(not current:RequestData("snapshot", marker))
    clock.environment.UnitFullName = function() return marker, marker end
    clock.environment.NameUtil = { GetUnmodifiedUnitFullName = function() return marker end }
    assert(not current:IsDataSelf("Self") and not current:RequestData("snapshot", ""),
        "Secret names and payloads never enter comparisons, concatenation or transport")
end

-- Native rejection/exception does not leave a live request or retry queue behind.
for _, failure in ipairs({ "reject", "throw" }) do
    local responses = 0
    local current, clock = requestFixture(nil, function() responses = responses + 1 end)
    clock.sendResult, clock.sendThrows = failure == "reject" and 11 or 0, failure == "throw"
    assert(not current:RequestData("snapshot", "failed"))
    assert(next(current.dataState.pendingRequests) == nil)
    local attempted = clock.sendCalls
    clock.sendResult, clock.sendThrows = 0, false
    clock:advance(30)
    assert(clock.sendCalls == attempted and responses == 0, "Failed snapshots are retried only by the requesting feature")
    if failure == "reject" then
        local id = clock.nativeSends[1].message:match("^1|Q|snapshot|([^|]+)|")
        assert(not current:ReceiveData("Friend", "1|R|snapshot|" .. id .. "|self-testrealm|late failed reply"))
    end
    assert(current:RequestData("snapshot", "current"))
end

-- A broken or declining snapshot handler cannot interrupt other requests or streaming features.
do
    local current, clock = requestFixture(function() error("Request callback failed") end,
        function() error("Response callback failed") end)
    assert(current:RegisterDataRequest("decline", function() return nil end, function() return false end))
    assert(current:RegisterDataRequest("other", function() return "working" end, function() end))
    assert(current:RegisterDataFeature("echo", function() end))
    assert(not current:ReceiveData("Friend", "1|Q|snapshot|broken|"))
    assert(not current:ReceiveData("Friend", "1|Q|decline|declined|"))
    local accepted, id = current:RequestData("snapshot", "")
    assert(accepted and not current:ReceiveData("Friend", "1|R|snapshot|" .. id .. "|self-testrealm|broken"))
    accepted, id = current:RequestData("decline", "")
    assert(accepted and not current:ReceiveData("Friend", "1|R|decline|" .. id .. "|self-testrealm|declined"))
    assert(current:ReceiveData("Friend", "1|Q|other|healthy|"))
    assert(current:ReceiveData("Friend", "1|echo|still working"))
    assert(clock.nativeSends[#clock.nativeSends].message == "1|R|other|healthy|friend-testrealm|working")
end

-- Losing native memberships and logging out invalidate request correlation.
for _, action in ipairs({ "disconnect", "logout" }) do
    local calls, responses = 0, 0
    local current, clock = requestFixture(function() calls = calls + 1; return "own" end,
        function() responses = responses + 1 end)
    local accepted, oldID = current:RequestData("snapshot", "old")
    assert(accepted and current:ReceiveData("Friend", "1|Q|snapshot|peer-request|"))
    if action == "disconnect" then clock:disconnect()
    else clock:fire("PLAYER_LOGOUT") end
    assert(next(current.dataState.pendingRequests) == nil and next(current.dataState.repliedRequests) == nil, action)
    if action ~= "logout" then
        clock:connect()
        assert(not current:ReceiveData("Friend", "1|R|snapshot|" .. oldID .. "|self-testrealm|stale"), action)
        local fresh, id = current:RequestData("snapshot", "fresh")
        assert(fresh and id ~= oldID and current:ReceiveData("Friend", "1|R|snapshot|" .. id .. "|self-testrealm|current"), action)
        assert(current:ReceiveData("Friend", "1|Q|snapshot|peer-request|"), "Reply caches belong to one native connection")
        assert(calls == 2 and responses == 1)
    else
        assert(not current:ReceiveData("Friend", "1|Q|snapshot|after-logout|"))
        assert(not current:RequestData("snapshot", "after logout"))
    end
end

-- Connection callbacks can request a new snapshot after native cleanup.
do
    local responses = 0
    local current, clock = requestFixture(nil, function() responses = responses + 1 end)
    local _, oldID = current:RequestData("snapshot", "old")
    local freshID
    current:RegisterDataFeature("connection_snapshot", function() end, function(connected)
        if connected then local accepted; accepted, freshID = current:RequestData("snapshot", "new"); assert(accepted) end
    end)
    clock:disconnect()
    clock:connect()
    assert(current.dataState.pendingRequests[freshID] and not current.dataState.pendingRequests[oldID])
    assert(current:ReceiveData("Friend", "1|R|snapshot|" .. freshID .. "|self-testrealm|fresh") and responses == 1)
end

local function statusFixture(values, accepted, native)
    local current, clock = newAddon(nil, false, native)
    local samples, connections = {}, {}
    assert(current:RegisterDataStatusProvider("player", function() return values end,
        function(sender, fields, stamp, sequence, metadata)
            samples[#samples + 1] = { sender = sender, fields = fields, stamp = stamp, sequence = sequence, metadata = metadata }
        end, function(connected) connections[#connections + 1] = connected end))
    clock:connect(accepted)
    return current, clock, samples, connections
end

local function full(session, stamp, revision, body)
    return "5|F|" .. session .. "|" .. stamp .. "|" .. revision .. "|" .. body
end

local function receive(current, sender, payload)
    return current:ReceiveData(sender, "1|status|" .. payload)
end

local function friendsStatus(addon, stamp, revision, fields, session)
    return assert(addon:EncodeFriendsStatus({ session = session or "77359400-0-1", stamp = stamp,
        revision = revision, fields = fields }))
end

local function friendsLevel(addon, packet, level)
    local decoded = packet.prefix == addon:GetFriendsDataPrefix() and addon:DecodeFriendsStatus(packet.message)
    return decoded and decoded.fields[1] == tostring(level)
end

do
    local current = newAddon()
    local snapshot = { session = "77359400-0-1", stamp = 2000000000, revision = 1,
        fields = { [1] = "24", [2] = "420", [3] = "1000", [4] = "1", [10] = "2", [11] = "7", [12] = "40" } }
    local frame = assert(current:EncodeFriendsStatus(snapshot))
    assert(#current:GetFriendsDataPrefix() == 4 and #frame == 25 and frame:sub(1, 1) == "S"
        and equal(current:DecodeFriendsStatus(frame), snapshot),
        "A full Friends fixture uses 25 payload bytes plus the four-byte prefix and round-trips exactly")
    local levelOnly = friendsStatus(current, snapshot.stamp, snapshot.revision, { [1] = "24" })
    assert(#levelOnly == 15 and equal(assert(current:DecodeFriendsStatus(levelOnly)).fields, { [1] = "24" }),
        "A level-only Friends snapshot uses 15 payload bytes and omits unavailable fields")

    snapshot.session, snapshot.stamp, snapshot.revision = "literal-session", 9999999999, 999999999
    snapshot.fields = { [1] = "0", [2] = "00420", [3] = "", [13] = "-1.25e-7", [37] = "a|b=%",
        [65535] = "unknown" }
    frame = assert(current:EncodeFriendsStatus(snapshot))
    assert(frame == "SDPliteral-session__43gqJ_vy15dHBAK00420AANAQ-1.25e-7lBAKa|b=%___BAOunknown"
        and equal(current:DecodeFriendsStatus(frame), snapshot),
        "Empty, noncanonical numeric and unknown ASCII values retain their original wire encoding")

    snapshot.session, snapshot.stamp = "2540be3ff-7ffffffe-1", 0
    frame = assert(current:EncodeFriendsStatus(snapshot))
    assert(equal(current:DecodeFriendsStatus(frame), snapshot), "Wide session epochs and negative stamp offsets are exact")

    snapshot.fields = { [65535] = "" }
    local beforeLength = #assert(current:EncodeFriendsStatus(snapshot))
    snapshot.fields[65535] = string.rep("x", 255 - beforeLength - 1)
    frame = assert(current:EncodeFriendsStatus(snapshot))
    assert(#frame == 255 and equal(current:DecodeFriendsStatus(frame), snapshot))
    assert(not current:DecodeFriendsStatus(frame .. "x") and not current:DecodeFriendsStatus(frame:sub(1, -2)))
    snapshot.fields[65535] = snapshot.fields[65535] .. "x"
    assert(not current:EncodeFriendsStatus(snapshot), "The codec rejects snapshots beyond the native payload limit")

    for _, fields in ipairs({ { [0] = "1" }, { [65536] = "1" }, { ["1"] = "1" }, { [1] = 1 },
        { [1] = "nul\000" }, { [1] = "newline\n" }, { [1] = string.char(127) }, { [65535] = string.char(128, 255) } }) do
        snapshot.fields = fields
        assert(not current:EncodeFriendsStatus(snapshot), "Invalid fields and bytes outside printable ASCII are rejected")
    end
    assert(not current:DecodeFriendsStatus("SCgglrz7BABABA___BAFgP8"), "The former Base64 literal tag is rejected")
    assert(not current:DecodeFriendsStatus("1|status|5|F|literal-session|100|1|1=24")
        and not current:DecodeFriendsStatus(levelOnly .. "A"), "The codec rejects legacy or overlong encodings")
end

-- Friends discover other addon users before exchanging status snapshots. Guild
-- and group routes also carry request and reply frames.
do
    local bob = { id = "bob-fern", name = "Bob-Fern", displayName = "Bob Fern", gameAccountID = 42 }
    local carol = { id = "carol-reed", name = "Carol-Reed", displayName = "Carol Reed", whisper = "Carol Reed" }
    local localRealm, bobRealm = "CAMWOWEU5Realm4PvP", "CAMWOWEU5Realm12PvP"
    local function setRealm(environment, name, realm)
        environment.GetNormalizedRealmName = function() return realm end
        environment.UnitFullName = function(unit) assert(unit == "player"); return name, realm end
    end
    local values = { level = 24, xp = 420, xpMax = 1000, xpState = "known", class = "MAGE",
        burned = 40, inParty = false, canInvite = true, partyFull = false }
    local current, clock, samples = statusFixture(values, true, {
        guild = true, friends = { [bob.id] = bob, [carol.id] = carol },
        configure = function(environment) setRealm(environment, "Alice Oak", localRealm) end,
    })
    local function packets(message)
        local matching = {}
        for _, packet in ipairs(clock.sent) do
            if packet.message:match(message) then matching[#matching + 1] = packet end
        end
        return matching
    end

    assert(current:GetDataChannelEnabled("friends"), "An existing profile uses Friends by default")
    clock:advance(5)
    local helloTargets = {}
    for _, packet in ipairs(packets("^1|H$")) do
        helloTargets[packet.distribution] = packet.target
    end
    assert(helloTargets.BATTLENET == 42 and helloTargets.WHISPER == "Carol Reed",
        "Discovery addresses each friend using the native target for their transport")
    for _, packet in ipairs(clock.sent) do
        if packet.target ~= nil then
            assert(packet.prefix == "LITF" and packet.message == "1|H", "Discovery carries no status data")
        end
    end

    local bobStatus = friendsStatus(current, 2000000005, 1, { [1] = "25" })
    clock:incomingFriend("1|A", 123)
    clock:incomingFriend("1|A", 42, "OTHER")
    clock:incomingFriend("1|A", 42, current:GetDataPrefix())
    clock:incomingFriend(bobStatus, 123)
    clock:incomingFriend(bobStatus, 42)
    assert(#samples == 0, "An unknown or unconfirmed sender cannot supply status")

    clock:incomingFriend("1|A", 42)
    clock:incomingFriend("1|H", "Carol Reed")
    clock:advance(6)
    local acknowledgments = packets("^1|A$")
    assert(#acknowledgments == 1 and acknowledgments[1].distribution == "WHISPER"
        and acknowledgments[1].target == "Carol Reed", "An eligible hello is acknowledged on the same route")
    local snapshotTargets, aliceSnapshot = {}, nil
    for _, packet in ipairs(packets("^S")) do
        snapshotTargets[packet.distribution] = packet.target
        if packet.target == 42 then aliceSnapshot = packet end
    end
    assert(snapshotTargets.BATTLENET == 42 and snapshotTargets.WHISPER == "Carol Reed",
        "Confirmed friends get compact status over both transports")
    local nativeRequest = packets("^1|Q|status|")[1]
    assert(nativeRequest.distribution == "GUILD" and nativeRequest.prefix == "LockInToolsData",
        "Guild discovery still sends a request with the original prefix")

    local alice = { id = "alice-oak", name = "Alice-Oak", displayName = "Alice Oak", gameAccountID = 21 }
    local _, peerClock, peerSamples = statusFixture({ level = 25 }, true, {
        guild = false, friends = { [alice.id] = alice },
        configure = function(environment) setRealm(environment, "Bob Fern", bobRealm) end,
    })
    peerClock:advance(5)
    peerClock:incomingFriend("1|A", 21)
    peerClock:incomingFriend(aliceSnapshot.message, 21, aliceSnapshot.prefix)
    peerClock:advance(6)
    local bobSnapshot
    for _, packet in ipairs(peerClock.sent) do
        if packet.message:match("^S") then bobSnapshot = packet end
    end
    assert(bobSnapshot and bobSnapshot.target == 21 and bobSnapshot.distribution == "BATTLENET")
    clock:incomingFriend(bobSnapshot.message, 42)
    assert(#samples == 1 and samples[1].sender == bob.name and samples[1].fields.level == "25"
        and #peerSamples == 1 and peerSamples[1].sender == alice.name and peerSamples[1].fields.level == "24"
        and peerSamples[1].fields.xp == "420" and peerSamples[1].fields.xpMax == "1000"
        and peerSamples[1].fields.xpState == "known" and peerSamples[1].fields.class == "MAGE"
        and peerSamples[1].fields.burned == "40" and peerSamples[1].fields.inParty == false
        and peerSamples[1].fields.canInvite == true and peerSamples[1].fields.partyFull == false,
        "Compact status preserves every reported value and resolves Friends across realms")

    local bobSession = assert(current:DecodeFriendsStatus(bobSnapshot.message)).session
    local accepted, requestID = current:RequestData("status", nativeRequest.message:match("^1|Q|status|[^|]+|(.*)$"))
    assert(accepted and clock.sent[#clock.sent].distribution == "GUILD")
    local target = next(current.dataState.pendingRequests[requestID].targets)
    local sends = #clock.sent
    local revisedBobStatus = full(bobSession, 2000000013, 2, "1=26")
    clock:incomingFriend("1|status|" .. revisedBobStatus, 42)
    clock:incomingFriend("1|status|" .. revisedBobStatus, 42, current:GetDataPrefix())
    clock:incomingFriend("1|Q|status|bob-request|" .. revisedBobStatus, 42)
    clock:incomingFriend("1|R|status|" .. requestID .. "|" .. target .. "|" .. revisedBobStatus, 42)
    local compactRevised = friendsStatus(current, 2000000013, 2, { [1] = "26" }, bobSession)
    clock:incomingFriend(compactRevised, 42, current:GetDataPrefix())
    clock:incoming(compactRevised, bob.name, { distribution = "GUILD", prefix = current:GetFriendsDataPrefix() })
    clock:incoming("1|status|" .. revisedBobStatus, bob.name,
        { distribution = "GUILD", prefix = current:GetFriendsDataPrefix() })
    clock:advance(2)
    assert(#samples == 1 and #clock.sent == sends,
        "Friends and native routes reject each other's prefixes, frames, and request and reply traffic")

    clock:incoming("1|status|" .. revisedBobStatus, bob.name, { distribution = "GUILD" })
    assert(#samples == 2 and samples[2].sender == bob.name and samples[2].fields.level == "26")
    clock:incomingFriend(friendsStatus(current, 2000000014, 2, { [1] = "26" }, bobSession), 42)
    assert(#samples == 3 and samples[3].fields.level == "26" and samples[3].stamp == 2000000014,
        "The same revision can refresh across wire formats with identical fields and a newer stamp")
    assert(current:RegisterDataFeature("echo", function() end) and current:SendData("echo", "overlap"))
    values.level = 27
    clock:advance(8)
    local feature = packets("^1|echo|overlap$")
    assert(#feature == 1 and feature[1].distribution == "GUILD", "Generic features stay on the native group routes")
    local native, direct = packets("^1|status|.*|1=27|"), {}
    for _, packet in ipairs(packets("^S")) do
        if friendsLevel(current, packet, 27) then direct[#direct + 1] = packet end
    end
    assert(#native == 1 and native[1].distribution == "GUILD" and #direct == 1 and direct[1].target == "Carol Reed",
        "A friend whose status arrived through the guild receives no redundant snapshot")
    local previousSend = -math.huge
    for _, packet in ipairs(clock.sent) do
        if packet.target ~= nil then
            assert(packet.at - previousSend >= 0.5, "Targeted sends share one paced queue")
            previousSend = packet.at
        end
    end

    clock.friends[bob.id] = nil
    current:Notify("FRIEND_DATA_CHANGED")
    clock:incomingFriend(friendsStatus(current, 2000000019, 3, { [1] = "27" }, bobSession), 42)
    assert(#samples == 3, "Roster removal revokes a confirmed friend's access")

    assert(current:SetDataChannelEnabled("friends", false) and current.db.data.channels.friends == false)
    sends = #clock.sent
    clock:incomingFriend("1|H", "Carol Reed")
    clock:incomingFriend(friendsStatus(current, 2000000015, 1, { [1] = "26" }), "Carol Reed")
    clock:advance(5)
    assert(#samples == 3 and #clock.sent == sends and current:IsDataConnected(),
        "Friends opt-out stops friend traffic while the native guild route stays connected")
    local reopened, freshClock = newAddon(current.db, false, { guild = false, friends = clock.friends })
    freshClock:login()
    freshClock:advance(5)
    assert(not reopened:GetDataChannelEnabled("friends") and not reopened:IsDataConnected() and #freshClock.sent == 0,
        "The explicit Friends opt-out survives reload")
    assert(reopened:SetDataChannelEnabled("friends", true))
    freshClock:advance(5)
    assert(#freshClock.sent == 1 and freshClock.sent[1].message == "1|H"
        and freshClock.sent[1].distribution == "WHISPER" and freshClock.sent[1].target == "Carol Reed")
    freshClock:incomingFriend("1|A", "Carol Reed")
    assert(reopened:IsDataConnected(), "A confirmed friend can provide the only active route")
end

-- Native and Friends snapshots publish at independent cadences. A new friend
-- joins the next allowed batch, which carries the latest sample to both peers.
do
    local bob = { id = "bob-fern", name = "Bob-Fern", displayName = "Bob Fern", gameAccountID = 42 }
    local carol = { id = "carol-reed", name = "Carol-Reed", displayName = "Carol Reed", whisper = "Carol Reed" }
    local values = { level = 24 }
    local current, clock = statusFixture(values, true, { guild = true, friends = { [bob.id] = bob, [carol.id] = carol } })
    local function snapshots(direct)
        local result = {}
        for _, packet in ipairs(clock.sent) do
            if (direct and packet.prefix == "LITF" and packet.message:match("^S"))
                or (not direct and packet.prefix == "LockInToolsData" and packet.message:match("^1|status|")) then
                result[#result + 1] = packet
            end
        end
        return result
    end

    clock:advance(1)
    clock:incomingFriend("1|A", 42)
    clock:advance(5)
    local first = snapshots(true)[1]
    assert(first and first.target == 42 and friendsLevel(current, first, 24), "The first confirmed friend receives status")
    clock:incomingFriend("1|H", carol.whisper)
    local changed = clock.now
    values.level = 25
    clock:advance(5)
    local native = snapshots(false)
    assert(#native == 1 and native[1].at <= changed + 5 and native[1].message:match("|1=25$"),
        "The native route sends changes on its five-second cadence")
    assert(#snapshots(true) == 1, "New friends and status changes wait for the next ten-second batch")

    values.level = 26
    clock:advance(6)
    local batch = snapshots(true)
    assert(#batch == 3 and batch[2].message == batch[3].message and friendsLevel(current, batch[2], 26)
        and batch[2].at - first.at >= 10 and batch[3].at - batch[2].at == 0.5,
        "One paced Friends batch sends the latest complete status to both targets")
    assert((batch[2].target == 42 and batch[3].target == carol.whisper)
        or (batch[3].target == 42 and batch[2].target == carol.whisper))
    native = snapshots(false)
    assert(#native == 2 and native[2].at - native[1].at == 5 and native[2].message:match("|1=26$"))

    clock:advance(30)
    native = snapshots(false)
    assert(#native == 3 and native[3].at - native[2].at == 30 and native[3].message:match("|1=26$"),
        "The native unchanged refresh remains thirty seconds")
    assert(#snapshots(true) == 3, "Friends do not refresh at the native thirty-second boundary")
    clock:advance(32)
    local refresh = snapshots(true)
    local function stamp(packet) return assert(current:DecodeFriendsStatus(packet.message)).stamp end
    assert(#refresh == 5 and stamp(refresh[4]) - stamp(batch[2]) == 60
        and refresh[5].at - refresh[4].at == 0.5
        and refresh[4].message == refresh[5].message and friendsLevel(current, refresh[4], 26),
        "An unchanged Friends snapshot refreshes after sixty seconds")
end

-- Queuing a Friends snapshot must not clear a failed native discovery request.
do
    local peer = { id = "bob-fern", name = "Bob-Fern", displayName = "Bob Fern", gameAccountID = 42 }
    local current, clock = statusFixture({ level = 24 }, true, { guild = true, friends = { [peer.id] = peer },
        configure = function(_, world) world.routeResults = { GUILD = 11 } end,
    })
    clock:advance(1)
    clock:incomingFriend("1|A", 42)
    clock:advance(5)
    assert(#clock.sent == 4 and clock.sent[3].distribution == "GUILD"
        and clock.sent[3].message:match("^1|Q|status|") and clock.sent[3].at == 5
        and clock.sent[4].distribution == "BATTLENET" and clock.sent[4].target == 42
        and friendsLevel(current, clock.sent[4], 24)
        and next(current.dataState.pendingRequests) == nil,
        "Friends can publish at the same tick as a failed guild discovery request")
    clock.routeResults.GUILD = 0
    clock:advance(4)
    local retry = clock.sent[5]
    local requestID = retry and retry.message:match("^1|Q|status|([^|]+)|")
    assert(#clock.sent == 5 and retry.at == 10 and retry.distribution == "GUILD" and requestID
        and current.dataState.pendingRequests[requestID], "Guild discovery retries on the next status tick")
end

-- A friend on both rosters must answer on the probed transport or initiate a
-- handshake on the other one. Their confirmed transport carries the snapshots.
do
    local peer = { id = "bob-fern", name = "Bob-Fern", displayName = "Bob Fern",
        gameAccountID = 42, whisper = "Bob Fern" }
    local current, clock, samples = statusFixture({ level = 24 }, true, {
        guild = false, friends = { [peer.id] = peer },
    })
    clock:advance(1)
    assert(#clock.sent == 1 and clock.sent[1].message == "1|H" and clock.sent[1].distribution == "BATTLENET"
        and clock.sent[1].target == 42, "Discovery initially prefers Battle.net for a friend on both rosters")

    clock:incomingFriend("1|A", peer.whisper)
    assert(not current:IsDataConnected(), "An acknowledgment cannot complete a probe on a different transport")
    clock:incomingFriend("1|H", peer.whisper)
    clock:advance(6)
    assert(current:IsDataConnected() and #clock.sent == 3 and clock.sent[2].message == "1|A"
        and clock.sent[2].distribution == "WHISPER" and clock.sent[2].target == peer.whisper
        and friendsLevel(current, clock.sent[3], 24) and clock.sent[3].distribution == "WHISPER"
        and clock.sent[3].target == peer.whisper, "Status uses the route confirmed by the friend's hello")
    assert(next(current.dataState.pendingRequests) == nil, "Friends-only publication creates no pending requests")

    local received = 0
    assert(current:RegisterDataFeature("echo", function() received = received + 1 end))
    clock:incomingFriend("1|echo|generic feature", peer.whisper)
    assert(received == 0 and not current:SendData("echo", "generic feature"),
        "The Friends route only exchanges status snapshots")

    local snapshot = friendsStatus(current, 2000000007, 1, { [1] = "25", [65535] = "unknown" })
    clock:incomingFriend(snapshot .. string.rep("x", 256), peer.whisper)
    clock:incomingFriend(snapshot:sub(1, -2) .. "\000", peer.whisper)
    clock:incomingFriend(snapshot:sub(1, -2), peer.whisper)
    assert(#samples == 0, "Oversized, NUL-containing and truncated snapshots do not reach status providers")
    clock:incomingFriend(snapshot, peer.whisper)
    assert(#samples == 1 and samples[1].fields.level == "25", "An unknown field does not prevent reading known values")
end

-- A local guild change drops cached guild contact. A valid duplicate still proves contact.
do
    local peer = { id = "bob-fern", name = "Bob-Fern", displayName = "Bob Fern", gameAccountID = 42 }
    local values = { level = 24 }
    local current, clock, samples = statusFixture(values, true, { guild = true, friends = { [peer.id] = peer } })
    clock:advance(1)
    clock:incomingFriend("1|A", 42)
    local snapshot = "1|status|" .. full("77359400-0-1", 2000000001, 1, "1=25")
    clock:incomingFriend(friendsStatus(current, 2000000001, 1, { [1] = "25" }), 42)
    clock:incoming(snapshot, peer.name)
    clock:advance(5)
    assert(#samples == 1, "The second copy is a valid duplicate, not another status update")
    local function friendHasLevel(level)
        for _, packet in ipairs(clock.sent) do
            if packet.target == 42 and friendsLevel(current, packet, level) then return true end
        end
        return false
    end
    assert(not friendHasLevel(24), "A valid duplicate proves native contact and avoids a direct snapshot")
    clock:fire("PLAYER_GUILD_UPDATE", "player")
    clock:incoming("1|status|5|F|malformed", peer.name)
    clock:incoming("1|Q|status|invalid!|" .. snapshot:sub(10), peer.name)
    clock:incoming("1|R|status|valid-id|someone-testrealm|malformed", peer.name)
    values.level = 26
    clock:advance(5)
    assert(friendHasLevel(26), "A guild change and malformed frames cannot suppress a direct snapshot")

    clock:incoming(snapshot, peer.name)
    clock.guild = false
    clock:fire("PLAYER_GUILD_UPDATE", "player")
    clock.guild = true
    clock:fire("PLAYER_GUILD_UPDATE", "player")
    values.level = 27
    clock:advance(10)
    assert(friendHasLevel(27), "Immediately joining another guild does not restore stale guild contact")
end

-- ACKs stay distinct by transport. An outgoing Battle.net failure falls back
-- to a confirmed character whisper or discovers that route first.
for _, whisperConfirmed in ipairs({ true, false }) do
    local peer = { id = "bob-fern", name = "Bob-Fern", displayName = "Bob Fern",
        gameAccountID = 42, whisper = "Bob Fern" }
    local values = { level = 24 }
    local current, clock = statusFixture(values, true, { guild = false, friends = { [peer.id] = peer } })
    clock:advance(1)
    if whisperConfirmed then
        clock:incomingFriend("1|H", 42)
        clock:incomingFriend("1|H", peer.whisper)
    else
        clock:incomingFriend("1|A", 42)
    end
    local sendBattleNet = clock.environment.C_BattleNet.SendGameData
    local battleNetDown = true
    clock.environment.C_BattleNet.SendGameData = function(target, prefix, message)
        local result = sendBattleNet(target, prefix, message)
        return battleNetDown and message:match("^S") and 11 or result
    end
    clock:advance(3)
    local acks, battleNetSnapshots, whisperSnapshots, whisperHello = {}, 0, 0, false
    for _, packet in ipairs(clock.sent) do
        if packet.message == "1|A" then acks[packet.distribution] = packet.at end
        if packet.message == "1|H" and packet.target == peer.whisper then whisperHello = true end
        if friendsLevel(current, packet, 24) then
            if packet.target == 42 then battleNetSnapshots = battleNetSnapshots + 1 end
            if packet.target == peer.whisper then
                whisperSnapshots = whisperSnapshots + 1
                if whisperConfirmed then assert(acks.WHISPER and acks.WHISPER < packet.at) end
            end
        end
    end
    if whisperConfirmed then
        assert(acks.BATTLENET and acks.WHISPER, "Both incoming hellos get acknowledged on their own transport")
        assert(battleNetSnapshots == 1 and whisperSnapshots == 1,
            "The confirmed whisper sends the snapshot rejected by Battle.net")
    else
        assert(battleNetSnapshots == 1 and whisperSnapshots == 0 and whisperHello,
            "A failed Battle.net send probes the whisper route before sharing status")
        clock:incomingFriend("1|A", peer.whisper)
    end

    -- Incoming Battle.net traffic is not evidence that outgoing sends recovered.
    clock:incomingFriend("1|A", 42)
    clock:incomingFriend(friendsStatus(current, 2000000004, 1, { [1] = "25" }), 42)
    values.level = 26
    clock:advance(8)
    local last = clock.sent[#clock.sent]
    assert(last.target == peer.whisper and friendsLevel(current, last, 26),
        "New status keeps using the working character whisper")

    battleNetDown = false
    clock:advance(25)
    local recoveryProbe = false
    for _, packet in ipairs(clock.sent) do
        if packet.at > 11 and packet.target == 42 then
            assert(packet.message == "1|H", "An unacknowledged recovery probe does not restore Battle.net snapshots")
            recoveryProbe = true
        end
    end
    assert(recoveryProbe, "Battle.net is probed again while snapshots use the working whisper")
    clock:incomingFriend("1|A", 42)
    values.level = 27
    clock:advance(6)
    last = clock.sent[#clock.sent]
    assert(last.target == 42 and friendsLevel(current, last, 27)
        and current:GetDataSendStatusText() == "", "A successful probe restores Battle.net and clears its failure")
end

-- Class uses a compact status enum; future numeric codes preserve compatible
-- snapshot decoding without inventing a supported player class.
do
    for code, class in pairs({ [0] = "unknown", [1] = "WARRIOR", [7] = "MAGE" }) do
        local current, clock, samples = statusFixture({ class = class })
        assert(clock.sent[1].message:match("|11=" .. code .. "$"), "Class is encoded as its permanent numeric ID")
        assert(receive(current, "Friend", full("peer", 2000000000, 1, "11=" .. code)))
        assert(samples[1].fields.class == class)
    end
    local current, _, samples = statusFixture({ class = "UNSUPPORTED" })
    assert(receive(current, "Friend", full("peer", 2000000000, 1, "11=65535")))
    assert(samples[1].fields.class == "unknown", "Future class IDs decode to unknown")
end

-- Unexpected callback errors remain visible without cancelling future status
-- work; the next tick must publish the current sample after the error clears.
do
    local values = { level = 24 }
    local current, clock = statusFixture(values)
    local tick = current.DataStatusTick
    current.DataStatusTick = function() error("Simulated status callback failure") end
    local ok, problem = pcall(function() clock:advance(5) end)
    assert(not ok and problem:find("Simulated status callback failure", 1, true),
        "Unexpected status errors must still reach the native error handler")
    assert(current.dataState.status.timer and #clock.sent == 1,
        "An interrupted status callback leaves its next tick scheduled")
    current.DataStatusTick, values.level = tick, 25
    clock:advance(5)
    assert(#clock.sent == 2
        and clock.sent[2].message:match("^1|status|5|F|[^|]+|2000000010|2|1=25$"),
        "The next scheduled status tick publishes the latest values after recovery")
    clock:advance(30)
    assert(#clock.sent == 3
        and clock.sent[3].message:match("^1|status|5|F|[^|]+|2000000040|2|1=25$"),
        "Automatic recovery preserves the normal status heartbeat")
end

-- Retired fields remain readable for older senders without entering status
-- state or causing a newer snapshot at the same revision to be rejected.
do
    local current, clock, samples = statusFixture({ level = 24, class = "MAGE", burned = 50 })
    local legacy = full("peer", 2000000000, 1, "1=25|8=1|9=P,37,30000,70000|11=3|12=80")
    assert(receive(current, "Friend", legacy))
    assert(equal(samples[1].fields, { level = "25", class = "HUNTER", burned = "80" }))
    assert(current.dataState.status.received["friend-testrealm"].fields[8] == nil
        and current.dataState.status.received["friend-testrealm"].fields[9] == nil)
    assert(receive(current, "Friend", full("peer", 2000000001, 1, "1=25|8=0|9=U|11=3|12=80")))
    assert(not current:ReceiveData("Friend", "1|position|2|P|2000000002|37|80000|70000")
        and #samples == 2, "Standalone location reports are no longer handled")
    local requested = full("peer", 2000000002, 1, "1=25|8=1|9=P,37,40000,70000|11=3|12=80")
    assert(current:ReceiveData("Friend", "1|Q|status|initial|" .. requested) and #samples == 3)
    clock:advance(30)
    assert(#clock.sent == 3 and clock.sent[1].message:match("^1|Q|status|")
        and clock.sent[2].message:match("^1|R|status|initial|friend%-testrealm|")
        and clock.sent[3].message:match("^1|status|5|F|"))
    for _, packet in ipairs(clock.sent) do
        assert(packet.message:match("|1=24|11=7|12=50$"), "Status never serializes a location or sharing flag")
    end
end

-- The public status clock remains monotonic across a rollback.
do
    local values = { level = 24 }
    local _, clock = statusFixture(values)
    clock:advance(4)
    clock.epoch, values.level = clock.epoch - 10, 25
    clock:advance(1)
    assert(#clock.sent == 2 and clock.sent[2].message:match("^1|status|5|F|[^|]+|2000000000|2|1=25$"))
end

-- Rejected sends never count as successful broadcasts. Retry the latest whole
-- sample, including when it has returned to the previously broadcast values.
for _, latest in ipairs({ 3, 1 }) do
    local values = { xp = 1 }
    local _, clock = statusFixture(values)
    values.xp, clock.sendResult = 2, 11
    clock:advance(5)
    assert(#clock.sent == 2 and clock.sent[2].message:match("|5|F|[^|]+|2000000005|2|2=2$"))
    values.xp, clock.sendResult = latest, 0
    clock:advance(5)
    local expected = "|5|F|[^|]+|2000000010|3|2=" .. latest .. "$"
    assert(#clock.sent == 3 and clock.sent[3].message:match(expected),
        "Retries publish current values without any dependency on earlier packets")
    clock:advance(25)
    assert(#clock.sent == 3, "A successfully retried sample clears unpublished state")
    clock:advance(5)
    assert(#clock.sent == 4 and clock.sent[4].message:match("^1|status|5|F|[^|]+|2000000040|3|2=" .. latest .. "$"))
end

-- These IDs are permanent protocol assignments. Collectors and consumers retain
-- readable names and typed values at the API boundary.
do
    local values = {
        level = 24, xp = 420, xpMax = 1000, xpState = "known",
        inParty = true, canInvite = false, partyFull = false,
    }
    local current, clock, samples = statusFixture(values)
    local body = "1=24|2=420|3=1000|4=1|10=1"
    assert(clock.sent[1].message:match("|5|F|[^|]+|2000000000|1|(.+)$") == body)
    assert(receive(current, "Friend", full("peer", 2000000000, 1, body)))
    for name, value in pairs(values) do
        local expected = type(value) == "number" and tostring(value) or value
        assert(samples[1].fields[name] == expected, name)
    end
    assert(samples[1].fields[1] == nil and samples[1].fields["1"] == nil,
        "Numeric field IDs are private to the codec")

    -- Unknown Lua names never acquire IDs automatically or fall back to named
    -- wire fields. An invalid provider cannot publish its partially valid data.
    assert(current:RegisterDataStatusProvider("unregistered", function()
        return { future = "new", xp = 1 }
    end, function() end))
    clock:advance(5)
    assert(#clock.sent == 1)
end

-- Party flags keep their readable booleans at the API boundary. In particular,
-- a zero mask means all false; omitting the mask means all three are unknown.
for _, mask in ipairs({ 0, 3, 7 }) do
    local values = {
        inParty = mask % 2 == 1,
        canInvite = math.floor(mask / 2) % 2 == 1,
        partyFull = math.floor(mask / 4) % 2 == 1,
    }
    local current, clock, samples = statusFixture(values)
    assert(clock.sent[1].message:match("|5|F|[^|]+|2000000000|1|(.+)$") == "10=" .. mask)
    assert(receive(current, "Friend", full("peer", 2000000000, 1, "10=" .. mask)))
    assert(equal(samples[1].fields, values), "Party mask round trip: " .. mask)
    assert(receive(current, "Friend", full("peer", 2000000001, 2, "")))
    assert(next(samples[2].fields) == nil, "An omitted mask must not invent false flags")
end

-- The registry performs field-specific value conversion, preserving ordinary
-- strings in other fields and keeping absent values distinct from false/zero.
do
    local values = { xpState = "unavailable", xpMax = "known" }
    local current, clock, samples = statusFixture(values)
    assert(clock.sent[1].message:match("|5|F|[^|]+|2000000000|1|(.+)$") == "3=known|4=0")
    local states = { "unavailable", "known", "max" }
    for code = 0, 2 do
        assert(receive(current, "Friend", full("peer", 2000000000 + code, code + 1,
            "3=known|4=" .. code)))
        assert(equal(samples[#samples].fields,
            { xpMax = "known", xpState = states[code + 1] }))
        values.xpState = states[code + 1]
        clock:advance(5)
        assert(clock.sent[#clock.sent].message:match("|4=" .. code .. "$"))
    end
    assert(receive(current, "Friend", full("peer", 2000000003, 4, "")))
    assert(next(samples[#samples].fields) == nil)
end

-- Future XP states fail closed to unavailable; future party bits have no
-- effect on today's flags. Raw values still protect same-revision consistency.
do
    local current, _, samples = statusFixture({ level = 24 })
    assert(receive(current, "Friend", full("peer", 2000000000, 1, "4=3|10=9")))
    assert(equal(samples[1].fields,
        { xpState = "unavailable", inParty = true, canInvite = false, partyFull = false }))
    assert(not receive(current, "Friend", full("peer", 2000000001, 1, "4=4|10=9")))
    assert(not receive(current, "Friend", full("peer", 2000000001, 1, "4=3|10=1")))
    assert(receive(current, "Friend", full("peer", 2000000001, 2, "4=65535|10=4294967295")))
    assert(equal(samples[2].fields,
        { xpState = "unavailable", inParty = true, canInvite = true, partyFull = true }))
    assert(receive(current, "Friend", full("peer", 2000000002, 3, "10=8|5=true|6=false|7=true")))
    assert(equal(samples[3].fields, { inParty = false, canInvite = false, partyFull = false }))
    assert(receive(current, "Friend", full("peer", 2000000003, 4, "5=true|6=false|7=true")))
    assert(next(samples[4].fields) == nil, "Retired party field IDs must not expose legacy values")
end

-- A provider cannot manufacture known flags from incomplete or untyped input.
-- Reject the whole provider sample while continuing to collect healthy peers.
do
    local current, clock = newAddon()
    local values
    assert(current:RegisterDataStatusProvider("invalid", function() return values end, function() end))
    assert(current:RegisterDataStatusProvider("healthy", function() return { level = 24 } end, function() end))
    clock:connect()
    assert(clock.sent[1].message:match("|5|F|[^|]+|2000000000|1|(.+)$") == "1=24")
    for _, invalid in ipairs({
        { xp = "discard", inParty = true },
        { xp = "discard", inParty = false, canInvite = false, partyFull = 0 },
        { xp = "discard", sharing = false },
        { xp = "discard", xpState = "future" }, { xp = "discard", partyFlags = 3 },
    }) do
        values = invalid
        clock:advance(5)
        assert(not clock.sent[#clock.sent].message:find("discard", 1, true),
            "An invalid typed field must not partially publish the provider")
        assert(clock.sent[#clock.sent].message:match("|1|1=24$"), "Healthy providers continue publishing")
    end
    values = { xp = "recovered", inParty = false, canInvite = true, partyFull = false, xpState = "known" }
    clock:advance(5)
    assert(clock.sent[#clock.sent].message:match("|2|1=24|2=recovered|4=1|10=2$"))
end

-- One provider owns the whole mask. Two complete groups collide atomically;
-- flags from partial providers must never be combined into a fabricated group.
do
    local current, clock = newAddon()
    local first = { inParty = false, canInvite = false, partyFull = false }
    local second = { inParty = true, canInvite = true, partyFull = true }
    assert(current:RegisterDataStatusProvider("first", function() return first end, function() end))
    assert(current:RegisterDataStatusProvider("second", function() return second end, function() end))
    clock:connect()
    assert(#clock.sent == 0, "Overlapping mask providers must not publish whichever happens to win")
    second = { canInvite = true, partyFull = true }
    clock:advance(5)
    assert(#clock.sent == 1 and clock.sent[1].message:match("|1|10=0$"))
    first = { inParty = true }
    clock:advance(5)
    assert(#clock.sent == 2 and clock.sent[2].message:match("|2|$"),
        "Partial groups in separate providers remain unavailable")
    second = { inParty = true, canInvite = true, partyFull = true }
    clock:advance(5)
    assert(#clock.sent == 3 and clock.sent[3].message:match("|3|10=7$"))
end

-- Unknown numeric IDs never leak to named consumers, but still participate in
-- same-revision consistency. Newer complete snapshots replace all prior fields.
do
    local current, clock, samples = statusFixture({ level = 24 })
    local function sample(revision, expected)
        local received = samples[#samples]
        assert(received.sequence == revision and equal(received.fields, expected))
    end
    assert(receive(current, "Friend", full("peer", 2000000000, 1, "1=25|13=future|65535=edge")))
    sample(1, { level = "25" })
    assert(receive(current, "Friend", full("peer", 2000000001, 5, "1=25|13=changed|14=|65535=edge")))
    sample(5, { level = "25" })
    assert(not receive(current, "Friend", full("peer", 2000000002, 5, "1=25|13=conflict|14=|65535=edge")))
    assert(not receive(current, "Friend", full("peer", 2000000002, 5, "1=25")))
    assert(receive(current, "Friend", full("peer", 2000000002, 5, "1=25|13=changed|14=|65535=edge")))
    sample(5, { level = "25" })
    assert(receive(current, "Friend", full("peer", 2000000003, 8, "1=25|2=10")))
    sample(8, { level = "25", xp = "10" })
    assert(receive(current, "Friend", full("peer", 2000000004, 9, "2=10")))
    sample(9, { xp = "10" })
    clock:advance(5)
    assert(#clock.sent == 1, "Remote changes must not schedule recovery requests")
end

-- One shared five-second scheduler sends complete changes and periodic complete
-- refreshes. Targeted replies cannot mark an unpublished local change as public.
do
    local values = { xpState = "known", xpMax = 100, xp = 10, level = 24 }
    local current, clock, samples, connections = statusFixture(values)
    assert(#clock.sent == 1 and clock.sent[1].message:match("^1|Q|status|[^|]+|5|F|[^|]+|2000000000|1|"))
    assert(clock.sent[1].message:find("1=24|2=10|3=100|4=1", 1, true))
    current:StartDataMessages()
    current:OnDataLogin()
    clock:advance(25)
    assert(#clock.sent == 1 and #connections == 2 and clock:activeTimers() == 1, "Only the shared status timer remains")
    clock:advance(5)
    assert(#clock.sent == 2 and clock.sent[2].at == 30
        and clock.sent[2].message:match("^1|status|5|F|[^|]+|2000000030|1|1=24|2=10|3=100|4=1$"))
    values.xp = 20
    clock:advance(5)
    assert(#clock.sent == 3 and clock.sent[3].message:match("|5|F|[^|]+|2000000035|2|1=24|2=20|3=100|4=1$"),
        "A changed field sends the complete independently usable status")
    values.xp = 21
    clock:advance(1)
    assert(not current:DataStatusTick() and #clock.sent == 3)
    values.xp = 29
    clock:advance(4)
    assert(#clock.sent == 4 and clock.sent[4].at == 40
        and clock.sent[4].message:match("|5|F|[^|]+|2000000040|3|1=24|2=29|3=100|4=1$"))
    values.xp = 30
    assert(current:ReceiveData("Friend", "1|Q|status|joined|" .. full("friend-1", 2000000040, 1,
        "1=25|2=5|3=200|4=1")))
    assert(#samples == 1 and samples[1].fields.level == "25" and samples[1].fields.xp == "5"
        and samples[1].metadata.session == "friend-1")
    assert(#clock.sent == 5 and clock.sent[5].message:match("^1|R|status|joined|friend%-testrealm|5|F|"))
    assert(clock.sent[5].message:find("2=30", 1, true))
    clock:advance(5)
    assert(#clock.sent == 6 and clock.sent[6].message:match("^1|status|5|F|")
        and clock.sent[6].message:find("2=30", 1, true),
        "A targeted reply does not consume the public change")
    clock:advance(25)
    assert(#clock.sent == 6)
    clock:advance(5)
    assert(#clock.sent == 7 and clock.sent[7].message:match("^1|status|5|F|")
        and clock.sent[7].message:find("1=24|2=30|3=100|4=1", 1, true))
end

-- A temporary value shared in a requested reply must be corrected even if it
-- changes back to the previously published value before the next tick.
do
    local values = { xp = 1 }
    local current, clock = statusFixture(values)
    values.xp = 2
    assert(current:ReceiveData("Friend", "1|Q|status|temporary|" .. full("peer", 2000000000, 1, "1=25")))
    assert(clock.sent[2].message:find("2=2", 1, true))
    values.xp = 1
    clock:advance(5)
    assert(#clock.sent == 3 and clock.sent[3].message:match("^1|status|5|F|")
        and clock.sent[3].message:match("|3|2=1$"))
end

-- Complete snapshots dispatch independent tables. Omitted fields disappear;
-- an explicitly empty string remains a real value.
do
    local current, clock, samples = statusFixture({ level = 24 })
    local second = {}
    assert(current:RegisterDataStatusProvider("future", function() return { class = "MAGE", xp = "a|b=c%" } end,
        function(_, fields, _, _, metadata)
            second[#second + 1] = { level = fields.level, metadata = metadata }
            fields.level = "mutated"; metadata.session = "mutated"
        end))
    assert(not current:RegisterDataStatusProvider("future", function() end, function() end))
    assert(not current:RegisterDataStatusProvider("Upper", function() end, function() end))
    clock:advance(5)
    assert(#clock.sent == 2 and clock.sent[2].message:match("^1|status|5|F|")
        and clock.sent[2].message:find("2=a%7Cb%3Dc%25|11=7", 1, true)
        and clock.sent[2].message:find("1=24", 1, true))
    assert(clock:activeTimers() == 1 and current.dataState.features.status and current.dataState.requests.status
        and not current.dataState.features.player and not current.dataState.features.future)
    local initial = full("friend-1", 2000000005, 10, "1=25|2=future%7Cvalue|3=|4=1|6=old")
    assert(receive(current, "Friend", initial))
    assert(#samples == 1 and samples[1].fields.level == "25" and samples[1].fields.xp == "future|value"
        and samples[1].fields.xpMax == "" and samples[1].fields.xpState == "known" and second[1].level == "25"
        and samples[1].metadata.session == "friend-1" and second[1].metadata.session == "mutated",
        "Each provider receives independent fields and session metadata")
    assert(not receive(current, "FRIEND-Test Realm", initial))
    assert(not receive(current, "Friend", full("friend-1", 2000000004, 9, "1=26")))
    assert(not receive(current, "Self-TestRealm", initial))
    assert(receive(current, "Friend", full("friend-1", 2000000006, 11, "1=25|2=20|3=future%7Cvalue")))
    assert(#samples == 2 and samples[2].fields.level == "25" and samples[2].fields.xp == "20"
        and samples[2].fields.xpMax == "future|value" and samples[2].fields.canInvite == nil
        and samples[2].fields.xpState == nil and samples[2].metadata.session == "friend-1")
    assert(receive(current, "Friend", full("friend-1", 2000000036, 11, "1=25|2=20|3=future%7Cvalue")))
    assert(#samples == 3 and samples[3].stamp == 2000000036 and samples[3].fields.xp == "20"
        and samples[3].metadata.session == "friend-1",
        "A complete refresh delivers current values and refreshes presence")
    assert(not receive(current, "Friend", full("friend-1", 2000000036, 11, "1=25|2=20|3=future%7Cvalue")))
    local attempts, healthy = 0, 0
    assert(current:RegisterDataStatusProvider("declining", function() error("Collector failed") end,
        function() attempts = attempts + 1; return false end))
    assert(current:RegisterDataStatusProvider("broken", function() return nil end,
        function() error("Receiver failed") end))
    assert(current:RegisterDataStatusProvider("healthy", function() return { xpMax = "healthy" } end,
        function() healthy = healthy + 1 end))
    assert(receive(current, "Other", full("other-1", 2000000005, 1, "1=99")))
    assert(receive(current, "Other", full("other-1", 2000000006, 2, "1=26")))
    assert(attempts == 2 and healthy == 2, "Failed and declining callbacks cannot stop other consumers")
    clock:advance(5)
    assert(clock.sent[#clock.sent].message:find("3=healthy", 1, true))
end

-- Every complete packet is usable across revision gaps. Revisions order one
-- session; timestamps also order its refreshes and changes of session.
do
    local values = { xp = 1 }
    local current, clock, samples = statusFixture(values)
    assert(receive(current, "Friend", full("friend-1", 2000000000, 1, "1=24|2=10")))
    assert(receive(current, "Friend", full("friend-1", 2000000005, 30, "1=24|2=30")))
    assert(#samples == 2 and samples[2].fields.xp == "30",
        "No earlier revision is needed for a complete snapshot")
    assert(not receive(current, "Friend", full("friend-1", 2000000006, 29, "1=24|2=29")))
    assert(not receive(current, "Friend", full("friend-1", 2000000004, 30, "1=24|2=30")))
    assert(not receive(current, "Friend", full("friend-1", 2000000006, 30, "1=24|2=99")))
    assert(not receive(current, "Friend", full("friend-1", 2000000005, 30, "1=24|2=30")))
    assert(#samples == 2, "Rejected packets cannot refresh presence or alter current values")
    assert(receive(current, "Friend", full("friend-1", 2000000006, 30, "1=24|2=30")))
    assert(receive(current, "Friend", full("friend-1", 2000000005, 31, "1=24|2=31")),
        "A newer revision retains precedence over timestamp ordering within one session")
    assert(receive(current, "Friend", full("friend-2", 2000000006, 1, "1=25|2=0")),
        "A reconnect may restart revisions in the same server second under a fresh session")
    assert(not receive(current, "Friend", full("friend-1", 2000000040, 31, "1=99")),
        "A retired sender session cannot overwrite the replacement")
    assert(not receive(current, "Friend", full("old-session", 2000000005, 99, "1=99")))
    assert(samples[#samples].fields.xp == "0" and samples[#samples].metadata.session == "friend-2")
    assert(receive(current, "Unknown", full("unknown-1", 2000000006, 9999, "2=99")))
    assert(samples[#samples].fields.xp == "99" and samples[#samples].metadata.session == "unknown-1",
        "A new peer can start at any complete revision")
    clock:advance(5)
    assert(#clock.sent == 1, "Receiving status never schedules a standalone recovery request")
end

-- Logically targeted replies do not postpone the public refresh needed by
-- other peers. Switching to read-only settings stops this scheduler as well.
do
    local current, clock = statusFixture({ level = 24 })
    clock:advance(10)
    assert(current:ReceiveData("Friend", "1|Q|status|first|" .. full("peer", 2000000010, 1, "1=25")))
    clock:advance(10)
    assert(current:ReceiveData("Friend", "1|Q|status|second|" .. full("peer", 2000000020, 1, "1=25")))
    clock:advance(10)
    assert(clock.sent[#clock.sent].message:match("^1|status|5|F|[^|]+|2000000030|1|1=24$"))
    current.savedDataReadOnly = true
    local sent = #clock.sent
    clock:advance(60)
    assert(#clock.sent == sent and clock:activeTimers() == 0 and not current.dataState.status.connected)
end

-- Initial responses may repeat the current sample in the same server second;
-- this exception never permits conflicting values at an existing revision.
do
    local current, clock, samples = statusFixture({ xp = 1 })
    local requestID = assert(clock.sent[1].message:match("^1|Q|status|([^|]+)|"))
    local snapshot = full("friend-1", 2000000000, 4, "2=40")
    assert(receive(current, "Friend", snapshot))
    assert(current:ReceiveData("Friend", "1|R|status|" .. requestID .. "|self-testrealm|" .. snapshot))
    assert(#samples == 2 and samples[2].fields.xp == "40")
    assert(receive(current, "Other", full("other-1", 2000000000, 4, "2=40")))
    assert(not current:ReceiveData("Other", "1|R|status|" .. requestID .. "|self-testrealm|"
        .. full("other-1", 2000000000, 4, "2=99")),
        "A solicited response cannot change values at the same revision")
    assert(not receive(current, "Friend", full("friend-1", 2000000001, 4, "2=99")))
    assert(samples[2].fields.xp == "40")
end

-- Decode every field before dispatch. Invalid frames cannot partially merge or
-- consume a revision. Old status versions and named wire fields are rejected.
do
    local current, clock, samples = statusFixture({ level = 24 }, nil, {})
    local initialSends = #clock.nativeSends
    -- One representative per structural, numeric, typed-value and escaping failure.
    for index, payload in ipairs({
        "4|F|peer|2000000000|1|1=25", "5|D|peer|2000000000|2|1|1=25",
        "5|F||2000000000|1|1=25", "5|F|peer|10000000000|1|1=25",
        "5|F|peer|2000000000|0|1=25", "5|F|peer|2000000000|01|1=25",
        "5|F|peer|2000000000|1|1=25|1=26", "5|F|peer|2000000000|1|1=25|",
        "5|F|peer|2000000000|1|level=25", "5|F|peer|2000000000|1|1=25=26",
        "5|F|peer|2000000000|1|4=known", "5|F|peer|2000000000|1|8=0|8=1",
        "5|F|peer|2000000000|1|10=-1", "5|F|peer|2000000000|1|11=65536",
        "5|F|peer|2000000000|1|0=x", "5|F|peer|2000000000|1|65536=x",
        "5|F|peer|2000000000|1|1=%GG", "5|F|peer|2000000000|1|1=%0A",
    }) do
        assert(not receive(current, "Friend", payload), payload)
        assert(not current:ReceiveData("Friend", "1|Q|status|direct-" .. index .. "|" .. payload), payload)
        assert(#samples == 0 and #clock.nativeSends == initialSends,
            "Malformed status frames cannot dispatch or receive replies: " .. payload)
    end
    clock:incoming("1|status|" .. full("peer", 2000000000, 1, "1=25"), "Friend")
    assert(#samples == 1)
    for _, body in ipairs({ "2=20|10=%GG", "2=20|0=x", "2=20|65536=x", "2=20|10|10=bad" }) do
        assert(not receive(current, "Friend", full("malformed-session", 9999999999, 999999999, body)))
        clock:incoming("1|status|" .. full("malformed-session", 9999999999, 999999999, body), "Friend")
        assert(#samples == 1,
            "Malformed later IDs cannot partially dispatch or poison sender ordering")
    end
    clock:incoming("1|status|" .. full("peer", 2000000005, 2, "1=25|2=20"), "Friend")
    assert(#samples == 2 and samples[2].fields.level == "25" and samples[2].fields.xp == "20")
end

-- A provider with no initial sample stays quiet. Once it had a sample, becoming
-- unavailable sends an empty complete snapshot instead of retaining stale data.
do
    local current, clock = newAddon()
    local values, marker = nil, {}
    clock.environment.issecretvalue = function(value) return rawequal(value, marker) end
    assert(current:RegisterDataStatusProvider("unsafe", function() return values end, function() end))
    clock:login(); clock:connect()
    for _, invalid in ipairs({ marker, { xpState = marker }, { [marker] = "secret" },
        { xpState = 0 / 0 }, { xpState = "bad\nvalue" } }) do
        values = invalid
        clock:advance(5)
        assert(#clock.sent == 0)
    end
    values = { burned = 0 }
    clock:advance(5)
    assert(#clock.sent == 1 and clock.sent[1].message:find("12=0", 1, true))
    values = nil
    clock:advance(5)
    assert(#clock.sent == 2 and clock.sent[2].message:match("|5|F|[^|]+|%d+|2|$"))
end

-- Initial failures retry at the five-second cadence; reconnecting resets peer
-- state and starts a fresh join request. Logout cancels all scheduled work.
do
    local values = { xp = 1 }
    local current, clock, _, connections = statusFixture(values, false)
    assert(#clock.sent == 1 and next(current.dataState.pendingRequests) == nil)
    for _ = 1, 10 do current:DataStatusTick() end
    assert(#clock.sent == 1)
    values.xp = 2
    clock:advance(5)
    assert(#clock.sent == 2 and clock.sent[2].message:find("2=2", 1, true))
    clock:disconnect()
    assert(not connections[#connections])
    clock:connect()
    assert(#clock.sent == 3 and clock.sent[3].message:match("^1|Q|status|") and connections[#connections])
    assert(receive(current, "Friend", full("peer", 2000000000, 1, "2=7")))
    clock:disconnect(); clock:connect()
    assert(receive(current, "Friend", full("peer", 2000000000, 1, "2=8")))
    clock:fire("PLAYER_LOGOUT")
    local sent = #clock.sent
    clock:advance(60)
    assert(#clock.sent == sent and clock:activeTimers() == 0)
end

-- Real roster fields share complete native status snapshots; periodic refreshes
-- preserve presence without resetting the age of an unchanged XP sample.
do
    local bus = newRequestBus()
    for index, client in ipairs(bus.clients) do
        local clock, environment = client.world, client.world.environment
        clock.level, clock.xp, clock.xpMax = 24, 100 * index, 1000
        environment.UnitLevel = function(unit) assert(unit == "player"); return clock.level end
        environment.UnitXP = function(unit) assert(unit == "player"); return clock.xp end
        environment.UnitXPMax = function(unit) assert(unit == "player"); return clock.xpMax end
        environment.GetMaxPlayerLevel = function() return 60 end
        loadModule("Roster.lua", client.addon, environment)
        client.addon:InitializeRoster()
        client.addon:OnRosterLogin()
    end
    bus:pump()
    local alice, bob = bus.clients[1], bus.clients[2]
    local function player(client, name)
        for _, row in ipairs(client.addon:GetOverviewPlayers()) do
            if row.id == name:lower() .. "-testrealm" then return row end
        end
        error("Missing discovered player " .. name)
    end
    for _, client in ipairs(bus.clients) do
        assert(#client.addon:GetOverviewPlayers() == 3)
        for index, other in ipairs(bus.clients) do
            local row = player(client, other.name)
            assert(row.level == 24 and row.xp == 100 * index and row.xpMax == 1000
                and row.xpState == "known" and row.online and not row.xpStale)
        end
    end
    local function counts(client)
        local snapshots = 0
        for _, packet in ipairs(client.world.nativeSends) do
            assert(#packet.message <= 255 and not packet.message:match("^1|[QR]?|?roster|"))
            if packet.message:match("^1|status|5|F|") then snapshots = snapshots + 1 end
        end
        return snapshots
    end
    assert(counts(alice) == 0)
    assert(alice.addon:RegisterDataStatusProvider("activity", function() return {} end, function() end))
    alice.world.xp = 420
    alice.world:fire("PLAYER_XP_UPDATE", "player")
    assert(player(alice, "Alice").xp == 420 and player(bob, "Alice").xp == 100)
    alice.world:advance(4); bus:pump(); assert(counts(alice) == 0)
    alice.world:advance(1); bus:pump()
    assert(counts(alice) == 1 and player(bob, "Alice").xp == 420 and not alice.addon.dataState.features.activity)
    local xpStamp = assert(bob.addon.rosterState.progress["alice-testrealm"].xpUpdatedAt)
    alice.world:advance(30); bus:pump()
    assert(counts(alice) == 2 and not player(bob, "Alice").xpStale
        and bob.addon.rosterState.progress["alice-testrealm"].xpUpdatedAt == xpStamp)
    alice.world.level, alice.world.xp, alice.world.xpMax = 25, 0, 1200
    alice.world:fire("PLAYER_LEVEL_UP", 25)
    alice.world:fire("PLAYER_XP_UPDATE", "player")
    bus:pump()
    assert(player(bob, "Alice").level == 24 and player(bob, "Alice").xp == 420,
        "Level and XP wait for the same coherent shared status update")
    alice.world:advance(5); bus:pump()
    assert(player(bob, "Alice").level == 25 and player(bob, "Alice").xp == 0
        and player(bob, "Alice").xpMax == 1200 and counts(alice) == 3)
    alice.world:disconnect()
    assert(#alice.addon:GetOverviewPlayers() == 0 and alice.addon.rosterState.progress["bob-testrealm"].disconnected,
        "Losing all native audiences hides retained peers and marks their progress stale")
    alice.world:connect()
    assert(player(alice, "Bob").xp == 200 and player(alice, "Bob").xpStale,
        "Reconnect keeps the last reported XP stale until the shared status response arrives")
    bus:pump()
    assert(player(alice, "Bob").xp == 200 and not player(alice, "Bob").xpStale)
end

-- Burned reports ride the shared snapshots, include the local value exactly
-- once, and never interpret an older client's omitted field as a zero.
do
    local bus = newRequestBus(function(client)
        client.addon.db.burned = { status = ({ Alice = 30, Bob = 60, Carol = 90 })[client.name] }
        client.world.party = true
        for _, name in ipairs({ "Alice", "Bob", "Carol" }) do
            if name ~= client.name then table.insert(client.world.groupMembers, { name = name, realm = "Test Realm" }) end
        end
        loadModule("Roster.lua", client.addon, client.world.environment)
        loadModule("Burned.lua", client.addon, client.world.environment)
        client.addon:InitializeBurned()
    end)
    bus:pump()
    local alice, bob = bus.clients[1], bus.clients[2]
    for _, client in ipairs(bus.clients) do
        local mean = client.addon:GetGroupBurnedStatus()
        assert(mean.count == 3 and mean.average == 60,
            "Native request/reply echoes must not double-count the local character")
        for _, packet in ipairs(client.world.nativeSends) do
            assert(#packet.message <= 255 and packet.message:find("|12=", 1, true),
                "Burned status uses field 12 within ordinary bounded player snapshots")
        end
    end
    local changes = 0
    alice.addon:RegisterNotification("BURNED_CHANGED", function() changes = changes + 1 end)
    local sends = #alice.world.nativeSends
    assert(alice.addon:SetBurnedStatus(80) and not alice.addon:SetBurnedStatus(31.4))
    assert(alice.addon:GetGroupBurnedStatus().average == 230 / 3)
    alice.world:advance(4); bus:pump()
    assert(#alice.world.nativeSends == sends and bob.addon:GetGroupBurnedStatus().average == 60)
    alice.world:advance(1); bus:pump()
    assert(#alice.world.nativeSends == sends + 1 and bob.addon:GetGroupBurnedStatus().average == 230 / 3,
        "An accepted edit uses the five-second status cadence; rejected edits cannot replace it")
    alice.world:advance(84.9)
    assert(alice.addon:GetGroupBurnedStatus().count == 3)
    local beforeExpiry = changes
    alice.world:advance(0.1)
    local mean = alice.addon:GetGroupBurnedStatus()
    assert(mean.count == 1 and mean.average == 80 and changes > beforeExpiry,
        "Unrefreshed peers expire after 90 seconds and notify the meter without new packets")
    assert(receive(alice.addon, "Friend", full("friend", 2000000090, 1, "12=20")))
    assert(alice.addon:GetGroupBurnedStatus().count == 1, "A guildmate outside the native group cannot report Burned")
    alice.world.groupMembers = { { name = "Friend", realm = "Test Realm" } }
    alice.world:fire("GROUP_ROSTER_UPDATE")
    assert(alice.addon:GetGroupBurnedStatus().count == 1, "Joining a group cannot reuse an out-of-group report")
    assert(receive(alice.addon, "Friend", full("friend", 2000000090, 2, "12=20")))
    assert(alice.addon:GetGroupBurnedStatus().average == 50)
    local revision = 2
    for _, body in ipairs({ "1=24", "12=101", "12=-1", "12=1.5", "12=nan", "12=" }) do
        revision = revision + 1
        assert(receive(alice.addon, "Friend", full("friend", 2000000090, revision, body)))
        assert(alice.addon:GetGroupBurnedStatus().count == 1,
            "Missing and invalid values must withdraw a peer's old contribution")
        revision = revision + 1
        assert(receive(alice.addon, "Friend", full("friend", 2000000090, revision, "12=20")))
    end
    assert(not receive(alice.addon, "Friend", full("friend", 2000000090, 1, "12=100")))
    assert(alice.addon:GetGroupBurnedStatus().average == 50,
        "An old status revision cannot overwrite a current burned report")
    alice.world.groupMembers = { { name = "Friend", realm = "Other Realm" } }
    alice.world:fire("GROUP_ROSTER_UPDATE")
    assert(alice.addon:IsDataConnected() and alice.addon:GetGroupBurnedStatus().count == 1
        and next(alice.addon.burnedState.peers) == nil,
        "Replacing a member with the same first name on another realm prunes the previous report")
    alice.world.groupMembers = { { name = "Friend", realm = "Test Realm" } }
    alice.world:fire("GROUP_ROSTER_UPDATE")
    assert(alice.addon:GetGroupBurnedStatus().count == 1, "Returning members must report again")
    assert(receive(alice.addon, "Friend", full("friend", 2000000091, revision, "12=20")))
    assert(alice.addon:GetGroupBurnedStatus().average == 50)
    alice.world:disconnect()
    assert(alice.addon:GetGroupBurnedStatus().average == nil
        and alice.addon:GetGroupBurnedStatus().count == 0 and next(alice.addon.burnedState.peers) == nil)
    alice.world:connect()
    assert(alice.addon:GetGroupBurnedStatus().average == 80 and alice.addon:GetGroupBurnedStatus().count == 1,
        "Reconnect waits for fresh remote values while retaining the personal setting")
    assert(receive(alice.addon, "Friend", full("friend-new", 2000000090, 1, "12=20")))
    alice.world:fire("PLAYER_LOGOUT")
    alice.world:advance(100)
    assert(alice.addon:GetGroupBurnedStatus().count == 0 and alice.world:activeTimers() == 0,
        "Logout cancels presence expiry and transport work")
end

-- Burned follows current native group membership and the account preference;
-- ordinary status continues across both changes on the same guild route.
do
    local current, clock = newAddon({ burned = { status = 40, changeAvailableAt = 2000000300 } }, false,
        { compact = true, groupMembers = { { name = "Friend", realm = "Test Realm" } } })
    loadModule("Roster.lua", current, clock.environment)
    loadModule("Burned.lua", current, clock.environment)
    local values, samples = { level = 24, xp = 40, xpMax = 100, xpState = "known" }, {}
    current:InitializeBurned()
    assert(current:RegisterDataStatusProvider("player", function() return values end,
        function(_, fields) samples[#samples + 1] = fields end))
    clock:login()
    local discovery = clock.sent[1].message
    assert(current:GetBurnedEnabled() and not discovery:find("|12=", 1, true)
        and discovery:find("|1=24|2=40|3=100|4=1", 1, true)
        and current:GetGroupBurnedStatus().count == 0, "Solo guild status includes XP fields without Burned")
    assert(receive(current, "Friend", full("friend", 2000000000, 1, "1=25|12=80")))
    assert(current:GetGroupBurnedStatus().count == 0 and samples[1].level == "25")

    clock.party = true
    clock:fire("GROUP_ROSTER_UPDATE")
    assert(current:GetGroupBurnedStatus().count == 1 and current:GetGroupBurnedStatus().average == 40)
    clock:advance(5)
    local function lastFields()
        local packet = clock.sent[#clock.sent]
        assert(packet.prefix == "LITG" and packet.distribution == "GUILD")
        return assert(current:DecodeFriendsStatus(packet.message)).fields
    end
    assert(lastFields()[12] == "40" and lastFields()[1] == "24")
    assert(receive(current, "Friend", full("friend", 2000000005, 2, "1=26|12=80")))
    assert(current:GetGroupBurnedStatus().count == 2 and current:GetGroupBurnedStatus().average == 60)

    local deadline = current.db.burned.changeAvailableAt
    assert(current:SetBurnedEnabled(false) and not current:GetBurnedEnabled() and current.db.burned.enabled == false)
    assert(current:GetGroupBurnedStatus().count == 0 and next(current.burnedState.peers) == nil
        and not current:SetBurnedStatus(70) and current:GetBurnedStatus() == 40 and current:GetBurnedStatusCooldown() == 295)
    assert(receive(current, "Friend", full("friend", 2000000005, 3, "1=27|12=90")))
    assert(samples[#samples].level == "27" and next(current.burnedState.peers) == nil,
        "Disabled Burned ignores the report without dropping a peer's other fields")
    values.xp = 65
    clock:advance(5)
    assert(lastFields()[12] == nil and lastFields()[2] == "65")

    assert(current:SetBurnedEnabled(true) and current:GetGroupBurnedStatus().count == 1
        and current.db.burned.changeAvailableAt == deadline and current:GetBurnedStatusCooldown() == 290)
    assert(not receive(current, "Friend", full("friend", 2000000005, 3, "1=27|12=90"))
        and current:GetGroupBurnedStatus().count == 1, "Re-enabling does not replay a report heard while disabled")
    assert(receive(current, "Friend", full("friend", 2000000010, 4, "1=27|12=70")))
    assert(current:GetGroupBurnedStatus().count == 2 and current:GetGroupBurnedStatus().average == 55)
    clock:advance(5)
    assert(lastFields()[12] == "40")
    clock.party = false
    clock:fire("GROUP_ROSTER_UPDATE")
    assert(current:IsDataConnected() and current:GetGroupBurnedStatus().count == 0)
    clock:advance(5)
    assert(lastFields()[12] == nil and lastFields()[2] == "65", "Leaving the group withdraws only Burned")
end

-- Turning Burned off withdraws a direct snapshot still waiting in the paced queue.
do
    local peer = { id = "bob-fern", name = "Bob-Fern", gameAccountID = 42 }
    local current, clock = newAddon({ burned = { status = 40 } }, false, {
        guild = false, party = true, friends = { [peer.id] = peer },
        groupMembers = { { name = "Bob Fern", realm = "Test Realm" } },
    })
    loadModule("Roster.lua", current, clock.environment)
    loadModule("Burned.lua", current, clock.environment)
    current:InitializeBurned()
    local values = { level = 24, xp = 40, xpMax = 100, xpState = "known" }
    assert(current:RegisterDataStatusProvider("player", function() return values end, function() end))
    clock:login()
    clock:advance(0.5)
    assert(#clock.sent == 1 and clock.sent[1].message == "1|H")
    clock:incomingFriend("1|A", 42)
    local queued = current.dataState.friendOutbox[1]
    local fields = assert(queued and current:DecodeFriendsStatus(queued.message)).fields
    assert(fields[12] == "40" and fields[2] == "40" and #clock.sent == 1)

    assert(current:SetBurnedEnabled(false))
    values.xp = 65
    clock:advance(10)
    assert(#clock.sent == 1, "Disabling Burned withdraws the queued snapshot and retains the Friends send cadence")
    clock:advance(0.5)
    local packet = clock.sent[2]
    assert(#clock.sent == 2 and packet.at == 11 and packet.prefix == "LITF"
        and packet.distribution == "BATTLENET" and packet.target == 42)
    fields = assert(current:DecodeFriendsStatus(packet.message)).fields
    assert(fields[12] == nil and fields[2] == "65", "The next Friends snapshot carries fresh XP without Burned")
end

-- Personal edit cooldowns do not delay discovery, accepted edit delivery, or
-- idle status heartbeats carrying the same saved Burned value.
do
    local current, clock = newAddon(nil, false, { guild = true, party = true })
    loadModule("Roster.lua", current, clock.environment)
    loadModule("Burned.lua", current, clock.environment)
    current:InitializeBurned()
    clock:login()
    assert(#clock.sent == 1 and clock.sent[1].message:find("|12=0", 1, true))
    assert(current:SetBurnedStatus(80) and #clock.sent == 1)
    local deadline = current.db.burned.changeAvailableAt
    clock:advance(4)
    assert(not current:SetBurnedStatus(20) and current:SetBurnedStatus(80)
        and not current:SetBurnedStatus("bad") and #clock.sent == 1
        and current.db.burned.changeAvailableAt == deadline)
    clock:advance(1)
    assert(#clock.sent == 2 and clock.sent[2].message:find("|12=80", 1, true)
        and current:GetBurnedStatusCooldown() == 295)
    clock:advance(30)
    assert(#clock.sent == 3 and clock.sent[3].message:find("|12=80", 1, true)
        and current:GetBurnedStatusCooldown() == 265,
        "The unchanged personal status keeps its normal 30-second heartbeat during cooldown")
end

-- Diagnostics describe the native failure without exposing payloads or exception text.
-- A route remains eligible for receives and retries while its outgoing sends fail.
do
    local profile = { schemaVersion = 4,
        data = { channels = { party = false, guild = true } } }
    local current, clock = newAddon(profile, false, { guild = true })
    assert(current:RegisterDataFeature("echo", function() end))
    clock:login()
    local notices = 0
    current:RegisterNotification("DATA_CHANGED", function() notices = notices + 1 end)
    local private = "private payload must never appear in status"
    clock.sendResult = 11
    assert(not current:SendData("echo", private) and current:IsDataConnected())
    local status = current:GetDataStatusText()
    assert(status:find("Send failures: legacy guild", 1, true) and status:find("AddOnMessageLockdown", 1, true)
        and status:find("11", 1, true) and not status:find(private, 1, true),
        "Status reports rejected guild messages even though membership remains active")
    assert(notices == 1)
    assert(not current:SendData("echo", private) and notices == 1,
        "Repeated identical failures do not repeatedly notify the interface")
    clock.sendResult = 10
    assert(not current:SendData("echo", private))
    assert(current:GetDataSendStatusText():find("NotInGuild, code 10", 1, true) and notices == 2)
    clock.sendResult = 777
    assert(not current:SendData("echo", private))
    assert(current:GetDataSendStatusText():find("code 777", 1, true) and notices == 3,
        "Unknown native numeric results remain diagnosable")
    clock.sendThrows, clock.sendError = true, private
    assert(not current:SendData("echo", private))
    assert(current:GetDataSendStatusText():find("native API error", 1, true)
        and not current:GetDataSendStatusText():find(private, 1, true) and notices == 4)
    local secret = {}
    clock.sendThrows, clock.sendResult = false, secret
    clock.environment.issecretvalue = function(value) return rawequal(value, secret) end
    assert(not current:SendData("echo", private))
    assert(current:GetDataSendStatusText():find("native result unavailable", 1, true) and notices == 5)
    clock.sendResult = private
    assert(not current:SendData("echo", private))
    assert(not current:GetDataSendStatusText():find(private, 1, true) and notices == 5,
        "Unexpected strings and secret native results are never displayed")
    clock.sendResult = 0
    assert(current:SendData("echo", private) and current:GetDataSendStatusText() == ""
        and not current:GetDataStatusText():find("Send failures:", 1, true) and notices == 6,
        "Successful recovery clears status and notifies the interface once")
    clock.sendResult = 11
    assert(not current:SendData("echo", private))
    assert(current:SetDataChannelEnabled("guild", false) and not current:IsDataConnected())
    assert(current:GetDataSendStatusText() == "" and not current:GetDataStatusText():find("Send failures:", 1, true),
        "Disabling a route clears its obsolete failure instead of carrying it into another session")
end


-- Guild works without a key and accepts only GUILD distribution.
do
    local current, clock = newAddon(nil, false, { guild = true, party = true })
    local received = 0
    assert(current:RegisterDataFeature("echo", function() received = received + 1 end))
    assert(not current:HasDataGroup() or not current:IsDataConnected())
    clock:login()
    assert(current:IsDataConnected() and current:HasDataGroup() and current.dataState.routes.GUILD)
    assert(current:SendData("echo", "native") and #clock.sent == 1
        and clock.sent[1].distribution == "GUILD")
    assert(current:ReceiveData("Friend", "1|echo|native", "GUILD") and received == 1)
    for _, route in ipairs({ "PARTY", "RAID", "CHANNEL", "WHISPER" }) do
        assert(not current:ReceiveData("Friend", "1|echo|retired", route) and received == 1)
    end
    assert(current:GetDataStatusText():match("^Data routes: guild%."))
    assert(not current:GetDataChannelEnabled("global") and not current:SetDataChannelEnabled("global", true))
    clock:advance(60)
    assert(clock:activeTimers() == 0, "A native connection needs no transport watchdog")
end

-- Party and raid changes preserve guild request caches and cannot maintain a connection alone.
do
    local current, clock = newAddon(nil, false, { party = true, guild = true })
    local notices = {}
    current:RegisterDataFeature("echo", function() end, function(connected) notices[#notices + 1] = connected end)
    current:RegisterDataRequest("snapshot", function() return "own" end, function() end)
    clock:login()
    local _, id = current:RequestData("snapshot", "pending")
    assert(current:ReceiveData("Friend", "1|Q|snapshot|peer|", "GUILD"))
    local pending, replied, count = current.dataState.pendingRequests, current.dataState.repliedRequests, #notices
    clock.party, clock.raid = false, true
    clock:fire("GROUP_ROSTER_UPDATE")
    assert(current.dataState.routes.GUILD and not current.dataState.routes.RAID and not current.dataState.routes.PARTY)
    assert(current.dataState.pendingRequests == pending and pending[id]
        and current.dataState.repliedRequests == replied and next(replied) and #notices == count)
    clock.guild = false
    clock:fire("PLAYER_GUILD_UPDATE", "player")
    assert(not current:IsDataConnected() and clock.raid and #notices == count + 1 and notices[#notices] == false
        and next(current.dataState.pendingRequests) == nil and next(current.dataState.repliedRequests) == nil)
    clock.guild = true
    clock:fire("PLAYER_ENTERING_WORLD")
    assert(current:IsDataConnected() and current.dataState.routes.GUILD)
    clock:fire("PLAYER_LOGOUT")
    clock:fire("PLAYER_GUILD_UPDATE", "player")
    assert(not current:IsDataConnected() and not current:SendData("echo", "after logout"))
end

-- Sending rechecks membership even before the native roster event arrives.
do
    local current, clock = newAddon(nil, false, { guild = true, party = true })
    current:RegisterDataFeature("echo", function() end)
    current:RegisterDataRequest("snapshot", function() return "own" end, function() end)
    clock:login()
    local accepted, id = current:RequestData("snapshot", "pending")
    assert(accepted and current.dataState.pendingRequests[id])
    clock.party, clock.raid = false, true
    local before = #clock.sendAttempts
    assert(current:SendData("echo", "guild before roster update")
        and #clock.sendAttempts == before + 1
        and clock.sendAttempts[#clock.sendAttempts].distribution == "GUILD"
        and current.dataState.routes.GUILD and not current.dataState.routes.RAID
        and current.dataState.pendingRequests[id],
        "A send follows guild membership while retaining its live request cache")
    clock.guild = false
    before = #clock.sendAttempts
    assert(not current:SendData("echo", "left before roster update")
        and #clock.sendAttempts == before and not current:IsDataConnected()
        and next(current.dataState.routes) == nil and next(current.dataState.pendingRequests) == nil,
        "Losing the final membership disconnects before attempting the native send")
end

-- Guild requests deduplicate repeated frames while streams retain their receive semantics.
do
    local current, clock = newAddon(nil, false, { guild = true })
    local receives, requests, responses = 0, 0, 0
    current:RegisterDataFeature("echo", function() receives = receives + 1 end)
    current:RegisterDataRequest("snapshot", function() requests = requests + 1; return "own" end,
        function() responses = responses + 1 end)
    clock:login()
    local before = #clock.sendAttempts
    local accepted, id = current:RequestData("snapshot", "shared")
    assert(accepted and #clock.sendAttempts == before + 1 and current:GetDataSendStatusText() == "")
    assert(clock.sendAttempts[before + 1].message == "1|Q|snapshot|" .. id .. "|shared")
    local first = true
    for _ = 1, 2 do
        assert(current:ReceiveData("Friend", "1|R|snapshot|" .. id .. "|self-testrealm|answer") == first)
        assert(current:ReceiveData("Friend", "1|Q|snapshot|peer-overlap|") == first)
        assert(current:ReceiveData("Friend", "1|echo|feature duplicate"))
        first = false
    end
    assert(responses == 1 and requests == 1 and receives == 2,
        "Duplicate requests and replies dispatch once; streaming features keep their own receive semantics")
end

-- The guild switch governs sends and receives independently of gameplay groups.
do
    local current, clock = newAddon({ data = { channels = { party = false, guild = true, friends = false } } }, false,
        { guild = true, raid = true })
    current:RegisterDataFeature("echo", function() end)
    clock:login()
    assert(current.dataState.routes.GUILD and not current.dataState.routes.RAID)
    assert(not current:ReceiveData("Friend", "1|echo|disabled", "RAID"))
    assert(current:SetDataChannelEnabled("guild", false) and not current:IsDataConnected())
    assert(current:GetDataStatusText() == "All data channels are disabled.")
    assert(not current:SetDataChannelEnabled("party", true) and not current:IsDataConnected()
        and not current:SendData("echo", "raid") and #clock.sent == 0)
    assert(not current:SetDataChannelEnabled("party", "yes") and not current:SetDataChannelEnabled("raid", true))
    clock:fire("PLAYER_LOGOUT")
    local sends = #clock.sent
    assert(current:SetDataChannelEnabled("guild", true))
    clock:advance(60)
    assert(not current:IsDataConnected() and #clock.sent == sends)
end

-- Native group changes do not trigger guild discovery or replace the status session.
do
    local current, clock = statusFixture({ level = 24 }, true, { guild = true })
    local status, pending, before = current.dataState.status, current.dataState.pendingRequests, #clock.sent
    local session = status.session
    clock.party = true
    clock:fire("GROUP_ROSTER_UPDATE")
    clock:advance(5)
    assert(status.session == session and current.dataState.pendingRequests == pending)
    assert(#clock.sent == before)
end

-- A modern client discovers legacy guild peers first and responds in the
-- format received from a client whose legacy prefix is unavailable.
do
    local function client(name, level, compact, refused)
        return statusFixture({ level = level }, true, { playerName = name, guild = true, compact = compact,
            configure = function(_, world)
                if refused then world.prefixResults = { [refused] = 2 } end
            end })
    end
    local current, clock, samples = client("Alice", 24, true)
    local old, oldClock, oldSamples = client("Bob", 25, false)
    local compactOnly, compactClock, compactSamples = client("Carol", 26, true, "LockInToolsData")
    local oldPrefix, compactPrefix = current:GetDataPrefix(), current:GetCompactGuildDataPrefix()
    local function packetOn(world, prefix, pattern)
        for _, packet in ipairs(world.sent) do
            if packet.prefix == prefix and packet.message:match(pattern) then return packet end
        end
    end
    local function deliver(world, packet, sender, route)
        world:incoming(packet.message, sender, { distribution = route or "GUILD", prefix = packet.prefix })
    end
    local legacy = assert(packetOn(clock, oldPrefix, "^1|Q|status|"))
    local compact = assert(packetOn(compactClock, compactPrefix, "^Q"))
    local id, encoded = compact.message:match("^Q([^|]+)|(S.*)$")
    assert(id and assert(current:DecodeFriendsStatus(encoded)).fields[1] == "26"
        and #clock.sent == 1 and #oldClock.sent == 1 and #compactClock.sent == 1,
        "Each client sends a single discovery request on its preferred available prefix")
    assert(not old.dataState.guildCompactActive and not compactOnly.dataState.guildLegacyActive)
    assert(old:IsDataConnected() and compactOnly:IsDataConnected())
    assert(compactOnly:RegisterDataFeature("echo", function() end))
    assert(not compactOnly:SendData("echo", "legacy only"), "A compact-only guild sends status frames only")

    deliver(oldClock, compact, "Carol")
    deliver(compactClock, legacy, "Alice")
    assert(#oldSamples == 0 and #compactSamples == 0, "An unavailable guild prefix is ignored")
    deliver(oldClock, legacy, "Alice")
    assert(#oldSamples == 1 and oldSamples[1].fields.level == "24")
    local legacyReply = assert(packetOn(oldClock, oldPrefix, "^1|R|status|"))
    deliver(clock, legacyReply, "Bob")
    deliver(clock, compact, "Carol")
    local compactReply = assert(packetOn(clock, compactPrefix, "^R"))
    assert(compactReply.message:match("^R([^|]+)|") == id)
    compactClock:incoming(compactReply.message:gsub("|S.*$", "|S"), "Alice", { prefix = compactPrefix })
    assert(#compactSamples == 0, "A malformed reply does not consume the sender's response slot")
    deliver(compactClock, compactReply, "Alice")
    assert(#compactSamples == 1 and compactSamples[1].fields.level == "24")
    assert(#samples == 2 and samples[1].fields.level == "25" and samples[2].fields.level == "26",
        "A modern client exchanges full status with both guild formats")

    local carolSession = assert(current:DecodeFriendsStatus(encoded)).session
    local legacyNew = "1|status|" .. full(carolSession, 2000000005, 2, "1=27")
    local compactNew = friendsStatus(current, 2000000005, 2, { [1] = "27" }, carolSession)
    for _, route in ipairs({ "PARTY", "RAID", "CHANNEL", "WHISPER" }) do
        clock:incoming(legacyNew, "Carol", { distribution = route, prefix = oldPrefix })
        clock:incoming(compactNew, "Carol", { distribution = route, prefix = compactPrefix })
    end
    clock:incoming(legacyNew, "Carol", { prefix = compactPrefix })
    clock:incoming(compactNew, "Carol", { prefix = oldPrefix })
    clock:incoming(compactNew, "Carol", { prefix = current:GetFriendsDataPrefix() })
    assert(#samples == 2, "The native guild formats and Friends prefix are isolated from other routes")
    clock:incoming(compactNew, "Carol", { prefix = compactPrefix })
    clock:incoming(legacyNew, "Carol", { prefix = oldPrefix })
    clock:incoming(friendsStatus(current, 2000000006, 1, { [1] = "28" }, carolSession), "Carol", { prefix = compactPrefix })
    assert(#samples == 3 and samples[3].fields.level == "27", "Duplicates and older revisions cannot overwrite status")

    local before = #clock.sent
    clock:incoming("Qfallback|S", "Bob", { prefix = compactPrefix })
    clock:incoming("1|Q|status|fallback|" .. full("bob", 2000000007, 1, "1=25"), "Bob", { prefix = oldPrefix })
    assert(#clock.sent == before + 1 and clock.sent[#clock.sent].prefix == oldPrefix
        and clock.sent[#clock.sent].message:match("^1|R|status|fallback|"),
        "A malformed compact request leaves the corresponding legacy discovery answerable")
end

-- Guild publishes at most one accepted format per tick and includes the latest
-- fields in the legacy baseline even when they change at the deadline.
do
    local values = { level = 24 }
    local current, clock = statusFixture(values, true, { compact = true, guild = true })
    local legacy, compact = current:GetDataPrefix(), current:GetCompactGuildDataPrefix()
    local _, oldClock, oldSamples = statusFixture({ level = 30 }, true, { playerName = "Old", guild = true })
    local _, newClock, newSamples = statusFixture({ level = 30 }, true,
        { playerName = "New", guild = true, compact = true })
    local function deliver(packet)
        oldClock:incoming(packet.message, "Self", { prefix = packet.prefix })
        newClock:incoming(packet.message, "Self", { prefix = packet.prefix })
    end
    assert(#clock.sent == 1 and clock.sent[1].prefix == legacy and clock.sent[1].at == 0
        and clock.sent[1].message:match("^1|Q|status|.*|1=24$"))
    deliver(clock.sent[1])
    assert(oldSamples[1].fields.level == "24" and newSamples[1].fields.level == "24")

    values.level = 25
    clock:advance(5)
    assert(#clock.sent == 2 and clock.sent[2].prefix == compact and clock.sent[2].at == 5
        and assert(current:DecodeFriendsStatus(clock.sent[2].message)).fields[1] == "25")
    deliver(clock.sent[2])
    assert(#oldSamples == 1 and #newSamples == 2 and newSamples[2].fields.level == "25")
    clock:advance(24)
    assert(#clock.sent == 2, "Unchanged status does not generate another guild packet before the legacy baseline")

    values.level = 26
    clock:advance(1)
    assert(#clock.sent == 3 and clock.sent[3].prefix == legacy and clock.sent[3].at == 30
        and clock.sent[3].message:match("^1|status|.*|1=26$"),
        "Legacy baseline takes priority and publishes the latest revision once")
    deliver(clock.sent[3])
    assert(#oldSamples == 2 and oldSamples[2].fields.level == "26"
        and #newSamples == 3 and newSamples[3].fields.level == "26",
        "The legacy baseline updates old and current clients to the same latest value")
    clock:advance(29)
    assert(#clock.sent == 3, "A legacy baseline covers current clients without a follow-up compact snapshot")
    clock:advance(1)
    assert(#clock.sent == 4 and clock.sent[4].prefix == legacy and clock.sent[4].at == 60
        and clock.sent[4].message:match("^1|status|.*|1=26$"))
end

-- Each format keeps the ordinary cadence when registration leaves it as the
-- only available guild prefix.
for _, prefix in ipairs({ "LockInToolsData", "LITG" }) do
    local values = { level = 24 }
    local other = prefix == "LITG" and "LockInToolsData" or "LITG"
    local _, clock = statusFixture(values, true, { compact = true, guild = true,
        configure = function(_, world) world.prefixResults = { [other] = 2 } end,
    })
    assert(#clock.sent == 1 and clock.sent[1].prefix == prefix and clock.sent[1].at == 0)
    values.level = 25
    clock:advance(34)
    assert(#clock.sent == 2 and clock.sent[2].prefix == prefix and clock.sent[2].at == 5)
    clock:advance(1)
    assert(#clock.sent == 3 and clock.sent[3].prefix == prefix and clock.sent[3].at == 35,
        "A single guild format refreshes after thirty seconds without change")
end

do
    local _, clock = statusFixture({ level = 24 }, true, { compact = true, guild = true,
        configure = function(_, world) world.prefixResults = { LockInToolsData = 2 } end,
    })
    assert(#clock.sent == 1 and clock.sent[1].prefix == "LITG" and clock.sent[1].message:match("^Q"))
    clock.prefixResults.LockInToolsData = 0
    clock:advance(35)
    assert(#clock.sent == 2 and clock.sent[2].prefix == "LockInToolsData"
        and clock.sent[2].message:match("^1|status|.*|1=24$"),
        "A recovered legacy prefix publishes a baseline without repeating discovery")
end

-- Prefix failures retry once per interval; disabling every route cancels work.
do
    local peer = { id = "bob-fern", name = "Bob-Fern", gameAccountID = 42 }
    local current, clock = newAddon(nil, false, { guild = true, compact = true, friends = { [peer.id] = peer } })
    local groupPrefix, friendsPrefix = current:GetDataPrefix(), current:GetFriendsDataPrefix()
    assert(current:RegisterDataFeature("echo", function() end))
    clock.prefixResults = { [friendsPrefix] = 2 }
    clock:login()
    assert(current:IsDataConnected() and current.dataState.routes.GUILD and not current.dataState.routes.FRIENDS,
        "A refused Friends prefix leaves guild operational")
    clock:incomingFriend("1|H", 42)
    assert(current:SendData("echo", "native") and #clock.sent == 1 and clock.sent[1].prefix == groupPrefix)
    clock:advance(29)
    assert(#clock.sent == 1 and #clock.prefixCalls == 3)
    clock.prefixResults[friendsPrefix] = 1
    clock:advance(2)
    assert(#clock.prefixCalls == 4 and clock.prefixCalls[4] == friendsPrefix
        and #clock.sent == 2 and clock.sent[2].prefix == friendsPrefix and clock.sent[2].message == "1|H",
        "A retry registers and uses only the previously refused prefix")
    clock:incomingFriend("1|A", 42)
    assert(current.dataState.routes.FRIENDS, "Friends connect after their own registration recovers")
end

-- A failed legacy discovery may still publish to current peers, without a
-- second discovery. The legacy request stays due until it succeeds.
do
    local current, clock = statusFixture({ level = 24 }, true, { compact = true, guild = true,
        configure = function(_, world) world.prefixSendResults = { LockInToolsData = 11 } end,
    })
    assert(current:IsDataConnected() and #clock.sendAttempts == 2
        and clock.sendAttempts[1].prefix == "LockInToolsData" and clock.sendAttempts[1].message:match("^1|Q|status|")
        and clock.sendAttempts[2].prefix == "LITG" and clock.sendAttempts[2].message:match("^S")
        and next(current.dataState.pendingRequests) == nil)
    clock.prefixSendResults.LockInToolsData = 0
    clock:advance(5)
    assert(#clock.sendAttempts == 3 and clock.sendAttempts[3].prefix == "LockInToolsData"
        and clock.sendAttempts[3].message:match("^1|Q|status|") and next(current.dataState.pendingRequests)
        and current:GetDataSendStatusText() == "", "Legacy discovery retries at the next eligible tick")
end

-- Rejected updates can fall back without two accepted copies. A failed legacy
-- baseline stays due until it succeeds.
do
    local values = { level = 24 }
    local current, clock = statusFixture(values, true, { compact = true, guild = true })
    local legacy, compact = current:GetDataPrefix(), current:GetCompactGuildDataPrefix()
    clock.prefixSendResults = { [compact] = 11 }
    values.level = 25
    clock:advance(5)
    assert(#clock.sendAttempts == 3 and clock.sendAttempts[2].prefix == compact
        and clock.sendAttempts[3].prefix == legacy and clock.sendAttempts[3].at == 5
        and current:GetDataSendStatusText():find("compact guild", 1, true),
        "A rejected compact update falls back once to legacy and reports the compact failure")
    clock.prefixSendResults = {}
    values.level = 26
    clock:advance(5)
    assert(#clock.sendAttempts == 4 and clock.sendAttempts[4].prefix == compact
        and current:GetDataSendStatusText() == "")
    clock.prefixSendResults[legacy] = 11
    clock:advance(25)
    assert(#clock.sendAttempts == 5 and clock.sendAttempts[5].prefix == legacy and clock.sendAttempts[5].at == 35
        and current:GetDataSendStatusText():find("legacy guild", 1, true),
        "A rejected legacy baseline does not re-send already-current compact status")
    clock.prefixSendResults[legacy] = 0
    clock:advance(5)
    assert(#clock.sendAttempts == 6 and clock.sendAttempts[6].prefix == legacy and clock.sendAttempts[6].at == 40
        and current:GetDataSendStatusText() == "", "The failed legacy baseline retries on the next eligible tick")
    clock.prefixSendResults[legacy] = 11
    clock:advance(25)
    values.level = 27
    clock:advance(5)
    assert(#clock.sendAttempts == 8 and clock.sendAttempts[7].prefix == legacy
        and clock.sendAttempts[8].prefix == compact and clock.sendAttempts[8].at == 70
        and assert(current:DecodeFriendsStatus(clock.sendAttempts[8].message)).fields[1] == "27",
        "A rejected legacy baseline can publish changed status once over compact")
end

for _, failure in ipairs({ "reject", "throw" }) do
    local current, clock = newAddon({ data = { channels = { friends = false } } }, false, { compact = true })
    clock.prefixResult, clock.prefixThrows = 2, failure == "throw"
    clock:login()
    assert(not current:IsDataConnected() and clock:activeTimers(true) == 1)
    for _ = 1, 20 do clock:fire("GROUP_ROSTER_UPDATE"); clock:fire("PLAYER_ENTERING_WORLD") end
    clock:advance(29)
    assert(#clock.prefixCalls == 2 and clock:activeTimers(true) == 1)
    clock:advance(1)
    assert(#clock.prefixCalls == 4 and clock:activeTimers(true) == 1)
    assert(current:SetDataChannelEnabled("guild", false))
    assert(clock:activeTimers(true) == 0)
    clock.prefixResult, clock.prefixThrows = 1, false
    assert(current:SetDataChannelEnabled("guild", true) and current:IsDataConnected()
        and clock:activeTimers(true) == 0, "A duplicate registered prefix is reusable")
end

do
    local current, clock = newAddon(nil, false, { configure = function(environment)
        environment.C_ChatInfo.SendAddonMessage = false
    end })
    clock:login()
    assert(not current:IsDataConnected() and current:GetDataStatusText() == "The native addon messaging API is unavailable.")
    clock.environment.C_ChatInfo.SendAddonMessage = function() return 0 end
    clock:advance(60)
    assert(not current:IsDataConnected() and #clock.prefixCalls == 0 and clock:activeTimers() == 0,
        "Native capability detection is stable for the UI session")
end

print("Data tests passed.")
