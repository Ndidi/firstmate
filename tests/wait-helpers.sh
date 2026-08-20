#!/usr/bin/env bash
# tests/wait-helpers.sh - wait until a stated condition holds, instead of
# sleeping a fixed guess.
#
# NOT to be confused with tests/wake-helpers.sh, which builds wake-queue and
# watcher fixtures. This file owns only the "how long do we wait" primitive.
#
# tests/lib.sh sources this file, so every test that already sources lib.sh gets
# these helpers with no extra source line.
#
# THE PROBLEM THESE REPLACE
#
# A fixed `sleep 0.5` between "start the thing" and "assert the thing happened"
# is wrong in both directions. Too short and the assertion is a coin flip
# decided by machine load; too long and every single run pays the worst case
# even though the condition usually holds in milliseconds. A suite full of them
# is both flaky and slow, and raising the sleep to cure the flake makes the
# slowness worse.
#
# A wait-until-true poll fixes both: it returns the instant the condition holds,
# and it only spends its whole budget on a run that was genuinely going to fail.
#
# THE RULES THAT MAKE A CONVERSION HONEST
#
# 1. The timeout must be generous but REAL. Waiting forever for something that
#    will never happen is not an improvement over a bad sleep - it converts a
#    fast wrong answer into a hung suite. Every helper here fails at the
#    deadline.
# 2. The failure must name the condition it was waiting for AND what it saw
#    instead. "timed out" alone tells a maintainer nothing; the wrappers below
#    each print the subject they actually inspected.
# 3. A NEGATIVE assertion ("X must not happen") cannot be a wait - there is no
#    moment at which "still has not happened" becomes true. Wait for a positive
#    proxy that proves the work under test reached its decision, then assert the
#    negative. Where no proxy exists, use fm_settle, which forces the reason to
#    be written down.
#
# Probes run in a command substitution so their output can be reported, so a
# probe cannot set variables in the calling shell. Pass a command, not a
# side-effecting function.

if [ -n "${FM_TEST_WAIT_HELPERS_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_WAIT_HELPERS_SOURCED=1

# fail() belongs to the sourcing suite: tests/lib.sh for most files, or the
# file's own reporter where one predates the library (a few e2e tests define
# fail so it can run their bespoke cleanup). Calls below resolve it at call
# time, so source order does not matter and neither definition is displaced.
# This fallback exists only so a caller with neither still reports rather than
# dying on an unbound command.
if ! declare -F fail >/dev/null 2>&1; then
  fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
  }
fi

# Default deadline for every helper here, in whole seconds. Generous enough that
# no healthy machine reaches it, short enough that a genuine hang is reported
# rather than waited out. Override per call with -t, or suite-wide with the
# environment variable (a deliberately slow environment, not a way to paper over
# a flake).
FM_TEST_WAIT_TIMEOUT=${FM_TEST_WAIT_TIMEOUT:-30}

# Poll cadence. Starts tight so a condition that holds almost immediately costs
# almost nothing, then backs off so a long wait does not spin a core.
FM_TEST_WAIT_POLL_MIN=${FM_TEST_WAIT_POLL_MIN:-0.01}
FM_TEST_WAIT_POLL_MAX=${FM_TEST_WAIT_POLL_MAX:-0.2}

# Bytes of diagnostic context reported on timeout, so a huge log cannot bury the
# failure line it is supposed to explain.
FM_TEST_WAIT_SAW_MAX=${FM_TEST_WAIT_SAW_MAX:-2000}

# Set FM_TEST_WAIT_TRACE=1 to have every wait report what it waited for and how
# long it actually took, one line per wait on stderr. That is the measurement
# that tells you whether a suite's wall-clock sits in its waits or somewhere
# else, which is exactly the question a fixed sleep makes unanswerable: a sleep
# always "takes" its nominal duration and never says whether it needed to.
FM_TEST_WAIT_TRACE=${FM_TEST_WAIT_TRACE:-0}

# fm_wait_trace <start-ns> <outcome> <what>
fm_wait_trace() {
  [ "$FM_TEST_WAIT_TRACE" = 1 ] || return 0
  awk -v a="$1" -v b="$(date +%s%N)" -v o="$2" -v w="$3" \
    'BEGIN { printf "FM_WAIT\t%.3f\t%s\t%s\n", (b - a) / 1000000000, o, w }' >&2
}

# fm_wait_probe [-t SECS] <cmd> [args...]
# Poll <cmd> until it exits 0. Returns 0 the moment it does, 1 at the deadline.
# Reports nothing and never fails the test: this is the variant for a caller
# that wants to branch on the outcome. Everything else here is built on it.
fm_wait_probe() {
  local timeout=$FM_TEST_WAIT_TIMEOUT deadline delay=$FM_TEST_WAIT_POLL_MIN
  while [ $# -gt 0 ]; do
    case "$1" in
      -t) timeout=$2; shift 2 ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 1
  local started
  started=$(date +%s%N)
  deadline=$(($(date +%s) + timeout))
  while :; do
    if FM_WAIT_LAST_OUTPUT=$("$@" 2>&1); then
      fm_wait_trace "$started" held "$1"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      fm_wait_trace "$started" timeout "$1"
      return 1
    fi
    sleep "$delay"
    delay=$(awk -v d="$delay" -v m="$FM_TEST_WAIT_POLL_MAX" \
      'BEGIN { d *= 2; if (d > m) d = m; printf "%.4f", d }')
  done
}

# fm_wait_until [-t SECS] [--saw <shell-snippet>] <what> <cmd> [args...]
# Poll <cmd> until it exits 0, or fail naming <what>. <what> is a noun phrase
# completing "timed out ... waiting for": "the arm log to appear", not "check
# the log".
#
# On timeout the report carries whatever the probe itself last printed. When the
# probe is silent (test -e, kill -0), pass --saw with a snippet that prints the
# state a maintainer would look at first; its output is reported under "saw".
fm_wait_until() {
  local timeout=$FM_TEST_WAIT_TIMEOUT saw='' what saw_out
  while [ $# -gt 0 ]; do
    case "$1" in
      -t) timeout=$2; shift 2 ;;
      --saw) saw=$2; shift 2 ;;
      *) break ;;
    esac
  done
  what=${1:-}
  shift || true
  [ -n "$what" ] || fail 'fm_wait_until: called with no condition description'
  [ $# -gt 0 ] || fail "fm_wait_until: no probe command for: $what"
  # Options bind before the description. An option that reaches this point was
  # written after it and would otherwise be run as part of the probe, turning a
  # real wait into one that can never succeed - and reporting the resulting
  # "command not found" as if the condition had failed.
  case "$1" in
    -t | --saw) fail "fm_wait_until: $1 must come before the condition description, not after it (condition: $what)" ;;
  esac
  fm_wait_probe -t "$timeout" "$@" && return 0
  saw_out=${FM_WAIT_LAST_OUTPUT:-}
  if [ -n "$saw" ]; then
    saw_out=$(eval "$saw" 2>&1)
  fi
  fm_wait_timeout "$timeout" "$what" "$saw_out"
}

# fm_wait_timeout <secs> <what> <saw>: the one timeout report, so every helper
# here fails in the same shape. Kept separate because the specific wrappers
# below each compute their own "saw" from the subject they know about.
fm_wait_timeout() {
  local timeout=$1 what=$2 saw=$3
  if [ -n "$saw" ]; then
    saw=$(printf '%s' "$saw" | head -c "$FM_TEST_WAIT_SAW_MAX")
    fail "timed out after ${timeout}s waiting for $what"$'\n'"--- saw instead ---"$'\n'"$saw"
  fi
  fail "timed out after ${timeout}s waiting for $what (nothing observed)"
}

# fm_wait_file [-t SECS] <path> [what]
# Wait for <path> to exist. On timeout, reports the parent directory listing, so
# a near miss (wrong name, wrong case, wrong directory) is visible immediately.
fm_wait_file() {
  local timeout=$FM_TEST_WAIT_TIMEOUT path what
  while [ $# -gt 0 ]; do
    case "$1" in
      -t) timeout=$2; shift 2 ;;
      *) break ;;
    esac
  done
  path=$1
  what=${2:-"$path to exist"}
  fm_wait_probe -t "$timeout" test -e "$path" && return 0
  fm_wait_timeout "$timeout" "$what" \
    "$(ls -la "$(dirname "$path")" 2>&1)"
}

# fm_wait_nonempty [-t SECS] <path> [what]
# Wait for <path> to exist AND hold at least one byte. Use this rather than
# fm_wait_file whenever the writer creates the file before filling it, which is
# the usual shape for a redirect: `> file` exists instantly and says nothing.
fm_wait_nonempty() {
  local timeout=$FM_TEST_WAIT_TIMEOUT path what
  while [ $# -gt 0 ]; do
    case "$1" in
      -t) timeout=$2; shift 2 ;;
      *) break ;;
    esac
  done
  path=$1
  what=${2:-"$path to become non-empty"}
  fm_wait_probe -t "$timeout" test -s "$path" && return 0
  fm_wait_timeout "$timeout" "$what" \
    "$([ -e "$path" ] && printf 'exists, %s bytes\n' "$(wc -c < "$path" 2>/dev/null || echo '?')" || printf 'does not exist\n')"
}

# fm_wait_grep [-t SECS] <fixed-pattern> <file> [what]
# Wait for a fixed-string match in <file>, matching assert_grep's semantics. On
# timeout it reports the file's actual contents, which is the most literal
# answer to "what did it see instead" this suite can give.
fm_wait_grep() {
  local timeout=$FM_TEST_WAIT_TIMEOUT pattern file what
  while [ $# -gt 0 ]; do
    case "$1" in
      -t) timeout=$2; shift 2 ;;
      *) break ;;
    esac
  done
  pattern=$1 file=$2
  what=${3:-"'$pattern' to appear in $file"}
  fm_wait_probe -t "$timeout" grep -qF -- "$pattern" "$file" && return 0
  fm_wait_timeout "$timeout" "$what" \
    "$([ -e "$file" ] && cat "$file" 2>&1 || printf '%s does not exist\n' "$file")"
}

# fm_wait_gone [-t SECS] <path> [what]
# Wait for <path> to disappear. This one IS a legitimate wait despite reading
# like a negative: removal is an event, so there is a moment at which it becomes
# true.
fm_wait_gone() {
  local timeout=$FM_TEST_WAIT_TIMEOUT path what
  while [ $# -gt 0 ]; do
    case "$1" in
      -t) timeout=$2; shift 2 ;;
      *) break ;;
    esac
  done
  path=$1
  what=${2:-"$path to be removed"}
  fm_wait_probe -t "$timeout" test '!' -e "$path" && return 0
  fm_wait_timeout "$timeout" "$what" "$(ls -la "$path" 2>&1)"
}

# fm_wait_pid_gone [-t SECS] <pid> [what]
# Wait for <pid> to stop being signalable. On timeout it reports the process
# row, so a wedge is distinguishable from a zombie at a glance.
fm_wait_pid_gone() {
  local timeout=$FM_TEST_WAIT_TIMEOUT pid what
  while [ $# -gt 0 ]; do
    case "$1" in
      -t) timeout=$2; shift 2 ;;
      *) break ;;
    esac
  done
  pid=$1
  what=${2:-"pid $pid to exit"}
  # shellcheck disable=SC2016 # Deliberate: the inner shell expands $1, not this one.
  fm_wait_probe -t "$timeout" sh -c '! kill -0 "$1" 2>/dev/null' _ "$pid" && return 0
  fm_wait_timeout "$timeout" "$what" \
    "$(ps -o pid=,stat=,command= -p "$pid" 2>&1)"
}

# fm_settle <secs> <why>
# A DELIBERATE fixed wait, for the one case a poll cannot cover: proving that
# something did NOT happen, where no positive proxy exists to wait for instead.
#
# Prefer a proxy every time one exists. A run-loop that touches a beacon each
# pass, a coordinator call that resolves with its own refusal reason, a log line
# written before the decision point - any of these turns "sleep and hope" into
# "wait until the code under test has provably decided", which is both faster
# and immune to machine load.
#
# The <why> argument is mandatory and is not decoration: it is what keeps the
# remaining fixed waits auditable, so a later reader can tell a considered
# settle apart from a guess nobody revisited.
fm_settle() {
  local secs=$1 why=${2:-}
  [ -n "$why" ] || fail "fm_settle: a fixed ${secs}s wait needs a stated reason no condition can be polled for"
  sleep "$secs"
}
