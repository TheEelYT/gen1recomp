local Trace = { active = false, errorCount = 0 }
local lines, layouts, cells = 0, 0, 0

function Trace.record(stage, detail)
  if not Trace.active or lines >= 128 then return end
  pcall(function()
    local file = io.open("ux0:/data/g1r-cart-boot.txt", lines == 0 and "w" or "a")
    if not file then return end
    local timer = love and love.timer
    local at = timer and timer.getTime and timer.getTime() or os.clock()
    file:write(("at=%.3f stage=%s lua_kib=%.1f layouts=%d cells=%d %s\n"):format(
      at, stage, collectgarbage("count"), layouts, cells,
      tostring(detail or ""):gsub("[\r\n]", " "):sub(1, 384)))
    file:close()
    lines = lines + 1
  end)
end

function Trace.begin(id)
  Trace.active = _G.POKEPORT_VITA == true
  lines, layouts, cells = 0, 0, 0
  Trace.errorCount, Trace.lastError = 0, nil
  Trace.record("cart.begin", id)
end

function Trace.error(message)
  if not Trace.active then return end
  Trace.errorCount = Trace.errorCount + 1
  Trace.lastError = tostring(message):sub(1, 384)
  Trace.record("error", Trace.lastError)
end

function Trace.layout(n, compact)
  if not Trace.active then return end
  layouts, cells = layouts + 1, cells + n
  if layouts == 1 or layouts % 32 == 0 then
    Trace.record("layout.decode", compact and "compact" or "tables")
  end
end

function Trace.stop() Trace.active = false end
return Trace
