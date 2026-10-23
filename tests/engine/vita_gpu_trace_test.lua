package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
local Trace = require("src.debug.VitaGpuTrace")
local realOpen = io.open
local marker, files, opens, calls = nil, {}, 0, {}
local active, saved = {}, {}
local original = active
local failWrite = false
io.open = function(path, mode)
  opens = opens + 1
  if path:match("vita%-gpu%-debug%.txt$") then
    if not marker then return nil end
    return { read = function() return marker end, close = function() end }
  end
  if mode == "w" then files[path] = "" end
  return {
    write = function(_, text)
      if failWrite then return nil, "disk full" end
      files[path] = (files[path] or "") .. text
      return true
    end,
    flush = function() return true end,
    close = function() end,
  }
end
love = { graphics = {
  getStats = function() return { images = 5, texturememory = 4096, canvases = 7 } end,
  flushBatch = function() calls[#calls + 1] = "submit" end,
  push = function() saved[#saved + 1] = active end,
  setCanvas = function(target) active = target end,
  pop = function() active = table.remove(saved) end,
} }
_G.POKEPORT_VITA = false
T.eq(Trace.new(), nil, "desktop trace is disabled")
T.eq(opens, 0, "desktop does not probe Vita paths")
_G.POKEPORT_VITA = true
T.eq(Trace.new(), nil, "missing marker leaves rendering unchanged")
marker = "invalid"
T.eq(Trace.new(), nil, "invalid mode leaves tracing disabled")
marker = "trace\n"
local trace = Trace.new()
trace:beginFrame("emerald intro scene=scene1 frame=14 counter=2")
trace:checkpoint("background", { newImageData = function() error("must not read back") end })
trace:endFrame()
local path = "ux0:/data/g1r-render-0.txt"
T.check(files[path]:find("scene=scene1", 1, true), "intro context logged")
T.check(files[path]:find("textureBytes=4096", 1, true), "live graphics memory logged")
T.check(files[path]:find("background submitted", 1, true), "submission logged")
T.eq(#calls, 1, "trace mode submits without readback")
marker = "sync"
trace, calls = Trace.new(), {}
trace:beginFrame("sync test")
trace:checkpoint("composition", { newImageData = function()
  T.eq(active, nil, "readback target detached")
  calls[#calls + 1] = "readback"
  return { release = function() calls[#calls + 1] = "release" end }
end })
T.same(calls, { "submit", "readback", "release" }, "flush precedes readback and releases CPU data")
T.eq(active, original, "render state restored after readback")
trace:checkpoint("unsupported", { newImageData = function() error("no readback support") end })
T.eq(active, original, "render state restored after a readback error")
T.eq(trace.mode, "trace", "unsupported readback downgrades to trace")
T.check(files[path]:find("readback unavailable", 1, true), "readback error recorded")
trace:endFrame()
for i = 2, 241 do trace:beginFrame("rotation"); trace:endFrame() end
T.check(files[path]:match("^241 ") ~= nil, "first chunk rotates at frame 241")
T.check(files["ux0:/data/g1r-render-1.txt"]:match("^121 ") ~= nil, "previous chunk retained")
local n = 0
for _ in pairs(files) do n = n + 1 end
T.eq(n, 2, "long traces stay bounded to two files")
trace:beginFrame("write failure")
failWrite = true
trace:note("failure")
T.check(trace.disabled and trace.file == nil, "write failure closes trace without crashing")
calls = {}
trace:checkpoint("disabled", {})
T.eq(#calls, 0, "disabled trace no longer changes graphics submission")
-- Exercise the public renderer with tracing enabled, including the normal
-- BG, empty OBJ/window targets and final composition checkpoints.
failWrite, marker, calls = false, "sync", {}
local graphics = love.graphics
local function noop() end
for _, name in ipairs({ "origin", "setScissor", "setColor", "clear", "setShader", "setBlendMode", "draw" }) do
  graphics[name] = noop
end
love.image = { newImageData = function() return { setPixel = noop } end }
graphics.newImage = function() return { setFilter = noop, replacePixels = noop } end
graphics.newShader = function() return { send = noop } end
graphics.newCanvas = function()
  local target = { setFilter = noop }
  function target:newImageData()
    T.check(active ~= self, "PPU target detached before readback")
    return { release = noop }
  end
  return target
end
local Ppu = require("src.core.game3.gba_ppu")
local ppu = Ppu.new()
ppu.traceContext = "integration frame"
ppu:set("DISPCNT", Ppu.DISPCNT_BG0_ON)
ppu:setBg(0, 0, { image = {}, w = 16, h = 8 })
ppu:render()
T.eq(active, original, "PPU integration restores caller's render target")
for _, label in ipairs({ "bg0 size=16x8 affine=false", "objects count=0", "object window count=0", "composition" }) do
  T.check(files[path]:find(label .. " readback complete", 1, true), label .. " completed")
end
T.eq(ppu.trace.file, nil, "PPU closes its trace at frame end")
marker, calls = nil, {}
local normalPpu = Ppu.new()
normalPpu:render()
T.eq(normalPpu.trace, nil, "normal Vita rendering has no trace")
T.eq(#calls, 0, "normal Vita renderer does not add flush/readback checkpoints")
io.open = realOpen
_G.POKEPORT_VITA = nil
T.finish("Vita GPU trace")
