local Shutdown = {}

function Shutdown.closeWindow()
  if _G.POKEPORT_VITA ~= true then return end
  local f = io.open("ux0:/data/g1r-shutdown.txt", "w")
  local function step(label, fn)
    if f then f:write(label .. " begin\n"); f:flush() end
    local ok, err = pcall(fn)
    if f then f:write(label .. (ok and " complete\n" or " error: " .. tostring(err) .. "\n")); f:flush() end
  end
  local g, w = love.graphics, love.window
  step("detach render state", function()
    if g then
      if g.flushBatch then g.flushBatch() end
      if g.setCanvas then g.setCanvas() end
      if g.setShader then g.setShader() end
    end
  end)
  -- Window.close calls Graphics::unSetMode / Volatile::unloadAll while the
  -- Lua-owned fonts/images still exist. Their later finalizers see no handles.
  step("close graphics before Lua finalizers", function()
    if w and w.close then w.close() end
  end)
  if f then f:close() end
end

return Shutdown
