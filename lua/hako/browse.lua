-- Browse: the plugins of every list the user has on, by what each is to them,
-- then the lists; a view pushed over hako's screen (B). From the design
-- handoff doc/handoffs/PLUGIN_BROWSER.md; doc/SCREEN.md is the account, with
-- where it departs from it.
local util = require("hako.util")
local state = require("hako.state")
local lists = require("hako.lists")

local M = {}

local SECTIONS = { "Not installed", "Available", "Needs a newer ranma", "Installed" }

local query = ""   -- what / holds in Browse
local marked = {}  -- list urls an ask would delete: the `deletes` mark
local fetching = 0 -- lists being fetched in this run, for the status

-- ---------------------------------------------------------------------------
-- What is in Browse. Pure but for reading the lists' copies and the specs.
-- ---------------------------------------------------------------------------

-- The lists the user has, each with its copy (or none): { url, on, added,
-- official, list, status }.
function M.lists()
  local out = {}
  for _, l in ipairs(lists.read_config()) do
    l.official = l.url == lists.OFFICIAL
    l.list = lists.cached(l.url)
    l.status = lists.status(l.url)
    out[#out + 1] = l
  end
  return out
end

local function list_name(l)
  return l.list and l.list.name or (l.official and "ranma plugins") or (l.url:gsub("^%a+://", ""))
end

-- Every plugin of the lists that are on, once each: the first list to name
-- one (the official list comes first) says what it is; `from` is every list
-- that names it.
function M.entries(ls)
  local out, by = {}, {}
  for _, l in ipairs(ls) do
    if l.on and l.list then
      for _, p in ipairs(l.list.plugins) do
        local k = lists.key(p.repo)
        local e = by[k]
        if not e then
          e = util.merge(p, {})
          e.from, e.official = {}, false
          by[k] = e
          out[#out + 1] = e
        end
        e.from[#e.from + 1] = list_name(l)
        e.official = e.official or l.official
      end
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- The declared plugin an entry is, if it is declared.
function M.declared(e)
  local k = lists.key(e.repo)
  for _, p in ipairs(state.plugins) do
    if (p.url and lists.key(p.url) == k) or (not p.url and p.name == e.name) then return p end
  end
  return state.by_name[e.name]
end

-- What an entry is to the user: "inst", "decl", "newer" or "avail".
function M.state_of(e, p)
  if p then return p.installed and "inst" or "decl" end
  if e.ranma and lists.older(ranma.version or "0.0.0", e.ranma) then return "newer" end
  return "avail"
end

-- Words match the name, the description and the author; #tag matches a tag.
-- Every word and every tag has to.
function M.matches(e, q)
  for word in (q or ""):lower():gmatch("%S+") do
    if word:sub(1, 1) == "#" then
      local found = false
      for _, t in ipairs(e.tags) do
        if t:lower() == word:sub(2) then found = true end
      end
      if not found then return false end
    else
      local hay = (e.name .. " " .. e.description .. " " .. e.author):lower()
      if not hay:find(word, 1, true) then return false end
    end
  end
  return true
end

-- The tags of every entry, most used first: what an empty filter suggests.
local function all_tags(es)
  local n = {}
  for _, e in ipairs(es) do
    for _, t in ipairs(e.tags) do n[t] = (n[t] or 0) + 1 end
  end
  local out = {}
  for t in pairs(n) do out[#out + 1] = t end
  table.sort(out, function(a, b) return n[a] ~= n[b] and n[a] > n[b] or a < b end)
  for i, t in ipairs(out) do out[i] = "#" .. t end
  return out
end

-- A list of what is not nil: details and facts with optional parts.
local function C(...)
  local t = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if v ~= nil then t[#t + 1] = v end
  end
  return t
end

local function joined(names)
  if #names == 2 then return names[1] .. " and " .. names[2] end
  return table.concat(names, ", ")
end

-- ---------------------------------------------------------------------------
-- Rows.
-- ---------------------------------------------------------------------------

local function value_of(name, plain)
  local t = state.tasks[name]
  if t then
    if t.frac then return { meter = math.max(0, math.min(1, t.frac)), text = t.task } end
    local s = os.time() - t.since
    return { text = t.task, time = string.format("%d:%02d", s // 60, s % 60) }
  end
  local r = state.results[name]
  if r then return { r[1], r[2] } end
  return plain
end

-- What a plugin says, then where it came from and what it needs; `lead` (a
-- state the row is in) comes first, and the description gives up a line.
local function plugin_detail(e, lead)
  local d = {}
  if lead then d[#d + 1] = lead end
  d[#d + 1] = { "text", e.description, max = lead and 1 or 2 }
  local from = { "facts", { "from", joined(e.from) } }
  if not e.official then from[#from + 1] = { "", "nobody reviews it", role = "accent" } end
  d[#d + 1] = from
  -- What it needs: programs, and a ranma at least so new when it says so.
  local newer = e.ranma and lists.older(ranma.version or "0.0.0", e.ranma)
  local role, strong = newer and "accent" or nil, newer or nil
  if #e.needs > 0 then
    d[#d + 1] = C("facts", { "needs", table.concat(e.needs, ", ") },
      e.ranma and { "ranma", e.ranma .. " or newer", role = role, strong = strong } or nil)
  elseif e.ranma then
    d[#d + 1] = { "facts", { "needs", "ranma " .. e.ranma .. " or newer", role = role, strong = strong } }
  end
  d[#d + 1] = { "facts", { "", e.repo }, { "by", e.author } }
  if #e.tags > 0 then d[#d + 1] = { "facts", { "tags", table.concat(e.tags, ", ") } } end
  return d
end

local function plugin_row(ctx, e)
  local p = M.declared(e)
  local st = M.state_of(e, p)
  local row = { "row", id = e.name, name = e.name, note = e.description }
  if not e.official then row.mark = { "unreviewed", "accent" } end
  local install = { "i", "install", ctx.on(e.name, function() ctx.install(e, p) end) }
  local section
  if st == "avail" then
    section = "Available"
    row.keys = { install }
    row.detail = plugin_detail(e)
  elseif st == "decl" then
    section = "Not installed"
    row.value = { "○ missing", "normal" }
    row.keys = { install }
    local where = ctx.where(p)
    row.detail = plugin_detail(e, { "text", "Declared" .. (where and (" in " .. where) or "")
      .. ", not cloned: i installs it.", max = 1 })
  elseif st == "inst" then
    section = "Installed"
    row.value = { "● installed", "dim" }
    row.keys = { { "B", "installed view", ctx.on(e.name, function() ctx.back(e.name) end) } }
    local where = ctx.where(p)
    row.detail = plugin_detail(e, { "text", "Installed" .. (where and (", from " .. where) or "") .. ".", role = "dim", max = 1 })
  else
    section = "Needs a newer ranma"
    row.value = { "needs " .. e.ranma, "dim" }
    row.keys = {}
    row.detail = plugin_detail(e, { "text", "Needs ranma " .. e.ranma .. "; this one is " .. (ranma.version or "?") .. ".", role = "accent", max = 1 })
  end
  -- Installing: the clone runs on its row, as in the installed view.
  local t = p and state.tasks[p.name]
  if p and (t or state.results[p.name]) then
    row.value = value_of(p.name, row.value)
    if t then
      row.mark = { "new", "accent" }
      row.keys = { { "enter", "open", ctx.on(e.name, function() ctx.open_dir(p.path) end) } }
      local src = (p.url or e.repo):gsub("^%a+://", ""):gsub("%.git$", "")
      row.detail = C(
        { "log", lines = t.tail },
        #e.needs > 0 and { "facts", { "needs", table.concat(e.needs, ", ") } } or nil,
        { "facts", { "", src } },
        ctx.where(p) and { "facts", { "from", ctx.where(p) } } or nil
      )
    end
  end
  return section, row
end

local function ago(t)
  return t and (util.age(t) .. " ago") or "never"
end

local function list_row(ctx, l)
  local name = list_name(l)
  local id = "list:" .. l.url
  local row = { "row", id = id, name = name, note = (l.url:gsub("^https://", "")) }
  if l.official then row.mark = { "official", "dim" } end
  if marked[l.url] then row.mark = { "deletes", "urgent" } end
  local turn = { "t", l.on and "turn off" or "turn on", ctx.on(id, function() ctx.toggle(l) end) }
  row.keys = l.official and { turn } or { turn, { "x", "remove", ctx.on(id, function() ctx.ask_remove(l) end) } }
  local url = { "facts", { "", l.url } }
  local who = l.official
    and { "text", "The official list: reviewed before a plugin goes on it. t turns it off; it can't be removed.", role = "dim", max = 2 }
    or { "text", "Nobody reviews this list: read a plugin's code before you install it.", role = "accent", max = 2 }
  local s = l.status
  local n = l.list and #l.list.plugins
  if s.since then
    local secs = os.time() - s.since
    row.value = { text = "fetch", time = string.format("%d:%02d", secs // 60, secs % 60) }
    row.keys = {}
    row.detail = {
      { "log", lines = { { { "$ curl -fsSL --max-time 10", "strong" } }, "  " .. l.url:gsub("^https://", "") } },
      { "facts", { "", l.list and "fetching again" or "first fetch" }, { "then", "every " .. (ranma.get("hako.check_hours") or 6) .. " hours" } },
    }
  elseif not l.on then
    row.value = { "– off", "dim" }
    row.detail = {
      { "text", "Off: its plugins are not in Browse. t turns it on again.", max = 2 },
      { "facts", { "", n and (n .. " plugins") or "no copy" }, { "fetched", ago(l.list and l.list.fetched_at) } },
      url,
    }
  elseif s.error and l.list then
    row.value = { "✗ " .. util.age(l.list.fetched_at) .. " old", "accent" }
    row.detail = {
      { "log", lines = { { { s.error, "strong" } } } },
      { "text", "Showing its copy from " .. ago(l.list.fetched_at) .. " (" .. n .. " plugins). C tries again.", max = 2 },
      { "facts", { "tried", ago(s.tried_at) }, { "fetched", ago(l.list.fetched_at) } },
      url,
    }
  elseif s.error or not l.list then
    row.value = { s.error and "✗ no copy" or "not fetched", s.error and "urgent" or "dim" }
    row.detail = C(
      s.error and { "log", lines = { { { s.error, "strong" } } } } or nil,
      { "text", "Never fetched, so none of its plugins show. C tries again"
        .. (l.official and "." or "; x removes it."), max = 2 },
      C("facts", { "tried", ago(s.tried_at) }, l.added and { "added", ago(l.added) } or nil),
      url
    )
  else
    row.value = { n .. " plugins", "dim" }
    row.detail = {
      who,
      C("facts", { "", n .. " plugins" }, { "fetched", ago(l.list.fetched_at) }, l.added and { "added", ago(l.added) } or nil),
      url,
    }
  end
  return row
end

-- A list needs the user when it failed, or is fetched for the first time.
local function needs_you(l)
  return (l.status.since and not l.list) or (l.status.error ~= nil and l.on)
end

-- The body, the count and the status, for `ctx` (the screen's helpers).
function M.view(ctx)
  local ls = M.lists()
  local es = M.entries(ls)
  local by, shown = {}, 0
  for _, e in ipairs(es) do
    if M.matches(e, query) then
      local section, row = plugin_row(ctx, e)
      by[section] = by[section] or {}
      table.insert(by[section], row)
      shown = shown + 1
    end
  end
  local plugins = {}
  for _, s in ipairs(SECTIONS) do
    if by[s] then
      plugins[#plugins + 1] = { "heading", s, count = #by[s] }
      for _, r in ipairs(by[s]) do plugins[#plugins + 1] = r end
    end
  end
  local list_rows, first = { { "heading", "Lists", count = #ls } }, false
  for _, l in ipairs(ls) do
    list_rows[#list_rows + 1] = list_row(ctx, l)
    first = first or needs_you(l)
  end

  local b = {}
  local filtering = query:match("%S") ~= nil
  if filtering then
    -- The lists go while a filter stands; the sections stay.
    b = plugins
    if shown == 0 then
      b = {
        { "text", "No plugin matches " .. query .. ".", strong = true },
        { "space" },
        { "text", "Words match names, descriptions and authors; #tag matches a tag:", role = "dim", max = 2 },
        { "text", table.concat(all_tags(es), " "), role = "accent", max = 3 },
      }
    end
  else
    local any_on, any_copy = false, false
    for _, l in ipairs(ls) do
      any_on = any_on or l.on
      any_copy = any_copy or (l.on and l.list ~= nil)
    end
    if first then
      for _, r in ipairs(list_rows) do b[#b + 1] = r end
      for _, r in ipairs(plugins) do b[#b + 1] = r end
    else
      for _, r in ipairs(plugins) do b[#b + 1] = r end
      for _, r in ipairs(list_rows) do b[#b + 1] = r end
    end
    if not any_on then
      b[#b + 1] = { "space" }
      b[#b + 1] = { "text", "Every list is off: nothing to browse. t turns one on.", role = "dim", max = 2 }
    elseif not any_copy and fetching > 0 then
      b[#b + 1] = { "space" }
      b[#b + 1] = { "text", "Fetching the official list. Its plugins show here as soon as it lands.", role = "dim", max = 2 }
    end
  end

  local count
  local copies = 0
  for _, l in ipairs(ls) do if l.list then copies = copies + 1 end end
  if copies == 0 then
    count = "browse"
  elseif filtering then
    count = "browse · " .. shown .. " of " .. #es
  else
    count = "browse · " .. #es .. (#es == 1 and " plugin" or " plugins")
  end

  local status
  local failed = 0
  for _, l in ipairs(ls) do if l.on and l.status.error then failed = failed + 1 end end
  if fetching > 0 then
    local done = 0
    for _, l in ipairs(ls) do if l.status.tried_at and not l.status.since then done = done + 1 end end
    status = { "fetching " .. math.min(done, fetching) .. "/" .. fetching, "accent" }
  elseif failed > 0 then
    status = { failed .. (failed == 1 and " list failed" or " lists failed"), "urgent" }
  end
  return b, count, status
end

-- ---------------------------------------------------------------------------
-- What the screen asks of this module.
-- ---------------------------------------------------------------------------

function M.query(q)
  query = q or ""
end

function M.mark(url, on)
  marked[url] = on or nil
end

function M.unmark()
  marked = {}
end

-- Fetch the lists that are on and due (or all of them, `all`).
function M.fetch(all, changed)
  local urls = {}
  for _, l in ipairs(lists.read_config()) do
    if l.on and (all or lists.due(l.url)) then urls[#urls + 1] = l.url end
  end
  if #urls == 0 then return false end
  fetching = #urls
  lists.fetch(urls, changed, function()
    fetching = 0
    changed()
  end)
  return true
end

-- How many plugins Browse holds that are not declared, and from how many
-- lists: the installed view's last line.
function M.more()
  local ls = M.lists()
  local n, from = 0, 0
  for _, l in ipairs(ls) do if l.on and l.list then from = from + 1 end end
  for _, e in ipairs(M.entries(ls)) do
    if not M.declared(e) then n = n + 1 end
  end
  return n, from
end

return M
