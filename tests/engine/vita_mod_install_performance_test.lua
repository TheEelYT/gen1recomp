package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
love = require("tests.love_stub")
_G.POKEPORT_VITA = true
local LauncherMods = require("src.mods.LauncherMods")
local CacheBlob = require("src.import.CacheBlob")

-- Fast installation must keep the same cache format and ordinary defaults.
local deflate = CacheBlob.deflate
local seen
CacheBlob.deflate = function(raw, level) seen = level; return deflate(raw, level) end
local raw = ("\1\2\3\255"):rep(256 * 256)
local packed = CacheBlob.encode("mods/test/battle.rgba", raw, 1)
T.eq(seen, 1, "installer can select fast compression")
T.eq(CacheBlob.decode("mods/test/battle.rgba", packed), raw, "fast texture decodes byte for byte")
packed = CacheBlob.encode("mods/test/battle.rgba", raw)
T.eq(seen, 6, "ordinary cache writes retain the existing compression level")
T.eq(CacheBlob.decode("mods/test/battle.rgba", packed), raw, "ordinary cache format remains valid")
CacheBlob.encode("assets/atlas_test.rgba", raw)
T.eq(seen, 1, "derived atlas default is unchanged")
T.eq(CacheBlob.encode("mods/test/main.lua", "return {}", 1), "return {}", "non-texture files remain raw")

-- Cheap files can amortize a slow redraw, while costly files yield promptly.
local elapsed = 0
love.timer = { getTime = function() return elapsed end }
local function job(cost)
  return { co = coroutine.create(function()
    for i = 1, 100 do
      elapsed = elapsed + cost
      coroutine.yield({ files = i })
    end
    return true, "1.0.0"
  end) }
end
local cheap = job(0)
local done, _, _, progress = LauncherMods.pumpDownloadedZip(cheap)
T.eq(done, false, "bounded cheap batch yields to the UI")
T.eq(progress.files, 64, "cheap files are not capped at eight per redraw")
local costly = job(0.01)
done, _, _, progress = LauncherMods.pumpDownloadedZip(costly)
T.eq(done, false, "costly batch yields to the UI")
T.eq(progress.files, 4, "work yields after crossing the 32 ms budget")
T.check(costly.pumpSeconds >= 0.032 and costly.pumpSeconds < 0.05, "pump timings include all work slices")
local terminal
costly.report = function(event) terminal = event end
while not done do done = LauncherMods.pumpDownloadedZip(costly) end
T.eq(terminal, "complete", "terminal report runs after final work is timed")

-- Exercise the actual draw entry point: neither cartridge nor video draws
-- should run behind the blocking progress panel during a Vita install.
local View = require("src.import.LauncherView")
local Kit = require("src.ui.kit.Kit")
local Layout = require("src.ui.kit.Layout")
local Loader = require("src.ui.kit.Loader")
local Theme = require("src.ui.kit.Theme")
local begins, ends, fields, overlay = 0, 0, 0
Kit.beginFrame = function(_, _, clicked, wheel)
  begins = begins + 1
  T.eq(clicked, false, "install view never dispatches stale clicks")
  T.eq(wheel, 0, "install view consumes stale scrolling")
end
Kit.endFrame = function() ends = ends + 1 end
Layout.metrics = function() return { W = 960, H = 544 } end
Theme.field = function() fields = fields + 1 end
Loader.overlay = function(_, spec) overlay = spec end
local page = { _modInstall = {}, _busy = { title = "Installing fixture",
  detail = "asset.rgba", count = "5200 / 7849 files", progress = 0.66 },
  _clickPt = { x = 123, y = 456 }, _wheelY = 3,
  _themeVideo = { draw = function() error("hidden video should not draw") end } }
View.draw(page)
T.eq(begins, 1, "lightweight install view starts a UI frame")
T.eq(ends, 1, "lightweight install view finishes a UI frame")
T.eq(fields, 1, "install view clears the background")
T.eq(overlay.title, "Installing fixture", "install view displays the real stage")
T.eq(overlay.progress, 0.66, "install view retains measured percentage")
T.eq(overlay.count, "5200 / 7849 files", "install view retains file count")
T.eq(overlay.detail, "asset.rgba", "install view retains current filename")
T.eq(page._clickPt, nil, "stale pointer input is consumed")
T.eq(page._wheelY, 0, "stale wheel input is consumed")
T.finish("Vita installer performance contracts")
