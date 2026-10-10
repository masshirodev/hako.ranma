#!/bin/bash
# hako end to end: a private, headless ranma server (its own runtime, state
# and config directories, in a tmux server of its own) loading this checkout,
# with plugins cloned from local git repositories. Never touches a real
# session. Needs ranma (with ranma.packadd), tmux and git.
#
#   tests/e2e.sh          run it
#   KEEP=1 tests/e2e.sh   leave the work directory for a look afterwards
#   SHOW=1 tests/e2e.sh   print the screen as it is drawn
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

fail() { echo "FAIL: $*"; echo "--- screen:"; T capture-pane -p -t s 2>/dev/null || true; exit 1; }
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
repo slow.ranma 'plugin/slow.lua=ranma.option("slow.n", { type = "int", default = 9 })'
repo plain.ranma 'plugin/plain.lua=ranma.option("plain.n", { type = "int", default = 7 })'
repo gamma.ranma 'plugin/gamma.lua=ranma.option("gamma.n", { type = "int", default = 3 })'

mkdir -p "$CFG/lua/plugins" "$ROOT"
cat > "$CFG/init.lua" <<EOF
assert(ranma.packadd("$HAKO"))
require("hako").setup({
  "file://$SRC/plain.ranma",
  { "file://$SRC/slow.ranma", build = "sleep 3" },
  { "file://$SRC/alpha.ranma", opts = { n = 5 } },
  { "file://$SRC/beta.ranma", dependencies = { "file://$SRC/dep.ranma" } },
  { "file://$SRC/off.ranma", enabled = false },
  { import = "plugins" },
}, { root = "$ROOT", lockfile = "$CFG/hako-lock.json" })
ranma.bar { right = { "hako", "clock" } }
EOF
echo "return { \"file://$SRC/broken.ranma\" }" > "$CFG/lua/plugins/broken.lua"
echo "return { \"file://$SRC/typo.ranma\", event = \"VeryLazy\" }" > "$CFG/lua/plugins/typo.lua"

T new-session -d -s s -x 120 -y 30 "${ENVV[*]} ranma; sleep 60"
for _ in $(seq 1 40); do RL 'true' >/dev/null 2>&1 && break; sleep 0.25; done

# 1. First start: nothing is cloned until asked; hako says what is missing.
#    Asked, everything declared and enabled is cloned, locked, and loaded on
#    the reload that follows.
sleep 2
[ -z "$(ls -A "$ROOT")" ] || fail "a first start installed something nobody asked for: $(ls "$ROOT")"
T capture-pane -p -t s | grep -q "declared, not installed" || fail "no word about the missing plugins"
ok "a first start installs nothing, and says what is missing"
RL 'require("hako").install()' >/dev/null
# A reload in the middle (slow.ranma's build sleeps) stops the run; what was
# asked for is installed by the load after it all the same.
sleep 1.5
"${ENVV[@]}" "RANMA_SOCKET=$RT/ranma/1.sock" ranma action reload_config
until_lua 'return ranma.get("slow.n") == 9' "an install a reload stopped resumes"
ok "an install a reload stopped resumes on the next load"
until_lua 'local l = io.open("'"$CFG"'/hako-lock.json") and io.open("'"$CFG"'/hako-lock.json"):read("a") or "" return l:find("alpha") ~= nil and l:find("broken") ~= nil and ranma.get("alpha.n") ~= nil' "installed and reloaded"
ok "missing plugins installed, locked, reloaded"
[ "$(RL 'return ranma.get("alpha.n")')" = "5" ] || fail "opts applied: alpha.n is $(RL 'return ranma.get("alpha.n")')"
ok "opts went to ranma.set { alpha = ... }"
[ "$(RL 'return ranma.get("plain.n")')" = "7" ] || fail "a bare string beside tables in setup's list was not read as a spec"
ok "setup's list: a bare string beside tables is a spec of its own"
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

# 4b. A clone a reload stopped half made is never loaded, and the next load
#     clears it away.
mkdir -p "$ROOT/.part-half.ranma/plugin"
echo 'error("a half-made clone was loaded")' > "$ROOT/.part-half.ranma/plugin/half.lua"
"${ENVV[@]}" "RANMA_SOCKET=$RT/ranma/1.sock" ranma action reload_config
for _ in $(seq 1 40); do [ ! -e "$ROOT/.part-half.ranma" ] && break; sleep 0.25; done
[ ! -e "$ROOT/.part-half.ranma" ] || fail "a leftover part dir was not cleared"
RL 'for _, p in ipairs(require("hako").plugins()) do if p.name:find("half") then return "loaded" end end return "no"' | grep -q no || fail "a part dir was taken for a plugin"
ok "a half-made clone is never a plugin, and is cleared on load"

# 5. Add: a file of its own, then the reload installs it.
RL 'require("hako.ops").add("file://'"$SRC"'/gamma.ranma")' >/dev/null
[ -f "$CFG/lua/plugins/gamma.lua" ] || fail "add wrote no spec file"
until_lua 'return ranma.get("gamma.n") == 3' "an added plugin installs and loads"
ok "add: lua/plugins/gamma.lua written, installed, loaded"

# 6. The screen.
scr() { T capture-pane -p -t s; }
wait_screen() { # pattern, what
  for _ in $(seq 1 40); do scr | grep -q -- "$1" && return 0; sleep 0.25; done
  fail "$2 (no \"$1\" on screen)"
}
mkdir -p "$ROOT/stray.ranma"
RL 'require("hako").open()' >/dev/null
wait_screen "hako" "the screen opens"
wait_screen "Failed" "the Failed section"
wait_screen "✗ load" "a plugin that failed to load says so"
wait_screen "✗ spec" "a spec hako refused is listed"
wait_screen "Not in spec" "a stray has its section"
scr | tail -1 | grep -q "✗ 2 failed" || fail "the bar module: $(scr | tail -1)"
ok "the screen: sections, states, and the bar module"
# SHOW=1 prints the screen as drawn, to hold up against the handoff's mock.
if [ -n "${SHOW:-}" ]; then scr; fi
T send-keys -t s a
wait_screen "+ " "a: the line being typed"
wait_screen " add " "a: the status says add"
T send-keys -t s x / y
wait_screen "+ x/y" "a: typing goes into the line"
T send-keys -t s Escape
for _ in $(seq 1 20); do scr | grep -q "+ x/y" || break; sleep 0.25; done
scr | grep -q "+ x/y" && fail "esc did not take the add ask down"
ok "a: an ask with a typed line, esc cancels"
T send-keys -t s S
wait_screen "sync?" "S with a stray asks first"
wait_screen "deletes" "the stray is marked deletes"
T send-keys -t s u
sleep 0.5
[ -d "$ROOT/stray.ranma" ] || fail "a key other than the answers deleted something"
T send-keys -t s Escape
sleep 0.5
[ -d "$ROOT/stray.ranma" ] || fail "esc deleted the stray"
ok "S: asks before it deletes; nothing but y answers"
# l is a row's key (the handoff's table): back to the first row, which has it.
for _ in $(seq 1 12); do T send-keys -t s k; done
T send-keys -t s l
wait_screen "log · the last 7 days" "l pushes the log"
wait_screen "esc back" "the log says esc back"
wait_screen "alpha.ranma" "the log holds the update made above"
T send-keys -t s Escape
wait_screen "Not in spec" "esc comes back to the list"
scr | grep -q "hako" || fail "esc closed the screen instead of going back"
ok "l: the log, and esc back to the list"

echo "hako e2e: ok"
