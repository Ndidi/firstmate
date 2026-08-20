#!/usr/bin/env bash
# Per-worker memory bound for spawned direct reports and anything they launch.
# Usage:
#   fm-crew-memory-cap.sh limit            print the effective per-worker limit, or "off"
#   fm-crew-memory-cap.sh status           print "available", or "unavailable: <reason>"
#   fm-crew-memory-cap.sh wrap <command>   print <command> wrapped in the bound, or <command> unchanged
#   fm-crew-memory-cap.sh run <cmd> [arg]  run <cmd> under the bound (ad-hoc heavy scripts)
#   fm-crew-memory-cap.sh report           account for the limit, its source, and availability
#
# WHY THIS EXISTS. On 2026-08-20 one `node` process reached 24.6 GiB resident on
# a 29 GiB host, sustained memory pressure tripped systemd-oomd, and the whole
# user session - desktop, terminal, tmux server, and all six agents - was torn
# down. The six agents cost about 2 GiB between them; they were never the
# problem. This script bounds each worker so one bad allocation can no longer
# reach the host.
#
# THE MECHANISM, and why it is this exact set of properties:
#
#   systemd-run --user --scope -p MemoryMax=<limit> -p MemorySwapMax=0 \
#     -p CollectMode=inactive-or-failed -- <cmd>
#
#   MemoryMax alone is NOT a bound on a host with swap. Verified on this host
#   (systemd 255, 29 GiB RAM, 16 GiB swap): a child under MemoryMax=256M reached
#   6.4 GiB of external allocations and was never killed - the kernel simply
#   reclaimed it into swap. That is the "throttled worker swaps and grinds"
#   failure mode, which presents to supervision as a wedge rather than a death,
#   and it is not hypothetical: the process that took the host down had 7.2 GiB
#   swapped on top of its 24.6 GiB resident. MemorySwapMax=0 is what converts
#   the limit into a hard bound; the same child then dies with SIGKILL (137).
#
#   A scope, not a service, because --scope execs the command in the caller's
#   own process rather than handing it to the service manager: the worker keeps
#   the pane's terminal, process group, environment, PATH, and cwd, and adds no
#   process of its own to the pane's foreground process group. That is what lets
#   the bound be invisible to bin/backends/tmux.sh's liveness classifier.
#
#   The bound covers CHILD PROCESSES, which is the entire point - the agent was
#   369 MiB and its child was 24.6 GiB. Every process the worker launches is
#   created inside the scope's cgroup and counts against the same limit.
#
#   CollectMode=inactive-or-failed keeps the mechanism from littering; see
#   cap_properties below, which is the single owner of the property set.
#
# WHAT SUPERVISION SEES. When any process in the scope is OOM-killed, systemd
# tears down the whole scope (verified: the surviving parent exits 143/SIGTERM
# even though memory.oom.group is 0). The worker therefore dies as a unit, the
# pane falls back to a bare shell, and fm_backend_tmux_agent_state reports
# `dead` - a recovery-grade state the stuck-crewmate-recovery skill acts on.
# A bounded death is a normal recoverable death, not a new supervision case.
#
# THE DEFAULT needs no configuration: 25% of the host's total memory, clamped to
# [2 GiB, 8 GiB]. On the 29 GiB host that is 7 GiB - ample for a bundler or a
# test suite, and a third of what the runaway took. The clamp keeps a small host
# usable (an 8 GiB laptop yields the 2 GiB floor) and stops a very large host
# from handing out a limit so high it stops being a bound. The ceiling is
# deliberately per-worker rather than fleet-wide, so one greedy worker cannot
# starve its siblings, and it leaves the desktop session real headroom: the
# systemd-oomd pressure kill fires on the whole user slice, so no single worker
# may approach the point where that slice starts thrashing.
#
# FM_CREW_MEMORY_CAP_MEMINFO_OVERRIDE names an alternate MemTotal source, so the
# derivation and its clamp can be exercised against hosts of any size on one
# machine. It follows the FM_*_OVERRIDE convention the rest of bin/ uses and
# changes nothing else about how the bound is applied.
#
# UNSUPPORTED HOSTS degrade openly. Where systemd, a user manager, or memory
# delegation is missing, `wrap` returns the command UNCHANGED and prints one
# plain reason on stderr. Firstmate reports that and spawns unbounded rather
# than refusing to work on a host that simply cannot offer the bound; silently
# spawning unbounded is the one behaviour this script never has.
#
# docs/configuration.md "Crew memory cap (config/crew-memory-max)" owns the
# operator-facing contract; this header owns the mechanism and exact values.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

CAP_FILE="crew-memory-max"
CAP_FRACTION_PERCENT=25
CAP_FLOOR_MIB=2048
CAP_CEILING_MIB=8192
CAP_PROBE_TIMEOUT=5

usage() {
  sed -n '2,8{s/^# \{0,1\}//;p;}' "$0"
}

cap_error() {
  printf 'crew-memory-cap: %s\n' "$1" >&2
}

cap_link_count() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

# cap_configured_value: print the validated override, or nothing when absent.
# Fails (status 1) only for a PRESENT but unsafe or malformed file, which is an
# operator error worth reporting rather than a value to infer around.
cap_configured_value() {
  local path="$CONFIG/$CAP_FILE" links value digits
  [ ! -L "$CONFIG" ] || { cap_error "config directory is symlinked"; return 1; }
  [ -e "$path" ] || return 0
  [ ! -L "$path" ] || { cap_error "config/$CAP_FILE is symlinked"; return 1; }
  [ -f "$path" ] || { cap_error "config/$CAP_FILE is not a regular file"; return 1; }
  links=$(cap_link_count "$path")
  [ "${links:-1}" = 1 ] || { cap_error "config/$CAP_FILE is hardlinked"; return 1; }
  [ "$(wc -l < "$path")" = 1 ] || { cap_error "config/$CAP_FILE must be one line ending in a newline"; return 1; }
  value=$(head -n 1 "$path")
  if [ "$value" = off ]; then
    printf 'off\n'
    return 0
  fi
  # A strict size: digits, then at most one K/M/G. Deliberately not a loose
  # character check - "1G2M" passes any charset test, is accepted by nothing,
  # and would fail at launch time with the pane already open and no agent in it.
  digits=${value%[KMG]}
  case "$digits" in
    ''|*[!0-9]*|0*)
      cap_error "config/$CAP_FILE must be 'off' or a size such as 6G, 512M (got '$value')"
      return 1
      ;;
  esac
  printf '%s\n' "$value"
}

# cap_default_limit: 25% of MemTotal, clamped to [2 GiB, 8 GiB]. Empty when the
# host does not expose a total to derive from.
cap_default_limit() {
  local total_kib mib meminfo
  meminfo=${FM_CREW_MEMORY_CAP_MEMINFO_OVERRIDE:-/proc/meminfo}
  [ -r "$meminfo" ] || return 0
  total_kib=$(awk '/^MemTotal:/{print $2; exit}' "$meminfo" 2>/dev/null || true)
  case "${total_kib:-}" in
    ''|*[!0-9]*) return 0 ;;
  esac
  mib=$(( total_kib * CAP_FRACTION_PERCENT / 100 / 1024 ))
  [ "$mib" -ge "$CAP_FLOOR_MIB" ] || mib=$CAP_FLOOR_MIB
  [ "$mib" -le "$CAP_CEILING_MIB" ] || mib=$CAP_CEILING_MIB
  printf '%sM\n' "$mib"
}

# cap_limit: the effective limit token, "off", or empty when undeterminable.
cap_limit() {
  local configured
  configured=$(cap_configured_value) || return 1
  if [ -n "$configured" ]; then
    printf '%s\n' "$configured"
    return 0
  fi
  cap_default_limit
}

# cap_status: authoritative availability. The verdict comes from actually
# creating a bounded scope, never from a proxy signal. `systemctl --user
# is-system-running` was tried and deliberately rejected: it reports `degraded`
# and exits non-zero whenever ANY unrelated user unit has failed, on a host
# where bounded scopes work perfectly (verified on this host), so gating on it
# would silently disable the bound fleet-wide for an unrelated reason. When the
# probe fails, systemd-run's own first line of stderr becomes the reason, so an
# operator is told what actually refused rather than what this script guessed.
cap_status() {  # [limit]
  local limit=${1:-} probe_err
  command -v systemd-run >/dev/null 2>&1 || { printf 'unavailable: systemd-run is not installed\n'; return 0; }
  [ -n "$limit" ] || limit=$(cap_default_limit)
  [ -n "$limit" ] || { printf 'unavailable: this host does not expose a total memory size to bound against\n'; return 0; }
  if command -v timeout >/dev/null 2>&1; then
    # shellcheck disable=SC2046  # deliberate word splitting: cap_properties emits separate flags
    probe_err=$(timeout "$CAP_PROBE_TIMEOUT" systemd-run --user --scope -q \
      $(cap_properties "$limit") -- true 2>&1 >/dev/null) && { printf 'available\n'; return 0; }
  else
    # shellcheck disable=SC2046  # deliberate word splitting: cap_properties emits separate flags
    probe_err=$(systemd-run --user --scope -q \
      $(cap_properties "$limit") -- true 2>&1 >/dev/null) && { printf 'available\n'; return 0; }
  fi
  probe_err=$(printf '%s' "$probe_err" | head -n 1)
  printf 'unavailable: could not create a memory-bounded scope%s\n' "${probe_err:+ - $probe_err}"
}

# cap_properties <limit>: the systemd properties every bounded scope carries.
# The probe below and the real launch both go through this, so the availability
# check can never validate a different scope shape than a worker actually gets.
#
# CollectMode=inactive-or-failed is what stops the bound from littering: a
# transient scope that dies is kept by systemd's default CollectMode, so without
# it EVERY worker killed at its limit leaves a permanent failed unit in the user
# manager (verified: 23 of them accumulated across one afternoon of testing).
# The journal still records the kill, so the durable evidence is not lost.
cap_properties() {  # <limit>
  printf -- '-p MemoryMax=%s -p MemorySwapMax=0 -p CollectMode=inactive-or-failed' "$1"
}

cap_shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# cap_wrap <command-string> [description]
# Prints the bounded command line, or the command UNCHANGED with one reason on
# stderr when the bound cannot be applied. Never fails the caller: an
# unsupported host must still be able to spawn.
cap_wrap() {
  local command=$1 description=${2:-firstmate worker} limit status
  if ! limit=$(cap_limit); then
    printf '%s\n' "$command"
    return 0
  fi
  if [ -z "$limit" ] || [ "$limit" = off ]; then
    [ "$limit" = off ] && cap_error "memory bound disabled by config/$CAP_FILE; this worker is unbounded"
    [ -n "$limit" ] || cap_error "no host memory total to derive a bound from; this worker is unbounded"
    printf '%s\n' "$command"
    return 0
  fi
  status=$(cap_status "$limit")
  if [ "$status" != available ]; then
    cap_error "${status#unavailable: }; this worker is unbounded"
    printf '%s\n' "$command"
    return 0
  fi
  printf 'systemd-run --user --scope -q --description=%s %s -- /bin/sh -c %s\n' \
    "$(cap_shell_quote "$description")" "$(cap_properties "$limit")" "$(cap_shell_quote "$command")"
}

cap_run() {
  local limit status
  [ "$#" -gt 0 ] || { cap_error "run needs a command"; return 2; }
  limit=$(cap_limit) || return 1
  status=$(cap_status "$limit")
  if [ -z "$limit" ] || [ "$limit" = off ] || [ "$status" != available ]; then
    cap_error "running unbounded: ${status#unavailable: }"
    exec "$@"
  fi
  # shellcheck disable=SC2046  # deliberate word splitting: cap_properties emits separate flags
  exec systemd-run --user --scope -q --description='firstmate ad-hoc command' \
    $(cap_properties "$limit") -- "$@"
}

cap_report() {
  local configured limit status
  configured=$(cap_configured_value) || return 1
  limit=$(cap_limit) || return 1
  status=$(cap_status "$limit")
  printf 'limit:      %s\n' "${limit:-undeterminable}"
  if [ -n "$configured" ]; then
    printf 'source:     config/%s\n' "$CAP_FILE"
  else
    printf 'source:     default (%s%% of host memory, clamped to [%sM, %sM])\n' \
      "$CAP_FRACTION_PERCENT" "$CAP_FLOOR_MIB" "$CAP_CEILING_MIB"
  fi
  printf 'mechanism:  %s\n' "$status"
}

case "${1:-}" in
  limit)  shift; cap_limit ;;
  status) shift; cap_status ;;
  wrap)   shift; [ "$#" -ge 1 ] || { usage >&2; exit 2; }; cap_wrap "$@" ;;
  run)    shift; cap_run "$@" ;;
  report) shift; cap_report ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
