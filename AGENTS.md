# AGENTS.md

hako is a plugin manager for ranma (`~/projects/ranma`, `masshirodev/ranma`),
written as a ranma plugin in Lua. `README.md` is the user's reference;
`doc/DESIGN.md` records the decisions, including what it deliberately does not
do (lazy-loading). Read both before changing behaviour.

## Layout

- `lua/hako/init.lua`: `setup()`, reading specs and loading plugins with
  `ranma.packadd`.
- `lua/hako/spec.lua`: parsing specs, strictly; `lua/hako/ops.lua`: the
  background operations; `lua/hako/task.lua`: coroutines over `ranma.spawn`;
  `lua/hako/screen.lua`: the screen (`doc/SCREEN.md`); `lua/hako/ui.lua`:
  the palette command, the key and the bar module; `lua/hako/lock.lua`,
  `lua/hako/util.lua`, `lua/hako/state.lua`.
- There is no `plugin/` directory: hako runs when `init.lua` calls `setup`.

## Before a commit

```sh
tests/e2e.sh
```

It starts a private, headless ranma (its own runtime, state and config
directories, its own tmux server) and never touches a real session.
**`ranma lua` and `ranma action` talk to whatever `RANMA_SOCKET` names**, and
every ranma pane exports it: a test that does not set it to its own server's
socket drives the user's real ranma. Keep the `env -u RANMA_SOCKET …` and the
explicit `RANMA_SOCKET=$RT/ranma/1.sock` in place.

A change to behaviour comes with a step in `tests/e2e.sh`, a line in
`README.md`, and, for a decision, `doc/DESIGN.md`.

## Conventions

- Push to `main`.
- ranma's API is the reference: `ranma --dump-types` prints it. Only binds,
  options, hooks and `packadd` work while loading; `spawn`, `toast`, `action`
  and pickers only at run time (`util.later` defers to the first tick).
- Nothing hako does may fail `init.lua`: errors are caught, kept on the plugin
  and toasted.
- Specs are parsed strictly, as ranma parses its config: an unknown field is an
  error naming it, never ignored.
- Never delete anything without asking, and never anything a spec still
  declares or that hako did not clone (`dir` checkouts, `pack/*/start`).
