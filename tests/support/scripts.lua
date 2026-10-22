-- Register hooks without replacing native handlers; dispatch the handler first.
local function HookScript(widget, name, callback)
    widget.scriptHooks[name] = widget.scriptHooks[name] or {}
    widget.scriptHooks[name][#widget.scriptHooks[name] + 1] = callback
end

local function RunScript(widget, name, ...)
    if widget.scripts[name] then widget.scripts[name](widget, ...) end
    for _, callback in ipairs(widget.scriptHooks[name] or {}) do callback(widget, ...) end
end

return HookScript, RunScript
