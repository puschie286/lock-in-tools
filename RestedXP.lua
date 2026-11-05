local _, addon = ...

-- Local import helper. RestedXP owns validation and installation;
-- this module only retargets an export and hands it to the native importer.
function addon:CleanupRestedXPData()
    if self.savedDataReadOnly then return false, "Saved preferences are read-only." end
    if type(self.db) ~= "table" then return false, "Saved preferences are not loaded yet." end
    -- All former guide packs, subscriptions and installation markers lived
    -- under this namespace, including the obsolete source-tag preference.
    -- Guide strings are never saved.
    self.db.restedxp = nil
    return true, "Old RestedXP data cleared from LockInTools. Use /reload to save the cleaned settings."
end

function addon:InitializeRestedXP()
    self:CleanupRestedXPData()
    if self.restedxpState then return end
    self.restedxpState = {}
    self:RegisterGameEvents({ "ADDON_LOADED", "PLAYER_LOGOUT" }, function(_, event, name)
        local state = self.restedxpState
        if event == "PLAYER_LOGOUT" then
            self:CleanupRestedXPData()
            self:StopRestedXPImportTracking()
            if state.timer then state.timer:Cancel() end
            state.job, state.timer, state.importing = nil, nil, nil
        elseif name == "RXPGuides" then self:Notify("RESTEDXP_CHANGED") end
    end)
end

function addon:GetRestedXPState()
    local result = self:GetRestedXPInstallation()
    local state = self.restedxpState
    local battleTag, problem = self:GetRestedXPBattleTag()
    if not battleTag then result.problem = result.problem or problem end
    result.busy = state and (state.job ~= nil or state.importing ~= nil) or false
    result.readOnly = self.savedDataReadOnly == true
    result.status = state and state.status
    result.error = state and state.error
    result.phase = state and state.phase
    result.current, result.total = state and state.current, state and state.total
    result.canImport = self.ready == true and result.compatible == true and battleTag ~= nil
        and not result.busy and not result.readOnly
    return result
end

function addon:ImportRestedXPString(raw)
    local state = self.restedxpState
    if not self.ready or not state then return false, "Still loading. Please try again after login." end
    if self.savedDataReadOnly then return false, "Saved preferences are read-only." end
    if state.job or state.importing then return false, "An import is already in progress." end
    local installation = self:GetRestedXPInstallation()
    if not installation.compatible then return false, installation.problem or "RestedXP is unavailable." end
    if type(raw) ~= "string" or issecretvalue and issecretvalue(raw)
        or #raw == 0 or #raw > self.RestedXPCodec.MAX_DATA then
        return false, "Paste a RestedXP export no larger than 2 MiB."
    end
    local destination, problem = self:GetRestedXPBattleTag()
    if not destination then return false, problem end
    if not C_Timer or type(C_Timer.NewTimer) ~= "function" then return false, "The import helper is unavailable." end

    local job = coroutine.create(function()
        return self.RestedXPCodec.Reencrypt(raw, "Player#1234", destination)
    end)
    state.job, state.status, state.error = job, "Preparing import...", nil
    state.phase, state.current, state.total = "preparing", nil, nil
    self:Notify("RESTEDXP_CHANGED")
    local function Finish(message, isError, phase)
        state.job, state.timer, state.status, state.error = nil, nil, message, isError == true
        state.importing, state.phase = nil, phase or (isError and "failed" or "unknown")
        self:Notify("RESTEDXP_CHANGED")
    end
    local function Step()
        state.timer = nil
        if state.job ~= job then return end
        local started = type(debugprofilestop) == "function" and debugprofilestop()
        for _ = 1, 8 do
            local success, converted, failure = coroutine.resume(job)
            if not success then Finish("Could not prepare the export. Check the import string.", true); return end
            if coroutine.status(job) == "dead" then
                if not converted then Finish(failure or "Could not prepare the export.", true); return end
                if self:GetRestedXPBattleTag() ~= destination then
                    Finish("Your BattleTag became unavailable or changed. Try importing again.", true)
                    return
                end
                local token = {}
                state.job, state.importing = nil, token
                state.phase, state.status = "importing", "Importing guides in RestedXP..."
                self:Notify("RESTEDXP_CHANGED")
                local function Progress(phase, current, total)
                    if state.importing ~= token then return end
                    if phase == "completed" then
                        Finish("Guide import completed.", false, phase)
                    elseif phase == "failed" then
                        Finish("Guide import failed. Check RestedXP's importer for details.", true, phase)
                    elseif phase == "cancelled" then
                        Finish("Guide import cancelled or replaced in RestedXP.", true, phase)
                    elseif phase == "unknown" then
                        Finish("Import status is unavailable. Check RestedXP's importer.", false, phase)
                    elseif phase == "importing" then
                        if state.current == current and state.total == total then return end
                        state.current, state.total = current, total
                        state.status = current and total and total > 0
                            and string.format("Importing guides: %d/%d (%d%%)", current, total, math.floor(current * 100 / total))
                            or "Importing guides in RestedXP..."
                        self:Notify("RESTEDXP_CHANGED")
                    end
                end
                local accepted, nativeProblem, monitored = self:ForwardRestedXPImport(converted, Progress)
                -- A native status callback may already have finished this job.
                if state.importing ~= token then return end
                if not accepted then
                    Finish(nativeProblem or "RestedXP could not start the import.", true)
                elseif not monitored then
                    Finish("Sent to RestedXP. Check its import window for the result.", false, "unknown")
                end
                return
            end
            if started and debugprofilestop() - started >= 2 then break end
        end
        state.timer = C_Timer.NewTimer(0.01, Step)
    end
    state.timer = C_Timer.NewTimer(0, Step)
    return true
end
