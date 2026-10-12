-- Plugin lists: JSON files at a URL naming plugins to browse, the official
-- one and any the user adds (doc/LISTS.md is the format, doc/SCREEN.md the
-- view). This module reads a list strictly, keeps which lists the user has
-- in hako-lists.json, keeps the last good copy of each, and fetches them with
-- curl in the background.
local util = require("hako.util")
local state = require("hako.state")
local task = require("hako.task")

local M = {}

-- The format this hako reads. A list in a newer one is refused by name,
-- rather than read for what this hako happens to understand.
M.FORMAT = 1

-- HAKO_OFFICIAL_LIST stands in for it in tests/e2e.sh, which never goes to
-- the network.
M.OFFICIAL = os.getenv("HAKO_OFFICIAL_LIST")
  or "https://raw.githubusercontent.com/masshirodev/ranma-plugins/main/plugins.json"

local TOP = { format = true, name = true, plugins = true }
local FIELDS = { repo = true, description = true, author = true, tags = true, needs = true, ranma = true }

-- ---------------------------------------------------------------------------
-- Reading a list. Pure: text in, a list or why not out.
-- ---------------------------------------------------------------------------

local function sorted_keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = tostring(k) end
  table.sort(out)
  return out
end

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n == #t
end

local function strings(v, what)
  if v == nil then return {} end
  if type(v) ~= "table" or not is_array(v) then return nil, "`" .. what .. "` is a list of strings" end
  for _, s in ipairs(v) do
    if type(s) ~= "string" or s == "" then return nil, "`" .. what .. "` is a list of strings" end
  end
  return v
end

-- "0.1.0" as numbers, or nil.
function M.version(v)
  if type(v) ~= "string" then return nil end
  local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  return { tonumber(a), tonumber(b), tonumber(c) }
end

-- Whether version `a` is older than `b` (both "x.y.z").
function M.older(a, b)
  local x, y = M.version(a), M.version(b)
  if not (x and y) then return false end
  for i = 1, 3 do
    if x[i] ~= y[i] then return x[i] < y[i] end
  end
  return false
end

-- What makes two mentions of a plugin the same plugin: its repository, as
-- spec reads one (owner/repo is GitHub), without scheme, .git or case.
function M.key(repo)
  local r = (repo or ""):lower():gsub("%.git$", ""):gsub("/+$", "")
  r = r:gsub("^%a[%w+.-]*://", ""):gsub("^git@([^:]+):", "%1/")
  return (r:gsub("^github%.com/", ""))
end

-- The name hako gives the plugin (as spec does): the repository's last part.
function M.name_of(repo)
  local src = repo:gsub("/+$", "")
  return ((src:match("([^/:]+)$") or src):gsub("%.git$", ""))
end

local function owner_of(repo)
  local src = repo:gsub("/+$", ""):gsub("%.git$", "")
  return src:match("([^/:]+)/[^/:]+$") or "?"
end

local function check_plugin(p, i)
  local where = "plugins[" .. i .. "]"
  if type(p) ~= "table" or is_array(p) and #p > 0 then return nil, where .. " is not an object" end
  if type(p.repo) == "string" then where = where .. " (" .. p.repo .. ")" end
  for _, k in ipairs(sorted_keys(p)) do
    if not FIELDS[k] then return nil, where .. ": unknown field `" .. k .. "`" end
  end
  if type(p.repo) ~= "string" or not (p.repo:match("^[%w_.-]+/[%w_.-]+$")
      or p.repo:match("^https://[^%s]+$") or p.repo:match("^file:///[^%s]+$")) then
    return nil, where .. ": `repo` is owner/repo (GitHub), or an https:// or file:// URL"
  end
  if type(p.description) ~= "string" or p.description == "" then
    return nil, where .. ": `description` is required"
  end
  if p.author ~= nil and (type(p.author) ~= "string" or p.author == "") then
    return nil, where .. ": `author` is a string"
  end
  local tags, err = strings(p.tags, "tags")
  if not tags then return nil, where .. ": " .. err end
  local needs
  needs, err = strings(p.needs, "needs")
  if not needs then return nil, where .. ": " .. err end
  if p.ranma ~= nil and not M.version(p.ranma) then
    return nil, where .. ": `ranma` is a version, \"0.1.0\""
  end
  return {
    repo = p.repo,
    name = M.name_of(p.repo),
    description = p.description,
    author = p.author or owner_of(p.repo),
    tags = tags,
    needs = needs,
    ranma = p.ranma,
  }
end

-- A list's text: { name, plugins }, or nil and the first problem.
function M.parse(text)
  local ok, t = pcall(ranma.json.decode, text or "")
  if not ok or type(t) ~= "table" or is_array(t) and #t > 0 then return nil, "not a JSON object" end
  for _, k in ipairs(sorted_keys(t)) do
    if not TOP[k] then return nil, "unknown field `" .. k .. "`" end
  end
  if type(t.format) ~= "number" then return nil, "`format` is required (" .. M.FORMAT .. ")" end
  if t.format > M.FORMAT then
    return nil, "format " .. t.format .. ": this hako reads format " .. M.FORMAT .. "; update hako"
  end
  if type(t.name) ~= "string" or t.name == "" then return nil, "`name` is required" end
  if type(t.plugins) ~= "table" or not is_array(t.plugins) then return nil, "`plugins` is a list" end
  local out, seen = {}, {}
  for i, p in ipairs(t.plugins) do
    local e, err = check_plugin(p, i)
    if not e then return nil, err end
    local k = M.key(e.repo)
    if seen[k] then return nil, "plugins[" .. i .. "] (" .. e.repo .. "): listed twice" end
    seen[k] = true
    out[#out + 1] = e
  end
  return { name = t.name, plugins = out }
end

-- ---------------------------------------------------------------------------
-- The user's lists: hako-lists.json, written only when they change one.
-- ---------------------------------------------------------------------------

local function config_path()
  return state.lists_file
end

-- { { url, on, added } }, the official one first, always there.
function M.read_config()
  local text = util.read(config_path())
  local t = {}
  if text then
    local ok, decoded = pcall(ranma.json.decode, text)
    if ok and type(decoded) == "table" and type(decoded.lists) == "table" then t = decoded.lists end
  end
  local out, official = {}, nil
  for _, l in ipairs(t) do
    if type(l) == "table" and type(l.url) == "string" then
      local e = { url = l.url, on = l.on ~= false, added = tonumber(l.added) }
      if l.url == M.OFFICIAL then official = e else out[#out + 1] = e end
    end
  end
  table.insert(out, 1, official or { url = M.OFFICIAL, on = true })
  return out
end

function M.write_config(lists)
  local lines = { "{", "  \"lists\": [" }
  for i, l in ipairs(lists) do
    local fields = { "\"url\": " .. ranma.json.encode(l.url), "\"on\": " .. tostring(l.on ~= false) }
    if l.added then fields[#fields + 1] = "\"added\": " .. l.added end
    lines[#lines + 1] = "    { " .. table.concat(fields, ", ") .. " }" .. (i < #lists and "," or "")
  end
  lines[#lines + 1] = "  ]"
  lines[#lines + 1] = "}"
  os.execute("mkdir -p " .. util.quote(config_path():match("^(.*)/[^/]*$") or "."))
  return util.write(config_path(), table.concat(lines, "\n") .. "\n")
end

-- ---------------------------------------------------------------------------
-- The last good copy of each list, in the data directory.
-- ---------------------------------------------------------------------------

local function cache_dir()
  return state.root .. "/.lists"
end

local function cache_path(url)
  local name = url:gsub("^%a[%w+.-]*://", ""):gsub("[^%w%.%-]", "_")
  return cache_dir() .. "/" .. name:sub(1, 120) .. ".json"
end

-- { name, plugins, fetched_at }, or nil when there is none (or it no longer
-- reads, after a hako update tightened the format).
function M.cached(url)
  local text = util.read(cache_path(url))
  if not text then return nil end
  local ok, t = pcall(ranma.json.decode, text)
  if not ok or type(t) ~= "table" then return nil end
  local list = M.parse(t.body)
  if not list then return nil end
  list.fetched_at = tonumber(t.fetched_at)
  return list
end

local function save(url, body)
  os.execute("mkdir -p " .. util.quote(cache_dir()))
  return util.write(cache_path(url), "{ \"fetched_at\": " .. os.time() .. ", \"body\": "
    .. ranma.json.encode(body) .. " }\n")
end

function M.forget(url)
  os.remove(cache_path(url))
end

-- ---------------------------------------------------------------------------
-- Fetching. What is happening to each list is in the store, so it outlives a
-- reload: { [url] = { since, tried_at, error } }.
-- ---------------------------------------------------------------------------

local function status_of()
  return state.store:get("lists") or {}
end

function M.status(url)
  return status_of()[url] or {}
end

local function set_status(url, s)
  local all = status_of()
  all[url] = s
  state.store:set("lists", all)
end

-- curl's own words, first line, without its progress noise.
local function curl_error(stderr, code)
  local line = util.first_line(stderr)
  if line == "" then return "curl failed (exit " .. tostring(code) .. ")" end
  -- ranma could not start it at all: no curl on PATH.
  if not line:match("^curl:") and (line:match("No such file") or line:match("not found")) then
    return "curl is not installed: Browse fetches its lists with it"
  end
  return line
end

-- Inside a task: fetch one URL and read it. Returns the list, or nil and why.
local function fetch_one(url)
  local ok, out, err, code = task.run({ "curl", "-fsSL", "--max-time", "10", url }, nil, 20)
  if not ok then return nil, curl_error(err, code) end
  local list, perr = M.parse(out)
  if not list then return nil, perr end
  return list, nil, out
end

-- Whether a list is due a fetch: never fetched, or older than the check
-- interval (hako.check_hours, the same as updates).
function M.due(url)
  local c = M.cached(url)
  if not c or not c.fetched_at then return true end
  local hours = ranma.get("hako.check_hours") or 6
  return os.time() - c.fetched_at >= hours * 3600
end

-- Fetch these lists (URLs) in the background; `changed()` after each step,
-- `done()` once all have ended. A failure keeps the last good copy.
function M.fetch(urls, changed, done)
  local todo = {}
  for _, url in ipairs(urls) do
    if not M.status(url).since then todo[#todo + 1] = url end
  end
  for _, url in ipairs(todo) do
    local s = M.status(url)
    s.since = os.time()
    set_status(url, s)
  end
  if changed then changed() end
  task.pool(todo, 4, function(url)
    local list, err, body = fetch_one(url)
    if list then save(url, body) end
    return list ~= nil, err
  end, function(url, ok, err)
    set_status(url, { tried_at = os.time(), error = (not ok) and (err or "failed") or nil })
    if changed then changed() end
  end, function()
    if done then done() end
  end)
end

-- Fetch one list to look at it before it is added: `cb(list, err, body)`.
function M.peek(url, cb)
  -- One table back: a task hands its function's first two values on.
  task.start(function()
    local list, err, body = fetch_one(url)
    return { list = list, err = err, body = body }
  end, function(r, err)
    if type(r) ~= "table" then return cb(nil, err) end
    cb(r.list, r.err, r.body)
  end)
end

-- Add a list the user said yes to, with the copy just fetched.
function M.add(url, body)
  local lists = M.read_config()
  for _, l in ipairs(lists) do
    if l.url == url then
      l.on = true
      save(url, body)
      return M.write_config(lists)
    end
  end
  lists[#lists + 1] = { url = url, on = true, added = os.time() }
  save(url, body)
  set_status(url, { tried_at = os.time() })
  return M.write_config(lists)
end

function M.toggle(url)
  local lists = M.read_config()
  for _, l in ipairs(lists) do
    if l.url == url then l.on = not l.on end
  end
  return M.write_config(lists)
end

function M.remove(url)
  if url == M.OFFICIAL then return nil, "the official list can be turned off, not removed" end
  local lists, out = M.read_config(), {}
  for _, l in ipairs(lists) do
    if l.url ~= url then out[#out + 1] = l end
  end
  M.forget(url)
  set_status(url, nil)
  return M.write_config(out)
end

return M
