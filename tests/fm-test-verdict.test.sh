#!/usr/bin/env bash
# tests/fm-test-verdict.test.sh - behavior tests for what makes the suite's
# verdict readable: tool identity (bin/fm-tool-identity-lib.sh), named per-case
# dependency skips (tests/require.sh), and the known-failing register with its
# ratchet (bin/fm-test-quarantine.sh, tests/quarantine.tsv).
#
# The load-bearing case in this file is
# test_a_new_failure_still_fails_the_run: everything else here makes failures
# quieter, and that one proves the quiet did not become silence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-verdict)
RUNNER="$ROOT/bin/fm-test-run.sh"
# Absolute, because one case below deliberately runs with an EMPTY PATH to make a
# tool genuinely absent, and would otherwise not find a shell at all.
BASH_BIN=$(command -v bash)
QUARANTINE="$ROOT/bin/fm-test-quarantine.sh"

# --- fixtures ---------------------------------------------------------------

# A throwaway executable on PATH answering --help with <help>. This is how a
# name collision is simulated without needing the colliding tool installed.
fake_tool() {  # <dir> <name> <help-text>
  local dir=$1 name=$2 help=$3
  mkdir -p "$dir"
  cat > "$dir/$name" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --help ]; then
  cat <<'HELP'
$help
HELP
  exit 0
fi
exit 0
SH
  chmod +x "$dir/$name"
  printf '%s\n' "$dir"
}

# A test script the runner can execute, sourcing the real tests/lib.sh so it has
# the same fail/pass/skip primitives as any other test in the suite.
write_test_script() {  # <path> <body>
  local path=$1 body=$2
  mkdir -p "$(dirname "$path")"
  {
    printf '#!/usr/bin/env bash\nset -u\n'
    printf '. "%s/tests/lib.sh"\n' "$ROOT"
    printf '%s\n' "$body"
  } > "$path"
  chmod +x "$path"
}

# --- tool identity ----------------------------------------------------------

test_identity_rejects_the_gnome_screen_reader() {
  local case_dir fakebin rc reason
  case_dir="$TMP_ROOT/identity-gnome"
  # The real /usr/bin/orca help, trimmed to the parts that identify it.
  fakebin=$(fake_tool "$case_dir/bin" orca \
'Usage: orca [-h] [-v] [-r] [-s] [-l] [-e OPTION] [-d OPTION] [-p NAME]

Optional arguments:
  -r, --replace                Replace a currently running instance of this
                               screen reader
  --speech-system NAME         Speech system

Report bugs on https://gitlab.gnome.org/GNOME/orca/-/issues.')

  rc=0
  PATH="$fakebin:$PATH" bash -c \
    '. "$0/bin/fm-tool-identity-lib.sh"; fm_tool_identify orca' "$ROOT" || rc=$?
  [ "$rc" -eq 2 ] \
    || fail "GNOME's screen reader must be reported present-but-not-orca (rc 2), got rc $rc"

  reason=$(PATH="$fakebin:$PATH" bash -c \
    '. "$0/bin/fm-tool-identity-lib.sh"; fm_tool_identity_reason orca' "$ROOT")
  assert_contains "$reason" "screen reader" \
    "the reason must name what was found instead, not just say 'not installed'"
  pass "tool identity: an executable named orca that is GNOME's screen reader is not the Orca CLI"
}

test_identity_accepts_the_real_orca_cli() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/identity-real"
  fakebin=$(fake_tool "$case_dir/bin" orca \
'Usage: orca <command>

Commands:
  status    report runtime readiness
  worktree  create and manage worktrees
  terminal  create, read, and write terminals')

  rc=0
  PATH="$fakebin:$PATH" bash -c \
    '. "$0/bin/fm-tool-identity-lib.sh"; fm_tool_identify orca' "$ROOT" || rc=$?
  [ "$rc" -eq 0 ] || fail "a CLI advertising Orca's own commands must identify, got rc $rc"
  pass "tool identity: the Orca CLI identifies itself through its own command surface"
}

test_identity_distinguishes_absent_from_impostor() {
  local case_dir empty_bin rc reason
  case_dir="$TMP_ROOT/identity-absent"
  empty_bin="$case_dir/bin"
  mkdir -p "$empty_bin"
  rc=0
  # shellcheck disable=SC2016  # $0 is the inner shell's argument, not this one's.
  PATH="$empty_bin" "$BASH_BIN" -c \
    '. "$0/bin/fm-tool-identity-lib.sh"; fm_tool_identify orca' "$ROOT" || rc=$?
  [ "$rc" -eq 1 ] || fail "an absent tool must be rc 1, distinct from an impostor's rc 2, got $rc"
  # shellcheck disable=SC2016  # $0 is the inner shell's argument, not this one's.
  reason=$(PATH="$empty_bin" "$BASH_BIN" -c \
    '. "$0/bin/fm-tool-identity-lib.sh"; fm_tool_identity_reason orca' "$ROOT")
  [ "$reason" = "orca is not installed" ] \
    || fail "absent tool reason should be plain, got: $reason"
  pass "tool identity: absent and impostor are different answers, not one 'missing'"
}

test_identity_probe_is_bounded_and_trust_can_override() {
  local case_dir fakebin rc started ended
  case_dir="$TMP_ROOT/identity-hang"
  mkdir -p "$case_dir/bin"
  # A tool whose --help never returns must not hang the suite. GNOME's orca does
  # exactly this for `orca status --json`, which is why the probe uses --help and
  # bounds it anyway.
  cat > "$case_dir/bin/orca" <<'SH'
#!/usr/bin/env bash
sleep 600
SH
  chmod +x "$case_dir/bin/orca"
  fakebin="$case_dir/bin"

  started=$(date +%s)
  rc=0
  PATH="$fakebin:$PATH" FM_TOOL_IDENTITY_TIMEOUT=1 bash -c \
    '. "$0/bin/fm-tool-identity-lib.sh"; fm_tool_identify orca' "$ROOT" || rc=$?
  ended=$(date +%s)
  [ "$rc" -eq 2 ] || fail "a probe that never returns must refuse, got rc $rc"
  [ $((ended - started)) -lt 30 ] \
    || fail "the identity probe was not bounded: it took $((ended - started))s"

  rc=0
  PATH="$fakebin:$PATH" FM_TOOL_IDENTITY_TRUST=orca bash -c \
    '. "$0/bin/fm-tool-identity-lib.sh"; fm_tool_identify orca' "$ROOT" || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "FM_TOOL_IDENTITY_TRUST must let an operator override a probe that misjudges a real tool, got rc $rc"
  pass "tool identity: the probe is bounded, and an operator can override it per tool"
}

test_bootstrap_reports_a_colliding_orca_as_missing() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/bootstrap-collision"
  mkdir -p "$case_dir/home/config" "$case_dir/bin"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' orca > "$case_dir/home/config/backend"
  fakebin=$(fake_tool "$case_dir/bin" orca 'a screen reader, --speech-system')
  # Everything else the universal toolchain needs, so orca is the only variable.
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi
  fm_fake_version_tool "$fakebin" lavish-axi FM_UNUSED_LAVISH 0.1.46
  fm_fake_version_tool "$fakebin" gh-axi FM_UNUSED_GH_AXI 0.1.29

  out=$(PATH="$fakebin:/usr/bin:/bin" FM_HOME="$case_dir/home" \
    FM_ROOT_OVERRIDE="$case_dir/home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null || true)
  assert_contains "$out" "MISSING: orca" \
    "bootstrap must report the Orca backend missing when the only orca on PATH is a different tool"
  pass "bootstrap: a name collision no longer reports the Orca backend as installed"
}

# --- named per-case skips ---------------------------------------------------

test_missing_dependency_skips_instead_of_failing() {
  local script out rc
  script="$TMP_ROOT/skip-run/tests/fake-missing.test.sh"
  write_test_script "$script" '
test_needs_tool() {
  fm_require_tool "the case that needs it" fm-definitely-not-installed || return 0
  fail "the case ran even though its dependency is absent"
}
test_needs_tool
pass "the rest of the file still runs"
'
  out=$(cd "$ROOT" && "$RUNNER" "$script" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "a missing dependency must not fail the run, got rc $rc: $out"
  assert_contains "$out" "the rest of the file still runs" \
    "skipping one case must not discard the rest of the file's coverage"
  assert_contains "$out" "FM_TEST_SKIP" "the run must report the skip in machine-readable form"
  assert_contains "$out" "fm-definitely-not-installed is not installed" \
    "the skip must name the SPECIFIC missing requirement"
  assert_contains "$out" "skipped_case=1" "the summary must count the skip"
  pass "skip: a missing dependency reports skipped, named, and counted - not failed"
}

test_the_same_case_runs_where_the_dependency_exists() {
  local script out rc fakebin
  fakebin=$(fake_tool "$TMP_ROOT/present/bin" fm-present-tool 'anything')
  script="$TMP_ROOT/present-run/tests/fake-present.test.sh"
  write_test_script "$script" '
test_needs_tool() {
  fm_require_tool "the case that needs it" fm-present-tool || return 0
  pass "the case ran for real because its dependency is present"
}
test_needs_tool
'
  out=$(cd "$ROOT" && PATH="$fakebin:$PATH" "$RUNNER" "$script" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "the case should pass where the dependency exists: $out"
  assert_contains "$out" "the case ran for real" \
    "the case must actually run where the dependency exists"
  assert_not_contains "$out" "FM_TEST_SKIP" "nothing should be skipped when the dependency is present"
  assert_contains "$out" "skipped_case=0" "the summary must report no skips"
  pass "skip: the same case runs and passes on a machine that has the dependency"
}

test_a_skip_is_never_silent() {
  local script out
  script="$TMP_ROOT/loud-run/tests/fake-loud.test.sh"
  write_test_script "$script" '
fm_require_tool "first case" fm-absent-one || true
fm_require_tool "second case" fm-absent-two || true
pass "done"
'
  out=$(cd "$ROOT" && "$RUNNER" "$script" 2>&1)
  assert_contains "$out" "fm-absent-one is not installed" "first skip must be named"
  assert_contains "$out" "fm-absent-two is not installed" "second skip must be named"
  assert_contains "$out" "skipped_case=2" "every skip must be counted, not just the first"
  pass "skip: each skip is counted and named, so nothing is skipped silently"
}

# --- the known-failing register ---------------------------------------------

test_a_recorded_failure_does_not_fail_the_run() {
  local script register out rc
  script="$TMP_ROOT/quarantined-run/tests/fake-known.test.sh"
  write_test_script "$script" '
fail "a known broken thing"
'
  register="$TMP_ROOT/quarantined-run/register.tsv"
  printf '%s\t%s\t2026-08-20\t2999-01-01\tstated reason\n' "$script" "a known broken thing" > "$register"

  out=$(cd "$ROOT" && FM_QUARANTINE_FILE="$register" FM_QUARANTINE_CEILING_OVERRIDE=1 "$RUNNER" "$script" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "a recorded known failure should not fail the run, got rc $rc: $out"
  assert_contains "$out" "FM_TEST_QUARANTINED" "an absorbed known failure must still be reported"
  assert_contains "$out" "quarantined=1" "the summary must count it"
  pass "quarantine: a recorded known failure is absorbed, counted, and named"
}

test_a_new_failure_still_fails_the_run() {
  local script register out rc
  # THE criterion this whole change is judged against: quieting known failures
  # must not quiet a new one, including inside a file that already has an entry.
  script="$TMP_ROOT/new-failure-run/tests/fake-new.test.sh"
  write_test_script "$script" '
fail "a brand new broken thing"
'
  register="$TMP_ROOT/new-failure-run/register.tsv"
  printf '%s\t%s\t2026-08-20\t2999-01-01\tstated reason\n' "$script" "a known broken thing" > "$register"

  out=$(cd "$ROOT" && FM_QUARANTINE_FILE="$register" FM_QUARANTINE_CEILING_OVERRIDE=1 "$RUNNER" "$script" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a NEW failure in a quarantined file must still fail the run: $out"
  assert_contains "$out" "a brand new broken thing" "the new failure must be visible"
  assert_not_contains "$out" "quarantined=1" "a new failure must not be counted as known"
  pass "quarantine: introducing a NEW failure still fails the suite"
}

test_a_near_miss_assertion_is_not_absorbed() {
  local script register out rc
  script="$TMP_ROOT/near-miss-run/tests/fake-near.test.sh"
  write_test_script "$script" '
fail "worker is idle after teardown"
'
  register="$TMP_ROOT/near-miss-run/register.tsv"
  printf '%s\t%s\t2026-08-20\t2999-01-01\tstated reason\n' "$script" "worker is idle" > "$register"

  out=$(cd "$ROOT" && FM_QUARANTINE_FILE="$register" FM_QUARANTINE_CEILING_OVERRIDE=1 "$RUNNER" "$script" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "an entry must not swallow a different assertion that merely starts the same way: $out"
  pass "quarantine: an entry matches its own assertion, not everything sharing its prefix"
}

test_appended_failure_detail_still_matches_its_entry() {
  local script register out rc
  script="$TMP_ROOT/detail-run/tests/fake-detail.test.sh"
  write_test_script "$script" '
assert_contains "abc" "zzz" "the thing is wrong"
'
  register="$TMP_ROOT/detail-run/register.tsv"
  printf '%s\t%s\t2026-08-20\t2999-01-01\tstated reason\n' "$script" "the thing is wrong" > "$register"

  out=$(cd "$ROOT" && FM_QUARANTINE_FILE="$register" FM_QUARANTINE_CEILING_OVERRIDE=1 "$RUNNER" "$script" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "an entry must still match when an assertion appends its own detail: $out"
  pass "quarantine: an entry matches even though assertions append detail to the message"
}

test_a_stale_entry_fails_the_run() {
  local script register out rc
  script="$TMP_ROOT/stale-run/tests/fake-fixed.test.sh"
  write_test_script "$script" '
pass "this used to fail and no longer does"
'
  register="$TMP_ROOT/stale-run/register.tsv"
  printf '%s\t%s\t2026-08-20\t2999-01-01\tstated reason\n' "$script" "a failure that got fixed" > "$register"

  out=$(cd "$ROOT" && FM_QUARANTINE_FILE="$register" FM_QUARANTINE_CEILING_OVERRIDE=1 "$RUNNER" "$script" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "a quarantined script that now passes must fail the run so the entry gets removed: $out"
  assert_contains "$out" "QUARANTINE_STALE" "the run must say which entry no longer describes reality"
  pass "quarantine: an entry that stopped reproducing fails the run, so the list shrinks"
}

test_a_fixed_assertion_retires_from_behind_a_broken_sibling() {
  local script register out rc
  # The case script-granular staleness cannot see: two entries, one of them
  # fixed. The file never goes green, so without assertion granularity the fixed
  # entry would stay on the list forever.
  script="$TMP_ROOT/partial-fix-run/tests/fake-partial.test.sh"
  write_test_script "$script" '
still_broken() { fail "this one still fails"; }
now_fixed() { pass "this one was fixed"; }
fm_test_case still_broken
fm_test_case now_fixed
'
  register="$TMP_ROOT/partial-fix-run/register.tsv"
  {
    printf '%s\t%s\t2026-08-20\t2999-01-01\tstated reason\n' "$script" "this one still fails"
    printf '%s\t%s\t2026-08-20\t2999-01-01\tstated reason\n' "$script" "a failure that got fixed"
  } > "$register"

  out=$(cd "$ROOT" && FM_QUARANTINE_FILE="$register" FM_QUARANTINE_CEILING_OVERRIDE=2 "$RUNNER" "$script" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "an entry that stopped failing must fail the run even while a sibling entry still fails: $out"
  assert_contains "$out" "a failure that got fixed" \
    "the run must name the entry that no longer describes reality"
  assert_not_contains "$out" 'no longer fails "this one still fails"' \
    "an entry that DID fail must not be reported as fixed"
  pass "quarantine: a fixed assertion retires even while a sibling entry in the same file still fails"
}

test_an_unreached_assertion_is_not_reported_as_fixed() {
  local script register out rc
  # The safety half, and the one that matters: when a file exits early, the cases
  # after that point never ran. Their entries must NOT be retired - reporting an
  # assertion "fixed" because it was never reached would discard a live known
  # failure, which is strictly worse than keeping a stale entry one run longer.
  script="$TMP_ROOT/unreached-run/tests/fake-unreached.test.sh"
  write_test_script "$script" '
fail "the file stops right here"
pass "never reached"
'
  register="$TMP_ROOT/unreached-run/register.tsv"
  {
    printf '%s\t%s\t2026-08-20\t2999-01-01\tstated reason\n' "$script" "the file stops right here"
    printf '%s\t%s\t2026-08-20\t2999-01-01\tstated reason\n' "$script" "a case that never got to run"
  } > "$register"

  out=$(cd "$ROOT" && FM_QUARANTINE_FILE="$register" FM_QUARANTINE_CEILING_OVERRIDE=2 "$RUNNER" "$script" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a file that stopped early must not be treated as proof its later cases pass: $out"
  assert_not_contains "$out" "a case that never got to run" \
    "an assertion whose case never ran must not be reported as fixed"
  pass "quarantine: an entry is retired only on proof its case ran, never on the silence of a file that stopped early"
}

test_the_register_cannot_grow_silently() {
  local register out rc ceiling i
  register="$TMP_ROOT/ratchet/register.tsv"
  mkdir -p "$TMP_ROOT/ratchet"
  # Two entries against a ceiling of one: exactly the shape of absorbing a new
  # known failure by appending a line and changing nothing else.
  ceiling=1
  : > "$register"
  i=0
  while [ "$i" -lt 2 ]; do
    printf 'tests/fm-test-verdict.test.sh\tentry %s\t2026-08-20\t2999-01-01\tstated reason\n' "$i" >> "$register"
    i=$((i + 1))
  done
  out=$(FM_QUARANTINE_FILE="$register" FM_QUARANTINE_CEILING_OVERRIDE="$ceiling" "$QUARANTINE" --check 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "the register must refuse to grow past its ceiling"
  assert_contains "$out" "QUARANTINE_GREW" "growth must be reported as growth"
  pass "ratchet: absorbing a new known failure needs a deliberate ceiling bump, not one appended line"
}

test_the_register_cannot_bank_slack() {
  local register out rc ceiling
  register="$TMP_ROOT/ratchet-slack/register.tsv"
  mkdir -p "$TMP_ROOT/ratchet-slack"
  ceiling=2
  printf 'tests/fm-test-verdict.test.sh\tonly one\t2026-08-20\t2999-01-01\tstated reason\n' > "$register"
  out=$(FM_QUARANTINE_FILE="$register" FM_QUARANTINE_CEILING_OVERRIDE="$ceiling" "$QUARANTINE" --check 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "removing an entry without lowering the ceiling must be reported"
  assert_contains "$out" "QUARANTINE_SLACK" "unused ceiling room must be reported"
  pass "ratchet: the ceiling cannot keep room banked for a future silent addition"
}

test_an_expired_entry_fails_the_run() {
  local register out rc ceiling
  ceiling=1
  register="$TMP_ROOT/expiry/register.tsv"
  mkdir -p "$TMP_ROOT/expiry"
  printf 'tests/fm-test-verdict.test.sh\tsomething\t2020-01-01\t2020-06-01\tstated reason\n' > "$register"
  out=$(FM_QUARANTINE_FILE="$register" FM_QUARANTINE_CEILING_OVERRIDE="$ceiling" "$QUARANTINE" --check 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "an entry past its review-by date must fail the check"
  assert_contains "$out" "QUARANTINE_EXPIRED" "expiry must name the entry that is overdue"
  pass "expiry: a quarantine entry cannot rot quietly into a permanent one"
}

test_an_entry_without_a_stated_reason_is_refused() {
  local register out rc ceiling
  ceiling=1
  register="$TMP_ROOT/no-reason/register.tsv"
  mkdir -p "$TMP_ROOT/no-reason"
  printf 'tests/fm-test-verdict.test.sh\tsomething\t2026-08-20\t2999-01-01\t\n' > "$register"
  out=$(FM_QUARANTINE_FILE="$register" FM_QUARANTINE_CEILING_OVERRIDE="$ceiling" "$QUARANTINE" --check 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "an entry with no stated reason must be refused"
  pass "quarantine: every entry must carry a reason someone can act on"
}

test_this_repos_register_is_valid() {
  "$QUARANTINE" --check >/dev/null 2>&1 \
    || fail "this repo's own quarantine register does not pass its check: $("$QUARANTINE" --check 2>&1)"
  pass "quarantine: the register committed in this repo is valid, in-date, and at its ceiling"
}

# --- containing one failure so it cannot eat a file --------------------------

test_one_failing_case_does_not_discard_the_rest() {
  local script out
  script="$TMP_ROOT/contain-run/tests/fake-contain.test.sh"
  write_test_script "$script" '
first() { fail "the first case is broken"; }
second() { pass "the second case still ran"; }
fm_test_case first
fm_test_case second
'
  out=$(cd "$ROOT" && "$RUNNER" "$script" 2>&1) || true
  assert_contains "$out" "the second case still ran" \
    "a contained failure must not take the rest of the file's coverage with it"
  assert_contains "$out" "the first case is broken" "the failure itself must still be reported"
  pass "containment: one failing case no longer ends the whole file"
}

test_a_contained_failure_still_fails_the_file() {
  local script rc
  script="$TMP_ROOT/contain-verdict/tests/fake-verdict.test.sh"
  write_test_script "$script" '
first() { fail "still broken"; }
second() { pass "and this ran"; }
fm_test_case first
fm_test_case second
'
  rc=0
  bash "$script" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "a file using fm_test_case must still exit non-zero when a case failed"
  pass "containment: a file cannot opt in to containment and then report a green verdict"
}

test_identity_rejects_the_gnome_screen_reader
test_identity_accepts_the_real_orca_cli
test_identity_distinguishes_absent_from_impostor
test_identity_probe_is_bounded_and_trust_can_override
test_bootstrap_reports_a_colliding_orca_as_missing
test_missing_dependency_skips_instead_of_failing
test_the_same_case_runs_where_the_dependency_exists
test_a_skip_is_never_silent
test_a_recorded_failure_does_not_fail_the_run
test_a_new_failure_still_fails_the_run
test_a_near_miss_assertion_is_not_absorbed
test_appended_failure_detail_still_matches_its_entry
test_a_stale_entry_fails_the_run
test_a_fixed_assertion_retires_from_behind_a_broken_sibling
test_an_unreached_assertion_is_not_reported_as_fixed
test_the_register_cannot_grow_silently
test_the_register_cannot_bank_slack
test_an_expired_entry_fails_the_run
test_an_entry_without_a_stated_reason_is_refused
test_this_repos_register_is_valid
test_one_failing_case_does_not_discard_the_rest
test_a_contained_failure_still_fails_the_file

echo "# all fm-test-verdict tests passed"
