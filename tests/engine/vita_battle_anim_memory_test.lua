-- ROM-free integration: exercise the real LZ decoder, PNG encoder and pack
-- writer with a wide background and every battle image extraction path.
package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
local Versions = require("src.import.gba.versions")
local CacheBlob = require("src.import.CacheBlob")
Versions.select("emerald")
local Extract = require("src.import.gba.battle_anim_extract")
local function le(n, size)
  local bytes = {}
  for i = 1, size do bytes[i], n = string.char(n % 256), math.floor(n / 256) end
  return table.concat(bytes)
end
local chunks, size = {}, 16
chunks[1] = string.rep("\0", size)
local function add(bytes)
  local off = size
  chunks[#chunks + 1], size = bytes, size + #bytes
  return off
end
local function ptr(off) return le(0x08000000 + off, 4) end
local function lz(bytes)
  local out = { "\16" .. le(#bytes, 3) }
  for i = 1, #bytes, 8 do out[#out + 1] = "\0" .. bytes:sub(i, i + 7) end
  return add(table.concat(out))
end
local palette = {}
for i = 0, 15 do palette[#palette + 1] = le(i + i * 32 + i * 1024, 2) end
palette = table.concat(palette)
local pal = lz(palette)
local tiles = lz(string.rep("\16\50\84\118\152\186\220\254", 512))
-- Tile flips and index zero test transparency, indexed alpha, row boundaries
-- and the second 32x32 screen block in a 512x256 background.
local mapBytes = {}
for i = 0, 2047 do mapBytes[#mapBytes + 1] = le(i % 128 + (i % 4) * 1024, 2) end
local map = lz(table.concat(mapBytes))
local maskMap = lz(table.concat(mapBytes):sub(1, 2048))
local script = add("\0" .. le(10000, 2) .. "\8")
local moves = add(ptr(script))
local pics = add(ptr(tiles) .. le(4096, 4))
local pals = add(ptr(pal) .. le(10000, 4))
local bgs = add(ptr(tiles) .. ptr(pal) .. ptr(map))
local quiet = add(le(1, 2) .. le(0xFFFF, 2))
Versions.BATTLE_ANIMS = {
  moves_table = moves, move_count = 1, sprites_start = 10000,
  tag_count = 1, pic_table = pics, pal_table = pals,
  bg_table = bgs, bg_count = 1, quiet_bgm_moves = quiet,
  named_bgs = { transparent = { gfx = tiles, map = map, pal = pal } },
  smokescreen_gfx = tiles, smokescreen_pal = pal,
  substitute_pal = pal, substitute_front = tiles, substitute_back = tiles,
  stat_mask_gfx = tiles, stat_mask_pal = pal,
  stat_mask_pals = { pal, pal, pal, pal, pal, pal, pal, pal },
  stat_mask_tilemap1 = maskMap, stat_mask_tilemap2 = maskMap,
}
local data = table.concat(chunks)
chunks, mapBytes = nil, nil
local rom = { size = #data }
function rom:get(off) return data:byte(off + 1) end
function rom:u16(off) return self:get(off) + self:get(off + 1) * 256 end
function rom:u32(off) return self:u16(off) + self:u16(off + 2) * 65536 end
function rom:ptrOffset(addr)
  local off = addr - 0x08000000
  if off >= 0 and off < self.size then return off end
end

local deflate = CacheBlob.deflate
-- Warm up zlib's lazy binding so the memory comparison measures extraction.
deflate("warmup")
local function run(vita)
  _G.POKEPORT_VITA = vita
  collectgarbage("collect")
  local baseline, peak = collectgarbage("count"), 0
  CacheBlob.deflate = function(...)
    peak = math.max(peak, collectgarbage("count") - baseline)
    return deflate(...)
  end
  local files = {}
  local result = Extract.run(rom, { write = function(_, path, bytes)
    files[path] = bytes
  end }, { force = true, strict = true })
  CacheBlob.deflate = deflate
  T.eq(result.tagCount, 1, "fixture tag extracted")
  return files, peak
end
local desktop, desktopPeak = run(false)
local vita, vitaPeak = run(true)
local count = 0
for path, bytes in pairs(desktop) do
  count = count + 1
  T.eq(vita[path], bytes, "byte-identical " .. path)
end
for path in pairs(vita) do T.check(desktop[path] ~= nil, "no extra output " .. path) end
T.eq(count, 13, "all tag, background, smoke, doll, mask and pack files written")
local pack = assert(loadstring(vita["data/generated/gba/pokemon/battle_anims/pack.lua"]))()
T.eq(pack.animBgs[0].w, 512, "largest supported background width")
T.eq(pack.animBgs[0].h, 256, "largest supported background height")
T.check(vitaPeak < desktopPeak * 0.5, "Vita peak is less than half the desktop peak")
print(("battle extraction Lua heap increase: desktop %.2f MiB, Vita %.2f MiB")
  :format(desktopPeak / 1024, vitaPeak / 1024))
-- The module must still work in a Lua runtime without FFI pixel buffers.
local ffi = package.loaded.ffi
package.loaded.ffi = {}
Extract = assert(loadfile("src/import/gba/battle_anim_extract.lua"))()
package.loaded.ffi = ffi
local fallback = run(true)
for path, bytes in pairs(desktop) do
  T.eq(fallback[path], bytes, "FFI-free byte-identical " .. path)
end
_G.POKEPORT_VITA = nil
T.finish("Vita battle animation memory")
