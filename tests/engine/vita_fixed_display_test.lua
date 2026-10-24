package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
local calls = { mode = 0, fullscreen = 0, writes = 0 }
love = { system = { getOS = function() return "Linux" end },
  graphics = { getDimensions = function() return 960, 544 end,
    getPixelDimensions = function() return 960, 544 end },
  window = {
    getMode = function() return 960, 544, {} end,
    setMode = function() calls.mode = calls.mode + 1; return true end,
    setFullscreen = function() calls.fullscreen = calls.fullscreen + 1 end,
  }, filesystem = {} }
package.loaded["src.core.SaveData"] = { portableFs = function() return {
  read = function() return "windowed\n800\n600\n" end,
  write = function() calls.writes = calls.writes + 1; return true end,
} end }
local Video = require("src.core.VideoMode")
local Faithful = require("src.core.FaithfulRes")
local Window = require("src.import.LauncherWindow")
_G.POKEPORT_VITA = true
T.eq(Video.fixedDisplay(), true, "Vita is fixed even though getOS reports Linux")
T.eq(Faithful.fixedDisplay(), true, "faithful ratio uses fixed-panel behavior")
T.eq(Window.supported(), false, "desktop launcher window restoration is disabled")
Window.activate() -- initial launcher
Video.apply("windowed")
Video.apply("borderless")
Faithful.setNativeSize(240, 160)
Faithful.apply(1)
T.eq(Faithful.scaleCap(), 3, "240x160 game fits panel at 3x")
Faithful.apply(0)
Window.activate() -- EXIT returns through makeLauncher -> activate
Window.toggle()
T.eq(calls.mode, 0, "initial launch, game options and return never resize Vita")
T.eq(calls.fullscreen, 0, "options never toggle Vita fullscreen")
T.eq(calls.writes, 0, "Vita does not persist desktop window preferences")
_G.POKEPORT_VITA = false
T.eq(Video.fixedDisplay(), false, "desktop Linux remains resizable")
Window.activate()
Video.apply("borderless")
T.eq(calls.mode, 1, "desktop launcher still restores its window")
T.eq(calls.fullscreen, 1, "desktop fullscreen still works")
_G.POKEPORT_VITA = nil
T.finish("Vita fixed display lifecycle")
