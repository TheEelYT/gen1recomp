-- Bound temporary allocation growth between expensive full-heap scans.
-- Keep the first scan: imported game data leaves tens of MiB of loader garbage.
local Memory = { LUA_GROWTH_KB = 4 * 1024, IMAGE_BUDGET_BYTES = 4 * 1024 * 1024 }
local baseKB, imageBytes

function Memory.reset()
  baseKB, imageBytes = nil, 0
end
Memory.reset()

local function full(path, reason)
  local timer = love and love.timer
  local started = timer and timer.getTime and timer.getTime()
  collectgarbage("collect")
  baseKB, imageBytes = collectgarbage("count"), 0
  if started then
    require("src.debug.VitaLoadTrace").slow("gc", path, "before-image",
      timer.getTime() - started, "full/" .. reason)
  end
end

function Memory.load(path, loader)
  if _G.POKEPORT_VITA ~= true then return loader(path) end
  local kb = collectgarbage("count")
  if baseKB and kb < baseKB then baseKB = kb end
  if not baseKB then full(path, "startup")
  elseif kb - baseKB >= Memory.LUA_GROWTH_KB then full(path, "lua-growth")
  elseif imageBytes >= Memory.IMAGE_BUDGET_BYTES then full(path, "image-budget") end

  local ok, img = pcall(loader, path)
  if not ok then
    local err = tostring(img):lower()
    if not (err:find("out of memory", 1, true) or err:find("not enough memory", 1, true)
        or err:find("cannot allocate", 1, true)) then error(img, 0) end
    full(path, "allocation-retry")
    -- One retry only. Preserve the original loader and its ownership behavior.
    img = loader(path)
  end
  -- Conservatively count RGBA CPU + GPU image traffic. This is an activity
  -- budget for native temporaries, not a measurement of free memory or garbage.
  imageBytes = imageBytes + img:getWidth() * img:getHeight() * 8
  return img
end

return Memory
