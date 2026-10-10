-- hako: a plugin manager for ranma, shaped like lazy.nvim without the lazy-loading.
--
--   require("hako").setup({ "owner/repo", { import = "plugins" } }, { lockfile = ... })
--
-- setup() runs while ranma loads: it reads the specs and loads every
-- installed, enabled plugin there and then through ranma.packadd, in
-- dependency order, applying its opts, config and keys. Cloning, fetching and
-- the rest run in the background afterwards (hako.ops) and reload ranma when
-- what loads has changed. README.md is the reference.
local util = require("hako.util")
local spec = require("hako.spec")
local lock = require("hako.lock")
local state = require("hako.state")

local M = {}

local function declare_options()
  ranma.option("hako.install_missing", {
    type = "bool", default = false,
    name = "Install missing", desc = "Clone what the specs declare and is not installed, as ranma loads. Off: hako says what is missing, and installs what you pick.",
  })
  ranma.option("hako.check", {
    type = "bool", default = true,
    name = "Check for updates", desc = "Fetch every plugin now and then, and count the commits each is behind.",
  })
  ranma.option("hako.check_hours", {
    type = "int", default = 6, min = 1, max = 168, slider = false,
    name = "Check every", desc = "Hours between update checks.",
  })
  ranma.option("hako.notify", {
    type = "bool", default = true,
    name = "Toast updates", desc = "A toast when a check finds updates.",
  })
  ranma.option("hako.concurrency", {
    type = "int", default = 4, min = 1, max = 16,
    name = "At once", desc = "How many plugins are cloned or fetched at the same time.",
  })
end

-- The directory hako itself was loaded from, so clean never deletes it.
local function self_dir()
  local path = package.searchpath("hako", package.path)
  return path and path:match("^(.*)/lua/hako/init%.lua$")
end

-- A spec's enabled or cond: a boolean, or a function of the plugin.
local function truth(p, v, field)
  if type(v) == "function" then
    local ok, res = pcall(v, p)
    if not ok then
      p.errors[#p.errors + 1] = field .. ": " .. tostring(res)
      return false
    end
    return res ~= false and res ~= nil
  end
  return v ~= false
end

local function load(p)
  if p.init then
    local ok, err = pcall(p.init, p)
    if not ok then p.errors[#p.errors + 1] = "init: " .. tostring(err) end
  end
  local t0 = os.clock()
  local ok, err = ranma.packadd(p.path)
  p.ms = (os.clock() - t0) * 1000
  p.loaded = ok
  if not ok then
    p.errors[#p.errors + 1] = err
    return
  end
  local opts = p.opts
  if type(opts) == "function" then
    local good, res = pcall(opts, p)
    if good then opts = res else p.errors[#p.errors + 1] = "opts: " .. tostring(res); opts = nil end
  end
  if p.config then
    local good, res = pcall(p.config, p, opts or {})
    if not good then p.errors[#p.errors + 1] = "config: " .. tostring(res) end
  elseif type(opts) == "table" and next(opts) ~= nil then
    local good, res = pcall(ranma.set, { [p.main] = opts })
    if not good then p.errors[#p.errors + 1] = "opts: " .. tostring(res) end
  end
  for _, k in ipairs(p.keys or {}) do
    local good, res = pcall(ranma.bind, k[1], k[2], {
      desc = k.desc, global = k.global, exit = k.exit, group = k.group,
    })
    if not good then p.errors[#p.errors + 1] = "keys: " .. tostring(res) end
  end
end

local function setup(specs, opts)
  if opts == nil and type(specs) == "table" and specs.spec ~= nil then
    opts, specs = specs, specs.spec
  end
  opts = opts or {}
  for k in pairs(opts) do
    if not ({ root = true, lockfile = true, key = true })[k] then
      error("setup: unknown option `" .. tostring(k) .. "` (root, lockfile, key)", 0)
    end
  end
  state.opts = opts
  state.root = util.expand(opts.root or util.data_dir())
  state.lockfile = util.expand(opts.lockfile or ((ranma.config_dir or util.HOME) .. "/hako-lock.json"))
  state.self = self_dir()
  state.store = ranma.store("hako")
  declare_options()

  local ctx = spec.new(ranma.config_dir)
  spec.read(ctx, specs or {}, "init.lua", false)
  state.plugins = spec.order(ctx)
  state.by_name = ctx.by_name
  state.spec_errors = ctx.errors
  state.imports = ctx.imports
  state.lock = lock.read(state.lockfile)

  for _, p in ipairs(state.plugins) do
    p.errors = {}
    p.managed = p.dir == nil
    p.path = p.dir or (state.root .. "/" .. p.name)
    p.installed = util.is_dir(p.path)
    -- enabled = false: as if not declared (clean removes it). cond = false:
    -- kept and updated, only not loaded.
    p.wanted = truth(p, p.enabled, "enabled")
    p.on = p.wanted and truth(p, p.cond, "cond")
    if p.installed and p.on then load(p) end
  end

  -- A spec hako could not read is hako's to say. A plugin that failed to
  -- load, ranma has already toasted: the screen and the module show it.
  for _, e in ipairs(ctx.errors) do
    util.toast("hako: " .. util.tilde(e.source) .. ": " .. e.spec .. ": " .. e.error, true)
  end

  local ok, err = pcall(require("hako.ui").install, opts)
  if not ok then util.toast("hako: " .. tostring(err), true) end
  local screen = require("hako.screen")
  screen.forget_added()
  screen.after_load()
  require("hako.ops").after_load()
end

-- Read the specs and load what is installed. A bug in hako, or a spec it
-- cannot read, never fails init.lua: it is toasted and ranma starts.
function M.setup(specs, opts)
  local ok, err = pcall(setup, specs, opts)
  if not ok then util.toast("hako: setup failed: " .. tostring(err), true) end
end

function M.plugins()
  return state.plugins or {}
end

-- The operations, for binds and `ranma lua`. sync and clean ask first, on
-- the screen.
for _, name in ipairs({ "install", "update", "check", "restore" }) do
  M[name] = function(...) return require("hako.ops")[name](...) end
end
for _, name in ipairs({ "open", "sync", "clean", "log" }) do
  M[name] = function(...) return require("hako.screen")[name](...) end
end

return M
