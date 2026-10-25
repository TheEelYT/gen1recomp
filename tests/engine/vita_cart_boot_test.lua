package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
love = require("tests.love_stub")
local Store = require("src.carts.CartStore")
local file = assert(io.open("main.lua", "rb"))
local main = file:read("*a"); file:close()
local block = assert(main:match("(  local cartDefinition, cartHash, cartSpeeds, cartOptions.-)  local CacheFs = require"))
local prepare = Store.prepareBoot
local result, cleared, launchers
Store.prepareBoot = function() return result, result and "hash" or "out of memory" end
local fn = assert(loadstring("local cartId, GameVersion = ...\n" .. block
  .. "return cartDefinition, cartHash", "@cart-boot-preflight"))
local env = setmetatable({ require = function(name)
  if name == "src.carts.CartStore" then return Store end
  if name == "src.core.SaveData" then return { setCart = function() cleared = true end } end
  if name == "src.debug.VitaCartTrace" then return { begin = function() end, record = function() end, stop = function() end } end
  error(name)
end, makeLauncher = function() launchers = launchers + 1; return {} end }, { __index = _G })
setfenv(fn, env)
launchers = 0
local definition = fn("test_cart", { get = function() return "emerald" end })
T.eq(definition, nil, "failed preflight returns without entering game")
T.eq(cleared, true, "failed preflight clears pending save scope")
T.eq(launchers, 1, "failed preflight returns to launcher")
T.eq(env.Importer._cartPopup, "emerald", "cart error is visible in the picker")
T.check(env.Importer._cartNotice:find("out of memory", 1, true), "actual cart read error reaches player")
result = { id = "test_cart", mods = {} }
definition = fn("test_cart", { get = function() return "emerald" end })
T.eq(definition, result, "successful preflight carries validated definition")
T.eq(launchers, 1, "successful preflight does not reopen launcher")
T.check(main:find(block, 1, true) < main:find("CacheFs.mountVersion(GameVersion.get())", 1, true),
  "cart is prepared before the version cache changes the search path")
Store.prepareBoot = prepare

local Game3 = require("src.core.Game3")
local seen
package.loaded["src.mods.Loader"] = { new = function(opts) seen = opts.cart; error("test mod init failure") end }
local ok, err = Game3._loadMods({ data = {} }, { cartId = "test_cart", cart = result })
T.eq(seen, result, "Game3 loader receives the preflight definition")
T.eq(ok, false, "requested cart does not silently continue after loader exception")
T.check(err:find("test mod init failure", 1, true), "cart load failure keeps its cause")
package.loaded["src.mods.Loader"] = { new = function()
  return { load = function() end, status = function() return {} end,
    cartReport = { enforced = true, refused = true, message = "pinned mod missing" }, errors = {} }
end }
ok, err = Game3._loadMods({ data = {} }, { cartId = "test_cart", cart = result })
T.eq(ok, false, "refused sealed-cart plan stops boot")
T.eq(err, "pinned mod missing", "refused plan explains why")
_G.POKEPORT_VITA = true
local trace = require("src.debug.VitaCartTrace")
trace.begin("test_cart")
package.loaded["src.mods.Loader"] = { new = function()
  return { load = function() require("src.core.Logger").error("Mod layout test is invalid") end,
    status = function() return {} end, cartReport = { enforced = true }, errors = {} }
end }
ok, err = Game3._loadMods({ data = {} }, { cartId = "test_cart", cart = result })
T.eq(ok, false, "fatal log-and-return initialization does not quietly start vanilla")
T.eq(err, "Mod layout test is invalid", "initialization log reaches the cart error")
trace.stop()
T.finish("Vita cart boot safeguards")
