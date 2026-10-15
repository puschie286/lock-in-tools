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

local function newProbe(saved)
    local world = {
        now = 0, epoch = 2000000000, timers = {}, messages = {},
        joins = {}, leaves = {}, sends = {}, selected = {}, channels = {},
        roster = {}, map = 37, x = 0.25, y = 0.75,
        sendResults = { CHANNEL = 0, WHISPER = 0 }, sendThrows = {},
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
            SendAddonMessageResult = { Success = 0 },
            RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1 },
        },
        C_Timer = { NewTimer = timer },
        GetTime = function() return world.now end,
        GetServerTime = function() return world.epoch + math.floor(world.now) end,
        time = function() return world.epoch + math.floor(world.now) end,
        UnitFullName = function(unit) assert(unit == "player"); return "Self", "Test Realm" end,
        GetNormalizedRealmName = function() return "TestRealm" end,
        GetRealmName = function() return "Test Realm" end,
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
                            "Self-TestRealm", nil, 0, joined.id, joined.name)
                    else
                        world.probe:OnEvent("CHAT_MSG_ADDON", prefix, body, channel, "Self-TestRealm")
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
        probe:OnEvent("CHANNEL_ROSTER_UPDATE", 3)
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
assert(world.environment.LockInToolsDB == saved and saved.group.secret == "  OTTER-4827  ")
assert(saved.schemaVersion == 3 and saved.chat.autoJoin == false and saved.showWelcome == false)
assert(world.joins[1].name ~= probe:GetGroupChannelName(), "Keep probe discovery separate from shared chat")

-- Discovery needs the roster display index, which differs from channel number 7.
world:join()
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
world:receive(valid, "Unrelated-TestRealm")
world:receive(valid, "Friend-TestRealm", "OTHER")
world:receive(valid, "Friend-TestRealm", nil, "PARTY")
world:receive(valid, "Friend-TestRealm", nil, "CHANNEL", { id = 99, name = "OtherChannel" })
assert(channelFriend.positions == 1, "Ignore channel messages delivered through an unrelated channel")
for _, packet in ipairs({
    valid:gsub("LITP2", "LITP1", 1), valid .. "|extra", "LITP2|P|2000000005|3|37|0.4",
    world:message("H", nil, 3), world:message("P", nil, 3, "37|1.2|0.6"),
    world:message("P", nil, 3, "0|0.4|0.6"), world:message("P", nil, 3, "37|unknown|0.6"),
}) do
    world:receive(packet, "Friend-TestRealm")
end
assert(friend.positions == accepted, "Unrelated routes and malformed data must not replace a valid location")
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
world:join()
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
assert(world:count("P", "CHANNEL") == 1, "A channel broadcast does not multiply with roster size")
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
world:receive(packet, "Self-TestRealm", nil, "CHANNEL")
assert(probe.state.transports.CHANNEL.peers["self-testrealm"] == nil,
    "A normal channel echo does not establish peer delivery")
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
