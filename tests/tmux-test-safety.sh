#!/usr/bin/env bash
# tests/tmux-test-safety.sh - shared hard guarantee that a test which reaches a
# REAL tmux binary can never create, see, or kill anything in the machine's
# actual tmux server. Completes the per-backend safety set alongside
# tests/herdr-test-safety.sh, tests/zellij-test-safety.sh and
# tests/cmux-test-safety.sh, which had no tmux counterpart.
#
# The incident that produced this file, 2026-08-19: the captain asked what the
# crew was working on and could see one more window than firstmate reported. The
# extra one was `fm-unfilled-ship`, created by
# tests/fm-spawn-unfilled-brief.test.sh in the captain's own live `firstmate`
# session, owned by no task - no state/<id>.meta, no status log, no backlog
# entry. Its pane's working directory was a temp tree that had already been
# cleaned up, so the window outlived the fixture that made it.
#
# Three things make that worth a shared guarantee rather than a local patch:
#
#   1. It puts a fake worker in front of the captain. They count windows to see
#      what is running, so a leaked one makes firstmate's own report look wrong.
#   2. It is invisible to firstmate, which reconciles the fleet from
#      state/*.meta. A window no task owns simply does not appear, so the
#      captain could see it and firstmate could not.
#   3. bin/fm-spawn.sh names windows `fm-<task-id>`. A test using a plausible
#      task id could collide with a genuine task's window, and then cleanup
#      would not be cosmetic - it would reach into live work. This is the same
#      principle behind the standing rule never to broadly kill watcher
#      processes: a test must not be able to touch anything real.
#
# WHY ISOLATION RATHER THAN TIDY-UP. Cleanup only removes the window a test
# knows it made, on the paths where cleanup runs. The failure the captain hit
# was a test that ASSERTED it never reached the backend ("Every case here fails
# before any endpoint, worktree, or backend side effect") and was right about
# its passing path and wrong about its failing one: the placeholder guard it
# exercises was under development, so the spawn ran on to create a window and
# the test died at the first failed assertion with the window still there. A
# private tmux server removes the whole class - a leak into it is invisible to
# the captain, harmless, and disappears with the server - which no trap can
# promise, because the trap is exactly what an abort skips.
#
# HOW. bin/backends/tmux.sh invokes bare `tmux`, never an absolute path, so a
# `tmux` shim at the front of PATH transparently redirects every call in the
# whole process tree - including ones made by bin/fm-spawn.sh and any helper it
# runs - to a private server (`tmux -L <socket>`). Nothing under bin/ changes.
#
# FAILS CLOSED. Isolation that silently did not take effect would put a test
# straight back in the captain's session, so tmux_isolate PROVES the redirect
# before returning: it creates a probe window on the private server and refuses
# unless that window is invisible to the ambient one. A refusal aborts the test
# rather than letting it run unisolated.
#
# Usage, immediately after sourcing tests/lib.sh and before anything that can
# reach tmux:
#
#   # shellcheck source=tests/tmux-test-safety.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/tmux-test-safety.sh"
#   tmux_isolate my-suite-label
#
# tmux_isolate is a no-op that returns 0 when no tmux binary is installed, so a
# tmux-free host still runs the suite unchanged.
set -u

# Idempotent guard: a test may source this both directly and through a
# behavior-area helper. Re-sourcing must not clear an installed isolation.
if [ -n "${FM_TMUX_SAFETY_SOURCED:-}" ]; then
  return 0
fi
FM_TMUX_SAFETY_SOURCED=1

FM_TMUX_ISOLATED_SOCKET=
FM_TMUX_ISOLATED_SHIM=
FM_TMUX_REAL=

# tmux_isolation_cleanup: kill the private server and remove the shim. Safe to
# call repeatedly and safe to call when isolation was never installed. Only ever
# names the private socket, so it cannot reach the ambient server even if the
# variables were somehow clobbered - `-L` with an empty name is refused below
# rather than defaulting to the real server.
tmux_isolation_cleanup() {
  if [ -n "${FM_TMUX_REAL:-}" ] && [ -n "${FM_TMUX_ISOLATED_SOCKET:-}" ]; then
    "$FM_TMUX_REAL" -L "$FM_TMUX_ISOLATED_SOCKET" kill-server >/dev/null 2>&1 || true
    # kill-server stops the server but leaves the socket inode behind, which is
    # how the existing isolated suites accumulate dead `fm-*` files under the
    # socket dir. Harmless, but leftover files in /tmp are the shape of the
    # complaint this file answers, so remove ours. Guarded by the non-empty
    # socket name above, so this can never name the default server's socket.
    rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$FM_TMUX_ISOLATED_SOCKET" 2>/dev/null || true
  fi
  [ -n "${FM_TMUX_ISOLATED_SHIM:-}" ] && rm -rf "$FM_TMUX_ISOLATED_SHIM"
  FM_TMUX_ISOLATED_SOCKET=
  FM_TMUX_ISOLATED_SHIM=
}

# tmux_isolate [label]: redirect every `tmux` call this test makes to a private
# server and prove the redirect took effect. Exports the modified PATH so child
# processes (bin/fm-spawn.sh and everything it runs) inherit it.
#
# TMUX is unset deliberately. fm_backend_tmux_container_ensure reuses the
# CURRENT session when TMUX is set (`tmux display-message -p '#S'`), which is
# precisely how the leaked window landed in the captain's own session; with TMUX
# unset the adapter instead ensures its own detached `firstmate` session, which
# under the shim is created on the private server. That also makes the test
# behave identically whether or not it was launched from inside tmux. A test
# that specifically needs the inside-tmux branch can set TMUX itself afterwards.
tmux_isolate() {  # [label]
  local label=${1:-fm-test} real shim socket probe ambient

  real=$(command -v tmux 2>/dev/null) || return 0
  [ -n "$real" ] || return 0

  shim=$(mktemp -d "${TMPDIR:-/tmp}/fm-tmux-isolate.XXXXXX") || return 1
  # The label reaches tmux as a socket NAME, which becomes a filename under the
  # socket directory. Reduce it to characters that cannot escape or confuse that
  # path, so a careless label fails as a clear refusal rather than a puzzling
  # tmux error - and can never point the socket somewhere else.
  label=$(printf '%s' "$label" | tr -c 'A-Za-z0-9_-' '-')
  socket="fm-isolated-${label}-$$"

  cat > "$shim/tmux" <<SH
#!/usr/bin/env bash
exec "$real" -L "$socket" "\$@"
SH
  chmod +x "$shim/tmux" || { rm -rf "$shim"; return 1; }

  FM_TMUX_REAL=$real
  FM_TMUX_ISOLATED_SOCKET=$socket
  FM_TMUX_ISOLATED_SHIM=$shim

  PATH="$shim:$PATH"
  export PATH
  unset TMUX

  # Stand up the private server with the same `firstmate` session shape the
  # adapter expects, so both of its container-ensure branches resolve here.
  "$real" -L "$socket" new-session -d -s firstmate -n harness >/dev/null 2>&1 \
    || { tmux_isolation_cleanup; return 1; }

  # Prove the redirect. The probe window must exist on the private server and
  # must NOT be visible to the ambient one; anything else means a test is about
  # to run against the captain's real session.
  probe="fm-isolation-probe-$$"
  "$real" -L "$socket" new-window -d -t firstmate: -n "$probe" >/dev/null 2>&1 \
    || { tmux_isolation_cleanup; return 1; }

  if ! tmux list-windows -a -F '#{window_name}' 2>/dev/null | grep -qx "$probe"; then
    tmux_isolation_cleanup
    return 1
  fi

  # An ambient server that cannot be reached at all is trivially isolated; one
  # that can see the probe is not isolated and must abort the test.
  ambient=$("$real" list-windows -a -F '#{window_name}' 2>/dev/null || true)
  if printf '%s\n' "$ambient" | grep -qx "$probe"; then
    tmux_isolation_cleanup
    return 1
  fi

  "$real" -L "$socket" kill-window -t "firstmate:$probe" >/dev/null 2>&1 || true
  return 0
}

# tmux_isolate_or_fail [label]: the form a test should normally call. Isolation
# is a safety precondition, so a failure to establish it aborts rather than
# letting the test proceed against the real server. Uses lib.sh's `fail` when
# the test sourced it, and exits non-zero either way.
# Always exits non-zero on failure, including for a suite whose own `fail` only
# records a flag and returns (tests/fm-afk-launch.test.sh does exactly that).
# Isolation is a precondition, not a test case, so it must not be survivable.
tmux_isolate_or_fail() {  # [label]
  local label=${1:-fm-test}
  local msg='tmux isolation could not be established; refusing to run against the real tmux server'
  tmux_isolate "$label" && return 0
  if command -v fail >/dev/null 2>&1; then
    fail "$msg"
  else
    printf 'not ok - %s\n' "$msg" >&2
  fi
  exit 1
}

# tmux_isolated_windows: the private server's current windows, one
# "<session>:<window>" per line. Empty when isolation is not installed. Lets a
# test assert what it did or did not create without naming the socket itself.
tmux_isolated_windows() {
  [ -n "${FM_TMUX_REAL:-}" ] && [ -n "${FM_TMUX_ISOLATED_SOCKET:-}" ] || return 0
  "$FM_TMUX_REAL" -L "$FM_TMUX_ISOLATED_SOCKET" \
    list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null || true
}

# fm_tmux_test_cleanup: this file's cleanup COMPOSED with lib.sh's, because a
# bare `trap tmux_isolation_cleanup EXIT` here would REPLACE the
# `trap fm_test_cleanup EXIT` lib.sh installs at source time and silently leak
# every fixture temp dir. Sourcing order is lib.sh then this file, so this
# handler owns both and calls fm_test_cleanup when it is defined.
#
# A test that installs its OWN EXIT trap overrides this one, exactly as it
# already does lib.sh's. The contract is the same as lib.sh states for
# fm_test_cleanup: call fm_tmux_test_cleanup from inside that trap.
fm_tmux_test_cleanup() {
  tmux_isolation_cleanup
  if command -v fm_test_cleanup >/dev/null 2>&1; then
    fm_test_cleanup
  fi
}

# Cleanup on every exit path - success, failure, and interrupt alike. An aborted
# run is exactly when a leak is most likely, so a happy-path-only trap would not
# be a fix. The private socket makes this a tidiness measure rather than the
# safety boundary, which is the point: correctness no longer depends on it.
trap fm_tmux_test_cleanup EXIT
trap 'fm_tmux_test_cleanup; exit 130' INT
trap 'fm_tmux_test_cleanup; exit 143' TERM
