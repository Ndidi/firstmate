#!/usr/bin/env bash
# tests/fm-wait-helpers.test.sh - the shared wait-until-true primitives in
# tests/wait-helpers.sh.
#
# These helpers are load-bearing for the rest of the suite: every test that
# converted a fixed settle now trusts them to stop at the right moment AND to
# fail at the deadline. A wait helper that silently waits forever is worse than
# the sleep it replaced, because the suite hangs instead of reporting, so the
# cases below pin both halves - the fast success and the bounded, named failure.
#
# The helpers are exercised through a real subshell (fail() exits), which is the
# only way to observe the failure text a maintainer would actually read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-wait-helpers)

# Run a helper in a subshell and echo "<exit>|<combined output>", so a case can
# assert on the failure a real test author would see.
run_helper() {
  local out status
  out=$(FM_TEST_WAIT_TIMEOUT=1 bash -c '
    set -u
    . "$1"/tests/lib.sh
    shift
    "$@"
  ' _ "$ROOT" "$@" 2>&1)
  status=$?
  printf '%s|%s' "$status" "$out"
}

elapsed_ms() {  # <start-ns>
  local start=$1 now
  now=$(date +%s%N)
  printf '%s' $(((now - start) / 1000000))
}

test_wait_returns_as_soon_as_the_condition_holds() {
  local target start ms
  target="$TMP_ROOT/appears-late"
  ( sleep 0.4; : > "$target" ) &
  start=$(date +%s%N)
  fm_wait_file -t 20 "$target"
  ms=$(elapsed_ms "$start")
  wait
  # The point of the conversion: the wait ends when the thing happens. A fixed
  # settle sized for the 20s budget would have burned all 20. Allow generous
  # headroom over the 400ms producer so a loaded machine cannot fail this.
  [ "$ms" -lt 5000 ] \
    || fail "wait_file did not return promptly after the file appeared (${ms}ms for a 400ms producer)"
  pass "a wait ends when its condition holds, not when its budget expires"
}

test_unsatisfiable_condition_fails_naming_what_it_awaited() {
  local result status output
  result=$(run_helper fm_wait_until 'the harbour to freeze over' false)
  status=${result%%|*}
  output=${result#*|}
  # The whole point of a real timeout: a condition that can never hold must end
  # the test, not the machine's patience.
  expect_code 1 "$status" "an unsatisfiable wait must fail rather than hang"
  assert_contains "$output" 'timed out after 1s' 'the failure must say it hit the deadline'
  assert_contains "$output" 'the harbour to freeze over' \
    'the failure must name the condition that was awaited'
  pass "an unsatisfiable condition fails at the deadline naming what was awaited"
}

test_timeout_reports_what_it_saw_instead() {
  local file result output
  file="$TMP_ROOT/wrong-contents.log"
  printf 'watcher: FAILED - could not attach\n' > "$file"
  result=$(run_helper fm_wait_grep 'watcher: healthy' "$file")
  output=${result#*|}
  assert_contains "$output" 'watcher: healthy' 'the failure must name the awaited pattern'
  assert_contains "$output" 'saw instead' 'the failure must label the observed state'
  # Naming the condition alone leaves a maintainer guessing. The contents are
  # what turns "it did not appear" into "here is what was there instead".
  assert_contains "$output" 'watcher: FAILED - could not attach' \
    'the failure must report the file contents it actually observed'
  pass 'a timeout reports the state it observed, not just that it timed out'
}

test_missing_subject_is_reported_as_missing() {
  local result output
  result=$(run_helper fm_wait_grep 'anything' "$TMP_ROOT/never-created.log")
  output=${result#*|}
  # A absent file and a present-but-wrong file fail for different reasons, and a
  # maintainer needs to tell them apart from the failure line alone.
  assert_contains "$output" 'does not exist' \
    'a wait on a file that was never created must say so'
  pass 'waiting on a subject that never appeared reports it as absent'
}

test_nonempty_wait_does_not_accept_a_bare_created_file() {
  local file result status
  file="$TMP_ROOT/created-but-empty.log"
  : > "$file"
  result=$(run_helper fm_wait_nonempty "$file")
  status=${result%%|*}
  # `> file` makes the path exist instantly, so fm_wait_file would pass here
  # while the writer has not written anything. This is the trap fm_wait_nonempty
  # exists to close.
  expect_code 1 "$status" "an existing but empty file must not satisfy a non-empty wait"
  pass 'a non-empty wait rejects a file that exists but holds nothing'
}

test_probe_variant_reports_by_exit_code_without_failing() {
  local status
  set +e
  FM_TEST_WAIT_TIMEOUT=1 fm_wait_probe -t 1 false
  status=$?
  set -e
  set +e
  # The branching variant must stay silent and return, so a caller can handle
  # "did not happen" as an outcome rather than a test failure.
  expect_code 1 "$status" "fm_wait_probe must report a deadline by exit code"
  set -e
  pass 'the probe variant reports a deadline by exit code instead of failing'
}

test_pid_wait_ends_at_process_exit() {
  local pid start ms
  ( sleep 0.3 ) &
  pid=$!
  start=$(date +%s%N)
  fm_wait_pid_gone -t 20 "$pid"
  ms=$(elapsed_ms "$start")
  [ "$ms" -lt 5000 ] || fail "wait_pid_gone did not return promptly after exit (${ms}ms)"
  pass 'a process wait ends at the exit it was waiting for'
}

test_settle_refuses_an_unexplained_fixed_wait() {
  local result status
  result=$(run_helper fm_settle 0.01)
  status=${result%%|*}
  # fm_settle is the escape hatch for proving a negative, and it stays honest
  # only while every remaining fixed wait carries its reason. An unexplained one
  # is indistinguishable from the guesswork this whole change removes.
  expect_code 1 "$status" "fm_settle must refuse a fixed wait with no stated reason"
  pass 'a deliberate fixed settle refuses to run without a stated reason'
}

test_wait_returns_as_soon_as_the_condition_holds
test_unsatisfiable_condition_fails_naming_what_it_awaited
test_timeout_reports_what_it_saw_instead
test_missing_subject_is_reported_as_missing
test_nonempty_wait_does_not_accept_a_bare_created_file
test_probe_variant_reports_by_exit_code_without_failing
test_pid_wait_ends_at_process_exit
test_settle_refuses_an_unexplained_fixed_wait
