# hako: decisions

## What it is for

Installing and keeping ranma plugins, the way lazy.nvim does for Neovim:
specs in Lua, a lockfile, one place that shows every plugin's state and does
every operation. ranma's DESIGN.md decided that "a plugin manager, if one is
ever wanted, is itself a plugin"; this is that plugin.

## No lazy-loading (and so not called lazy)

lazy.nvim is named after deferring a plugin's code until its key, command or
event is first used. ranma cannot do that and would gain nothing from it:
binds, options and hooks are only made while the configuration loads (`ranma.bind`
from a timer is an error), so "load this when its key is pressed" would be a
whole reload, which costs what loading it up front does. And ranma plugins
load in about a millisecond. The fields that only mean lazy-loading (`lazy`,
`event`, `cmd`, `ft`, `module`) are refused by name, so a spec copied from a
lazy.nvim config says what is wrong instead of silently doing something else.
`keys` is kept, as plain binds made with the spec.

## Loading goes through ranma.packadd

Plugins are cloned outside the config directory (`$XDG_DATA_HOME/ranma/hako`),
where ranma does not load them by itself, and `setup()` loads each with
`ranma.packadd` in the spec's order. That is what makes `enabled`, `cond`,
`dependencies`, `priority`, `init`, `config` and `opts` mean something; a clone
under `pack/*/start/` would load whether wanted or not, before `init.lua`.

`packadd` (ranma core, 2026-10-10) sources a package's files the way ranma
sources its own: each dropped whole if it fails, with its own load budget,
listed in `ranma health`, watched for a reload. hako never `dofile`s a plugin:
one broken plugin would then fail `init.lua`, which is fatal.

## Nothing hako does can fail init.lua

`setup` runs under `pcall`. A spec it cannot read is dropped with a toast
naming the file and the field; a plugin that fails to load, or whose `opts`
ranma refuses, is listed with the error. ranma starts either way.

## Work in the background, as coroutines

Everything that runs git runs after loading, through `ranma.spawn`. A task is a
coroutine; `task.run(argv)` yields until the process exits, so an operation
reads as straight-line Lua (`clone`, then `checkout`, then `build`, then lock)
while each resume is a callback well inside ranma's 200 ms. Several plugins run
at once (`hako.concurrency`), one operation at a time. What changed what loads
ends in one `reload_config`.

The list reads commits from `.git` files rather than running git: it is drawn
inside a callback, which must not wait on a process.

## Installing is the user's choice

hako clones itself on a first start, and nothing else: a declared plugin that
is not installed waits under *Not installed* until someone picks it (`i`,
`I`, `S`, `hako install`), and a toast says how many there are, once for each
new set. Dotfiles shared between machines declare everything, and not every
machine wants every plugin installed the moment it starts. `a` and
`hako add` are a choice already, so what they add installs.

What was asked for is kept in the store (`pending`) until it lands, because a
reload stops every job: the next load installs what is still pending.
`hako.install_missing = true` installs everything declared, as lazy.nvim
does. The lock is written as each plugin lands rather than when the run ends,
for the same reason.

## A clone is renamed into place when it is whole

A reload SIGTERMs every job the old configuration started, and installing
ends in a reload, so a reload in the middle of a run is ordinary (saving a
spec file is one). A clone is therefore made in `.part-<name>` beside the
others, checked out and built there, and renamed to its name only when all of
that worked. A directory under a plugin's name is always a whole one, a
`.part-` one is never loaded, and the next load deletes leftovers and installs
what is still missing. Found the first time hako was switched on for real: a
reload mid-install left half-cloned directories that the next load took as
installed.

**Every ranma server runs hako**, one per terminal, and they share its store
(the pending installs among it): an install from Browse writes a spec file,
both servers reload, and both clone the plugin. With one `.part-<name>`
between them the second clone met the first's ("already exists", or git's
own `BUG:` over refs), and the plugin, installed by the winner, showed as
`✗ clone` (2026-10-11). So the part dir is `.part-<name>.<token>`, a token per
Lua state; a clone first looks whether the plugin has landed, and a rename
that finds it there counts as done. The load's cleanup deletes only part dirs
older than ten minutes, since a newer one may be another server's clone in
progress, and a clone failure whose plugin is installed after all is cleared.

**`add` clones at once** as well as leaving the install pending (2026-10-12).
A reload that fails keeps the old configuration, and an `init.lua` whose bar
names a plugin's module before the plugin is installed fails every reload:
the old configuration never hears of the new spec, so nothing installed the
plugin whose module would have made the config load. Cloning at once breaks
that; a reload that does work stops the clone, and the pending install
finishes it.

## State that outlives a reload

Lua starts over on every reload, and every update ends in one. Update counts,
the last check's time and a task's failure live in `ranma.store("hako")`; the
rest is rebuilt from the specs and the disk each time.

A reload can also come in the middle of a run, from ranma itself: it watches
every plugin's directory and reloads when one changes, and a fast-forward
changes it before the run has locked the plugin or run its `build`. So an
update leaves a note (`landing`) before it moves the checkout and clears it
once it has built; the next load locks whatever is still noted where its
checkout now is, and runs the build the reload cut off. Found when hako
updating itself left the lock at the old commit (2026-10-11). Installs have
the same kind of note (`pending`, above).

## The lockfile is the user's

It defaults to the config directory, but the point of it is to sit in
dotfiles, so `lockfile` takes any path. Written sorted, one plugin a line, so
a diff of it reads as what changed. Only declared, managed plugins are kept in
it.

## Removing is narrow on purpose

hako writes spec files (`hako add` → `lua/plugins/<name>.lua`) and deletes
them (`hako remove`), but only a file that declares that one plugin and
nothing else. It never rewrites `init.lua` or a file with several specs: it
says where the spec is. Deleting anything asks first.

## The screen

Built from ranma's design handoff (`doc/handoffs/PLUGIN_MANAGER.md`); what it
needed that `ranma.screen` lacked went into ranma for every plugin, not into
hako. `doc/SCREEN.md` is the account, with where it departs from the handoff.

A reload closes a plugin's screen (its Lua is gone), and every install and
update reloads. So hako leaves a note in its store before it reloads (or
before a save it caused does), and opens the screen again when it loads, on
the row a key last acted on: ranma does not tell Lua which row is selected.

## Browse and plugin lists

ranma is too new for Neovim's way of finding plugins (blog posts, dotfiles,
awesome-lists): a new user does not know they exist. So hako browses
**plugin lists**, Dalamud's plugin repositories in shape: one JSON file at a
URL, an official one, and any others a user adds. The design came from a
handoff (`doc/SCREEN.md`, "Browse"); `doc/LISTS.md` is the format.

- **A file at a URL, fetched with curl**, not a git repository: a list is
  data, often one file in a repository that holds other things, and curl
  fetches a raw file from anywhere (and `file://` for the tests).
- **Strict, like everything ranma reads.** An unknown field refuses the list
  by name; a newer `format` says "update hako" instead of being half read. A
  list that does not read keeps its last good copy in Browse.
- **Adding a list asks, and says why.** A plugin is Lua that runs as you;
  only the official list is reviewed. The ask comes after the list is
  fetched, so it can say what is in it, and only `y` answers.
- **Installing is `add`**: the spec file is the record of what you chose,
  in your config, editable; Browse writes nothing else. Removing a list
  leaves its plugins installed.
- **`hako-lists.json` is written only when you change it**, beside the
  lockfile and configurable like it, so it can live in dotfiles.
- **The words are plain English** ("Browse", "plugin lists"): `hako` and
  `ranma` are names, but a word you have to read to understand what something
  does should not need a dictionary.
