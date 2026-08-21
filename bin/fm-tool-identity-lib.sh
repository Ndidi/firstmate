#!/usr/bin/env bash
# bin/fm-tool-identity-lib.sh - single owner of "is the executable on PATH
# actually the tool we mean?"
#
# `command -v <name>` answers a question about a NAME, never about a TOOL. Every
# such check is one namespace collision away from lying, and one already did:
# GNOME ships its screen reader as /usr/bin/orca, so a plain `command -v orca`
# reports the Orca session backend as installed on any GNOME desktop, and the
# operator is told the backend is ready right up until a spawn fails.
#
# This library replaces that name lookup with an identity probe wherever a wrong
# answer is costly. A tool with no registered probe keeps plain presence
# semantics, so adopting it is never a behavior change on its own.
#
# API:
#   fm_tool_identify <tool>        0 = identified, 1 = absent, 2 = present but not <tool>
#   fm_tool_identity_reason <tool> one line naming the SPECIFIC missing requirement
#   fm_tool_present <tool>         convenience boolean over fm_tool_identify
#
# fm_tool_identity_reason is the operator-facing half: a bare "not installed" is
# what made the Orca collision cost hours, so a mismatch always names what was
# found instead and where.
#
# Escape hatch: FM_TOOL_IDENTITY_TRUST is a comma-separated tool list whose
# probes are skipped in favor of plain presence. It exists so a real tool whose
# vendor changed its --help surface can never become unusable; it is deliberately
# explicit and per-tool rather than a global off switch.
#
# Probe safety contract, and it is not optional: a probe runs a foreign
# executable, so it must be side-effect free and BOUNDED. Only argument forms
# that print and exit are used - never a subcommand that could start the tool.
# `orca status --json` is exactly the trap: on GNOME's screen reader it does not
# exit, so the identity probe uses `--help`, which is verified to print usage and
# exit on both.

# Seconds any single identity probe may run before it is treated as unidentified.
FM_TOOL_IDENTITY_TIMEOUT=${FM_TOOL_IDENTITY_TIMEOUT:-5}

# Run "$@" with stdout+stderr captured, stdin closed, and a hard wall clock
# bound. Prints whatever the command produced; returns 0 only when the command
# exited 0 within the bound. Implemented without coreutils `timeout` on purpose:
# macOS has no `timeout`, and that is precisely where the Orca CLI lives, so a
# timeout-shaped dependency would make every macOS probe fail closed.
fm_tool_bounded_capture() {  # <cmd> [args...]
  local out rc pid waited limit
  out=$(mktemp "${TMPDIR:-/tmp}/.fm-tool-probe.XXXXXX") || return 1
  limit=$((FM_TOOL_IDENTITY_TIMEOUT * 20))
  "$@" >"$out" 2>&1 </dev/null &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 0.2
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$out"
      return 1
    fi
    sleep 0.05
    waited=$((waited + 1))
  done
  # `rc=0; ... || rc=$?` throughout this file rather than `...; rc=$?`, because
  # this library is sourced into `set -e` scripts and a probe's non-zero verdict
  # is an ANSWER, not an error. The bare form only survives today because every
  # current caller happens to sit in an errexit-suspended context.
  rc=0
  wait "$pid" || rc=$?
  cat "$out"
  rm -f "$out"
  return "$rc"
}

fm_tool_identity_trusted() {  # <tool>
  local tool=$1 entry
  local old_ifs=$IFS
  IFS=,
  for entry in ${FM_TOOL_IDENTITY_TRUST:-}; do
    if [ "$entry" = "$tool" ]; then
      IFS=$old_ifs
      return 0
    fi
  done
  IFS=$old_ifs
  return 1
}

# --- per-tool probes --------------------------------------------------------
#
# A probe receives the resolved absolute path and prints nothing. It returns 0
# when the executable proves itself, and 2 when it proves itself something else.
# Anything a probe cannot positively identify is a refusal, so an unrecognised
# build is reported rather than launched on a guess.

# GNOME's Orca is a screen reader that answers to the same name as the Orca
# session backend. Two independent readings of one bounded --help: the backend
# CLI advertises the worktree and terminal surface Firstmate drives, and the
# screen reader advertises speech options and its own GNOME issue tracker.
# The screen-reader reading wins when both somehow match, because proof of a
# different tool outranks a keyword that could appear anywhere.
FM_TOOL_IDENTITY_FOUND=

fm_tool_probe_orca() {  # <path>
  local path=$1 help
  FM_TOOL_IDENTITY_FOUND=
  help=$(fm_tool_bounded_capture "$path" --help) || help=
  case "$help" in
    *"screen reader"*|*"--speech-system"*|*"GNOME/orca"*)
      FM_TOOL_IDENTITY_FOUND="GNOME's Orca screen reader"
      return 2
      ;;
  esac
  case "$help" in
    *worktree*|*terminal*) return 0 ;;
  esac
  FM_TOOL_IDENTITY_FOUND="an executable whose --help does not describe the Orca CLI's worktree or terminal commands"
  return 2
}

fm_tool_probe_for() {  # <tool>; echoes the probe function name, or nothing
  case "$1" in
    orca) printf '%s\n' fm_tool_probe_orca ;;
    *) return 1 ;;
  esac
}

# --- public API -------------------------------------------------------------

# Verdicts are memoized per (tool, resolved path) for the life of the process.
# A probe execs a foreign binary, so an unmemoized check would change how often
# that tool is invoked - which is a real behavior change, not just a cost.
FM_TOOL_IDENTITY_MEMO_KEY=
FM_TOOL_IDENTITY_MEMO_RC=
FM_TOOL_IDENTITY_MEMO_FOUND=

# 0 = present and identified, 1 = not on PATH, 2 = on PATH but not this tool.
fm_tool_identify() {  # <tool>
  local tool=$1 path probe rc key
  path=$(command -v "$tool" 2>/dev/null) || return 1
  [ -n "$path" ] || return 1
  fm_tool_identity_trusted "$tool" && return 0
  probe=$(fm_tool_probe_for "$tool") || return 0
  key="$tool@$path"
  if [ "$key" = "$FM_TOOL_IDENTITY_MEMO_KEY" ]; then
    FM_TOOL_IDENTITY_FOUND=$FM_TOOL_IDENTITY_MEMO_FOUND
    return "$FM_TOOL_IDENTITY_MEMO_RC"
  fi
  rc=0
  "$probe" "$path" || rc=$?
  FM_TOOL_IDENTITY_MEMO_KEY=$key
  FM_TOOL_IDENTITY_MEMO_RC=$rc
  FM_TOOL_IDENTITY_MEMO_FOUND=$FM_TOOL_IDENTITY_FOUND
  return "$rc"
}

fm_tool_present() {  # <tool>
  fm_tool_identify "$1" >/dev/null 2>&1
}

# One line naming the SPECIFIC missing requirement, for a diagnostic or a test
# skip reason. Empty (and non-zero) when the tool is properly identified.
fm_tool_identity_reason() {  # <tool>
  local tool=$1 rc path found
  rc=0
  fm_tool_identify "$tool" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 1 ;;
    1) printf "%s is not installed\n" "$tool" ;;
    *)
      path=$(command -v "$tool" 2>/dev/null || printf '%s' "$tool")
      found=${FM_TOOL_IDENTITY_FOUND:-}
      if [ -n "$found" ]; then
        printf '%s is not installed; %s is %s\n' "$tool" "$path" "$found"
      else
        printf '%s is not installed; %s is a different tool of the same name\n' "$tool" "$path"
      fi
      ;;
  esac
  return 0
}
