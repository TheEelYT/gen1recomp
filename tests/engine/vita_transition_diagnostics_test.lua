package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
local now, records, order = 0, {}, {}
local Trace = require("src.debug.VitaLoadTrace")
Trace.slow = function(kind, key, phase, seconds) records[#records + 1] = {key, phase, seconds} end
local function read(path) now = now + 2; return path, nil, "third" end
local function image() now = now + 3; return "image" end
love = {timer = {getTime = function() return now end},
  filesystem = {read = read}, image = {newImageData = image},
  graphics = {newImage = image, newShader = function() error("compiler error") end}}
_G.POKEPORT_VITA = false
Trace.install()
T.eq(love.filesystem.read, read, "desktop functions untouched")
_G.POKEPORT_VITA = true
Trace.install()
local wrapped = love.filesystem.read
Trace.install()
T.eq(love.filesystem.read, wrapped, "installation is idempotent")
local function results(...) return select("#", ...), ... end
local n, a, b, c = results(love.filesystem.read("scene.png"))
T.eq(n, 3, "all return values forwarded including embedded nil")
T.eq(a, "scene.png", "path result preserved")
T.eq(b, nil, "nil preserved")
T.eq(c, "third", "last result preserved")
T.eq(records[1][1], "scene.png", "file path labeled")
T.eq(records[1][3], 2, "file IO duration measured")
T.eq(select("#", love.graphics.newImage("scene.png")), 1, "single image result stays single")
T.eq(records[2][2], "graphics.newImage", "upload/decode path labeled")
T.eq(pcall(love.graphics.newShader), false, "shader errors still propagate")
local realOpen = io.open
io.open = function() return {write = function() end, flush = function() end, close = function() end} end
local function call(name) return function() order[#order + 1] = name end end
love.graphics.flushBatch, love.graphics.setCanvas, love.graphics.setShader = call("flush"), call("canvas"), call("shader")
love.window = {close = call("close")}
require("src.debug.VitaShutdown").prepare()
T.same(order, {"flush", "canvas", "shader"}, "detach without invoking crashing window teardown")
T.eq(_G.G1R_VITA_SHUTDOWN_READY, true, "actual Vita exit arms native process shutdown")
_G.G1R_VITA_SHUTDOWN_READY = nil
_G.POKEPORT_VITA = false
require("src.debug.VitaShutdown").prepare()
T.eq(#order, 3, "desktop shutdown untouched")
T.eq(_G.G1R_VITA_SHUTDOWN_READY, nil, "desktop never requests native exit")
io.open = realOpen
_G.POKEPORT_VITA = nil
T.finish("Vita transition diagnostics and shutdown ordering")
