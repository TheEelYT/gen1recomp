-- ROM-free regression: Emerald extraction must not use the default FRLG family.
package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
local GameVersion = require("src.core.GameVersion")
local Versions = require("src.import.gba.versions")
local Family = require("src.import.gba.family")
local Catalog = require("src.import.gba.map_catalog")
local Profile = require("src.core.game3.profile")
local Extractor = require("src.import.RomExtractorGen3")
local CacheFs = require("src.import.CacheFs")
local worker = assert(loadfile("src/import/ExtractThread.lua"))
local games = { "emerald", "ruby", "sapphire", "firered", "leafgreen" }
local expected, observed
local channels = {}
love = {
  filesystem = { getInfo = function() return nil end },
  timer = { getTime = os.clock },
  thread = { getChannel = function(name)
    channels[name] = channels[name] or { messages = {}, push = function(self, msg)
      self.messages[#self.messages + 1] = msg
    end }
    return channels[name]
  end },
}
package.loaded["src.import.RomManifest"] = { decode = function(version)
  T.eq(GameVersion.get(), version, "worker selects the game before decoding its manifest")
  return { romSha1 = GameVersion.info(version).sha1 }
end }
local function checkContext(label)
  T.eq(GameVersion.get(), expected, label .. " active game")
  T.eq(Versions.active(), expected, label .. " ROM tables")
  T.eq(Family.active().game, expected, label .. " layout edition")
  Catalog.rebuildIndex() -- Used by maps_tree; raised FRLG_MAP_TO_FR on Emerald.
  local id = Catalog.mapIdFor(0, 0)
  local prefix = Profile.of(expected).map.enginePrefix
  T.check(type(id) == "string" and id:sub(1, #prefix) == prefix,
    label .. " catalog uses the selected game's map identifiers")
  if expected == "emerald" then
    T.eq(id, "EM_PETALBURG_CITY", label .. " Emerald group 0 map 0")
  end
end
Extractor.run = function(self)
  observed = true
  checkContext("thread")
  T.eq(CacheFs.prefix, expected .. "/", "worker retains its cache prefix")
end
for _, game in ipairs(games) do
  expected = game
  -- Constructor is also used by the coroutine fallback and standalone tools.
  GameVersion.set(game == "firered" and "emerald" or "red")
  Versions.select("firered")
  Extractor.new("fixture ROM", nil, nil, GameVersion.info(game).sha1)
  local ok, err = pcall(checkContext, "constructor")
  T.check(ok, "constructor catalog builds: " .. tostring(err))
  for _, vita in ipairs({ false, true }) do
    GameVersion.set("red")
    Versions.select("firered")
    channels, observed = {}, false
    worker(game, game .. "/", "fixture ROM", "progress", "result",
      GameVersion.info(game).sha1, vita)
    local res = channels.result.messages[1]
    T.check(res and res.ok, game .. " worker completes: " .. tostring(res and res.error))
    T.check(observed, game .. " extractor runs")
    T.eq(_G.POKEPORT_VITA, vita, "Vita flag transferred independently of game selection")
  end
end
T.finish("import game context")
