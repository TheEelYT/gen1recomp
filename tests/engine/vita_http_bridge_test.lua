package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
love = require("tests.love_stub")
love.system.getOS = function() return "Linux" end
love.system._vitaHttp = true
-- Worker states have the native marker but do not inherit conf.lua globals.
_G.POKEPORT_VITA = nil
local HostShell = require("src.core.HostShell")
HostShell.popen = function() error("Vita must not launch a shell") end
T.eq(HostShell.haveCurl(), false, "worker marker disables desktop curl probing")
local seen
love.system.httpGet = function(url, agent, accept, timeout)
  seen = { url, agent, accept, timeout }
  return "index", nil, 200
end
love.system.httpDownload = function(url, path, agent, accept, timeout)
  seen = { url, path, agent, accept, timeout }
  return true
end
love.system.httpRequest = function(url, method, headers, body, agent, timeout)
  seen = { url = url, method = method, headers = headers, body = body, timeout = timeout }
  return "STATUS 409\nconflict"
end
local Platform = require("src.core.Platform")
T.check(Platform.canFetchRemote(), "native bridge enables remote mods")
T.eq(Platform.canSpawnProcess(), false, "Linux OS name does not enable processes on Vita")
T.eq(Platform.networkValidated(), false, "native downloads do not enable self-update")
T.check(HostShell.canHttpRequest(), "Vita supports authenticated requests")
T.eq(HostShell.httpGet("https://example/index", "agent", "application/json", 17), "index",
  "GET returns native body directly without a shared temporary file")
T.eq(seen[4], 17, "GET timeout reaches native transport")
T.check(HostShell.httpDownload("https://example/mod", "ux0:/data/mod.zip", "agent", "*/*", 80),
  "download uses native streaming bridge")
T.eq(seen[5], 80, "download timeout reaches native transport")
local body, err, code = HostShell.httpRequest("https://example/sync", {
  method = "PUT", body = "save\0bytes", maxTime = 19,
  headers = { ["x-sync-account"] = "account", ["x-sync-token"] = "test-token" },
})
T.eq(body, "conflict", "sync conflict body is preserved")
T.eq(err, nil, "HTTP conflict is not a transport failure")
T.eq(code, 409, "sync conflict status is preserved")
T.eq(seen.body, "save\0bytes", "request body is binary safe")
T.eq(seen.timeout, 19, "request timeout reaches native transport")
local headers = {}
for i = 1, #seen.headers, 2 do headers[seen.headers[i]] = seen.headers[i + 1] end
T.eq(headers["x-sync-token"], "test-token", "custom authentication header reaches bridge")
love.system.httpGet = function() return nil, "certificate check failed", 0 end
body, err = HostShell.httpGet("https://example/index")
T.eq(body, nil, "TLS failure has no success body")
T.check(err and err:find("certificate check failed", 1, true), "native TLS error remains visible")
love.system.httpRequest = function() return "STATUS 204\n" end
T.check(HostShell.httpPost("https://example/post", "payload"), "POST accepts empty 204 response")

-- Cancellation must happen before joining any worker, and reset before restart.
local events, channels = {}, {}
local function event(name) events[#events + 1] = name end
love.system.httpCancelAll = function() event("cancel") end
love.system.httpResetCancel = function() event("reset") end
love.thread = {
  getChannel = function(name)
    if not channels[name] then
      local ch = {}
      function ch:clear() self.values = {} end
      function ch:push(value) self.values[#self.values + 1] = value end
      function ch:pop() return table.remove(self.values, 1) end
      function ch:peek() return self.values[1] end
      ch:clear(); channels[name] = ch
    end
    return channels[name]
  end,
  newThread = function()
    return { start = function() event("start") end, wait = function() event("wait") end,
      getError = function() return nil end }
  end,
}
local Fetch = require("src.net.Fetch")
Fetch.get("https://example/index")
T.eq(events[1], "reset", "a new worker pool resets native shutdown cancellation first")
Fetch.shutdown()
T.eq(events[5], "cancel", "native transfer is cancelled before worker joins")
T.eq(events[6], "wait", "workers are joined after cancellation")
events = {}
Fetch.get("https://example/index")
T.eq(events[1], "reset", "a reopened pool can make transfers again")
Fetch.shutdown()

love.system._vitaHttp = nil
love.system.httpDownload = nil
_G.POKEPORT_VITA = true
Platform._resetForTests()
T.eq(Platform.canFetchRemote(), false, "older Vita runtime without HTTP stays unavailable")
T.eq(HostShell.haveCurl(), false, "older Vita main state still avoids a shell")
T.finish("Vita HTTP bridge")
