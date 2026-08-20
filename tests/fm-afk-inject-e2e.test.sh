#!/usr/bin/env bash
# tests/fm-afk-inject-e2e.test.sh - private-socket end-to-end test for the afk
# daemon's injection path. It covers three operator-visible injection contracts:
#
#   Scenario A (human-partial-input): a partial line is typed into the
#     supervisor pane with NO Enter, then an escalation fires. The daemon must
#     DEFER (not merge the digest into the human's text). After the pane goes
#     idle, the digest arrives as a separate, clean submission.
#
#   Scenario B (swallowed-Enter): the first Enter the daemon sends is dropped.
#     The daemon must retry Enter (NOT retype the digest) and deliver exactly
#     ONE clean submission: no concatenation, no duplicate.
#
#   Scenario C (normal digest): no human input and no swallowed Enter.
#     A captain-relevant status must deliver exactly ONE sentinel-prefixed,
#     single-line digest with no duplicate or spurious user submission.
#
# Isolation: all test tmux runs on a dedicated socket (tmux -L afk-e2e-<pid>).
# A tmux shim first on PATH redirects the daemon's bare `tmux` calls to the
# private socket. The daemon points at a throwaway state dir (FM_STATE_OVERRIDE)
# and the test pane (FM_SUPERVISOR_TARGET). Nothing touches the live fleet.
# FM_SUPERVISOR_BACKEND=tmux is passed explicitly (not left to auto-detection):
# this test's own process may itself be running inside herdr (HERDR_ENV=1 is
# inherited by every process herdr manages a pane for), which would otherwise
# leak into the spawned daemon subprocess and misdetect backend=herdr against
# what is actually a tmux pane on the private socket.
#
# Assert on submitted CONTENT (logged verbatim by the supervisor pane), not pane
# appearance - terminal line-wrapping looks like newlines but isn't.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

# Skip gracefully if tmux is not installed.
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="afk-e2e-$$"
STATE_DIR=
TMUX_SHIM_DIR=
LOG_FILE=
DAEMON_PID=
SUPERVISOR_PANE=
LOOP_SCRIPT=

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# Sourced AFTER fail() so the helpers report through this file's own cleanup.
# shellcheck source=tests/wait-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wait-helpers.sh"

cleanup_all() {
  if [ -n "${DAEMON_PID:-}" ]; then
    afk_exit "${STATE_DIR:-}" 2>/dev/null || true
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if [ -n "${SOCKET:-}" ] && [ -n "${REAL_TMUX:-}" ]; then
    "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  fi
  rm -rf "${TMUX_SHIM_DIR:-}" 2>/dev/null || true
  rm -rf "${STATE_DIR:-}" 2>/dev/null || true
}
trap cleanup_all EXIT

# --- setup ------------------------------------------------------------------

STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-e2e.XXXXXX")
mkdir -p "$STATE_DIR"
LOG_FILE="$STATE_DIR/submitted.log"
: > "$LOG_FILE"

# Source the daemon to get FM_INJECT_MARK, afk_enter, afk_exit.
# shellcheck source=/dev/null
. "$DAEMON"

# Private tmux server with a supervisor session.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s supervisor -x 200 -y 50
SUPERVISOR_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t supervisor '#{pane_id}')

# Supervisor pane loop: a small deterministic composer that logs each submitted
# line verbatim (hex + text + classification). It draws the in-progress input
# itself instead of relying on the terminal driver's canonical-mode echo, because
# tmux cursor placement for that echo varies across CI environments.
LOOP_SCRIPT="$STATE_DIR/supervisor-loop.sh"
cat > "$LOOP_SCRIPT" <<'LOOP'
#!/usr/bin/env bash
MARK=$'\xE2\x81\xA3'
LOG="$1"
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() {
  [ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

_buf=
# The drawn composer row carries a real agent prompt glyph, matching the
# production supervisor pane this daemon injects into: under the strict
# container-proof rule (captain decision blank-row-injection-posture) a bare
# unidentified row is never a safe injection target, so the fixture must
# render the shape the classifier positively proves - "❯ " when idle,
# "❯ <buffer>" while input is pending. The glyph is rendering only; it never
# enters the buffer, so submitted-content assertions are unchanged.
redraw() {
  printf '\r\033[K\xe2\x9d\xaf %s' "$_buf"
}
submit_line() {
  local _line=$_buf _c _hex
  if [ "${_line:0:1}" = "$MARK" ]; then
    _c="injection"
  else
    _c="user"
  fi
  _hex=$(printf '%s' "$_line" | od -An -tx1 | tr -d ' \n')
  printf '%s\t%s\t%s\n' "$_hex" "$_line" "$_c" >> "$LOG"
  _buf=
  printf '\r\033[K\n'
  redraw
}

redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then
    submit_line
    continue
  fi
  case "$_ch" in
    $'\r'|$'\n') submit_line ;;
    $'\177'|$'\b') _buf=${_buf%?}; redraw ;;
    *) _buf="${_buf}${_ch}"; redraw ;;
  esac
done
LOOP
chmod +x "$LOOP_SCRIPT"

# Start the loop in the supervisor pane.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" \
  "bash '$LOOP_SCRIPT' '$LOG_FILE'" Enter
# The loop draws its own prompt glyph on entry, so that glyph IS the "it is
# running" signal. A fixed second was a guess in both directions: too short on a
# cold machine (every later assertion then races a pane with no reader) and pure
# waste on a warm one.
# shellcheck disable=SC2016 # Deliberate: the inner shell (or the deferred --saw snippet) expands these, not this one.
fm_wait_until 'the supervisor loop to draw its prompt' \
  sh -c '"$1" -L "$2" capture-pane -p -t "$3" 2>/dev/null | grep -q "$4"' \
  _ "$REAL_TMUX" "$SOCKET" "$SUPERVISOR_PANE" "$(printf '\xe2\x9d\xaf')"

# tmux shim: redirects bare `tmux` to the private socket. Optionally swallows
# the first Enter (file-based flag) for Scenario B.
TMUX_SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-shim.XXXXXX")
cat > "$TMUX_SHIM_DIR/tmux" <<SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = "send-keys" ] && [ -f "$STATE_DIR/.swallow-enter" ]; then
  shift
  _args=()
  for _arg in "\$@"; do
    if [ "\$_arg" = "Enter" ] && [ -f "$STATE_DIR/.swallow-enter" ]; then
      rm -f "$STATE_DIR/.swallow-enter"
      continue
    fi
    _args+=("\$_arg")
  done
  exec "$REAL_TMUX" -L "$SOCKET" send-keys "\${_args[@]}"
fi
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SHIM
chmod +x "$TMUX_SHIM_DIR/tmux"

# Create a fake crewmate window (the watcher lists fm-* windows for stale
# detection). The pane is an inert shell - it just needs to exist.
"$REAL_TMUX" -L "$SOCKET" new-window -d -n fm-fake-c1 -t supervisor

start_daemon() {
  PATH="$TMUX_SHIM_DIR:$PATH" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_SUPERVISOR_TARGET="$SUPERVISOR_PANE" \
  FM_SUPERVISOR_BACKEND=tmux \
  FM_ESCALATE_BATCH_SECS=0 \
  FM_HOUSEKEEPING_TICK=1 \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 \
  FM_CHECK_INTERVAL=999999 \
  FM_INJECT_CONFIRM_SLEEP=0.3 \
  FM_INJECT_CONFIRM_RETRIES=5 \
  FM_STALE_ESCALATE_SECS=999999 \
  nohup "$DAEMON" >"$STATE_DIR/daemon.out" 2>"$STATE_DIR/daemon.err" &
  DAEMON_PID=$!
  # Wait for the daemon to start and acquire the lock.
  local i=0
  while [ "$i" -lt 30 ]; do
    [ -f "$STATE_DIR/.supervise-daemon.pid" ] && break
    sleep 0.2
    i=$((i + 1))
  done
  [ -f "$STATE_DIR/.supervise-daemon.pid" ] || {
    echo "daemon stderr:" >&2; cat "$STATE_DIR/daemon.err" >&2
    fail "daemon did not start (no pid file after 6s)"
  }
}

stop_daemon() {
  [ -n "${DAEMON_PID:-}" ] || return 0
  afk_exit "$STATE_DIR" 2>/dev/null || true
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=""
  sleep 1
}

reset_state() {
  # Clear daemon and watcher state for a fresh scenario.
  rm -f "$STATE_DIR"/*.status \
         "$STATE_DIR"/.subsuper-* \
         "$STATE_DIR"/.wake-queue* \
         "$STATE_DIR"/.watch.lock* \
         "$STATE_DIR"/.watcher-down* \
         "$STATE_DIR"/.last-* \
         "$STATE_DIR"/.hash-* \
         "$STATE_DIR"/.count-* \
         "$STATE_DIR"/.stale-* \
         "$STATE_DIR"/.seen-* \
         "$STATE_DIR"/.heartbeat-streak \
         "$STATE_DIR"/.swallow-enter \
         2>/dev/null || true
  : > "$LOG_FILE"
}

# --- pane_input_pending environment self-check ------------------------------
# Verify that pane_input_pending (which uses cursor_y + capture-pane) can detect
# typed text in this tmux environment. If it can't, the e2e cannot prove the
# operator-visible injection contracts it owns.

selfcheck_pane_input_pending() {
  local check_text="selfcheck-marker-12345"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" -l "$check_text"
  if wait_for_pane_input_pending; then
    # Detected - clean up the text and proceed.
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" Enter
    sleep 0.3
    return 0
  fi
  # Not detected - print diagnostics and fail.
  echo "pane_input_pending cannot detect typed text in this tmux environment" >&2
  local _cy _line
  _cy=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SUPERVISOR_PANE" '#{cursor_y}' 2>/dev/null)
  echo "  cursor_y=$_cy" >&2
  echo "  pane capture (first 10 lines):" >&2
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SUPERVISOR_PANE" 2>/dev/null | head -10 | sed 's/^/    /' >&2
  _line=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SUPERVISOR_PANE" 2>/dev/null | sed -n "$((_cy + 1))p")
  echo "  cursor line: '$_line'" >&2
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" Enter
  fail "pane_input_pending self-check failed"
}

# --- observing the daemon's own progress records -----------------------------
#
# Every wait below reads a record the daemon writes for itself, so the test stops
# when the daemon has provably reached the step under assertion rather than when
# a chosen number of seconds has passed. That difference is what lets the
# negative assertions ("the digest was NOT injected") mean something: the old
# fixed settles could not distinguish "the daemon decided to defer" from "the
# daemon had not looked yet", and would have passed either way.

# One housekeeping stamp value, or 0 before the first pass.
housekeep_stamp() {
  cat "$STATE_DIR/.subsuper-last-housekeep" 2>/dev/null || printf '0\n'
}

# Wait until a housekeeping pass has run start to finish after <since>. The
# daemon stamps the file BEFORE running the pass, so one stamp at or after
# <since> only proves a pass started; the NEXT stamp is what proves that pass
# returned. Both are needed to claim a flush was attempted and declined.
wait_for_completed_housekeeping() {  # <since-epoch>
  local since=$1 first
  # shellcheck disable=SC2016 # Deliberate: the inner shell (or the deferred --saw snippet) expands these, not this one.
  fm_wait_until --saw 'housekeep_stamp' \
    "a housekeeping pass to begin after ${since}" \
    sh -c '[ "$(cat "$1" 2>/dev/null || echo 0)" -ge "$2" ]' \
    _ "$STATE_DIR/.subsuper-last-housekeep" "$since"
  first=$(housekeep_stamp)
  # shellcheck disable=SC2016 # Deliberate: the inner shell (or the deferred --saw snippet) expands these, not this one.
  fm_wait_until --saw 'housekeep_stamp' \
    "the housekeeping pass stamped ${first} to complete" \
    sh -c '[ "$(cat "$1" 2>/dev/null || echo 0)" -gt "$2" ]' \
    _ "$STATE_DIR/.subsuper-last-housekeep" "$first"
}

# Wait until the daemon has buffered an escalation AND declined to deliver it.
# The buffer is the daemon's record that it saw the status; a complete
# housekeeping pass afterwards is its record that the flush ran and left the
# buffer in place.
wait_for_deferred_escalation() {
  local buffered_at
  fm_wait_nonempty "$STATE_DIR/.subsuper-escalations" \
    'the daemon to buffer the escalation it must defer'
  buffered_at=$(date +%s)
  wait_for_completed_housekeeping "$buffered_at"
}

# Wait until a digest reached the pane AND the daemon confirmed the submit.
# escalate_flush empties the buffer only after inject_msg confirms, so an empty
# buffer alongside a logged digest is the daemon's own "delivered" receipt.
wait_for_delivered_digest() {
  fm_wait_grep 'Supervisor escalate' "$LOG_FILE" \
    'the digest to reach the supervisor pane'
  # shellcheck disable=SC2016 # Deliberate: the inner shell (or the deferred --saw snippet) expands these, not this one.
  fm_wait_until --saw 'cat "$STATE_DIR/.subsuper-escalations" 2>/dev/null' \
    'the daemon to confirm the submit and clear its escalation buffer' \
    test '!' -s "$STATE_DIR/.subsuper-escalations"
}

# One housekeeping tick, spent proving a duplicate did NOT follow a delivered
# digest. "Exactly one" is the only claim here that no record can settle: a
# second submission would look identical to a first that has not happened yet,
# so the tick that could produce it has to be given the chance to fire.
DUPLICATE_WINDOW_SECS=2

wait_for_pane_input_pending() {
  local i=0
  while [ "$i" -lt 30 ]; do
    if PATH="$TMUX_SHIM_DIR:$PATH" pane_input_pending "$SUPERVISOR_PANE"; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

selfcheck_pane_input_pending

# --- Scenario A: human-partial-input ----------------------------------------

test_scenario_a() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon

  # Type partial text into the supervisor pane with NO Enter. This simulates the
  # captain returning and starting to type before afk has been cleared.
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" -l "human draft text"
  wait_for_pane_input_pending \
    || fail "Scenario A: human draft text did not become detectable as pending input"

  # Write a captain-relevant status to trigger a real escalation through the
  # real watcher child.
  echo "done: PR https://example.test/pr/100" > "$STATE_DIR/fake-c1.status"

  # Wait until the daemon has buffered the escalation and run a full flush pass
  # without delivering it. Six fixed seconds could not tell a deferral apart from
  # a daemon that simply had not reached the flush yet, so the assertion below
  # would have held for the wrong reason on a slow machine.
  wait_for_deferred_escalation

  # Assert: the digest was NOT injected while the pane had pending input.
  if grep -q 'Supervisor escalate' "$LOG_FILE"; then
    fail "Scenario A: daemon injected while pane had pending input (merged with human text?)"
  fi

  # Assert: no merged line (human text + digest) was submitted.
  if grep -q 'human draft text.*Supervisor escalate' "$LOG_FILE" 2>/dev/null || \
     grep -q 'Supervisor escalate.*human draft text' "$LOG_FILE" 2>/dev/null; then
    fail "Scenario A: human text and digest were merged into one line"
  fi

  # Now submit the human's text (Enter). The pane goes idle.
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" Enter

  # The loop logs the human line on submit, and the daemon retries its deferred
  # inject once the pane is idle. Both are observable, so wait for each rather
  # than for a settle long enough to cover the slower of the two.
  fm_wait_grep 'human draft text' "$LOG_FILE" \
    'the submitted human line to reach the log'
  wait_for_delivered_digest

  # Assert: human text and digest are on SEPARATE lines (never merged).
  if grep -q 'human draft text.*Supervisor escalate' "$LOG_FILE" || \
     grep -q 'Supervisor escalate.*human draft text' "$LOG_FILE"; then
    fail "Scenario A: human text and digest merged into one line (after idle)"
  fi

  # Assert: the human text line is classified as "user", not "injection".
  local human_line
  human_line=$(grep 'human draft text' "$LOG_FILE" | head -1)
  case "$human_line" in
    *user) ;;  # correct
    *) fail "Scenario A: human text misclassified (expected user): $human_line" ;;
  esac

  # Assert: the digest line is classified as "injection".
  local digest_line
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  case "$digest_line" in
    *injection) ;;  # correct
    *) fail "Scenario A: digest misclassified (expected injection): $digest_line" ;;
  esac

  stop_daemon
  pass "Scenario A: partial input defers injection; digest arrives clean after idle"
}

# --- Scenario B: swallowed-Enter --------------------------------------------

test_scenario_b() {
  reset_state
  afk_enter "$STATE_DIR"

  # Arm the swallow: the daemon's first Enter will be dropped by the shim.
  touch "$STATE_DIR/.swallow-enter"

  start_daemon

  # Write a captain-relevant status to trigger a real escalation.
  echo "done: PR https://example.test/pr/200" > "$STATE_DIR/fake-c1.status"

  # With the Enter swallowed, delivery only completes once the daemon retries.
  # Waiting for its own delivery receipt covers that retry however long it takes,
  # instead of guessing a settle wide enough to contain it.
  wait_for_delivered_digest
  fm_settle "$DUPLICATE_WINDOW_SECS" \
    'a duplicate submission could only arrive on a later housekeeping tick, and no record distinguishes "no duplicate" from "no duplicate yet"'

  # Assert: exactly ONE terminal-safe marker in the log (no duplicate, no loss).
  local marker_count
  marker_count=$(awk -F '\t' '{ hex=$1; count += gsub(/e281a3/, "", hex) } END { print count + 0 }' "$LOG_FILE")
  [ "$marker_count" -eq 1 ] \
    || fail "Scenario B: expected exactly 1 U+2063 marker, got $marker_count (duplicate or lost)"

  # Assert: the digest line is classified as "injection" and starts with the
  # terminal-safe sentinel marker (hex starts with e281a3).
  local digest_line digest_hex
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  digest_hex=$(printf '%s' "$digest_line" | cut -f1)
  case "$digest_hex" in
    e281a3*) ;;  # correct: starts with the terminal-safe sentinel marker
    *) fail "Scenario B: digest does not start with sentinel marker (hex: $digest_hex)" ;;
  esac

  # Assert: exactly ONE user-message line was submitted (no spurious empty lines
  # from extra Enters). The log should have exactly 1 injection line and 0 user
  # lines.
  local user_count
  user_count=$(grep -c $'\tuser$' "$LOG_FILE" || true)
  [ "$user_count" -eq 0 ] \
    || fail "Scenario B: expected 0 user lines, got $user_count (spurious Enter submitted empty line?)"

  stop_daemon
  pass "Scenario B: swallowed Enter produces exactly one clean digest"
}

# --- Scenario C: normal status, single clean digest -------------------------
# No human input, no swallowed Enter: a captain-relevant status must produce
# exactly ONE sentinel-prefixed, single-line digest, submitted once. This owns
# the marker + single-line + no-duplicate operator contract that the deleted
# fake-tmux units used to assert via internal send-keys counts.

test_scenario_c() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon

  echo "done: PR https://example.test/pr/300" > "$STATE_DIR/fake-c1.status"
  wait_for_delivered_digest
  fm_settle "$DUPLICATE_WINDOW_SECS" \
    'a duplicate submission could only arrive on a later housekeeping tick, and no record distinguishes "no duplicate" from "no duplicate yet"'

  # Exactly one terminal-safe marker in the submitted log (no duplicate, no loss).
  local marker_count
  marker_count=$(awk -F '\t' '{ hex=$1; count += gsub(/e281a3/, "", hex) } END { print count + 0 }' "$LOG_FILE")
  [ "$marker_count" -eq 1 ] \
    || fail "Scenario C: expected exactly 1 U+2063 marker, got $marker_count"

  # The digest is classified as an injection and starts with the sentinel byte.
  local digest_line digest_hex
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  case "$digest_line" in
    *injection) ;;
    *) fail "Scenario C: digest misclassified (expected injection): $digest_line" ;;
  esac
  digest_hex=$(printf '%s' "$digest_line" | cut -f1)
  case "$digest_hex" in
    e281a3*) ;;
    *) fail "Scenario C: digest does not start with sentinel marker (hex: $digest_hex)" ;;
  esac

  # The digest was submitted as ONE line (a multi-line digest would log >1 line),
  # and no spurious user-classified lines were submitted.
  local user_count
  user_count=$(grep -c $'\tuser$' "$LOG_FILE" || true)
  [ "$user_count" -eq 0 ] \
    || fail "Scenario C: expected 0 user lines, got $user_count (spurious submission?)"

  stop_daemon
  pass "Scenario C: a normal captain status injects exactly one clean single-line sentinel digest"
}

test_scenario_a
test_scenario_b
test_scenario_c

echo "all e2e injection tests passed"
