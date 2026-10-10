-- Small helpers: paths, files and messages that are safe while ranma loads.
local M = {}

M.HOME = os.getenv("HOME") or ""

function M.data_dir()
  return (os.getenv("XDG_DATA_HOME") or (M.HOME .. "/.local/share")) .. "/ranma/hako"
end

function M.expand(path)
  if path == "~" then return M.HOME end
  if path:sub(1, 2) == "~/" then return M.HOME .. path:sub(2) end
  return path
end

-- Home spelled `~`, for messages.
function M.tilde(path)
  if M.HOME ~= "" and path:sub(1, #M.HOME + 1) == M.HOME .. "/" then
    return "~" .. path:sub(#M.HOME + 1)
  end
  return path
end

function M.quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

function M.exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

function M.is_dir(path)
  local f = io.open(path, "r")
  if not f then return false end
  local ok, _, code = f:read(0)
  f:close()
  -- Reading a directory fails with EISDIR (21).
  return ok == nil and code == 21
end

function M.read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

-- Written beside, then renamed over: a crash leaves the old file or the new.
function M.write(path, text)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "w")
  if not f then return nil, err end
  f:write(text)
  f:close()
  return os.rename(tmp, path)
end

-- The names in a directory, sorted; none if it does not exist.
function M.ls(dir)
  local out = {}
  local p = io.popen("ls -1A " .. M.quote(dir) .. " 2>/dev/null")
  if not p then return out end
  for name in p:lines() do out[#out + 1] = name end
  p:close()
  table.sort(out)
  return out
end

-- Messages and actions only work at run time; while ranma loads they wait
-- for the first tick.
function M.later(fn)
  ranma.defer(0, fn)
end

function M.toast(text, urgent)
  M.later(function() ranma.toast(text, { urgent = urgent or false, timeout = urgent and 15 or nil }) end)
end

-- A deep copy of `b` merged over `a`: tables merge, anything else replaces.
function M.merge(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return b end
  local out = {}
  for k, v in pairs(a) do out[k] = v end
  for k, v in pairs(b) do out[k] = M.merge(out[k], v) end
  return out
end

-- A checkout's commit and branch, read from .git without running git: the
-- list is drawn inside a callback, which must not wait on processes.
function M.git_head(path)
  local gitdir = path .. "/.git"
  if not M.is_dir(gitdir) then
    local d = (M.read(gitdir) or ""):match("gitdir:%s*(%S+)")
    if not d then return nil end
    gitdir = d:sub(1, 1) == "/" and d or (path .. "/" .. d)
  end
  local head = M.read(gitdir .. "/HEAD")
  if not head then return nil end
  local ref = head:match("^ref:%s*(%S+)")
  if not ref then return (head:gsub("%s+$", "")), nil end
  local commit = M.read(gitdir .. "/" .. ref)
  if not commit then
    local packed = M.read(gitdir .. "/packed-refs") or ""
    commit = packed:match("(%x+) " .. (ref:gsub("%p", "%%%0")) .. "\n")
  end
  return commit and (commit:gsub("%s+$", "")), ref:match("^refs/heads/(.+)$")
end

function M.first_line(text)
  return ((text or ""):match("[^\n]*") or ""):gsub("%s+$", "")
end

return M
