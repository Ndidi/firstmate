#!/usr/bin/env bash
# fm-capture-receipt.sh - the captain's named-receipt ledger.
#
# THE PROBLEM THIS SOLVES: the captain gives an instruction, firstmate files it,
# and the reply says "filed as its own work" or nothing at all. Storage worked;
# the captain still cannot name the thing, so to them it was never captured. A
# record whose identity the captain cannot quote back is indistinguishable from
# no record. AGENTS.md section 9 owns the obligation; this script owns its
# mechanics.
#
# WHY THE OBLIGATION IS DERIVED, NOT DECLARED. Nothing here asks firstmate to
# register a receipt, because "remember to declare it" is the same class of step
# that already failed. The ledger reads this home's own data/backlog.md and
# compares its identity set against a durable baseline: an identity that was not
# there before is a receipt the captain is owed, whoever filed it and however.
# That makes incurring the debt a side effect of filing, the same shape as
# fm-send.sh's --resolve-key closing a decision at answer time instead of hoping
# the worker appends a matching line later.
#
# WHAT THIS CANNOT DO. Captain-facing chat has no tool boundary, so no hook can
# confirm the sentence actually reached the captain. `delivered` is an
# attestation: running it while not having named the identity in the reply is a
# false statement to the captain, not a shortcut. The guard closes the much
# larger hole - a receipt that was never composed at all - and the durable record
# closes the one after it, a receipt lost to compaction or a restart.
#
# NO MTIME FAST PATH, DELIBERATELY. Skipping the parse when data/backlog.md
# looks unchanged is the obvious optimisation and it is wrong here: a filing
# whose write lands in the same whole second as the previous reconcile leaves
# mtime identical, so the receipt would be silently skipped until some later
# edit happened to move the clock. A missed receipt is the exact failure this
# script exists to prevent, and one awk pass over a backlog is negligible
# against a turn, so the check always reads the file. A home with no
# data/backlog.md still returns before doing anything at all.
#
# Usage:
#   fm-capture-receipt.sh pending
#       One block per owed receipt, each carrying the exact sentence to send.
#       Silent when nothing is owed. Read-only apart from reconciling the
#       ledger against the current backlog.
#
#   fm-capture-receipt.sh delivered <identity>...
#       Attest that the reply named these identities to the captain, clearing
#       them. An identity that is not owed is refused before anything is
#       cleared, so a mistyped or half-remembered name cannot silently retire
#       the wrong debt.
#
#   fm-capture-receipt.sh active
#       Silent probe. Exit 0 when this home owes at least one receipt, 1
#       otherwise. Reconciles first, so a session start is authoritative even
#       when the turn that filed the work never reached a turn end. Safe to call
#       unconditionally; used to gate the session-start subsection.
#
#   fm-capture-receipt.sh guard
#       Turn-end check, invoked by bin/fm-turnend-guard.sh inside an already
#       scoped primary home. Exit 2 with the owed sentences on stderr when a
#       receipt has never been surfaced; exit 0 otherwise.
#
#   fm-capture-receipt.sh reconcile
#       Fold the current backlog into the ledger without printing. Exposed for
#       tests and for establishing the baseline by hand.
#
# LOOP SAFETY. The guard blocks AT MOST ONCE PER IDENTITY, ever, recorded in the
# owed record itself rather than in a per-session counter. N newly filed items
# can therefore cost at most N forced continuations across the whole life of the
# home, and a firstmate that ignores the block cannot be wedged by it: the debt
# stays owed and resurfaces in the session-start digest instead. That bound is
# independent of every harness loop-guard field, so it holds identically on each
# supported primary. Marking the block happens BEFORE the block is emitted, and
# a failure to mark allows the turn end, so an unwritable state directory can
# never trap a session.
#
# SCOPE. Receipts are a MAIN-HOME concern. A secondmate never addresses the
# captain (AGENTS.md hard rule 4), and its backlog receives handed-off items it
# must not receipt, so bin/fm-turnend-guard.sh skips this check in a marked
# secondmate home. Nothing here reads or writes another home's state.
#
# STATE, all under state/capture-receipts/ (0700):
#   baseline         the backlog identity set at the last reconcile, one per line
#   owed/<identity>  one owed receipt: title=, first_seen=, blocked=
# The FIRST reconcile in a home establishes the baseline and owes nothing, so
# adopting this script never claims the whole existing backlog as unpaid debt.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

BACKLOG="$DATA/backlog.md"
LEDGER="$STATE/capture-receipts"
BASELINE="$LEDGER/baseline"
OWED="$LEDGER/owed"

TITLE_CAP=120
TAB=$(printf '\t')

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

# Identities are backlog slugs. Anything else is skipped rather than sanitized,
# because an identity is also a path component here and a permissive rule is how
# a crafted backlog line would reach outside the ledger.
receipt_valid_id() {  # <identity>
  case "${1:-}" in
    '' | . | ..) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Emit "<identity><TAB><title>" for every item line in the backlog, in file
# order, first occurrence wins. Accepts the tasks-axi markdown backend's
# "- [ ] <id> - <title>" and the manual backend's unchecked "- <id> - <title>",
# and anchors at column 0 so indented task bodies (which contain their own
# bullets) are never mistaken for items - the same anchoring
# bin/fm-session-start.sh's manual listing uses.
receipt_parse_backlog() {
  awk -v cap="$TITLE_CAP" '
    /^[-*][ \t]+/ {
      line = $0
      sub(/^[-*][ \t]+/, "", line)
      sub(/^\[[ xX]\][ \t]+/, "", line)
      idx = index(line, " - ")
      if (idx == 0) next
      id = substr(line, 1, idx - 1)
      if (id !~ /^[A-Za-z0-9._-]+$/) next
      if (id in seen) next
      seen[id] = 1
      title = substr(line, idx + 3)
      # Trailing "(kind: ship)" / "(since 2026-08-07)" metadata groups are the
      # backend rendering, not the captain-facing title.
      while (match(title, /[ \t]+\((since [^()]*|[A-Za-z_][A-Za-z0-9_ -]*:[^()]*)\)[ \t]*$/)) {
        title = substr(title, 1, RSTART - 1)
      }
      sub(/[ \t]+$/, "", title)
      if (length(title) > cap) title = substr(title, 1, cap - 3) "..."
      printf "%s\t%s\n", id, title
    }
  ' "$BACKLOG" 2>/dev/null
}

# Owed identities, one per line. Every temporary file this script writes lives
# in the ledger root rather than in owed/, so nothing transient can be read back
# as a receipt; the validity filter is defence in depth for a hand-dropped file.
receipt_owed_ids() {
  local record id
  [ -d "$OWED" ] || return 0
  for record in "$OWED"/*; do
    [ -f "$record" ] || continue
    id=${record##*/}
    receipt_valid_id "$id" || continue
    printf '%s\n' "$id"
  done
}

receipt_field() {  # <record> <field>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# The captain-facing sentence, with no trailing newline: every caller reads it
# through a command substitution, which would strip one anyway.
# The backticks are literal markdown: the captain's terminal renders the reply,
# so the identity arrives as inline code and reads as something to quote back.
# shellcheck disable=SC2016 # Backticks are literal output, not a substitution.
receipt_sentence() {  # <identity> <title>
  if [ -n "${2:-}" ]; then
    printf 'Filed as `%s` - %s.' "$1" "$2"
  else
    printf 'Filed as `%s`.' "$1"
  fi
}

# Fold the current backlog into the ledger. Never fails the caller: a home that
# cannot write its own state must not lose a turn to this.
receipt_reconcile() {
  local current id cid title record present tmp
  [ -f "$BACKLOG" ] || return 0

  mkdir -p "$OWED" 2>/dev/null || return 0
  chmod 700 "$LEDGER" 2>/dev/null || true

  current=$(receipt_parse_backlog) || return 0

  if [ ! -f "$BASELINE" ]; then
    # First reconcile in this home: adopt the whole backlog as already known so
    # nothing pre-existing is claimed as an unpaid receipt.
    receipt_write_baseline "$current"
    return 0
  fi

  while IFS="$TAB" read -r id title; do
    [ -n "$id" ] || continue
    receipt_valid_id "$id" || continue
    grep -Fxq "$id" "$BASELINE" 2>/dev/null && continue
    record="$OWED/$id"
    [ -e "$record" ] && continue
    tmp="$LEDGER/.write.$$"
    if printf 'title=%s\nfirst_seen=%s\nblocked=0\n' "$title" "$(date +%s)" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$record" 2>/dev/null || true
    fi
    rm -f "$tmp" 2>/dev/null || true
  done <<EOF
$current
EOF

  # An identity that has left the backlog entirely (removed, or archived out of
  # the Done tail) is no longer a debt worth carrying.
  for id in $(receipt_owed_ids); do
    present=0
    while IFS="$TAB" read -r cid _; do
      [ "$cid" = "$id" ] && { present=1; break; }
    done <<EOF
$current
EOF
    [ "$present" -eq 1 ] || rm -f "$OWED/$id" 2>/dev/null || true
  done

  receipt_write_baseline "$current"
}

receipt_write_baseline() {  # <parsed>
  local tmp
  tmp="$LEDGER/.baseline.$$"
  if printf '%s\n' "$1" | cut -f1 | grep -v '^$' > "$tmp" 2>/dev/null || [ -f "$tmp" ]; then
    mv -f "$tmp" "$BASELINE" 2>/dev/null || true
  fi
  rm -f "$tmp" 2>/dev/null || true
}

cmd_pending() {
  local id record title blocked
  receipt_reconcile
  for id in $(receipt_owed_ids); do
    record="$OWED/$id"
    title=$(receipt_field "$record" title)
    blocked=$(receipt_field "$record" blocked)
    printf 'owed: %s\n' "$id"
    printf '  say: %s\n' "$(receipt_sentence "$id" "$title")"
    [ "$blocked" = 1 ] && printf '  (already surfaced once at a turn end)\n'
    printf '  clear: %s/bin/fm-capture-receipt.sh delivered %s\n' "$FM_ROOT" "$id"
  done
}

cmd_delivered() {
  local id missing=0
  [ "$#" -gt 0 ] || { echo "usage: fm-capture-receipt.sh delivered <identity>..." >&2; return 2; }
  receipt_reconcile
  for id in "$@"; do
    if ! receipt_valid_id "$id" || [ ! -f "$OWED/$id" ]; then
      printf 'error: no receipt is owed for %s\n' "$id" >&2
      missing=1
    fi
  done
  if [ "$missing" -eq 1 ]; then
    # shellcheck disable=SC2016 # Backticks are literal output, not a substitution.
    printf 'refusing before clearing anything; run `%s/bin/fm-capture-receipt.sh pending` for what is actually owed\n' \
      "$FM_ROOT" >&2
    return 1
  fi
  for id in "$@"; do
    rm -f "$OWED/$id" 2>/dev/null || true
    printf 'receipt delivered: %s\n' "$id"
  done
}

cmd_active() {
  local id
  # Reconciles first so a session start is authoritative even when the turn
  # that filed the work never reached a turn end.
  receipt_reconcile
  for id in $(receipt_owed_ids); do
    [ -n "$id" ] && return 0
  done
  return 1
}

cmd_guard() {
  local id record title blocked pending_ids='' tmp rule
  receipt_reconcile
  for id in $(receipt_owed_ids); do
    blocked=$(receipt_field "$OWED/$id" blocked)
    [ "$blocked" = 1 ] && continue
    pending_ids="$pending_ids $id"
  done
  [ -n "$pending_ids" ] || return 0

  # Mark first: a receipt that cannot be marked must not block, or an unwritable
  # state dir would refuse every turn end from here on.
  tmp="$LEDGER/.write.$$"
  for id in $pending_ids; do
    record="$OWED/$id"
    if ! sed 's/^blocked=0$/blocked=1/' "$record" > "$tmp" 2>/dev/null \
      || ! mv -f "$tmp" "$record" 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null || true
      return 0
    fi
  done
  rm -f "$tmp" 2>/dev/null || true

  rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$rule"
    printf '●  THE CAPTAIN HAS NOT BEEN TOLD WHAT THIS WAS FILED AS\n'
    printf '●  Work was filed this turn and the captain cannot name it. A record they\n'
    printf '●  cannot quote back reads to them as nothing captured (AGENTS.md section 9).\n'
    printf '●  Send these exact sentences before ending the turn:\n'
    for id in $pending_ids; do
      title=$(receipt_field "$OWED/$id" title)
      printf '●    %s\n' "$(receipt_sentence "$id" "$title")"
    done
    printf '●  Then attest delivery:\n'
    printf '●    %s/bin/fm-capture-receipt.sh delivered%s\n' "$FM_ROOT" "$pending_ids"
    printf '●  If the captain already has a name for one, attest it and move on. This\n'
    printf '●  block is raised once per item; after that the debt only shows at session start.\n'
    printf '●%s\n' "$rule"
  } >&2
  return 2
}

case "${1:-}" in
  pending) shift; cmd_pending "$@" ;;
  delivered) shift; cmd_delivered "$@" ;;
  active) shift; cmd_active "$@" ;;
  guard) shift; cmd_guard "$@" ;;
  reconcile) shift; receipt_reconcile ;;
  -h | --help | help) usage ;;
  *) usage >&2; exit 2 ;;
esac
