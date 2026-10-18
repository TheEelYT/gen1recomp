-- ROM-free equivalence checks for the compact Vita import path.
package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
local Pack = require("src.import.gba.native_pack")
local Metatile = require("src.import.gba.metatile")
local Maps = require("src.import.gba.maps")
local Host = require("src.core.HostShell")
local Gc = require("src.import.ImportGc")
local Contract = require("src.import.CacheContract")
local noenv = function() return nil end

love = { system = { getOS = function() return "Linux" end } }
T.check(Host.canRestart(), "desktop retains its restart path")
_G.POKEPORT_VITA = true
T.check(not Host.canRestart(), "Vita uses the in-process launcher")
T.check(Gc.lowMemoryHost(noenv), "Vita imports use low-memory GC without handheld pacing")
_G.POKEPORT_VITA = nil

-- Synthetic layer pixels let us compare complete serialized outputs against
-- the existing desktop encoder, including the new upstream middle layer.
for i, name in ipairs({ "compositeIndexedUnder", "compositeIndexedOver", "compositeIndexedMiddle" }) do
  Metatile[name] = function(_, mid)
    local pixels = {}
    for n = 1, 256 do pixels[n] = (mid + n * i) % 256 end
    return pixels
  end
end
local raw = { 3 + 4096 * 5, 9 + 1024 + 4096 * 2 }
local rom = { u16 = function(_, off) return raw[off / 2 + 1] end }
local opts = { midLists = { test = { 0, 3, 9, 700 } } }
local function encode(vita)
  _G.POKEPORT_VITA = vita
  local grid = Maps.loadGrid(rom, { width = 2, height = 1, offset = 0 })
  grid.pair = "test"
  local writes = {}
  local cache = { write = function(_, path, bytes) writes[path] = bytes end }
  Pack.writeExtract(cache, "root", { test = { mapPals = {} } }, { M = grid },
    { M = { width = 1, height = 1, mids = { 9 } } }, { "test" }, {}, nil, nil,
    nil, nil, opts)
  return writes
end
local desktop, vita = encode(false), encode(true)
for path, bytes in pairs(desktop) do T.eq(vita[path], bytes, path .. " matches desktop") end
local mid = Pack.decodeIdx(assert(vita["root/native/test/mids_mid.idx"]))
T.eq(mid.midCount, 4, "precomputed full mid list retained")
T.eq(mid.midIds[4], 700, "unused full-atlas metatile retained")
local layout = Pack.decodeMidLayout(vita["root/native/layouts/M.mid"])
T.eq(layout.cells[1].elev, 5, "packed elevation preserved")
T.eq(layout.cells[2].mid, 9, "packed metatile preserved")
T.eq(layout.cells[2].coll, Pack.resolveLayoutColl(1, 1), "packed collision preserved")
for _, path in ipairs(Contract.requiredFilesFor("firered")) do
  T.check(not path:find("/pokemon_jump/", 1, true), "skipped minigame does not block Vita readiness")
end
_G.POKEPORT_VITA = nil
T.finish("vita import compatibility")
