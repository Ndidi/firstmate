#!/usr/bin/env bash
# Behavior tests for tests/tmux-test-safety.sh - the guarantee that a test which
# reaches a real tmux binary cannot create, see, or kill anything in the
# machine's actual tmux server.
#
# This pins the fix for the 2026-08-19 leak: tests/fm-spawn-unfilled-brief.test.sh
# left an `fm-unfilled-ship` window in the captain's own live session, owned by no
# task, because the spawn guard it exercises was under development and the run
# carried on into the backend before dying at its first failed assertion.
#
# The cases deliberately drive the paths a leak actually escapes through - the
# failing run and the interrupted run - because cleanup that only holds on the
# happy path is not a fix. They also pin the fail-closed refusal, since isolation
# that silently did not take effect would put a test straight back in the
# captain's session, and the trap composition with tests/lib.sh, since a bare
# `trap ... EXIT` here would replace lib.sh's and leak every fixture temp dir.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SAFETY="$ROOT/tests/tmux-test-safety.sh"
assert_present "$SAFETY" "tests/tmux-test-safety.sh is missing"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
TMP_ROOT=$(fm_test_tmproot fm-tmux-test-safety)
SOCKET_DIR="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"

# A child script that sources lib.sh then the safety helper, exactly as a real
# test does, and then runs <body>. Run as a separate process so this test can
# observe the child's exit paths and leftovers from outside.
write_child() {  # <path> <body>
  cat > "$1" <<EOF
set -u
. "$ROOT/tests/lib.sh"
. "$SAFETY"
$2
EOF
}

# A window created under isolation must be invisible to the ambient server, even
# when it carries a name that would collide with a genuine task's window. This is
# the core guarantee: not "the test tidies up" but "the test cannot reach".
test_isolated_window_is_invisible_to_the_real_server() {
  local child="$TMP_ROOT/invisible.sh" out ambient collide='fm-collision-probe'
  write_child "$child" "
tmux_isolate_or_fail invisible
tmux new-window -d -t firstmate: -n $collide
printf 'socket=%s\n' \"\$FM_TMUX_ISOLATED_SOCKET\"
tmux_isolated_windows
"
  out=$(bash "$child" 2>&1) || fail "the isolated child failed: $out"
  assert_contains "$out" "firstmate:$collide" \
    "the window was not created on the private server at all; the test would prove nothing"

  ambient=$("$REAL_TMUX" list-windows -a -F '#{window_name}' 2>/dev/null || true)
  case "$ambient" in
    *"$collide"*) fail "an isolated test's window reached the REAL tmux server" ;;
  esac
  pass "tmux-test-safety: a window created under isolation never reaches the real server"
}

# The guarantee must not depend on the test passing. A child that creates a
# window and then dies non-zero is the exact shape of the 2026-08-19 leak.
test_failing_run_leaves_the_real_server_untouched() {
  local child="$TMP_ROOT/failing.sh" status ambient leaked='fm-leaked-by-failure'
  write_child "$child" "
tmux_isolate_or_fail failing
tmux new-window -d -t firstmate: -n $leaked
exit 1
"
  bash "$child" >/dev/null 2>&1
  status=$?
  [ "$status" -eq 1 ] || fail "expected the child to fail with 1, got $status"

  ambient=$("$REAL_TMUX" list-windows -a -F '#{window_name}' 2>/dev/null || true)
  case "$ambient" in
    *"$leaked"*) fail "a FAILING isolated test leaked a window into the real server" ;;
  esac
  pass "tmux-test-safety: a failing run leaves the real server untouched"
}

# ...and must not depend on the test finishing. An aborted run is when a leak is
# most likely, because the abort is exactly what skips a cleanup trap.
test_interrupted_run_leaves_the_real_server_untouched() {
  local child="$TMP_ROOT/interrupted.sh" socket_file pid i=0 ambient
  local leaked='fm-leaked-by-interrupt'
  socket_file="$TMP_ROOT/interrupt.socket"
  write_child "$child" "
tmux_isolate_or_fail interrupted
tmux new-window -d -t firstmate: -n $leaked
printf '%s\n' \"\$FM_TMUX_ISOLATED_SOCKET\" > '$socket_file'
sleep 30
"
  bash "$child" >/dev/null 2>&1 &
  pid=$!
  while [ ! -s "$socket_file" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$socket_file" ] || { kill "$pid" 2>/dev/null; fail "the child never reported its socket"; }

  kill -INT "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  ambient=$("$REAL_TMUX" list-windows -a -F '#{window_name}' 2>/dev/null || true)
  case "$ambient" in
    *"$leaked"*) fail "an INTERRUPTED isolated test leaked a window into the real server" ;;
  esac

  # The private server is torn down on the interrupt path too, so an aborted run
  # does not accumulate live servers across a suite.
  local socket
  socket=$(cat "$socket_file")
  "$REAL_TMUX" -L "$socket" list-sessions >/dev/null 2>&1 \
    && fail "the private server survived an interrupt"
  pass "tmux-test-safety: an interrupted run leaves the real server untouched and kills its private server"
}

# Isolation that silently did not take effect is worse than none, because the
# test would run against the captain's session believing it was safe. The probe
# check must refuse rather than proceed. Simulated with a tmux that ignores -L,
# so the private server and the ambient one are the same server.
test_isolation_that_does_not_take_effect_is_refused() {
  local child="$TMP_ROOT/refused.sh" shim="$TMP_ROOT/leaky-shim" out status
  local shared="fm-safety-shared-$$"
  mkdir -p "$shim"
  # Ignores -L <name> and always talks to one fixed server, so tmux_isolate's
  # probe becomes visible to the "ambient" call and isolation is provably absent.
  cat > "$shim/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -L ]; then shift 2; fi
exec "$REAL_TMUX" -L "$shared" "\$@"
SH
  chmod +x "$shim/tmux"

  write_child "$child" "
tmux_isolate_or_fail refused
printf 'REACHED_THE_BODY\n'
"
  out=$(PATH="$shim:$PATH" bash "$child" 2>&1)
  status=$?
  "$REAL_TMUX" -L "$shared" kill-server >/dev/null 2>&1 || true
  rm -f "$SOCKET_DIR/$shared"

  [ "$status" -ne 0 ] || fail "isolation that did not take effect was allowed to proceed"
  assert_not_contains "$out" "REACHED_THE_BODY" \
    "the test body ran despite isolation not being established"
  assert_contains "$out" "refusing to run against the real tmux server" \
    "the refusal did not say why it stopped"
  pass "tmux-test-safety: isolation that cannot be proven refuses rather than proceeding"
}

# tests/lib.sh installs `trap fm_test_cleanup EXIT` at source time. A bare
# `trap ... EXIT` in the safety helper would REPLACE it and silently leak every
# fixture temp dir, so the composed handler must still run lib.sh's cleanup.
test_lib_fixture_cleanup_still_runs_under_isolation() {
  local child="$TMP_ROOT/compose.sh" dir_file fixture
  dir_file="$TMP_ROOT/fixture-dir"
  write_child "$child" "
tmux_isolate_or_fail compose
d=\$(fm_test_tmproot fm-compose-probe)
printf '%s\n' \"\$d\" > '$dir_file'
"
  bash "$child" >/dev/null 2>&1 || fail "the composing child failed"
  fixture=$(cat "$dir_file")
  [ -n "$fixture" ] || fail "the child never reported its fixture dir"
  assert_absent "$fixture" \
    "the safety helper's EXIT trap replaced lib.sh's and leaked the fixture dir"
  pass "tmux-test-safety: lib.sh's fixture cleanup still runs when the helper is sourced"
}

# Sourcing twice must not clear an installed isolation - a test may pick the
# helper up both directly and through a behavior-area helper.
test_resourcing_preserves_installed_isolation() {
  local child="$TMP_ROOT/resource.sh" out
  write_child "$child" "
tmux_isolate_or_fail resource
before=\$FM_TMUX_ISOLATED_SOCKET
. '$SAFETY'
printf 'before=%s after=%s\n' \"\$before\" \"\$FM_TMUX_ISOLATED_SOCKET\"
"
  out=$(bash "$child" 2>&1) || fail "the re-sourcing child failed: $out"
  # The backreference is the whole assertion: the socket after re-sourcing must
  # be the SAME name, not merely non-empty.
  printf '%s\n' "$out" | grep -Eq 'before=(\S+) after=\1' \
    || fail "re-sourcing the helper cleared the installed isolation (got: $out)"
  pass "tmux-test-safety: re-sourcing preserves the installed isolation"
}

# The private socket must never be the default one, whatever the label.
test_private_socket_is_never_the_default() {
  local child="$TMP_ROOT/socket.sh" out
  write_child "$child" "
tmux_isolate_or_fail default
printf '%s\n' \"\$FM_TMUX_ISOLATED_SOCKET\"
"
  out=$(bash "$child" 2>&1) || fail "the socket-naming child failed: $out"
  [ -n "$out" ] || fail "no socket name was reported"
  [ "$out" != default ] || fail "isolation resolved to tmux's DEFAULT socket"
  case "$out" in
    fm-isolated-*) : ;;
    *) fail "unexpected private socket name: $out" ;;
  esac
  pass "tmux-test-safety: the private socket is never tmux's default"
}

# The label becomes a socket name, and a socket name becomes a filename. A label
# carrying path separators must not be able to aim the socket elsewhere.
test_label_cannot_escape_the_socket_directory() {
  local child="$TMP_ROOT/label.sh" out
  write_child "$child" "
tmux_isolate_or_fail '../../escape/attempt'
printf '%s\n' \"\$FM_TMUX_ISOLATED_SOCKET\"
"
  out=$(bash "$child" 2>&1) || fail "the awkward-label child failed: $out"
  assert_not_contains "$out" "/" "the socket name kept a path separator"
  assert_not_contains "$out" ".." "the socket name kept a parent-directory hop"
  pass "tmux-test-safety: a label cannot steer the socket out of its directory"
}

test_isolated_window_is_invisible_to_the_real_server
test_label_cannot_escape_the_socket_directory
test_failing_run_leaves_the_real_server_untouched
test_interrupted_run_leaves_the_real_server_untouched
test_isolation_that_does_not_take_effect_is_refused
test_lib_fixture_cleanup_still_runs_under_isolation
test_resourcing_preserves_installed_isolation
test_private_socket_is_never_the_default
