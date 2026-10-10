-- Specs: what the user declared, read as strictly as ranma reads init.lua.
--
-- A spec is "owner/repo", or a table: { "owner/repo", opts = {...}, ... },
-- { dir = "~/src/thing.ranma" }, or { import = "plugins" } (every
-- lua/plugins/*.lua, each returning a spec or a list of them). A plugin
-- declared twice is merged, opts deeply, as lazy.nvim does.
local util = require("hako.util")

local M = {}

-- Field -> the types it takes.
local FIELDS = {
  name = "string", url = "string", dir = "string", main = "string",
  branch = "string", tag = "string", commit = "string",
  pin = "boolean", priority = "number",
  enabled = "boolean|function", cond = "boolean|function",
  opts = "table|function", config = "function", init = "function",
  build = "string|function", keys = "table", dependencies = "table|string",
}

-- lazy.nvim's fields that mean nothing here, and what to do instead.
local LAZY_LOAD = "hako does not lazy-load: plugins load with the configuration, in about a millisecond"
local NOT_HERE = {
  lazy = LAZY_LOAD, event = LAZY_LOAD, cmd = LAZY_LOAD, ft = LAZY_LOAD, module = LAZY_LOAD,
  version = "no semver ranges: pin a `tag` or a `commit`",
  dev = "for a checkout of your own, use `dir`",
  submodules = "submodules are not cloned",
  rocks = "there are no luarocks here",
}

local function type_ok(value, want)
  for t in want:gmatch("[^|]+") do
    if type(value) == t then return true end
  end
  return false
end

-- A table that is one spec (rather than a list of them).
local function is_spec(t)
  return type(t[1]) == "string" or t.dir ~= nil or t.url ~= nil or t.import ~= nil or t.name ~= nil
end

local function name_of(t)
  if t.name then return t.name end
  local src = (t[1] or t.dir or t.url):gsub("/+$", "")
  return (src:match("([^/:]+)$") or src):gsub("%.git$", "")
end

local function url_of(t)
  if t.dir then return nil end
  if t.url then return t.url end
  local src = t[1]
  if not src then return nil end
  if src:match("^%a[%w+.-]*://") or src:match("^git@") or src:sub(1, 1) == "/" then return src end
  return "https://github.com/" .. src .. ".git"
end

-- The option group a plugin's `opts` go to: history.ranma -> history.
function M.main_of(name)
  return (name:gsub("%.ranma$", ""):gsub("^ranma[%-.]", ""))
end

-- Check one spec's fields; the first problem, or nil.
local function check(t)
  for k, v in pairs(t) do
    if k == 1 then
      if type(v) ~= "string" then return "its first item is the plugin's `owner/repo` or URL" end
    elseif type(k) ~= "string" then
      return "a spec takes one positional item, the plugin's source"
    elseif NOT_HERE[k] then
      return "`" .. k .. "`: " .. NOT_HERE[k]
    elseif k == "import" then
      return "`import` goes in a spec of its own: { import = \"plugins\" }"
    elseif not FIELDS[k] then
      return "unknown field `" .. k .. "`"
    elseif not type_ok(v, FIELDS[k]) then
      return "`" .. k .. "` takes a " .. FIELDS[k]:gsub("|", " or ") .. ", not a " .. type(v)
    end
  end
  local src = t[1]
  if src and not (src:match("^%a[%w+.-]*://") or src:match("^git@") or src:sub(1, 1) == "/"
      or src:match("^[%w._-]+/[%w._-]+$")) then
    return "`" .. src .. "` is not `owner/repo`, a URL or an absolute path"
  end
  if not (t[1] or t.dir or t.url) then
    return "it names no plugin: give `owner/repo`, `url` or `dir`"
  end
  if t.dir and (t[1] or t.url) then
    return "`dir` is a checkout hako never touches; it takes no source"
  end
  local pins = (t.tag and 1 or 0) + (t.commit and 1 or 0)
  if pins > 1 then return "`tag` and `commit` both pin it; give one" end
  return nil
end

-- A new reader: feed it with M.read, then take M.order.
function M.new(config_dir)
  return { config_dir = config_dir, plugins = {}, by_name = {}, errors = {}, imports = {}, n = 0 }
end

local function add(ctx, t, source, single)
  local problem = check(t)
  local label = type(t[1]) == "string" and t[1] or t.dir or t.url or t.name or "?"
  if problem then
    ctx.errors[#ctx.errors + 1] = { source = source, spec = label, error = problem }
    return nil
  end
  local deps = {}
  local list = t.dependencies
  if type(list) == "string" then list = { list } end
  for _, d in ipairs(list or {}) do
    local dep = M.read(ctx, d, source, false)
    if dep then deps[#deps + 1] = dep end
  end
  local name = name_of(t)
  local p = ctx.by_name[name]
  if not p then
    ctx.n = ctx.n + 1
    p = { name = name, main = M.main_of(name), deps = {}, sources = {}, seen = ctx.n }
    ctx.by_name[name] = p
    ctx.plugins[#ctx.plugins + 1] = p
  end
  p.sources[#p.sources + 1] = source
  -- One file holding only this spec is a file `hako remove` may delete.
  p.single = (#p.sources == 1) and single or false
  for k, v in pairs(t) do
    if k == "opts" then
      p.opts = (type(p.opts) == "table" and type(v) == "table") and util.merge(p.opts, v) or v
    elseif k ~= 1 and k ~= "dependencies" then
      p[k] = v
    end
  end
  p.url = url_of(t) or p.url
  if t.dir then p.dir = util.expand(t.dir) end
  if t.main then p.main = t.main end
  for _, d in ipairs(deps) do
    local known = false
    for _, have in ipairs(p.deps) do known = known or have == d end
    if not known then p.deps[#p.deps + 1] = d end
  end
  return name
end

-- The files an import names: lua/<a/b>.lua, or every lua/<a/b>/*.lua.
local function import_files(ctx, module)
  if not ctx.config_dir then return {}, nil end
  local base = ctx.config_dir .. "/lua/" .. module:gsub("%.", "/")
  if util.exists(base .. ".lua") then return { base .. ".lua" }, nil end
  local files = {}
  for _, f in ipairs(util.ls(base)) do
    if f:match("%.lua$") then files[#files + 1] = base .. "/" .. f end
  end
  return files, base
end

-- Read a spec, a list of them, or an import; returns the plugin's name for a
-- single spec, so dependencies can name what they read.
function M.read(ctx, t, source, single)
  if type(t) == "string" then return add(ctx, { t }, source, single) end
  if type(t) ~= "table" then
    ctx.errors[#ctx.errors + 1] = { source = source, spec = tostring(t), error = "a spec is a string or a table" }
    return nil
  end
  if t.import ~= nil then
    if type(t.import) ~= "string" or next(t, nil) ~= "import" or next(t, "import") ~= nil then
      ctx.errors[#ctx.errors + 1] = { source = source, spec = "import", error = "{ import = \"module\" } takes nothing else" }
      return nil
    end
    local files, dir = import_files(ctx, t.import)
    if dir then ctx.imports[#ctx.imports + 1] = dir end
    for _, file in ipairs(files) do
      local chunk, err = loadfile(file)
      local ok, res = false, err
      if chunk then ok, res = pcall(chunk) end
      if not ok then
        ctx.errors[#ctx.errors + 1] = { source = file, spec = file:match("[^/]*$"), error = tostring(res) }
      elseif type(res) ~= "table" and type(res) ~= "string" then
        ctx.errors[#ctx.errors + 1] = { source = file, spec = file:match("[^/]*$"), error = "it returns no spec" }
      else
        M.read(ctx, res, file, type(res) == "string" or is_spec(res))
      end
    end
    return nil
  end
  if is_spec(t) then return add(ctx, t, source, single) end
  for _, item in ipairs(t) do M.read(ctx, item, source, false) end
  return nil
end

-- The plugins in the order they load: dependencies first, then higher
-- `priority`, then as declared. A cycle is an error on each plugin in it.
function M.order(ctx)
  local list = {}
  for _, p in ipairs(ctx.plugins) do list[#list + 1] = p end
  table.sort(list, function(a, b)
    local pa, pb = a.priority or 50, b.priority or 50
    if pa ~= pb then return pa > pb end
    return a.seen < b.seen
  end)
  local out, state = {}, {}
  local function visit(p, path)
    if state[p.name] == "done" then return end
    if state[p.name] == "visiting" then
      ctx.errors[#ctx.errors + 1] = { source = p.sources[1], spec = p.name,
        error = "a dependency cycle: " .. table.concat(path, " -> ") .. " -> " .. p.name }
      return
    end
    state[p.name] = "visiting"
    path[#path + 1] = p.name
    for _, d in ipairs(p.deps) do
      if ctx.by_name[d] then visit(ctx.by_name[d], path) end
    end
    path[#path] = nil
    state[p.name] = "done"
    out[#out + 1] = p
  end
  for _, p in ipairs(list) do visit(p, {}) end
  return out
end

return M
