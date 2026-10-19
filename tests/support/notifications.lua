-- Load the actual embedded notification libraries into each isolated WoW mock.
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
    chunk("LockInTools", addon)
end

return function(addon, environment)
    local errors = {}
    environment._G = environment
    environment.geterrorhandler = function()
        return function(problem) errors[#errors + 1] = tostring(problem) end
    end
    if loadstring and setfenv then
        environment.loadstring = function(source, name)
            local chunk, problem = loadstring(source, name)
            if chunk then setfenv(chunk, environment) end
            return chunk, problem
        end
    end
    if type(environment.CreateFrame) ~= "function" then
        environment.CreateFrame = function(kind)
            assert(kind == "Frame", "AceEvent only needs a native event frame")
            local frame = { events = {} }
            function frame:RegisterEvent(event) self.events[event] = true end
            function frame:UnregisterEvent(event) self.events[event] = nil end
            function frame:SetScript(script, callback)
                assert(script == "OnEvent")
                self.onEvent = callback
            end
            return frame
        end
    end
    for _, file in ipairs({
        "Libs/LibStub/LibStub.lua",
        "Libs/CallbackHandler-1.0/CallbackHandler-1.0.lua",
        "Libs/AceEvent-3.0/AceEvent-3.0.lua",
        "Notifications.lua",
    }) do
        loadModule(file, addon, environment)
    end
    return errors
end
