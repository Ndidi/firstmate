#!/usr/bin/env bash
# Behavior tests for bin/fm-unowned-window-lib.sh - the detect-only report for
# `fm-*` windows no task in this home claims.
#
# The gap it closes: firstmate reconciles the fleet from state/<id>.meta, so a
# window no task owns does not appear in the fleet view at all. On 2026-08-19 the
# captain could see a leftover `fm-unfilled-ship` window and firstmate could not.
#
# This suite runs entirely on a private tmux server, which is not incidental: a
# test for a check that inspects live windows is exactly the test most likely to
# create one in the captain's session. See tests/tmux-test-safety.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/tmux-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/tmux-test-safety.sh"

LIB="$ROOT/bin/fm-unowned-window-lib.sh"
assert_present "$LIB" "bin/fm-unowned-window-lib.sh is missing"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
tmux_isolate_or_fail unowned-window

# shellcheck source=bin/fm-unowned-window-lib.sh
. "$LIB"

TMP_ROOT=$(fm_test_tmproot fm-unowned-window)
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"

# The private server already carries a `firstmate` session from tmux_isolate.
make_window() {  # <name>
  tmux new-window -d -t firstmate: -n "$1" || fail "could not create fixture window $1"
}

# The core case: a window matching fm-spawn.sh's naming that no meta claims.
test_unclaimed_window_is_reported() {
  local out
  make_window fm-leftover-task
  out=$(fm_unowned_windows "$STATE")
  assert_contains "$out" "firstmate:fm-leftover-task" \
    "an fm-* window claimed by no task was not reported"
  pass "unowned-window: a window no task claims is reported"
}

# A window a task DOES claim must never be reported, or every real crewmate
# would be flagged at session start and the check would be turned off.
test_claimed_window_is_not_reported() {
  local out
  make_window fm-real-task
  fm_write_meta "$STATE/real-task.meta" \
    'window=firstmate:fm-real-task' \
    'worktree=/nowhere' \
    'project=alpha'
  out=$(fm_unowned_windows "$STATE")
  assert_not_contains "$out" "firstmate:fm-real-task" \
    "a window a task record claims was wrongly reported as unowned"
  pass "unowned-window: a window a task claims is never reported"
}

# The captain's own windows are none of firstmate's business.
test_non_fm_windows_are_ignored() {
  local out
  make_window my-editor
  out=$(fm_unowned_windows "$STATE")
  assert_not_contains "$out" "my-editor" \
    "a window outside fm-spawn's naming was reported"
  pass "unowned-window: windows outside fm-* naming are ignored"
}

# Matching is on the full session:window target, so a same-named window in a
# different session is still unclaimed rather than absorbed by the first match.
test_same_name_in_another_session_is_still_unclaimed() {
  local out
  tmux new-session -d -s other -n placeholder || fail "could not create the second session"
  tmux new-window -d -t other: -n fm-real-task || fail "could not create the twin window"
  out=$(fm_unowned_windows "$STATE")
  assert_contains "$out" "other:fm-real-task" \
    "an identically-named window in another session was wrongly treated as claimed"
  assert_not_contains "$out" "firstmate:fm-real-task" \
    "the genuinely claimed window was reported alongside its twin"
  pass "unowned-window: matching is per session:window, not by window name alone"
}

# The report wrapper must state the uncertainty and must not propose remediation:
# an unrecognised window may be another firstmate home's live work.
test_report_is_informational_and_never_remediating() {
  local out
  out=$(fm_unowned_window_report "$STATE")
  assert_contains "$out" "BOOTSTRAP_INFO:" \
    "the report did not use the no-action BOOTSTRAP_INFO prefix"
  assert_contains "$out" "another firstmate home's live work" \
    "the report did not state that an unrecognised window may not be a leftover"
  assert_contains "$out" "nothing was touched" \
    "the report did not make clear that it took no action"
  for banned in 'kill-window' 'kill-session' 'tmux kill'; do
    assert_not_contains "$out" "$banned" \
      "the detect-only report handed over a destructive command"
  done
  pass "unowned-window: the report is informational and proposes no destructive action"
}

# An empty or absent state dir means every fm-* window is unclaimed - it must not
# error, and it must not silently report nothing either.
test_absent_state_dir_still_reports() {
  local out
  out=$(fm_unowned_windows "$TMP_ROOT/no-such-state")
  assert_contains "$out" "firstmate:fm-leftover-task" \
    "an absent state dir suppressed the report instead of reporting everything unclaimed"
  pass "unowned-window: an absent state directory reports rather than errors"
}

# A check that cannot run must stay silent rather than manufacture a finding.
# The interpreter is invoked by absolute path because the whole point is a PATH
# with no tmux on it, which is also a PATH with no `bash` on it.
test_absent_tmux_is_silent() {
  local out shim="$TMP_ROOT/no-tmux" sh
  mkdir -p "$shim"
  sh=$(command -v bash) || fail "no bash on PATH"
  out=$(PATH="$shim" "$sh" -c ". '$LIB'; fm_unowned_windows '$STATE'" 2>&1)
  [ -z "$out" ] || fail "the check spoke up with no tmux available (got: $out)"
  pass "unowned-window: silent when tmux is unavailable"
}

test_unclaimed_window_is_reported
test_claimed_window_is_not_reported
test_non_fm_windows_are_ignored
test_same_name_in_another_session_is_still_unclaimed
test_report_is_informational_and_never_remediating
test_absent_state_dir_still_reports
test_absent_tmux_is_silent
