#!/usr/bin/env bash
# bin/fm-unowned-window-lib.sh - detect `fm-*` terminal windows that no task in
# THIS home claims, so a window firstmate cannot see is reported rather than
# left for the captain to find.
#
# WHY. Firstmate reconciles the fleet from state/<id>.meta, so a window no task
# owns simply does not appear in the fleet view. On 2026-08-19 the captain asked
# what the crew was working on, firstmate answered "one worker", and the captain
# could see two - the extra one an `fm-unfilled-ship` window left behind by a
# test, owned by nothing. The captain could see it and firstmate could not. This
# check closes that specific gap: it is the thing that would have caught the
# leak before they did.
#
# STRICTLY DETECT-ONLY, AND DELIBERATELY SO. This library never kills, renames,
# or otherwise touches a window, and callers must not either. Several firstmate
# homes can share one terminal server, and a secondmate home's crew windows are
# recorded in that home's own state directory, not this one. So a window this
# home does not recognise is NOT evidence the window is dead - it may be another
# home's live work. The only safe action is to report it and let the captain
# decide, which is why the output is an informational fact rather than a
# diagnostic that asks for remediation.
#
# SCOPE. tmux only, which is the verified reference backend and the one whose
# windows carry fm-spawn.sh's `fm-<task-id>` naming. Silent on every other
# backend, when tmux is absent, and when no server is running - a check that
# cannot run must not manufacture output.

# fm_unowned_windows <state-dir>: print one "<session>:<window>" per line for
# every `fm-*` window on the current tmux server that no <state-dir>/*.meta
# file claims via its `window=` field. Prints nothing (exit 0) when tmux is
# absent, no server is running, or every window is accounted for.
#
# Matching is on the full "<session>:<window>" target exactly as fm-spawn.sh
# records it, so an identically-named window in a different session is still
# correctly reported as unclaimed rather than silently absorbed.
fm_unowned_windows() {  # <state-dir>
  local state_dir=${1:-} live claimed target

  command -v tmux >/dev/null 2>&1 || return 0

  # No server, or an unreadable one, is not a finding.
  live=$(tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null) || return 0
  [ -n "$live" ] || return 0

  claimed=$(
    if [ -n "$state_dir" ] && [ -d "$state_dir" ]; then
      # A missing glob expands to a literal path grep simply will not match.
      grep -h '^window=' "$state_dir"/*.meta 2>/dev/null | sed 's/^window=//'
    fi
  )

  while IFS= read -r target; do
    [ -n "$target" ] || continue
    # Only fm-spawn.sh's own naming is in scope; the captain's other windows are
    # none of firstmate's business.
    case "${target##*:}" in
      fm-*) ;;
      *) continue ;;
    esac
    printf '%s\n' "$claimed" | grep -qxF "$target" && continue
    printf '%s\n' "$target"
  done <<EOF
$live
EOF
}

# fm_unowned_window_report <state-dir>: the caller-facing wrapper. Emits one
# BOOTSTRAP_INFO fact per unclaimed window - an existing no-action prefix, chosen
# so this adds no new diagnostic contract and needs no handling playbook. The
# wording states the uncertainty rather than hiding it, because "unrecognised"
# and "abandoned" are not the same claim and only the captain can tell them apart.
fm_unowned_window_report() {  # <state-dir>
  local target
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    echo "BOOTSTRAP_INFO: window $target is not claimed by any task in this home - it may be a leftover, or another firstmate home's live work; nothing was touched"
  done <<EOF
$(fm_unowned_windows "${1:-}")
EOF
}
