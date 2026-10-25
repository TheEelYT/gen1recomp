package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
local Pack = require("src.import.gba.native_pack")
local Layout = require("src.core.game3.layout_native")
local function blob(w, h)
  local cells = {}
  for i = 1, w * h do cells[i] = { mid = i % 1024, coll = i % 256, elev = i % 16 } end
  return Pack.encodeMidLayout({ width = w, height = h, borderMids = { 7 }, cells = cells })
end
local bytes = blob(32, 16)
_G.POKEPORT_VITA = false
local ordinary = assert(Pack.decodeMidLayout(bytes))
T.eq(type(ordinary.cells[1]), "table", "ordinary hosts retain table records")
_G.POKEPORT_VITA = true
local compact = assert(Pack.decodeMidLayout(bytes))
T.eq(type(compact.cells[1]), "cdata", "Vita uses owned compact native records")
T.eq(#compact.cells, #ordinary.cells, "array length is unchanged")
local count = 0
for i, c in ipairs(compact.cells) do
  count = count + 1
  local ref = ordinary.cells[i]
  T.eq(c.mid, ref.mid, "metatile value is unchanged")
  T.eq(c.coll, ref.coll, "collision value is unchanged")
  T.eq(c.elev, ref.elev, "elevation value is unchanged")
end
T.eq(count, 512, "normal ipairs visits every compact cell")
T.eq(Pack.encodeMidLayout(compact), bytes, "compact layout re-encodes identically")
compact.cells[1].coll = -1
compact.cells[2].coll = 163
T.eq(compact.cells[1].coll, -1, "signed collision sentinels survive mutation")
T.eq(compact.cells[2].coll, 163, "mod collision remapping survives mutation")
local map = Layout.fromDecoded(compact, "TEST", "TEST")
T.eq(map:collAt(0, 0), -1, "layout samples compact collisions")
T.eq(map:midAt(1, 0), ordinary.cells[2].mid, "layout samples compact metatiles")
local destination = Layout.fromDecoded(assert(Pack.decodeMidLayout(bytes)), "DEST", "TEST")
T.eq(destination:stamp(map, 0, 0), 512, "layout stamping accepts compact source cells")
T.eq(destination:collAt(1, 0), 163, "stamping preserves remapped collisions")
local retained = compact.cells[2]
compact, map = nil, nil
collectgarbage("collect")
T.eq(retained.coll, 163, "cell owns storage independently of its layout")
T.eq(Pack.decodeMidLayout(bytes:sub(1, #bytes - 1)), nil, "truncated cells are rejected before allocation")
T.eq(Pack.decodeMidLayout(bytes:sub(1, 15)), nil, "truncated headers are rejected")

local large = blob(128, 128)
local function retainedKiB(vita)
  _G.POKEPORT_VITA = vita
  collectgarbage("collect")
  local before = collectgarbage("count")
  local bank = {}
  for i = 1, 4 do bank[i] = assert(Pack.decodeMidLayout(large)) end
  collectgarbage("collect")
  local used = collectgarbage("count") - before
  T.eq(#bank[4].cells, 16384, "retained bank has complete layouts")
  return used
end
local normalKiB = retainedKiB(false)
local compactKiB = retainedKiB(true)
T.check(compactKiB < normalKiB * 0.6, "compact bank uses substantially less Lua memory")
print(("layout bank: tables %.1f KiB, compact %.1f KiB"):format(normalKiB, compactKiB))
T.finish("Vita native layout memory")
