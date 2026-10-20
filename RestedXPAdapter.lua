local _, addon = ...

-- RestedXP's format-40000 importer runs a coroutine and then parses one guide
-- per frame. Acceptance of ImportString is not installation confirmation.
local FORMAT = 40000
local TIMEOUT = 300
local observations = setmetatable({}, { __mode = "k" })
local guideObservations = setmetatable({}, { __mode = "k" })
local installation

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
    local tagged = guide.classic or guide.tbc or guide.wotlk or guide.df or guide.retail or guide.cata
    if not tagged then return true end
    game = type(game) == "string" and game:lower() or ""
    return guide[game] ~= nil and guide[game] ~= false
        or game == "forever" and guide.classic ~= nil and guide.classic ~= false
        or game == "retail" and guide.df ~= nil and guide.df ~= false
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
