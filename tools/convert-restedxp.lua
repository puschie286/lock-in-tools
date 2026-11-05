-- Invoked by convert-restedxp.ps1 from the checkout root. Only the first stdin
-- line is metadata; the remainder stays opaque input for the shared codec.
local addon = {}
assert(loadfile("RestedXPCodec.lua"))("LockInTools", addon)
local sourceTag = io.read("*l")
local raw = io.read("*a")
local converted, problem = addon.RestedXPCodec.Reencrypt(raw, sourceTag, "Player#1234")
if not converted then
    io.stderr:write(problem, "\n")
    os.exit(1)
end
io.write(converted)
