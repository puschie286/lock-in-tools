-- Standalone probe checks; this harness is never loaded by either addon.
local function loadModule(file, addon, environment)
    local chunk, problem
    if setfenv then
        chunk, problem = loadfile(file)
        assert(chunk, problem)
        setfenv(chunk, environment)
    else
        chunk, problem = loadfile(file, "t", environment)
        assert(chunk, problem)
    end
    chunk("LockInToolsPositionProbe", addon)
end

local function newProbe(saved, flags)
    flags = flags or {}
    local world = {
        now = 0, epoch = 2000000000, timers = {}, messages = {},
        joins = {}, leaves = {}, sends = {}, selected = {}, channels = {}, listCalls = {},
        roster = {}, map = 37, x = 0.25, y = 0.75,
        sendResults = { CHANNEL = 0, WHISPER = 0 }, sendThrows = {},
        realmRestricted = flags.realmRestricted, chatLockdown = flags.chatLockdown,
    }
    local function timer(delay, callback)
        local result = { at = world.now + delay, callback = callback }
        function result:Cancel() self.cancelled = true end
        function result:IsCancelled() return self.cancelled == true end
        world.timers[#world.timers + 1] = result
        return result
    end
    local environment = setmetatable({
        bit = false, bit32 = false,
        LockInToolsDB = saved or {
            schemaVersion = 3, group = { secret = "  OTTER-4827  " },
            chat = { autoJoin = false }, showWelcome = false,
        },
        SlashCmdList = {},
        Enum = {
            SendAddonMessageResult = { Success = 0, AddOnMessageLockdown = 11 },
            RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1 },
        },
        C_Timer = { NewTimer = timer },
        issecretvalue = function(value) return world.secretValue ~= nil and value == world.secretValue end,
        GetTime = function() return world.now end,
        GetServerTime = function() return world.epoch + math.floor(world.now) end,
        time = function() return world.epoch + math.floor(world.now) end,
        UnitFullName = function(unit) assert(unit == "player"); return flags.playerName or "Self", flags.realm or "Test Realm" end,
        GetNormalizedRealmName = function() return flags.realm or "TestRealm" end,
        GetRealmName = function() return flags.realm or "Test Realm" end,
        GetBuildInfo = function() return "1.60.1", "70374", "Oct 2026", 16001 end,
        UnitFactionGroup = function(unit) assert(unit == "player"); return "Alliance" end,
        UnitName = function(unit) assert(unit == "player"); return "Self", "Test Realm" end,
        IsLoggedIn = function() return true end,
        JoinTemporaryChannel = function(name, password)
            assert(type(name) == "string" and type(password) == "string")
            world.joins[#world.joins + 1] = { name = name, password = password }
            return 0, name -- A join request does not synchronously supply membership.
        end,
        LeaveChannelByName = function(name)
            world.leaves[#world.leaves + 1] = name
            world.channels[name:lower()] = nil
        end,
        GetChannelName = function(identifier)
            if type(identifier) == "string" then
                local channel = world.channels[identifier:lower()]
                if channel then return channel.id, channel.name end
            else
                for _, channel in pairs(world.channels) do
                    if channel.id == identifier then return channel.id, channel.name end
                end
            end
            return 0, nil
        end,
        GetNumDisplayChannels = function() return #world.roster end,
        GetChannelDisplayInfo = function(index)
            local channel = assert(world.roster[index], "Use a display index, not a channel number")
            return channel.name, channel.header == true, false, channel.id,
                #(channel.members or {}), true, "CHANNEL_CATEGORY_CUSTOM"
        end,
        SetSelectedDisplayChannel = function(index)
            assert(world.roster[index], "Select an existing display row")
            world.selected[#world.selected + 1] = index
            if world.selectionThrows then error("Native selection unavailable") end
            world.nativeSelectedIndex = index
            if world.onSelect then world.onSelect(index) end
        end,
        C_Map = {
            GetBestMapForUnit = function(unit) assert(unit == "player"); return world.map end,
            GetPlayerMapPosition = function(map, unit)
                assert(map == world.map and unit == "player")
                if world.x == nil or world.y == nil then return nil end
                return { GetXY = function() return world.x, world.y end }
            end,
        },
        DEFAULT_CHAT_FRAME = { AddMessage = function(_, text)
            world.messages[#world.messages + 1] = text
        end },
        CreateFrame = function(kind)
            assert(kind == "Frame")
            local frame = { events = {} }
            function frame:RegisterEvent(event) self.events[event] = true end
            function frame:UnregisterEvent(event) self.events[event] = nil end
            function frame:SetScript(script, callback)
                assert(script == "OnEvent")
                self.callback = callback
            end
            world.frame = frame
            return frame
        end,
    }, { __index = _G })
    environment._G = environment
    environment.C_ChatInfo = {
        RegisterAddonMessagePrefix = function(prefix)
            local alreadyRegistered = world.prefix == prefix
            world.prefix = prefix
            return alreadyRegistered and 1 or 0
        end,
        SendAddonMessage = function(prefix, body, channel, target)
            assert(channel == "WHISPER" or channel == "CHANNEL")
            if channel == "CHANNEL" then
                local joined = world.channels[world.probe.state.channel:lower()]
                assert(joined and target == tostring(joined.id), "Broadcast to the resolved channel number")
            end
            local result = world.sendResults[channel]
            world.sends[#world.sends + 1] = {
                at = world.now, prefix = prefix, body = body, target = target, distribution = channel, result = result,
            }
            if world.sendThrows[channel] then error(world.sendThrows[channel]) end
            local loopback = world.loopback == true
                or type(world.loopback) == "table" and world.loopback[channel]
            if loopback and result == 0 then
                timer(0, function()
                    if channel == "CHANNEL" then
                        local joined = world.channels[world.probe.state.channel:lower()]
                        world.probe:OnEvent("CHAT_MSG_ADDON", prefix, body, channel,
                            world.loopbackSender or "Self-TestRealm", nil, 0, joined.id, joined.name)
                    else
                        world.probe:OnEvent("CHAT_MSG_ADDON", prefix, body, channel, world.loopbackSender or "Self-TestRealm")
                    end
                end)
            end
            return result
        end,
        GetChannelRosterInfo = function(displayIndex, rosterIndex)
            local channel = assert(world.roster[displayIndex], "Roster lookup uses the display row")
            local member = assert(channel.members[rosterIndex])
            return member, false, false, "Player-Test-" .. rosterIndex
        end,
    }
    if flags.realmRestricted ~= nil then
        environment.C_ChatInfo.AreOutgoingAddonChatMessagesRestricted = function() return world.realmRestricted end
    end
    if flags.chatLockdown ~= nil then
        environment.C_ChatInfo.InChatMessagingLockdown = function() return world.chatLockdown end
    end
    if flags.nativeName ~= nil then
        environment.NameUtil = { GetUnmodifiedUnitFullName = function(unit)
            assert(unit == "player")
            if type(flags.nativeName) == "function" then return flags.nativeName() end
            return flags.nativeName
        end }
    end
    if flags.nativeSelection then
        environment.GetSelectedDisplayChannel = function() return world.nativeSelectedIndex end
    end
    if flags.regionalNames ~= nil then
        environment.RegionalUniqueNamesEnabled = function() return flags.regionalNames end
    end
    if flags.listAPI then
        environment.ListChannelByName = function(name)
            world.listCalls[#world.listCalls + 1] = name
            if world.listThrows then error("Native chatlist unavailable") end
        end
    end
    local probe = {}
    loadModule("Crypto.lua", probe, environment)
    loadModule("Group.lua", probe, environment)
    loadModule("tools/position-probe/Probe.lua", probe, environment)
    world.probe, world.environment = probe, environment
    function world:advance(seconds)
        local target, callbacks = self.now + seconds, 0
        while true do
            local nextIndex, nextTimer
            for index, entry in ipairs(self.timers) do
                if not entry.cancelled and entry.at <= target
                    and (not nextTimer or entry.at < nextTimer.at) then
                    nextIndex, nextTimer = index, entry
                end
            end
            if not nextTimer then break end
            table.remove(self.timers, nextIndex)
            self.now, callbacks = nextTimer.at, callbacks + 1
            assert(callbacks < 100, "The probe must not create an unbounded timer loop")
            nextTimer.callback(nextTimer)
        end
        self.now = target
    end
    function world:join(members)
        local name = assert(self.joins[#self.joins]).name
        self.channels[name:lower()] = { id = 7, name = name }
        self.roster = {
            { name = "Channels", header = true },
            { name = "General", id = 1, members = { "Unrelated" } },
            { name = name, id = 7, members = members or { "Self-TestRealm", "Friend-TestRealm" } },
        }
        probe:OnEvent("CHAT_MSG_CHANNEL_NOTICE", "YOU_JOINED", name, "", "", "", "", 0, 7, name)
        probe:OnEvent("CHANNEL_ROSTER_UPDATE", 3, #self.roster[3].members)
    end
    function world:message(kind, _, sequence, extra, timestamp)
        local body = table.concat({ "LITP2", kind,
            tostring(timestamp or (self.epoch + math.floor(self.now))), tostring(sequence) }, "|")
        if extra then body = body .. "|" .. extra end
        return body
    end
    function world:receive(body, sender, prefix, distribution, metadata)
        if distribution == "CHANNEL" then
            local joined = self.channels[probe.state.channel:lower()]
            metadata = metadata or { id = joined and joined.id, name = joined and joined.name }
            probe:OnEvent("CHAT_MSG_ADDON", prefix or self.prefix, body, distribution, sender,
                nil, metadata.zone or 0, metadata.id, metadata.name)
        else
            probe:OnEvent("CHAT_MSG_ADDON", prefix or self.prefix, body, distribution or "WHISPER", sender)
        end
    end
    function world:count(kind, distribution)
        local count = 0
        for _, sent in ipairs(self.sends) do
            if sent.distribution == (distribution or "WHISPER")
                and sent.body:match("^LITP2|" .. kind .. "|") then count = count + 1 end
        end
        return count
    end
    return probe, world
end

-- Merely loading the optional probe must leave the real addon and its key alone.
local probe, world = newProbe()
local saved = world.environment.LockInToolsDB
assert(#world.joins == 0 and #world.sends == 0 and #world.timers == 0)
assert(type(world.environment.SlashCmdList.LOCKINTOOLSPOSITIONPROBE) == "function")
world.environment.SlashCmdList.LOCKINTOOLSPOSITIONPROBE("status")
assert(#world.joins == 0 and #world.sends == 0)
probe:Start()
assert(#world.joins == 1 and #world.sends == 0, "Wait for an asynchronous roster before targeting anyone")
assert(probe.state.realmRestricted == nil and probe.state.chatLockdown == nil,
    "Clients without optional messaging-status APIs can still run the diagnostic")
assert(probe.state.nativeSelfName == nil, "The optional native-name helper is not required")
assert(table.concat(world.messages, "\n"):find("realm outgoing=unknown; chat lockdown=unknown", 1, true))
assert(world.environment.LockInToolsDB == saved and saved.group.secret == "  OTTER-4827  ")
assert(saved.schemaVersion == 3 and saved.chat.autoJoin == false and saved.showWelcome == false)
assert(world.joins[1].name ~= probe:GetGroupChannelName(), "Keep probe discovery separate from shared chat")

-- Discovery needs the roster display index, which differs from channel number 7.
world:join()
probe:RequestRosterList()
assert(not probe.state.listRequested and #world.listCalls == 0, "A missing optional chatlist API leaves the diagnostic usable")
world:advance(5)
assert(world.selected[#world.selected] == 3, "Refresh the discovery roster through its display row")
assert(world:count("P") == 1, "Send the first position on the five-second tick after roster discovery")
assert(world:count("P", "CHANNEL") == 1, "Send one channel broadcast alongside the peer whisper")
for _, sent in ipairs(world.sends) do
    if sent.distribution == "WHISPER" then
        assert(sent.target:lower() == "friend-testrealm", "Never whisper unrelated channel members or self")
    end
end
local whisper, broadcast = probe.state.transports.WHISPER, probe.state.transports.CHANNEL
assert(whisper.sendErrors == 0 and broadcast.sendErrors == 0, "A zero-valued send result is success")
assert(probe.state.addonEvents == 0 and whisper.events == 0 and broadcast.events == 0,
    "Successful sends do not imply that any native receive event occurred")
local first = world:message("P", nil, 1, "37|0.4|0.6", world.epoch - 60)
world:receive(first, "Friend-TestRealm")
local friend = assert(whisper.peers["friend-testrealm"])
assert(friend.positions == 1 and friend.lastPosition, "Accept the first unsigned location without an introduction")
world:receive(first, "Friend-TestRealm", nil, "CHANNEL")
local channelFriend = assert(broadcast.peers["friend-testrealm"])
assert(channelFriend.positions == 1, "The same update must be counted independently on both transports")
world:receive(first, "Friend-TestRealm", nil, "CHANNEL")
assert(channelFriend.positions == 1 and friend.positions == 1, "Each transport discards its own duplicate")
world:receive(world:message("P", nil, 2, "37|0.41|0.6", world.epoch - 60), "Friend-TestRealm")
assert(friend.positions == 2 and friend.lastPosition.x == 0.41 and friend.changes == 1,
    "Later unsigned coordinates replace the previous position")

-- Ignore unrelated routes and malformed packets while retaining valid positions.
local accepted = friend.positions
local valid = world:message("P", nil, 3, "37|0.42|0.6")
local eventsBefore = probe.state.addonEvents
world:receive(valid, "Unrelated-TestRealm")
world:receive(valid, "Friend-TestRealm", "OTHER")
world:receive(valid, "Friend-TestRealm", nil, "PARTY")
world:receive(valid, "Friend-TestRealm", nil, "CHANNEL", { id = 99, name = "OtherChannel" })
assert(channelFriend.positions == 1, "Ignore channel messages delivered through an unrelated channel")
assert(probe.state.addonEvents == eventsBefore + 3 and probe.state.otherEvents == 1,
    "Count matching-prefix events before routing, while ignoring another addon's prefix")
assert(whisper.filterReasons.candidate == 1 and broadcast.filterReasons.channel == 1
    and whisper.filtered == 1 and broadcast.filtered == 1,
    "Expose candidate and channel drops separately from rejected payloads")
local invalidBefore = whisper.invalid
world.secretValue = {}
for _, packet in ipairs({
    valid:gsub("LITP2", "LITP1", 1), valid .. "|extra", "LITP2|P|2000000005|3|37|0.4",
    world:message("H", nil, 3), world:message("P", nil, 3, "37|1.2|0.6"),
    world:message("P", nil, 3, "0|0.4|0.6"), world:message("P", nil, 3, "37|unknown|0.6"),
    false, string.rep("x", 256), world.secretValue,
}) do
    world:receive(packet, "Friend-TestRealm")
end
assert(friend.positions == accepted, "Unrelated routes and malformed data must not replace a valid location")
assert(whisper.invalid == invalidBefore + 10 and whisper.filtered == 1,
    "Malformed, unreadable and oversized payloads are rejected rather than counted as routing filters")
world:receive(valid, "Friend-TestRealm")
assert(friend.positions == accepted + 1)
world:receive(valid, "Friend-TestRealm", nil, "CHANNEL")
assert(channelFriend.positions == 2, "Whisper receipt must not suppress the matching broadcast")
local rejectedBroadcasts, rejectedWhispers = broadcast.invalid, whisper.invalid
world:receive(valid .. "|extra", "Friend-TestRealm", nil, "CHANNEL")
assert(broadcast.invalid == rejectedBroadcasts + 1 and whisper.invalid == rejectedWhispers,
    "Count invalid payloads independently for each transport")
world:receive(valid, "Friend-TestRealm")
world:receive(world:message("P", nil, 2, "37|0.4|0.6"), "Friend-TestRealm")
world:receive(world:message("P", nil, 99, "37|0.4|0.6", world.epoch + world.now - 1), "Friend-TestRealm")
assert(friend.positions == accepted + 1, "Ignore duplicate and older updates")
world:advance(5)
world:receive(world:message("P", nil, 1, "37|0.43|0.6"), "Friend-TestRealm")
assert(friend.positions == accepted + 2, "A newer timestamp permits a restarted sequence")

-- Resolve the current channel number on each send, rather than caching the display row or old number.
world.channels[probe.state.channel:lower()].id = 9
world.roster[3].id = 9

-- Missing player coordinates are reported without fabricating a position.
world.map = nil
local unavailableBefore = world:count("U")
local channelUnavailableBefore = world:count("U", "CHANNEL")
world:advance(5)
assert(world:count("U") == unavailableBefore + 1)
assert(world:count("U", "CHANNEL") == channelUnavailableBefore + 1)
local incomingUnavailable = friend.unavailable
local unavailable = world:message("U", nil, 4)
world:receive(unavailable, "Friend-TestRealm")
world:receive(unavailable, "Friend-TestRealm", nil, "CHANNEL")
assert(friend.unavailable == incomingUnavailable + 1)
assert(channelFriend.unavailable == 1)

-- Stop cancels later sends and leaves only the channel owned by this probe.
local sendsBefore, channelName = #world.sends, world.joins[1].name
probe:Stop()
world:advance(20)
assert(not probe.state.running and #world.sends == sendsBefore)
assert(#world.leaves == 1 and world.leaves[1] == channelName)
assert(friend.lastPosition == nil and channelFriend.lastPosition == nil, "Clear retained coordinates on both transports")
assert(saved.group.secret == "  OTTER-4827  " and saved.chat.autoJoin == false)
for _, message in ipairs(world.messages) do
    assert(not message:find("otter-4827", 1, true), "Never print the group key")
end
probe:Start()
assert(probe.state.running and #world.joins == 2, "A registered prefix must allow another run without reloading")
probe:Stop()

-- A self-test proves the local timer/message path but never discovers a peer.
probe, world = newProbe()
world.loopback = true
probe:Start(true)
assert(probe.state.selfTest, "Explicitly distinguish loopback from a two-client validation")
world:advance(5)
assert(world:count("P") == 1 and world:count("P", "CHANNEL") == 0,
    "Self whispers can run while discovery channel membership is still pending")
world:join({ "Self-TestRealm" })
assert(probe.state.rosterEvents == 1 and probe.state.rosterEventCount == 1)
assert(probe.state.rosterReadableCount == 1 and probe.state.rosterSelfSeen == true and next(probe.state.candidates) == nil,
    "A readable self member is roster evidence without becoming a discovered peer")
assert(probe.state.nativeSelectedIndex == nil, "An unavailable selection getter leaves the native selection unknown")
assert(world.frame.events.CHANNEL_COUNT_UPDATE and world.frame.events.CHAT_MSG_CHANNEL_LIST)
probe:OnEvent("CHANNEL_COUNT_UPDATE", 2, 91)
probe:OnEvent("CHANNEL_COUNT_UPDATE", 3, 7)
assert(probe.state.countEventsTotal == 2 and probe.state.countEvents == 1 and probe.state.countEventCount == 7
    and probe.state.rosterEvents == 1 and probe.state.rosterEventCount == 1,
    "Count events and roster events retain independent native counts")
probe:OnEvent("CHANNEL_ROSTER_UPDATE", 2, 91)
assert(probe.state.rosterEvents == 1, "Ignore another display channel's roster event")
probe:OnEvent("CHANNEL_ROSTER_UPDATE", 3, 12)
assert(probe.state.rosterEvents == 2 and probe.state.rosterEventCount == 12 and probe.state.rosterCount == 1,
    "Keep the native roster-event count separate from display-row membership")
probe:OnEvent("CHANNEL_ROSTER_UPDATE", 3)
assert(probe.state.rosterEventCount == nil, "A missing event count must not be inferred from the display row")
probe:Status()
assert(table.concat(world.messages, "\n"):find("discovered peers=0; whisper targets=1 (limit 9)", 1, true))
assert(probe.state.rosterEventsTotal == 4)
assert(table.concat(world.messages, "\n"):find("roster events=3 (all=4); last event count=unknown", 1, true))
world:advance(114)
assert(probe.state.running and world:count("P") > 0)
local previous = {}
for _, sent in ipairs(world.sends) do
    if sent.distribution == "WHISPER" then assert(sent.target:lower() == "self-testrealm") end
    if sent.body:match("^LITP2|P|") then
        local last = previous[sent.distribution]
        if last then assert(sent.at - last == 5, "Sample and send positions on the five-second cadence") end
        previous[sent.distribution] = sent.at
    end
end
assert(probe.state.transports.WHISPER.sendErrors == 0 and probe.state.transports.CHANNEL.sendErrors == 0)
assert(probe.state.transports.WHISPER.peers["self-testrealm"].positions == 23)
assert(probe.state.transports.CHANNEL.peers["self-testrealm"].positions == 22)
world:advance(1)
assert(not probe.state.running, "End the diagnostic run automatically after 120 seconds")
sendsBefore = #world.sends
world:advance(30)
assert(#world.sends == sendsBefore, "The bounded probe must remain stopped")

-- Explicit peers can test native whispers across internal realms without discovery APIs.
do
    local first, left = newProbe(nil, { playerName = "Alpha", nativeName = "Alpha One", realm = "TestRealm", regionalNames = true })
    local second, right = newProbe(nil, { playerName = "Beta", nativeName = "Beta Two", realm = "TestRealm2", regionalNames = true })
    for _, side in ipairs({ left, right }) do
        side.environment.GetNumDisplayChannels, side.environment.GetChannelDisplayInfo = nil, nil
        side.environment.JoinTemporaryChannel, side.environment.SetSelectedDisplayChannel, side.environment.GetChannelName = nil, nil, nil
        side.environment.C_ChatInfo.GetChannelRosterInfo = nil
    end
    first:Start(false, "whisper", "  Beta Two  ")
    right.environment.SlashCmdList.LOCKINTOOLSPOSITIONPROBE("wHiSpEr Alpha One")
    assert(first.state.directPeer == "Beta Two" and second.state.directPeer == "Alpha One")
    assert(first.state.directPeerKey == "beta two" and second.state.directPeerKey == "alpha one")
    first:OnEvent("CHANNEL_ROSTER_UPDATE", 3, 99)
    for step = 1, 3 do
        left.x, right.x = 0.2 + step / 10, 0.8 - step / 10
        left:advance(5)
        right:advance(5)
        assert(#left.sends == step and #right.sends == step)
        assert(left.sends[step].target == "Beta Two" and right.sends[step].target == "Alpha One",
            "Preserve the native target's complete name and case")
        local fromLeft = step == 1 and "Alpha One" or "Alpha One-TestRealm"
        local fromRight = step == 1 and "Beta Two-TestRealm2" or "Beta Two"
        right:receive(left.sends[step].body, fromLeft)
        left:receive(right.sends[step].body, fromRight)
    end
    local receivedLeft = first.state.transports.WHISPER.peers["beta two"]
    local receivedRight = second.state.transports.WHISPER.peers["alpha one"]
    assert(receivedLeft.positions == 3 and receivedRight.positions == 3
        and receivedLeft.minGap == 5 and receivedLeft.maxGap == 5 and receivedRight.changes == 2)
    right:receive(left.sends[3].body, "Alpha One-TestRealm2")
    right:receive(left.sends[3].body, "Alpha Other")
    assert(receivedRight.positions == 3 and second.state.transports.WHISPER.invalid == 1
        and second.state.transports.WHISPER.filterReasons.candidate == 1,
        "Qualified variants share ordering state while another surname remains excluded")
    for _, side in ipairs({ left, right }) do
        assert(#side.joins == 0 and #side.roster == 0 and side.probe.state.rosterSelectionAttempts == 0
            and side.probe.state.transports.CHANNEL.attempts == 0)
        side.probe:Stop()
        local sent = #side.sends
        side:advance(20)
        assert(#side.sends == sent and #side.leaves == 0, "Direct tests stop without touching native channels")
    end
    local start = #left.messages + 1
    first:Status()
    local report = table.concat(left.messages, "\n", start)
    assert(report:find("DIRECT PEER (discovery bypassed)", 1, true) and report:find('Direct whisper target="Beta Two"', 1, true))
end

-- Without regional full names, an explicitly qualified target remains realm-sensitive.
probe, world = newProbe(nil, { regionalNames = false })
probe:Start(false, "whisper", "Friend-TestRealm2")
local directPacket = world:message("P", nil, 1, "37|0.3|0.7")
world:receive(directPacket, "Friend")
assert(next(probe.state.transports.WHISPER.peers) == nil)
world:receive(directPacket, "Friend-TestRealm2")
assert(probe.state.transports.WHISPER.peers["friend-testrealm2"].positions == 1)
probe:Stop()

-- Direct errors remain bounded and invalid arguments do not initialize or alter the addon.
probe, world = newProbe()
world.sendResults.WHISPER = 11
probe:Start(false, "whisper", "Other Name")
world:advance(120)
assert(not probe.state.running and probe.state.transports.WHISPER.results["11"] == 23
    and probe.state.transports.WHISPER.events == 0 and #world.joins == 0 and #world.leaves == 0)
for _, arguments in ipairs({
    { false, "whisper", false }, { false, "whisper", {} }, { false, "whisper", "" },
    { false, "whisper", "  " }, { false, "whisper", string.rep("a", 129) },
    { false, "whisper", "Other|Name" }, { false, "whisper", "Other\nName" },
    { false, "whisper", "Self" }, { false, "whisper", "Self Surname" },
    { false, "channel", "Other Name" }, { true, "whisper", "Other Name" },
}) do
    probe, world = newProbe(nil, { nativeName = "Self Surname", regionalNames = true })
    probe:Start(arguments[1], arguments[2], arguments[3])
    assert(not probe.state and world.prefix == nil and #world.joins == 0 and #world.sends == 0)
    assert(world.environment.LockInToolsDB.group.secret == "  OTTER-4827  "
        and world.environment.LockInToolsDB.chat.autoJoin == false)
end

-- An empty cached roster is retried after membership, with bounded native selection attempts.
probe, world = newProbe(nil, { nativeSelection = true, listAPI = true })
probe:RequestRosterList()
probe:Start(true)
probe:RequestRosterList()
assert(#world.listCalls == 0 and not probe.state.listRequested, "A chatlist request waits for an active joined run")
world.roster = { { name = "Channels", header = true }, { name = "General", id = 1, members = {} },
    { name = probe.state.channel, id = 7, members = {} } }
probe:OnEvent("CHANNEL_UI_UPDATE")
assert(probe.state.rosterSelectionAttempts == 0, "A cached display row alone does not prove channel membership")
world.onSelect = function(index)
    if #world.selected == 2 then world.roster[index].members = { "Self-TestRealm" } end
    probe:OnEvent("CHANNEL_ROSTER_UPDATE", index, #world.roster[index].members)
end
world:join({})
for _ = 1, 20 do probe:OnEvent("CHANNEL_UI_UPDATE") end
assert(probe.state.rosterSelectionAttempts == 1 and #world.selected == 1)
world:advance(5)
assert(probe.state.rosterSelectionAttempts == 2 and probe.state.rosterCount == 1
    and probe.state.rosterReadableCount == 1 and probe.state.rosterSelfSeen and next(probe.state.candidates) == nil,
    "Re-read a roster that becomes available during the delayed second selection")
world.nativeSelectedIndex = 2
for _ = 1, 20 do probe:OnEvent("CHANNEL_UI_UPDATE") end
assert(probe.state.rosterSelectionAttempts == 2, "Event storms cannot bypass the five-second retry spacing")
world:advance(5)
assert(probe.state.rosterSelectionAttempts == 3 and probe.state.lastRosterSelectionAt == 10)
world.nativeSelectedIndex = 2
world:advance(10)
assert(probe.state.rosterSelectionAttempts == 3 and probe.state.nativeSelectedIndex == 2
    and probe.state.selectedIndex == 3, "The matched row and current native selection remain distinct after the retry limit")
probe:OnEvent("CHAT_MSG_CHANNEL_LIST", "Ignored before request", "", "", "", "", "", 0, 7, probe.state.channel)
world.environment.SlashCmdList.LOCKINTOOLSPOSITIONPROBE("roster")
probe:RequestRosterList()
assert(#world.listCalls == 1 and world.listCalls[1] == probe.state.channel and probe.state.listCallOK == true)
probe:OnEvent("CHAT_MSG_CHANNEL_LIST", "Unrelated", "", "", "", "", "", 0, 1, "General")
probe:OnEvent("CHAT_MSG_CHANNEL_LIST", "Outsider-TestRealm", "", "", "", "", "", 0, 7, probe.state.channel)
assert(probe.state.listEventsTotal == 3 and probe.state.listEvents == 1 and next(probe.state.candidates) == nil,
    "Associate only requested-channel list responses without turning localized chat text into peers")
probe:Stop()

-- Synchronous roster events must not re-enter selection or double-count readable members.
probe, world = newProbe()
probe:Start(true)
world.onSelect = function(index)
    world.roster[index].members = { "Self-TestRealm", "Friend-TestRealm" }
    probe:OnEvent("CHANNEL_ROSTER_UPDATE", index, 2)
end
world:join({})
assert(probe.state.rosterSelectionAttempts == 1 and #world.selected == 1
    and probe.state.rosterReadableCount == 2 and probe.state.rosterSelfSeen
    and probe.state.candidates["friend-testrealm"] and not probe.state.candidates["self-testrealm"],
    "One native selection with a nested event yields two readable members and one peer")
probe:Stop()

-- Optional getter failures and native selection/list exceptions remain safe and bounded.
probe, world = newProbe(nil, { nativeSelection = true, listAPI = true })
world.environment.GetSelectedDisplayChannel = function() error("Optional getter unavailable") end
world.selectionThrows, world.listThrows = true, true
probe:Start(true)
world:join({})
world:advance(15)
assert(probe.state.running and probe.state.rosterSelectionAttempts == 3 and probe.state.rosterSelectionErrors == 3
    and probe.state.nativeSelectedIndex == nil and #world.selected == 3)
probe:RequestRosterList()
probe:RequestRosterList()
assert(#world.listCalls == 1 and probe.state.listRequested and probe.state.listCallOK == false,
    "A failed native list call is recorded without repeated requests")
probe:Stop()

-- Forever's exact native full name is an additional self identity, not a broad name match.
probe, world = newProbe(nil, { nativeName = "Self.Surname" })
world.loopback, world.loopbackSender = true, "Self.Surname"
probe:Start(true)
world:join({ "Self-TestRealm", "Self.Surname", "Self.Other" })
world:advance(5)
assert(probe.state.selfName == "self-testrealm" and probe.state.nativeSelfName == "self.surname-testrealm")
for _, distribution in ipairs({ "CHANNEL", "WHISPER" }) do
    assert(probe.state.transports[distribution].peers["self.surname-testrealm"].positions == 1,
        "The native self sender must be accepted independently on both routes")
end
assert(world.sends[#world.sends].target == "self-testrealm", "Preserve the original self whisper target")
local aliasPacket = world:message("P", nil, 2, "37|0.3|0.7")
world:receive(aliasPacket, "Self.Other")
world:receive(aliasPacket, "Self.Other", nil, "CHANNEL")
whisper, broadcast = probe.state.transports.WHISPER, probe.state.transports.CHANNEL
assert(whisper.filterReasons.sender == 1 and broadcast.filterReasons.sender == 1
    and whisper.peers["self.other-testrealm"] == nil and broadcast.peers["self.other-testrealm"] == nil,
    "A different surname remains another player during a self-test")
local firstSample, printed = whisper.firstSenderFilter, #world.messages
assert(firstSample:find("self-testrealm", 1, true) and firstSample:find("self.surname-testrealm", 1, true)
    and firstSample:find("Self.Other", 1, true) and firstSample:find("self.other-testrealm", 1, true))
world:receive(aliasPacket, "Different")
assert(whisper.firstSenderFilter == firstSample and #world.messages == printed,
    "Keep the first mismatch sample without printing every later sender rejection")
local aliasStatusStart = #world.messages + 1
probe:Status()
assert(table.concat(world.messages, "\n", aliasStatusStart):find(firstSample, 1, true),
    "Status retains the expected and actual sender identities")
probe:Stop()

probe, world = newProbe(nil, { nativeName = "Self.Surname" })
probe:Start()
world:join({ "Self-TestRealm", "Self.Surname", "Friend-TestRealm" })
assert(probe.state.candidates["self-testrealm"] == nil and probe.state.candidates["self.surname-testrealm"] == nil
    and probe.state.candidates["friend-testrealm"], "Exclude both exact self names from peer discovery")
for _, distribution in ipairs({ "CHANNEL", "WHISPER" }) do
    world:receive(aliasPacket, "Self.Surname", nil, distribution)
    local transport = probe.state.transports[distribution]
    assert(transport.filterReasons.sender == 1 and transport.peers["self.surname-testrealm"] == nil,
        "A native self echo cannot establish delivery to another player")
end
probe:Stop()

-- Failed or unreadable native-name helpers fall back without stringifying secret values.
for _, kind in ipairs({ "throws", "unreadable", "empty" }) do
    local conversions = 0
    local secret = setmetatable({}, { __tostring = function() conversions = conversions + 1; error("Secret value exposed") end })
    local nativeName = kind == "throws" and function() error("Optional helper unavailable") end
        or kind == "empty" and "" or secret
    probe, world = newProbe(nil, { nativeName = nativeName })
    world.secretValue, world.loopback = secret, true
    probe:Start(true)
    world:advance(5)
    assert(probe.state.nativeSelfName == nil and probe.state.transports.WHISPER.peers["self-testrealm"].positions == 1)
    world:receive(aliasPacket, secret)
    local sample = probe.state.transports.WHISPER.firstSenderFilter
    assert(sample:find("<unreadable>", 1, true) and conversions == 0,
        "An unreadable sender is reported safely without exposing its value")
    probe:Stop()
end

-- Realm restriction flags are observations; actual native sends establish the result.
probe, world = newProbe(nil, { realmRestricted = true, chatLockdown = false })
world.loopback = true
world.environment.SlashCmdList.LOCKINTOOLSPOSITIONPROBE("self")
assert(probe.state and probe.state.running and probe.state.realmRestricted == true and probe.state.chatLockdown == false,
    "A realm restriction flag must not prevent an explicit native-API diagnostic")
world:join()
world:advance(5)
for _, distribution in ipairs({ "CHANNEL", "WHISPER" }) do
    local transport = probe.state.transports[distribution]
    assert(transport.attempts == 1 and transport.sent == 1 and transport.sendErrors == 0)
    assert(transport.peers["self-testrealm"].positions == 1,
        "Successful native sends and receive events are observed even on a flagged realm")
end
probe:Status()
local restrictionReport = table.concat(world.messages, "\n")
assert(restrictionReport:find("realm outgoing=true; chat lockdown=false", 1, true),
    "Reports must preserve both the enabled realm flag and the disabled lockdown flag")
world.realmRestricted, world.chatLockdown = false, true
world.sendResults.CHANNEL = 11
world:advance(5)
assert(probe.state.realmRestricted == false and probe.state.chatLockdown == true,
    "Refresh messaging observations during a running diagnostic")
whisper, broadcast = probe.state.transports.WHISPER, probe.state.transports.CHANNEL
assert(broadcast.results["11"] == 1 and broadcast.sent == 1 and broadcast.peers["self-testrealm"].positions == 1)
assert(whisper.results["11"] == nil and whisper.sent == 2 and whisper.peers["self-testrealm"].positions == 2,
    "Changing status flags must not replace the independent native result for either transport")
probe:Status()
assert(table.concat(world.messages, "\n"):find("realm outgoing=false; chat lockdown=true", 1, true))
probe:Stop()

-- A native lockdown result is recorded as a failure, never as accepted or delivered data.
probe, world = newProbe(nil, { realmRestricted = true, chatLockdown = true })
world.loopback = true
world.sendResults.CHANNEL, world.sendResults.WHISPER = 11, 11
probe:Start(true)
assert(probe.state and probe.state.running and probe.state.chatLockdown == true)
world:join()
world:advance(5)
for _, distribution in ipairs({ "CHANNEL", "WHISPER" }) do
    local transport = probe.state.transports[distribution]
    assert(transport.attempts == 1 and transport.sent == 0 and transport.bytes == 0)
    assert(transport.sendErrors == 1 and transport.results["11"] == 1 and next(transport.peers) == nil)
end
world:advance(115)
assert(not probe.state.running and probe.state.finished == 120,
    "Restriction failures do not remove the diagnostic's normal 120-second bound")
for _, distribution in ipairs({ "CHANNEL", "WHISPER" }) do
    local transport = probe.state.transports[distribution]
    assert(transport.attempts == 23 and transport.results["11"] == 23 and next(transport.peers) == nil)
end
local lockdownReport = table.concat(world.messages, "\n")
assert(lockdownReport:find("AddOnMessageLockdown", 1, true), "Show the native enum name alongside its recorded result")
for _, message in ipairs(world.messages) do
    assert(not message:lower():find("otter-4827", 1, true)
        and not message:find(world.joins[1].password, 1, true), "Restriction reports must not disclose credentials")
end
sendsBefore = #world.sends
world:advance(10)
assert(#world.sends == sendsBefore)

-- An unavailable optional observation does not prevent native sending or hide other observations.
probe, world = newProbe(nil, { realmRestricted = false, chatLockdown = false })
world.loopback = true
world.environment.C_ChatInfo.AreOutgoingAddonChatMessagesRestricted = function() error("Status API unavailable") end
probe:Start(true)
assert(probe.state and probe.state.running and probe.state.realmRestricted == nil and probe.state.chatLockdown == false)
world:advance(5)
assert(probe.state.transports.WHISPER.peers["self-testrealm"].positions == 1)
probe:Status()
assert(table.concat(world.messages, "\n"):find("realm outgoing=unknown; chat lockdown=false", 1, true))
probe:Stop()

-- Roster membership is the only discovery input, and probe traffic stays bounded.
probe, world = newProbe()
probe:Start()
world:join({ "Self-TestRealm", "One-TestRealm", "Two-TestRealm", "Three-TestRealm",
    "Four-TestRealm", "Five-TestRealm", "Six-TestRealm", "Seven-TestRealm",
    "Eight-TestRealm", "Nine-TestRealm", "Ten-TestRealm" })
world:advance(5)
local targets, targetCount = {}, 0
for _, sent in ipairs(world.sends) do
    if sent.distribution == "WHISPER" then
        local target = sent.target:lower()
        if not targets[target] then targets[target], targetCount = true, targetCount + 1 end
    end
end
assert(targetCount == 9, "Limit diagnostic fan-out to nine roster candidates")
assert(probe.state.targetCount == 9, "Report the bounded outgoing target count rather than all discovered candidates")
assert(world:count("P", "CHANNEL") == 1, "A channel broadcast does not multiply with roster size")
probe:Status()
assert(table.concat(world.messages, "\n"):find("discovered peers=10; whisper targets=9 (limit 9)", 1, true))
local packet = world:message("P", nil, 1, "37|0.2|0.8")
world:receive(packet, "Outsider-TestRealm")
assert(probe.state.transports.WHISPER.peers["outsider-testrealm"] == nil, "Ignore updates outside the discovery roster")
world:receive(packet, "One-TestRealm")
world:receive(packet, "Two-TestRealm")
assert(probe.state.transports.WHISPER.peers["one-testrealm"].positions == 1
    and probe.state.transports.WHISPER.peers["two-testrealm"].positions == 1,
    "The actual WoW event sender identifies each peer without a payload identity")
probe:Stop()

-- Broadcast failures and silent non-delivery do not stop the whisper comparison.
probe, world = newProbe()
world.loopback = { WHISPER = true }
world.sendResults.CHANNEL = 7
probe:Start(true)
world:join()
world:advance(5)
whisper, broadcast = probe.state.transports.WHISPER, probe.state.transports.CHANNEL
assert(broadcast.sent == 0 and broadcast.sendErrors == 1 and broadcast.results["7"] == 1)
assert(broadcast.attempts == 1 and broadcast.bytes == 0)
assert(whisper.sent == 1 and whisper.sendErrors == 0 and whisper.peers["self-testrealm"].positions == 1,
    "A failed channel send must leave the whisper path working")
world.sendResults.CHANNEL = 0
world:advance(5)
assert(broadcast.sent == 1 and next(broadcast.peers) == nil,
    "API acceptance without a receive event is not evidence of channel delivery")
assert(broadcast.events == 0 and broadcast.filtered == 0 and broadcast.invalid == 0,
    "No native receive event must remain distinct from a filtered or rejected event")
assert(whisper.sent == 2 and whisper.peers["self-testrealm"].positions == 2,
    "Whispers continue when broadcasts are accepted but silently dropped")
assert(whisper.results["7"] == nil and broadcast.sendErrors == 1,
    "Report send errors independently for each transport")
probe:Status()
assert(probe.state.selfTest, "Loopback results must remain identified as a self-test")
probe:Stop()

-- A native channel-call exception must leave the timer and whisper experiment running.
probe, world = newProbe()
world.loopback = { WHISPER = true }
world.sendThrows.CHANNEL = "unsupported channel call"
probe:Start(true)
world:join()
world:advance(10)
whisper, broadcast = probe.state.transports.WHISPER, probe.state.transports.CHANNEL
assert(probe.state.running and broadcast.attempts == 2 and broadcast.sendErrors == 2)
assert(broadcast.results["API error"] == 2 and broadcast.sent == 0 and broadcast.bytes == 0)
assert(whisper.sent == 2 and whisper.peers["self-testrealm"].positions == 2,
    "A raised channel API error must not interrupt whisper delivery or later ticks")
probe:Stop()
local statusStart = #world.messages + 1
probe:Status()
local stoppedStatus = table.concat(world.messages, "\n", statusStart)
world:advance(20)
statusStart = #world.messages + 1
probe:Status()
assert(table.concat(world.messages, "\n", statusStart) == stoppedStatus,
    "Completed traffic measurements must retain their original rates")

-- Isolated runs compare the actual traffic for a ten-player group.
for _, mode in ipairs({ "channel", "whisper" }) do
    probe, world = newProbe()
    world.environment.SlashCmdList.LOCKINTOOLSPOSITIONPROBE(mode)
    world:join({ "Self-TestRealm", "One-TestRealm", "Two-TestRealm", "Three-TestRealm",
        "Four-TestRealm", "Five-TestRealm", "Six-TestRealm", "Seven-TestRealm",
        "Eight-TestRealm", "Nine-TestRealm" })
    world:advance(10)
    assert(world:count("P", "CHANNEL") == (mode == "channel" and 2 or 0))
    assert(world:count("P", "WHISPER") == (mode == "whisper" and 18 or 0))
    assert(probe.state.targetCount == (mode == "whisper" and 9 or 0),
        "Channel-only runs have no whisper targets")
    for _, distribution in ipairs({ "CHANNEL", "WHISPER" }) do
        local count, bytes = 0, 0
        for _, sent in ipairs(world.sends) do
            if sent.distribution == distribution then
                count, bytes = count + 1, bytes + #sent.body
            end
        end
        local transport = probe.state.transports[distribution]
        assert(transport.attempts == count and transport.sent == count and transport.bytes == bytes,
            "Report each isolated path's exact send attempts and accepted payload bytes")
    end
    probe:Stop()
end

-- A joined channel can prove its delivery independently of asynchronous roster availability.
probe, world = newProbe()
probe:Start(false, "channel")
world:join({})
world:advance(5)
packet = world:message("P", nil, 1, "37|0.2|0.8")
world:receive(packet, "Friend-TestRealm", nil, "CHANNEL", { id = 99, name = probe.state.channel })
world:receive(packet, "Friend-TestRealm", nil, "CHANNEL", { zone = 7 })
assert(next(probe.state.transports.CHANNEL.peers) == nil,
    "A mismatched local channel number or zone ID alone must not associate a broadcast")
world:receive(packet, "Friend-TestRealm", nil, "CHANNEL", { name = probe.state.channel:upper() })
assert(probe.state.transports.CHANNEL.peers["friend-testrealm"].positions == 1)
world:receive(world:message("P", nil, 2, "37|0.21|0.8"), "Friend-TestRealm", nil, "CHANNEL",
    { id = 7, name = "DifferentChannel" })
assert(probe.state.transports.CHANNEL.peers["friend-testrealm"].positions == 2,
    "A valid local channel number is authoritative, with channel name used only as fallback")
world:receive(packet, "Friend-TestRealm")
assert(next(probe.state.transports.WHISPER.peers) == nil, "Whispers still require discovered recipients")
assert(probe.state.transports.WHISPER.events == 1 and probe.state.transports.WHISPER.filterReasons.mode == 1,
    "Report events filtered by the selected diagnostic mode")
world:receive(packet, "Self-TestRealm", nil, "CHANNEL")
assert(probe.state.transports.CHANNEL.peers["self-testrealm"] == nil,
    "A normal channel echo does not establish peer delivery")
assert(probe.state.transports.CHANNEL.filterReasons.sender == 1 and probe.state.transports.CHANNEL.filtered == 3,
    "Expose self-echo filtering alongside the two channel-metadata filters")
probe:Stop()

-- Changing groups ends the run instead of continuing on the old discovery channel.
probe, world = newProbe()
probe:Start()
world:join()
world:advance(5)
sendsBefore = #world.sends
world.environment.LockInToolsDB.group.secret = "new-group"
world:advance(5)
assert(not probe.state.running and #world.sends == sendsBefore and #world.leaves == 1)

-- Invalid and newer saved data is preserved without requesting a channel join.
for _, bad in ipairs({
    { schemaVersion = 99, group = { secret = "otter-4827" } },
    { schemaVersion = 3, group = { secret = "invalid secret!" } },
}) do
    probe, world = newProbe(bad)
    local original = bad.group.secret
    probe:Start()
    assert(#world.joins == 0 and not (probe.state and probe.state.running))
    assert(bad.group.secret == original)
end

print("Position probe tests passed.")
