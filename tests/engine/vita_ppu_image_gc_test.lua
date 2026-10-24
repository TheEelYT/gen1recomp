-- Native decoder allocations do not contribute to Lua's GC threshold.
-- Ensure unreachable asset data can be freed before a new uncached image.
package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
local Ppu = require("src.core.game3.gba_ppu")
local IndexedPng = require("src.core.game3.indexed_png")
local dead, collected, loads
local function garbage()
  local value = {}
  return setmetatable({ value }, { __mode = "v" })
end
local function decode()
  collected, loads = dead[1] == nil, loads + 1
  return { setFilter = function() end, getWidth = function() return 8 end,
    getHeight = function() return 8 end }
end
love = { graphics = { newImage = decode } }
IndexedPng.indexImage = decode
collectgarbage("stop")
for _, vita in ipairs({ false, true }) do
  _G.POKEPORT_VITA = vita
  for _, kind in ipairs({ "layer", "sheet" }) do
    Ppu.clearCache()
    dead, collected, loads = garbage(), false, 0
    local function load()
      if kind == "layer" then return Ppu.indexLayer("fixture", 8, 8, 4) end
      return Ppu.indexSheet("fixture", 8, 8)
    end
    local image = load()
    T.eq(collected, vita, kind .. " collects stale data before native decode only on Vita")
    dead = garbage()
    T.eq(load(), image, kind .. " cache hit reuses image")
    T.eq(loads, 1, kind .. " cache hit does not decode again")
    T.check(dead[1] ~= nil, kind .. " cache hit does not force collection")
  end
end
collectgarbage("restart")
_G.POKEPORT_VITA = nil
T.finish("Vita PPU image allocation GC")
