-- Exercise the real codec and guide protocol between independent clients.
local function loadModule(file, addon, env)
    local chunk = assert(loadfile(file))
    setfenv(chunk, env)
    chunk("LockInTools", addon)
end

local function client(name, saved, readOnly)
    local world = { now = 0, timers = {}, sent = {}, listeners = {}, events = {}, installs = {}, notifications = 0 }
    local addon = { db = saved or {}, savedDataReadOnly = readOnly, ready = true, initialized = true,
        connected = false, fingerprint = "test-group", dataState = { requestSession = name .. "-session" } }
    local env = setmetatable({ bit = false, bit32 = false, GetTime = function() return world.now end,
        UnitFullName = function() return name, "TestRealm" end,
        InCombatLockdown = function() return world.combat == true end,
        C_Timer = { NewTimer = function(delay, callback)
            local timer = { at = world.now + delay, callback = callback }
            function timer:Cancel() self.cancelled = true end
            world.timers[#world.timers + 1] = timer
            return timer
        end },
    }, { __index = _G })
    env._G = env
    loadModule("Libs/LibStub/LibStub.lua", addon, env)
    loadModule("Libs/LibDeflate/LibDeflate.lua", addon, env)
    loadModule("Crypto.lua", addon, env)
    loadModule("RestedXPCodec.lua", addon, env)
    function addon:HasGroup() return self.fingerprint ~= nil end
    function addon:IsGroupSwitching() return self.switching == true end
    function addon:GetGroupFingerprint() return self.fingerprint end
    function addon:IsDataConnected() return self.connected end
    function addon:GetDataSenderIdentity(sender)
        local identity = sender:find("-", 1, true) and sender:lower() or sender:lower() .. "-testrealm"
        return identity, identity == name:lower() .. "-testrealm"
    end
    function addon:SignGroupMessage(feature, body)
        return self.Crypto.Hex(self.Crypto.HMACSHA256(self.fingerprint .. feature, body))
    end
    function addon:VerifyGroupMessage(feature, body, signature)
        return type(signature) == "string" and self.Crypto.Equal(self:SignGroupMessage(feature, body), signature)
    end
    function addon:Notify(event)
        world.notifications = world.notifications + 1
        for _, callback in ipairs(world.listeners[event] or {}) do callback() end
    end
    function addon:RegisterNotification(event, callback)
        world.listeners[event] = world.listeners[event] or {}
        table.insert(world.listeners[event], callback)
    end
    function addon:RegisterGameEvents(events, callback)
        for _, event in ipairs(events) do world.events[event] = callback end
    end
    function addon:RegisterDataFeature(feature, receive, connected)
        assert(feature == "guides")
        world.receive, world.connection = receive, connected
        connected(self.connected)
    end
    function addon:SendData(feature, wire)
        assert(feature == "guides" and #("1|guides|" .. wire) <= 255 and not wire:find("\0", 1, true))
        if world.rejectSends then return false end
        world.sent[#world.sent + 1] = wire
        return true
    end
    function addon:GetRestedXPInstallation()
        return { installed = not world.missing, loaded = not world.missing, compatible = not world.missing,
            version = "test", guides = {}, problem = world.missing and "RestedXP is not installed." or nil }
    end
    function addon:InstallRestedXPPack(pack, callback)
        if world.busy then return false, "Native import running", "busy" end
        world.installs[#world.installs + 1] = pack.hash
        world.installTimer = env.C_Timer.NewTimer(0.5, function()
            callback(not world.failInstall, world.failInstall and "Synthetic import failure" or nil)
        end)
        return true
    end
    function addon:CancelRestedXPInstallation()
        if world.installTimer then world.installTimer:Cancel() end
    end
    loadModule("RestedXP.lua", addon, env)
    addon:InitializeRestedXP()
    addon.testWorld = world
    function world:connect(value)
        addon.connected = value
        self.connection(value)
    end
    function world:advance(seconds)
        local target, iterations = self.now + seconds, 0
        while true do
            local first, index
            for i, timer in ipairs(self.timers) do
                if not timer.cancelled and timer.at <= target and (not first or timer.at < first.at) then first, index = timer, i end
            end
            if not first then break end
            table.remove(self.timers, index)
            self.now = first.at
            iterations = iterations + 1
            assert(iterations < 10000, "bounded guide timers")
            first.callback()
        end
        self.now = target
    end
    function world:deliver(other, filter)
        self.delivered = self.delivered or 0
        while self.delivered < #self.sent do
            self.delivered = self.delivered + 1
            local wire = self.sent[self.delivered]
            if not filter or filter(wire) then other.receive(name .. "-TestRealm", wire) end
        end
    end
    return addon, world, env
end

local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64(raw)
    local result = {}
    for i = 1, #raw, 3 do
        local a, b, c = raw:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local function char(shift) local p = math.floor(n / 2 ^ shift) % 64; return alphabet:sub(p + 1, p + 1) end
        result[#result + 1] = char(18) .. char(12) .. (b and char(6) or "=") .. (c and char(0) or "=")
    end
    return table.concat(result)
end
local function packFor(addon, env, version, seed)
    local text = "#forever\n#group Synthetic Pack\n#name Test Route\n#version " .. version .. "\nstep\n"
    local lines = {}
    for i = 1, 400 do lines[i] = ".note " .. (i * (seed or 3)) .. " " .. (i * i) .. " " .. (i * i * 7 % 997) end
    text = text .. table.concat(lines, "\n")
    local deflate = env.LibStub("LITLibDeflate")
    local compressed = deflate:CompressZlib(text)
    local canonical = "1|" .. string.format("%.0f", deflate:Adler32(text)) .. ":" .. base64(compressed) .. "%|40000"
    return assert(addon.RestedXPCodec.DecodeCanonical(canonical))
end
local function publish(addon, pack, id)
    local export = assert(addon.RestedXPCodec.Encode(pack, "Source#1234"))
    assert(addon:ImportRestedXPPack(id or "leveling", export, "Source#1234"))
    for _ = 1, 10000 do
        if not addon.restedxpState.job then break end
        addon.testWorld:advance(0.02)
    end
    assert(not addon.restedxpState.job and addon.db.restedxp.groups[addon.fingerprint].packs[id or "leveling"],
        "asynchronous publishing completes with a verified pack")
end
local function exchange(a, b, seconds, filter)
    for _ = 1, math.ceil(seconds / 0.15) do
        a:advance(0.15); b:advance(0.15)
        a:deliver(b, filter); b:deliver(a)
    end
end
local function transferMessages(world)
    local count = 0
    for _, wire in ipairs(world.sent) do
        if wire:match("^1|[WD]|") then count = count + 1 end
    end
    return count
end

-- A late joiner discovers an earlier publication, follows it explicitly, and
-- recovers a dropped data packet before reporting confirmed installation.
do
    local publisher, a, api = client("Alpha")
    local recipient, b = client("Beta")
    local pack = packFor(publisher, api, 1)
    assert(#pack.data > 1024, "the fixture exercises multiple transfer windows")
    a:connect(true)
    publish(publisher, pack)
    a:advance(3)
    a.delivered = #a.sent -- these announcements preceded the recipient
    b:connect(true)
    exchange(a, b, 4)
    local state = recipient:GetRestedXPState()
    assert(#state.packs == 1 and state.packs[1].hash == pack.hash and not state.packs[1].selected)
    assert(#b.installs == 0, "unsolicited announcements never install guides")
    assert(recipient:SelectRestedXPPack("leveling", "Alpha-TestRealm"))
    assert(recipient:UpdateRestedXPGuides())
    local dropped = false
    exchange(a, b, 70, function(wire)
        if not dropped and wire:match("^1|D|[^|]+|3|") then dropped = true; return false end
        return true
    end)
    assert(dropped and #b.installs == 1, "missing chunks are requested again without duplicate installation")
    local installed = recipient:GetRestedXPState()
    assert(installed.packs[1].installed and installed.packs[1].hash == pack.hash)

    local sent, requested = transferMessages(a), transferMessages(b)
    assert(recipient:UpdateRestedXPGuides())
    exchange(a, b, 5)
    assert(#b.installs == 1 and transferMessages(a) == sent and transferMessages(b) == requested,
        "rechecking an identical followed pack neither transfers nor reinstalls it")
    assert(not recipient:GetRestedXPState().busy
        and recipient:GetRestedXPState().status:find("up to date", 1, true),
        "an unchanged online followed pack finishes with an explicit up-to-date result")

    -- Content changes with the same guide #version still propagate automatically.
    local updated = packFor(publisher, api, 1, 5)
    assert(updated.hash ~= pack.hash)
    publish(publisher, updated)
    exchange(a, b, 70)
    assert(#b.installs == 2 and b.installs[2] == updated.hash)
    local group = recipient.db.restedxp.groups[recipient.fingerprint]
    assert(group.packs.leveling.previous.hash == pack.hash, "keep previous verified package for recovery")
    assert(not recipient.restedxpState.incoming)
end

-- A failed install is not marked successful or retried forever. A manual
-- update can retry it; busy native imports are deferred without discarding it.
do
    local publisher, a, api = client("Alpha")
    local recipient, b = client("Beta")
    local pack = packFor(publisher, api, 2)
    a:connect(true); b:connect(true); publish(publisher, pack)
    exchange(a, b, 4)
    assert(recipient:SelectRestedXPPack("leveling", "alpha-testrealm"))
    b.failInstall = true
    assert(recipient:UpdateRestedXPGuides())
    exchange(a, b, 70)
    assert(#b.installs == 1 and not recipient:GetRestedXPState().packs[1].installed)
    b.failInstall, b.busy = false, true
    assert(recipient:UpdateRestedXPGuides())
    exchange(a, b, 5)
    assert(#b.installs == 1 and recipient.restedxpState.pending.leveling)
    b.busy = false
    exchange(a, b, 5)
    assert(#b.installs == 2 and recipient:GetRestedXPState().packs[1].installed)
end

-- Updates span all followed packs, not only the first one in the catalog.
do
    local publisher, a, api = client("Alpha")
    local recipient, b = client("Beta")
    a:connect(true); b:connect(true)
    publish(publisher, packFor(publisher, api, 1), "first")
    publish(publisher, packFor(publisher, api, 2, 4), "second")
    exchange(a, b, 5)
    assert(recipient:SelectRestedXPPack("first", "alpha-testrealm"))
    assert(recipient:SelectRestedXPPack("second", "alpha-testrealm"))
    assert(recipient:UpdateRestedXPGuides())
    exchange(a, b, 100)
    assert(#b.installs == 2, "one update request installs both followed packs")
end

-- Authentication, bounded packets, disconnects and read-only data protect the
-- group lifecycle. Accepted native sends alone are never delivery confirmation.
do
    local addon, world, env = client("Beta")
    world:connect(true)
    local function sign(body) return body .. "|" .. addon:SignGroupMessage("restedxp", body) end
    local hash = string.rep("a", 64)
    assert(not world.receive("Alpha-TestRealm", "1|O|leveling|" .. hash .. "|100|" .. string.rep("0", 64)))
    assert(not world.receive("Alpha-TestRealm", sign("1|O|bad id|" .. hash .. "|100")))
    assert(not world.receive("Alpha-TestRealm", sign("1|O|leveling|" .. hash .. "|99999999")))
    assert(not world.receive("Beta-TestRealm", sign("1|O|leveling|" .. hash .. "|100")))
    assert(world.receive("Alpha-TestRealm", sign("1|O|leveling|" .. hash .. "|100")))
    assert(addon:SelectRestedXPPack("leveling", "alpha-testrealm"))
    assert(addon:UpdateRestedXPGuides())
    world:advance(3)
    assert(addon.restedxpState.incoming)
    world:connect(false)
    local count = #world.sent
    world:advance(50)
    assert(#world.sent == count and not addon.restedxpState.incoming)
    addon.fingerprint = "other-group"
    addon:Notify("GROUP_CHANGED")
    assert(addon.db.restedxp.groups["test-group"] == nil and #addon:GetRestedXPState().packs == 0)
    world:connect(true)
    assert(not world.receive("Alpha-TestRealm", sign("1|D|" .. hash:sub(1, 16) .. "|1|abc")))

    local future = { untouched = true }
    local readonly, readWorld = client("ReadOnly", future, true)
    readWorld:connect(true)
    readWorld:advance(5)
    assert(not readonly:UpdateRestedXPGuides() and not readonly:ImportRestedXPPack("test", "bad", "Source#1234"))
    assert(future.untouched and future.restedxp == nil and #readWorld.sent == 0)
end

-- Empty inventories still complete discovery and restore the update control.
do
    local addon, world = client("Solo")
    world:connect(true)
    assert(addon:GetRestedXPState().busy, "login starts bounded discovery without a manual update")
    world:advance(4)
    assert(not addon:GetRestedXPState().busy and addon:GetRestedXPState().canUpdate
        and addon:GetRestedXPState().status:find("No LIT-shared packs found.", 1, true),
        "login discovery completes even when no member has published an export")
    assert(addon:UpdateRestedXPGuides())
    assert(addon:GetRestedXPState().busy)
    world:advance(4)
    assert(not addon:GetRestedXPState().busy and addon:GetRestedXPState().canUpdate)
    assert(addon:GetRestedXPState().status:find("No LIT-shared packs found.", 1, true))
end

-- Local publications install once, and an unchanged manual update has the same
-- no-op behavior as an unchanged followed pack. Failed installations remain retryable.
do
    local addon, world, api = client("Publisher")
    world:connect(true)
    publish(addon, packFor(addon, api, 1))
    world.failInstall = true
    assert(addon:UpdateRestedXPGuides())
    world:advance(4)
    assert(#world.installs == 1 and not addon:GetRestedXPState().packs[1].installed,
        "a failed local publication install is not recorded as installed")
    world.failInstall = false
    assert(addon:UpdateRestedXPGuides())
    world:advance(4)
    assert(#world.installs == 2 and addon:GetRestedXPState().packs[1].installed,
        "a manual update can retry a failed local publication install")
    local transferred = transferMessages(world)
    assert(addon:UpdateRestedXPGuides())
    world:advance(4)
    local state = addon:GetRestedXPState()
    assert(#world.installs == 2 and transferMessages(world) == transferred,
        "rechecking an identical local publication neither transfers nor reinstalls it")
    assert(not state.busy and state.status:find("up to date", 1, true),
        "an already installed local publication finishes with an explicit up-to-date result")
end

-- Stale senders cannot permanently exhaust the peer slots, and selecting a new
-- source must not install an unrelated old cached package while that source is offline.
do
    local addon, world, api = client("Beta")
    world:connect(true)
    local function signed(body) return body .. "|" .. addon:SignGroupMessage("restedxp", body) end
    for index = 1, 32 do assert(world.receive("Peer" .. index .. "-TestRealm", signed("1|Q|hello"))) end
    assert(not world.receive("Peer33-TestRealm", signed("1|Q|hello")))
    world:advance(76)
    assert(world.receive("Peer33-TestRealm", signed("1|Q|hello")))
    local original = packFor(addon, api, 1)
    publish(addon, original)
    local group = addon.db.restedxp.groups[addon.fingerprint]
    group.packs.leveling.source = "alpha-testrealm"
    local hash = string.rep("a", 64)
    assert(world.receive("Other-TestRealm", signed("1|O|leveling|" .. hash .. "|100")))
    assert(addon:SelectRestedXPPack("leveling", "other-testrealm"))
    world:advance(200)
    assert(addon:UpdateRestedXPGuides())
    world:advance(3)
    assert(#world.installs == 0, "an unavailable newly selected publisher does not authorize the previous publisher's cache")
    assert(addon:GetRestedXPState().status:find("offline", 1, true),
        "a completed discovery distinguishes offline publishers from confirmed current content")
end

print("PASS: RestedXP pack sharing, content updates, transfer recovery and lifecycle")
