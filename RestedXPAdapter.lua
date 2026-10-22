local _, addon = ...
local FORMAT = 40000
local observers = setmetatable({}, { __mode = "k" })
local tracking

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

-- Skin capabilities are independent of the importer's format/version checks.
function addon:GetRestedXPAddon()
    return GetRestedXP()
end

local function Compatible(rxp)
    return rxp and rxp.version == FORMAT and type(rxp.guideImporter) == "table"
        and type(rxp.guideImporter.ImportString) == "function"
end

function addon:GetRestedXPInstallation()
    local version = CallNative("GetAddOnMetadata", "RXPGuides", "Version")
    local rxp = GetRestedXP()
    local loaded = CallNative("IsAddOnLoaded", "RXPGuides") == true
    local result = {
        installed = type(version) == "string" or loaded or rxp ~= nil,
        loaded = loaded or rxp ~= nil,
        compatible = Compatible(rxp) == true,
    }
    if not result.installed then
        result.problem = "Install RestedXP Guides before importing an export."
    elseif not result.loaded then
        result.problem = "Enable RestedXP Guides and reload the interface."
    elseif not result.compatible then
        result.problem = "RestedXP's importer is unavailable. Enable or update RestedXP, then reload."
    end
    return result
end

function addon:GetRestedXPBattleTag()
    if type(BNGetInfo) == "function" then
        local success, _, tag = pcall(BNGetInfo)
        if success and type(tag) == "string" and tag:match("^.+#%d+$") then return tag end
    end
    return nil, "Your BattleTag is unavailable. Sign in to Battle.net before importing guides."
end

local function Busy(rxp)
    local importer = rxp.guideImporter
    if importer.importCoroutine ~= nil or (tonumber(importer.importBufferSize) or 0) > 0
        or importer.importReady == true or importer.cachedState ~= nil then return true end
    local frame = rxp.workerFrame
    return frame and type(frame.GetScript) == "function" and frame:GetScript("OnUpdate") ~= nil
end

local messages = {
    importing = "Importing guides in RestedXP...",
    completed = "RestedXP completed the import.",
    failed = "RestedXP reported an import error. Check its import window.",
    cancelled = "The RestedXP import was cancelled or replaced.",
    unknown = "RestedXP import progress is unavailable. Check its import window.",
}

local function Detach(job)
    if job.timer then job.timer:Cancel(); job.timer = nil end
    if tracking == job then tracking = nil end
end

local function Emit(job, phase)
    if tracking ~= job or not job.accepted then return end
    local current, total = job.current, job.total
    if job.lastPhase == phase and job.lastCurrent == current and job.lastTotal == total then return end
    job.lastPhase, job.lastCurrent, job.lastTotal = phase, current, total
    if phase ~= "importing" then Detach(job) end
    -- Callback failures must never interrupt RestedXP's native worker.
    pcall(job.callback, phase, current, total, messages[phase])
end

local function FlushSoon(job)
    if job.timer then return end
    job.timer = C_Timer.NewTimer(0, function()
        job.timer = nil
        if tracking ~= job or not job.accepted then return end
        if GetRestedXP() ~= job.rxp or job.rxp.guideImporter ~= job.importer then
            Emit(job, "unknown")
            return
        end
        local phase = job.phase or (job.aborted and "cancelled" or "importing")
        job.phase = nil
        if job.aborted and phase == "importing" then phase = "cancelled" end
        Emit(job, phase)
    end)
end

local function Observe(rxp)
    local importer = rxp.guideImporter
    if type(hooksecurefunc) ~= "function" or not C_Timer or type(C_Timer.NewTimer) ~= "function"
        or type(importer.UpdateImportStatusHistory) ~= "function" or type(importer.AbortImport) ~= "function"
        or type(rxp.locale) ~= "table" or type(rxp.locale.Get) ~= "function" then return nil end
    local okay, completed = pcall(rxp.locale.Get, "Guides Loaded Successfully")
    if not okay or type(completed) ~= "string" or completed == "" then return nil end
    local observer = observers[importer]
    if not observer then observer = {}; observers[importer] = observer end
    local function Hook(method, callback)
        if observer[method] then return true end
        local success = pcall(hooksecurefunc, importer, method, callback)
        if success then observer[method] = true end
        return success
    end
    if not Hook("UpdateImportStatusHistory", function(_, data, isError, ...)
        local job = tracking
        if not job or job.importer ~= importer then return end
        if isError then job.phase = "failed"
        elseif data == job.completed and job.phase ~= "failed" then job.phase = "completed"
        elseif type(data) == "string" and job.phase ~= "failed" and job.phase ~= "completed" then
            local formatted, message = pcall(string.format, data, ...)
            local current, total
            if formatted then current, total = message:match("(%d+)/(%d+)") end
            current, total = tonumber(current), tonumber(total)
            if current and total and total > 0 and current <= total and total < math.huge then
                if current == job.current and total == job.total and not job.aborted then return end
                job.current, job.total, job.phase = current, total, "importing"
            else return end
        else return end
        -- Defer until the native call returns: replacement imports must not
        -- attribute their initial status to the import being observed.
        FlushSoon(job)
    end) or not Hook("ImportString", function()
        local job = tracking
        if job and job.importer == importer and not job.calling then Emit(job, "cancelled") end
    end) or not Hook("AbortImport", function()
        local job = tracking
        if job and job.importer == importer then job.aborted = true; FlushSoon(job) end
    end) then return nil end
    return completed
end

function addon:StopRestedXPImportTracking()
    if tracking then Detach(tracking) end
end

function addon:ForwardRestedXPImport(raw, callback)
    if type(raw) ~= "string" or raw == "" then return false, "Paste a RestedXP export before importing." end
    -- Conversion can yield across frames. Check the live importer again here,
    -- immediately before handing it the converted string.
    local status = self:GetRestedXPInstallation()
    if not status.compatible then return false, status.problem end
    local rxp = GetRestedXP()
    if not Compatible(rxp) then return false, "RestedXP became unavailable. Reload and try the import again." end
    if type(InCombatLockdown) == "function" and InCombatLockdown() then
        return false, "Leave combat before importing guides."
    end
    if Busy(rxp) then return false, "RestedXP is already importing guides. Wait for it to finish." end
    local completed = type(callback) == "function" and Observe(rxp)
    local job
    if completed then
        self:StopRestedXPImportTracking()
        job = { rxp = rxp, importer = rxp.guideImporter, callback = callback, completed = completed, calling = true }
        tracking = job
    end
    local success, accepted = pcall(rxp.guideImporter.ImportString, rxp.guideImporter, raw)
    if job then job.calling = false end
    if not success or accepted ~= true then
        if job then Detach(job) end
        return false, success and "RestedXP rejected the export. Check its import window for details."
            or "RestedXP could not start the import. Check its import window and try again.", false
    end
    if job then job.accepted = true; FlushSoon(job) end
    -- Acceptance is separate from the optional later native status callbacks.
    return true, nil, job ~= nil
end
