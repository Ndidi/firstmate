#!/usr/bin/env bash
# tests/fm-lavish-live-e2e.test.sh - live drift guard proving the real
# lavish-axi still behaves the way bin/fm-lavish-lib.sh is written against.
#
# The library rests on three vendor facts a stub can only restate: a server
# started without LAVISH_AXI_LINK_HOST/LAVISH_AXI_ALLOWED_HOSTS answers the
# tunnel's Host with 403 {"error":"forbidden host"}; a running server keeps that
# binding until it is stopped and started again with them; and `lavish-axi
# <file>` prints a `url:` line carrying /session/<id>. This guard runs the real
# tool on an isolated port and state directory, with the ngrok API and public
# edge played by tests/lavish-tunnel-helpers.sh and a fake ngrok that cannot
# start anything, so the machine's own tunnel and Lavish server are never
# touched. Standard CI has no lavish-axi, so this reports a capability skip
# there; tests/fm-lavish.test.sh pins the logic in CI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lavish-tunnel-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/lavish-tunnel-helpers.sh"

fm_live_gate default-on FM_LAVISH_LIVE lavish-axi python3 curl

note() { printf '# %s\n' "$1"; }

TMP_ROOT=$(fm_test_tmproot fm-lavish-live)
WORLD="$TMP_ROOT/world"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$TMP_ROOT/pages"
printf 'lavish\n' > "$HOME_DIR/config/lavish-tunnel"
printf '<!doctype html><title>live guard</title><p>scratch</p>\n' > "$TMP_ROOT/pages/guard.html"
PAGE="$TMP_ROOT/pages/guard.html"

fm_lavish_world_start "$WORLD"
# Only the fake ngrok is used: the real lavish-axi must serve this guard.
FAKEBIN="$TMP_ROOT/fakebin"
fm_lavish_world_fakebin "$WORLD" "$FAKEBIN"
rm -f "$FAKEBIN/lavish-axi"
: > "$WORLD/ngrok-broken"

LAVISH_AXI_PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
export LAVISH_AXI_PORT LAVISH_AXI_NO_OPEN=1
HOST=$FM_LAVISH_WORLD_HOST
BASE="http://127.0.0.1:$LAVISH_AXI_PORT"
fm_lavish_world_tunnel "$WORLD" lavish "https://$HOST" "$BASE"

cleanup_live() {
  lavish-axi stop >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_live EXIT

VERSION=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
note "lavish-axi ${VERSION:-version-unknown} on isolated port $LAVISH_AXI_PORT"

probe() { curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 5 -H "Host: $HOST" "$BASE/health"; }

# The defect, reproduced against the real tool: a plainly started server.
plain=$(env -u LAVISH_AXI_LINK_HOST -u LAVISH_AXI_ALLOWED_HOSTS lavish-axi "$PAGE" 2>&1) \
  || fail "lavish-axi ${VERSION:-?} could not open the scratch page: $plain"
[ "$(probe)" = 403 ] \
  || fail "lavish-axi ${VERSION:-?} no longer rejects an unlisted Host with 403; bin/fm-lavish-lib.sh's restart test is stale"
pass "a plainly started server rejects the tunnel's host"

# A later call carrying the environment does not change the running server.
LAVISH_AXI_LINK_HOST=$HOST LAVISH_AXI_ALLOWED_HOSTS=$HOST lavish-axi "$PAGE" >/dev/null 2>&1 \
  || fail "lavish-axi ${VERSION:-?} could not resume the scratch page"
[ "$(probe)" = 403 ] \
  || fail "lavish-axi ${VERSION:-?} now applies the host environment to a running server; the restart may be unnecessary"
pass "a running server keeps its binding when a later call carries the environment"

out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-lavish.sh" open "$PAGE" 2>&1) \
  || fail "bin/fm-lavish.sh open failed against lavish-axi ${VERSION:-?}: $out"
[ "$(probe)" = 200 ] || fail "after bin/fm-lavish.sh open the server still rejects the tunnel's host"
assert_contains "$out" "server-restarted:" "the restart was not reported"
session_id=$(lavish-axi 2>/dev/null | grep -F "$(cd -P "$TMP_ROOT/pages" && pwd -P)/guard.html," \
  | sed -n -E 's#.*/session/([A-Za-z0-9_-]+).*#\1#p' | head -n 1)
[ -n "$session_id" ] || fail "lavish-axi ${VERSION:-?} did not list the scratch session"
assert_contains "$out" "link: https://$HOST/session/$session_id" \
  "the printed link does not carry the real session id from lavish-axi ${VERSION:-?}"
pass "bin/fm-lavish.sh restarts the real server with the public host and prints its real session link"

lavish-axi end "$PAGE" >/dev/null 2>&1 || true
