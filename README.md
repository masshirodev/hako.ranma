# hako

箱, a box: a plugin manager for [ranma](https://github.com/masshirodev/ranma),
the terminal tiling window manager. It is shaped like
[lazy.nvim](https://github.com/folke/lazy.nvim): plugins are declared as specs
in Lua, a lockfile pins each to a commit, and one place shows them all and
installs, updates, cleans and restores them.

It does **not** lazy-load. ranma makes binds only while its configuration
loads, and a ranma plugin loads in about a millisecond, so there is nothing to
put off and nothing to gain. lazy.nvim's `event`, `cmd`, `ft` and `lazy` fields
are refused by name rather than ignored.

Needs a ranma with `ranma.packadd` (2026-10-10 or later) and `git`.

## Install

At the top of `~/.config/ranma/init.lua`:

```lua
local hako = (os.getenv("XDG_DATA_HOME") or (os.getenv("HOME") .. "/.local/share")) .. "/ranma/hako/hako.ranma"
if ranma.packadd(hako) then
  require("hako").setup({
    "masshirodev/hako.ranma",          -- so hako updates itself
    { import = "plugins" },            -- one file per plugin, in lua/plugins/
  })
else
  -- The first start: clone hako, then reload, which installs the rest.
  ranma.defer(0, function()
    ranma.spawn({ "git", "clone", "--filter=blob:none", "https://github.com/masshirodev/hako.ranma", hako }, {
      on_exit = function(r)
        if r.code == 0 then
          ranma.action("reload_config")
        else
          ranma.toast("hako: clone failed: " .. (r.stderr or ""), { urgent = true })
        end
      end,
    })
  end)
end
```

`ranma.packadd` loads hako when it is there and says `false` when it is not,
so the first start clones it in the background and reloads; every start after
that loads it at once. Settings and binds after the `setup` call see the
plugins it loaded.

## Specs

Three ways to declare a plugin, mixed as you like:

```lua
-- 1. In setup's list
require("hako").setup({
  "masshirodev/history.ranma",
  { "masshirodev/compose.ranma", opts = { keep = 30 } },
  { dir = "~/projects/agents.ranma" },
  { import = "plugins" },
})

-- 2. A file of its own: ~/.config/ranma/lua/plugins/compose.lua
return { "masshirodev/compose.ranma", opts = { keep = 30, submit = false } }

-- 3. A plain `git clone` into ~/.config/ranma/pack/*/start/: ranma loads it
--    by itself; hako lists it as not managed and leaves it alone.
```

A plugin declared in two places is one plugin: its fields merge, `opts`
deeply, as lazy.nvim does.

| Field | |
| --- | --- |
| `[1]` | `owner/repo` on GitHub, a URL (`https://`, `file://`, `git@…`), or an absolute path to clone from. |
| `dir` | A checkout of your own, loaded from where it is. hako never clones, fetches or deletes it. |
| `url`, `name` | The source and the directory name, when `[1]` does not say them. |
| `opts` | A table (or a function of the plugin returning one) given to `ranma.set { <main> = opts }` after the plugin loads: a ranma plugin's settings are options in its own group. |
| `main` | That group: by default the name without `.ranma` (`history.ranma` → `history`). |
| `config` | `function(plugin, opts)`, run after it loads, instead of the `ranma.set`. |
| `init` | `function(plugin)`, run before it loads. |
| `keys` | Binds made with it: `{ { "g h", fn_or_action, desc = "…", global = false, exit = true, group = "…" } }`. Made at load, like any bind; nothing waits for them. |
| `dependencies` | Specs (or names) loaded before it. |
| `priority` | Higher loads earlier (default 50), dependencies still first. |
| `enabled` | `false` (or a function returning it): as if not declared. Not installed, not loaded, and `clean` deletes it. |
| `cond` | `false`: installed and updated, not loaded. |
| `branch`, `tag`, `commit` | What to follow. A `tag` or a `commit` pins it. |
| `pin` | `true`: never updated (checks still count what it misses). |
| `build` | A shell command run in its directory, or `function(plugin)`, after install and update. |

Anything else is an error naming the field, the spec and the file it is in;
that spec is dropped and the rest load. A plugin that fails to load is dropped
whole (ranma's own rule for plugins), and hako lists the error.

## Using it

**The screen**: `leader L` (or `hako` in the palette, or a click on the bar
module) opens every plugin in sections by what needs you (Failed, Updates,
Not installed, Installed, Not in spec, Not managed), with every operation on a
key: `u/U` update, `i/I` install, `r/R` restore, `x/X` remove and clean, `C`
check, `S` sync, `a` add, `l` the log, `e` the error's file, `o` the plugin's
options. Nothing is deleted on one key: `x`, `X` and a cleaning `S` ask, and
only `y` answers. `doc/SCREEN.md` is the account.

The palette (leader `:`) has `hako` too:

| | |
| --- | --- |
| `hako` | The screen. |
| `hako install` | Clone what is declared and missing. Runs by itself after a reload that declared something new. |
| `hako update [name]` | Fetch, fast-forward, run `build`, lock where each landed, reload. |
| `hako check [name]` | Fetch and count the new commits, changing nothing. Also every few hours on its own. |
| `hako sync` | Install and update; asks first if it would clean. |
| `hako restore [name]` | Back to the lockfile's commits. |
| `hako clean` | Delete clones no spec declares (asks first). |
| `hako add owner/repo` | Write `lua/plugins/<name>.lua` with the spec; the save reloads ranma, which installs it. |
| `hako remove name` | For a plugin declared in a file of its own: delete the file and the clone (it asks first). Declared anywhere else, it says where. |
| `hako log name` | The commits an update would bring, or the latest ones. |

From Lua (a bind, `ranma lua`): `require("hako").open()`, `.update()`,
`.check()`, `.install()`, `.restore()`, and `.sync()`, `.clean()`, `.log()`
(which open the screen to ask or show).

**The bar.** A module named `hako`, placed like any other
(`ranma.bar { right = { "hako", "clock" } }`), says nothing when there is
nothing to say, `↑ 3 updates` after a check finds some, `✗ 1 failed ↑ 3` when a
plugin failed, and `● sync 7/10` while a run goes with the screen closed; on a
narrow terminal `↑3`. A click opens the screen.

**The toast.** Once per check that finds new commits: `3 plugins have
updates: history, compose and marks. leader L shows them; checked 16:30`.

## Settings

`setup(specs, opts)`:

| | |
| --- | --- |
| `root` | Where clones go. Default `$XDG_DATA_HOME/ranma/hako`. |
| `lockfile` | Default `<config dir>/hako-lock.json`. Point it into your dotfiles to make another machine the same: `lockfile = "~/.config/myconf/ranma/hako-lock.json"`. |
| `key` | The WM-mode key that opens the screen. Default `"shift+l"` (`leader L`); `false` binds nothing. |

The rest are ranma options, in the settings panel under `hako`:
`hako.install_missing`, `hako.check`, `hako.check_hours` (6),
`hako.notify`, `hako.concurrency` (4).

## The lockfile

```json
{
  "compose.ranma": { "branch": "main", "commit": "4f1c2a9…" },
  "history.ranma": { "branch": "main", "commit": "b03e77d…" }
}
```

Sorted, one plugin a line, so its diff reads as what changed. A fresh install
checks out the locked commit; `update` moves it; `restore` goes back to it.

## Tests

`tests/e2e.sh` runs a private, headless ranma (its own sockets, state and
config, in a tmux server of its own) against plugins cloned from local
repositories: install, opts, dependencies, enabled, a failing plugin, a
refused field, check, update, restore, clean and add, then the screen through
tmux keys: sections and states, the bar module, the add ask, a sync that asks
before deleting and takes only `y`, and the log with `esc` back.
`SHOW=1 tests/e2e.sh` prints the screen as it is drawn.

## License

MIT or Apache-2.0, as ranma.
