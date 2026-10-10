#!/bin/bash
# hako end to end: a private, headless ranma server (its own runtime, state
# and config directories, in a tmux server of its own) loading this checkout,
# with plugins cloned from local git repositories. Never touches a real
# session. Needs ranma (with ranma.packadd), tmux and git.
#
#   tests/e2e.sh          run it
#   KEEP=1 tests/e2e.sh   leave the work directory for a look afterwards
set -euo pipefail

HAKO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/hako-e2e.XXXX")
# The socket path must stay short (SUN_LEN): its own small directory.
RT=$(mktemp -d /tmp/hako-rt.XXXX)
SRC=$WORK/src CFG=$WORK/cfg ROOT=$WORK/root STATE=$WORK/state
SOCK=hako-e2e-$$
T() { tmux -L "$SOCK" "$@"; }
ENVV=(env -u SSH_CONNECTION -u SSH_TTY -u SSH_CLIENT -u RANMA -u RANMA_SOCKET -u RANMA_PANE -u TMUX
  "XDG_RUNTIME_DIR=$RT" "XDG_CACHE_HOME=$WORK/cache" "XDG_STATE_HOME=$STATE"
  "RANMA_CONFIG_DIR=$CFG" RANMA_NO_UPDATE_CHECK=1 SHELL=/bin/bash
  GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t)

cleanup() {
  T kill-server 2>/dev/null || true
  for p in $(pgrep -x ranma); do
    tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$RT" && kill "$p"
  done
  rm -rf "$RT"
  if [ -z "${KEEP:-}" ]; then rm -rf "$WORK"; else echo "kept $WORK"; fi
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; echo "--- hako:"; RL 'local s = {} for _, p in ipairs(require("hako").plugins()) do s[#s+1] = p.name .. ": " .. require("hako.ui").describe(p) end return table.concat(s, "\n")' || true; exit 1; }
ok() { echo "ok   $*"; }
# Lua in the test's server, printed as `ranma lua` prints it. It names the
# test's socket: a pane exports RANMA_SOCKET, and the real server is the one
# it would otherwise reach.
RL() { "${ENVV[@]}" "RANMA_SOCKET=$RT/ranma/1.sock" ranma lua "$1" 2>&1; }
# Wait until a Lua expression returns true.
until_lua() { # expr, what
  for _ in $(seq 1 80); do [ "$(RL "$1")" = "true" ] && return 0; sleep 0.25; done
  fail "$2"
}

# A plugin repository: name, then file=content pairs.
repo() {
  local dir=$SRC/$1; shift
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  while [ $# -gt 0 ]; do
    mkdir -p "$(dirname "$dir/${1%%=*}")"
    printf '%s\n' "${1#*=}" > "$dir/${1%%=*}"
    shift
  done
  "${ENVV[@]}" git -C "$dir" add -A
  "${ENVV[@]}" git -C "$dir" commit -q -m init
}

repo alpha.ranma 'plugin/alpha.lua=ranma.option("alpha.n", { type = "int", default = 1 })'
repo dep.ranma 'plugin/dep.lua=DEP_LOADED = true'
repo beta.ranma 'lua/beta.lua=return { ok = true }' \
  'plugin/beta.lua=assert(DEP_LOADED, "dep loads first") ranma.option("beta.ok", { type = "bool", default = (require("beta")).ok })'
repo broken.ranma 'plugin/broken.lua=error("boom")'
repo off.ranma 'plugin/off.lua=error("disabled: never loaded")'
repo gamma.ranma 'plugin/gamma.lua=ranma.option("gamma.n", { type = "int", default = 3 })'

mkdir -p "$CFG/lua/plugins" "$ROOT"
cat > "$CFG/init.lua" <<EOF
assert(ranma.packadd("$HAKO"))
require("hako").setup({
  { "file://$SRC/alpha.ranma", opts = { n = 5 } },
  { "file://$SRC/beta.ranma", dependencies = { "file://$SRC/dep.ranma" } },
  { "file://$SRC/off.ranma", enabled = false },
  { import = "plugins" },
}, { root = "$ROOT", lockfile = "$CFG/hako-lock.json" })
EOF
echo "return { \"file://$SRC/broken.ranma\" }" > "$CFG/lua/plugins/broken.lua"
echo "return { \"file://$SRC/typo.ranma\", event = \"VeryLazy\" }" > "$CFG/lua/plugins/typo.lua"

T new-session -d -s s -x 120 -y 30 "${ENVV[*]} ranma; sleep 60"
for _ in $(seq 1 40); do RL 'true' >/dev/null 2>&1 && break; sleep 0.25; done

# 1. First start: everything declared and enabled is cloned, locked, and
#    loaded on the reload that follows.
until_lua 'local l = io.open("'"$CFG"'/hako-lock.json") and io.open("'"$CFG"'/hako-lock.json"):read("a") or "" return l:find("alpha") ~= nil and l:find("broken") ~= nil and ranma.get("alpha.n") ~= nil' "installed and reloaded"
ok "missing plugins installed, locked, reloaded"
[ "$(RL 'return ranma.get("alpha.n")')" = "5" ] || fail "opts applied: alpha.n is $(RL 'return ranma.get("alpha.n")')"
ok "opts went to ranma.set { alpha = ... }"
[ "$(RL 'return ranma.get("beta.ok")')" = "true" ] || fail "beta (after dep, with its lua/) did not load"
ok "a dependency loads first; a package's lua/ is on require's path"
[ ! -e "$ROOT/off.ranma" ] || fail "a disabled plugin was installed"
ok "enabled = false installs nothing"
[ "$(RL 'return require("hako.state").by_name["broken.ranma"].loaded')" = "false" ] || fail "broken counted as loaded"
RL 'return require("hako.state").by_name["broken.ranma"].errors[1]' | grep -q boom || fail "broken's error not kept"
ok "a failing plugin is reported, and ranma runs on"
RL 'return require("hako.state").spec_errors[1].error' | grep -q 'does not lazy-load' || fail "lazy.nvim's event field not refused"
ok "a lazy-loading field is refused by name, the rest load"

# 2. Check and update.
old=$(git -C "$ROOT/alpha.ranma" rev-parse HEAD)
printf '%s\n' 'ranma.option("alpha.n", { type = "int", default = 1 })' 'ranma.option("alpha.v", { type = "string", default = "two" })' > "$SRC/alpha.ranma/plugin/alpha.lua"
"${ENVV[@]}" git -C "$SRC/alpha.ranma" commit -qam two
RL 'require("hako").check()' >/dev/null
until_lua 'local u = require("hako.ops").updates()["alpha.ranma"] return u ~= nil and u.n == 1' "check counts one new commit"
ok "check: alpha is 1 behind"
RL 'require("hako").update()' >/dev/null
until_lua 'return ranma.get("alpha.v") == "two"' "update fast-forwards and reloads"
new=$(git -C "$ROOT/alpha.ranma" rev-parse HEAD)
grep -q "$new" "$CFG/hako-lock.json" || fail "the lock did not move to $new"
ok "update: fast-forwarded, locked, reloaded"

# 3. Restore to an older lock.
sed -i "s/$new/$old/" "$CFG/hako-lock.json"
"${ENVV[@]}" "RANMA_SOCKET=$RT/ranma/1.sock" ranma action reload_config
sleep 1
RL 'require("hako").restore()' >/dev/null
for _ in $(seq 1 40); do [ "$(git -C "$ROOT/alpha.ranma" rev-parse HEAD)" = "$old" ] && break; sleep 0.25; done
[ "$(git -C "$ROOT/alpha.ranma" rev-parse HEAD)" = "$old" ] || fail "restore did not go back to $old"
ok "restore: back at the lockfile's commit"

# 4. Clean.
mkdir -p "$ROOT/stray.ranma"
RL 'require("hako.ops").clean(true)' >/dev/null
for _ in $(seq 1 40); do [ ! -e "$ROOT/stray.ranma" ] && break; sleep 0.25; done
[ ! -e "$ROOT/stray.ranma" ] || fail "clean left stray.ranma"
[ -d "$ROOT/alpha.ranma" ] || fail "clean deleted a declared plugin"
ok "clean: deletes what nothing declares, only that"

# 5. Add: a file of its own, then the reload installs it.
RL 'require("hako.ops").add("file://'"$SRC"'/gamma.ranma")' >/dev/null
[ -f "$CFG/lua/plugins/gamma.lua" ] || fail "add wrote no spec file"
until_lua 'return ranma.get("gamma.n") == 3' "an added plugin installs and loads"
ok "add: lua/plugins/gamma.lua written, installed, loaded"

echo "hako e2e: ok"
