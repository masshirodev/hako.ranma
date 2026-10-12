-- hako's screen, from ranma's doc/handoffs/PLUGIN_MANAGER.md (card c196):
-- every plugin in sections by what needs you, its state as a value that
-- reads without colour, the detail of the selected one, and every operation
-- on a key. doc/SCREEN.md is the account, with where it departs from the
-- handoff.
local util = require("hako.util")
local state = require("hako.state")
local ops = require("hako.ops")
local spec = require("hako.spec")
local browse = require("hako.browse")
local lists = require("hako.lists")

local M = {}

local SECTIONS = { "Failed", "Updates", "Not installed", "Installed", "Not in spec", "Not managed" }

local screen       -- the open screen's handle, or nil
local reason       -- why it opened by itself (the subtitle), or nil
local frozen       -- while a run goes: id -> section, so rows hold still
local marked = {}  -- ids an ask would delete: the `deletes` mark
local last_row     -- the row a key last acted on: the selection after a reload
local refresh_due = false
local sizes = {}   -- stray name -> { kb, age }, filled in the background
local view = "installed" -- or "browse", while Browse is pushed over the list
local ask_status   -- a standing ask's status, kept over background redraws
local clears = false -- whether this ranma's s:set takes status = false

-- A status to set: nil means "no status", which s:set reads as "unchanged"
-- unless it is false (a ranma from before that keeps the old one instead).
local function st(v)
  if v ~= nil then return v end
  if clears then return false end
  return nil
end

local function store()
  return state.store
end

-- ---------------------------------------------------------------------------
-- What is on the screen: plugins, spec errors, strays, hand-cloned packages.
-- ---------------------------------------------------------------------------

local function config_dir()
  return ranma.config_dir or (util.HOME .. "/.config/ranma")
end

-- Where a plugin was declared: "init.lua:3", "lua/plugins/compose.lua:1".
local function declared(p)
  local src = p.sources and p.sources[1]
  if not src then return nil end
  local file = src == "init.lua" and (config_dir() .. "/init.lua") or src
  local line = p.src and util.find_line(file, p.src)
  local short = src == "init.lua" and "init.lua" or util.tilde(src):gsub("^" .. util.tilde(config_dir()):gsub("%p", "%%%0") .. "/", "")
  return short .. (line and (":" .. line) or ""), file, line
end

local function note_of(p)
  if p.dir then return util.tilde(p.dir) end
  local d = declared(p)
  return d and (d:gsub("^lua/", "")) or "no spec"
end

local function hand_cloned()
  local out = {}
  local base = config_dir() .. "/pack"
  for _, pack in ipairs(util.ls(base)) do
    for _, name in ipairs(util.ls(base .. "/" .. pack .. "/start")) do
      out[#out + 1] = { name = name, where = "pack/" .. pack .. "/start/" .. name, path = base .. "/" .. pack .. "/start/" .. name }
    end
  end
  return out
end

local function strays()
  local out = {}
  for _, c in ipairs(ops.cleanable()) do
    if not state.by_name[c.name] then out[#out + 1] = c end
  end
  return out
end

-- A stray's size and when it last changed, read in the background once.
local function measure(item)
  if sizes[item.name] then return end
  sizes[item.name] = {}
  ranma.spawn({ "du", "-sk", item.path }, {
    timeout = 10,
    on_exit = function(r)
      sizes[item.name].kb = tonumber((r.stdout or ""):match("^(%d+)"))
      M.changed()
    end,
  })
  ranma.spawn({ "git", "-C", item.path, "log", "-1", "--format=%cr" }, {
    timeout = 10,
    on_exit = function(r)
      sizes[item.name].age = (r.stdout or ""):gsub("%s+$", "")
      M.changed()
    end,
  })
end

local function size_of(name)
  local s = sizes[name] or {}
  return s.kb and util.human_kb(s.kb) or "…", s.age
end

-- The state a plugin is in, as the handoff's table names them.
local function state_of(p)
  local f = ops.failures()[p.name]
  if f then return "failtask" end
  if #p.errors > 0 then return "failload" end
  if not p.wanted then return "disabled" end
  if not p.installed then return p.managed and "missing" or "failload" end
  local up = ops.updates()[p.name]
  if up and up.n > 0 and not (p.pin or p.commit) then return "update" end
  if not p.on then return "disabled" end
  if not p.managed then return "local" end
  if p.pin or p.commit or p.tag then return "pinned" end
  local commit = util.git_head(p.path)
  local locked = state.lock[p.name]
  if locked and commit and locked.commit ~= commit then return "offlock" end
  return "loaded"
end

local SECTION_OF = {
  failtask = "Failed", failload = "Failed", spec = "Failed", update = "Updates",
  missing = "Not installed", stray = "Not in spec", hand = "Not managed",
}

-- ---------------------------------------------------------------------------
-- Details.
-- ---------------------------------------------------------------------------

local function commit_facts(p, extra)
  local items = { "facts" }
  local commit, branch = util.git_head(p.path)
  if p.tag then
    items[#items + 1] = { "tag", p.tag }
  elseif branch then
    items[#items + 1] = { "branch", branch }
  end
  if commit then items[#items + 1] = { "at", commit:sub(1, 7) } end
  for _, e in ipairs(extra or {}) do items[#items + 1] = e end
  if p.ms and p.loaded then items[#items + 1] = { "load", string.format("%.1fms", p.ms) } end
  return items
end

local function from_facts(p)
  local d = declared(p)
  return d and { "facts", { "from", d } } or nil
end

local function push(list, b)
  if b then list[#list + 1] = b end
end

local function url_text(p)
  return (p.url or ""):gsub("^%a+://", ""):gsub("%.git$", "")
end

-- The error's file and line, from a Lua error ("…/init.lua:42: …").
local function error_place(msg)
  local file, line = (msg or ""):match("(/[^:%s]+%.lua):(%d+):")
  return file, tonumber(line)
end

-- An error as the handoff writes it: `plugin/x.lua:42: attempt to …`, the
-- plugin's own path left off, one paragraph, no traceback.
local function short_error(p, msg)
  msg = (msg or ""):gsub("\nstack traceback:.*$", ""):gsub("^runtime error:%s*", "")
  msg = msg:gsub("%s*\n%s*", " ")
  if p and p.path then msg = msg:gsub(p.path:gsub("%p", "%%%0") .. "/", "") end
  return (msg:gsub(util.HOME:gsub("%p", "%%%0"), "~"))
end

local function detail_for(p, st)
  local d = {}
  local t = state.tasks[p.name]
  if t then
    push(d, { "log", lines = t.tail })
    push(d, commit_facts(p))
    push(d, from_facts(p))
    return d
  end
  if st == "update" then
    local up = ops.updates()[p.name]
    local lines = {}
    for _, l in ipairs(up.log or {}) do
      local hash, subject = l:match("^(%S+)%s+(.*)$")
      lines[#lines + 1] = { { (hash or "") .. " ", "num" }, { subject or l } }
    end
    push(d, { "log", lines = lines })
    push(d, commit_facts(p, { { "behind", tostring(up.n), role = "accent", strong = true } }))
    push(d, from_facts(p))
  elseif st == "failload" then
    local err = p.errors[1] or ("no directory at " .. util.tilde(p.path))
    push(d, { "text", short_error(p, err), role = "urgent", max = 2 })
    local file, line = error_place(err)
    if file then
      local rel = file:sub(1, #p.path + 1) == p.path .. "/" and file:sub(#p.path + 2) or util.tilde(file)
      push(d, { "text", "e opens " .. rel .. ":" .. line .. " in a pane.", role = "dim", max = 1 })
    end
    push(d, commit_facts(p, { { "", p.loaded == false and "not loaded" or "loaded", role = "urgent" } }))
    push(d, from_facts(p))
  elseif st == "failtask" then
    local f = ops.failures()[p.name]
    local lines = {}
    if f.cmd then lines[1] = { { "$ " .. f.cmd, "strong" } } end
    for _, l in ipairs(f.tail or {}) do lines[#lines + 1] = l end
    push(d, { "log", lines = lines })
    local facts = { "facts", { f.task or "task", f.code and ("exit " .. f.code) or "failed", role = "urgent", strong = true } }
    local commit = util.git_head(p.path)
    if commit then facts[#facts + 1] = { "at", commit:sub(1, 7) } end
    push(d, facts)
    push(d, from_facts(p))
  elseif st == "missing" then
    push(d, { "text", "Declared, not cloned yet: i installs it, and so does the next sync.", max = 2 })
    push(d, { "facts", { "", url_text(p) } })
    push(d, from_facts(p))
  elseif st == "disabled" then
    if not p.wanted then
      push(d, { "text", p.installed and "enabled = false: not loaded, and clean deletes its clone."
        or "enabled = false: not installed, not loaded.", max = 2 })
    else
      push(d, { "text", "cond = false: installed and updated, not loaded.", max = 2 })
    end
    push(d, commit_facts(p))
    push(d, from_facts(p))
  elseif st == "local" then
    push(d, { "text", "Your checkout: loaded as it is, never fetched, reset or deleted.", max = 2 })
    push(d, { "facts", { "dir", util.tilde(p.path) } })
    push(d, commit_facts(p))
  elseif st == "pinned" then
    local why = p.pin and "pin = true: update and sync skip it."
      or p.commit and ("commit = " .. p.commit:sub(1, 7) .. ": it stays there.")
      or ("tag = " .. p.tag .. ": update follows the tag.")
    push(d, { "text", why, max = 2 })
    push(d, commit_facts(p))
    push(d, from_facts(p))
  elseif st == "offlock" then
    local commit = util.git_head(p.path) or "?"
    push(d, { "text", "At " .. commit:sub(1, 7) .. "; the lock says " .. state.lock[p.name].commit:sub(1, 7)
      .. ". r goes back to it; u updates and locks.", role = "accent", max = 2 })
    push(d, commit_facts(p))
    push(d, from_facts(p))
  else
    local checked = store():get("checked_at")
    push(d, { "text", "Up to date" .. (checked and (" · checked " .. util.age(checked) .. " ago") or ""), role = "dim" })
    push(d, commit_facts(p))
    push(d, from_facts(p))
  end
  return d
end

-- ---------------------------------------------------------------------------
-- Keys.
-- ---------------------------------------------------------------------------

local function editor_at(file, line)
  ranma.action("exec " .. util.editor() .. (line and (" +" .. line) or "") .. " " .. util.quote(file))
end

local function open_dir(path)
  ranma.action("exec cd " .. util.quote(path) .. " && exec \"${SHELL:-sh}\"")
end

-- A key's function, noting the row so a reload can select it again.
local function on(id, fn)
  return function(...)
    last_row = id
    return fn(...)
  end
end

local ask_remove, ask_clean, ask_delete_stray, show_log

local function keys_for(p, st)
  local id = p.name
  local k = {
    u = { "u", "update", on(id, function() ops.update(p.name) end), all = { "U", on(id, function() ops.update() end) } },
    i = { "i", "install", on(id, function() ops.install(p.name) end), all = { "I", on(id, function() ops.install() end) } },
    r = { "r", "restore", on(id, function() ops.restore(p.name) end), all = { "R", on(id, function() ops.restore() end) } },
    x = { "x", "remove", on(id, function() ask_remove(p) end), all = { "X", on(id, function() ask_clean() end) } },
    l = { "l", "log", on(id, function() show_log() end) },
    e = { "e", "edit", on(id, function()
      local file, line = error_place(p.errors[1])
      if not file then file, line = select(2, declared(p)) end
      if file then editor_at(file, line) end
    end) },
    b = { "b", "rebuild", on(id, function() ops.rebuild(p.name) end) },
    enter = { "enter", "open", on(id, function() if p.installed then open_dir(p.path) end end) },
  }
  if state.tasks[p.name] then return { k.enter, k.l } end
  local by = {
    loaded = { k.u, k.l, k.x },
    update = { k.u, k.l, k.x },
    failload = { k.e, k.u, k.l },
    failtask = (function()
      local f = ops.failures()[p.name]
      if f and f.task == "build" then return { k.b, k.u, k.x } end
      if f and f.task == "clone" then return { k.i, k.x } end
      return { k.u, k.enter, k.l }
    end)(),
    missing = { k.i, k.x },
    -- enabled = false is as if undeclared: nothing to update.
    disabled = p.wanted and { k.u, k.x } or { k.x },
    ["local"] = { k.enter, k.x },
    pinned = { k.r, k.l, k.x },
    offlock = { k.r, k.u, k.l },
  }
  return by[st] or by.loaded
end

-- ---------------------------------------------------------------------------
-- Rows.
-- ---------------------------------------------------------------------------

local function value_of(id, plain)
  local t = state.tasks[id]
  if t then
    if t.frac then return { meter = math.max(0, math.min(1, t.frac)), text = t.task } end
    local s = os.time() - t.since
    return { text = t.task, time = string.format("%d:%02d", s // 60, s % 60) }
  end
  local r = state.results[id]
  if r then return { r[1], r[2] } end
  return plain
end

local PLAIN = {
  update = function(p) return { "↑ " .. ops.updates()[p.name].n, "accent" } end,
  failload = function(p) return { p.installed and "✗ load" or "✗ no dir", "urgent" } end,
  failtask = function(p) return { "✗ " .. (ops.failures()[p.name].task or "task"), "urgent" } end,
  missing = function() return { "○ missing", "normal" } end,
  disabled = function() return { "– off", "dim" } end,
}

local function plugin_row(p)
  local st = state_of(p)
  local plain = PLAIN[st] and PLAIN[st](p) or { p.ms and string.format("● %.1fms", p.ms) or "●", "dim" }
  local mark
  if marked[p.name] then
    mark = { "deletes", "urgent" }
  elseif store():get("added") == p.name and not p.installed then
    mark = { "new", "accent" }
  elseif not p.managed then
    mark = { "local", "dim" }
  elseif p.pin or p.commit or p.tag then
    mark = { "pinned", "dim" }
  elseif st == "offlock" then
    mark = { "off lock", "accent" }
  end
  return SECTION_OF[st] or "Installed", {
    "row", id = p.name, name = p.name, mark = mark, note = note_of(p),
    value = value_of(p.name, plain), keys = keys_for(p, st), detail = detail_for(p, st),
    group = p.main,
  }
end

local function spec_row(e, i)
  local id = "spec:" .. i
  local file = e.source == "init.lua" and (config_dir() .. "/init.lua") or e.source
  local line = util.find_line(file, e.spec)
  local where = (e.source == "init.lua" and "init.lua" or util.tilde(e.source)) .. (line and (":" .. line) or "")
  return "Failed", {
    "row", id = id, name = (e.spec:gsub("/+$", ""):match("([^/:]+)$") or e.spec):gsub("%.git$", ""),
    note = where, value = { "✗ spec", "urgent" },
    keys = { { "e", "edit", on(id, function() editor_at(file, line) end) } },
    detail = { { "text", e.error, role = "urgent", max = 2 }, { "facts", { "from", where } } },
  }
end

local function stray_row(item)
  measure(item)
  local size, age = size_of(item.name)
  return "Not in spec", {
    "row", id = item.name, name = item.name, note = "no spec",
    mark = marked[item.name] and { "deletes", "urgent" } or nil,
    value = value_of(item.name, { "◇ " .. size, "dim" }),
    keys = {
      { "x", "delete", on(item.name, function() ask_delete_stray(item) end), all = { "X", on(item.name, function() ask_clean() end) } },
      { "enter", "open", on(item.name, function() open_dir(item.path) end) },
    },
    detail = {
      { "text", "No spec declares it. x deletes this clone, X every stray; both ask first.", max = 2 },
      { "facts", { "dir", util.tilde(item.path) }, { "size", size }, { "changed", age or "…" } },
    },
  }
end

local function hand_row(item)
  local commit = util.git_head(item.path)
  return "Not managed", {
    "row", id = "pack:" .. item.where, name = item.name, note = item.where, value = { "●", "dim" },
    keys = {
      { "enter", "open", on(item.name, function() open_dir(item.path) end) },
    },
    detail = {
      { "text", "Cloned by hand into pack/*/start/: ranma loads it; hako leaves it be.", max = 2 },
      { "facts", commit and { "at", commit:sub(1, 7) } or { "", "not a git checkout" } },
    },
  }
end

-- Everything, as (section, row), in no particular order.
local function rows()
  local out = {}
  for i, e in ipairs(state.spec_errors) do out[#out + 1] = { spec_row(e, i) } end
  for _, p in ipairs(state.plugins) do out[#out + 1] = { plugin_row(p) } end
  for _, s in ipairs(strays()) do out[#out + 1] = { stray_row(s) } end
  for _, h in ipairs(hand_cloned()) do out[#out + 1] = { hand_row(h) } end
  return out
end

-- The body: sections in order of what needs you, rows by name inside one.
-- While a run goes, each row stays in the section it had when it began.
local function body()
  local by = {}
  local n = 0
  for _, sr in ipairs(rows()) do
    local section, row = sr[1], sr[2]
    if frozen and frozen[row.id] then section = frozen[row.id] end
    by[section] = by[section] or {}
    table.insert(by[section], row)
    n = n + 1
  end
  local out = {}
  for _, s in ipairs(SECTIONS) do
    local list = by[s]
    if list and #list > 0 then
      table.sort(list, function(a, b) return a.name < b.name end)
      out[#out + 1] = { "heading", s, count = #list }
      for _, r in ipairs(list) do out[#out + 1] = r end
    end
  end
  return out, n
end

local function status()
  local run = state.run
  if run then
    local word = run.op == "install" and "installing" or run.op
    local t = word .. " " .. run.done .. "/" .. run.total
    if run.failed > 0 then return { t .. " · " .. run.failed .. " failed", "urgent" } end
    return { t, "accent" }
  end
  local failed = #state.spec_errors
  for _, p in ipairs(state.plugins) do
    if ops.failures()[p.name] or #p.errors > 0 then failed = failed + 1 end
  end
  if failed > 0 then return { failed .. " failed", "urgent" } end
  local ups = 0
  for _, u in pairs(ops.updates()) do
    if u.n and u.n > 0 then ups = ups + 1 end
  end
  if ups > 0 then return { ups .. (ups == 1 and " update" or " updates"), "accent" } end
  return nil
end

-- ---------------------------------------------------------------------------
-- The screen.
-- ---------------------------------------------------------------------------

local CARD = {
  { "u U", "update it · all" },
  { "i I", "install it · all missing" },
  { "r R", "restore it · all (the lock)" },
  { "x X", "remove it · clean (asks)" },
  { "C", "check all for updates" },
  { "S", "sync: install, clean, pull" },
  { "a", "add one: owner/repo" },
  { "B", "browse plugins from lists" },
  { "l", "the log of its updates" },
  { "b", "run its build again", "build" },
  { "e", "edit at the error", "load" },
  { "enter", "open its folder in a pane" },
  { "o", "its options in settings" },
}

local browse_ctx

-- The installed view's last line: what Browse has that is not declared.
local function with_more(b)
  local n, from = browse.more()
  b[#b + 1] = { "space" }
  if from == 0 then
    b[#b + 1] = { "text", "B browses plugins from the official list.", role = "dim" }
  elseif n > 0 then
    b[#b + 1] = { "text", "B browses " .. n .. " more, from " .. from .. (from == 1 and " list." or " lists."), role = "dim" }
  end
  return b
end

local function refresh()
  refresh_due = false
  if not screen then return end
  if view == "browse" then
    local b, count, lst = browse.view(browse_ctx)
    -- Browse's status is about lists and installs; a plugin failing to load
    -- is the installed view's to say.
    screen:set { body = b, count = count, status = st(ask_status or (state.run and status()) or lst) }
    return
  end
  local b, n = body()
  screen:set { body = with_more(b), status = st(ask_status or status()), count = n .. (n == 1 and " plugin" or " plugins") }
end

-- Something changed: redraw soon (many changes in a burst redraw once).
function M.changed()
  if not screen or refresh_due then return end
  refresh_due = true
  ranma.defer(150, refresh)
end

function M.is_open()
  return screen ~= nil
end

function M.freeze()
  frozen = {}
  for _, sr in ipairs(rows()) do frozen[sr[2].id] = sr[1] end
end

function M.thaw()
  frozen = nil
  M.changed()
end

-- An ask's own status, then back to the screen's.
local function asking(t, word, role)
  ask_status = { word, role or "urgent" }
  screen:set { status = ask_status }
  t.keys = t.keys or {}
  screen:ask(t)
end

local function done_asking()
  marked = {}
  ask_status = nil
  refresh()
end

local function sync_ask()
  local list = strays()
  if #list == 0 then return ops.sync(false) end
  local lines = {}
  for _, s in ipairs(list) do
    marked[s.name] = true
    local size, age = size_of(s.name)
    lines[#lines + 1] = { { s.name, "strong" }, { "  " .. size .. (age and (" · changed " .. age) or "") } }
  end
  local install, update, skip = 0, 0, 0
  for _, p in ipairs(state.plugins) do
    if p.managed and p.wanted then
      if not p.installed then install = install + 1
      elseif p.pin or p.commit then skip = skip + 1
      else update = update + 1 end
    elseif not p.managed then
      skip = skip + 1
    end
  end
  refresh()
  screen:set { select = list[1].name }
  asking({
    blocks = {
      { "text", "Sync deletes " .. #list .. (#list == 1 and " clone" or " clones") .. " no spec declares:", role = "urgent", strong = true },
      { "log", lines = lines },
      { "text", "Then it installs " .. install .. ", updates " .. update .. " and skips " .. skip .. " (local, pinned).", max = 2 },
      { "space" },
    },
    keys = {
      { "y", "sync", function() done_asking(); ops.sync(true) end, role = "urgent" },
      { "n", "sync, keep it", function() done_asking(); ops.sync(false) end },
      { "esc", "cancel", done_asking },
    },
  }, "sync?")
end

function ask_remove(p)
  local where, file, line = declared(p)
  if p.single and p.sources[1] ~= "init.lua" then
    marked[p.name] = true
    refresh()
    local lines = { { { "deletes ", "num" }, { (where:gsub(":%d+$", "")) } } }
    if p.managed then lines[2] = { { "deletes ", "num" }, { "its clone, " .. util.tilde(p.path) } } end
    return asking({
      blocks = {
        { "text", "Remove " .. p.name .. "?", role = "urgent", strong = true },
        { "log", lines = lines },
        { "text", "ranma reloads without it.", role = "dim" },
      },
      keys = {
        { "y", "remove", function() done_asking(); M.before_reload(); ops.remove(p.name) end, role = "urgent" },
        { "esc", "keep it", done_asking },
      },
    }, "remove?")
  end
  local text = p.name .. " is declared in " .. (where or "your config") .. "."
  asking({
    blocks = {
      { "text", text, strong = true },
      { "text", "hako never rewrites " .. ((where or "it"):gsub(":%d+$", ""))
        .. ": delete that spec, save, and X cleans the clone up.", max = 3 },
      { "space" },
    },
    keys = {
      { "e", "edit " .. (where or "it"), function() done_asking(); if file then editor_at(file, line) end end },
      { "esc", "back", done_asking },
    },
  }, "remove", "normal")
end

function ask_delete_stray(item)
  marked[item.name] = true
  refresh()
  local size, age = size_of(item.name)
  asking({
    blocks = {
      { "text", "Delete " .. item.name .. "?", role = "urgent", strong = true },
      { "log", lines = { { { "deletes ", "num" }, { util.tilde(item.path) } } } },
      { "facts", { "size", size }, { "changed", age or "…" } },
    },
    keys = {
      { "y", "delete it", function() done_asking(); ops.delete({ item }) end, role = "urgent" },
      { "esc", "keep it", done_asking },
    },
  }, "delete?")
end

function ask_clean()
  local list = strays()
  if #list == 0 then return ranma.notify("hako: no clone is undeclared") end
  local lines, total, width = {}, 0, 0
  for _, s in ipairs(list) do width = math.max(width, #s.name) end
  for _, s in ipairs(list) do
    marked[s.name] = true
    local size, age = size_of(s.name)
    total = total + ((sizes[s.name] or {}).kb or 0)
    lines[#lines + 1] = { { s.name .. string.rep(" ", width - #s.name), "strong" },
      { string.format("  %5s  %s", size, age or "") } }
  end
  refresh()
  screen:set { select = list[1].name }
  asking({
    blocks = {
      { "text", "Delete " .. #list .. (#list == 1 and " clone" or " clones") .. " no spec declares?", role = "urgent", strong = true },
      { "log", lines = lines },
      { "facts", { "", util.human_kb(total) .. " in all" } },
    },
    keys = {
      { "y", "delete " .. #list, function() done_asking(); ops.clean() end, role = "urgent" },
      { "esc", "keep them", done_asking },
    },
  }, "clean?")
end

local function ask_add()
  local dir = state.imports[1]
  local rel = dir and (util.tilde(dir):gsub("^" .. util.tilde(config_dir()):gsub("%p", "%%%0") .. "/", "")) or "lua/plugins"
  asking({
    blocks = {
      { "text", "owner/repo, or a git URL.", strong = true },
      { "text", "Writes " .. rel .. "/<name>.lua with its spec; ranma reloads and installs it.", role = "dim", max = 2 },
      { "facts", { "writes", rel .. "/<name>.lua" } },
      { "space" },
    },
    input = { prefix = "+", text = "" },
    keys = {
      { "enter", "add", function(_, text)
        local name, err = ops.add(text)
        if not name then
          refresh()
          return ranma.toast("hako add: " .. err, { urgent = true })
        end
        last_row = name
        M.before_reload()
      end },
      { "esc", "cancel", done_asking },
      { "ctrl+u", "clear" },
    },
  }, "add", "accent")
end

-- `l`: what updates brought in the last 7 days, over the list.
function show_log()
  local week = os.time() - 7 * 86400
  local b, plugins = {}, 0
  for _, e in ipairs(ops.history()) do
    if e.time >= week and #e.commits > 0 then
      plugins = plugins + 1
      b[#b + 1] = { "heading", e.name, tag = (e.from or ""):sub(1, 7) .. " → " .. (e.to or ""):sub(1, 7), count = #e.commits }
      local p = state.by_name[e.name]
      for _, c in ipairs(e.commits) do
        local stat, width = {}, 0
        for _, f in ipairs(c.files) do width = math.max(width, #f.path) end
        for _, f in ipairs(c.files) do
          stat[#stat + 1] = string.format("%-" .. width .. "s  +%s −%s", f.path, f.add, f.del)
        end
        stat[#stat + 1] = #c.files .. (#c.files == 1 and " file changed" or " files changed")
        local age = util.age(c.time)
        b[#b + 1] = {
          "row", id = e.name .. ":" .. c.hash, name = c.subject, note = c.hash, value = { age, "dim" },
          keys = {
            { "enter", "show", function()
              if p then ranma.action("exec git -C " .. util.quote(p.path) .. " show " .. c.hash) end
            end },
            { "y", "copy hash", function() ranma.copy(c.hash); ranma.notify("copied " .. c.hash) end },
          },
          detail = {
            { "log", lines = stat },
            { "facts", { "", c.hash }, { "by", c.author }, { "", age .. " ago" } },
          },
        }
      end
    end
  end
  if #b == 0 then b[1] = { "text", "No updates in the last 7 days.", role = "dim" } end
  screen:push {
    subtitle = "log · the last 7 days",
    count = plugins .. (plugins == 1 and " plugin" or " plugins"),
    body = b,
  }
end

-- ---------------------------------------------------------------------------
-- Browse (B): the lists' plugins, pushed over the list. browse.lua builds it.
-- ---------------------------------------------------------------------------

local BROWSE_CARD = {
  { "i", "install it" },
  { "t", "turn a list off · on", "list" },
  { "x", "remove a list (asks)", "list" },
  { "a", "add a list: its URL" },
  { "C", "fetch every list again" },
  { "B", "the installed view" },
  { "o", "its options in settings" },
}

local ask_add_list, ask_remove_list

browse_ctx = {
  on = on,
  where = function(p) return (declared(p)) end,
  open_dir = function(path) open_dir(path) end,
  install = function(e, p)
    if p then return ops.install(p.name) end
    local name, err = ops.add(e.repo, e.from[1])
    if not name then
      refresh()
      return ranma.toast("hako: " .. err, { urgent = true })
    end
    last_row = e.name
    M.before_reload()
  end,
  back = function(sel)
    screen:pop()
    view = "installed"
    refresh()
    if sel then screen:set { select = sel } end
  end,
  toggle = function(l)
    lists.toggle(l.url)
    if not l.on then browse.fetch(false, M.changed) end
    refresh()
  end,
  ask_remove = function(l) ask_remove_list(l) end,
}

local function fetch_all()
  if not browse.fetch(true, M.changed) then ranma.notify("hako: every list is off") end
  refresh()
end

function ask_add_list()
  asking({
    blocks = {
      { "text", "A list's URL: one JSON file.", strong = true },
      { "text", "enter fetches it and shows what it holds; nothing is added yet.", role = "dim", max = 2 },
      { "facts", { "then writes", util.tilde(state.lists_file):match("[^/]*$") } },
      { "space" },
    },
    input = { prefix = "+", text = "" },
    keys = {
      { "enter", "fetch", function(_, text)
        local url = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if url == "" then return refresh() end
        screen:set { status = { "fetching", "accent" } }
        lists.peek(url, function(list, err, body)
          if not screen then return end
          if not list then
            refresh()
            return ranma.toast("hako: " .. url .. ": " .. tostring(err), { urgent = true })
          end
          local n = #list.plugins
          local add = function()
            done_asking()
            lists.add(url, body)
            last_row = "list:" .. url
            refresh()
            screen:set { select = "list:" .. url }
          end
          -- The official list needs no warning: it is the one somebody reviews.
          if url == lists.OFFICIAL then return add() end
          asking({
            blocks = {
              { "text", "Add the list " .. list.name .. "?", role = "urgent", strong = true },
              { "facts", { "", n .. (n == 1 and " plugin" or " plugins") }, { "", (url:gsub("^https://", "")) } },
              { "text", "Nobody reviews this list. Its plugins are Lua that runs as you: they can read "
                .. "your files and run any program. Add it only if you trust who keeps it.", max = 4 },
            },
            keys = {
              { "y", "add it", add, role = "urgent" },
              { "esc", "cancel", done_asking },
            },
          }, "add list?")
        end)
      end },
      { "esc", "cancel", done_asking },
      { "ctrl+u", "clear" },
    },
  }, "add list", "accent")
end

function ask_remove_list(l)
  local name = l.list and l.list.name or l.url
  local n = l.list and #l.list.plugins
  browse.mark(l.url, true)
  refresh()
  asking({
    blocks = {
      { "text", "Remove " .. name .. "?", role = "urgent", strong = true },
      { "text", (n and ("Its " .. n .. " plugins leave Browse. ") or "")
        .. "What you installed from it stays installed, and updates from its own repository.", max = 3 },
      { "facts", { "edits", util.tilde(state.lists_file):match("[^/]*$") } },
    },
    keys = {
      { "y", "remove", function()
        browse.unmark()
        lists.remove(l.url)
        done_asking()
      end, role = "urgent" },
      { "esc", "keep it", function() browse.unmark(); done_asking() end },
    },
  }, "remove?")
end

-- B: Browse over the list, fetching the lists that are due.
function M.browse(sel)
  if not screen then return M.open({ view = "browse", sel = sel }) end
  view = "browse"
  browse.query("")
  browse.fetch(false, M.changed)
  local b, count, lst = browse.view(browse_ctx)
  local t = {
    count = count, status = (state.run and status()) or lst, body = b, card = BROWSE_CARD,
    keys = {
      { "a", "add list", function() ask_add_list() end },
      { "C", "fetch", function() fetch_all() end },
      { "B", "installed view", function() browse_ctx.back() end },
    },
    filter = "plugin",
    on_query = function(q)
      browse.query(q)
      refresh()
    end,
    on_back = function()
      view = "installed"
      refresh()
    end,
  }
  -- A ranma from before pushed views took a filter of their own filters by
  -- name: Browse still works, matching names only.
  if not pcall(screen.push, screen, t) then
    t.filter, t.on_query, t.on_back = "names", nil, nil
    screen:push(t)
  end
  if sel then screen:set { select = sel } end
end

-- Open the screen, or bring it up to date. opts: reason (the subtitle when
-- it opened by itself), sel (a row to select).
function M.open(opts)
  opts = opts or {}
  if opts.reason then reason = opts.reason end
  if screen then
    if opts.view == "browse" and view ~= "browse" then return M.browse(opts.sel) end
    refresh()
    if opts.sel then screen:set { select = opts.sel } end
    return
  end
  local b, n = body()
  b = with_more(b)
  marked = {}
  view = "installed"
  screen = ranma.screen {
    title = "hako", chip = "HAKO", options = true, group = "hako", detail = 6,
    filter = reason and false or "names",
    subtitle = reason,
    count = n .. (n == 1 and " plugin" or " plugins"),
    status = status(),
    keys = {
      { "S", "sync", function() sync_ask() end },
      { "a", "add", function() ask_add() end },
      { "C", "check", function() ops.check() end },
      { "B", "browse", function() M.browse() end },
    },
    card = CARD,
    body = b,
    empty = "no plugins: declare some in require(\"hako\").setup",
    on_close = function()
      screen, reason, marked, view, ask_status = nil, nil, {}, "installed", nil
      browse.unmark()
    end,
  }
  clears = pcall(screen.set, screen, { status = status() or false })
  if opts.view == "browse" then return M.browse(opts.sel) end
  if opts.sel then screen:set { select = opts.sel } end
end

-- The palette's way into the asks: open the screen, then ask.
function M.sync()
  M.open()
  sync_ask()
end

function M.clean()
  M.open()
  ask_clean()
end

function M.remove(name)
  local p = state.by_name[name or ""]
  if not p then return ranma.toast("hako remove: no plugin `" .. tostring(name) .. "`") end
  M.open({ sel = p.name })
  ask_remove(p)
end

function M.log()
  M.open()
  show_log()
end

-- hako is about to reload ranma (or a save will): the screen closes with the
-- Lua it belongs to, so leave a note to open it again on the same row.
function M.before_reload()
  if screen then store():set("reopen", { sel = last_row, view = view }) end
end

-- After a load: open again if a reload of hako's closed the screen.
function M.after_load()
  local again = store():get("reopen")
  if not again then return end
  store():set("reopen", nil)
  util.later(function() M.open({ sel = again.sel, view = again.view }) end)
end

-- "leader L": the key `setup` bound to open the screen, as the toast names it.
function M.key_name()
  local k = state.key
  if not k then return nil end
  local letter = k:match("^shift%+(%a)$")
  return "leader " .. (letter and letter:upper() or k)
end

-- The bar module: nothing to say takes no room.
function M.module()
  local run = state.run
  local narrow = (ranma.client().cols or 80) < 80
  if run then
    local t = run.done .. "/" .. run.total
    return { text = narrow and ("● " .. t) or ("● " .. run.op .. " " .. t), style = "accent" }
  end
  local failed = #state.spec_errors
  for _, p in ipairs(state.plugins) do
    if ops.failures()[p.name] or #p.errors > 0 then failed = failed + 1 end
  end
  local ups = 0
  for _, u in pairs(ops.updates()) do
    if u.n and u.n > 0 then ups = ups + 1 end
  end
  if failed > 0 then
    local up = ups > 0 and (narrow and (" ↑" .. ups) or (" ↑ " .. ups)) or ""
    return { text = (narrow and ("✗" .. failed) or ("✗ " .. failed .. " failed")) .. up, style = "urgent" }
  end
  if ups > 0 then
    return { text = narrow and ("↑" .. ups) or ("↑ " .. ups .. (ups == 1 and " update" or " updates")), style = "accent" }
  end
  return nil
end

-- The added plugin is no longer new once it is installed.
function M.forget_added()
  local added = store():get("added")
  local p = added and state.by_name[added]
  if p and p.installed then store():set("added", nil) end
end

return M
