#!/usr/bin/env bash
# tests/require.sh - per-case dependency skips for firstmate behavior tests.
#
# Whole-file gating already exists: bin/fm-test-run.sh counts a script whose
# FIRST output line is "skip: <reason>" as a gate skip. That shape is right only
# when the ENTIRE file needs the dependency. Most missing-dependency failures are
# one assertion inside a file that otherwise has real coverage to give, and
# failing that file both throws the coverage away and reports a defect that is
# not one.
#
# Two rules this file exists to enforce:
#
# 1. A skip is never silent. On a machine where the dependency DOES exist the
#    same assertion runs for real, so a quiet skip would hide a genuine
#    regression behind an environment difference. Every skip prints one
#    machine-readable line and bin/fm-test-run.sh counts and reprints all of them
#    in the run summary.
#
# 2. Absence is DETECTED, never listed. There is no registry of test names
#    allowed to skip, because such a list stops tracking reality the moment the
#    environment changes and becomes a silence list. The only input is a live
#    check of the specific requirement, and the reason names that requirement
#    rather than saying "unsupported".
#
# Output contract, stdout, one line per skip (bin/fm-test-run.sh parses it):
#
#   skip - <case>: <specific missing requirement>
#
# It cannot collide with the whole-file gate: that one matches "skip:" on the
# first line only, and this one never uses a colon after "skip".
#
# API:
#   fm_test_skip <case> <reason>            print the marker; always returns 0
#   fm_require_tool <case> <tool>           0 = run, 1 = skipped (identity-checked)
#   fm_require <case> <reason> <cmd...>     0 = run, 1 = skipped when <cmd> fails
#
# Every caller reads as a guard on the case it protects:
#   fm_require_tool 'ci.yml YAML parse' ruby || return 0

if [ -n "${FM_TEST_REQUIRE_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_REQUIRE_SOURCED=1

# Presence is decided through the identity probe, not `command -v`: a name on
# PATH is not the tool. bin/fm-tool-identity-lib.sh owns that distinction and
# supplies the reason text, so a collision is reported as the collision it is.
# shellcheck source=bin/fm-tool-identity-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/fm-tool-identity-lib.sh"

fm_test_skip() {  # <case> <reason>
  printf 'skip - %s: %s\n' "$1" "$2"
  return 0
}

# 0 when <tool> is present AND identified, so the case should run.
# 1 after printing a skip naming what is actually missing.
fm_require_tool() {  # <case> <tool>
  local case_name=$1 tool=$2 reason
  if reason=$(fm_tool_identity_reason "$tool"); then
    fm_test_skip "$case_name" "$reason"
    return 1
  fi
  return 0
}

# Generic form for a requirement that is not a tool on PATH - a reachable host, a
# kernel behavior, a credential. <reason> must name the requirement precisely
# enough that a reader never has to wonder what did not run.
fm_require() {  # <case> <reason> <cmd> [args...]
  local case_name=$1 reason=$2
  shift 2
  if "$@" >/dev/null 2>&1; then
    return 0
  fi
  fm_test_skip "$case_name" "$reason"
  return 1
}

# --- keeping one known failure from eating a whole file --------------------
#
# fail() exits, so the FIRST failing assertion ends the file and every case after
# it silently never runs. That is tolerable while all failures are defects to fix
# now, and corrosive once a file carries a recorded known failure: the known one
# fails first, and a dozen real cases behind it stop being coverage at all.
#
# fm_test_case runs one case in a subshell, so a failure inside it is contained.
# The file's exit status still reflects it: the first call installs an EXIT trap
# that keeps tests/lib.sh's cleanup and adds the verdict, so a file cannot opt in
# and then report success by forgetting to check. Opt in per file by calling
# cases as `fm_test_case test_thing` instead of `test_thing`.
FM_TEST_CASE_FAILED=0

# Printed once, by the trap, when the file reached its own end with every case
# dispatched. bin/fm-test-run.sh needs that proof to retire a known-failing entry
# whose assertion has quietly started passing while a sibling entry in the same
# file still fails: without it, staleness can only be seen when a whole file goes
# green, and a fixed assertion sitting behind a still-broken one would stay on the
# list forever. That is the exact way such lists become permanent.
FM_TEST_CASES_COMPLETE_MARKER='# fm-test-cases-complete'

fm_test_case() {  # <case-fn> [args...]
  if [ -z "${FM_TEST_CASE_TRAP_ARMED:-}" ]; then
    FM_TEST_CASE_TRAP_ARMED=1
    trap 'fm_test_case_exit $?' EXIT
  fi
  ( "$@" ) || FM_TEST_CASE_FAILED=1
}

# The marker is claimed only when the pending exit status is 0, which is the one
# state that proves the file ran off its own end. An uncontained fail() exits
# non-zero from the body, as does a stray error under set -u, and in both cases
# the cases after it never ran - so a marker printed there would tell the runner
# an assertion "passed" when it was never reached, and retire a live entry.
# Failing to claim the marker only costs a slower retirement; claiming it wrongly
# loses a real known failure, so the doubtful direction is silence.
fm_test_case_exit() {  # <pending-exit-status>
  local rc=$1
  fm_test_cleanup
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$FM_TEST_CASES_COMPLETE_MARKER"
  fi
  [ "${FM_TEST_CASE_FAILED:-0}" -eq 0 ] || exit 1
  exit "$rc"
}

# True only when an orphaned process is reparented to init (pid 1). A Linux
# session with a child subreaper - `systemd --user` on essentially every modern
# desktop - adopts orphans itself, so a test that needs the init handoff cannot
# observe it there. Checked by asking the kernel, never by guessing from the
# platform name.
fm_test_orphans_reparent_to_init() {
  local pid ppid i
  bash -c 'sleep 5 >/dev/null 2>&1 & echo $! > "$1"; exit 0' _ "${TMPDIR:-/tmp}/.fm-orphan-probe.$$" \
    >/dev/null 2>&1 || return 1
  pid=$(cat "${TMPDIR:-/tmp}/.fm-orphan-probe.$$" 2>/dev/null || true)
  rm -f "${TMPDIR:-/tmp}/.fm-orphan-probe.$$"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  i=0
  ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  while [ "$i" -lt 50 ] && [ -n "$ppid" ] && [ "$ppid" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  done
  kill "$pid" 2>/dev/null || true
  [ "$ppid" = 1 ]
}

# Drop a fake `orca` into <fakebin> that answers the identity probe the way the
# real Orca CLI does. A bare exit-0 stub no longer counts as installed, which is
# the entire point of the probe: GNOME's screen reader is also an executable
# named orca that exits 0.
fm_fake_orca_cli() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  printf 'Usage: orca <command>\n\nCommands:\n  status    report runtime readiness\n  worktree  create and manage worktrees\n  terminal  create, read, and write terminals\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/orca"
}
