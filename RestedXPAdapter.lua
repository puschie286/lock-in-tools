local _, addon = ...

-- RestedXP's format-40000 importer runs a coroutine and then parses one guide
-- per frame. Acceptance of ImportString is not installation confirmation.
local FORMAT = 40000
local TIMEOUT = 300
local observations = setmetatable({}, { __mode = "k" })
local guideObservations = setmetatable({}, { __mode = "k" })
local installation
local installedWatcher
local watchedOwners = setmetatable({}, { __mode = "k" })
local MAX_CACHE_ENTRIES, MAX_SCAN_BYTES = 10000, 16 * 1024 * 1024

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
    local snapshot = { cache = cache, entries = {}, count = 0 }
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
    if cache ~= snapshot.cache or type(cache) ~= "table" then return false end
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

local function MarkInstalledDirty(rxp, key, source)
    local watcher = installedWatcher
    if not watcher or watcher.rxp ~= rxp then return end
    watcher.dirty, watcher.changedAt = true, GetTime()
    local cache = rxp.db and rxp.db.profile and rxp.db.profile.guides
    if watcher.recentCache ~= cache then
        watcher.recentCache, watcher.recent, watcher.recentCount, watcher.recentBytes = cache, {}, 0, 0
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
    local watcher = { callback = callback, dirty = true, changedAt = GetTime(), serial = 0,
        recent = {}, recentCount = 0, recentBytes = 0 }
    installedWatcher = watcher
    watcher.timer = C_Timer.NewTicker(0.5, function()
        if installedWatcher ~= watcher then return end
        local rxp = GetRestedXP()
        if watcher.rxp ~= rxp then
            watcher.rxp, watcher.snapshot = rxp, nil
            watcher.recentCache, watcher.recent, watcher.recentCount, watcher.recentBytes = nil, {}, 0, 0
            watcher.dirty, watcher.changedAt = true, GetTime()
        end
        if not rxp then return end
        AttachInstalledHooks(rxp)
        if not watcher.nextPoll or GetTime() >= watcher.nextPoll then
            watcher.nextPoll = GetTime() + 5
            if not watcher.snapshot or not SameSnapshot(rxp, watcher.snapshot) then
                watcher.snapshot = Snapshot(rxp)
                watcher.dirty, watcher.changedAt = true, GetTime()
            end
        end
        if not watcher.dirty or not Compatible(rxp) or Busy(rxp) or GetTime() - watcher.changedAt < 0.5 then return end
        watcher.snapshot = Snapshot(rxp)
        watcher.dirty = false
        pcall(watcher.callback)
    end)
    return true
end

local function CollectSources(self)
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
    local codec = self.RestedXPCodec
    if not codec or type(codec.DecodeCachedSource) ~= "function" or type(codec.SourceMetadata) ~= "function" then
        info.problem = "Installed guide source conversion is unavailable."
        return nil, info
    end
    local snapshot = Snapshot(rxp)
    if snapshot.overflow then
        info.problem = "RestedXP guide storage exceeds the supported guide limit."
        return nil, info
    end
    local recent, watcher = {}, installedWatcher
    if watcher and watcher.rxp == rxp and watcher.recentCache == snapshot.cache then
        for _, entry in pairs(watcher.recent) do
            local raw = entry.raw and codec.NormalizeSource(entry.raw) or codec.DecodeCachedSource(entry.compressed, MAX_SCAN_BYTES)
            local metadata = raw and codec.SourceMetadata(raw)
            if metadata then
                local identity = SourceIdentity(raw)
                if not recent[identity] or recent[identity].serial < entry.serial then
                    recent[identity] = { hash = metadata.sourceHash, serial = entry.serial }
                end
            end
            Pause()
        end
    end
    local selected, bytes = {}, 0
    local keys = {}
    for key in pairs(snapshot.entries) do keys[#keys + 1] = key end
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
        local raw, problem
        if type(entry.data) == "string" and entry.text == nil then
            raw, problem = codec.DecodeCachedSource(entry.data, MAX_SCAN_BYTES - bytes)
        end
        local metadata = raw and codec.SourceMetadata(raw)
        if not raw or not metadata then
            info.skipped = info.skipped + 1
            info.problem = problem or "Some installed guides have no recoverable complete source."
        else
            bytes = bytes + #raw
            if bytes > MAX_SCAN_BYTES then
                info.problem = "Installed guide sources exceed the supported size limit."
                return nil, info
            end
            local identity = SourceIdentity(raw)
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
    info.complete = info.skipped == 0
    return result, info, rxp, snapshot
end

function addon:CollectRestedXPInstalledPacks()
    local sources, info, rxp, snapshot = CollectSources(self)
    if not sources then return nil, info end
    local grouped, result = {}, {}
    for _, source in ipairs(sources) do
        local group = source.metadata.group
        grouped[group] = grouped[group] or {}
        grouped[group][#grouped[group] + 1] = source.raw
    end
    local names = {}
    for group in pairs(grouped) do names[#names + 1] = group end
    table.sort(names)
    for _, group in ipairs(names) do
        local pack, problem = self.RestedXPCodec.FromSources(grouped[group])
        if pack then
            local hash = self.Crypto.Hex(self.Crypto.SHA256("LIT-RXP-INSTALLED-1\000" .. group, Pause))
            result[#result + 1] = { id = "rxpi-" .. hash:sub(1, 24), label = group, pack = pack }
        else
            info.complete, info.skipped = false, info.skipped + #grouped[group]
            info.problem = problem or "Some installed guide groups could not be prepared for sharing."
        end
        Pause()
    end
    if GetRestedXP() ~= rxp or Busy(rxp) or not SameSnapshot(rxp, snapshot) then
        info.complete, info.busy, info.problem = false, true, "RestedXP guides changed while preparing shared packs; retrying after the import."
        return nil, info
    end
    return result, info
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
        if not job or not job.importedContent or job.rxp ~= rxp or not Owns(job) or type(raw) ~= "string" then return end
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
    Stop(job, not success)
    if job.callback then pcall(job.callback, success, problem) end
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

function addon:InstallRestedXPPack(pack, callback)
    local status = self:GetRestedXPInstallation()
    if not status.compatible then return false, status.problem, "unavailable" end
    if installation then return false, "A LIT guide installation is already running.", "busy" end
    if type(InCombatLockdown) == "function" and InCombatLockdown() then
        return false, "Leave combat before installing guides.", "combat"
    end
    local rxp = GetRestedXP()
    if Busy(rxp) then return false, "RestedXP is already importing guides. Wait for it to finish.", "busy" end
    if type(pack) ~= "table" or tonumber(pack.format) ~= FORMAT or type(pack.guides) ~= "table" or #pack.guides == 0 then
        return false, "This guide package has no supported import metadata."
    end
    local tag, problem = self:GetRestedXPBattleTag()
    if not tag then return false, problem end
    local codec = self.RestedXPCodec
    if not codec or type(codec.Encode) ~= "function" then return false, "Guide conversion is unavailable." end
    local observation = Observe(rxp.guideImporter)
    if not observation then return false, "RestedXP import completion cannot be monitored safely." end
    local hasContentHashes = false
    for _, guide in ipairs(pack.guides) do
        if guide.contentHash then hasContentHashes = true; break end
    end
    if hasContentHashes and not ObserveGuideImports(rxp, self.Crypto) then
        return false, "This RestedXP guide importer cannot be monitored safely.", "unavailable"
    end
    local job = {
        rxp = rxp, importer = rxp.guideImporter, pack = pack, callback = callback,
        observation = observation, started = GetTime(), importedContent = hasContentHashes and {},
        preparation = coroutine.create(function() return codec.Encode(pack, tag) end),
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
