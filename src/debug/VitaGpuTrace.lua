-- Opt-in hardware diagnostics. Put "trace" or "sync" in
-- ux0:/data/vita-gpu-debug.txt before launching the game.
local Trace = {}
Trace.__index = Trace
local ROOT = "ux0:/data/"

function Trace.new()
  if _G.POKEPORT_VITA ~= true then return nil end
  local ok, mode = pcall(function()
    local f = io.open(ROOT .. "vita-gpu-debug.txt", "r")
    if not f then return nil end
    local text = f:read(32)
    f:close()
    return text and text:match("^%s*(%a+)")
  end)
  if not ok or (mode ~= "trace" and mode ~= "sync") then return nil end
  return setmetatable({ mode = mode, frame = 0, disabled = false }, Trace)
end

function Trace:note(text)
  if self.disabled or not self.file then return end
  local ok = pcall(function()
    assert(self.file:write(("%d %s\n"):format(self.frame, text)))
    assert(self.file:flush()) -- Preserve the last checkpoint across a GPU reset.
  end)
  if not ok then
    pcall(function() self.file:close() end)
    self.file, self.disabled = nil, true
  end
end

function Trace:beginFrame(context)
  if self.disabled then return end
  if self.file then self:endFrame() end
  self.frame = self.frame + 1
  -- Alternate chunks so long intro runs retain bounded logs and the chunk
  -- preceding a crash remains available. Only these diagnostic files rotate.
  local slot = math.floor((self.frame - 1) / 120) % 2
  local path = ROOT .. "g1r-render-" .. slot .. ".txt"
  local ok, file = pcall(io.open, path, (self.frame - 1) % 120 == 0 and "w" or "a")
  if not ok or not file then self.disabled = true; return end
  self.file = file
  self.path = path
  self:note("begin mode=" .. self.mode .. " " .. tostring(context or "gba_ppu"))
  local statsOk, stats = pcall(function() return love.graphics.getStats() end)
  if statsOk and stats then
    self:note(("memory luaKiB=%.1f textures=%s textureBytes=%s canvases=%s")
      :format(collectgarbage("count"), tostring(stats.images),
        tostring(stats.texturememory), tostring(stats.canvases)))
  end
end

function Trace:asset(label, path, w, h)
  if self.disabled or not self.path then return end
  -- Asset loading happens in update, between render frames. Keep that event
  -- in the same chunk even though the frame's file handle is already closed.
  local opened = not self.file
  if opened then
    local ok, file = pcall(io.open, self.path, "a")
    if not ok or not file then self.disabled = true; return end
    self.file = file
  end
  local ok, info = pcall(function() return love.filesystem.getInfo(path) end)
  self:note(("asset %s file=%s size=%sx%s fileBytes=%s"):format(label,
    tostring(path), tostring(w), tostring(h), tostring(ok and info and info.size)))
  if opened and self.file then
    pcall(function() self.file:close() end)
    self.file = nil
  end
end

function Trace:checkpoint(label, target)
  if self.disabled then return end
  self:note(label .. " submit")
  if self.disabled then return end
  -- LOVE batches draws: write the breadcrumb before flushing so a fault in
  -- command submission is distinguishable from a wait for GPU completion.
  love.graphics.flushBatch()
  self:note(label .. " submitted")
  if self.mode == "sync" and target then
    self:note(label .. " readback begin pixel=1x1")
    -- Readback is the public LOVE API that waits for this render target.
    -- This intentionally changes scheduling; it is diagnostic, not a fix.
    love.graphics.push("all")
    love.graphics.setCanvas() -- LOVE forbids reading the active Canvas.
    -- A one-pixel read still waits for the render target, without allocating
    -- a full 240x160 image at every checkpoint (150 KiB per RGBA8 image).
    -- LOVE 11: slice, mipmap, x, y, width, height. Slice is ignored for 2D.
    local ok, data = pcall(target.newImageData, target, 1, 1, 0, 0, 1, 1)
    love.graphics.pop()
    if ok then
      data:release()
      self:note(label .. " readback complete")
    else
      self:note(label .. " readback unavailable: " .. tostring(data))
      self.mode = "trace"
    end
  end
end

function Trace:endFrame()
  self:note("offscreen end")
  if self.file then
    pcall(function() self.file:close() end)
    self.file = nil
  end
end

return Trace
