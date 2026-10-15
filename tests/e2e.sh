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
  "XDG_DATA_HOME=$WORK/data"
  "RANMA_CONFIG_DIR=$CFG" RANMA_NO_UPDATE_CHECK=1 SHELL=/bin/bash
  "HAKO_OFFICIAL_LIST=file://$WORK/official.json" "HAKO_OPEN=$WORK/open.sh"
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
# ranma puts the hako in its data directory on require's path before init.lua
# runs, so that one is this checkout: otherwise require("hako") finds the
# copy ranma cloned from GitHub, and the test tests that.
mkdir -p "$WORK/data/ranma/hako"
ln -s "$HAKO" "$WORK/data/ranma/hako/hako.ranma"
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
echo 'PLAIN_RAN = true' > "$CFG/lua/plugins/plain-config.lua"

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
spec_errors() { RL 'local o = {} for _, e in ipairs(require("hako.state").spec_errors) do o[#o+1] = e.spec .. ": " .. e.error end return table.concat(o, "\n")'; }
spec_errors | grep -q 'does not lazy-load' || fail "lazy.nvim's event field not refused: $(spec_errors)"
ok "a lazy-loading field is refused by name, the rest load"
spec_errors | grep -q 'plain-config.lua: it returns no spec.*goes in plugin/' || fail "plain Lua among the specs not pointed at plugin/"
ok "a spec file that returns nothing is told where plain Lua goes"
# Gone before the screen is looked at, whose rows the later steps count.
rm "$CFG/lua/plugins/plain-config.lua"

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

# 3b. An update a reload stopped after the checkout moved (ranma reloads as
#     soon as a plugin's files change, which a fast-forward does before the
#     run locks it): the next load locks it where it landed.
git -C "$ROOT/alpha.ranma" merge -q --ff-only "$new"
RL 'local s = require("hako.state").store local a = s:get("landing") or {} a["alpha.ranma"] = { build = false } s:set("landing", a)' >/dev/null
"${ENVV[@]}" "RANMA_SOCKET=$RT/ranma/1.sock" ranma action reload_config
for _ in $(seq 1 40); do grep -q "$new" "$CFG/hako-lock.json" && break; sleep 0.25; done
grep -q "$new" "$CFG/hako-lock.json" || fail "an update a reload stopped was not locked where it landed"
ok "an update a reload stopped is locked on the next load"

# 3c. Updating several at once: the first to land changes a plugin's files,
#     ranma reloads, and the run stops with the rest never fetched. The next
#     load takes them up again, until all of them have landed.
for r in alpha plain; do
  printf '%s\n' "-- $r three" >> "$SRC/$r.ranma/plugin/$r.lua"
  "${ENVV[@]}" git -C "$SRC/$r.ranma" commit -qam three
done
# One at a time, and alpha's fetch as slow as a real remote's (a local one
# is done inside ranma's reload debounce), so the reload plain's landing sets
# off always comes with alpha still to go.
git -C "$ROOT/alpha.ranma" config remote.origin.uploadpack "sleep 1; git-upload-pack"
echo 'ranma.set({ hako = { concurrency = 1 } })' >> "$CFG/init.lua"
until_lua 'return ranma.get("hako.concurrency") == 1' "concurrency 1 loaded"
RL 'require("hako").update()' >/dev/null
for _ in $(seq 1 80); do
  [ "$(git -C "$ROOT/alpha.ranma" rev-parse HEAD)" = "$(git -C "$SRC/alpha.ranma" rev-parse HEAD)" ] \
    && [ "$(git -C "$ROOT/plain.ranma" rev-parse HEAD)" = "$(git -C "$SRC/plain.ranma" rev-parse HEAD)" ] && break
  sleep 0.25
done
for r in alpha plain; do
  [ "$(git -C "$ROOT/$r.ranma" rev-parse HEAD)" = "$(git -C "$SRC/$r.ranma" rev-parse HEAD)" ] \
    || fail "$r was left behind by an update a reload stopped"
done
until_lua 'return next(require("hako.state").store:get("queued") or {}) == nil and require("hako.ops").running() == nil' "the update queue empties"
for r in alpha plain; do
  grep -q "$(git -C "$SRC/$r.ranma" rev-parse HEAD)" "$CFG/hako-lock.json" || fail "$r not locked where it landed"
done
git -C "$ROOT/alpha.ranma" config --unset remote.origin.uploadpack
sed -i '/concurrency = 1/d' "$CFG/init.lua"
until_lua 'return ranma.get("hako.concurrency") == 4' "concurrency back to 4"
ok "an update a reload stopped goes on with the rest on the next load"

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
touch -d '-20 min' "$ROOT/.part-half.ranma"
# A fresh one may be another server's clone, still going: it stays.
mkdir -p "$ROOT/.part-busy.ranma.othr"
"${ENVV[@]}" "RANMA_SOCKET=$RT/ranma/1.sock" ranma action reload_config
for _ in $(seq 1 40); do [ ! -e "$ROOT/.part-half.ranma" ] && break; sleep 0.25; done
[ ! -e "$ROOT/.part-half.ranma" ] || fail "a leftover part dir was not cleared"
[ -d "$ROOT/.part-busy.ranma.othr" ] || fail "a fresh part dir (another server's clone) was deleted"
rm -rf "$ROOT/.part-busy.ranma.othr"
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
# w opens a plugin's repository in the browser: the opener here only writes
# down what it was given. A repository on disk has no page, so no w.
printf '#!/bin/sh\necho "$1" > "%s/opened"\n' "$WORK" > "$WORK/open.sh"
chmod +x "$WORK/open.sh"
[ "$(RL 'local u = require("hako.util"); return table.concat({ u.web_url("masshirodev/zen.ranma"), u.web_url("git@github.com:a/b.git"), u.web_url("ssh://git@codeberg.org/c/d.git"), u.web_url("https://gitlab.com/e/f.git") }, " ")')" = \
  '"https://github.com/masshirodev/zen.ranma https://github.com/a/b https://codeberg.org/c/d https://gitlab.com/e/f"' ] ||
  fail "web_url: $(RL 'return require("hako.util").web_url("git@github.com:a/b.git")')"
[ "$(RL 'return require("hako.util").web_url("/tmp/x.ranma") == nil')" = "true" ] || fail "a path has a page"
RL 'require("hako.util").open_url("https://github.com/masshirodev/hako.ranma")' >/dev/null
for _ in $(seq 1 20); do [ -s "$WORK/opened" ] && break; sleep 0.25; done
[ "$(cat "$WORK/opened" 2>/dev/null)" = "https://github.com/masshirodev/hako.ranma" ] || fail "open_url did not run the opener"
ok "w: a repository's page, opened by the desktop's opener"

# 7. Browse: plugins from lists. The official list is a local file here
#    (HAKO_OFFICIAL_LIST), and so is the one added with a.
repo zeta.ranma 'plugin/zeta.lua=ranma.option("zeta.n", { type = "int", default = 4 })'
repo eta.ranma 'plugin/eta.lua=ranma.option("eta.n", { type = "int", default = 8 })'
cat > "$WORK/official.json" <<JSON
{ "format": 1, "name": "ranma plugins", "plugins": [
  { "repo": "file://$SRC/zeta.ranma", "description": "Zeta: a plugin to install.", "author": "t", "tags": ["git", "bar"] },
  { "repo": "file://$SRC/plain.ranma", "description": "Plain: declared and installed.", "author": "t", "tags": ["bar"] },
  { "repo": "file://$SRC/far.ranma", "description": "Far: needs a ranma from the future.", "author": "t", "ranma": "9.0.0" }
] }
JSON
cat > "$WORK/third.json" <<JSON
{ "format": 1, "name": "kenji's plugins", "plugins": [
  { "repo": "file://$SRC/eta.ranma", "description": "Eta: from a list nobody reviews.", "author": "kenji" }
] }
JSON
out=$(RL 'require("hako").browse()') || fail "browse: $out"
wait_screen "browse · 3 plugins" "Browse opens and the official list lands"
wait_screen "Available" "an available plugin has its section"
wait_screen "needs 9.0.0" "a plugin for a newer ranma says so"
wait_screen "● installed" "a declared, installed plugin says so"
wait_screen "Lists" "the lists are under the plugins"
if [ -n "${SHOW:-}" ]; then scr; fi
ok "Browse: the official list's plugins, by what each is to you"
T send-keys -t s / '#git'
wait_screen "browse · 1 of 3" "a #tag filters"
scr | grep -q "Lists" && fail "the lists stayed while a filter stands"
ok "Browse: /#git keeps the tagged plugin, and the lists go"
T send-keys -t s Enter i
until_lua 'return ranma.get("zeta.n") == 4' "i installs from Browse"
grep -q "from ranma plugins" "$CFG/lua/plugins/zeta.lua" || fail "the spec file does not say which list: $(cat "$CFG/lua/plugins/zeta.lua")"
wait_screen "browse ·" "hako comes back to Browse after the reload"
ok "i: the spec written (from its list), installed, back in Browse"
T send-keys -t s a
wait_screen "add list" "a asks for a list's URL"
T send-keys -t s "file://$WORK/third.json" Enter
wait_screen "add list?" "a fetched list asks before it is added"
wait_screen "Nobody reviews this list" "the warning"
T send-keys -t s u
sleep 0.5
grep -q third "$CFG/hako-lists.json" 2>/dev/null && fail "a key other than y added the list"
T send-keys -t s y
wait_screen " eta\.ranma" "the added list's plugin shows"
wait_screen "unreviewed" "a plugin from it is marked unreviewed"
grep -q third "$CFG/hako-lists.json" || fail "hako-lists.json does not have the list"
ok "a: fetched, warned, y adds it to hako-lists.json"
mv "$WORK/third.json" "$WORK/third.gone"
T send-keys -t s C
wait_screen "1 list failed" "a list that cannot be fetched says so"
scr | grep -q ' eta\.ranma' || fail "the failed list's last copy is not shown"
ok "C: a list that fails keeps its last copy"
RL 'local l = require("hako.lists") for _, x in ipairs(l.read_config()) do if x.url:find("third") then l.remove(x.url) end end require("hako.screen").changed()' >/dev/null
for _ in $(seq 1 20); do scr | grep -q ' eta\.ranma' || break; sleep 0.25; done
scr | grep -q ' eta\.ranma' && fail "a removed list's plugins are still in Browse"
scr | grep -q "list failed" && fail "the removed list's failure stayed in the status"
grep -q third "$CFG/hako-lists.json" && fail "the removed list is still in hako-lists.json"
ok "a removed list's plugins leave Browse"
T send-keys -t s Escape
wait_screen "B browses" "esc back to the installed view, which points at Browse"
ok "esc: back to the installed view"

# 8. A bar that names a plugin's module before the plugin is installed: every
#    reload fails and keeps the old configuration, which has never heard of
#    the plugin. Adding it clones it at once, so the next reload has the
#    module and loads.
repo modded.ranma 'plugin/modded.lua=ranma.module("modded", { render = function() return "modded" end })'
cp "$CFG/init.lua" "$WORK/init.before"
sed -i 's/ranma.bar { right = { "hako", "clock" } }/ranma.bar { right = { "hako", "modded", "clock" } }/' "$CFG/init.lua"
"${ENVV[@]}" "RANMA_SOCKET=$RT/ranma/1.sock" ranma action reload_config
sleep 1
[ "$(RL 'return require("hako.state").by_name["modded.ranma"] == nil')" = "true" ] || fail "the failing config was taken"
RL 'require("hako.ops").add("file://'"$SRC"'/modded.ranma")' >/dev/null
until_lua 'return require("hako.state").by_name["modded.ranma"] ~= nil and require("hako.state").by_name["modded.ranma"].loaded == true' "a plugin whose module the bar already names installs, and the config loads"
ok "add clones at once: a bar naming the plugin's module no longer locks it out"
cp "$WORK/init.before" "$CFG/init.lua"

# 9. install = true: installed without asking, once, as ranma's default setup
#    declares mobile.ranma. A spec file that disables it wins the merge, and
#    nothing is cloned. Once it has landed, removing it sticks; a plugin that
#    never landed is tried again, but at most once an hour.
repo auto.ranma 'plugin/auto.lua=ranma.option("auto.n", { type = "int", default = 4 })'
repo autooff.ranma 'plugin/autooff.lua=error("disabled: never loaded")'
echo "return { { \"file://$SRC/auto.ranma\", install = true }, { \"file://$SRC/autooff.ranma\", install = true }, { \"file://$SRC/later.ranma\", install = true } }" > "$CFG/lua/plugins/auto.lua"
echo "return { \"file://$SRC/autooff.ranma\", enabled = false }" > "$CFG/lua/plugins/zz-autooff.lua"
"${ENVV[@]}" "RANMA_SOCKET=$RT/ranma/1.sock" ranma action reload_config
until_lua 'return ranma.get("auto.n") == 4' "install = true installs without asking"
ok "install = true: installed and loaded without asking"
[ ! -e "$ROOT/autooff.ranma" ] || fail "enabled = false in a later spec file did not win over install = true"
ok "enabled = false merged over install = true installs nothing"
until_lua 'return (ranma.store("hako"):get("installed_once") or {})["auto.ranma"] == true' "the once mark after it landed"
[ "$(RL 'return (ranma.store("hako"):get("installed_once") or {})["later.ranma"] == nil')" = "true" ] || fail "a clone that failed was marked installed"
ok "landed: marked installed once; a failed clone is not"
# x on the screen, for a plugin no spec file of its own declares: the clone
# goes, the specs stay, and it is not installed again or counted as missing.
[ "$(RL 'return require("hako.ops").remove_clone("auto.ranma")')" = "true" ] || fail "remove_clone refused"
for _ in $(seq 1 40); do [ ! -e "$ROOT/auto.ranma" ] && break; sleep 0.25; done
sleep 2
"${ENVV[@]}" "RANMA_SOCKET=$RT/ranma/1.sock" ranma action reload_config
sleep 3
[ ! -e "$ROOT/auto.ranma" ] || fail "a plugin installed once and removed came back"
grep -q "auto.ranma" "$CFG/lua/plugins/auto.lua" || fail "removing the clone touched the spec"
[ "$(RL 'return ranma.store("hako"):get("told_missing") or ""')" != "" ] && \
  RL 'return ranma.store("hako"):get("told_missing")' | grep -q auto && fail "a removed plugin was counted as missing"
ok "x: the clone goes, the spec stays, and it is not installed again"
RL 'require("hako").install("auto.ranma")' >/dev/null
until_lua 'return ranma.get("auto.n") == 4' "i puts a removed plugin back"
ok "i puts it back"
# later.ranma's clone failed (no repository yet). Made now, it is not
# cloned again within the hour.
repo later.ranma 'plugin/later.lua=ranma.option("later.n", { type = "int", default = 1 })'
"${ENVV[@]}" "RANMA_SOCKET=$RT/ranma/1.sock" ranma action reload_config
sleep 3
[ ! -e "$ROOT/later.ranma" ] || fail "a plugin tried within the hour was cloned again"
ok "a clone that failed is tried again at most once an hour"
rm "$CFG/lua/plugins/auto.lua" "$CFG/lua/plugins/zz-autooff.lua"

echo "hako e2e: ok"
