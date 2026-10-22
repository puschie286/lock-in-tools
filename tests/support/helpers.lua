-- Shared mechanics for offline Lua 5.1 fixtures; addon behavior stays in each suite.
local function loadModule(file, addon, environment)
    local chunk, problem = loadfile(file)
    assert(chunk, problem)
    setfenv(chunk, environment)
    chunk("LockInTools", addon)
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function equal(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, item in pairs(left) do if not equal(item, right[key]) then return false end end
    for key in pairs(right) do if left[key] == nil then return false end end
    return true
end

local function capture(...) return { n = select("#", ...), ... } end

local function hooksecurefunc(environment, onHook)
    return function(owner, method, callback)
        if type(owner) == "string" then owner, method, callback = environment, owner, method end
        local original = assert(owner[method], tostring(method))
        if onHook then onHook(owner, method, callback) end
        owner[method] = function(...)
            -- Native hooks preserve every return value, including trailing nils.
            local result = capture(original(...))
            callback(...)
            return unpack(result, 1, result.n)
        end
    end
end

return { loadModule = loadModule, copy = copy, equal = equal, hooksecurefunc = hooksecurefunc }
