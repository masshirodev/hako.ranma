-- What hako does in the background: clone, fetch, update, restore, clean.
-- One operation at a time, several plugins at once; ranma reloads at the
-- end when what loads has changed.
local util = require("hako.util")
local task = require("hako.task")
local lock = require("hako.lock")
local state = require("hako.state")

local M = {}

local function git(p, ...)
  return task.run({ "git", "-C", p.path, ... })
end

local function managed(name)
  local out = {}
  for _, p in ipairs(state.plugins) do
    if p.managed and p.wanted and (name == nil or p.name == name) then out[#out + 1] = p end
  end
  return out
end

-- The status bar module and the list read these.
local function updates()
  return state.store:get("updates") or {}
end

local function set_update(name, info)
  local all = updates()
  all[name] = info
  state.store:set("updates", all)
end

local function set_failure(name, msg)
  local all = state.store:get("failures") or {}
  all[name] = msg
  state.store:set("failures", all)
end

function M.updates()
  return updates()
end

function M.failures()
  return state.store:get("failures") or {}
end

-- Where a plugin's checkout is, for the lockfile. Inside a task.
local function locate(p)
  local ok, commit = git(p, "rev-parse", "HEAD")
  if not ok then return nil end
  local on_branch, branch = git(p, "symbolic-ref", "--short", "-q", "HEAD")
  return { commit = commit, branch = on_branch and branch or nil, tag = p.tag }
end

local function relock(found)
  for name, entry in pairs(found) do state.lock[name] = entry end
  -- Only what the specs declare stays locked.
  for name in pairs(state.lock) do
    local p = state.by_name[name]
    if not (p and p.managed and p.wanted) then state.lock[name] = nil end
  end
  local ok, err = lock.write(state.lockfile, state.lock)
  if not ok then ranma.toast("hako: cannot write " .. util.tilde(state.lockfile) .. ": " .. tostring(err), { urgent = true }) end
end

local function build(p)
  if not p.build then return true end
  state.tasks[p.name] = "building"
  if type(p.build) == "function" then
    local ok, err = pcall(p.build, p)
    return ok, ok and nil or ("build: " .. tostring(err))
  end
  local ok, out, err = task.run({ "sh", "-c", p.build }, p.path, 600)
  return ok, ok and nil or ("build: " .. (err ~= "" and err or out))
end

-- The commit a fresh clone should sit at: the spec's pin, else the lock's.
local function target(p)
  if p.commit then return p.commit, true end
  if p.tag then return "tags/" .. p.tag, true end
  local e = state.lock[p.name]
  if e and e.commit and (not p.branch or e.branch == p.branch) then return e.commit, false end
  return nil
end

local function install_one(p)
  state.tasks[p.name] = "cloning"
  local argv = { "git", "clone", "--filter=blob:none", "--quiet" }
  if p.branch then
    argv[#argv + 1] = "--branch"
    argv[#argv + 1] = p.branch
  end
  argv[#argv + 1] = p.url
  argv[#argv + 1] = p.path
  local ok, _, err = task.run(argv)
  if not ok then return false, err end
  local at, detached = target(p)
  if at then
    state.tasks[p.name] = "checking out"
    if detached then
      ok, _, err = git(p, "checkout", "--quiet", at)
    else
      ok, _, err = git(p, "reset", "--hard", "--quiet", at)
    end
    if not ok then return false, err end
  end
  ok, err = build(p)
  if not ok then return false, err end
  return true, locate(p)
end

-- How far behind its target a plugin is: fetches first. Inside a task.
local function check_one(p)
  state.tasks[p.name] = "fetching"
  local ok, _, err = git(p, "fetch", "--quiet", "--tags", "--force", "origin")
  if not ok then return false, err end
  if p.commit then
    set_update(p.name, nil)
    return true, { n = 0, pinned = true }
  end
  local ref = p.tag and ("refs/tags/" .. p.tag) or "@{upstream}"
  local good, count = git(p, "rev-list", "--count", "HEAD.." .. ref)
  if not good then
    -- A detached checkout has no upstream: compare with the remote's head.
    ref = "origin/HEAD"
    good, count, err = git(p, "rev-list", "--count", "HEAD.." .. ref)
    if not good then return false, err end
  end
  local n = tonumber(count) or 0
  local log = {}
  if n > 0 then
    local _, out = git(p, "log", "--format=%h %s", "-n", "30", "HEAD.." .. ref)
    for line in out:gmatch("[^\n]+") do log[#log + 1] = line end
  end
  local info = { n = n, log = log, ref = ref, pinned = p.pin or false }
  set_update(p.name, n > 0 and info or nil)
  return true, info
end

local function update_one(p)
  if p.commit then return true, { skipped = "pinned to a commit" } end
  local ok, info = check_one(p)
  if not ok then return false, info end
  if p.pin then return true, { skipped = "pinned" } end
  if info.n == 0 then return true, { lock = locate(p) } end
  state.tasks[p.name] = "updating"
  local err
  if p.tag then
    ok, _, err = git(p, "checkout", "--quiet", info.ref)
  else
    ok, _, err = git(p, "merge", "--ff-only", "--quiet", info.ref)
  end
  if not ok then return false, err end
  ok, err = build(p)
  if not ok then return false, err end
  set_update(p.name, nil)
  return true, { changed = info.n, lock = locate(p) }
end

local function restore_one(p)
  local e = state.lock[p.name]
  if not (e and e.commit) then return true, { skipped = "not in the lockfile" } end
  local ok, now = git(p, "rev-parse", "HEAD")
  if ok and now == e.commit then return true, {} end
  state.tasks[p.name] = "restoring"
  if not git(p, "cat-file", "-e", e.commit .. "^{commit}") then
    ok, _, now = git(p, "fetch", "--quiet", "origin")
    if not ok then return false, now end
  end
  local err
  if p.commit or p.tag then
    ok, _, err = git(p, "checkout", "--quiet", e.commit)
  else
    ok, _, err = git(p, "reset", "--hard", "--quiet", e.commit)
  end
  if not ok then return false, err end
  return true, { changed = 1 }
end

-- Run `worker` over `plugins`; toast the outcome, relock, reload if needed.
local function batch(op, plugins, worker, opts)
  opts = opts or {}
  if state.busy then
    ranma.toast("hako: " .. state.busy .. " is still running")
    return
  end
  if #plugins == 0 then
    if not opts.quiet then ranma.toast("hako: " .. op .. ": nothing to do") end
    if opts.after then opts.after() end
    return
  end
  state.busy = op
  local done, failed, changed, found, notes = 0, {}, 0, {}, {}
  if not opts.quiet then ranma.notify("hako: " .. op .. " " .. #plugins .. " …") end
  task.pool(plugins, ranma.get("hako.concurrency") or 4, worker, function(p, ok, res)
    state.tasks[p.name] = nil
    if ok then
      done = done + 1
      set_failure(p.name, nil)
      local r = type(res) == "table" and res or {}
      if r.commit then found[p.name] = r end
      if r.lock then found[p.name] = r.lock end
      if r.changed then changed = changed + 1 end
      if r.n and r.n > 0 then notes[#notes + 1] = p.name .. " ↑" .. r.n end
    else
      failed[#failed + 1] = p.name
      set_failure(p.name, op .. ": " .. tostring(res))
    end
  end, function()
    state.busy = nil
    if next(found) then relock(found) end
    if opts.summary then
      opts.summary(done, failed, notes)
    elseif #failed > 0 then
      ranma.toast("hako: " .. op .. " failed for " .. table.concat(failed, ", ") .. " (hako list)", { urgent = true })
    elseif not opts.quiet then
      ranma.toast("hako: " .. op .. ": " .. (changed > 0 and (changed .. " changed") or "nothing changed"))
    end
    if opts.after then return opts.after(changed) end
    if changed > 0 then ranma.action("reload_config") end
  end)
end

function M.install(opts)
  local missing = {}
  for _, p in ipairs(managed()) do
    if not p.installed then missing[#missing + 1] = p end
  end
  batch("install", missing, function(p)
    local ok, res = install_one(p)
    if ok then
      res = res or {}
      res.changed = 1
    end
    return ok, res
  end, opts)
end

function M.update(name, opts)
  local list = {}
  for _, p in ipairs(managed(name)) do
    if p.installed then list[#list + 1] = p end
  end
  batch("update", list, update_one, opts)
end

function M.check(name, quiet)
  local list = {}
  for _, p in ipairs(managed(name)) do
    if p.installed then list[#list + 1] = p end
  end
  state.store:set("checked_at", os.time())
  batch("check", list, check_one, {
    quiet = quiet,
    after = function() end,
    summary = function(_, failed, notes)
      if #notes > 0 and (not quiet or ranma.get("hako.notify")) then
        ranma.toast("hako: updates: " .. table.concat(notes, ", ") .. " (hako update)")
      elseif #failed > 0 and not quiet then
        ranma.toast("hako: check failed for " .. table.concat(failed, ", "), { urgent = true })
      elseif not quiet then
        ranma.toast("hako: everything is up to date")
      end
    end,
  })
end

function M.restore(name)
  local list = {}
  for _, p in ipairs(managed(name)) do
    if p.installed then list[#list + 1] = p end
  end
  batch("restore", list, restore_one)
end

-- Directories under hako's root that no spec wants (hako itself excepted).
function M.cleanable()
  local out = {}
  for _, name in ipairs(util.ls(state.root)) do
    local path = state.root .. "/" .. name
    local p = state.by_name[name]
    local wanted = p and p.managed and p.wanted
    if not wanted and path ~= state.self and util.is_dir(path) then out[#out + 1] = { name = name, path = path } end
  end
  return out
end

local function remove_dirs(dirs, after)
  if #dirs == 0 then return after and after(0) end
  local argv = { "rm", "-rf", "--" }
  for _, d in ipairs(dirs) do argv[#argv + 1] = d end
  ranma.spawn(argv, {
    timeout = 60,
    on_exit = function(r)
      if r.error or r.code ~= 0 then
        ranma.toast("hako: could not delete: " .. (r.error or r.stderr or ""), { urgent = true })
      end
      if after then after(#dirs) end
    end,
  })
end

-- Ask before anything is deleted: a picker whose first row keeps it.
function M.confirm(title, what, yes)
  ranma.picker {
    title = title,
    items = {
      { label = "keep it", go = false },
      { label = "delete " .. what, go = true },
    },
    on_select = function(item) if item.go then yes() end end,
  }
end

function M.clean(force)
  local list = M.cleanable()
  if #list == 0 then return ranma.toast("hako: nothing to clean") end
  local names, dirs = {}, {}
  for _, c in ipairs(list) do
    names[#names + 1] = c.name
    dirs[#dirs + 1] = c.path
  end
  local function go()
    remove_dirs(dirs, function(n) ranma.toast("hako: deleted " .. n .. ": " .. table.concat(names, ", ")) end)
  end
  if force then return go() end
  M.confirm("clean: no spec declares these", table.concat(names, ", "), go)
end

-- Install what is missing, clean, then update everything.
function M.sync()
  M.install({
    after = function(installed)
      if #M.cleanable() > 0 then M.clean() end
      M.update(nil, {
        after = function(updated)
          if (installed or 0) + (updated or 0) > 0 then ranma.action("reload_config") end
        end,
      })
    end,
  })
end

-- Write lua/<import>/<name>.lua with the spec; saving it reloads ranma,
-- which installs it.
function M.add(src)
  src = (src or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if src == "" then return ranma.toast("hako add: give owner/repo or a URL") end
  local dir = state.imports[1]
  if not dir then
    return ranma.toast("hako add: there is no { import = \"plugins\" } in the setup to write to", { urgent = true })
  end
  local name = require("hako.spec").main_of((src:gsub("/+$", ""):match("([^/:]+)$") or src):gsub("%.git$", ""))
  local file = dir .. "/" .. name .. ".lua"
  if util.exists(file) then return ranma.toast("hako add: " .. util.tilde(file) .. " exists", { urgent = true }) end
  os.execute("mkdir -p " .. util.quote(dir))
  local ok, err = util.write(file, "return { " .. string.format("%q", src) .. " }\n")
  if not ok then return ranma.toast("hako add: " .. tostring(err), { urgent = true }) end
  ranma.toast("hako: wrote " .. util.tilde(file) .. "; installing")
end

-- A plugin declared in a file of its own: delete the file and the clone. One
-- declared anywhere else: say where, since hako does not rewrite your config.
function M.remove(name)
  local p = state.by_name[name or ""]
  if not p then return ranma.toast("hako remove: no plugin `" .. tostring(name) .. "`") end
  if not p.single or p.sources[1] == "init.lua" then
    return ranma.toast("hako remove: " .. name .. " is declared in " .. table.concat(p.sources, ", ")
      .. "; delete it there, then hako clean", { urgent = true })
  end
  local file = p.sources[1]
  M.confirm("remove " .. name, util.tilde(file) .. (p.managed and " and its clone" or ""), function()
    os.remove(file)
    remove_dirs(p.managed and { p.path } or {}, function() ranma.action("reload_config") end)
  end)
end

-- Once ranma has loaded: install what is missing, and check when it is time.
function M.after_load()
  util.later(function()
    if ranma.get("hako.install_missing") then
      local missing = false
      for _, p in ipairs(managed()) do missing = missing or not p.installed end
      if missing then M.install() end
    end
  end)
  local function due()
    if not ranma.get("hako.check") then return end
    local hours = ranma.get("hako.check_hours") or 6
    local last = state.store:get("checked_at") or 0
    if os.time() - last >= hours * 3600 then M.check(nil, true) end
  end
  -- Not at once: the first minute after a start is for the user.
  ranma.defer(60 * 1000, due)
  ranma.every(30 * 60 * 1000, due)
end

return M
