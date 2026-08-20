#!/usr/bin/env bash
# fm-pool-reap.sh - keep only as many isolated copies as the fleet actually needs.
#
# THE PROBLEM. Every worker gets its own pooled checkout under the treehouse root.
# The pool grows to the high-water mark of concurrent workers a project has ever
# had and nothing ever gives a copy back, so it only ratchets. Measured across
# this fleet on 2026-08-20: 35 copies, 3 in use, 22 GB, almost all of it
# node_modules installed once per copy. One project held sixteen copies and was
# using none of them.
#
# THIS SCRIPT IS POLICY AND WIRING, NOT A POOL. Treehouse owns the mechanics
# (status, prune, destroy, return) and keeps owning them. What is added here is
# the decision of how many copies to keep, which ones may go, and - above all -
# which ones must not.
#
# ══ THE REFUSALS COME FIRST AND THEY ARE ABSOLUTE ══════════════════════════════
#
# A reaper is precisely the shape of tool that destroys work by accident, and
# hard rule 3 says unlanded work is never torn down. Two faults in the same
# measured data make the danger concrete: a copy reading `available` while
# holding an unmerged branch with an open PR, and a copy reading `dirty` whose
# uncommitted changes have no known owner. `available` is a statement about
# whether a process is attached. It is not evidence about work.
#
#   1. Never reclaim a copy with uncommitted changes. The single exception is the
#      captain's standing authority of 2026-08-11 to discard
#      .claude/settings.local.json when it is the SOLE uncommitted change, and
#      that exception is not re-implemented here: it is inherited exactly, and
#      only as wide as it already is, from the shared owner in rule 2.
#
#      UNTRACKED-ONLY CONTENT STILL BLOCKS RECLAIM. This is a deliberate choice,
#      not a side effect of the filter. The case that forced it: one copy in this
#      fleet reads dirty purely from an untracked .scratch/ holding 486 MB - a
#      third-party repository cloned inside the worktree, with its own .git, no
#      tracked changes, no branch and no owner. It is tempting to call that
#      obviously disposable. It is not decidable. An untracked file is the LEAST
#      recoverable thing in a repository: it exists in exactly one place and git
#      will not bring it back, so `?? newfeature.ts` - a file a worker wrote and
#      never staged - is precisely the work hard rule 3 exists to protect, and
#      nothing distinguishes it from a vendored clone without guessing. A nested
#      repository can hold uncommitted work of its own besides. Declaring the
#      class disposable is also exactly the wider exception the captain withheld
#      when granting the narrow one above.
#
#      What it must NOT be is silent and permanent. A copy stuck this way is
#      locked out of the pool forever while still holding its disk, so the report
#      calls it out separately from an ordinary refusal, names what is sitting
#      there and what it costs, and prints the exact command that would clear it.
#      That command is the captain's to run: it discards work, so standing
#      authority does not reach it and this script never runs it.
#   2. Never reclaim a copy holding unlanded commits - a branch not merged, an
#      open PR, or commits that exist nowhere else. This runs TWO gates and a
#      refusal from either is final:
#        - bin/fm-teardown-safety-lib.sh, the existing owner of the complete
#          landed-work test, invoked with an EMPTY kind so neither the scout nor
#          the secondmate carve-out can apply to a copy whose provenance is
#          unknown. Mode is the owner's own default, deliberately NOT local-only:
#          local-only looks like the strict choice and is a trap here, because it
#          refuses on commits absent from the default branch WITHOUT the content
#          fallback, so every squash-merged copy - the ordinary flow - would be
#          refused forever on work that had in fact fully landed. Gate two below
#          supplies the strictness local-only was reached for, and does it
#          without that blind spot.
#        - a merged-into-default gate this script adds on top, because the
#          teardown owner accepts "reachable from a remote" as landed. That is
#          right for a task teardown, whose branch survives on the remote, and
#          wrong here: a pushed branch with an open PR is still unlanded work,
#          and reclaiming its copy is exactly the accident to prevent. A branch
#          counts as landed only when its commits are already in the default
#          branch, or when its content is (the squash-merge flow).
#   3. Never reclaim a copy a live task is recorded against, read from
#      firstmate's own durable task records rather than from whether a process
#      happens to be running in it. A crashed worker's copy still holds its work.
#      Every home scanned is named in the report, so a home that was not scanned
#      is visible rather than assumed empty.
#   4. Refusal is a result, not an obstacle. A copy that cannot be shown safe is
#      reported and left alone. This script has NO force flag, passes no
#      --include-unlanded, --include-in-use, --include-leased or --force to
#      treehouse, and has no target number it will discard work to reach. When it
#      cannot verify something it refuses; there is no path through it that
#      removes a copy it could not prove disposable.
#
# Treehouse's own bare `destroy` is then a second, independent gate: it removes
# only the genuinely disposable set and skips everything else. Both gates must
# agree before a copy goes.
#
# ══ THE POLICY ════════════════════════════════════════════════════════════════
#
# WARM RESERVE, default 1 per project. Not nought: a fresh copy pays a full
# dependency install before the next worker can start, and that cost lands on
# every dispatch. Not sixteen: each extra warm copy costs a whole dependency tree
# (about 2 GB per copy on the largest project here) to save install time on a
# CONCURRENT second dispatch, which is far rarer than a serial next one. One warm
# copy makes the common case - the next single dispatch - instant, and lets a
# genuine fan-out grow the pool again on demand. The reserve counts only copies
# that are actually available for reuse; a copy that is in use or refused cannot
# be handed to a worker, so it is never counted as warm.
#
# MINIMUM IDLE AGE, default 24 hours. A copy is reclaimed only once it has been
# untouched for that long. This is deliberate slack against races the durable
# records cannot close on their own: a copy acquired but not yet recorded against
# its task, a worker between teardown and the next acquire, a human poking at a
# checkout by hand. Reclaiming beyond the reserve is not urgent - the disk is
# already spent - so buying a wide safety margin with it is cheap.
#
# ORDER. Beyond the reserve, oldest-idle first: the least likely to be wanted
# next goes first, and the warm copies that remain are the most recently prepared.
#
# ══ WHEN IT RUNS ══════════════════════════════════════════════════════════════
#
# Automatically after a task's cleanup (bin/fm-teardown.sh calls it best-effort
# once a teardown has fully succeeded), and by hand at any time. Cleanup is the
# precise trigger rather than a periodic sweep, because cleanup is the moment a
# copy actually becomes free and the moment the fleet's need drops - and, since
# rule 3 keeps a copy protected for exactly as long as a task is recorded against
# it, cleanup is also the moment any copy BECOMES reclaimable. Each run sweeps
# every pool rather than only the project just torn down, so one cleanup anywhere
# reclaims the backlog everywhere.
#
# It is deliberately NOT wired into session start. Session start keeps external
# network calls off its blocking path, and a periodic sweep would mostly find
# nothing new, because nothing becomes reclaimable between cleanups.
#
# ══ REPORTING ═════════════════════════════════════════════════════════════════
#
# Every run prints what it reclaimed AND what it refused, with the reason for
# each refusal, so a refusal is visible rather than silent. Quiet runs stay quiet:
# with nothing reclaimed and nothing refused it prints a single summary line.
#
# Usage: fm-pool-reap.sh [options]
#   --project <name|path>   Sweep only the pool backing this project. A bare name
#                           matches the primary checkout's directory name.
#   --reserve <n>           Warm copies to keep per pool. Overrides config.
#   --min-idle-hours <h>    Minimum untouched hours before a copy may be
#                           reclaimed. Overrides config. 0 disables the wait.
#   --dry-run               Decide and report, reclaim nothing.
#   --json                  Emit the report as JSON instead of text.
#   --quiet                 Suppress the report; the exit status still stands.
#
# Configuration, per the config/ conventions in docs/configuration.md:
#   config/pool-reserve     Optional. A bare integer sets the default reserve for
#                           every project. `<project> = <n>` lines override single
#                           projects. `min-idle-hours = <h>` sets the idle wait.
#                           Absent means the built-in defaults, which need no
#                           configuration. Malformed values are reported and
#                           refused, never silently treated as a default.
#
# Environment: FM_POOL_ROOT overrides the treehouse root (tests, and an operator
# whose treehouse.toml configures a different root).
#
# Exit status: 0 when the sweep completed, whatever it refused - a refusal is a
# result. Non-zero only when the sweep itself could not run safely.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# The complete landed-work test. Shared with bin/fm-teardown.sh so this script
# cannot drift into a second, weaker copy of it (rule 2).
# shellcheck source=bin/fm-teardown-safety-lib.sh
. "$SCRIPT_DIR/fm-teardown-safety-lib.sh"
# shellcheck source=bin/fm-pool-lib.sh
. "$SCRIPT_DIR/fm-pool-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

DEFAULT_RESERVE=1
DEFAULT_MIN_IDLE_HOURS=24

OPT_PROJECT=
OPT_RESERVE=
OPT_MIN_IDLE_HOURS=
OPT_DRY_RUN=0
OPT_JSON=0
OPT_QUIET=0

die() {
  printf 'fm-pool-reap.sh: %s\n' "$1" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) [ "$#" -ge 2 ] || die "--project needs a value"; OPT_PROJECT=$2; shift 2 ;;
    --reserve) [ "$#" -ge 2 ] || die "--reserve needs a value"; OPT_RESERVE=$2; shift 2 ;;
    --min-idle-hours) [ "$#" -ge 2 ] || die "--min-idle-hours needs a value"; OPT_MIN_IDLE_HOURS=$2; shift 2 ;;
    --dry-run) OPT_DRY_RUN=1; shift ;;
    --json) OPT_JSON=1; shift ;;
    --quiet) OPT_QUIET=1; shift ;;
    -h|--help) sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
    *) die "unknown option '$1'" ;;
  esac
done

is_non_negative_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac }

# --- configuration ----------------------------------------------------------
#
# config/pool-reserve is a plain key/value file so an operator can read and edit
# it without tooling, matching the other config/ entries. A malformed line is an
# error rather than a silent fallback: silently reverting to a default would hide
# the operator's intent, and this script's decisions are about deleting things.

CONFIG_FILE="$CONFIG/pool-reserve"
CFG_DEFAULT_RESERVE=
CFG_MIN_IDLE_HOURS=
CFG_PROJECT_KEYS=()
CFG_PROJECT_VALUES=()

load_config() {
  local line key value lineno=0
  [ -f "$CONFIG_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%%#*}
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$line" ] || continue
    case "$line" in
      *=*)
        key=${line%%=*}
        value=${line#*=}
        key=$(printf '%s' "$key" | sed 's/[[:space:]]*$//')
        value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//')
        if [ "$key" = min-idle-hours ]; then
          is_non_negative_int "$value" \
            || die "$CONFIG_FILE line $lineno: min-idle-hours must be a whole number of hours, got '$value'"
          CFG_MIN_IDLE_HOURS=$value
        else
          is_non_negative_int "$value" \
            || die "$CONFIG_FILE line $lineno: reserve for '$key' must be a whole number, got '$value'"
          CFG_PROJECT_KEYS+=("$key")
          CFG_PROJECT_VALUES+=("$value")
        fi
        ;;
      *)
        is_non_negative_int "$line" \
          || die "$CONFIG_FILE line $lineno: expected a whole number or '<key> = <value>', got '$line'"
        CFG_DEFAULT_RESERVE=$line
        ;;
    esac
  done < "$CONFIG_FILE"
}

load_config

if [ -n "$OPT_RESERVE" ]; then
  is_non_negative_int "$OPT_RESERVE" || die "--reserve must be a whole number, got '$OPT_RESERVE'"
fi
if [ -n "$OPT_MIN_IDLE_HOURS" ]; then
  is_non_negative_int "$OPT_MIN_IDLE_HOURS" || die "--min-idle-hours must be a whole number, got '$OPT_MIN_IDLE_HOURS'"
fi

MIN_IDLE_HOURS=${OPT_MIN_IDLE_HOURS:-${CFG_MIN_IDLE_HOURS:-$DEFAULT_MIN_IDLE_HOURS}}

reserve_for_project() {  # <project-name>
  local name=$1 i
  if [ -n "$OPT_RESERVE" ]; then printf '%s\n' "$OPT_RESERVE"; return 0; fi
  for i in "${!CFG_PROJECT_KEYS[@]}"; do
    if [ "${CFG_PROJECT_KEYS[$i]}" = "$name" ]; then
      printf '%s\n' "${CFG_PROJECT_VALUES[$i]}"
      return 0
    fi
  done
  printf '%s\n' "${CFG_DEFAULT_RESERVE:-$DEFAULT_RESERVE}"
}

# --- rule 3: which copies do live task records claim? -----------------------
#
# Read from firstmate's own durable records, not from process liveness. Fails
# closed: if the records of a home cannot be read, this script refuses the whole
# sweep rather than treating that home as owning nothing.

CLAIMED_PATHS=()
SCANNED_HOMES=()

scan_home_task_records() {  # <home>
  local home=$1 state meta wt
  state="$home/state"
  [ -d "$state" ] || return 0
  if [ ! -r "$state" ] || [ ! -x "$state" ]; then
    die "cannot read task records in $state; refusing to reclaim anything while a home's claims are unknown"
  fi
  SCANNED_HOMES+=("$home")
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    while IFS= read -r wt; do
      wt=${wt#worktree=}
      [ -n "$wt" ] || continue
      CLAIMED_PATHS+=("$(fm_pool_realpath "$wt" 2>/dev/null || printf '%s' "$wt")|$(basename "$meta" .meta)|$home")
    done < <(grep '^worktree=' "$meta" 2>/dev/null || true)
  done
}

collect_task_claims() {
  local line home
  scan_home_task_records "$FM_HOME"
  # Registered LOCAL secondmates keep their own task records in their own homes.
  # A remote secondmate's home lives on another machine, so it can hold no copy
  # in this machine's pool and is correctly out of scope here.
  if [ -f "$DATA/secondmates.md" ]; then
    while IFS= read -r line; do
      case "$line" in '- '*) ;; *) continue ;; esac
      # Only a `home:` field can designate a home, so a bullet without one names
      # no records and skipping it loses no claim. A bullet that DOES carry one
      # and still will not parse is a home whose claims cannot be read, and this
      # sweep stops rather than treating it as owning nothing - silently dropping
      # a secondmate's claims is how a reaper reclaims someone else's work.
      if ! secondmate_registry_parse_line "$line" >/dev/null 2>&1; then
        case "$line" in
          *home:*) die "cannot read the secondmate route in $DATA/secondmates.md: ${line}
Refusing to reclaim anything while a registered home's claims are unknown." ;;
          *) continue ;;
        esac
      fi
      [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] && continue
      home=$SECONDMATE_REGISTRY_HOME
      [ -n "$home" ] || continue
      case "$home" in /*) ;; *) home="$FM_HOME/$home" ;; esac
      if [ ! -d "$home" ]; then
        # Reported, never silent: a home that is not on disk right now holds no
        # readable records, and that fact belongs in the report.
        SCANNED_HOMES+=("$home (not present)")
        continue
      fi
      scan_home_task_records "$home"
    done < "$DATA/secondmates.md"
  fi
}

# The claim covering <copy>, or empty. A copy matches when a record names it, or
# names a path inside it, or sits inside a recorded worktree - any of which means
# a task's work lives there.
claim_for_copy() {  # <copy-real-path>
  local copy=$1 entry path
  for entry in ${CLAIMED_PATHS+"${CLAIMED_PATHS[@]}"}; do
    path=${entry%%|*}
    [ -n "$path" ] || continue
    if [ "$path" = "$copy" ] || [ "${path#"$copy"/}" != "$path" ] || [ "${copy#"$path"/}" != "$copy" ]; then
      printf '%s\n' "${entry#*|}"
      return 0
    fi
  done
  return 1
}

# --- idle age ---------------------------------------------------------------

mtime_of() {  # <path>
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf ''
}

# Seconds since the copy was last touched: the newest of its own directory, its
# .git pointer, and its index. Any unreadable input yields no answer at all, and
# the caller then treats the copy as too fresh to touch rather than guessing.
copy_idle_seconds() {  # <copy>
  local copy=$1 now newest t gitdir
  now=$(date +%s)
  newest=
  for t in "$copy" "$copy/.git"; do
    t=$(mtime_of "$t")
    [ -n "$t" ] || continue
    [ -n "$newest" ] && [ "$t" -le "$newest" ] || newest=$t
  done
  if gitdir=$(git -C "$copy" rev-parse --path-format=absolute --git-dir 2>/dev/null) && [ -n "$gitdir" ]; then
    t=$(mtime_of "$gitdir/index")
    if [ -n "$t" ]; then
      [ -n "$newest" ] && [ "$t" -le "$newest" ] || newest=$t
    fi
  fi
  [ -n "$newest" ] || return 1
  printf '%s\n' "$(( now - newest ))"
}

human_idle() {  # <seconds>
  local s=$1
  if [ "$s" -lt 3600 ]; then printf '%dm\n' "$(( s / 60 ))"
  elif [ "$s" -lt 172800 ]; then printf '%dh\n' "$(( s / 3600 ))"
  else printf '%dd\n' "$(( s / 86400 ))"; fi
}

# --- treehouse's own view ---------------------------------------------------
#
# `treehouse status --json` is treehouse's supported interface and the authority
# on whether a copy has a process attached or a lease held. It resolves the pool
# from the working directory, so it is asked from the pool's own primary
# checkout - which is also what proves a pool is that repository's canonical one.

TH_STATUS_JSON=
load_pool_status() {  # <primary-checkout>
  local primary=$1
  TH_STATUS_JSON=
  [ -n "$primary" ] && [ -d "$primary" ] || return 1
  command -v treehouse >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  TH_STATUS_JSON=$( cd "$primary" && treehouse status --json 2>/dev/null ) || return 1
  [ -n "$TH_STATUS_JSON" ] || return 1
  printf '%s' "$TH_STATUS_JSON" | jq -e 'type == "array"' >/dev/null 2>&1
}

# "in-use", "available", or empty when treehouse does not know this path. Empty is
# never read as safe: the caller refuses a copy treehouse cannot account for.
status_of_copy() {  # <copy>
  local copy=$1
  [ -n "$TH_STATUS_JSON" ] || return 1
  printf '%s' "$TH_STATUS_JSON" \
    | jq -r --arg p "$copy" '.[] | select(.path == $p) | (if (.lease_id // "") != "" then "leased" elif ((.processes // []) | length) > 0 then "in-use" else .status end)' 2>/dev/null \
    | head -1
}

# --- rule 1 and rule 2: is this copy free of unlanded work? ------------------

REFUSAL_REASON=
# Set alongside REFUSAL_REASON when a copy is held ONLY by untracked content, so
# the report can single those out: "<total size>\t<first few entries>".
UNCLAIMED_UNTRACKED=

# Why a copy that failed gate one failed it, in the operator's terms. Gate one
# owns the VERDICT; this only explains an answer already given, by asking git
# narrower questions than the gate did rather than by re-deciding anything.
describe_dirty_refusal() {  # <copy>
  local copy=$1 entries sizes entry size total
  UNCLAIMED_UNTRACKED=
  if [ -n "$(git -C "$copy" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    REFUSAL_REASON="it has uncommitted changes to tracked files"
    return 0
  fi
  entries=$(git -C "$copy" ls-files --others --directory --exclude-standard 2>/dev/null | head -5)
  [ -n "$entries" ] || return 1
  total=$(du -sh "$copy" 2>/dev/null | awk '{print $1}')
  sizes=
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    size=$(du -sh "$copy/$entry" 2>/dev/null | awk '{print $1}')
    sizes="${sizes:+$sizes, }$entry${size:+ ($size)}"
  done <<UNTRACKED
$entries
UNTRACKED
  REFUSAL_REASON="it holds untracked files nobody has claimed: $sizes"
  UNCLAIMED_UNTRACKED="${total:-unknown}	$sizes"
  return 0
}

# Gate two of rule 2, and the one this script adds. The teardown owner accepts
# work reachable from any remote as landed, which is right for a task whose
# branch survives on the remote and wrong for a pool copy: a pushed branch with
# an open PR is unlanded. Landed here means the commits are already in the
# default branch, or - the squash-merge flow - their content is, which is what
# content_in_default proves. No PR lookup and no network round trip is needed to
# answer it, because "merged into default" is the same question either way.
work_is_merged_into_default() {  # uses WT / PROJ
  local name ref head
  head=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  name=$(default_branch) || return 1
  ref=absent
  if git -C "$WT" rev-parse --quiet --verify "refs/remotes/origin/$name" >/dev/null 2>&1; then
    git -C "$WT" merge-base --is-ancestor "$head" "refs/remotes/origin/$name" 2>/dev/null && return 0
    ref=found
  fi
  if git -C "$WT" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    git -C "$WT" merge-base --is-ancestor "$head" "refs/heads/$name" 2>/dev/null && return 0
    ref=found
  fi
  # No default branch to compare against at all is not evidence of anything.
  [ "$ref" = found ] || return 1
  content_in_default
}

# Both gates of rules 1 and 2. Sets REFUSAL_REASON and returns non-zero on any
# refusal, including any inability to decide.
copy_holds_no_unlanded_work() {  # <copy> <primary-checkout>
  local copy=$1 primary=$2 out rc reason branch
  REFUSAL_REASON=
  UNCLAIMED_UNTRACKED=

  if ! git -C "$copy" rev-parse --git-dir >/dev/null 2>&1; then
    REFUSAL_REASON="its backing repository is gone, so nothing it holds can be verified"
    return 1
  fi

  # Gate one: the shared owner of the complete landed-work test. kind is empty so
  # neither carve-out applies to a copy whose provenance is unknown; mode is the
  # owner's default so its full landed test runs, including the content fallback
  # that recognizes a squash merge (see the header on why local-only is wrong
  # here); force is empty and there is no flag that could set it.
  out=$(
    WT="$copy" PROJ="$primary" MODE=no-mistakes KIND='' FORCE='' PR_URL='' \
    TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY='' \
      validate_worktree_teardown_safety 2>&1
  )
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # Under the strictest mode the owner reports dirty and unmerged work in one
    # headline, which cannot tell an operator which of the two they are looking
    # at. Ask directly first, and fall back to the owner's own words.
    if describe_dirty_refusal "$copy"; then
      return 1
    fi
    reason=$(printf '%s\n' "$out" | sed -n 's/^REFUSED: //p' | head -1)
    if [ -z "$reason" ]; then
      reason="its state could not be inspected (the check exited $rc)"
    fi
    REFUSAL_REASON=$reason
    return 1
  fi

  # Gate two: merged into the default branch, not merely pushed somewhere.
  if ! WT="$copy" PROJ="$primary" work_is_merged_into_default; then
    branch=$(git -C "$copy" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'HEAD')
    REFUSAL_REASON="it holds commits on '$branch' that are not in the default branch (an unmerged branch or an open PR is not landed work)"
    return 1
  fi
  return 0
}

# --- report -----------------------------------------------------------------

REPORT_POOL=()
REPORT_PATH=()
REPORT_OUTCOME=()
REPORT_DETAIL=()
# Copies held ONLY by untracked content nobody has claimed, as
# "<path>\t<total size>\t<entries>". Reported apart from ordinary refusals
# because they never clear on their own: nothing will ever commit or land what is
# sitting there, so the copy stays out of the pool, and holds its disk, until the
# captain decides. See the untracked note in the header.
STUCK_UNTRACKED=()

record() {  # <pool> <path> <outcome> <detail>
  REPORT_POOL+=("$1"); REPORT_PATH+=("$2"); REPORT_OUTCOME+=("$3"); REPORT_DETAIL+=("$4")
}

RECLAIMED=0
REFUSED=0
RESERVED=0
IN_USE=0

# --- sweep ------------------------------------------------------------------

collect_task_claims

pool_matches_project_filter() {  # <primary-checkout> <pool-dir>
  local primary=$1 pool=$2 want
  [ -n "$OPT_PROJECT" ] || return 0
  case "$OPT_PROJECT" in
    */*) want=$(fm_pool_realpath "$OPT_PROJECT" 2>/dev/null || printf '%s' "$OPT_PROJECT")
         [ "$want" = "$primary" ] && return 0 ;;
    *)   [ -n "$primary" ] && [ "$(basename "$primary")" = "$OPT_PROJECT" ] && return 0
         [ "$(basename "$pool")" = "$OPT_PROJECT" ] && return 0 ;;
  esac
  return 1
}

DUPLICATE_REPORT=$(fm_pool_duplicate_dirs || true)

sweep_pool() {  # <pool-dir>
  local pool=$1 backing primary pool_name reserve copy copy_real status idle
  local claim candidates=() ages=() i n keep destroy_out
  backing=$(fm_pool_backing_state "$pool")
  primary=${backing#present }
  [ "$backing" != "${backing#present }" ] || primary=

  pool_name=$(basename "$pool")
  pool_matches_project_filter "$primary" "$pool" || return 0

  if [ -z "$primary" ]; then
    # An orphan or unreadable pool: its object store is gone, so no branch in it
    # can be checked against anything. Report it and leave every copy alone -
    # deciding it empty would be a guess, and guesses are what rule 4 forbids.
    while IFS= read -r copy; do
      [ -n "$copy" ] || continue
      record "$pool_name" "$copy" refused "its backing repository is gone, so nothing it holds can be verified"
      REFUSED=$((REFUSED + 1))
    done < <(fm_pool_copies "$pool")
    return 0
  fi

  if ! load_pool_status "$primary"; then
    while IFS= read -r copy; do
      [ -n "$copy" ] || continue
      record "$pool_name" "$copy" refused "the pool's own status could not be read, so whether it is in use is unknown"
      REFUSED=$((REFUSED + 1))
    done < <(fm_pool_copies "$pool")
    return 0
  fi

  reserve=$(reserve_for_project "$(basename "$primary")")

  while IFS= read -r copy; do
    [ -n "$copy" ] || continue
    copy_real=$(fm_pool_realpath "$copy" 2>/dev/null || printf '%s' "$copy")

    if claim=$(claim_for_copy "$copy_real"); then
      record "$pool_name" "$copy" refused "task ${claim%%|*} is still recorded against it"
      REFUSED=$((REFUSED + 1)); continue
    fi

    status=$(status_of_copy "$copy" || true)
    case "$status" in
      in-use|leased)
        record "$pool_name" "$copy" in-use "a worker is using it"
        IN_USE=$((IN_USE + 1)); continue ;;
      available) ;;
      *)
        record "$pool_name" "$copy" refused "treehouse does not account for it, so its state is unknown"
        REFUSED=$((REFUSED + 1)); continue ;;
    esac

    if ! idle=$(copy_idle_seconds "$copy"); then
      record "$pool_name" "$copy" refused "how recently it was used could not be determined"
      REFUSED=$((REFUSED + 1)); continue
    fi

    if ! copy_holds_no_unlanded_work "$copy" "$primary"; then
      record "$pool_name" "$copy" refused "$REFUSAL_REASON"
      [ -z "$UNCLAIMED_UNTRACKED" ] || STUCK_UNTRACKED+=("$copy	$UNCLAIMED_UNTRACKED")
      REFUSED=$((REFUSED + 1)); continue
    fi

    if [ "$(( idle / 3600 ))" -lt "$MIN_IDLE_HOURS" ]; then
      record "$pool_name" "$copy" reserved "used $(human_idle "$idle") ago, inside the ${MIN_IDLE_HOURS}h settling window"
      RESERVED=$((RESERVED + 1)); continue
    fi

    candidates+=("$copy")
    ages+=("$idle")
  done < <(fm_pool_copies "$pool")

  n=${#candidates[@]}
  [ "$n" -gt 0 ] || return 0

  # Keep the reserve as the most recently used copies, and release the rest
  # oldest-idle first. Sorting by idle seconds descending puts the stalest first.
  local order
  order=$(
    for i in "${!candidates[@]}"; do printf '%s\t%s\n' "${ages[$i]}" "$i"; done \
      | LC_ALL=C sort -rn -k1,1
  )
  keep=$(( n > reserve ? reserve : n ))
  # The kept ones are the freshest, i.e. the tail of that descending order.
  local release_count=$(( n - keep )) seen=0 idx age
  while IFS=$'\t' read -r age idx; do
    [ -n "$idx" ] || continue
    copy=${candidates[$idx]}
    if [ "$seen" -lt "$release_count" ]; then
      seen=$((seen + 1))
      if [ "$OPT_DRY_RUN" = 1 ]; then
        record "$pool_name" "$copy" would-reclaim "idle $(human_idle "$age"), beyond the reserve of $reserve"
        RECLAIMED=$((RECLAIMED + 1))
        continue
      fi
      # No --include-* and no --force, ever: treehouse's bare destroy removes only
      # the genuinely disposable set, so it is a second gate agreeing with ours
      # rather than a command told to override anything.
      if destroy_out=$( cd "$primary" && treehouse destroy "$copy" --yes 2>&1 ) && [ ! -d "$copy" ]; then
        record "$pool_name" "$copy" reclaimed "idle $(human_idle "$age"), beyond the reserve of $reserve$(printf '%s' "$destroy_out" | sed -n 's/.*freed \([0-9.]* [A-Za-z]*\).*/, freed \1/p' | head -1)"
        RECLAIMED=$((RECLAIMED + 1))
      else
        record "$pool_name" "$copy" refused "treehouse declined to remove it: $(printf '%s' "$destroy_out" | tr '\n' ' ' | sed 's/[[:space:]]\{2,\}/ /g; s/[[:space:]]*$//')"
        REFUSED=$((REFUSED + 1))
      fi
    else
      record "$pool_name" "$copy" reserved "kept warm (reserve $reserve)"
      RESERVED=$((RESERVED + 1))
    fi
  done <<EOF
$order
EOF
}

while IFS= read -r pool_dir; do
  [ -n "$pool_dir" ] || continue
  sweep_pool "$pool_dir"
done < <(fm_pool_dirs)

# --- output -----------------------------------------------------------------

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

emit_json() {
  local i first=1
  printf '{"reclaimed":%d,"refused":%d,"reserved":%d,"in_use":%d,"dry_run":%s,"reserve_default":%s,"min_idle_hours":%s,"homes_scanned":[' \
    "$RECLAIMED" "$REFUSED" "$RESERVED" "$IN_USE" \
    "$([ "$OPT_DRY_RUN" = 1 ] && echo true || echo false)" \
    "${CFG_DEFAULT_RESERVE:-${OPT_RESERVE:-$DEFAULT_RESERVE}}" "$MIN_IDLE_HOURS"
  for i in ${SCANNED_HOMES+"${!SCANNED_HOMES[@]}"}; do
    [ "$first" = 1 ] || printf ','
    printf '"%s"' "$(json_escape "${SCANNED_HOMES[$i]}")"
    first=0
  done
  printf '],"copies":['
  first=1
  for i in ${REPORT_PATH+"${!REPORT_PATH[@]}"}; do
    [ "$first" = 1 ] || printf ','
    printf '{"pool":"%s","path":"%s","outcome":"%s","detail":"%s"}' \
      "$(json_escape "${REPORT_POOL[$i]}")" "$(json_escape "${REPORT_PATH[$i]}")" \
      "$(json_escape "${REPORT_OUTCOME[$i]}")" "$(json_escape "${REPORT_DETAIL[$i]}")"
    first=0
  done
  printf ']}\n'
}

# Paths as treehouse prints them: a pool root under $HOME reads as ~, which keeps
# a report of several copies scannable instead of wrapping on a shared prefix.
display_path() {  # <path>
  case "${1:-}" in
    "$HOME"/*) printf '~%s\n' "${1#"$HOME"}" ;;
    *) printf '%s\n' "${1:-}" ;;
  esac
}

emit_text() {
  local i outcome shown=0 common pools dup
  for i in ${REPORT_PATH+"${!REPORT_PATH[@]}"}; do
    outcome=${REPORT_OUTCOME[$i]}
    case "$outcome" in reserved|in-use) continue ;; esac
    [ "$shown" = 0 ] && printf 'Isolated copies:\n'
    shown=1
    printf '  %-14s %s\n                 %s\n' \
      "$outcome" "$(display_path "${REPORT_PATH[$i]}")" "${REPORT_DETAIL[$i]}"
  done
  local stuck path total entries
  if [ "${#STUCK_UNTRACKED[@]}" -gt 0 ]; then
    printf 'Held by untracked files nobody has claimed - these never clear on their own:\n'
    for stuck in "${STUCK_UNTRACKED[@]}"; do
      IFS=$'\t' read -r path total entries <<STUCK
$stuck
STUCK
      printf '  %s  (%s on disk)\n    %s\n' "$(display_path "$path")" "$total" "$entries"
    done
    printf '  Nothing will ever commit or land these, so the copy stays out of the pool until\n'
    printf '  you decide. Discarding them needs your explicit word; this never does it for you:\n'
    printf '      treehouse destroy <copy> --include-unlanded --yes\n'
  fi
  if [ -n "$DUPLICATE_REPORT" ]; then
    printf 'Duplicate pools - one repository holding more than one pool:\n'
    while IFS=$'\t' read -r common pools; do
      [ -n "$common" ] || continue
      printf '  %s\n' "$(display_path "$common")"
      printf '%s' "$pools" | tr ',' '\n' | while IFS= read -r dup; do
        [ -n "$dup" ] && printf '    %s\n' "$(display_path "$dup")"
      done
    done <<EOF
$DUPLICATE_REPORT
EOF
  fi
  printf 'Pool: %d reclaimed, %d refused, %d kept warm, %d in use%s.\n' \
    "$RECLAIMED" "$REFUSED" "$RESERVED" "$IN_USE" \
    "$([ "$OPT_DRY_RUN" = 1 ] && printf ' (nothing was removed: this was a preview)' || printf '')"
}

if [ "$OPT_QUIET" != 1 ]; then
  if [ "$OPT_JSON" = 1 ]; then emit_json; else emit_text; fi
fi
exit 0
