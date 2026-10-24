package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
local realOpen, opens, closed, log, now, fail = io.open, 0, 0, "stale", 10, false
io.open = function(path, mode)
  opens = opens + 1
  T.eq(path, "ux0:/data/g1r-loads.txt", "uses dedicated diagnostic path")
  if fail then return nil end
  if mode == "w" then log = "" end
  return { write = function(_, text) log = log .. text; return true end,
    close = function() closed = closed + 1; return true end }
end
love = { timer = { getTime = function() return now end } }
local Trace = require("src.debug.VitaLoadTrace")
_G.POKEPORT_VITA = false
Trace.slow("warm", "desktop", "slice", 1)
T.eq(opens, 0, "desktop never opens Vita log")
_G.POKEPORT_VITA = true
Trace.slow("warm", "fast", "slice", .01)
T.eq(opens, 0, "normal loads never write a file")
local Warm = require("src.core.game3.warm")
Warm.add("fixture\nmodule", function() now = now + .125 end)
Warm.step(.001)
T.check(log:find("warm=fixture module phase=slice ms=125.0", 1, true), "slow warm slice logged and label sanitized")
local Decode = require("src.core.game3.asset_decode")
Decode.sprite = function() now = now + .08; return {} end
local Stream = require("src.core.game3.asset_stream")
local owner = Stream.new("sprite", {}, "ROOT", function() now = now + .09; return {} end, function() end)
owner:get("fixture")
T.check(log:find("sprite=fixture phase=decode ms=80.0 route=sync", 1, true), "synchronous decode identified")
T.check(log:find("sprite=fixture phase=upload ms=90.0 route=sync", 1, true), "synchronous upload identified")
T.eq(closed, opens, "all log handles closed")
Trace.MAX_ENTRIES = 3
local before = opens
Trace.slow("warm", "capped", "slice", 1)
T.eq(opens, before, "diagnostic storage stays bounded")
package.loaded["src.debug.VitaLoadTrace"] = nil
Trace = require("src.debug.VitaLoadTrace")
fail = true
Trace.slow("warm", "disk unavailable", "slice", 1)
before = opens
Trace.slow("warm", "disabled", "slice", 1)
T.eq(opens, before, "IO failure disables logging without affecting loads")
io.open = realOpen
_G.POKEPORT_VITA = nil
T.finish("Vita slow load tracing")
