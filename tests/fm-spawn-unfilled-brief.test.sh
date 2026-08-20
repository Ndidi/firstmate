#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's refusal to launch an unfilled brief.
#
# fm-brief.sh scaffolds the task text as a bare `{TASK}` placeholder line for
# firstmate to replace before dispatch. Launching one hands a worker a brief with
# no task in it, which is the failure this guard stops.
#
# The regression that shapes the check: a brief scaffolded WITHOUT --herdr-lab
# carries the un-enabled Herdr declaration, whose prose names `{TASK}` inline
# ("the task text that replaces `{TASK}` later"). An unanchored substring match
# would therefore refuse EVERY brief scaffolded without that flag - a guard that
# refuses everything gets removed rather than fixed. test_filled_brief_is_not_refused
# pins the distinction directly, with the Herdr prose asserted present so the case
# cannot go quietly vacuous if that section is ever reworded.
#
# Every case here is EXPECTED to fail before any endpoint, worktree, or backend
# side effect, so a passing run creates no windows and no worktrees.
# FM_SPAWN_NO_GUARD=1 keeps them off the live watcher guard and state.
#
# That expectation held for the passing path and not for the failing one. On
# 2026-08-19 this file left an `fm-unfilled-ship` window in the captain's own
# live session, owned by no task: while the placeholder guard was under
# development the spawn ran on to create the window, and the test then died at
# its first failed assertion with the window still there. The guard being
# checked is exactly the thing whose absence carries the run into the backend,
# so this file must never depend on it holding. tmux_isolate puts every tmux
# call on a private server, which makes that reachable-backend path harmless
# instead of merely unlikely. See tests/tmux-test-safety.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/tmux-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/tmux-test-safety.sh"
tmux_isolate_or_fail spawn-unfilled-brief

SPAWN="$ROOT/bin/fm-spawn.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-unfilled-brief)

# Clear ambient firstmate overrides so the behavior test owns its environment.
run_spawn() {  # <home> <args...>
  local home=$1; shift
  FM_ROOT_OVERRIDE='' \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_HOME="$home" \
    FM_BACKEND=tmux \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

new_home() {  # <name> -> prints the home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/projects/alpha"
  printf '%s\n' "$home"
}

fill_task() {  # <brief path> <text> - replace the placeholder line, nothing else
  local brief=$1 text=$2 tmp="$1.filling"
  awk -v text="$text" '$0 == "{TASK}" { print text; next } { print }' "$brief" > "$tmp"
  mv "$tmp" "$brief"
}

# The placeholder must stop the launch for every task kind that carries one, and
# must do so before the task has any recorded runtime state.
test_unfilled_brief_is_refused() {
  local home out status label brief_flags spawn_flags
  home=$(new_home unfilled)
  "$BRIEF" --help >/dev/null 2>&1 || fail "fm-brief.sh is not runnable"
  # A scout spawn refuses the ship delivery flags, so each kind carries its own.
  while IFS='|' read -r label brief_flags spawn_flags; do
    [ -n "$label" ] || continue
    # A scout's --scope-given is backed by a recorded framing verdict
    # (bin/fm-scout-framing.sh); this test is about the {TASK} placeholder, not scope.
    if [ "$label" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-scout-framing.sh" "unfilled-$label" \
        --captain-words 'Find out whether alpha drops records.' \
        --question 'Does alpha drop records?' >/dev/null 2>&1 \
        || fail "$label: could not record the fixture framing"
    fi
    # shellcheck disable=SC2086  # brief_flags is an intentional word-split arg list
    FM_HOME="$home" "$BRIEF" "unfilled-$label" alpha $brief_flags --scope-given >/dev/null 2>&1 \
      || fail "$label: could not scaffold the fixture brief"
    # shellcheck disable=SC2086  # spawn_flags is an intentional word-split arg list
    out=$(run_spawn "$home" "unfilled-$label" projects/alpha $spawn_flags)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: an unfilled brief should not launch"
    printf '%s\n' "$out" | grep -F 'still carries the unfilled {TASK} placeholder' >/dev/null \
      || fail "$label: refusal did not name the unfilled placeholder (got: $out)"
    printf '%s\n' "$out" | grep -F 'acceptance criteria' >/dev/null \
      || fail "$label: refusal did not say what to replace the placeholder with"
    assert_absent "$home/state/unfilled-$label.meta" \
      "$label: a refused spawn still recorded task state"
  done <<'ROWS'
ship|--mode local-only|--mode local-only --yolo off
scout|--scout|--scout
ROWS
  pass "fm-spawn.sh: a brief still carrying the {TASK} placeholder is refused before any side effect"
}

# The guard must not fire on the Herdr declaration's inline mention of the
# placeholder, which every brief scaffolded without --herdr-lab carries. A filled
# brief is proven to get PAST the check by failing at the next gate instead.
test_filled_brief_is_not_refused() {
  local home brief out status
  home=$(new_home filled)
  FM_HOME="$home" "$BRIEF" filled-ship alpha --mode local-only --scope-given >/dev/null 2>&1 \
    || fail "could not scaffold the fixture brief"
  brief="$home/data/filled-ship/brief.md"
  fill_task "$brief" 'Rename the widget helper and update its callers.'

  # The divergence this test depends on: the placeholder line is gone while the
  # Herdr prose still mentions it inline. Assert both, so a future rewording of
  # that section turns this test red rather than silently vacuous.
  grep -qx '{TASK}' "$brief" && fail "fixture still holds a placeholder line; the test would prove nothing"
  # shellcheck disable=SC2016  # a literal backticked {TASK}, not a substitution
  grep -F 'replaces `{TASK}` later' "$brief" >/dev/null \
    || fail "the un-enabled Herdr section no longer mentions {TASK} inline; this test can no longer prove the anchor is needed"

  # Deliberately mismatched --mode: the delivery check sits immediately after the
  # placeholder check, so reaching it proves the filled brief was let through.
  out=$(run_spawn "$home" filled-ship projects/alpha --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "the mismatched delivery mode should still refuse"
  printf '%s\n' "$out" | grep -F 'still carries the unfilled {TASK} placeholder' >/dev/null \
    && fail "a filled brief was refused because the Herdr section mentions {TASK} in prose"
  printf '%s\n' "$out" | grep -F 'delivery mismatch for filled-ship' >/dev/null \
    || fail "the filled brief did not reach the next gate (got: $out)"
  pass "fm-spawn.sh: a filled brief passes the placeholder check despite the Herdr section's inline mention"
}

# A brief whose task text merely contains the placeholder inside a sentence is a
# filled brief - only a placeholder occupying its own line is unfilled. This is
# the case a task about the scaffold itself produces, and refusing it would make
# firstmate unable to brief work on its own briefing tool.
test_placeholder_quoted_in_task_text_is_not_refused() {
  local home brief out
  home=$(new_home quoted)
  FM_HOME="$home" "$BRIEF" quoted-ship alpha --mode local-only --scope-given >/dev/null 2>&1 \
    || fail "could not scaffold the fixture brief"
  brief="$home/data/quoted-ship/brief.md"
  # shellcheck disable=SC2016  # a literal backticked {TASK}, not a substitution
  fill_task "$brief" 'Make the scaffold stop emitting a bare `{TASK}` marker without a scope source.'

  out=$(run_spawn "$home" quoted-ship projects/alpha --mode no-mistakes --yolo off)
  printf '%s\n' "$out" | grep -F 'still carries the unfilled {TASK} placeholder' >/dev/null \
    && fail "a task description quoting {TASK} was wrongly treated as unfilled"
  printf '%s\n' "$out" | grep -F 'delivery mismatch for quoted-ship' >/dev/null \
    || fail "the quoting brief did not reach the next gate (got: $out)"
  pass "fm-spawn.sh: a task description that quotes {TASK} inline is not treated as unfilled"
}

test_unfilled_brief_is_refused
test_filled_brief_is_not_refused
test_placeholder_quoted_in_task_text_is_not_refused
