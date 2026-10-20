local _, addon = ...

-- RestedXP's format-40000 importer runs a coroutine and then parses one guide
-- per frame. Acceptance of ImportString is not installation confirmation.
local FORMAT = 40000
local TIMEOUT = 300
local observations = setmetatable({}, { __mode = "k" })
local guideObservations = setmetatable({}, { __mode = "k" })
local installation
local installedWatcher
local sourceMemo
local inventoryMemo
local watchedOwners = setmetatable({}, { __mode = "k" })
local MAX_CACHE_ENTRIES, MAX_SCAN_BYTES = 10000, 16 * 1024 * 1024
local MAX_SOURCE_MEMO_BYTES, MAX_PACK_MEMO_BYTES = MAX_SCAN_BYTES * 2, MAX_SCAN_BYTES

local function CallNative(name, ...)
    local callback = C_AddOns and C_AddOns[name] or _G[name]
    if type(callback) ~= "function" then return nil end
    local success, value = pcall(callback, ...)
    if success then return value end
end

local function GetRestedXP()
    if not LibStub then return nil end
    local success, library = pcall(LibStub, "AceAddon-3.0", true)
    if not success or type(library) ~= "table" or type(library.GetAddon) ~= "function" then return nil end
    local found, rxp = pcall(library.GetAddon, library, "RXPGuides", true)
    if found and type(rxp) == "table" then return rxp end
end

local function GuideVersion(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then return 0 end
    return value
end

local function GuideKey(value, fallback)
    if type(value.key) == "string" and value.key ~= "" then return value.key end
    if type(value.group) == "string" and type(value.name) == "string" then
        return value.group .. "|" .. (value.subgroup or "") .. "|" .. value.name
    end
    if type(fallback) == "string" then return fallback:match("^([^|]+|[^|]*|[^|]+)") end
end

local function InstalledGuides(rxp)
    local byKey, result = {}, {}
    local function Add(guide, fallback, active)
        if type(guide) ~= "table" then return end
        local key = GuideKey(guide, fallback)
        if not key then return end
        local group, subgroup, name = key:match("^([^|]+)|([^|]*)|(.+)$")
        if not group or name == "" then return end
        local previous = byKey[key]
        local version = GuideVersion(guide.version)
        if previous and not active and (previous.active or previous.version >= version) then return end
        byKey[key] = {
            key = key, name = guide.name or name, group = guide.group or group,
            subgroup = guide.subgroup or subgroup, version = version, active = active == true,
        }
    end
    local cache = rxp and rxp.db and rxp.db.profile and rxp.db.profile.guides
    if type(cache) == "table" then
        for key, value in pairs(cache) do
            if type(value) == "table" then
                local metadata = value.metadata
                if type(metadata) == "table" then
                    Add(metadata, value.key or key)
                else
                    Add(value, key)
                end
            end
        end
    end
    if rxp and type(rxp.guides) == "table" then
        for key, guide in pairs(rxp.guides) do Add(guide, key, true) end
    end
    for _, guide in pairs(byKey) do result[#result + 1] = guide end
    table.sort(result, function(left, right) return left.key < right.key end)
    return result
end

local function Compatible(rxp)
    local importer = rxp and rxp.guideImporter
    return rxp and rxp.version == FORMAT and type(rxp.guides) == "table"
        and type(rxp.db) == "table" and type(rxp.db.profile) == "table"
        and type(rxp.db.profile.guides) == "table" and type(importer) == "table"
        and type(importer.ImportString) == "function" and type(importer.AbortImport) == "function"
        and type(importer.ProcessInputBuffer) == "function" and type(importer.gui) == "table"
        and type(hooksecurefunc) == "function" and C_Timer and type(C_Timer.NewTicker) == "function"
end

function addon:GetRestedXPInstallation()
    local version = CallNative("GetAddOnMetadata", "RXPGuides", "Version")
    local rxp = GetRestedXP()
    local loaded = CallNative("IsAddOnLoaded", "RXPGuides") == true
    local installed = type(version) == "string" or loaded or rxp ~= nil
    local result = {
        installed = installed, loaded = loaded or rxp ~= nil,
        version = type(version) == "string" and version or rxp and tostring(rxp.release or "unknown") or "",
        guides = InstalledGuides(rxp), compatible = Compatible(rxp) == true,
    }
    if not result.installed then
        result.problem = "RestedXP Guides is not installed."
    elseif not result.loaded then
        result.problem = "Enable RestedXP Guides and reload the interface."
    elseif not result.compatible then
        result.problem = "This RestedXP importer is unsupported or still loading."
    end
    return result
end

function addon:GetRestedXPBattleTag()
    if type(BNGetInfo) == "function" then
        local success, _, tag = pcall(BNGetInfo)
        if success and type(tag) == "string" and tag:match("^.+#%d+$") then return tag end
    end
    return nil, "Your BattleTag is unavailable. Sign in to Battle.net before installing guides."
end

local function WorkerActive(rxp)
    local frame = rxp.workerFrame
    return frame and type(frame.GetScript) == "function" and frame:GetScript("OnUpdate") ~= nil
end

local function Busy(rxp)
    local importer = rxp.guideImporter
    return importer.importCoroutine ~= nil or (tonumber(importer.importBufferSize) or 0) > 0
        or importer.importReady == true or importer.cachedState ~= nil or WorkerActive(rxp)
end

local function Pause()
    if coroutine and coroutine.running() then coroutine.yield() end
end

-- These are source identities, not the character-specific keys produced by
-- ParseGuide. Keep conditional headers so faction/class variants stay intact.
local function SourceIdentity(raw)
    local fields = {}
    local games = { classic = true, tbc = true, wotlk = true, cata = true, mop = true,
        df = true, retail = true, forever = true }
    for line in raw:gmatch("[^\r\n]+") do
        if line:match("^%s*step%s*$") or line:match("^%s*step%s+") then break end
        local name, value = line:match("^%s*#([%a]+)%s*(.-)%s*$")
        if name == "group" or name == "subgroup" or name == "name" or games[name] then
            fields[#fields + 1] = name .. ":" .. tostring(#value) .. ":" .. value
        elseif line:match("^%s*<<") then
            fields[#fields + 1] = "condition:" .. line:match("^%s*(.-)%s*$")
        end
    end
    return table.concat(fields, "\n")
end

local function Snapshot(rxp)
    local cache = rxp and rxp.db and rxp.db.profile and rxp.db.profile.guides
    local snapshot = { cache = cache, profile = rxp and rxp.db and rxp.db.profile, entries = {}, count = 0 }
    if type(cache) ~= "table" then return snapshot end
    for key, entry in pairs(cache) do
        snapshot.count = snapshot.count + 1
        if snapshot.count > MAX_CACHE_ENTRIES then snapshot.overflow = true; break end
        snapshot.entries[key] = type(entry) == "table" and {
            entry = entry, data = entry.groupOrContent, text = entry.text, version = entry.version,
        } or { entry = entry }
    end
    return snapshot
end

local function SameSnapshot(rxp, snapshot)
    local cache = rxp and rxp.db and rxp.db.profile and rxp.db.profile.guides
    if cache ~= snapshot.cache or rxp.db.profile ~= snapshot.profile or type(cache) ~= "table" then return false end
    local count = 0
    for key, entry in pairs(cache) do
        count = count + 1
        if count > MAX_CACHE_ENTRIES then return snapshot.overflow == true end
        local previous = snapshot.entries[key]
        if not previous or previous.entry ~= entry or type(entry) == "table"
            and (previous.data ~= entry.groupOrContent or previous.text ~= entry.text or previous.version ~= entry.version) then
            return false
        end
    end
    return count == snapshot.count
end

local function MemoFor(rxp, codec)
    local profile = rxp and rxp.db and rxp.db.profile
    local cache = profile and profile.guides
    if not sourceMemo or sourceMemo.rxp ~= rxp or sourceMemo.profile ~= profile
        or sourceMemo.cache ~= cache or sourceMemo.codec ~= codec then
        sourceMemo = { rxp = rxp, profile = profile, cache = cache, codec = codec,
            sources = {}, normalized = {}, sourceCount = 0, sourceBytes = 0, normalizedCount = 0,
            normalizedBytes = 0, groups = {}, packBytes = 0 }
    end
    return sourceMemo
end

local function ForgetCompleted(memo)
    if memo then memo.completed, memo.acknowledgement = nil, nil end
end

function addon:ResetRestedXPSourceMemo()
    sourceMemo = nil
    return true
end

function addon:ResetRestedXPInventoryMemo()
    inventoryMemo = nil
    return true
end

local function NewMetrics()
    return { cacheHits = 0, decodedSources = 0, groupsBuilt = 0, groupsReused = 0 }
end

local function CopyInfo(info)
    local metrics = info.metrics or NewMetrics()
    return { complete = info.complete, skipped = info.skipped, problem = info.problem, busy = info.busy,
        metrics = { cacheHits = metrics.cacheHits, decodedSources = metrics.decodedSources,
            groupsBuilt = metrics.groupsBuilt, groupsReused = metrics.groupsReused } }
end

local function PrepareSource(codec, memo, raw)
    local prepared = memo.normalized[raw]
    if prepared then return prepared end
    local metadata = codec.SourceMetadata(raw)
    prepared = { raw = raw, metadata = metadata, identity = metadata and SourceIdentity(raw),
        version = metadata and GuideVersion(metadata.version) }
    if memo.normalizedCount < MAX_CACHE_ENTRIES and memo.normalizedBytes + #raw <= MAX_SCAN_BYTES then
        memo.normalized[raw] = prepared
        memo.normalizedCount, memo.normalizedBytes = memo.normalizedCount + 1, memo.normalizedBytes + #raw
    end
    return prepared
end

local function RecoverSource(codec, memo, compressed, maximum, metrics)
    local prepared = memo.sources[compressed]
    if prepared then
        metrics.cacheHits = metrics.cacheHits + 1
        if prepared.raw and #prepared.raw > maximum then return nil, "Installed guide sources exceed the supported size limit." end
        return prepared, prepared.problem
    end
    metrics.decodedSources = metrics.decodedSources + 1
    local raw, problem = codec.DecodeCachedSource(compressed, maximum)
    prepared = raw and PrepareSource(codec, memo, raw) or { problem = problem }
    -- Cache failures only when the full per-source allowance was tried. A
    -- failure under a nearly exhausted scan budget may be valid next time.
    local size = #compressed + (raw and #raw or 0)
    if (raw or maximum == MAX_SCAN_BYTES) and memo.sourceCount < MAX_CACHE_ENTRIES
        and memo.sourceBytes + size <= MAX_SOURCE_MEMO_BYTES then
        memo.sources[compressed] = prepared
        memo.sourceCount, memo.sourceBytes = memo.sourceCount + 1, memo.sourceBytes + size
    end
    return prepared, problem
end

local function MarkInstalledDirty(rxp, key, source)
    local watcher = installedWatcher
    if not watcher or watcher.rxp ~= rxp then return end
    watcher.dirty, watcher.changedAt = true, GetTime()
    watcher.changeSerial = watcher.changeSerial + 1
    local cache = rxp.db and rxp.db.profile and rxp.db.profile.guides
    if watcher.recentCache ~= cache or watcher.recentProfile ~= rxp.db.profile then
        watcher.recentCache, watcher.recent, watcher.recentCount, watcher.recentBytes = cache, {}, 0, 0
        watcher.recentProfile = rxp.db.profile
    end
    -- A post-hook sees the raw argument before the native cache's lossy keys
    -- can make equal-version replacements indistinguishable after a restart.
    local compressed = type(source) == "table" and source.groupOrContent or nil
    local raw = type(source) == "string" and source or nil
    if type(key) ~= "string" or not raw and type(compressed) ~= "string" then return end
    local previous = watcher.recent[key]
    local size = #(raw or compressed)
    local bytes = watcher.recentBytes - (previous and previous.size or 0) + size
    if not previous and watcher.recentCount >= MAX_CACHE_ENTRIES or bytes > MAX_SCAN_BYTES then return end
    watcher.serial = watcher.serial + 1
    watcher.recent[key] = { raw = raw, compressed = compressed, size = size, serial = watcher.serial }
    watcher.recentCount = watcher.recentCount + (previous and 0 or 1)
    watcher.recentBytes = bytes
end

local function WatchMethod(rxp, owner, method, cache)
    if type(owner) ~= "table" or type(owner[method]) ~= "function" or type(hooksecurefunc) ~= "function" then return end
    local methods = watchedOwners[owner]
    if not methods then methods = {}; watchedOwners[owner] = methods end
    if methods[method] then return end
    local success = pcall(hooksecurefunc, owner, method, function(key, source)
        if cache then MarkInstalledDirty(rxp, key, source) else MarkInstalledDirty(rxp) end
    end)
    if success then methods[method] = true end
end

local function AttachInstalledHooks(rxp)
    WatchMethod(rxp, rxp, "CacheGuide", true)
    WatchMethod(rxp, rxp.RXPGuides or _G.RXPGuides, "ImportGuide")
    WatchMethod(rxp, rxp.guideImporter, "ImportString")
    WatchMethod(rxp, rxp, "LoadCachedGuides")
end

function addon:StopWatchingRestedXPInstalledGuides()
    if not installedWatcher then return false end
    if installedWatcher.timer then installedWatcher.timer:Cancel() end
    installedWatcher = nil
    return true
end

function addon:WatchRestedXPInstalledGuides(callback)
    self:StopWatchingRestedXPInstalledGuides()
    if type(callback) ~= "function" or not C_Timer or type(C_Timer.NewTicker) ~= "function" then return false end
    local rxp = GetRestedXP()
    local watcher = { callback = callback, dirty = true, changedAt = GetTime(), serial = 0, changeSerial = 0,
        rxp = rxp, profile = rxp and rxp.db and rxp.db.profile, snapshot = rxp and Snapshot(rxp), nextPoll = GetTime() + 5,
        recent = {}, recentCount = 0, recentBytes = 0 }
    installedWatcher = watcher
    if rxp then AttachInstalledHooks(rxp) end
    watcher.timer = C_Timer.NewTicker(0.5, function()
        if installedWatcher ~= watcher then return end
        local rxp = GetRestedXP()
        local profile = rxp and rxp.db and rxp.db.profile
        if watcher.rxp ~= rxp or watcher.profile ~= profile then
            watcher.rxp, watcher.profile, watcher.snapshot = rxp, profile, rxp and Snapshot(rxp)
            watcher.recentCache, watcher.recent, watcher.recentCount, watcher.recentBytes = nil, {}, 0, 0
            watcher.recentProfile = nil
            watcher.dirty, watcher.changedAt = true, GetTime()
            watcher.changeSerial = watcher.changeSerial + 1
        end
        if not rxp then return end
        AttachInstalledHooks(rxp)
        if not watcher.nextPoll or GetTime() >= watcher.nextPoll then
            watcher.nextPoll = GetTime() + 5
            if not watcher.snapshot or not SameSnapshot(rxp, watcher.snapshot) then
                watcher.snapshot = Snapshot(rxp)
                watcher.dirty, watcher.changedAt = true, GetTime()
                watcher.changeSerial = watcher.changeSerial + 1
            end
        end
        if not watcher.dirty or not Compatible(rxp) or Busy(rxp) or GetTime() - watcher.changedAt < 0.5 then return end
        watcher.snapshot = Snapshot(rxp)
        watcher.dirty = false
        pcall(watcher.callback)
    end)
    return true
end

function addon:AcknowledgeRestedXPInstalledGuides()
    local watcher, memo, rxp = installedWatcher, sourceMemo, GetRestedXP()
    local acknowledged = inventoryMemo and inventoryMemo.acknowledgement or memo and memo.acknowledgement
    if not watcher or not acknowledged or watcher.rxp ~= rxp or acknowledged.watcher ~= watcher
        or acknowledged.changeSerial ~= watcher.changeSerial or not Compatible(rxp) or Busy(rxp)
        or not SameSnapshot(rxp, acknowledged.snapshot) then return false end
    watcher.profile = acknowledged.snapshot.profile
    watcher.snapshot, watcher.dirty, watcher.nextPoll = acknowledged.snapshot, false, GetTime() + 5
    return true
end

local function InventoryRecord(entry, key)
    if type(entry) ~= "table" then return {} end
    local metadata = type(entry.metadata) == "table" and entry.metadata or entry
    local nativeKey = GuideKey(metadata, entry.key or key)
    local group = metadata.group or nativeKey and nativeKey:match("^([^|]+)|")
    local guideID = metadata.guideId or metadata.guideid or nativeKey
    if type(guideID) == "number" and guideID == guideID and guideID > -math.huge and guideID < math.huge then
        guideID = string.format("%.17g", guideID)
    end
    if type(group) ~= "string" or group == "" or #group > 4096 or type(guideID) ~= "string"
        or guideID == "" or #guideID > 4096 then return {} end
    return { group = group, guideID = guideID, nativeKey = nativeKey,
        version = GuideVersion(metadata.version == nil and entry.version or metadata.version),
        capable = type(entry.groupOrContent) == "string" and #entry.groupOrContent > 0
            and #entry.groupOrContent <= 2097152 and entry.text == nil }
end

local function SameInventory(rxp, snapshot)
    local profile = rxp and rxp.db and rxp.db.profile
    if not profile or profile ~= snapshot.profile or profile.guides ~= snapshot.cache then return false end
    local count = 0
    for key, entry in pairs(profile.guides) do
        count = count + 1
        if count > MAX_CACHE_ENTRIES then return false end
        local old, current = snapshot.entries[key], InventoryRecord(entry, key)
        if not old or old.group ~= current.group or old.guideID ~= current.guideID or old.nativeKey ~= current.nativeKey
            or old.version ~= current.version or old.capable ~= current.capable then return false end
    end
    return count == snapshot.count
end

local function CopyInventory(items)
    local result = {}
    for _, item in ipairs(items) do
        result[#result + 1] = { id = item.id, label = item.label, revision = item.revision, guideCount = item.guideCount }
    end
    return result
end

local function CachedGroupID(self, group, identities)
    if identities[group] then return identities[group] end
    local id = "rxpi-" .. self.Crypto.Hex(self.Crypto.SHA256("LIT-RXP-INSTALLED-1\000" .. group, Pause)):sub(1, 24)
    identities[group] = id
    return id
end

local function ExpectedGuideVersions(pack)
    local expected = pack and pack.expectedGuides
    if type(expected) ~= "table" or #expected == 0 or #expected > MAX_CACHE_ENTRIES then return nil end
    local versions, count, bytes = {}, 0, 0
    for index, guide in pairs(expected) do
        if type(index) ~= "number" or index < 1 or index > #expected or index ~= math.floor(index)
            or type(guide) ~= "table" or type(guide.id) ~= "string" or #guide.id == 0 or #guide.id > 4096
            or type(guide.version) ~= "number" or guide.version ~= guide.version
            or guide.version <= -math.huge or guide.version >= math.huge or versions[guide.id] ~= nil then return nil end
        count, bytes = count + 1, bytes + #guide.id + 64
        if bytes > MAX_SCAN_BYTES then return nil end
        versions[guide.id] = guide.version
    end
    if count ~= #expected then return nil end
    return versions, count
end

-- Installed discovery deliberately compares guide IDs/versions without source.
-- Same-version source edits must not trigger preparation, download or import.
function addon:CollectRestedXPInstalledInventory()
    local rxp = GetRestedXP()
    local info = { complete = false, skipped = 0 }
    if not Compatible(rxp) then
        info.problem = self:GetRestedXPInstallation().problem or "RestedXP guide storage is unavailable."
        return nil, info
    end
    if Busy(rxp) then
        info.busy, info.problem = true, "Waiting for RestedXP to finish importing guides."
        return nil, info
    end
    local watcher, serial = installedWatcher, installedWatcher and installedWatcher.changeSerial
    if inventoryMemo and inventoryMemo.rxp == rxp and SameInventory(rxp, inventoryMemo.snapshot) then
        inventoryMemo.acknowledgement = { snapshot = Snapshot(rxp), watcher = watcher, changeSerial = serial }
        return CopyInventory(inventoryMemo.items), { complete = inventoryMemo.info.complete,
            skipped = inventoryMemo.info.skipped, problem = inventoryMemo.info.problem }
    end
    local profile, grouped, metadataBytes = rxp.db.profile, {}, 0
    local snapshot = { profile = profile, cache = profile.guides, entries = {}, count = 0 }
    for key, entry in pairs(profile.guides) do
        snapshot.count = snapshot.count + 1
        if snapshot.count > MAX_CACHE_ENTRIES then
            info.problem = "RestedXP guide storage exceeds the supported guide limit."
            return nil, info
        end
        local record = InventoryRecord(entry, key)
        snapshot.entries[key] = record
        if record.guideID then
            metadataBytes = metadataBytes + #record.group + #record.guideID + 64
            if metadataBytes > MAX_SCAN_BYTES then
                info.problem = "RestedXP guide metadata exceeds the supported size limit."
                return nil, info
            end
            local group = grouped[record.group] or {}
            grouped[record.group] = group
            local previous = group[record.guideID]
            if not previous or record.version > previous.version then
                previous = { version = record.version, entries = {} }
                group[record.guideID] = previous
            end
            if record.version == previous.version then
                previous.entries[#previous.entries + 1] = { key = key, record = record }
            end
        else info.skipped = info.skipped + 1 end
        if snapshot.count % 64 == 0 then Pause() end
    end
    local groups, result, names = {}, {}, {}
    for group in pairs(grouped) do names[#names + 1] = group end
    table.sort(names)
    for _, name in ipairs(names) do
        local ids, keys, nativeKeys, expectedGuides, revision = {}, {}, {}, {}, { "LIT-RXP-GUIDE-VERSIONS-1\000" }
        for id in pairs(grouped[name]) do ids[#ids + 1] = id end
        table.sort(ids)
        local count = 0
        for _, guideID in ipairs(ids) do
            local guide, capable = grouped[name][guideID], true
            for _, entry in ipairs(guide.entries) do if not entry.record.capable then capable = false end end
            if capable then
                count = count + 1
                local version = string.format("%.17g", guide.version)
                revision[#revision + 1] = #guideID .. ":" .. guideID .. #version .. ":" .. version
                expectedGuides[#expectedGuides + 1] = { id = guideID, version = guide.version }
                for _, entry in ipairs(guide.entries) do
                    keys[entry.key] = true
                    if entry.record.nativeKey then nativeKeys[entry.record.nativeKey] = true end
                end
            else info.skipped = info.skipped + 1 end
        end
        if count > 0 then
            local id = "rxpi-" .. self.Crypto.Hex(self.Crypto.SHA256("LIT-RXP-INSTALLED-1\000" .. name, Pause)):sub(1, 24)
            local hash = self.Crypto.Hex(self.Crypto.SHA256(table.concat(revision), Pause))
            local item = { id = id, label = name, revision = hash, guideCount = count }
            result[#result + 1], groups[id] = item, { id = id, revision = hash, keys = keys, nativeKeys = nativeKeys,
                expectedGuides = expectedGuides }
        end
        Pause()
    end
    if GetRestedXP() ~= rxp or Busy(rxp) or not SameInventory(rxp, snapshot) then
        info.busy, info.problem = true, "RestedXP guide versions changed while reading the installed inventory."
        return nil, info
    end
    info.complete = info.skipped == 0
    if info.skipped > 0 then info.problem = "Some imported guides have no supported metadata or complete cached source." end
    inventoryMemo = { rxp = rxp, snapshot = snapshot, items = result, groups = groups, info = info,
        acknowledgement = { snapshot = Snapshot(rxp), watcher = watcher, changeSerial = serial } }
    return CopyInventory(result), { complete = info.complete, skipped = info.skipped, problem = info.problem }
end

function addon:MatchesRestedXPCachedPack(pack)
    if type(pack) ~= "table" or not pack.cacheFormat or type(pack.id) ~= "string" or #pack.id > 40
        or not pack.id:match("^rxpi%-%x+$") then return false end
    local rxp = GetRestedXP()
    if not Compatible(rxp) or Busy(rxp) then return false end
    if pack.expectedGuides == nil then
        -- C1 packages did not describe their guide set. Retain the older exact
        -- group-revision check for those persisted transfers.
        local items = self:CollectRestedXPInstalledInventory()
        local group = items and inventoryMemo.groups[pack.id]
        return group ~= nil and group.revision == (pack.revision or pack.hash)
    end
    local expected, expectedCount = ExpectedGuideVersions(pack)
    if not expected then return false end
    local profile, found, groupIDs, count, bytes = rxp.db.profile, {}, {}, 0, 0
    local snapshot = { profile = profile, cache = profile.guides, entries = {}, count = 0 }
    for key, entry in pairs(snapshot.cache) do
        count = count + 1
        if count > MAX_CACHE_ENTRIES then return false end
        local record = InventoryRecord(entry, key)
        snapshot.entries[key], snapshot.count = record, count
        if record.guideID then
            bytes = bytes + #record.group + #record.guideID + 64
            if bytes > MAX_SCAN_BYTES then return false end
            if CachedGroupID(self, record.group, groupIDs) == pack.id then
                local previous = found[record.guideID]
                if previous == nil or previous < record.version then found[record.guideID] = record.version end
            end
        end
    end
    if GetRestedXP() ~= rxp or rxp.db.profile ~= profile or Busy(rxp) or not SameInventory(rxp, snapshot) then return false end
    local checked = 0
    for id, version in pairs(expected) do
        if found[id] ~= version then return false end
        checked = checked + 1
    end
    return checked == expectedCount
end

local function CollectSources(self, selection)
    local rxp = GetRestedXP()
    local info = { complete = false, skipped = 0, metrics = NewMetrics() }
    local memo = MemoFor(rxp, self.RestedXPCodec)
    if not Compatible(rxp) then
        ForgetCompleted(memo)
        info.problem = self:GetRestedXPInstallation().problem or "RestedXP guide storage is unavailable."
        return nil, info
    end
    if Busy(rxp) then
        ForgetCompleted(memo)
        info.busy, info.problem = true, "Waiting for RestedXP to finish importing guides."
        return nil, info
    end
    local codec = self.RestedXPCodec
    if not codec or type(codec.DecodeCachedSource) ~= "function" or type(codec.SourceMetadata) ~= "function" then
        info.problem = "Installed guide source conversion is unavailable."
        return nil, info
    end
    local watcher = installedWatcher
    if memo.completed and memo.completed.watcher == watcher
        and memo.completed.selection == (selection and selection.id or false)
        and memo.completed.revision == (selection and selection.revision)
        and memo.completed.changeSerial == (watcher and watcher.changeSerial)
        and SameSnapshot(rxp, memo.completed.snapshot) then
        local reused = CopyInfo(memo.completed.info)
        reused.metrics = NewMetrics()
        reused.metrics.cacheHits = #memo.completed.sources
        return memo.completed.sources, reused, rxp, memo.completed.snapshot, memo
    end
    ForgetCompleted(memo)
    local snapshot = Snapshot(rxp)
    if snapshot.overflow then
        info.problem = "RestedXP guide storage exceeds the supported guide limit."
        return nil, info
    end
    local recent = {}
    if watcher and watcher.rxp == rxp and watcher.recentCache == snapshot.cache and watcher.recentProfile == snapshot.profile then
        for key, entry in pairs(watcher.recent) do
            if not selection or selection.nativeKeys[key] then
            local prepared = entry.prepared
            if not prepared then
                if entry.raw then
                    local raw = codec.NormalizeSource(entry.raw)
                    prepared = raw and PrepareSource(codec, memo, raw) or {}
                else prepared = RecoverSource(codec, memo, entry.compressed, MAX_SCAN_BYTES, info.metrics) end
                entry.prepared = prepared
            else
                info.metrics.cacheHits = info.metrics.cacheHits + 1
            end
            local metadata = prepared and prepared.metadata
            if metadata then
                local identity = prepared.identity
                if not recent[identity] or recent[identity].serial < entry.serial then
                    recent[identity] = { hash = metadata.sourceHash, serial = entry.serial }
                end
            end
            Pause()
            end
        end
    end
    local selected, bytes, used = {}, 0, {}
    local keys = {}
    for key in pairs(snapshot.entries) do
        if not selection or selection.keys[key] then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
        local cache = rxp.db and rxp.db.profile and rxp.db.profile.guides
        local entry = snapshot.entries[key]
        if GetRestedXP() ~= rxp or Busy(rxp) or cache ~= snapshot.cache
            or cache[key] ~= entry.entry or type(entry.entry) == "table"
                and (entry.entry.groupOrContent ~= entry.data or entry.entry.text ~= entry.text) then
            info.busy, info.problem = true, "RestedXP guides changed during collection; waiting for its import to finish."
            return nil, info
        end
        local prepared, problem
        if type(entry.data) == "string" and entry.text == nil then
            prepared, problem = RecoverSource(codec, memo, entry.data, MAX_SCAN_BYTES - bytes, info.metrics)
            used[entry.data] = true
        end
        local raw, metadata = prepared and prepared.raw, prepared and prepared.metadata
        if not raw or not metadata then
            info.skipped = info.skipped + 1
            info.problem = problem or "Some installed guides have no recoverable complete source."
        else
            bytes = bytes + #raw
            if bytes > MAX_SCAN_BYTES then
                info.problem = "Installed guide sources exceed the supported size limit."
                return nil, info
            end
            local identity = prepared.identity
            local previous = selected[identity]
            local version = GuideVersion(metadata.version)
            if not previous or version > previous.version then
                selected[identity] = { raw = raw, metadata = metadata, version = version }
            elseif version == previous.version and metadata.sourceHash ~= previous.metadata.sourceHash then
                local newest = recent[identity]
                if newest and newest.hash == metadata.sourceHash then
                    selected[identity] = { raw = raw, metadata = metadata, version = version }
                elseif not newest or newest.hash ~= previous.metadata.sourceHash then
                    previous.conflict = true
                end
            end
        end
        Pause()
    end
    if GetRestedXP() ~= rxp or Busy(rxp) or not SameSnapshot(rxp, snapshot) then
        info.busy, info.problem = true, "RestedXP guides changed during collection; retrying after the import."
        return nil, info
    end
    local result = {}
    for _, entry in pairs(selected) do
        if entry.conflict then
            info.skipped = info.skipped + 1
            info.problem = "Conflicting installed guide sources have the same identity and version; import the current export in RestedXP."
        else
            result[#result + 1] = entry
        end
    end
    table.sort(result, function(a, b) return a.raw < b.raw end)
    -- Keep immutable recovery work only for the current native profile. A long
    -- session of updates must not retain every historical guide source.
    if not selection then
    local recovered, normalized, count, retainedBytes, normalizedCount, normalizedBytes = {}, {}, 0, 0, 0, 0
    for compressed in pairs(used) do
        local prepared = memo.sources[compressed]
        if prepared then
            recovered[compressed] = prepared
            if prepared.raw and not normalized[prepared.raw] then
                normalized[prepared.raw] = prepared
                normalizedCount, normalizedBytes = normalizedCount + 1, normalizedBytes + #prepared.raw
            end
            count = count + 1
            retainedBytes = retainedBytes + #compressed + (prepared.raw and #prepared.raw or 0)
        end
    end
    memo.sources, memo.normalized, memo.sourceCount, memo.sourceBytes = recovered, normalized, count, retainedBytes
    memo.normalizedCount, memo.normalizedBytes = normalizedCount, normalizedBytes
    end
    info.complete = info.skipped == 0
    memo.completed = { sources = result, info = CopyInfo(info), snapshot = snapshot, watcher = watcher,
        changeSerial = watcher and watcher.changeSerial, selection = selection and selection.id or false,
        revision = selection and selection.revision }
    return result, info, rxp, snapshot, memo
end

function addon:CollectRestedXPInstalledPacks()
    local sources, info, rxp, snapshot, memo = CollectSources(self)
    if not sources then return nil, info end
    local grouped, signatures, result = {}, {}, {}
    for _, source in ipairs(sources) do
        local group = source.metadata.group
        grouped[group] = grouped[group] or {}
        grouped[group][#grouped[group] + 1] = source.raw
        signatures[group] = signatures[group] or {}
        signatures[group][#signatures[group] + 1] = source.metadata.sourceHash
    end
    local names = {}
    for group in pairs(grouped) do names[#names + 1] = group end
    table.sort(names)
    local groupMemo, packBytes = {}, 0
    for _, group in ipairs(names) do
        local signature = tostring(#grouped[group]) .. ":" .. table.concat(signatures[group], ":")
        local cached = memo.groups[group]
        local pack, problem, id
        if cached and cached.signature == signature then
            pack, problem, id = cached.pack, cached.problem, cached.id
            info.metrics.groupsReused = info.metrics.groupsReused + 1
        else
            info.metrics.groupsBuilt = info.metrics.groupsBuilt + 1
            pack, problem = self.RestedXPCodec.FromSources(grouped[group])
        end
        if pack then
            if not id then
                local hash = self.Crypto.Hex(self.Crypto.SHA256("LIT-RXP-INSTALLED-1\000" .. group, Pause))
                id = "rxpi-" .. hash:sub(1, 24)
            end
            result[#result + 1] = { id = id, label = group, pack = pack }
        else
            info.complete, info.skipped = false, info.skipped + #grouped[group]
            info.problem = problem or "Some installed guide groups could not be prepared for sharing."
        end
        local size = pack and #pack.data or 0
        if packBytes + size <= MAX_PACK_MEMO_BYTES then
            groupMemo[group] = { signature = signature, pack = pack, problem = problem, id = id }
            packBytes = packBytes + size
        end
        Pause()
    end
    if GetRestedXP() ~= rxp or Busy(rxp) or not SameSnapshot(rxp, snapshot) then
        ForgetCompleted(memo)
        info.complete, info.busy, info.problem = false, true, "RestedXP guides changed while preparing shared packs; retrying after the import."
        return nil, info
    end
    memo.groups, memo.packBytes = groupMemo, packBytes
    memo.acknowledgement = { snapshot = snapshot, watcher = memo.completed.watcher,
        changeSerial = memo.completed.changeSerial }
    return result, info
end

function addon:PrepareRestedXPInstalledPack(id, revision)
    local inventory, info = self:CollectRestedXPInstalledInventory()
    if not inventory then return nil, info.problem or "RestedXP guide inventory is unavailable." end
    local selection = inventoryMemo and inventoryMemo.groups[id]
    if not selection or selection.revision ~= revision then
        return nil, "The installed guide versions changed. Check available guides again."
    end
    local rxp = GetRestedXP()
    local memo = MemoFor(rxp, self.RestedXPCodec)
    memo.prepared = memo.prepared or {}
    local cached = memo.prepared[id]
    if cached and cached.revision == revision then return cached.pack end
    local codec = self.RestedXPCodec
    if not codec or type(codec.FromCachedSources) ~= "function" then return nil, "Cached guide sharing is unavailable." end
    local keys, compressed, seen, bytes = {}, {}, {}, 0
    for key in pairs(selection.keys) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for index, key in ipairs(keys) do
        local entry = memo.cache[key]
        local source = type(entry) == "table" and entry.groupOrContent
        if type(source) ~= "string" or #source == 0 then return nil, "The cached guide source became unavailable." end
        if not seen[source] then
            bytes = bytes + #source
            if bytes > MAX_SCAN_BYTES then return nil, "The cached guide group exceeds the supported size limit." end
            compressed[#compressed + 1], seen[source] = source, true
        end
        if index % 64 == 0 then Pause() end
    end
    local pack, problem = codec.FromCachedSources(compressed, selection.expectedGuides)
    if not pack then return nil, problem end
    pack.id, pack.hash, pack.revision, pack.cacheFormat = id, revision, revision, true
    local current, currentInfo = self:CollectRestedXPInstalledInventory()
    local currentSelection = current and inventoryMemo.groups[id]
    if GetRestedXP() ~= rxp or rxp.db.profile ~= memo.profile or rxp.db.profile.guides ~= memo.cache then
        return nil, "The RestedXP profile changed while preparing this guide group."
    end
    if not currentSelection or currentSelection.revision ~= revision then
        return nil, currentInfo.problem or "The installed guide versions changed while preparing this group."
    end
    bytes = #pack.data
    for other, prepared in pairs(memo.prepared) do
        if other ~= id then bytes = bytes + #prepared.pack.data end
    end
    if bytes <= MAX_PACK_MEMO_BYTES then memo.prepared[id] = { revision = revision, pack = pack } end
    return pack
end

local function Observe(importer)
    if observations[importer] then return observations[importer] end
    local observation = { serial = 0 }
    local success = pcall(hooksecurefunc, importer, "ImportString", function()
        observation.serial = observation.serial + 1
    end)
    if not success then return nil end
    observations[importer] = observation
    return observation
end

local function Owns(job)
    return job.nativeStarted and job.rxp.guideImporter == job.importer and job.observation.serial == job.serial
        and (job.importer.importCoroutine == nil or job.importer.importCoroutine == job.coroutine)
end

local function ObserveGuideImports(rxp, crypto)
    local public = rxp.RXPGuides or _G.RXPGuides
    if type(public) ~= "table" or type(public.ImportGuide) ~= "function"
        or type(crypto) ~= "table" or type(crypto.SHA256) ~= "function" or type(crypto.Hex) ~= "function" then
        return false
    end
    if guideObservations[public] then return true end
    local success = pcall(hooksecurefunc, public, "ImportGuide", function(raw)
        local job = installation
        if not job or job.rxp ~= rxp or not Owns(job) or type(raw) ~= "string" then return end
        job.nativeGuideCalls = (job.nativeGuideCalls or 0) + 1
        if not job.importedContent then return end
        local cache = rxp.db and rxp.db.profile and rxp.db.profile.guides
        if type(cache) ~= "table" then return end
        local wroteGuide = false
        for key, value in pairs(cache) do
            if type(value) == "table" and job.observedCache[key] ~= value then
                wroteGuide = true
                job.observedCache[key] = value
            end
        end
        -- A processed input alone does not prove installation: native imports
        -- deliberately skip guides for another game without caching them.
        if wroteGuide then
            local hash = crypto.Hex(crypto.SHA256(raw))
            job.importedContent[hash] = (job.importedContent[hash] or 0) + 1
        end
    end)
    if not success then return false end
    guideObservations[public] = true
    return true
end

-- Native imports can already have changed RestedXP's guides when they stop.
-- Failure or cancellation cannot promise rollback of those changes.
local function Stop(job, abort)
    if job.timer then job.timer:Cancel(); job.timer = nil end
    if abort and Owns(job) and Busy(job.rxp) then pcall(job.importer.AbortImport, job.importer) end
    if installation == job then installation = nil end
end

function addon:CancelRestedXPInstallation()
    if not installation then return false end
    Stop(installation, true)
    return true
end

local function Finish(job, success, problem)
    local now = GetTime()
    local info = { unchanged = job.unchanged == true,
        conversionWall = math.max(0, (job.conversionFinished or now) - job.conversionStarted),
        nativeWall = job.nativeStartedAt and math.max(0, now - job.nativeStartedAt) or 0 }
    Stop(job, not success)
    if job.callback then pcall(job.callback, success, problem, info) end
end

local function NormalizeName(name)
    return name:gsub("^(%d)-(%d%d?)", function(low, high)
        return "0" .. low .. "-" .. (#high == 1 and "0" .. high or high)
    end)
end

local function Matches(metadata, expected, key)
    local version = GuideVersion(metadata.version)
    if version ~= GuideVersion(expected.version) then return false end
    local expectedKey = GuideKey(expected)
    local actualKey = GuideKey(metadata, key)
    if expectedKey and actualKey == expectedKey then return true end
    if type(expected.name) ~= "string" or type(expected.group) ~= "string" then return false end
    local group, subgroup, name
    if actualKey then group, subgroup, name = actualKey:match("^([^|]+)|([^|]*)|(.+)$") end
    group, subgroup, name = metadata.group or group, metadata.subgroup or subgroup, metadata.name or name
    return group == expected.group and (name == expected.name or name == NormalizeName(expected.name))
        and (subgroup == (expected.subgroup or "")
            or (not expected.subgroup or expected.subgroup == "") and subgroup == expected.group)
end

local function AppliesToGame(guide, game)
    local tagged = guide.classic or guide.tbc or guide.wotlk or guide.df or guide.retail or guide.cata or guide.mop or guide.forever
    if not tagged then return true end
    game = type(game) == "string" and game:lower() or ""
    return guide[game] ~= nil and guide[game] ~= false
        or game == "forever" and guide.classic ~= nil and guide.classic ~= false
        or game == "retail" and guide.df ~= nil and guide.df ~= false
end

local function MatchesCanonicalMetadata(rxp, pack)
    if not rxp or type(pack.guides) ~= "table" then return false end
    local installed, byKey, checked = InstalledGuides(rxp), {}, 0
    for _, guide in ipairs(installed) do byKey[guide.key] = guide end
    for _, expected in ipairs(pack.guides) do
        if type(expected) ~= "table" then return false end
        if AppliesToGame(expected, rxp.game) then
            checked = checked + 1
            local key = GuideKey(expected)
            local found = key and byKey[key] and Matches(byKey[key], expected, key)
            if not found then
                for _, guide in ipairs(installed) do
                    if Matches(guide, expected, guide.key) then found = true; break end
                end
            end
            if not found then return false end
        end
    end
    return checked > 0
end

function addon:MatchesRestedXPInstalledPack(pack)
    if type(pack) ~= "table" or type(pack.guides) ~= "table" then return false end
    local sources, _, rxp = CollectSources(self)
    if not sources then return false end
    local available, expected, checked = {}, {}, 0
    for _, source in ipairs(sources) do
        if AppliesToGame(source.metadata, rxp.game) then
            local hash = source.metadata.sourceHash
            available[hash] = (available[hash] or 0) + 1
        end
    end
    for _, guide in ipairs(pack.guides) do
        if AppliesToGame(guide, rxp.game) then
            local hash = guide.sourceHash
            if type(hash) ~= "string" then return false end
            checked = checked + 1
            expected[hash] = (expected[hash] or 0) + 1
            if expected[hash] > (available[hash] or 0) then return false end
        end
    end
    return checked > 0
end

local function Verify(job)
    local cache = job.rxp.db and job.rxp.db.profile and job.rxp.db.profile.guides
    if type(cache) ~= "table" then return false, "RestedXP guide storage became unavailable." end
    local fresh = {}
    for key, value in pairs(cache) do
        if type(value) == "table" and job.before[key] ~= value then fresh[#fresh + 1] = { key = key, value = value } end
    end
    if job.pack.cacheFormat then
        if GetRestedXP() ~= job.rxp then
            return false, "RestedXP did not confirm a fresh guide installation. Check its import window."
        end
        if not addon:MatchesRestedXPCachedPack(job.pack) then
            return false, "RestedXP did not confirm the expected guide IDs and versions. Check its import window."
        end
        if #fresh == 0 then
            if job.testImport and job.installedBefore and (job.nativeGuideCalls or 0) > 0 then
                job.unchanged = true
                return true
            end
            return false, "RestedXP did not confirm a fresh guide installation. Check its import window."
        end
        local groupIDs, expected = {}, job.pack.expectedGuides and ExpectedGuideVersions(job.pack)
        for _, item in ipairs(fresh) do
            local record = InventoryRecord(item.value, item.key)
            if record.group and CachedGroupID(addon, record.group, groupIDs) == job.pack.id
                and (not expected or expected[record.guideID] == record.version) then return true end
        end
        return false, "RestedXP did not confirm a fresh guide installation for this group."
    end
    if #fresh == 0 and job.testImport and job.installedBefore and (job.nativeGuideCalls or 0) > 0
        and GetRestedXP() == job.rxp and MatchesCanonicalMetadata(job.rxp, job.pack) then
        job.unchanged = true
        return true
    end
    local checked, expectedCounts = 0, {}
    for _, guide in ipairs(job.pack.guides) do
        if AppliesToGame(guide, job.rxp.game) then
            checked = checked + 1
            local found = false
            if guide.contentHash and job.importedContent then
                local hash = guide.contentHash
                expectedCounts[hash] = (expectedCounts[hash] or 0) + 1
                found = (job.importedContent[hash] or 0) >= expectedCounts[hash]
            else
                for _, item in ipairs(fresh) do
                    local metadata = type(item.value.metadata) == "table" and item.value.metadata or item.value
                    if Matches(metadata, guide, item.value.key or item.key) then found = true; break end
                end
            end
            if not found then return false, "RestedXP did not confirm every guide in the package. Use its native importer to check this package." end
        end
    end
    if checked == 0 or #fresh == 0 then return false, "The package contains no guides for this game." end
    return true
end

function addon:InstallRestedXPPack(pack, callback, options)
    local status = self:GetRestedXPInstallation()
    if not status.compatible then return false, status.problem, "unavailable" end
    if installation then return false, "A LIT guide installation is already running.", "busy" end
    if type(InCombatLockdown) == "function" and InCombatLockdown() then
        return false, "Leave combat before installing guides.", "combat"
    end
    local rxp = GetRestedXP()
    if Busy(rxp) then return false, "RestedXP is already importing guides. Wait for it to finish.", "busy" end
    if type(pack) ~= "table" or tonumber(pack.format) ~= FORMAT then
        return false, "This guide package has no supported import metadata."
    end
    if pack.cacheFormat then
        if type(pack.id) ~= "string" or #pack.id > 40 or not pack.id:match("^rxpi%-%x+$")
            or type(pack.revision) ~= "string" or #pack.revision ~= 64 or pack.revision:find("[^0-9a-f]")
            or pack.hash ~= pack.revision then return false, "The cached package has no supported guide ID and version." end
        if pack.expectedGuides ~= nil and not ExpectedGuideVersions(pack) then
            return false, "The cached package has an invalid guide ID and version manifest."
        end
    elseif type(pack.guides) ~= "table" or #pack.guides == 0 then
        return false, "This guide package has no supported import metadata."
    end
    local tag, problem = self:GetRestedXPBattleTag()
    if not tag then return false, problem end
    local codec = self.RestedXPCodec
    local encode = codec and (pack.cacheFormat and codec.EncodeCached or codec.Encode)
    if type(encode) ~= "function" then return false, "Guide conversion is unavailable." end
    local observation = Observe(rxp.guideImporter)
    if not observation then return false, "RestedXP import completion cannot be monitored safely." end
    local hasContentHashes = false
    local testImport = type(options) == "table" and options.test == true
    local function MatchesTestMetadata()
        if pack.cacheFormat then return self:MatchesRestedXPCachedPack(pack) end
        return MatchesCanonicalMetadata(rxp, pack)
    end
    if not pack.cacheFormat then
        for _, guide in ipairs(pack.guides) do
            if guide.contentHash then hasContentHashes = true; break end
        end
    end
    if (hasContentHashes or testImport) and not ObserveGuideImports(rxp, self.Crypto) then
        return false, "This RestedXP guide importer cannot be monitored safely.", "unavailable"
    end
    local job = {
        rxp = rxp, importer = rxp.guideImporter, pack = pack, callback = callback,
        observation = observation, started = GetTime(), importedContent = hasContentHashes and {},
        conversionStarted = GetTime(), testImport = testImport,
        installedBefore = testImport and MatchesTestMetadata() or false,
        preparation = coroutine.create(function() return encode(pack, tag) end),
    }
    installation = job
    job.timer = C_Timer.NewTicker(0.01, function()
        if installation ~= job then return end
        if GetTime() - job.started >= TIMEOUT then
            Finish(job, false, "RestedXP guide installation timed out. The previous package is retained by LIT.")
            return
        end
        if job.preparation then
            local success, export, failure = coroutine.resume(job.preparation)
            if not success then
                Finish(job, false, "The guide package could not be personalized.")
                return
            elseif coroutine.status(job.preparation) ~= "dead" then
                return
            elseif type(export) ~= "string" then
                Finish(job, false, failure or "The guide package could not be personalized.")
                return
            end
            job.conversionFinished = GetTime()
            job.preparation, job.export = nil, export
        end
        if not job.nativeStarted then
            if GetRestedXP() ~= rxp or rxp.guideImporter ~= job.importer or not Compatible(rxp) then
                Finish(job, false, "RestedXP became unavailable before guide installation.")
                return
            end
            -- Personalization yields across frames; combat or a user import can
            -- begin in the meantime. Wait without claiming or aborting that job.
            if type(InCombatLockdown) == "function" and InCombatLockdown() or Busy(rxp) then return end
            job.before, job.observedCache = {}, {}
            for key, value in pairs(rxp.db.profile.guides) do
                job.before[key], job.observedCache[key] = value, value
            end
            if job.testImport then job.installedBefore = job.installedBefore and MatchesTestMetadata() end
            job.nativeGuideCalls, job.nativeStartedAt = 0, GetTime()
            local started, accepted = pcall(job.importer.ImportString, job.importer, job.export)
            job.serial, job.coroutine = observation.serial, job.importer.importCoroutine
            job.nativeStarted, job.export, job.started = true, nil, GetTime()
            if not started or accepted ~= true then
                Finish(job, false, "RestedXP rejected the guide package. Check its import window for details.")
            end
            return
        end
        if job.nextCheck and GetTime() < job.nextCheck then return end
        job.nextCheck = GetTime() + 0.25
        if not Owns(job) then
            Finish(job, false, "Another RestedXP import replaced this installation.")
        elseif job.importer.gui.progressError then
            Finish(job, false, "RestedXP reported an import error. Check its import window for details.")
        elseif not Busy(rxp) then
            local success, failure = Verify(job)
            Finish(job, success, failure)
        end
    end)
    return true
end
