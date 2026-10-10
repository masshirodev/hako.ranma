-- Background work as plain sequential Lua: a task is a coroutine, and
-- task.run(argv) yields until ranma.spawn's process exits. Nothing blocks
-- ranma; each resume is a callback well inside its 200 ms.
local M = {}

local function trim(s)
  return (s:gsub("%s+$", ""))
end

-- Run `fn` as a task; `done(ok, msg)` with what it returned, or false and
-- its error.
function M.start(fn, done)
  local co = coroutine.create(fn)
  local step
  step = function(...)
    local r = table.pack(coroutine.resume(co, ...))
    if not r[1] then return done(false, tostring(r[2])) end
    if coroutine.status(co) == "dead" then return done(r[2], r[3]) end
    local req = r[2]
    local ok, err = pcall(ranma.spawn, req.argv, {
      cwd = req.cwd,
      timeout = req.timeout or 120,
      on_exit = function(x)
        step(not x.error and x.code == 0, trim(x.stdout or ""), trim((x.error or "") .. (x.stderr or "")))
      end,
    })
    if not ok then step(false, "", tostring(err)) end
  end
  step()
end

-- Inside a task: run a process; returns ok, stdout, stderr (trimmed).
function M.run(argv, cwd, timeout)
  return coroutine.yield({ argv = argv, cwd = cwd, timeout = timeout })
end

-- Run `worker(item)` as a task for each item, `limit` at a time;
-- `each(item, ok, msg)` as each ends, `all()` once they all have.
function M.pool(items, limit, worker, each, all)
  local n, started, finished, running = #items, 0, 0, 0
  if n == 0 then return all() end
  local fill
  fill = function()
    while running < limit and started < n do
      started = started + 1
      running = running + 1
      local item = items[started]
      M.start(function() return worker(item) end, function(ok, msg)
        running = running - 1
        finished = finished + 1
        each(item, ok, msg)
        if finished == n then all() else fill() end
      end)
    end
  end
  fill()
end

return M
