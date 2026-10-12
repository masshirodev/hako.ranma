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
| `B` | Browse: plugins from lists (below) | the screen |
| `l` | the log of what updates brought, one group per plugin (all its updates of the last 7 days together) | most rows |
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

## Browse

`B` pushes Browse over the list: from the design handoff
`doc/handoffs/PLUGIN_BROWSER_MOCK.txt` (with `PLUGIN_BROWSER_screen.js`, which
draws it; the brief is `doc/briefs/done/PLUGIN_BROWSER.md`). `esc`, or `B`
again, comes back. `lua/hako/browse.lua` builds it; `lua/hako/lists.lua` reads
and fetches the lists (`doc/LISTS.md`).

| Section | What is in it |
| --- | --- |
| Not installed | declared in your specs, not cloned (`○ missing`; `i` installs it) |
| Available | in a list, not declared (`i` writes its spec and installs it) |
| Needs a newer ranma | its `ranma` is newer than the one running (`needs 0.2.0`; no `i`) |
| Installed | declared and cloned (`● installed`; `B` goes to the installed view) |
| Lists | each list: its plugin count, `fetch 0:01`, `✗ 3d old` (failed, its copy shown), `✗ no copy`, `– off` |

The lists go first while one needs you (a failed fetch, or the first one), as
Failed does in the installed view. While `/` holds a filter they go, and the
sections stay. A plugin from a list that is not the official one is marked
`unreviewed`, and its detail says "nobody reviews it".

| Key | Does | On |
| --- | --- | --- |
| `i` | install it | an available or not-installed plugin |
| `t` | turn a list off · on | a list |
| `x` | remove a list (asks; not the official one) | a list |
| `a` | add a list: its URL, fetched and shown, then a warning only `y` answers | Browse |
| `C` | fetch every list again | Browse |
| `B` | the installed view | Browse, an installed plugin |
| `/` | filter: words (name, description, author) and `#tag` | Browse |

Installing writes the spec file, ranma reloads, and hako opens again in
Browse on that row, where the clone runs as a meter.

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
- **The first run does not install by itself.** The handoff drew the screen
  opening on its own to clone three plugins. hako installs itself, then waits
  for the user to pick (`i`, `I`, `S`) and toasts what is missing; the screen
  opens on its own only to show an install someone asked for (an `a`, or one
  a reload stopped). `hako.install_missing = true` brings the handoff's first
  run back.
- **Paths and the bootstrap**: clones are in `~/.local/share/ranma/hako/`, the
  lockfile is `hako-lock.json`, and the bootstrap is `ranma.packadd` plus a
  background `git clone` (the handoff drew it with stand-in calls).

## Where Browse departs from its handoff

- **The plugins and the numbers** are the handoff's own (gitbar, float,
  pomodoro, "51 plugins"): Browse shows what the lists hold. "… 36 more, to
  the end of the alphabet" is the mock shortening a long list; Browse lists
  every plugin, and the list scrolls.
- **The status** in Browse is about lists and installs (`fetching 0/1`,
  `1 list failed`, `installing 1/1`), never a plugin that failed to load: that
  is the installed view's to say. The mock drew one of each, never both.
- **The bottom edge** says `esc back`, not `o options · esc back`: ranma draws
  every pushed view that way (the plugin manager's log, compared with its own
  handoff cell for cell, too). `o` works there all the same, and the keys
  card says so.
- **A list entry without `ranma`** says nothing about ranma's version. The
  handoff gave every plugin one, so it always drew "ranma 0.1.0 or newer".
- **Fetching** happens when Browse opens (for lists older than
  `hako.check_hours`) and on `C`, not every 6 hours in the background as the
  first-fetch detail suggests: nothing asks for a list until Browse opens.
- **The installed view's detail** is 6 rows, as this handoff draws it (the
  plugin manager's had 5).
- **On a ranma from before 2026-10-11**, whose pushed views take no filter of
  the plugin's own, `/` in Browse matches names only.

## Not done yet

- Cancelling a running task. The handoff left it open (`ctrl+c` on a working
  row would be the key).
- The first-run subtitle (`opened to install 3 plugins`) shows when hako opens
  the screen by itself; the filter is off for that opening, as drawn.
- hako's screen has no cell-for-cell test of its own: ranma's tests cover the
  drawing, and `tests/e2e.sh` checks what hako puts on it (sections, states,
  the bar module, the add ask, the sync ask taking only `y`, the log and `esc`
  back).
