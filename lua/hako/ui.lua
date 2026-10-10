-- How hako is reached: the `hako` palette command, a key, and a bar module.
-- What it shows is hako.screen.
local state = require("hako.state")
local ops = require("hako.ops")
local screen = require("hako.screen")

local M = {}

local COMMANDS = { "install", "update", "check", "sync", "clean", "restore", "log", "add", "remove" }

local function run(arg)
  local cmd, rest = (arg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  local name = rest ~= "" and rest or nil
  if cmd == "" then return screen.open() end
  if cmd == "install" then return ops.install(name) end
  if cmd == "update" then return ops.update(name) end
  if cmd == "check" then return ops.check(name) end
  if cmd == "restore" then return ops.restore(name) end
  if cmd == "sync" then return screen.sync() end
  if cmd == "clean" then return screen.clean() end
  if cmd == "log" then return screen.log() end
  if cmd == "remove" then return screen.remove(name) end
  if cmd == "add" then
    local added, err = ops.add(rest)
    if not added then return ranma.toast("hako add: " .. err, { urgent = true }) end
    return ranma.notify("hako: added " .. added .. "; ranma reloads and installs it")
  end
  ranma.toast("hako: " .. table.concat(COMMANDS, ", "))
end

-- While ranma loads: the command, the key (opts.key, "shift+l" unless false),
-- and the module.
function M.install(opts)
  ranma.command("hako", run, {
    desc = "plugins: the list, or install, update, check, sync, clean, restore, log, add, remove",
    args = "[command] [plugin]",
    complete = function()
      local out = {}
      for _, c in ipairs(COMMANDS) do out[#out + 1] = c end
      for _, p in ipairs(state.plugins) do
        for _, c in ipairs({ "update", "check", "restore", "remove" }) do
          out[#out + 1] = c .. " " .. p.name
        end
      end
      return out
    end,
  })
  local key = opts.key
  if key == nil then key = "shift+l" end
  if key then
    state.key = key
    ranma.bind(key, function() screen.open() end, { desc = "plugins", exit = true })
  end
  -- `hako` in ranma.bar: a run going, failures, updates; nothing otherwise.
  ranma.module("hako", {
    interval = 1,
    render = screen.module,
    on_click = function() screen.open() end,
  })
end

return M
