# The screen

`lua/hako/screen.lua` is hako's screen, built from ranma's design handoff
`doc/handoffs/PLUGIN_MANAGER.md` (in
[masshirodev/ranma](https://github.com/masshirodev/ranma), with
`PLUGIN_MANAGER_MOCK.txt`, cell for cell, and the script that draws it). The
handoff calls the manager `lazy`; it was renamed hako before it was built, and
nothing else about the design changed with the name.

ranma draws the screen (`ranma.screen`); hako only describes it. The five
things the handoff needed that a plugin could not draw (a meter value, an ask
with or without a typed line, paired keys, one step back) went into ranma for
every plugin, and ranma's tests compare them with the mock.

Open it with `leader L` (the `key` given to `setup`; `false` binds nothing),
`hako` in the palette, or a click on the `hako` bar module.

## Sections

In order of what needs you; empty ones are left out, and `tab` jumps between
them. Rows are sorted by name inside one.

| Section | What is in it |
| --- | --- |
| Failed | a plugin that failed to load (`✗ load`), a task that failed (`✗ clone`, `✗ pull`, `✗ build`, `✗ fetch`), a spec hako refused (`✗ spec`) |
| Updates | installed plugins behind their branch or tag (`↑ 3`) |
| Not installed | declared, not cloned (`○ missing`) |
| Installed | loaded (`● 0.6ms`), local (`local`), pinned (`pinned`), off the lock (`off lock`), switched off (`– off`) |
| Not in spec | clones under hako's root that nothing declares (`◇ 220K`) |
| Not managed | packages cloned by hand into `pack/*/start/` (`●`) |

**Rows hold still while a run goes.** Each row keeps the section it had when
the run began; its value turns into a meter (`clone ━━━●───`), a task and a
time (`build 0:04`), then the outcome (`✓ +3`, `✓ same`, `– skipped`, `✗ pull`).
They move to their new sections when the run ends.

The status (top right) is the worst thing on the screen: `2 failed`, else
`3 updates`; during a run `sync 7/10`, which turns `sync 7/10 · 1 failed` the
moment something fails.

## Keys

| Key | Does | On |
| --- | --- | --- |
| `u` / `U` | update it / all: fetch, fast-forward, build, lock | loaded, updates, failed, off |
| `i` / `I` | install it / all that are missing | not installed, a failed clone |
| `r` / `R` | restore it / all to the lockfile | pinned, off the lock |
| `x` / `X` | remove it / clean every stray (both ask) | most rows |
| `C` | check every plugin for updates | the screen |
| `S` | sync: install and update (asks first if it would delete) | the screen |
| `a` | add: type `owner/repo` or a URL | the screen |
| `l` | the log of what updates brought | most rows |
| `b` | run its build again | a failed build |
| `e` | the file at the error's line, in a pane | a failed load, a refused spec |
| `enter` | its directory in a new pane | local, not managed, working, strays |
| `o` | the selected plugin's options in settings | every plugin row |

**Nothing is deleted on one key.** `x`, `X`, and an `S` that would clean put an
ask on the screen: the detail area says exactly what goes, the rows that would
go are marked `deletes`, and only `y` answers (`esc` keeps everything). A
plugin declared in a file of its own (`lua/plugins/x.lua`) is removed with
that file; one declared in `init.lua` gets an explanation instead, since hako
never rewrites `init.lua`, and `e` opens it at the line.

## Where it departs from the handoff

- **Line numbers** (`init.lua:3`): Lua in ranma has no `debug` library, so a
  spec cannot say where it was written. hako finds the line by searching the
  file for the spec's text (`"masshirodev/history.ranma"`), and shows no number
  when it is not there (a spec built in a loop).
- **`enabled = false`** is lazy.nvim's meaning here: as if not declared, so it
  is not installed, not loaded, and `clean` deletes its clone. The handoff
  had it "installed, not loaded, updates still reach it", which is what
  `cond = false` does in hako. Both show `– off`; the detail says which.
- **Not managed** rows show `●` with no load time: ranma does not tell Lua how
  long its own `pack/*/start` loads took.
- **The key** that opens the screen is bound by hako (`shift+l`, `leader L`)
  so the update toast can name a real key. In the handoff the user bound it.
- **Cleaning's ask** shows each clone's size and when its last commit was
  (`changed 3 weeks ago`). The handoff's "loaded 3 weeks ago" is something
  nothing records.
- **Load failures are not toasted by hako**: ranma already toasts every plugin
  that fails to load. hako toasts what is its own: a spec it refused.
- **A refused spec** is a row in Failed (`✗ spec`, `e` opens the file). The
  handoff had no drawing for one.
- **`y` (copy its URL)** is left out: the handoff offered it only on
  hand-cloned packages, whose URL hako would have to run git to learn.
- **The selection after a reload** is the row a key last acted on. ranma does
  not tell Lua which row is selected, and every install or update reloads.
- **Meters** come from git's own progress (`Receiving objects: 60%`); a fetch
  with nothing to receive shows the task and a time instead.
- **Paths and the bootstrap**: clones are in `~/.local/share/ranma/hako/`, the
  lockfile is `hako-lock.json`, and the bootstrap is `ranma.packadd` plus a
  background `git clone` (the handoff drew it with stand-in calls).

## Not done yet

- Cancelling a running task. The handoff left it open (`ctrl+c` on a working
  row would be the key).
- The first-run subtitle (`opened to install 3 plugins`) shows when hako opens
  the screen by itself; the filter is off for that opening, as drawn.
- hako's screen has no cell-for-cell test of its own: ranma's tests cover the
  drawing, and `tests/e2e.sh` checks what hako puts on it (sections, states,
  the bar module, the add ask, the sync ask taking only `y`, the log and `esc`
  back).
