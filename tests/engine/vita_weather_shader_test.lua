package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
local shaders, sent = {}, {}
local function noop() end
love = { graphics = {}, image = { newImageData = function()
  return { setPixel = noop }
end } }
local g = love.graphics
for _, key in ipairs({ "push", "pop", "setColor", "setShader" }) do g[key] = noop end
g.getCanvas = function() return nil end
g.newImage = function() return { setFilter = noop } end
g.newShader = function(source)
  assert(not source:match("%f[%w_]row%f[^%w_]"), "ShaccCg rejects keyword row")
  local uniforms = {}
  for name in source:gmatch("extern%s+[%w_]+%s+([%w_]+)%s*;") do uniforms[name] = true end
  local sh = { source = source }
  function sh:send(name, value)
    assert(uniforms[name], "undeclared uniform " .. name)
    sent[#sent + 1] = { name, value }
  end
  shaders[#shaders + 1] = sh
  return sh
end
local Weather = require("src.core.game3.field_weather_rse")
Weather._manifest = { family = "rse", blobs = {} }
Weather.state.started, Weather.state.initialized = true, true
Weather.state.colorMapIndex = 3
Weather.draw(0, 0, 240, 160)
T.eq(#shaders, 3, "weather and mask shaders all compile through real load path")
local found
for _, row in ipairs(sent) do if row[1] == "weatherRow" then found = row[2] end end
T.eq(found, 21, "contrast lookup uploads renamed row (19 + index - 1)")
Weather.state.colorMapIndex = -2
Weather.draw(0, 0, 240, 160)
local drought
for _, row in ipairs(sent) do if row[1] == "dtable" then drought = row[2] end end
T.eq(drought, 1, "drought shader path retains table selection")
T.eq(#shaders, 3, "subsequent weather draws reuse compiled shaders")
T.finish("Vita weather shader uniforms")
