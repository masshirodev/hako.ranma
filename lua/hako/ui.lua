-- What hako shows: the `hako` palette command, a list of plugins, a bar
-- module. The list is a picker until the screen from the design handoff
-- (ranma's doc/briefs/PLUGIN_MANAGER.md) replaces it.
local util = require("hako.util")
local state = require("hako.state")
local ops = require("hako.ops")

local M = {}

-- One line on a plugin's state, most important first.
function M.describe(p)
  local task = state.tasks[p.name]
  if task then return task .. " …" end
  if not p.wanted then return "disabled" end
  if not p.installed then return p.managed and "not installed (hako install)" or ("no directory at " .. util.tilde(p.path)) end
  local failure = ops.failures()[p.name]
  if failure then return "failed: " .. util.first_line(failure) end
  if #p.errors > 0 then return "error: " .. util.first_line(p.errors[1]) end
  local parts = {}
  local commit, branch = util.git_head(p.path)
  if commit then parts[#parts + 1] = commit:sub(1, 7) end
  if p.tag then parts[#parts + 1] = "tag " .. p.tag elseif branch then parts[#parts + 1] = branch end
  if not p.managed then parts[#parts + 1] = "local" end
  if p.pin or p.commit then parts[#parts + 1] = "pinned" end
  local up = ops.updates()[p.name]
  if up and up.n > 0 then parts[#parts + 1] = "↑" .. up.n end
  local locked = state.lock[p.name]
  if p.managed and locked and commit and locked.commit ~= commit then parts[#parts + 1] = "off the lock" end
  if not p.on then
    parts[#parts + 1] = "not loaded (cond)"
  elseif p.ms then
    parts[#parts + 1] = string.format("%.1f ms", p.ms)
  end
  return table.concat(parts, " · ")
end

-- Packages cloned by hand under pack/*/start/: ranma loads them; hako only
-- says they are there.
local function unmanaged()
  local out = {}
  local base = ranma.config_dir and (ranma.config_dir .. "/pack")
  if not base then return out end
  for _, pack in ipairs(util.ls(base)) do
    for _, name in ipairs(util.ls(base .. "/" .. pack .. "/start")) do
      out[#out + 1] = { name = name, where = "pack/" .. pack .. "/start" }
    end
  end
  return out
end

local function exec_in(dir)
  ranma.action("exec cd " .. util.quote(dir) .. " && exec \"${SHELL:-sh}\"")
end

local function show_log(p)
  local up = ops.updates()[p.name]
  local function pick(lines, title)
    if #lines == 0 then return ranma.toast("hako: " .. p.name .. ": no commits to show") end
    local items = {}
    for _, l in ipairs(lines) do
      local hash, subject = l:match("^(%S+)%s+(.*)$")
      items[#items + 1] = { label = subject or l, detail = hash, hash = hash }
    end
    ranma.picker {
      title = title, items = items,
      on_select = function(item)
        if item.hash then ranma.copy(item.hash); ranma.toast("copied " .. item.hash) end
      end,
    }
  end
  if up and up.log and #up.log > 0 then return pick(up.log, p.name .. ": " .. up.n .. " new") end
  ranma.spawn({ "git", "-C", p.path, "log", "--format=%h %s", "-n", "20" }, {
    timeout = 10,
    on_exit = function(r)
      local lines = {}
      for line in (r.stdout or ""):gmatch("[^\n]+") do lines[#lines + 1] = line end
      pick(lines, p.name .. ": latest")
    end,
  })
end

local function actions(p)
  local items = {}
  local function add(label, detail, fn) items[#items + 1] = { label = label, detail = detail, fn = fn } end
  if p.managed and p.installed then
    local up = ops.updates()[p.name]
    add("update", up and (up.n .. " new commits") or nil, function() ops.update(p.name) end)
    add("check for updates", nil, function() ops.check(p.name) end)
    add("restore to the lockfile", state.lock[p.name] and state.lock[p.name].commit:sub(1, 7) or "not locked",
      function() ops.restore(p.name) end)
  elseif p.managed then
    add("install", p.url, function() ops.install() end)
  end
  if p.installed then
    add("log", nil, function() show_log(p) end)
    add("open its folder", util.tilde(p.path), function() exec_in(p.path) end)
  end
  if p.url then add("copy its URL", p.url, function() ranma.copy(p.url); ranma.toast("copied " .. p.url) end) end
  add("remove", table.concat(p.sources, ", "), function() ops.remove(p.name) end)
  ranma.picker {
    title = p.name .. ": " .. M.describe(p),
    items = items,
    on_select = function(item) item.fn() end,
  }
end

-- Every plugin and what can be done to all of them.
function M.open()
  local items = {}
  for _, e in ipairs(state.spec_errors) do
    items[#items + 1] = { label = "✗ " .. e.spec, detail = e.error .. " (" .. util.tilde(e.source) .. ")" }
  end
  for _, p in ipairs(state.plugins) do
    items[#items + 1] = { label = p.name, detail = M.describe(p), plugin = p.name }
  end
  for _, c in ipairs(ops.cleanable()) do
    items[#items + 1] = { label = c.name, detail = "declared nowhere: hako clean deletes it", clean = true }
  end
  for _, u in ipairs(unmanaged()) do
    items[#items + 1] = { label = u.name, detail = u.where .. ": ranma loads it, hako does not manage it" }
  end
  local verbs = {
    { "update all", "fetch, fast-forward, lock", ops.update },
    { "check for updates", "fetch and count, change nothing", function() ops.check() end },
    { "sync", "install, clean, update", ops.sync },
    { "install missing", nil, function() ops.install() end },
    { "clean", "delete what no spec declares", function() ops.clean() end },
    { "restore all", "back to " .. util.tilde(state.lockfile), function() ops.restore() end },
    { "add a plugin", "owner/repo, written to a file of its own", function()
      ranma.input { title = "hako add (owner/repo or URL)", on_submit = ops.add }
    end },
  }
  for _, v in ipairs(verbs) do
    items[#items + 1] = { label = ": " .. v[1], detail = v[2], fn = v[3] }
  end
  ranma.picker {
    title = "hako: " .. #state.plugins .. " plugins" .. (state.busy and (", " .. state.busy .. " running") or ""),
    items = items,
    on_select = function(item)
      if item.fn then return item.fn() end
      if item.clean then return ops.clean() end
      local p = item.plugin and state.by_name[item.plugin]
      if p then actions(p) end
    end,
  }
end

local COMMANDS = { "install", "update", "check", "sync", "clean", "restore", "log", "add", "remove", "list" }

local function run(arg)
  local cmd, rest = (arg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  local name = rest ~= "" and rest or nil
  if cmd == "" or cmd == "list" then return M.open() end
  if cmd == "install" then return ops.install() end
  if cmd == "update" then return ops.update(name) end
  if cmd == "check" then return ops.check(name) end
  if cmd == "sync" then return ops.sync() end
  if cmd == "clean" then return ops.clean() end
  if cmd == "restore" then return ops.restore(name) end
  if cmd == "add" then return ops.add(rest) end
  if cmd == "remove" then return ops.remove(name) end
  if cmd == "log" then
    local p = state.by_name[name or ""]
    if not p then return ranma.toast("hako log: which plugin?") end
    return show_log(p)
  end
  ranma.toast("hako: " .. table.concat(COMMANDS, ", "))
end

function M.install()
  ranma.command("hako", run, {
    desc = "plugins: list, install, update, check, sync, clean, restore, add, remove",
    args = "[command] [plugin]",
    complete = function()
      local out = {}
      for _, c in ipairs(COMMANDS) do out[#out + 1] = c end
      for _, p in ipairs(state.plugins) do
        for _, c in ipairs({ "update", "check", "restore", "log", "remove" }) do
          out[#out + 1] = c .. " " .. p.name
        end
      end
      return out
    end,
  })
  -- `hako` in ranma.bar: the number of plugins with updates, when there are.
  ranma.module("hako", {
    render = function()
      local n = 0
      for _, u in pairs(ops.updates()) do
        if u.n and u.n > 0 then n = n + 1 end
      end
      if n == 0 then return nil end
      return { text = "hako ↑" .. n, style = "accent" }
    end,
  })
end

return M
