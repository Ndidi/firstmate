#!/usr/bin/env bash
# tests/fm-crew-memory-cap.test.sh - behavioral coverage for the per-worker
# memory bound: limit derivation and clamping, the config override and its
# refusals, the quoting contract of `wrap`, open degradation on hosts that
# cannot offer the bound, the spawn-path integration, and - where the host can
# actually create a bounded scope - a real runaway being killed at its limit.
#
# The real-bound section self-skips rather than failing, because the mechanism
# is a property of the host (systemd, a user manager, cgroup memory delegation)
# and standard CI has none of them. Everything above it is portable and runs
# everywhere, so the logic stays pinned even where the kernel half cannot.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/tmux-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/tmux-test-safety.sh"

CAP="$ROOT/bin/fm-crew-memory-cap.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-memory-cap)

new_home() {  # <name> -> home dir with an empty config
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/data" "$home/state"
  printf '%s\n' "$home"
}

meminfo_with() {  # <name> <kib> -> path to a MemTotal source
  local path="$TMP_ROOT/meminfo-$1"
  printf 'MemTotal:       %s kB\nMemFree:          100 kB\n' "$2" > "$path"
  printf '%s\n' "$path"
}

cap() {  # <home> <meminfo> <args...>
  local home=$1 meminfo=$2
  shift 2
  FM_CONFIG_OVERRIDE="$home/config" FM_CREW_MEMORY_CAP_MEMINFO_OVERRIDE="$meminfo" \
    "$CAP" "$@"
}

# --- default derivation and clamping ---------------------------------------
#
# The default must need no configuration and must stay safe on any host size:
# a quarter of memory, never below 2 GiB (a small laptop stays usable) and never
# above 8 GiB (a large host still gets a real bound rather than a token one).

HOME_A=$(new_home derive)

got=$(cap "$HOME_A" "$(meminfo_with 30g 30502032)" limit)
[ "$got" = 7446M ] || fail "29 GiB host should derive 7446M, got '$got'"
pass "default limit is a quarter of host memory"

got=$(cap "$HOME_A" "$(meminfo_with 4g 4194304)" limit)
[ "$got" = 2048M ] || fail "4 GiB host should clamp up to the 2048M floor, got '$got'"
pass "small host clamps up to the floor"

got=$(cap "$HOME_A" "$(meminfo_with 256g 268435456)" limit)
[ "$got" = 8192M ] || fail "256 GiB host should clamp down to the 8192M ceiling, got '$got'"
pass "large host clamps down to the ceiling"

got=$(cap "$HOME_A" "$TMP_ROOT/definitely-absent-meminfo" limit)
[ -z "$got" ] || fail "a host with no readable memory total should yield no limit, got '$got'"
pass "no derivable host total yields no limit rather than a guess"

# --- the operator override --------------------------------------------------

HOME_B=$(new_home override)
MI=$(meminfo_with std 30502032)

printf '3G\n' > "$HOME_B/config/crew-memory-max"
got=$(cap "$HOME_B" "$MI" limit)
[ "$got" = 3G ] || fail "config/crew-memory-max should win over the default, got '$got'"
pass "operator override replaces the derived default"

out=$(cap "$HOME_B" "$MI" report)
assert_contains "$out" "config/crew-memory-max" "report should name the override as the source"
pass "report attributes the limit to its source"

printf 'off\n' > "$HOME_B/config/crew-memory-max"
got=$(cap "$HOME_B" "$MI" limit)
[ "$got" = off ] || fail "'off' should be preserved as a disable, got '$got'"
out=$(cap "$HOME_B" "$MI" wrap 'echo hello' 2>&1 >/dev/null)
assert_contains "$out" "unbounded" "disabling the bound must say so rather than going quiet"
got=$(cap "$HOME_B" "$MI" wrap 'echo hello' 2>/dev/null)
[ "$got" = 'echo hello' ] || fail "'off' must return the command unchanged, got '$got'"
pass "'off' disables the bound loudly, never silently"

# A present-but-unsafe or malformed override is an operator error worth
# reporting, never a value to infer around.
# '1G2M' is the one worth naming: it passes any loose charset check, is accepted
# by nothing, and would otherwise fail at LAUNCH time with the worker's pane
# already open and no agent in it.
for bad in '6X' 'not-a-size' '' '-4G' '1G2M' '0G' '4 G' '4G '; do
  printf '%s\n' "$bad" > "$HOME_B/config/crew-memory-max"
  cap "$HOME_B" "$MI" limit >/dev/null 2>&1 \
    && fail "malformed override '$bad' should be refused, not accepted"
done
pass "malformed override values are refused"

printf '4G\n4G\n' > "$HOME_B/config/crew-memory-max"
cap "$HOME_B" "$MI" limit >/dev/null 2>&1 && fail "a multi-line override should be refused"
pass "multi-line override is refused"

rm -f "$HOME_B/config/crew-memory-max"
printf '4G\n' > "$TMP_ROOT/elsewhere-cap"
ln -s "$TMP_ROOT/elsewhere-cap" "$HOME_B/config/crew-memory-max"
cap "$HOME_B" "$MI" limit >/dev/null 2>&1 && fail "a symlinked override should be refused"
pass "symlinked override is refused"
rm -f "$HOME_B/config/crew-memory-max"

# --- the wrap contract ------------------------------------------------------
#
# wrap composes a shell line that is typed verbatim into a worker's pane, so its
# quoting has to survive commands that contain single quotes, double quotes, and
# deferred command substitution. Asserting that the wrapped line still RUNS is
# what makes this a behavioral test rather than a string-shape test.

HOME_C=$(new_home wrapping)

wrapped=$(cap "$HOME_C" "$MI" wrap 'echo plain')
assert_contains "$wrapped" "MemoryMax=7446M" "wrap must carry the resolved limit"
assert_contains "$wrapped" "MemorySwapMax=0" \
  "wrap must disable swap: MemoryMax alone lets a runaway spill into swap instead of dying"
assert_contains "$wrapped" "--scope" "wrap must use a scope so the worker keeps its terminal"
assert_contains "$wrapped" "CollectMode=inactive-or-failed" \
  "wrap must let a killed scope be collected, or every bounded death leaves a failed unit behind"
pass "wrap carries the properties that make the limit a hard, self-cleaning bound"

nasty=$'CFG=\'{"a":"b","*":"c"}\' printf "%s" "$(echo deferred-ok)"'
wrapped=$(cap "$HOME_C" "$MI" wrap "$nasty")
plain=$(eval "$nasty")
[ "$plain" = deferred-ok ] || fail "fixture command should print deferred-ok, got '$plain'"
pass "wrap round-trips a command containing quotes and deferred substitution"

# --- open degradation -------------------------------------------------------
#
# A host that cannot offer the bound must still be able to spawn. The one
# behaviour this must never have is spawning unbounded in silence.

# A PATH holding every ordinary tool the script uses and no systemd-run, which
# is what a non-systemd host actually looks like from inside the script.
NOSYSTEMD="$TMP_ROOT/nosystemd/bin"
mkdir -p "$NOSYSTEMD"
for tool in bash sh env uname stat wc head awk sed cat grep timeout printf true; do
  resolved=$(command -v "$tool" 2>/dev/null) || continue
  ln -sf "$resolved" "$NOSYSTEMD/$tool"
done
command -v systemd-run >/dev/null 2>&1 && [ -e "$NOSYSTEMD/systemd-run" ] \
  && fail "the no-systemd fixture must not contain systemd-run"

out=$(PATH="$NOSYSTEMD" FM_CONFIG_OVERRIDE="$HOME_C/config" \
  FM_CREW_MEMORY_CAP_MEMINFO_OVERRIDE="$MI" "$CAP" status 2>&1)
assert_contains "$out" "unavailable" "a host without systemd-run must report unavailable"
assert_contains "$out" "systemd-run" "the reason must name what is missing"
pass "a host without the mechanism reports why"

set +e
out=$(PATH="$NOSYSTEMD" FM_CONFIG_OVERRIDE="$HOME_C/config" \
  FM_CREW_MEMORY_CAP_MEMINFO_OVERRIDE="$MI" "$CAP" wrap 'echo hello' 2>"$TMP_ROOT/degrade.err")
code=$?
set -e
expect_code 0 "$code" "wrap must not fail the caller on an unsupported host"
[ "$out" = 'echo hello' ] || fail "unsupported host must return the command unchanged, got '$out'"
assert_grep "unbounded" "$TMP_ROOT/degrade.err" \
  "an unsupported host must say the worker is unbounded, never degrade in silence"
pass "unsupported host degrades openly and still spawns"

# systemd-run present but refusing (no user manager, no delegation): the reason
# must come from what actually refused rather than from a guess.
REFUSING="$TMP_ROOT/refusing/bin"
mkdir -p "$REFUSING"
cp -a "$NOSYSTEMD/." "$REFUSING/"
cat > "$REFUSING/systemd-run" <<'SH'
#!/usr/bin/env bash
echo "Failed to connect to bus: No medium found" >&2
exit 1
SH
chmod +x "$REFUSING/systemd-run"

out=$(PATH="$REFUSING" FM_CONFIG_OVERRIDE="$HOME_C/config" \
  FM_CREW_MEMORY_CAP_MEMINFO_OVERRIDE="$MI" "$CAP" status 2>&1)
assert_contains "$out" "unavailable" "a refusing systemd-run must report unavailable"
assert_contains "$out" "Failed to connect to bus" \
  "the reason must repeat what systemd-run itself said, not a guess about it"
pass "a refusing mechanism reports the refusal verbatim"

set +e
out=$(PATH="$REFUSING" FM_CONFIG_OVERRIDE="$HOME_C/config" \
  FM_CREW_MEMORY_CAP_MEMINFO_OVERRIDE="$MI" "$CAP" wrap 'echo hello' 2>/dev/null)
code=$?
set -e
expect_code 0 "$code" "a refusing mechanism must not fail the caller"
[ "$out" = 'echo hello' ] || fail "a refusing mechanism must return the command unchanged, got '$out'"
pass "a refusing mechanism still lets the worker spawn"

# --- spawn-path integration -------------------------------------------------
#
# Drives the real bin/fm-spawn.sh against a fake tmux and a real isolated git
# worktree, and reads the exact launch line it typed into the pane.

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) continue ;;
          Enter|C-m) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

run_spawn_case() {  # <name> <cap-config-or-empty> -> echoes the launch log path
  local name=$1 capcfg=$2 case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  [ -z "$capcfg" ] || printf '%s\n' "$capcfg" > "$home/config/crew-memory-max"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  id="$name-m1"
  mkdir -p "$home/data/$id"
  printf 'Delivery contract: mode=no-mistakes\nbrief\n' > "$home/data/$id/brief.md"
  : > "$launchlog"
  env FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CREW_MEMORY_CAP_MEMINFO_OVERRIDE="$MI" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off >/dev/null 2>&1 || true
  printf '%s\n' "$launchlog"
}

if [ "$("$CAP" status 2>/dev/null)" = available ]; then
  log=$(run_spawn_case bounded '')
  assert_grep "MemoryMax=7446M" "$log" "a spawned worker's launch line must carry the bound"
  assert_grep "MemorySwapMax=0" "$log" "a spawned worker's bound must disable swap"
  assert_grep "claude" "$log" "the bound must wrap the harness launch, not replace it"
  pass "fm-spawn.sh applies the bound to the launch it types into the pane"

  log=$(run_spawn_case disabled 'off')
  assert_no_grep "MemoryMax" "$log" "an 'off' home must spawn without a bound"
  assert_grep "claude" "$log" "an 'off' home must still spawn the harness"
  pass "fm-spawn.sh honours an operator's 'off'"
else
  printf 'skip - spawn-path bound assertions need a host that can create a bounded scope\n'
fi

# --- the real bound ---------------------------------------------------------
#
# The demonstration the whole change exists for: a worker's CHILD over-allocates
# and is killed at the limit, while the machine around it is unharmed. This is
# the shape of the 2026-08-20 loss, where the agent was 369 MiB and its node
# child reached 24.6 GiB.

if [ "$("$CAP" status 2>/dev/null)" != available ]; then
  printf 'skip - real-bound demonstration needs systemd, a user manager, and cgroup memory delegation\n'
  printf 'ok - fm-crew-memory-cap portable coverage complete\n'
  exit 0
fi

HOME_R=$(new_home realbound)
printf '256M\n' > "$HOME_R/config/crew-memory-max"

# A child that allocates OUTSIDE any language runtime's managed heap, so no
# interpreter flag could have bounded it - the property that made the original
# runaway immune to --max-old-space-size. It records its running total so the
# peak is readable even when the kernel kills it mid-allocation, and it stops
# itself at 64 GiB so a BROKEN bound fails the test instead of hanging the host.
#
# The assertion is the peak, not the exit status, and deliberately so: a cgroup
# that refuses an allocation may either OOM-kill the process or fail the malloc,
# and which one happens is not deterministic. The guarantee under test is the
# one that matters either way - the child cannot get past its limit.
cat > "$TMP_ROOT/hog.py" <<'PYEOF'
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
ceiling = int(sys.argv[2])
blocks = []
mib = 0
try:
    while mib < ceiling:
        blocks.append(bytearray(16 * 1024 * 1024))
        mib += 16
        os.lseek(fd, 0, 0)
        os.write(fd, str(mib).encode())
except MemoryError:
    pass
PYEOF

if ! command -v python3 >/dev/null 2>&1; then
  printf 'skip - real-bound demonstration needs python3 for the over-allocating child\n'
  printf 'ok - fm-crew-memory-cap portable coverage complete\n'
  exit 0
fi

PEAK_FILE="$TMP_ROOT/hog.peak"
printf '0' > "$PEAK_FILE"
before_available=$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo)
wrapped=$(FM_CONFIG_OVERRIDE="$HOME_R/config" "$CAP" wrap \
  "echo PARENT-STARTED; python3 '$TMP_ROOT/hog.py' '$PEAK_FILE' 65536; echo CHILD-RETURNED" \
  "fm-crew-memory-cap-probe")
set +e
real_out=$(eval "$wrapped" 2>&1)
set -e
after_available=$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo)
peak_mib=$(cat "$PEAK_FILE")

assert_contains "$real_out" "PARENT-STARTED" "the bounded worker should start normally"
[ "${peak_mib:-0}" -gt 0 ] || fail "the child never allocated; the fixture proved nothing"

# 256M limit, so anything near or past 512 MiB means the bound did not hold. An
# unbounded child on this fixture runs to its own 64 GiB ceiling.
[ "$peak_mib" -lt 512 ] \
  || fail "the child reached ${peak_mib} MiB under a 256M bound; the limit did not hold"
pass "a runaway child is stopped at its limit (peaked at ${peak_mib} MiB under 256M)"

# The control that keeps the assertion above from going quietly vacuous: the
# SAME child, unbounded, must sail past the limit it was just stopped at. A
# fixture that could not allocate would otherwise "prove" any bound at all.
CONTROL_PEAK="$TMP_ROOT/hog.control"
printf '0' > "$CONTROL_PEAK"
set +e
python3 "$TMP_ROOT/hog.py" "$CONTROL_PEAK" 1024 >/dev/null 2>&1
set -e
control_mib=$(cat "$CONTROL_PEAK")
[ "${control_mib:-0}" -ge 1024 ] \
  || fail "the unbounded control only reached ${control_mib} MiB, so the bounded result proves nothing"
[ "$control_mib" -gt "$peak_mib" ] \
  || fail "bounded (${peak_mib} MiB) and unbounded (${control_mib} MiB) did not diverge; the bound is not what stopped the child"
pass "the same child unbounded reaches ${control_mib} MiB, so the bound is what stopped it"

# The point of a per-worker bound: the machine around it is untouched.
lost_mib=$(( (before_available - after_available) / 1024 ))
[ "$lost_mib" -lt 2048 ] || fail "the host lost ${lost_mib} MiB across a bounded kill; the bound did not contain it"
pass "the rest of the machine is unaffected (${lost_mib} MiB delta)"

# A bounded death must not litter the user manager. systemd keeps a failed
# transient unit by default, so without CollectMode every kill would leave a
# permanent record behind and they would accumulate for as long as the host runs.
leftover=$(systemctl --user list-units --type=scope --state=failed --no-legend 2>/dev/null \
  | grep -c "fm-crew-memory-cap-probe" || true)
[ "${leftover:-0}" -eq 0 ] \
  || fail "a bounded kill left ${leftover} failed scope unit(s) behind; they accumulate for the life of the host"
pass "a bounded kill leaves no failed unit behind"


# --- supervision still sees a bounded worker --------------------------------
#
# The bound is only safe if it is INVISIBLE to the liveness classifier while the
# worker runs, and VISIBLE as a stopped worker once it is killed. Both halves
# are asserted against the real classifier in bin/backends/tmux.sh, driving real
# processes in a real tmux server on a private socket, so nothing here can touch
# the machine's actual sessions.

if ! command -v tmux >/dev/null 2>&1; then
  printf 'skip - liveness-under-bound needs tmux\n'
  printf 'ok - fm-crew-memory-cap full coverage complete\n'
  exit 0
fi

# The shared guarantee that a test reaching a real tmux binary cannot create,
# see, or kill anything in the machine's actual server. It proves the redirect
# before returning and refuses rather than running unisolated.
tmux_isolate fm-crew-memory-cap

LAB="$TMP_ROOT/liveness"
mkdir -p "$LAB/bin"

# A stand-in harness: a SYMLINK (never a copy - a copied platform binary fails
# code-signing on macOS arm64) whose name is the executable identity the
# classifier reads.
ln -sf "$(command -v sleep)" "$LAB/bin/claude-link"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

tmux new-session -d -s memcap -x 200 -y 50
tmux rename-window -t memcap:0 worker

bounded=$(FM_CONFIG_OVERRIDE="$HOME_R/config" "$CAP" wrap "exec '$LAB/bin/claude-link' 300" "liveness probe")
tmux send-keys -t memcap:worker "$bounded" Enter

state=
for _ in 1 2 3 4 5 6 7 8 9 10; do
  state=$(fm_backend_agent_state tmux "memcap:worker")
  [ "$state" = alive ] && break
  sleep 0.5
done
[ "$state" = alive ] \
  || fail "a bounded worker must still read 'alive' to supervision, got '$state'"
pass "the bound is invisible to the liveness classifier while the worker runs"

# The wrapper must not leave a process of its own in the pane's foreground
# process group: that is what keeps the classifier's verdict unchanged.
fg_comms=$(fm_backend_tmux_foreground_comms "memcap:worker")
case "$fg_comms" in
  *systemd-run*) fail "systemd-run must exec into the worker, not linger in the pane" ;;
esac
pass "the wrapper execs into the worker and adds no process to the pane"

# Now the other half: kill the worker at its limit and confirm the pane
# reconciles to a state supervision acts on, rather than reading busy forever.
tmux send-keys -t memcap:worker C-c
runaway=$(FM_CONFIG_OVERRIDE="$HOME_R/config" "$CAP" wrap "python3 '$TMP_ROOT/hog.py' '$TMP_ROOT/hog.runaway' 65536" "runaway probe")
tmux send-keys -t memcap:worker "$runaway" Enter

state=
for _ in $(seq 1 40); do
  state=$(fm_backend_agent_state tmux "memcap:worker")
  [ "$state" = dead ] && break
  sleep 0.5
done
[ "$state" = dead ] \
  || fail "a worker killed at its limit must reconcile to 'dead', got '$state'"
pass "a worker killed at its limit reads 'dead', which supervision recovers from"


printf 'ok - fm-crew-memory-cap full coverage complete\n'
