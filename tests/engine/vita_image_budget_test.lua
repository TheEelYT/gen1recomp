package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
local Memory = require("src.core.game3.vita_image_memory")
local Ppu = require("src.core.game3.gba_ppu")
local realGC = collectgarbage
local kb, full, calls, clock, reasons, timings = 140 * 1024, 0, 0, 0, {}, {}
collectgarbage = function(mode)
  if mode == "count" then return kb end
  T.eq(mode, "collect", "budget does not introduce extra incremental GC steps")
  full, clock, kb = full + 1, clock + 1.45, 88 * 1024
end
love = {timer = {getTime = function() return clock end}, graphics = {}}
local Trace = require("src.debug.VitaLoadTrace")
local oldSlow = Trace.slow
Trace.slow = function(_, _, phase, seconds, reason)
  reasons[#reasons+1] = reason
  timings[#timings+1] = {phase = phase, seconds = seconds}
end
local function image(w, h)
  return {getWidth = function() return w or 8 end, getHeight = function() return h or 8 end,
    setFilter = function() end}
end
local function load()
  calls = calls + 1
  return image()
end
_G.POKEPORT_VITA = true
Memory.reset()
Memory.load("copyright", function()
  T.eq(full, 1, "startup garbage is collected before the very first image")
  T.eq(kb, 88 * 1024, "first image starts after loader garbage is reclaimed")
  return load()
end)
for i = 1, 20 do Memory.load("small-"..i, load) end
T.eq(full, 1, "small low-pressure cache misses do not rescan the live heap")
T.eq(reasons[1], "full/startup", "startup collection is labeled")
kb = kb + Memory.LUA_GROWTH_KB
Memory.load("lua-growth", load)
T.eq(full, 2, "Lua allocation growth triggers full cleanup")
T.eq(reasons[#reasons], "full/lua-growth", "growth collection is labeled")
kb = 64 * 1024
Memory.load("live-heap-shrank", load)
kb = kb + Memory.LUA_GROWTH_KB
Memory.load("growth-from-lower-heap", load)
T.eq(full, 3, "growth guard tracks a lower live-heap baseline")
Memory.reset(); full = 0
for i = 1, 4 do Memory.load("large-"..i, function() return image(512, 256) end) end
T.eq(full, 1, "four MiB of image traffic allowed after startup collection")
Memory.load("native-budget", load)
T.eq(full, 2, "native image activity triggers collection even at flat Lua heap size")
T.eq(reasons[#reasons], "full/image-budget", "native traffic collection is labeled")
Memory.reset(); full, calls = 0, 0
local function oomOnce()
  calls = calls + 1
  if calls == 1 then error("not enough memory") end
  return image()
end
T.check(Memory.load("pressure", oomOnce) ~= nil, "allocation failure can recover")
T.eq(calls, 2, "allocation failure retries exactly once")
T.eq(full, 2, "retry retains a full cleanup after initial startup cleanup")
T.eq(reasons[#reasons], "full/allocation-retry", "allocation retry is labeled")
calls = 0
T.eq(pcall(Memory.load, "persistent-oom", function() calls = calls + 1; error("out of memory") end),
  false, "persistent allocation failure propagates")
T.eq(calls, 2, "persistent pressure cannot enter a retry loop")
local before = full
calls = 0
T.eq(pcall(Memory.load, "broken", function() calls = calls + 1; error("bad PNG") end),
  false, "invalid assets still fail")
T.eq(calls, 1, "invalid asset is not retried")
T.eq(full, before, "invalid asset does not force another collection")
love.graphics.newImage = load
Ppu.clearCache(); full, calls = 0, 0
local a = Ppu.indexLayer("cached")
kb = kb + Memory.LUA_GROWTH_KB
T.eq(Ppu.indexLayer("cached"), a, "cache hit preserves image")
T.eq(full, 1, "cache hit performs no GC even under pressure")
Ppu.indexLayer("next")
T.eq(full, 2, "next uncached image observes allocation pressure")
Ppu.clearCache()
Ppu.indexLayer("new-cache")
T.eq(full, 3, "clearing cache restores startup cleanup")
local IndexedPng = require("src.core.game3.indexed_png")
local oldIndex = IndexedPng.indexImage
IndexedPng.indexImage = function() clock = clock + .2; return image() end
Ppu.clearCache()
Ppu.indexSheet("timed-sheet", 8, 8)
local timing = timings[#timings]
T.eq(timing.phase, "decode+upload", "indexed sheet retains its decode timing")
T.check(math.abs(timing.seconds - .2) < .000001, "sheet timing excludes the preceding full collection")
IndexedPng.indexImage = oldIndex
_G.POKEPORT_VITA = false
before = full
T.eq(Memory.load("desktop", load):getWidth(), 8, "desktop loader forwarded")
T.eq(full, before, "desktop collection behavior unchanged")
collectgarbage, Trace.slow = realGC, oldSlow
_G.POKEPORT_VITA = nil
T.finish("Vita image collection budgets and allocation recovery")
