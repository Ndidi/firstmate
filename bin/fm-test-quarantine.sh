#!/usr/bin/env bash
# fm-test-quarantine.sh - single owner of the known-failing test register.
#
# After a missing dependency skips (tests/require.sh) and a tool is identified
# rather than merely found (bin/fm-tool-identity-lib.sh), whatever still fails is
# a real, reproduced, pre-existing failure. Quarantine records those so the suite
# can fail on something NEW - which is the only property that makes its verdict
# worth reading.
#
# Register: tests/quarantine.tsv, tab-separated, one entry per line:
#
#   <script>\t<assertion>\t<recorded>\t<review-by>\t<reason>
#
#   script     repo-relative test file, e.g. tests/fm-secondmate-sync.test.sh
#   assertion  the exact text the test passes to fail(), matched literally
#   recorded   ISO date the entry was added
#   review-by  ISO date after which the suite FAILS on this entry
#   reason     the established cause, in one line
#
# ONLY A REPRODUCED FAILURE MAY BE RECORDED, and that is a deliberate refusal
# rather than an omission. An intermittent failure has no established cause yet,
# so recording one would be recording a guess. It would also break the staleness
# rule below, which is what makes the list shrink: an entry that passes half the
# time can never be shown stale, so it would live forever behind a green run.
# There is deliberately no `flaky` mode to put it in - a failure nobody can
# reproduce is unfinished triage, and the suite says so by staying red.
#
# Blank lines and #-comments are ignored.
#
# DESIGNING AGAINST THE OBVIOUS FAILURE MODE. Quarantine lists become permanent
# because nothing ever forces anyone to look at them again. Three devices, chosen
# because each one fails the suite rather than printing a warning nobody reads:
#
#   1. Expiry. Every entry carries review-by. Past it the suite fails until the
#      entry is either fixed away or deliberately re-dated with a fresh reason.
#      A dated entry cannot rot quietly, which is the whole problem.
#   2. A downward ratchet. FM_QUARANTINE_CEILING below must equal the entry
#      count exactly. Growing the register means editing this script as well as
#      the data, so absorbing a new failure is a visible, reviewable act rather
#      than one appended line. Shrinking it without lowering the ceiling also
#      fails, so slack can never be banked for a future silent addition.
#   3. Staleness. bin/fm-test-run.sh fails the run when a quarantined script
#      passes outright, because the entry no longer describes reality and is now
#      just noise. This is what makes the list shrink on its own.
#
# Expiry was chosen over the third option, a required owner, because this repo has
# one captain and a rotating fleet of workers: an owner field would name whoever
# happened to be on shift, and would still be true and still be ignored a year
# later. A name does not make anyone look again; a date the suite enforces does,
# and it is answerable by whoever is on shift when it fires.
#
# Usage:
#   fm-test-quarantine.sh --list
#   fm-test-quarantine.sh --count
#   fm-test-quarantine.sh --check                     validate register + ratchet + expiry
#   fm-test-quarantine.sh --match <script> <assertion>  exit 0 when quarantined
#   fm-test-quarantine.sh --scripts                   scripts with at least one entry
#   fm-test-quarantine.sh --assertions <script>       that script's recorded assertions
#   fm-test-quarantine.sh --tighten                   lower the ceiling to the entry count
#   fm-test-quarantine.sh -h | --help
#
# Overridable for tests only: FM_QUARANTINE_FILE, FM_QUARANTINE_TODAY.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The ratchet. Must equal the number of entries in the register. Raising it
# absorbs a new known failure and needs a reason stated in the entry itself.
# Raised 2 -> 3 on 2026-08-21 for tests/fm-secondmate-harness.test.sh's fixed
# 2-second pointer-delivery deadline, reproduced 4/4 alone and on clean main.
FM_QUARANTINE_CEILING=3

REGISTER=${FM_QUARANTINE_FILE:-$ROOT/tests/quarantine.tsv}

# A fixture register brings its own ceiling, so the ratchet can be exercised
# without editing this file. Deliberately honoured only alongside a non-default
# register: the committed one's ceiling can never be relaxed by an environment
# variable, which is the property that makes the ratchet worth having.
if [ -n "${FM_QUARANTINE_FILE:-}" ] && [ -n "${FM_QUARANTINE_CEILING_OVERRIDE:-}" ]; then
  FM_QUARANTINE_CEILING=$FM_QUARANTINE_CEILING_OVERRIDE
fi

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" >&2
}

die() {
  printf 'fm-test-quarantine: %s\n' "$*" >&2
  exit 2
}

today() {
  printf '%s\n' "${FM_QUARANTINE_TODAY:-$(date -u +%Y-%m-%d)}"
}

# Print every entry line with comments, blanks, and a trailing newline stripped.
entries() {
  [ -f "$REGISTER" ] || return 0
  awk 'NF && $0 !~ /^[[:space:]]*#/' "$REGISTER"
}

count_entries() {
  entries | wc -l | tr -d '[:space:]'
}

list_entries() {
  entries
}

scripts_with_entries() {
  entries | cut -f1 | sort -u
}

assertions_for_script() {  # <script>
  entries | awk -F'\t' -v s="$1" '$1 == s { print $2 }'
}

# Exit 0 when <script> has an entry matching the observed failure text.
#
# The observed text is a whole `not ok -` line, and failure messages carry their
# own detail appended to the end: assert_contains adds " (missing: ...)",
# expect_code adds ": expected exit ...", and hand-written messages add
# ", got: ...". So an entry matches when the observed text IS the assertion, or
# is the assertion followed by punctuation that introduces detail.
#
# A continuation into a WORD is a different failure and must not match: a
# quarantined "worker is idle" can never swallow a new "worker is idle after
# teardown". That is what keeps a new failure inside an already-quarantined file
# red, which is the whole point of recording entries at assertion granularity
# rather than per file.
match_entry() {  # <script> <observed>
  local script=$1 observed=$2
  entries | awk -F'\t' -v s="$script" -v o="$observed" '
    BEGIN { found = 0 }
    $1 != s { next }
    {
      a = $2
      if (o == a) { found = 1; next }
      if (length(o) > length(a) && substr(o, 1, length(a)) == a) {
        rest = substr(o, length(a) + 1)
        if (rest ~ /^ ?[:,;(]/) found = 1
      }
    }
    END { exit found ? 0 : 1 }'
}

check_register() {
  local rc=0 count now line script script_path assertion recorded review reason fields
  count=$(count_entries)
  now=$(today)

  if [ -f "$REGISTER" ]; then
    while IFS= read -r line; do
      fields=$(printf '%s' "$line" | awk -F'\t' '{ print NF }')
      if [ "$fields" -ne 5 ]; then
        printf 'QUARANTINE_INVALID: expected 5 tab-separated fields, got %s: %s\n' "$fields" "$line"
        rc=1
        continue
      fi
      IFS=$'\t' read -r script assertion recorded review reason <<EOF
$line
EOF
      # Committed entries are repo-relative; a fixture register may name an
      # absolute path, so resolve rather than assuming one shape.
      case "$script" in
        /*) script_path=$script ;;
        *) script_path="$ROOT/$script" ;;
      esac
      if [ ! -f "$script_path" ]; then
        printf 'QUARANTINE_STALE: %s no longer exists; remove its entry\n' "$script"
        rc=1
      fi
      case "$recorded" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        *) printf 'QUARANTINE_INVALID: recorded date is not ISO YYYY-MM-DD: %s\n' "$recorded"; rc=1 ;;
      esac
      case "$review" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        *) printf 'QUARANTINE_INVALID: review-by date is not ISO YYYY-MM-DD: %s\n' "$review"; rc=1 ;;
      esac
      [ -n "$assertion" ] || { printf 'QUARANTINE_INVALID: empty assertion for %s\n' "$script"; rc=1; }
      [ -n "$reason" ] || { printf 'QUARANTINE_INVALID: %s: %s has no stated reason\n' "$script" "$assertion"; rc=1; }
      # String comparison is exact for ISO dates and needs no date arithmetic,
      # so this behaves identically on GNU and BSD userlands.
      if [ -n "$review" ] && [ "$review" \< "$now" ]; then
        printf 'QUARANTINE_EXPIRED: %s: %s (review-by %s has passed; fix it or re-date it with a fresh reason)\n' \
          "$script" "$assertion" "$review"
        rc=1
      fi
    done <<EOF
$(entries)
EOF
  fi

  if [ "$count" -gt "$FM_QUARANTINE_CEILING" ]; then
    printf 'QUARANTINE_GREW: %s entries exceed the ceiling of %s; a new known failure needs a stated reason and a deliberate ceiling bump in bin/fm-test-quarantine.sh\n' \
      "$count" "$FM_QUARANTINE_CEILING"
    rc=1
  elif [ "$count" -lt "$FM_QUARANTINE_CEILING" ]; then
    printf 'QUARANTINE_SLACK: %s entries below the ceiling of %s; lower the ceiling (bin/fm-test-quarantine.sh --tighten) so the ratchet cannot bank room for a silent addition\n' \
      "$count" "$FM_QUARANTINE_CEILING"
    rc=1
  fi

  return "$rc"
}

tighten() {
  local count
  count=$(count_entries)
  [ "$count" -le "$FM_QUARANTINE_CEILING" ] \
    || die "refusing to raise the ceiling: $count entries exceed $FM_QUARANTINE_CEILING; edit the ceiling by hand with the reason in the entry"
  perl -0pi -e "s/^FM_QUARANTINE_CEILING=\\d+\$/FM_QUARANTINE_CEILING=$count/m" "$ROOT/bin/fm-test-quarantine.sh"
  printf 'fm-test-quarantine: ceiling lowered to %s\n' "$count" >&2
}

[ "$#" -gt 0 ] || { usage; exit 2; }

case "$1" in
  --list) list_entries ;;
  --count) count_entries ;;
  --scripts) scripts_with_entries ;;
  --assertions)
    [ "$#" -eq 2 ] || die "--assertions needs <script>"
    assertions_for_script "$2"
    ;;
  --check) check_register ;;
  --tighten) tighten ;;
  --ceiling) printf '%s\n' "$FM_QUARANTINE_CEILING" ;;
  --match)
    [ "$#" -eq 3 ] || die "--match needs <script> <assertion>"
    match_entry "$2" "$3"
    ;;
  -h|--help) usage; exit 0 ;;
  *) die "unknown argument: $1" ;;
esac
