-- What hako does in the background: clone, fetch, update, restore, clean.
-- One run at a time, several plugins at once. While a run goes, each
-- plugin's task (state.tasks) carries what it is doing, how far, and the tail
-- of its output, and the screen draws it; ranma reloads at the end when what
-- loads has changed.
local util = require("hako.util")
local task = require("hako.task")
local lock = require("hako.lock")
local state = require("hako.state")

local M = {}

local TAIL = 6
local HISTORY_DAYS = 30

-- The screen, when it is open, redraws from state; it is required late
-- because it requires this module.
local function changed()
  local ok, screen = pcall(require, "hako.screen")
  if ok then screen.changed() end
end

local function store()
  return state.store
end

-- ---------------------------------------------------------------------------
-- What outlives a reload: update counts, failures, the update history.
-- ---------------------------------------------------------------------------

function M.updates()
  return store():get("updates") or {}
end

local function set_update(name, info)
  local all = M.updates()
  all[name] = info
  store():set("updates", all)
end

-- A failed task: { task = "pull", tail = { lines }, code = 1, cmd = "git ..." }.
function M.failures()
  return store():get("failures") or {}
end

local function set_failure(name, f)
  local all = M.failures()
  all[name] = f
  store():set("failures", all)
end

-- What updates brought, newest first: { name, from, to, time, commits }.
function M.history()
  return store():get("history") or {}
end

local function add_history(entry)
  local list = { entry }
  local cutoff = os.time() - HISTORY_DAYS * 86400
  for _, e in ipairs(M.history()) do
    if e.time >= cutoff and #list < 100 then list[#list + 1] = e end
  end
  store():set("history", list)
end

-- ---------------------------------------------------------------------------
-- Running things.
-- ---------------------------------------------------------------------------

local function quote_all(argv)
  local out = {}
  for i, a in ipairs(argv) do out[i] = util.quote(a) end
  return table.concat(out, " ")
end

-- A task's record for the screen: `t.task` is the word, `t.frac` how far.
local function begin(p, word)
  local t = { task = word, since = os.time(), tail = {} }
  state.tasks[p.name] = t
  changed()
  return t
end

local function remember_line(t, line)
  line = line:gsub("%s+$", "")
  if line == "" then return end
  -- git rewrites one line as it counts; keep only its latest state.
  local head = line:match("^([^:]+):")
  local last = t.tail[#t.tail]
  if head and last and last:match("^([^:]+):") == head then
    t.tail[#t.tail] = line
  else
    t.tail[#t.tail + 1] = line
    if #t.tail > TAIL then table.remove(t.tail, 1) end
  end
  local pct = line:match("Receiving objects:%s+(%d+)%%") or line:match("Resolving deltas:%s+(%d+)%%")
  if pct then
    -- Receiving is most of the wait; resolving is the last stretch.
    local f = tonumber(pct) / 100
    t.frac = line:find("Resolving") and (0.9 + f * 0.1) or (f * 0.9)
  end
  changed()
end

-- Run a command and keep its output's tail in the task, as git prints it:
-- progress counters come on stderr, rewritten with \r. The exit status is
-- git's (pipefail), not tr's.
local function watched(t, argv, cwd, timeout)
  local cmd = "set -o pipefail; " .. quote_all(argv) .. " 2>&1 | tr '\\r' '\\n'"
  local ok, _, err, code = task.run({ "bash", "-c", cmd }, cwd, timeout, function(line) remember_line(t, line) end)
  return ok, err, code
end

local function failure(t, word, argv, code, err)
  local tail = {}
  for _, l in ipairs(t.tail) do tail[#tail + 1] = l end
  if err and err ~= "" and #tail == 0 then tail[1] = util.first_line(err) end
  return { task = word, tail = tail, code = code, cmd = argv and table.concat(argv, " ") or nil }
end

local function git(p, ...)
  return task.run({ "git", "-C", p.path, ... })
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
  local t = begin(p, "build")
  if type(p.build) == "function" then
    local ok, err = pcall(p.build, p)
    if ok then return true end
    t.tail = { tostring(err) }
    return false, failure(t, "build", nil, nil, tostring(err))
  end
  t.tail = { "$ " .. p.build }
  local ok, err, code = watched(t, { "sh", "-c", p.build }, p.path, 600)
  if ok then return true end
  return false, failure(t, "build", { p.build }, code, err)
end

-- The commit a fresh clone should sit at: the spec's pin, else the lock's.
local function target(p)
  if p.commit then return p.commit, true end
  if p.tag then return "tags/" .. p.tag, true end
  local e = state.lock[p.name]
  if e and e.commit and (not p.branch or e.branch == p.branch) then return e.commit, false end
  return nil
end

-- Where a clone is made before it is a plugin: a reload kills every job the
-- old configuration started, and a half-made clone under the plugin's own
-- name would load as if installed. Renamed into place only when done.
local function part_dir(p)
  return state.root .. "/.part-" .. p.name
end

local function install_one(p)
  local t = begin(p, "clone")
  -- The plugin as it is while being made: everything runs in the part dir.
  local q = setmetatable({ path = part_dir(p) }, { __index = p })
  task.run({ "rm", "-rf", "--", q.path })
  local argv = { "git", "clone", "--progress", "--filter=blob:none" }
  if p.branch then
    argv[#argv + 1] = "--branch"
    argv[#argv + 1] = p.branch
  end
  argv[#argv + 1] = p.url
  argv[#argv + 1] = q.path
  local ok, err, code = watched(t, argv)
  if not ok then return false, failure(t, "clone", argv, code, err) end
  local at, detached = target(p)
  if at then
    t.task, t.frac = "checkout", nil
    if detached then
      ok, _, err = git(q, "checkout", "--quiet", at)
    else
      ok, _, err = git(q, "reset", "--hard", "--quiet", at)
    end
    if not ok then return false, failure(t, "checkout", nil, nil, err) end
  end
  local built, f = build(q)
  if not built then return false, f end
  local moved, why = os.rename(q.path, p.path)
  if not moved then return false, failure(t, "clone", nil, nil, "could not move it into place: " .. tostring(why)) end
  return true, { lock = locate(p), changed = true, result = { "✓ cloned", "normal" } }
end

-- How far behind its target a plugin is: fetches first. Inside a task.
local function check_one(p)
  local t = begin(p, "fetch")
  local argv = { "git", "-C", p.path, "fetch", "--progress", "--tags", "--force", "origin" }
  local ok, err, code = watched(t, argv)
  if not ok then return false, failure(t, "fetch", argv, code, err) end
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
    if not good then return false, failure(t, "fetch", nil, nil, err) end
  end
  local n = tonumber(count) or 0
  local log = {}
  if n > 0 then
    local _, out = git(p, "log", "--format=%h %s", "-n", "30", "HEAD.." .. ref)
    for line in out:gmatch("[^\n]+") do log[#log + 1] = line end
  end
  local _, tip = git(p, "rev-parse", ref)
  local info = { n = n, log = log, ref = ref, tip = tip, pinned = p.pin or false }
  set_update(p.name, n > 0 and info or nil)
  return true, info
end

-- The commits between two points, with the files each touched.
local function commits_between(p, from, to)
  local ok, out = git(p, "log", "--format=%x1e%h%x09%ct%x09%an%x09%s", "--numstat", from .. ".." .. to)
  local list = {}
  if not ok then return list end
  for rec in out:gmatch("\30([^\30]*)") do
    local head, rest = rec:match("^([^\n]*)\n?(.*)$")
    local hash, time, author, subject = head:match("^(%S+)\t(%d+)\t([^\t]*)\t(.*)$")
    if hash then
      local files = {}
      for add, del, path in (rest or ""):gmatch("(%S+)\t(%S+)\t([^\n]+)") do
        files[#files + 1] = { path = path, add = add, del = del }
      end
      list[#list + 1] = { hash = hash, time = tonumber(time), author = author, subject = subject, files = files }
    end
  end
  return list
end

local function update_one(p)
  if p.commit then return true, { result = { "– skipped", "dim" } } end
  local ok, info = check_one(p)
  if not ok then return false, info end
  if p.pin then return true, { result = { "– skipped", "dim" } } end
  if info.n == 0 then return true, { lock = locate(p), result = { "✓ same", "dim" } } end
  local _, from = git(p, "rev-parse", "HEAD")
  local t = begin(p, "pull")
  local argv, err, code
  if p.tag then
    argv = { "git", "-C", p.path, "checkout", "--quiet", info.ref }
  else
    argv = { "git", "-C", p.path, "merge", "--ff-only", "--quiet", info.ref }
  end
  t.tail = { "$ " .. table.concat(argv, " ", 3) }
  ok, err, code = watched(t, argv)
  if not ok then return false, failure(t, "pull", argv, code, err) end
  local built, f = build(p)
  if not built then return false, f end
  set_update(p.name, nil)
  local _, to = git(p, "rev-parse", "HEAD")
  add_history({ name = p.name, from = from, to = to, time = os.time(), commits = commits_between(p, from, to) })
  return true, { lock = locate(p), changed = true, result = { "✓ +" .. info.n, "normal" } }
end

local function restore_one(p)
  local e = state.lock[p.name]
  if not (e and e.commit) then return true, { result = { "– not locked", "dim" } } end
  local ok, now = git(p, "rev-parse", "HEAD")
  if ok and now == e.commit then return true, { result = { "✓ same", "dim" } } end
  local t = begin(p, "restore")
  local err
  if not git(p, "cat-file", "-e", e.commit .. "^{commit}") then
    local argv = { "git", "-C", p.path, "fetch", "--progress", "origin" }
    t.task = "fetch"
    local code
    ok, err, code = watched(t, argv)
    if not ok then return false, failure(t, "fetch", argv, code, err) end
  end
  if p.commit or p.tag then
    ok, _, err = git(p, "checkout", "--quiet", e.commit)
  else
    ok, _, err = git(p, "reset", "--hard", "--quiet", e.commit)
  end
  if not ok then return false, failure(t, "restore", nil, nil, err) end
  return true, { changed = true, result = { "✓ " .. e.commit:sub(1, 7), "normal" } }
end

local function sync_one(p)
  if not p.installed then return install_one(p) end
  return update_one(p)
end

-- ---------------------------------------------------------------------------
-- Runs.
-- ---------------------------------------------------------------------------

local function managed(name)
  local out = {}
  for _, p in ipairs(state.plugins) do
    if p.managed and p.wanted and (name == nil or p.name == name) then out[#out + 1] = p end
  end
  return out
end

local function reload()
  local ok, screen = pcall(require, "hako.screen")
  if ok then screen.before_reload() end
  ranma.action("reload_config")
end

-- Run `worker` over `plugins`; relock, report, reload when something that
-- loads changed. opts: quiet, summary(done, failed, results), after(changed).
local function run(op, plugins, worker, opts)
  opts = opts or {}
  if state.run then
    ranma.toast("hako: " .. state.run.op .. " is still running")
    return
  end
  if #plugins == 0 then
    if not opts.quiet then ranma.toast("hako: " .. op .. ": nothing to do") end
    if opts.after then opts.after(0) end
    return
  end
  state.results = {}
  state.run = { op = op, total = #plugins, done = 0, failed = 0 }
  local ok_screen, screen = pcall(require, "hako.screen")
  if ok_screen then screen.freeze() end
  local ticker = ranma.every(500, changed)
  local found, failed, notes, n_changed = {}, {}, {}, 0
  task.pool(plugins, ranma.get("hako.concurrency") or 4, worker, function(p, ok, res)
    state.tasks[p.name] = nil
    state.run.done = state.run.done + 1
    local r = type(res) == "table" and res or {}
    if ok then
      set_failure(p.name, nil)
      -- Locked as each one lands, not at the end: a reload may stop the run
      -- before it ends, and what landed must be in the lock all the same.
      if r.lock then
        found[p.name] = r.lock
        relock({ [p.name] = r.lock })
      end
      if r.changed then n_changed = n_changed + 1 end
      if r.n and r.n > 0 then notes[#notes + 1] = p.name end
      if r.result then state.results[p.name] = r.result end
    else
      state.run.failed = state.run.failed + 1
      failed[#failed + 1] = p.name
      if type(res) ~= "table" then r = { task = op, tail = { tostring(res) } } end
      set_failure(p.name, r)
      state.results[p.name] = { "✗ " .. (r.task or op), "urgent" }
    end
    changed()
  end, function()
    ranma.cancel(ticker)
    state.run = nil
    if ok_screen then screen.thaw() end
    changed()
    local open = ok_screen and screen.is_open()
    if opts.summary then
      opts.summary(failed, notes)
    elseif not open and #failed > 0 then
      ranma.toast("hako: " .. op .. " failed for " .. table.concat(failed, ", "), { urgent = true })
    elseif not open and not opts.quiet then
      ranma.toast("hako: " .. op .. ": " .. (n_changed > 0 and (n_changed .. " changed") or "nothing changed"))
    end
    if opts.after then return opts.after(n_changed) end
    if n_changed > 0 then reload() end
  end)
end

function M.running()
  return state.run
end

-- Installs someone asked for and that have not finished: a reload stops a
-- run, and the next load picks these up again.
local function pending()
  return store():get("pending") or {}
end

local function set_pending(name, on)
  local all = pending()
  all[name] = on or nil
  store():set("pending", all)
end

function M.install(name, opts)
  local missing = {}
  for _, p in ipairs(managed(name)) do
    if not p.installed then
      missing[#missing + 1] = p
      set_pending(p.name, true)
    end
  end
  run("install", missing, function(p)
    local ok, res = install_one(p)
    if ok then set_pending(p.name, nil) end
    return ok, res
  end, opts)
end

function M.update(name, opts)
  local list = {}
  for _, p in ipairs(managed(name)) do
    if p.installed then list[#list + 1] = p end
  end
  run("update", list, update_one, opts)
end

-- The toast for a check: once per new commits, naming the key that opens
-- the screen.
local function check_summary(quiet)
  return function(failed, notes)
    local fresh = {}
    local seen = store():get("toasted") or {}
    local ups = M.updates()
    for _, name in ipairs(notes) do
      local tip = ups[name] and ups[name].tip
      if tip and seen[name] ~= tip then
        fresh[#fresh + 1] = name
        seen[name] = tip
      end
    end
    store():set("toasted", seen)
    local open = require("hako.screen").is_open()
    if #fresh > 0 and not open and (not quiet or ranma.get("hako.notify")) then
      local names = {}
      for i, n in ipairs(fresh) do names[i] = require("hako.spec").main_of(n) end
      local list = #names == 1 and names[1]
        or (table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names])
      local key = require("hako.screen").key_name()
      ranma.toast(#fresh .. (#fresh == 1 and " plugin has" or " plugins have") .. " updates: " .. list .. ".\n"
        .. (key and (key .. " shows them; ") or "hako shows them; ") .. "checked " .. os.date("%H:%M"))
    elseif not quiet and not open then
      if #failed > 0 then
        ranma.toast("hako: check failed for " .. table.concat(failed, ", "), { urgent = true })
      elseif #notes == 0 then
        ranma.toast("hako: everything is up to date")
      end
    end
  end
end

function M.check(name, quiet)
  local list = {}
  for _, p in ipairs(managed(name)) do
    if p.installed then list[#list + 1] = p end
  end
  store():set("checked_at", os.time())
  run("check", list, function(p)
    local ok, info = check_one(p)
    if ok and type(info) == "table" then
      info.result = info.n > 0 and { "↑ " .. info.n, "accent" } or { "✓ same", "dim" }
    end
    return ok, info
  end, { quiet = quiet, after = function() end, summary = check_summary(quiet) })
end

function M.restore(name)
  local list = {}
  for _, p in ipairs(managed(name)) do
    if p.installed then list[#list + 1] = p end
  end
  run("restore", list, restore_one)
end

-- Run a plugin's build again.
function M.rebuild(name)
  local p = state.by_name[name or ""]
  if not (p and p.installed) then return end
  run("build", { p }, function(q)
    local ok, f = build(q)
    if not ok then return false, f end
    return true, { changed = true, result = { "✓ built", "normal" } }
  end)
end

-- Install what is missing and update the rest, in one run; strays are the
-- screen's to ask about before (`clean = true` deletes them first).
function M.sync(clean)
  local function go()
    for _, p in ipairs(managed()) do
    if not p.installed then set_pending(p.name, true) end
  end
  run("sync", managed(), function(p)
    local ok, res = sync_one(p)
    if ok then set_pending(p.name, nil) end
    return ok, res
  end)
  end
  if clean then return M.delete(M.cleanable(), go) end
  go()
end

-- ---------------------------------------------------------------------------
-- Deleting: only ever after an ask.
-- ---------------------------------------------------------------------------

-- Directories under hako's root that no spec wants (hako itself excepted).
function M.cleanable()
  local out = {}
  for _, name in ipairs(util.ls(state.root)) do
    local path = state.root .. "/" .. name
    local p = state.by_name[name]
    -- A clone being made (or left by a run a reload stopped) is hako's own.
    if name:sub(1, 1) == "." then p = { managed = true, wanted = true } end
    local wanted = p and p.managed and p.wanted
    if not wanted and path ~= state.self and util.is_dir(path) then out[#out + 1] = { name = name, path = path } end
  end
  return out
end

-- Delete `items` ({ name, path }), then `after(n)`.
function M.delete(items, after)
  if #items == 0 then return after and after(0) end
  local argv = { "rm", "-rf", "--" }
  for _, it in ipairs(items) do
    argv[#argv + 1] = it.path
    state.results[it.name] = { "✓ deleted", "dim" }
  end
  ranma.spawn(argv, {
    timeout = 60,
    on_exit = function(r)
      if r.error or r.code ~= 0 then
        ranma.toast("hako: could not delete: " .. (r.error or r.stderr or ""), { urgent = true })
      end
      changed()
      if after then after(#items) end
    end,
  })
end

function M.clean()
  M.delete(M.cleanable(), function(n)
    if not require("hako.screen").is_open() then ranma.toast("hako: deleted " .. n .. " clones") end
  end)
end

-- A plugin declared in a file of its own: delete the file and the clone, and
-- reload. (The screen asks first; this is the answer.)
function M.remove(name)
  local p = state.by_name[name or ""]
  if not (p and p.single and p.sources[1] ~= "init.lua") then return false end
  os.remove(p.sources[1])
  M.delete(p.managed and { { name = p.name, path = p.path } } or {}, function() reload() end)
  return true
end

-- Write lua/<import>/<name>.lua with the spec; saving it reloads ranma, which
-- installs it. Returns the plugin's name, or nil and why not.
function M.add(src, from)
  src = (src or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if src == "" then return nil, "give owner/repo or a URL" end
  local dir = state.imports[1]
  if not dir then return nil, "there is no { import = \"plugins\" } in the setup to write to" end
  local spec = require("hako.spec")
  local name = (src:gsub("/+$", ""):match("([^/:]+)$") or src):gsub("%.git$", "")
  local file = dir .. "/" .. spec.main_of(name) .. ".lua"
  if util.exists(file) then return nil, util.tilde(file) .. " exists" end
  os.execute("mkdir -p " .. util.quote(dir))
  local by = from and ("-- written by hako, from " .. from .. ";\n-- yours to edit") or "-- written by hako; yours to edit"
  local ok, err = util.write(file, "-- " .. util.tilde(file) .. "\n" .. by .. "\nreturn {\n  "
    .. string.format("%q", src) .. ",\n}\n")
  if not ok then return nil, tostring(err) end
  store():set("added", name)
  -- Adding is asking for it: the load the save sets off installs it.
  set_pending(name, true)
  return name
end

-- Once ranma has loaded: install what is missing, and check when it is time.
function M.after_load()
  util.later(function()
    -- Clones a reload stopped half made: no job of this configuration is
    -- making them, so they go, and the install below starts over the ones
    -- that were asked for.
    local parts = {}
    for _, name in ipairs(util.ls(state.root)) do
      if name:match("^%.part%-") then parts[#parts + 1] = state.root .. "/" .. name end
    end
    if #parts > 0 then
      table.insert(parts, 1, "--")
      table.insert(parts, 1, "-rf")
      table.insert(parts, 1, "rm")
      ranma.spawn(parts, { timeout = 60 })
    end
    local missing, asked = {}, {}
    local wanted = pending()
    for _, p in ipairs(managed()) do
      if not p.installed then
        missing[#missing + 1] = p.name
        if wanted[p.name] then asked[#asked + 1] = p end
      else
        wanted[p.name] = nil
      end
    end
    store():set("pending", wanted)
    if #missing == 0 then return end
    local auto = ranma.get("hako.install_missing")
    local list = auto and missing or {}
    if not auto then
      for _, p in ipairs(asked) do list[#list + 1] = p.name end
    end
    if #list > 0 then
      local n = #list
      require("hako.screen").open({ reason = "opened to install " .. n .. (n == 1 and " plugin" or " plugins") })
      run("install", (function()
        local ps = {}
        for _, name in ipairs(list) do ps[#ps + 1] = state.by_name[name] end
        return ps
      end)(), function(p)
        local ok, res = install_one(p)
        if ok then set_pending(p.name, nil) end
        return ok, res
      end)
      return
    end
    -- Declared and not installed, and nobody asked: say so, once for each
    -- new set of names, and let them pick.
    table.sort(missing)
    local key = table.concat(missing, ",")
    if store():get("told_missing") == key then return end
    store():set("told_missing", key)
    local open = require("hako.screen").key_name()
    ranma.toast(#missing .. (#missing == 1 and " plugin is" or " plugins are") .. " declared, not installed: "
      .. (open or "hako") .. " shows them; i installs one, I all.")
  end)
  local function due()
    if not ranma.get("hako.check") then return end
    local hours = ranma.get("hako.check_hours") or 6
    local last = store():get("checked_at") or 0
    if os.time() - last >= hours * 3600 then M.check(nil, true) end
  end
  -- Not at once: the first minute after a start is for the user.
  ranma.defer(60 * 1000, due)
  ranma.every(30 * 60 * 1000, due)
end

return M
