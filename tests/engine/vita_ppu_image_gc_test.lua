-- Successful image loads must not scan the entire live game heap. Allocation
-- pressure still gets one full collection/retry, and temporary handles close.
package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
local Ppu = require("src.core.game3.gba_ppu")
local IndexedPng = require("src.core.game3.indexed_png")
local realGC, realIndex = collectgarbage, IndexedPng.indexImage
local steps, full, loads, released, fail = 0, 0, 0, 0
collectgarbage = function(mode)
  if mode == "step" then steps = steps + 1 elseif mode == "collect" then full = full + 1 end
  return 0
end
local function data() return {release = function() released = released + 1 end} end
local function image()
  loads = loads + 1
  if fail then local err = fail; fail = nil; error(err) end
  return {setFilter = function() end, getWidth = function() return 8 end, getHeight = function() return 8 end}
end
love = {graphics = {newImage = image}, image = {newImageData = data}}
IndexedPng.indexImage = image
for _, vita in ipairs({false, true}) do
  _G.POKEPORT_VITA = vita
  for _, kind in ipairs({"layer", "sheet"}) do
    Ppu.clearCache()
    steps, full, loads, released = 0, 0, 0, 0
    local function load()
      if kind == "layer" then return Ppu.indexLayer("fixture", 8, 8, 4) end
      return Ppu.indexSheet("fixture", 8, 8)
    end
    local img = load()
    T.eq(full, 0, kind .. " successful load never forces a full GC")
    T.eq(steps, vita and 1 or 0, kind .. " Vita advances incremental GC")
    T.eq(load(), img, kind .. " cache hit reuses image")
    T.eq(loads, 1, kind .. " cache hit does not decode again")
    T.eq(steps, vita and 1 or 0, kind .. " cache hit does not step GC")
    Ppu.clearCache(); fail = "out of memory"
    if vita then
      T.check(pcall(load), kind .. " allocation failure recovers")
      T.eq(full, 1, kind .. " allocation failure forces one full collection")
    else
      T.eq(pcall(load), false, kind .. " desktop failure unchanged")
      T.eq(full, 0, kind .. " desktop failure does not add collection")
    end
    Ppu.clearCache(); fail = "bad PNG"
    local before = full
    T.eq(pcall(load), false, kind .. " non-memory error propagates")
    T.eq(full, before, kind .. " corrupt asset never triggers full GC")
  end
end
_G.POKEPORT_VITA = true
Ppu.clearCache(); steps, full, loads, released = 0, 0, 0, 0
fail = "not enough memory"
Ppu.indexLayer("release-retry")
T.eq(released, 2, "temporary data handles released after failed and successful upload")
IndexedPng.load = function() return {} end
IndexedPng.indexImageData = data
loads, released = 0, 0
realIndex("sheet")
T.eq(released, 1, "indexed sheet releases temporary data")
fail = "upload error"
T.eq(pcall(realIndex, "sheet"), false, "indexed sheet upload error propagates")
T.eq(released, 2, "indexed sheet releases temporary data after upload error")
-- Shader programs survive a new PPU; render targets and palette data do not.
local compiled = 0
love.graphics.newShader = function() compiled = compiled + 1; return {} end
love.graphics.newCanvas = image
local a, b = Ppu.new():_ensureGpu(), Ppu.new():_ensureGpu()
T.eq(compiled, 3, "Vita compiles the GBA programs once")
T.eq(a.bgShader, b.bgShader, "new Vita PPU reuses BG program")
T.eq(a.composeShader, b.composeShader, "new Vita PPU reuses composition program")
T.check(a.out ~= b.out and a.palData ~= b.palData, "each PPU keeps independent render data")
_G.POKEPORT_VITA = false
Ppu.new():_ensureGpu(); Ppu.new():_ensureGpu()
T.eq(compiled, 9, "desktop PPU shader lifetime unchanged")
collectgarbage, IndexedPng.indexImage = realGC, realIndex
_G.POKEPORT_VITA = nil
T.finish("Vita PPU image pressure and shader reuse")
