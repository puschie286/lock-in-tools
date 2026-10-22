-- Load the actual embedded notification libraries into each isolated WoW mock.
local loadModule = dofile("tests/support/helpers.lua").loadModule

return function(addon, environment, captureOnly)
    local errors = {}
    environment._G = environment
    environment.geterrorhandler = function()
        return function(problem) errors[#errors + 1] = tostring(problem) end
    end
    environment.securecallfunction = function(callback, ...)
        local function capture(...) return { n = select("#", ...), ... } end
        local args = capture(...)
        local result = capture(xpcall(function()
            return callback(unpack(args, 1, args.n))
        end, environment.geterrorhandler()))
        if result[1] then return unpack(result, 2, result.n) end
    end
    environment.loadstring = function(source, name)
        local chunk, problem = loadstring(source, name)
        if chunk then setfenv(chunk, environment) end
        return chunk, problem
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
    if not captureOnly then
        local createFrame = environment.CreateFrame
        environment.CreateFrame = function(kind, name, ...)
            local frame = createFrame(kind, name, ...)
            if name == "AceEvent30Frame" then
                local setScript = frame.SetScript
                frame.SetScript = function(self, script, callback)
                    if script == "OnEvent" and callback then
                        local dispatch = callback
                        callback = function(...)
                            local before = #errors
                            dispatch(...)
                            assert(#errors == before, errors[before + 1])
                        end
                    end
                    return setScript(self, script, callback)
                end
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
    if not captureOnly then
        local function capture(...) return { n = select("#", ...), ... } end
        for _, name in ipairs({ "Notify", "EndNotificationBatch" }) do
            local original = addon[name]
            addon[name] = function(self, ...)
                local before = #errors
                local result = capture(original(self, ...))
                assert(#errors == before, errors[before + 1])
                return unpack(result, 1, result.n)
            end
        end
    end
    return errors
end
