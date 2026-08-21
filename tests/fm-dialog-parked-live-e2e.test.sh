#!/usr/bin/env bash
# tests/fm-dialog-parked-live-e2e.test.sh - the live parked-confirmation guard
# (live-harness-optin family; task fm-dialog-parked-worker-surfaces).
#
# The `dialog` verdict in bin/fm-composer-lib.sh is decided from vendor-rendered
# output, so per .agents/skills/firstmate-coding-guidelines ("Harness-dependent
# checks") a stub can only confirm the assumption already written into the stub.
# This guard drives every INSTALLED verified harness to draw a REAL confirmation
# and requires the real reader to prove it, failing loudly with the harness name
# and version. The portable regression
# (tests/fm-dialog-parked.test.sh) pins the classifier's logic everywhere CI runs
# tmux; this one is what catches a harness that changed how it DRAWS.
#
# Two axes per harness, because a false positive is the expensive direction:
#   1. a real confirmation must classify `dialog`;
#   2. that harness's ordinary IDLE composer must NOT, so the guard cannot pass
#      by calling everything a dialog.
#
# HOW EACH HARNESS IS DRIVEN TO A CONFIRMATION. There is no vendor-neutral way to
# demand one, so each is driven by the cheapest prompt that reliably produces its
# own guard, and a harness with no reachable mid-run confirmation under its
# autonomy flag is reported as NOT VERIFIED rather than silently skipped:
#   claude  - `rm -rf` on the session's own working directory or an ancestor.
#             claude's hardcoded dangerous-rm guard fires even under
#             --dangerously-skip-permissions, which is the exact shape the
#             defect was observed on. The target is this run's own throwaway
#             temp directory and the answer is always No, so nothing outside it
#             can be reached even if the guard were to be answered.
#   others  - see harness_confirm_prompt below.
#
# This spends a small number of model tokens per installed harness: a
# confirmation cannot be rendered without a turn that reaches a tool call. That
# cost is the point - it is what a stub cannot buy.
#
# Run explicitly with FM_DIALOG_LIVE=1. An absent harness is reported explicitly
# and skipped; a run that verified nothing fails rather than passing vacuously.
# Refresh docs/verification/runtime-backends.md ("Parked-confirmation
# detection") from this guard's output after any harness upgrade.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${FM_DIALOG_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_DIALOG_LIVE=1 to run the live parked-confirmation guard"
  exit 0
fi

command -v tmux >/dev/null 2>&1 \
  || { echo "not ok - FM_DIALOG_LIVE=1 but tmux is not installed" >&2; exit 1; }

SOCKET="fm-dlg-live-$$"
SESSION="dlglive"
WORKROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-dlg-live.XXXXXX")
CHECKED=0
FAILED=0
UNREACHED=""

note() { printf '# %s\n' "$1"; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$WORKROOT"
  rm -rf "$SHIM_DIR"
}
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
trap cleanup EXIT

# The reader under test, driven against a private socket through a PATH shim so
# its bare `tmux` calls can never reach the operator's live fleet.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-dlg-shim.XXXXXX")
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 200 -y 50 -c "$WORKROOT"

harness_version() {  # <binary>
  "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'
}

# The launch argv for one harness, with the autonomy flag firstmate spawns it
# with (bin/fm-spawn.sh), because a confirmation that only appears WITHOUT that
# flag would prove nothing about a real crewmate.
harness_launch() {  # <name> <workdir>
  case "$1" in
    claude)   printf '%s\n' env CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions ;;
    codex)    printf '%s\n' codex --dangerously-bypass-approvals-and-sandbox ;;
    opencode) printf '%s\n' opencode ;;
    grok)     printf '%s\n' grok --dangerously-skip-permissions ;;
    kimi)     printf '%s\n' kimi ;;
    pi)       printf '%s\n' pi ;;
    muse)     printf '%s\n' muse ;;
    cursor-agent) printf '%s\n' cursor-agent --force ;;
    *) return 1 ;;
  esac
}

# The prompt that drives one harness to its own mid-run confirmation, or empty
# when this guard knows of no reachable one for it. Empty is reported as an
# unverified axis, never as a pass.
harness_confirm_prompt() {  # <name> <workdir>
  local name=$1 dir=$2
  case "$name" in
    claude|codex|grok|kimi|cursor-agent|opencode|muse|pi)
      # Every verified harness runs shell commands, and a destructive `rm` of
      # the session's own working directory is the one operation a harness is
      # most likely to guard regardless of its autonomy flag. A harness that
      # does not guard it simply fails to produce a confirmation and is
      # reported unreached, which is the honest result.
      printf 'Run exactly this bash command, nothing else, no preamble: rm -rf %s' "$dir"
      ;;
    *) return 1 ;;
  esac
}

# Decline whatever is on screen with the one key that commits nothing. Enter is
# NEVER sent here, because on a confirmation Enter SELECTS the highlighted
# option - which on the dangerous-rm guard this test deliberately provokes means
# performing the deletion.
decline() {  # <window>
  tmux -L "$SOCKET" send-keys -t "$SESSION:$1" Escape 2>/dev/null || true
}

# A STARTUP modal is different, and the difference is load-bearing: on a trust
# prompt Escape EXITS the harness (verified live, claude 2.1.238 - an earlier
# revision of this guard lost every mid-run result that way), so a trust prompt
# must be accepted rather than declined. Accepting is safe only because the
# working directory is this run's own mktemp tree, created above and deleted on
# exit; it is never the operator's checkout. Any other startup modal - a vendor
# update offer - is still declined with Escape, which commits nothing.
clear_startup_modal() {  # <window>
  local screen
  screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$1" 2>/dev/null || true)
  if printf '%s\n' "$screen" | grep -qi 'trust'; then
    tmux -L "$SOCKET" send-keys -t "$SESSION:$1" Enter 2>/dev/null || true
  else
    tmux -L "$SOCKET" send-keys -t "$SESSION:$1" Escape 2>/dev/null || true
  fi
}

# Wait for the harness's idle composer, proving the launch worked before any
# claim is made about what it draws later.
wait_for_idle_composer() {  # <window> <budget>
  local win=$1 budget=$2 i=0
  while [ "$i" -lt "$budget" ]; do
    [ "$(fm_tmux_composer_state "$SESSION:$win")" = empty ] && return 0
    i=$((i + 1))
    sleep 1
  done
  return 1
}

wait_for_dialog() {  # <window> <budget>
  local win=$1 budget=$2 i=0
  while [ "$i" -lt "$budget" ]; do
    [ "$(fm_tmux_composer_state "$SESSION:$win")" = dialog ] && return 0
    i=$((i + 1))
    sleep 1
  done
  return 1
}

dump_tail() {  # <window> <label>
  printf '# %s pane tail:\n' "$2" >&2
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$1" 2>/dev/null \
    | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
}

check_harness() {  # <name>
  local name=$1 win="dlg-$1" version dir prompt launch=() idle_budget dlg_budget
  version=$(harness_version "$name")
  idle_budget=${FM_DIALOG_LIVE_IDLE_POLLS:-45}
  dlg_budget=${FM_DIALOG_LIVE_DIALOG_POLLS:-90}

  # A throwaway working directory per harness: this is the path the prompt asks
  # the agent to delete, so it must own nothing else.
  dir="$WORKROOT/$name/victim"
  mkdir -p "$dir"
  printf 'sacrificial\n' > "$dir/file.txt"

  while IFS= read -r a; do launch+=("$a"); done < <(harness_launch "$name" "$dir") \
    || { note "no launch recipe, not verified here: $name"; UNREACHED="$UNREACHED $name(launch)"; return; }

  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$dir" -- "${launch[@]}" \
    || { FAILED=1; printf 'not ok - %s (%s): could not launch in the isolated tmux server\n' "$name" "$version" >&2; return; }

  if ! wait_for_idle_composer "$win" "$idle_budget"; then
    # A trust or update modal at startup is itself a confirmation, and the
    # reader must already prove it. Distinguish that from a launch failure.
    if [ "$(fm_tmux_composer_state "$SESSION:$win")" = dialog ]; then
      CHECKED=$((CHECKED + 1))
      pass "$name ($version): a startup confirmation classifies dialog"
      clear_startup_modal "$win"
      if ! wait_for_idle_composer "$win" "$idle_budget"; then
        note "$name ($version): could not reach an idle composer after declining its startup modal; mid-run axis not verified"
        UNREACHED="$UNREACHED $name(mid-run)"
        tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
        return
      fi
    else
      dump_tail "$win" "$name"
      FAILED=1
      printf 'not ok - %s (%s): never reached an idle composer, so nothing about its confirmations was proven\n' \
        "$name" "$version" >&2
      tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
      return
    fi
  fi

  # AXIS 2 first, while the composer is provably idle: an ordinary composer must
  # NOT read dialog. Without this the guard could pass by calling everything one.
  if [ "$(fm_tmux_composer_state "$SESSION:$win")" = dialog ]; then
    dump_tail "$win" "$name"
    FAILED=1
    printf 'not ok - %s (%s): an ordinary IDLE composer classified dialog (false positive)\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return
  fi
  CHECKED=$((CHECKED + 1))
  pass "$name ($version): an ordinary idle composer is not mistaken for a confirmation"

  # AXIS 1: drive it to a real confirmation.
  if ! prompt=$(harness_confirm_prompt "$name" "$dir"); then
    note "$name ($version): no known mid-run confirmation trigger; that axis NOT verified"
    UNREACHED="$UNREACHED $name(mid-run)"
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return
  fi
  tmux -L "$SOCKET" send-keys -t "$SESSION:$win" -l "$prompt"
  sleep 1
  tmux -L "$SOCKET" send-keys -t "$SESSION:$win" Enter

  if wait_for_dialog "$win" "$dlg_budget"; then
    CHECKED=$((CHECKED + 1))
    pass "$name ($version): a real mid-run confirmation classifies dialog"
    # It must also stay un-injectable, which is the safety half of the verdict.
    if ! fm_pane_input_pending "$SESSION:$win"; then
      FAILED=1
      printf 'not ok - %s (%s): a confirmation did not defer injection\n' "$name" "$version" >&2
    fi
  else
    dump_tail "$win" "$name"
    note "$name ($version): no confirmation appeared for a destructive rm of its own working directory; that axis NOT verified"
    UNREACHED="$UNREACHED $name(mid-run)"
  fi
  decline "$win"
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

for h in claude codex opencode pi grok kimi muse cursor-agent; do
  if command -v "$h" >/dev/null 2>&1; then
    check_harness "$h"
  else
    note "harness absent, not verified here: $h"
    UNREACHED="$UNREACHED $h(absent)"
  fi
done

[ -z "$UNREACHED" ] || note "axes NOT verified by this run:$UNREACHED"
[ "$FAILED" -eq 0 ] || fail "live parked-confirmation guard observed failures above"
[ "$CHECKED" -gt 0 ] \
  || fail "live parked-confirmation guard verified nothing (no harness installed?); refusing a vacuous pass"
pass "live parked-confirmation guard verified $CHECKED live axis/axes"
