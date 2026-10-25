package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
love = require("tests.love_stub")
_G.POKEPORT_VITA = true
local fs = love.filesystem
local LauncherMods = require("src.mods.LauncherMods")
local CacheFs = require("src.import.CacheFs")
local CacheBlob = require("src.import.CacheBlob")
local ModUpdate = require("src.mods.ModUpdate")
local RomImporter = require("src.import.RomImporter")
local archive = "vita_mod_fixture.zip"
local id = "vita_install_fixture"
local source = archive .. "/" .. id
local target = "mods/" .. id
local manifest = '{"id":"' .. id .. '","name":"Vita fixture","version":"1.0.0","entry":"main.lua"}'
local realRead, realMount = fs.read, fs.mount
local realGetInfo, realWrite = fs.getInfo, CacheFs.write
local broken, failMode, failures, wholeReads, memoryMounts
local rgba = ("\1\2\3\255"):rep(256 * 256)
local ticks = 0
love.timer = { getTime = function() ticks = ticks + 0.01; return ticks end }
fs.newFileData = function() memoryMounts = memoryMounts + 1; error("must mount disk") end
fs.mount = function(path, point, append)
  T.eq(type(path), "string", "archive is mounted from disk")
  return realMount(path, point, append)
end
fs.read = function(path)
  if path == archive then wholeReads = wholeReads + 1; error("whole archive reread") end
  if broken and path:sub(-#broken) == broken and path:find("mod_import_mount", 1, true) then
    failures = failures + 1
    if failMode == "transient" and failures > 1 then return realRead(path) end
    return nil, "PhysFS test: storage read failed"
  end
  return realRead(path)
end
fs.getInfo = function(path, kind)
  local info = realGetInfo(path, kind)
  if info and info.type == "file" and path:find("mod_import_mount", 1, true) then
    local data = realRead(path)
    info.size = data and #data or nil
    if failMode == "short" and path:find("asset_003", 1, true) then info.size = info.size + 1 end
  end
  return info
end
CacheFs.write = function(path, data)
  if failMode == "throw" and path:find("asset_003", 1, true) then error("injected compression error") end
  return realWrite(path, data)
end

local function fixture(mode)
  CacheFs.prefix = ""
  local function clear(path)
    local info = fs.getInfo(path)
    if info and info.type == "directory" then
      for _, child in ipairs(fs.getDirectoryItems(path)) do clear(path .. "/" .. child) end
    end
    fs.remove(path)
  end
  clear(target)
  clear("imports/baseroms-recovery/" .. id)
  fs.write(archive, "PK fixture")
  fs.write(source .. "/manifest.json", manifest)
  fs.write(source .. "/main.lua", "return {}")
  for i = 1, 72 do fs.write(source .. ("/assets/asset_%03d.rgba"):format(i), rgba) end
  failMode, failures, wholeReads, memoryMounts = mode, 0, 0, 0
  broken = (mode == "persistent" or mode == "transient") and "asset_003.rgba" or nil
  CacheFs.prefix = "emerald/"
end

local function run()
  local job = LauncherMods.beginDownloadedZip(id, archive, "1.0.0")
  local initialManifest = realRead(target .. "/manifest.json")
  local frames, previous = 0, 0
  while frames < 100 do
    frames = frames + 1
    local done, ok, result, progress = LauncherMods.pumpDownloadedZip(job)
    T.eq(CacheFs.prefix, "emerald/", "cache prefix is restored before each frame")
    if done then
      T.eq(#fs._mounts, 0, "completed or failed installer unmounts its ZIP")
      T.eq(wholeReads, 0, "installation never reads the full archive into Lua")
      T.eq(memoryMounts, 0, "installation never allocates an archive FileData")
      return ok, result, frames
    end
    if progress.phase == "scan" then
      T.check(progress.scanned > 0, "preparation reports scanned files before total is known")
      T.eq(realRead(target .. "/manifest.json"), initialManifest, "preparation leaves old install unchanged")
    else
      T.check(progress.files > previous, "file counter advances across frames")
      T.eq(progress.total, 73, "extraction has a real file total")
      previous = progress.files
      T.eq(realRead(target .. "/manifest.json"), nil, "partial mod is not published")
    end
  end
  error("installer did not finish")
end

fixture()
local ok, version, frames = run()
T.check(ok, "large fixture installs successfully: " .. tostring(version))
T.eq(version, "1.0.0", "installed version reaches caller")
T.check(frames > 1, "large copy is spread over launcher frames")
T.eq(realRead(target .. "/manifest.json"), manifest, "manifest is published at completion")
T.eq(realRead(archive), nil, "successful archive is consumed")
local packed = realRead(target .. "/assets/asset_003.rgba")
T.eq(CacheBlob.decode(target .. "/assets/asset_003.rgba", packed), rgba,
  "copied textures retain the engine's compressed cache format")

for _, mode in ipairs({ "persistent", "short", "throw" }) do
  fixture(mode)
  ok, version = run()
  T.eq(ok, nil, mode .. " failure is not reported as success")
  T.check(type(version) == "string" and version:find("asset_003", 1, true)
    or mode == "throw" and version:find("compression error", 1, true),
    "failure identifies the asset or operation: " .. tostring(version))
  if mode == "persistent" then
    T.eq(failures, 2, "failed read retries once after collection")
    T.check(version:find("PhysFS test: storage read failed", 1, true), "real read error survives")
  end
  T.eq(realRead(target .. "/manifest.json"), nil, "failed copy is not discoverable as installed")
  T.eq(realRead(target .. "/assets/asset_001.rgba"), nil, "failed copy rolls back its files")
  T.eq(realRead(archive), "PK fixture", "failed archive is retained for inspection")
end
fixture("transient")
ok, version = run()
T.check(ok, "one transient read failure can recover")
T.eq(failures, 2, "recovered read has exactly one retry")
fixture("throw")
fs.write(target .. "/manifest.json", manifest)
fs.write(target .. "/baseroms/base.gba", "user input")
ok, version = run()
T.eq(ok, nil, "failed update is surfaced")
T.eq(realRead(target .. "/baseroms/base.gba"), "user input", "user baserom survives failed update")
fixture()
fs.write(target .. "/manifest.json", manifest)
fs.write(target .. "/baseroms/base.gba", "user input")
local interrupted = LauncherMods.beginDownloadedZip(id, archive, "1.0.0")
for _ = 1, 10 do
  local done, _, _, progress = LauncherMods.pumpDownloadedZip(interrupted)
  if progress and progress.phase == "copy" then break end
  T.eq(done, false, "interruption fixture reaches copying")
end
T.eq(realRead("imports/baseroms-recovery/" .. id .. "/base.gba"), "user input",
  "user inputs are persisted before a cooperative update deletes their old tree")
T.eq(realRead(target .. "/manifest.json"), nil, "interrupted copy has no ready manifest")
fs.unmount(archive) -- Model process restart releasing the abandoned mount.
interrupted = nil
ok, version = run()
T.check(ok, "next install can recover after interruption")
T.eq(realRead(target .. "/baseroms/base.gba"), "user input", "interrupted update recovers user inputs")
T.eq(realRead("imports/baseroms-recovery/" .. id .. "/base.gba"), nil, "successful recovery removes staging")

-- Exercise the launcher stages and cart hash gate, not just the copy helper.
local hashOk, hashes = true, 0
RomImporter.verifyArchiveSha256 = function()
  hashes = hashes + 1
  return hashOk, "test hash mismatch"
end
local downloading = false
ModUpdate.pumpDownloadZip = function()
  if downloading then return false, nil, nil, 0 end
  return true, archive
end
LauncherMods.checkDependencies = function() return { hasIssues = false } end
local function page()
  return setmetatable({ _modInstall = { h = {}, version = "1.0.0",
    spec = { modId = id, name = id, sha256 = ("a"):rep(64) } },
    _refreshMods = function() end, _rejudgeModUpdate = function() end }, RomImporter)
end
fixture()
local ri = page()
downloading = true
ri:_setBusy("Downloading fixture")
ri:_pumpModInstall()
T.eq(ri._busy.progress, nil, "native download uses a spinner instead of a stalled zero percent")
downloading = false
ri:_pumpModInstall()
T.check(ri._busy.title:find("Verifying", 1, true), "verification stage can paint before hashing")
T.eq(hashes, 0, "first download completion does not hash and copy in one frame")
ri:_pumpModInstall()
T.eq(hashes, 1, "cart archive is verified before unzip")
T.check(ri._modInstall.unpack ~= nil, "verified archive enters cooperative install")
ri:_pumpModInstall()
T.eq(ri._busy.progress, nil, "preparation is indeterminate while counting files")
T.check(ri._busy.count:find("Preparing", 1, true), "preparation counter is visible")
ri:_pumpModInstall(); ri:_pumpModInstall()
T.check(ri._busy.progress > 0 and ri._busy.progress < 1, "extraction percentage advances before completion")
T.check(ri._busy.count:find("73 files", 1, true), "extraction counter carries its known total")
for _ = 1, 100 do if ri._modInstall then ri:_pumpModInstall() end end
T.check(ri.modNotice and ri.modNotice.ok, "launcher reports successful cooperative installation")
T.eq(ri._modInstall, nil, "launcher releases completed job")
T.eq(ri._busy, nil, "launcher clears completed overlay")
fixture()
hashOk = false
fs.write(target .. "/manifest.json", manifest)
fs.write(target .. "/main.lua", "old installed content")
ri = page()
ri:_pumpModInstall(); ri:_pumpModInstall()
T.eq(ri._modInstall, nil, "hash mismatch clears job without extraction")
T.check(ri.modNotice and not ri.modNotice.ok, "hash mismatch remains an error")
T.eq(realRead(target .. "/manifest.json"), manifest, "bad hash leaves the existing manifest intact")
T.eq(realRead(target .. "/main.lua"), "old installed content", "bad hash leaves old content intact")
T.eq(#fs._mounts, 0, "bad hash never mounts the archive")
T.finish("Vita cooperative mod install")
