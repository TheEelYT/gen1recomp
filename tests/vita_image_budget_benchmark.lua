-- Host experiment with a large live Lua heap and native temporary buffers.
-- Run in separate processes: luajit tests/vita_image_budget_benchmark.lua baseline|budget
local ffi = require("ffi")
ffi.cdef[[void *malloc(size_t); void free(void *);]]
local realGC = collectgarbage
realGC("stop")
local live = {}
for i = 1, 240000 do live[i] = {id=i, label="entity-"..i, flags={1,2,3,4}} end
local nativeBytes, peakNative, fulls, seconds = 0, 0, 0, 0
local function temporary(n)
  local raw = ffi.C.malloc(n)
  assert(raw ~= nil, "host allocation failed")
  local p = ffi.gc(ffi.cast("uint8_t *", raw), function(ptr)
    ffi.C.free(ptr); nativeBytes = nativeBytes - n
  end)
  ffi.fill(p, n, 42)
  nativeBytes = nativeBytes + n
  return p
end
local startupSize = 50 * 1024 * 1024
local startup = temporary(startupSize)
startup = nil
collectgarbage = function(mode, ...)
  if mode ~= "collect" then return realGC(mode, ...) end
  local at = os.clock()
  local result = realGC(mode, ...)
  seconds = seconds + os.clock() - at
  fulls = fulls + 1
  return result
end
local Memory = require("src.core.game3.vita_image_memory")
local Trace = require("src.debug.VitaLoadTrace")
Trace.slow = function() end
_G.POKEPORT_VITA = true
love = {timer = {getTime = os.clock}}
local first, peakKB = true, 0
local function load()
  if first then assert(nativeBytes == 0, "startup native garbage was not reclaimed"); first = false end
  local scratch = temporary(256 * 1024)
  local values = {}
  for i = 1, 8192 do values[i] = i end
  peakNative = math.max(peakNative, nativeBytes)
  peakKB = math.max(peakKB, realGC("count"))
  return {getWidth = function() return 256 end, getHeight = function() return 256 end}
end
local mode = arg[1] or "budget"
assert(mode == "baseline" or mode == "budget")
Memory.reset()
for i = 1, 40 do
  if mode == "baseline" then collectgarbage("collect"); load()
  else Memory.load("fixture-"..i, load) end
end
local measuredFulls = fulls
realGC("collect")
assert(nativeBytes == 0, "native temporaries leaked")
assert(live[240000].id == 240000, "live game data lost")
if mode == "budget" then
  assert(measuredFulls < 40 and measuredFulls > 1)
  assert(peakNative <= 4 * 1024 * 1024, "native garbage budget exceeded")
end
print(("mode=%s images=40 fullGC=%d gcSeconds=%.4f peakLuaMiB=%.2f peakNativeTempMiB=%.2f startupFreedMiB=50")
  :format(mode, measuredFulls, seconds, peakKB/1024, peakNative/1024/1024))
collectgarbage = realGC
realGC("restart")
