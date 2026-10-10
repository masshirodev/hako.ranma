-- The lockfile: { name = { branch, commit } }, written sorted and one plugin
-- per line, so a diff of it reads as what changed.
local util = require("hako.util")

local M = {}

function M.read(path)
  local text = util.read(path)
  if not text then return {} end
  local ok, t = pcall(ranma.json.decode, text)
  return (ok and type(t) == "table") and t or {}
end

function M.write(path, lock)
  local names = {}
  for name in pairs(lock) do names[#names + 1] = name end
  table.sort(names)
  local lines = { "{" }
  for i, name in ipairs(names) do
    local e = lock[name]
    local fields = {}
    for _, k in ipairs({ "branch", "tag", "commit" }) do
      if e[k] then fields[#fields + 1] = ranma.json.encode(k) .. ": " .. ranma.json.encode(e[k]) end
    end
    lines[#lines + 1] = "  " .. ranma.json.encode(name) .. ": { " .. table.concat(fields, ", ") .. " }"
      .. (i < #names and "," or "")
  end
  lines[#lines + 1] = "}"
  return util.write(path, table.concat(lines, "\n") .. "\n")
end

return M
