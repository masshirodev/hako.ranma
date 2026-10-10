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

## State that outlives a reload

Lua starts over on every reload, and every update ends in one. Update counts,
the last check's time and a task's failure live in `ranma.store("hako")`; the
rest is rebuilt from the specs and the disk each time.

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
