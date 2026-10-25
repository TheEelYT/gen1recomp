package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
love = require("tests.love_stub")
local Sample = require("src.core.game3.m4a_sample")
local Player = require("src.core.game3.m4a_player")
local Version = require("src.core.GameVersion")
local bytes = {}
for i = 0, 1023 do bytes[#bytes + 1] = string.char((i * 37) % 256) end
bytes = table.concat(bytes)
local payload, views, fullReads, releases = setmetatable({}, {__mode = "k"}), 0, 0, 0
local function data(s)
  local p = newproxy(true)
  payload[p] = s
  getmetatable(p).__index = {
    typeOf = function(_, name) return name == "Data" end,
    getSize = function(self) return #payload[self] end,
    getString = function() fullReads = fullReads + 1; error("must not copy entire bank") end,
  }
  return p
end
local bank = data(bytes)
love.data = {newDataView = function(parent, off, size)
  views = views + 1
  return {getString = function() return payload[parent]:sub(off + 1, off + size) end,
    release = function() releases = releases + 1 end}
end}
for _, slice in ipairs({{0, 1}, {0, 256}, {127, 321}, {1023, 1}, {0, 1024}}) do
  local meta = {offset = slice[1], size = slice[2]}
  T.eq(Sample.loadPcm(bank, meta), Sample.loadPcm(bytes, meta), "shared slice matches string bytes")
end
T.eq(fullReads, 0, "whole bank is never converted to a Lua string")
T.eq(views, releases, "every instrument view releases its temporary handle")
for _, meta in ipairs({{offset=-1,size=1}, {offset=1024,size=1}, {offset=0,size=0}}) do
  T.eq(Sample.loadPcm(bank, meta), nil, "invalid shared sample bounds rejected")
end
T.eq(Sample.loadPcm(bank, nil), nil, "missing metadata rejected")
local reads, dataReads = 0, 0
local index = "return {songs={},samples={},voicegroups={}}"
local cache = {read = function(_, path)
  if path:match('/index%.lua$') then return index end
  if path:match('/samples%.bin$') then reads = reads + 1; return bytes end
end, readData = function() dataReads = dataReads + 1; return bank end}
local main = assert(Player.loadPack(cache, "audio", {shareSamples = true}))
local worker = assert(Player.loadPack(cache, "audio", {samplesData = main.samplesBin}))
T.eq(main.samplesBin, worker.samplesBin, "main and worker packs retain the same bank")
T.eq(dataReads, 1, "bank read once as Data")
T.eq(reads, 0, "neither pack reads a duplicate full-bank string")
local legacy = assert(Player.loadPack(cache, "audio"))
T.eq(type(legacy.samplesBin), "string", "desktop/default pack representation unchanged")
cache.readData = function() error("Data reader unavailable") end
local fallback = assert(Player.loadPack(cache, "audio", {shareSamples = true}))
T.eq(fallback.samplesBin, bytes, "custom/failed Data reader falls back to string cache")
T.eq(dataReads, 1, "fallback cannot bypass the custom cache")
local Mix = require("src.core.game3.m4a_mix")
local m = {offset=24,size=768,freq=13379*1024}
local function render(source)
  local v = Mix.newDsVoice(Sample.loadPcm(source, m), m, {rate=13379,volL=.7,volR=.4})
  return Mix.render({v}, 256, {raw=true,sampleRate=44100,hpfCapL=0,hpfCapR=0})
end
local l1, r1 = render(bytes)
local l2, r2 = render(bank)
T.same(l1, l2, "left mixed output unchanged")
T.same(r1, r2, "right mixed output unchanged")
-- Read Data through the same exact version prefix as Dataset's string cache.
local Fs = require("src.import.CacheFs")
local oldRoot = Fs.root
Fs.root = function() return nil end
local Dataset = require("src.core.game3.dataset")
local paths = {}
love.filesystem.read = function(container, path)
  if container == "data" then paths[#paths+1] = path; return bank, #bytes end
end
_G.POKEPORT_VITA = true
for _, version in ipairs({"emerald", "firered"}) do
  Version.set(version)
  T.eq(Dataset.cache():readData("data/generated/gba/audio/samples.bin"), bank, "Data bank resolves current cartridge")
  T.eq(paths[#paths], version .. "/data/generated/gba/audio/samples.bin", "cartridge namespace preserved")
end
_G.POKEPORT_VITA = false
T.eq(Dataset.cache():readData("data/generated/gba/audio/samples.bin"), nil, "desktop does not opt into shared bank")
_G.POKEPORT_VITA = true
Dataset.cacheRootOverride = "/explicit/cache"
T.eq(Dataset.cache():readData("data/generated/gba/audio/samples.bin"), nil, "explicit cache root uses existing reader")
Dataset.cacheRootOverride = nil
Fs.root = oldRoot
_G.POKEPORT_VITA = nil
T.finish("Vita shared audio sample bank")
