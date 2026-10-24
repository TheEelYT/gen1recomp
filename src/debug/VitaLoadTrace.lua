-- Record only slow CPU load slices. No graphics calls or per-frame file IO.
local Trace = { THRESHOLD = .05, MAX_ENTRIES = 512 }
local count, disabled = 0, false

function Trace.slow(kind, key, phase, seconds, route)
  if _G.POKEPORT_VITA ~= true or disabled or type(seconds) ~= "number"
      or seconds < Trace.THRESHOLD or count >= Trace.MAX_ENTRIES then return end
  local ok = pcall(function()
    local f = assert(io.open("ux0:/data/g1r-loads.txt", count == 0 and "w" or "a"))
    local timer = love and love.timer
    local at = timer and timer.getTime and timer.getTime() or os.clock()
    local wrote = f:write(("at=%.3f %s=%s phase=%s ms=%.1f route=%s luaKiB=%.1f\n")
      :format(at, tostring(kind), tostring(key):gsub("[\r\n]", " "):sub(1, 192), tostring(phase),
        seconds * 1000, tostring(route or "main"), collectgarbage("count")))
    local closed = f:close()
    assert(wrote and closed)
  end)
  if ok then count = count + 1 else disabled = true end
end

return Trace
