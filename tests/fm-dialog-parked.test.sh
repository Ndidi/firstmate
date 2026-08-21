#!/usr/bin/env bash
# tests/fm-dialog-parked.test.sh - the parked-on-a-confirmation shape
# (bin/fm-composer-lib.sh's `dialog` verdict and bin/fm-watch.sh's dialog_check).
#
# THE DEFECT, observed live 2026-08-21 on claude 2.1.238: a worker hit claude's
# hardcoded dangerous-`rm` confirmation - the one that fires even under
# --dangerously-skip-permissions - and parked on it. The harness stayed mid-turn,
# so every busy source correctly reported busy and bin/fm-crew-state.sh reported
# `working`. Nothing surfaced for an hour, until BUSY_TURN_MAX_SECS routed the
# pane through the wedge timer wearing the generic "stopped responding" wording -
# the opposite of the truth, which was a healthy worker awaiting one keypress.
#
# Worse, the shape read `pending`: claude marks its selected option with the same
# `❯` it draws its composer with, so `❯ 1. Yes` looked like a composer holding
# typed text - and `pending` is the one verdict both submit loops RETRY ENTER on.
# Enter on that dialog picks `1. Yes`.
#
# WHAT THIS PINS. Per .agents/skills/firstmate-coding-guidelines ("Harness-dependent
# checks") this classifier reads vendor-rendered output, so it needs a portable
# regression with real processes and no harness (here) AND a live guard against
# the real harnesses (tests/fm-dialog-parked-live-e2e.test.sh). The cases below
# render the observed shapes into REAL tmux panes from REAL processes, then:
#   1. the observed confirmation classifies `dialog`, never `empty`, and stays
#      un-injectable, so the strict blank-row posture is strengthened not weakened;
#   2. the verdict SURVIVES losing any one of the corroborating signals, and each
#      case asserts the divergence itself - that the signal really left the probe's
#      signal list - so a case cannot pass vacuously;
#   3. the containment precondition refuses every shape that merely LOOKS like a
#      dialog while a live composer is drawn around or below it;
#   4. the watcher surfaces it on its own `dialog:` reason naming the task and the
#      question, whether the pane reads busy or idle, absorbs a repeat of the same
#      screen, and still leaves BUSY_TURN_MAX_SECS owning the no-dialog hang.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=tests/tmux-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/tmux-test-safety.sh"

fm_require_tool "the parked-confirmation shape" tmux || exit 0
tmux_isolate_or_fail dialog-parked
trap fm_tmux_test_cleanup EXIT

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-dialog-parked-tests)
WATCH="$ROOT/bin/fm-watch.sh"
SESSION=firstmate
RULE='──────────────────────────────────────────────────────────────'

# --- the fixtures -----------------------------------------------------------
# Transcribed from the live capture rather than replayed from a stored byte
# dump, so each case states the shape it depends on in readable form and a
# reviewer can see exactly which signal a variant removes.

full_dialog() {
  cat <<EOF
$RULE
 Bash command

   │ rm -rf /tmp/fixture/victim
   Remove the fixture directory

 │ Dangerous rm operation on the working directory or an ancestor

 Do you want to proceed?
 ❯ 1. Yes
   2. No

 Esc to cancel · Tab to amend · ctrl+e to explain
EOF
}

# Each variant removes exactly ONE independent signal.
without_selection() { full_dialog | sed 's/^ ❯ 1\. Yes$/   1. Yes/'; }
without_keyhint()   { full_dialog | sed '/^ Esc to cancel/d'; }
without_question()  { full_dialog | sed 's/^ Do you want to proceed?$/ Reviewing the command/'; }
# Not a corroborating signal but the structural ANCHOR: see the deliberate
# boundary case below.
without_numbering() { full_dialog | sed 's/^ ❯ 1\. Yes$/ ❯ Yes/; s/^   2\. No$/   No/'; }

# The adversarial negative: the SAME option rows a human typed into a live
# composer. Byte-identical choices; only the enclosing composer rules differ.
typed_into_composer() {
  cat <<EOF
 earlier transcript output
$RULE
❯ 1. Yes
  2. No
$RULE
  bypass permissions on
EOF
}

# A quoted confirmation scrolled up the transcript, live composer still below.
composer_still_below() {
  cat <<EOF
 Do you want to proceed?
 ❯ 1. Yes
   2. No

 Esc to cancel · Tab to amend
$RULE
❯
$RULE
EOF
}

# A capture window that clipped the composer's OPENING rule but kept its
# closing one: without the separator-below rule this reads as a dialog.
keyhole_window() {
  cat <<EOF
❯ 1. Yes
  2. No
$RULE
  bypass permissions on
EOF
}

# An agent that exited to a plain login shell after printing a numbered list.
dead_shell_below() {
  cat <<'EOF'
 Do you want to proceed?
 ❯ 1. Yes
   2. No
 Esc to cancel
$
EOF
}

# --- real panes -------------------------------------------------------------

# draw <window> <fixture-fn> [cursor-up-rows]: render the fixture into a real
# tmux pane from a real process, then park that process so the pane keeps the
# rendered bytes. No harness is involved: the classifier sees exactly the rows a
# terminal drew. cursor-up-rows moves the terminal cursor back onto a chosen row
# so a case can place it where the real harness would.
draw() {  # <window> <fixture-fn> [cursor-up-rows]
  local win=$1 fn=$2 up=${3:-0} file="$TMP_ROOT/$1.screen"
  "$fn" > "$file"
  tmux new-window -d -t "$SESSION:" -n "$win" \
    -- bash -c "cat '$file'; [ '$up' -gt 0 ] && printf '\033[${up}A'; exec sleep 300" \
    || fail "could not create pane $win on the isolated server"
  # Wait for the pane to actually carry the fixture rather than sleeping a guess.
  local i=0
  while [ "$i" -lt 50 ]; do
    case "$(tmux capture-pane -p -t "$SESSION:$win" 2>/dev/null)" in
      *'2. No'*|*'  No'*) return 0 ;;
    esac
    i=$((i + 1))
    sleep 0.1
  done
  fail "pane $win never rendered its fixture"
}

# probe_signals <window>: the probe's signal list for a real pane, or the empty
# string when no dialog is proven. Goes through the public probe on a real
# capture, never through the library's internals.
probe_signals() {  # <window>
  local screen out
  screen=$(tmux capture-pane -p -e -t "$SESSION:$1" 2>/dev/null) || return 1
  out=$(fm_composer_dialog_probe "$(fm_tmux_composer_caps)" "$screen") || return 1
  printf '%s' "$out" | cut -f1
}

probe_question() {  # <window>
  local screen out
  screen=$(tmux capture-pane -p -e -t "$SESSION:$1" 2>/dev/null) || return 1
  out=$(fm_composer_dialog_probe "$(fm_tmux_composer_caps)" "$screen") || return 1
  printf '%s' "$out" | cut -f2
}

# --- 1. the observed confirmation is proven, and is not injectable -----------

test_observed_confirmation_classifies_dialog() {
  local verdict signals
  draw obs full_dialog
  verdict=$(fm_tmux_composer_state "$SESSION:obs")
  [ "$verdict" = dialog ] \
    || fail "the observed claude confirmation must classify dialog, got '$verdict'"
  [ "$verdict" != empty ] \
    || fail "a confirmation must never classify empty (the strict blank-row posture)"
  fm_pane_input_pending "$SESSION:obs" \
    || fail "a confirmation must defer injection, not be treated as a free composer"
  signals=$(probe_signals obs)
  case "$signals" in
    *options*) ;;
    *) fail "the observed confirmation lost its structural anchor: signals '$signals'" ;;
  esac
  pass "fm_tmux_composer_state: a real parked confirmation classifies dialog and stays un-injectable"
}

test_dialog_payload_names_the_question() {
  local question
  question=$(probe_question obs)
  [ "$question" = "Do you want to proceed?" ] \
    || fail "the probe must carry the question a supervisor needs, got '$question'"
  pass "fm_composer_dialog_probe: the payload names the question being asked"
}

test_dialog_verdict_does_not_depend_on_the_cursor() {
  # The confirmation is proven before any cursor-anchored shape selection, so a
  # backend with no cursor capability reads it identically. This is what lets
  # every session provider learn the shape from the one owner.
  local with_cursor without_cursor screen
  screen=$(tmux capture-pane -p -e -t "$SESSION:obs" 2>/dev/null)
  with_cursor=$(fm_composer_classify_screen "$(fm_tmux_composer_caps)" "$screen" 0)
  without_cursor=$(fm_composer_classify_screen "$(printf 'styled=1\nrows=40\n')" "$screen" '')
  [ "$with_cursor" = dialog ] && [ "$without_cursor" = dialog ] \
    || fail "the dialog verdict must not depend on cursor capability (got '$with_cursor' / '$without_cursor')"
  pass "fm_composer_classify_screen: the dialog verdict is identical with and without a cursor"
}

# --- 2. the verdict survives losing any ONE corroborating signal -------------

# assert_survives_without <signal> <window> <fixture-fn>
# Proves BOTH halves of the guarantee, so neither can go quietly vacuous:
#   - the divergence: the named signal is present in the full fixture's signal
#     list and absent from this variant's, so the variant really did remove it;
#   - the survival: the variant is still proven a dialog by what remains.
assert_survives_without() {  # <signal> <window> <fixture-fn>
  local signal=$1 win=$2 fn=$3 full variant
  full=$(probe_signals obs) || fail "the full fixture must be a dialog to compare against"
  case "$full" in
    *"$signal"*) ;;
    *) fail "the full fixture never carried '$signal', so removing it proves nothing (signals: $full)" ;;
  esac
  draw "$win" "$fn"
  variant=$(probe_signals "$win") \
    || fail "removing '$signal' alone must not lose the dialog verdict"
  case "$variant" in
    *"$signal"*) fail "the '$signal' variant still carries that signal (signals: $variant); the case is vacuous" ;;
  esac
  [ "$(fm_tmux_composer_state "$SESSION:$win")" = dialog ] \
    || fail "the '$signal' variant must still classify dialog through the real reader"
  pass "dialog signals: the verdict survives losing '$signal' (remaining: $variant)"
}

test_survives_without_selection() { assert_survives_without selection nosel without_selection; }
test_survives_without_keyhint()   { assert_survives_without keyhint nokey without_keyhint; }
test_survives_without_question()  { assert_survives_without question noq without_question; }

test_numbering_anchor_is_a_declared_boundary() {
  # The numbered choice list is the ANCHOR, not a corroborating signal: it is
  # what the containment precondition is measured against, and without it a
  # glyph-marked run is indistinguishable from a bare-glyph composer holding a
  # multi-line message (codex, muse and cursor all draw one). Refusing here is
  # the deliberate ambiguity boundary - false positives are the expensive
  # direction, and BUSY_TURN_MAX_SECS still covers what this declines to judge.
  draw nonum without_numbering
  if probe_signals nonum >/dev/null 2>&1; then
    fail "an unnumbered choice run must NOT be proven a dialog; that boundary is deliberate"
  fi
  pass "dialog anchor: an unnumbered choice run is declined, not guessed"
}

# --- 3. containment refuses every look-alike --------------------------------

assert_not_a_dialog() {  # <window> <fixture-fn> <why> [cursor-up]
  local win=$1 fn=$2 why=$3 up=${4:-0} signals
  draw "$win" "$fn" "$up"
  if signals=$(probe_signals "$win"); then
    fail "$why must not be proven a dialog (signals: $signals)"
  fi
  pass "dialog containment: $why is refused"
}

test_typed_numbered_list_in_a_composer_is_refused() {
  # The load-bearing negative. These option rows are byte-identical to the real
  # confirmation's; only the enclosing composer rules differ, which is why the
  # precondition is expressed in the composer catalogue's own shapes rather than
  # in any property of the rows themselves.
  assert_not_a_dialog typed typed_into_composer "a numbered list typed into a live composer" 3
  # Assert the divergence: the enclosing rules really are what changed.
  local screen rules
  screen=$(tmux capture-pane -p -t "$SESSION:typed" 2>/dev/null)
  rules=$(printf '%s\n' "$screen" | grep -c '^──' || true)
  [ "$rules" -ge 2 ] \
    || fail "the typed-composer fixture must actually be enclosed by two rules, found $rules"
}

test_quoted_confirmation_with_composer_below_is_refused() {
  assert_not_a_dialog quoted composer_still_below "a confirmation with a live composer still below it"
}

test_keyhole_capture_is_refused() {
  assert_not_a_dialog keyhole keyhole_window "a capture window that clipped the composer's opening rule"
}

test_dead_shell_below_is_refused() {
  assert_not_a_dialog deadsh dead_shell_below "a numbered list above a dead-shell prompt"
}

# --- 4. the current-state reader stops calling it working -------------------

# crew_state_of <window>: bin/fm-crew-state.sh's one canonical line for a task
# whose recorded endpoint is <window> on the isolated server. No no-mistakes run
# is attributed, so the reader falls through to the pane, which is the path the
# defect lived on.
crew_state_of() {  # <window>
  local win=$1 dir
  dir="$TMP_ROOT/cs-$win"
  mkdir -p "$dir/state" "$dir/wt"
  cat > "$dir/state/cs.meta" <<META
window=$SESSION:$win
worktree=$dir/wt
harness=claude
kind=scout
backend=tmux
META
  : > "$dir/state/cs.status"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CREW_STATE_NM_TIMEOUT=2 "$ROOT/bin/fm-crew-state.sh" cs 2>/dev/null
}

test_crew_state_reports_parked_not_working() {
  local line
  line=$(crew_state_of obs)
  case "$line" in
    'state: parked'*) ;;
    *) fail "a parked confirmation must read parked, not working; got '$line'" ;;
  esac
  case "$line" in
    *'awaiting a human answer'*) ;;
    *) fail "the current-state line must say a human answer is owed; got '$line'" ;;
  esac
  case "$line" in
    *'Do you want to proceed?'*) ;;
    *) fail "the current-state line must name the question; got '$line'" ;;
  esac
  pass "fm-crew-state.sh: a parked confirmation reads parked, naming the question, not working"
}

test_parked_is_never_absorbed_as_provably_working() {
  # crew_absorb_class is what the watcher's stale triage consults, and `working`
  # from a run-step or pane is the only verdict it absorbs on. A parked crew must
  # therefore be surfaced by the generic path too, not only by the dialog reason.
  local stub dir class
  dir="$TMP_ROOT/absorb"
  mkdir -p "$dir"
  stub="$dir/fm-crew-state.sh"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
printf 'state: parked · source: pane · awaiting a human answer: Do you want to proceed?
'
SH
  chmod +x "$stub"
  class=$(FM_CREW_STATE_BIN="$stub" bash -c '. "$1/bin/fm-classify-lib.sh"; crew_absorb_class t' _ "$ROOT")
  [ "$class" = none ] \
    || fail "a parked crew must not be absorbed as provably working, got '$class'"
  pass "fm-classify-lib.sh: a parked confirmation is never absorbed as provably working"
}

# --- 5. the watcher surfaces it on its own reason ---------------------------

# A watcher case drives the REAL bin/fm-watch.sh over a fake tmux serving one
# recorded capture, which is how every other watcher test isolates the poll loop.
# The pane content itself is still the real rendered fixture: it is captured from
# the isolated server above and replayed byte for byte.
make_dialog_case() {  # <name> <fixture-window> -> dir
  local name=$1 win=$2 dir
  dir=$(make_case "$name")
  tmux capture-pane -p -e -t "$SESSION:$win" > "$dir/capture"
  cat > "$dir/state/parkedtask.meta" <<META
window=firstmate:fm-parkedtask
worktree=$dir
harness=claude
kind=scout
backend=tmux
META
  : > "$dir/state/parkedtask.status"
  prime_signals "$dir"
  printf '%s\n' "$dir"
}

# Declare every status and turn-end signal already surfaced, so these cases
# exercise the pane loop rather than the separate signal path that would
# otherwise fire first on a freshly written fixture.
prime_signals() {  # <dir>
  local dir=$1 f
  for f in "$dir"/state/*.status "$dir"/state/*.turn-ended; do
    [ -e "$f" ] || continue
    prime_status_seen "$dir/state" "$f"
  done
}

# The watcher exits only on an ACTIONABLE wake, so a case expecting one runs it
# in the foreground and reads what it printed, while a case expecting an ABSORB
# must run it in the background and wait on its poll beacon - see
# wait_watcher_cycles in tests/wake-helpers.sh for why a stretch of clock will
# not do.
watch_env() {  # <dir>
  printf '%s\n' \
    "FM_STATE_OVERRIDE=$1/state" \
    "FM_CREW_STATE_BIN=$1/fakebin/fm-crew-state.sh" \
    "FM_FAKE_TMUX_WINDOW=firstmate:fm-parkedtask" \
    "FM_FAKE_TMUX_CAPTURE=$1/capture" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
}

run_watch_once() {  # <dir> <out> [extra env...]
  local dir=$1 out=$2
  shift 2
  local base=()
  while IFS= read -r kv; do base+=("$kv"); done < <(watch_env "$dir")
  PATH="$dir/fakebin:$PATH" env "${base[@]}" "$@" "$WATCH" > "$out" 2>/dev/null
}

run_watch_bg() {  # <dir> <out> [extra env...]
  local dir=$1 out=$2
  shift 2
  local base=()
  while IFS= read -r kv; do base+=("$kv"); done < <(watch_env "$dir")
  PATH="$dir/fakebin:$PATH" env "${base[@]}" "$@" "$WATCH" > "$out" 2>/dev/null &
}

test_watcher_surfaces_a_dialog_wake() {
  local dir out reason record
  dir=$(make_dialog_case watch-surface obs)
  out="$dir/out"
  run_watch_once "$dir" "$out" || true
  reason=$(cat "$out" 2>/dev/null)
  case "$reason" in
    dialog:*) ;;
    *) fail "a parked confirmation must surface on its own dialog: reason, got '$reason'" ;;
  esac
  case "$reason" in
    *stale*) fail "a parked confirmation must not be reported as stale: '$reason'" ;;
  esac
  case "$reason" in
    *fm-parkedtask*) ;;
    *) fail "the reason must name the task, got '$reason'" ;;
  esac
  case "$reason" in
    *'Do you want to proceed?'*) ;;
    *) fail "the reason must carry enough of the question to decide, got '$reason'" ;;
  esac
  record=$(awk -F '\t' '$3 == "dialog"' "$dir/state/.wake-queue" 2>/dev/null)
  [ -n "$record" ] \
    || fail "the dialog wake must be durable in the queue, not printed only"
  pass "fm-watch.sh: a parked confirmation surfaces immediately on a dialog: reason naming the question"
}

test_dialog_surfaces_even_while_the_pane_reads_busy() {
  # The exact incident: the harness is mid-turn, so busy is TRUE and correct,
  # and the stale path is never reached. Detection must not depend on it.
  local dir out reason
  dir=$(make_dialog_case watch-busy obs)
  out="$dir/out"
  run_watch_once "$dir" "$out" FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (claude-hook)' || true
  reason=$(cat "$out" 2>/dev/null)
  case "$reason" in
    dialog:*) ;;
    *) fail "a busy pane parked on a confirmation must still surface a dialog wake, got '$reason'" ;;
  esac
  pass "fm-watch.sh: a confirmation surfaces even while every busy source reports busy"
}

# Queued wakes stay durable until acknowledged, and an unacknowledged queue makes
# the next watcher start resurface its downtime instead of polling. Consume each
# run through the production drain so the following run exercises the pane loop.
queued_dialogs() {  # <dir>
  awk -F '\t' '$3 == "dialog"' "$1/state/.wake-queue" 2>/dev/null | wc -l | tr -d ' '
}

drain_and_ack() {  # <dir>
  local dir=$1
  local err="$dir/drain.err"
  FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$err" || true
  ack_drain_err "$dir/state" "$err" || true
  rm -f "$err"
}

test_repeat_of_the_same_screen_is_absorbed_then_resurfaced() {
  local dir out first second third
  dir=$(make_dialog_case watch-repeat obs)
  out="$dir/out"

  run_watch_once "$dir" "$out" || true
  first=$(queued_dialogs "$dir")
  [ "$first" = 1 ] || fail "the first sighting must queue exactly one dialog wake, got $first"
  drain_and_ack "$dir"

  # Same screen, still inside the re-surface window: absorbed. An absorbing
  # watcher never exits, so wait on completed poll cycles and then reap it.
  local pid
  run_watch_bg "$dir" "$out" FM_DIALOG_RESURFACE_SECS=999999
  pid=$!
  if ! wait_watcher_cycles "$dir/state" "$pid"; then
    reap "$pid"
    fail "an unchanged confirmation must be absorbed, but the watcher exited: $(cat "$out" 2>/dev/null)"
  fi
  second=$(queued_dialogs "$dir")
  reap "$pid"
  [ "$second" = 0 ] \
    || fail "an unchanged confirmation must not re-queue every poll, got $second new records"
  drain_and_ack "$dir"

  # Past the window: surfaced again, so an unanswered one cannot rot silently.
  run_watch_once "$dir" "$out" FM_DIALOG_RESURFACE_SECS=0 || true
  third=$(queued_dialogs "$dir")
  [ "$third" -ge 1 ] \
    || fail "an unanswered confirmation must re-surface past its window; nothing was queued"
  awk -F '\t' '$3 == "dialog" && $5 ~ /STILL/' "$dir/state/.wake-queue" 2>/dev/null | grep -q . \
    || fail "the re-surfaced reason must say the confirmation is still unanswered"
  pass "fm-watch.sh: an unchanged confirmation is absorbed, and re-surfaces past its bounded window"
}

test_busy_turn_max_secs_still_owns_the_no_dialog_hang() {
  # The dialog path must not have taken over the hang case: a busy pane with NO
  # confirmation on screen and no completed turn still escalates through the
  # existing wedge timer, on the existing stale reason.
  local dir out reason
  dir=$(make_dialog_case watch-hang typed)   # a live composer, no confirmation
  out="$dir/out"
  # Age the turn marker past the bound so busy_turn_over_age fires.
  : > "$dir/state/parkedtask.turn-ended"
  prime_signals "$dir"
  run_watch_once "$dir" "$out" \
    FM_BUSY_TURN_MAX_SECS=0 FM_STALE_ESCALATE_SECS=0 \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (claude-hook)' || true
  reason=$(cat "$out" 2>/dev/null)
  case "$reason" in
    stale:*) ;;
    *) fail "a busy pane with no confirmation must still reach the wedge path, got '$reason'" ;;
  esac
  case "$reason" in
    dialog:*) fail "a pane with no confirmation must never surface a dialog wake" ;;
  esac
  pass "fm-watch.sh: BUSY_TURN_MAX_SECS still owns the no-confirmation hang"
}

test_observed_confirmation_classifies_dialog
test_dialog_payload_names_the_question
test_dialog_verdict_does_not_depend_on_the_cursor
test_survives_without_selection
test_survives_without_keyhint
test_survives_without_question
test_numbering_anchor_is_a_declared_boundary
test_typed_numbered_list_in_a_composer_is_refused
test_quoted_confirmation_with_composer_below_is_refused
test_keyhole_capture_is_refused
test_dead_shell_below_is_refused
test_crew_state_reports_parked_not_working
test_parked_is_never_absorbed_as_provably_working
test_watcher_surfaces_a_dialog_wake
test_dialog_surfaces_even_while_the_pane_reads_busy
test_repeat_of_the_same_screen_is_absorbed_then_resurfaced
test_busy_turn_max_secs_still_owns_the_no_dialog_hang
