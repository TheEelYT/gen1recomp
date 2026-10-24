local Shutdown = {}

function Shutdown.prepare()
  if _G.POKEPORT_VITA ~= true then return end
  local f = io.open("ux0:/data/g1r-shutdown.txt", "w")
  local function step(label, fn)
    if f then f:write(label .. " begin\n"); f:flush() end
    local ok, err = pcall(fn)
    if f then f:write(label .. (ok and " complete\n" or " error: " .. tostring(err) .. "\n")); f:flush() end
  end
  local g = love.graphics
  step("detach render state", function()
    if g then
      if g.flushBatch then g.flushBatch() end
      if g.setCanvas then g.setCanvas() end
      if g.setShader then g.setShader() end
    end
  end)
  -- The device also faults freeing a font atlas inside Window.close itself.
  -- After the application shutdown hooks have finished, ask the native main
  -- to end the process without running the broken graphics finalizers. This
  -- flag is ignored on restart, and is never set when returning to launcher.
  _G.G1R_VITA_SHUTDOWN_READY = true
  if f then f:write("application shutdown complete; native process exit ready\n"); f:flush() end
  if f then f:close() end
end

return Shutdown
