#!/usr/bin/env bash
# tests/fm-bearings-board-lavish-live-e2e.test.sh - live drift guard proving
# the real lavish-axi still behaves the way bin/fm-bearings-board.sh's session
# liveness check is written against.
#
# Why this file exists: the build's "is this board actually live" verdict comes
# from what lavish-axi emits, which is a surface the vendor controls and changes
# without notice. The defect this guards was exactly that - opening a session
# the captain had ended from the browser EXITS 0 while refusing to reopen, so a
# build that trusted the exit status armed a poll against a dead session and the
# board read "not listening" with nobody watching it. A stubbed lavish-axi can
# only confirm the assumption already written into the stub, so the assumption
# itself needs a run against the real tool.
#
# The captain-ended state is reached through the same server route the browser's
# End session button calls, so no browser is needed and nothing here depends on
# a human. The artifact is a scratch page in a temporary directory, and the
# session it opens is ended again before the guard returns.
#
# The board opens only through the public tunnel (bin/fm-lavish-lib.sh), so the
# guard runs the real lavish-axi on its own port and state directory behind
# tests/lavish-tunnel-helpers.sh's stand-in ngrok API and public edge, and a
# fake ngrok that cannot start anything: the machine's own tunnel, Lavish
# server, and sessions are never touched.
#
# Standard CI has no lavish-axi, so this reports a capability skip there. The
# portable counterpart in tests/fm-bearings-board.test.sh pins the build's logic
# in CI against a stub that reproduces these shapes. Run this guard after a
# lavish-axi upgrade and before trusting refreshed evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lavish-tunnel-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/lavish-tunnel-helpers.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate default-on FM_BEARINGS_LAVISH_LIVE lavish-axi jq curl python3

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

LAB=''
# Set only once LAVISH_AXI_PORT names this guard's own server: before that,
# `lavish-axi stop` would reach the machine's real one.
ISOLATED_PORT=''
cleanup() {
  [ -z "$LAB" ] || {
    FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_PROCEVENT_CLAIM_ROOT="$LAB/procevent-claims" \
      "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
    [ ! -f "$LAB/.lavish/bearings-board.html" ] \
      || lavish-axi end "$LAB/.lavish/bearings-board.html" >/dev/null 2>&1 || true
    [ -z "$ISOLATED_PORT" ] || lavish-axi stop >/dev/null 2>&1 || true
    rm -rf "$LAB"
  }
}
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
trap cleanup EXIT

VERSION=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
note "lavish-axi ${VERSION:-version-unknown}"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-bearings-lavish-live.XXXXXX") || fail "cannot create the guard lab"
LAB=$(cd -P -- "$LAB" && pwd -P)
mkdir -p "$LAB/state" "$LAB/data" "$LAB/config"
printf 'lavish\n' > "$LAB/config/lavish-tunnel"

fm_lavish_world_start "$LAB/lavish-world"
FAKEBIN="$LAB/fakebin"
fm_lavish_world_fakebin "$LAB/lavish-world" "$FAKEBIN"
rm -f "$FAKEBIN/lavish-axi"
: > "$LAB/lavish-world/ngrok-broken"
LAVISH_AXI_PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
export LAVISH_AXI_PORT LAVISH_AXI_NO_OPEN=1
ISOLATED_PORT=$LAVISH_AXI_PORT
fm_lavish_world_tunnel "$LAB/lavish-world" lavish "https://$FM_LAVISH_WORLD_HOST" "http://127.0.0.1:$LAVISH_AXI_PORT"

cat > "$LAB/payload.json" <<'JSON'
{
  "schema": "fm-bearings-board.v1",
  "home": "lavish-live-guard",
  "generated": "2026-01-01T00:00Z",
  "prs_live": false,
  "captains_call": [
    {
      "key": "sample-live-guard-call",
      "type": "decision",
      "repo": "sample",
      "title": "Guard placeholder",
      "options": [{ "value": "yes", "label": "Yes" }]
    }
  ],
  "underway": [],
  "landed": [],
  "charted": []
}
JSON

run_board() {
  PATH="$FAKEBIN:$PATH" FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_DATA_OVERRIDE="$LAB/data" \
    FM_PROCEVENT_CLAIM_ROOT="$LAB/procevent-claims" \
    "$ROOT/bin/fm-bearings-board.sh" "$@"
}

BOARD="$LAB/.lavish/bearings-board.html"
run_board build "$LAB/payload.json" >/dev/null 2>&1 || fail "the guard board did not build"
[ -f "$BOARD" ] || fail "the guard board was not published"

url=$(lavish-axi "$BOARD" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"')
case "$url" in
  http://*/session/*) ;;
  *) fail "could not read the guard board session url: $url" ;;
esac
key=${url##*/}
# The session url carries the public host the board was opened for; the
# captain's End button reaches this isolated server directly.
base="http://127.0.0.1:$LAVISH_AXI_PORT"

# End it exactly as the browser's End session button does.
curl -fsS -X POST "$base/api/$key/end" >/dev/null 2>&1 \
  || fail "could not end the guard board session as the captain"

# ASSUMPTION UNDER GUARD: this exits 0 while reporting the session is not live.
set +e
ended_out=$(lavish-axi "$BOARD" 2>&1)
ended_rc=$?
set -e
[ "$ended_rc" -eq 0 ] \
  || fail "lavish-axi ${VERSION:-version-unknown} now exits $ended_rc on a captain-ended session; the board build's liveness check must be revisited"
ended_status=$(printf '%s\n' "$ended_out" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"')
[ "$ended_status" != opened ] \
  || fail "lavish-axi ${VERSION:-version-unknown} silently reopened a captain-ended session; the board build's liveness check must be revisited"
lavish-axi 2>/dev/null | grep -F "$BOARD," | grep -q ',open,' \
  && fail "lavish-axi ${VERSION:-version-unknown} still lists a captain-ended session as open; the board build's liveness check must be revisited"
pass "lavish-axi ${VERSION:-version-unknown} reports a captain-ended session without reopening it and without failing"

# THE BEHAVIOR UNDER GUARD: the build must not accept that, and must recover.
out=$(run_board build "$LAB/payload.json" 2>&1) \
  || fail "the board build refused a recoverable captain-ended session: $out"
case "$out" in
  *"session: reopened"*) ;;
  *) fail "the board build did not reopen the captain-ended session: $out" ;;
esac
lavish-axi 2>/dev/null | grep -F "$BOARD," | grep -q ',open,' \
  || fail "the board build reported success while the session was still not live"
pass "the board build reopens a captain-ended session against real lavish-axi instead of arming a dead one"
