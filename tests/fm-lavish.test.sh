#!/usr/bin/env bash
# tests/fm-lavish.test.sh - bin/fm-lavish.sh puts a page on the captain's phone
# or refuses; it never prints a loopback or LAN link.
#
# The defect this guards: every session had to remember to start the ngrok
# tunnel, set two Lavish environment variables on the call that starts the
# server, and rewrite lavish-axi's own http://<host>:4387 link, and a session
# that forgot handed the captain a link his phone could not open. Every case
# drives the real command against tests/lavish-tunnel-helpers.sh's stand-in for
# ngrok's API, the Lavish server's host check, and the public edge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lavish-tunnel-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/lavish-tunnel-helpers.sh"

command -v python3 >/dev/null 2>&1 || fail "python3 is required for the fake ngrok and Lavish world"

TMP_ROOT=$(fm_test_tmproot fm-lavish)
HOST=$FM_LAVISH_WORLD_HOST
LINK="https://$HOST/session/5e55101d0000abcd"

# One world per case, so a case's tunnel, server, and call log start clean.
new_case() {  # <name>
  CASE="$TMP_ROOT/$1"
  WORLD="$CASE/world"
  HOME_DIR="$CASE/home"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$CASE/pages"
  printf '<!doctype html><title>page</title>\n' > "$CASE/pages/review.html"
  PAGE=$(cd -P "$CASE/pages" && pwd -P)/review.html
  fm_lavish_world_start "$WORLD"
  FAKEBIN="$CASE/fakebin"
  fm_lavish_world_fakebin "$WORLD" "$FAKEBIN"
  printf 'lavish\n' > "$HOME_DIR/config/lavish-tunnel"
  : > "$WORLD/server-down"
}

run_lavish() {  # <args...>
  OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-lavish.sh" "$@" 2>"$CASE/stderr")
  RC=$?
  ERR=$(cat "$CASE/stderr")
}

calls() { cat "$WORLD/calls" 2>/dev/null || true; }
count_calls() { calls | grep -c -- "$1" || true; }

# --- the whole path from nothing running --------------------------------------
new_case cold
run_lavish open "$PAGE"
[ "$RC" -eq 0 ] || fail "open from a cold machine failed: $ERR"
assert_contains "$OUT" "link: $LINK" "open did not print the public https link"
assert_not_contains "$OUT" "http://" "open printed lavish-axi's own http link"
assert_not_contains "$OUT" ":4387" "open printed a link carrying the server port"
assert_not_contains "$OUT" "server-restarted" "a cold start reported restarting a server that was not running"
[ "$(count_calls '^ngrok start lavish')" -eq 1 ] || fail "open did not start the named tunnel exactly once: $(calls)"
assert_contains "$(calls)" "server link=$HOST allowed=$HOST" \
  "the Lavish server was not started with the public host as link and allowed host"
assert_contains "$(calls)" "open $PAGE link=$HOST allowed=$HOST no_open=1" \
  "the page was not opened with the public environment and without a local browser tab"
assert_contains "$(cat "$WORLD/requests")" "$HOST /health" \
  "the server was never probed with the public Host header through the tunnel's address"
pass "open starts the tunnel and the server with the public host and prints only the https link"

# --- nothing is started twice ---------------------------------------------------
new_case warm
fm_lavish_world_tunnel "$WORLD"
fm_lavish_world_allow "$WORLD" "$HOST"
run_lavish open "$PAGE"
[ "$RC" -eq 0 ] || fail "open with everything already up failed: $ERR"
assert_contains "$OUT" "link: $LINK" "open did not print the public link when everything was up"
[ "$(count_calls '^ngrok')" -eq 0 ] || fail "open started a second tunnel: $(calls)"
[ "$(count_calls '^stop')" -eq 0 ] || fail "open stopped a server that already accepted the public host"
[ "$(count_calls '^server')" -eq 0 ] || fail "open started a second server"
pass "open reuses a running tunnel and a correctly started server"

# --- a server started without the allowlist is restarted --------------------------
new_case misbound
fm_lavish_world_tunnel "$WORLD"
fm_lavish_world_allow "$WORLD"
run_lavish open "$PAGE"
[ "$RC" -eq 0 ] || fail "open could not recover a server started without the public host: $ERR"
assert_contains "$(calls)" $'stop\nserver link='"$HOST" \
  "a server answering 403 to the public host was not stopped and started with it"
assert_contains "$OUT" "server-restarted:" "open did not say it interrupted running polls"
assert_contains "$OUT" "link: $LINK" "open did not print the link after the restart"
pass "a server that rejects the public host is restarted with it, and the caller is told"

new_case plain-restarter
fm_lavish_world_tunnel "$WORLD"
fm_lavish_world_allow "$WORLD"
: > "$WORLD/plain-restarter"
run_lavish open "$PAGE"
[ "$RC" -ne 0 ] || fail "open succeeded while the server kept coming back without the public host"
assert_not_contains "$OUT" "link:" "open printed a link to a server that rejects the public host"
assert_contains "$ERR" "keeps coming back without $HOST" "the repeated plain restart was not named"
[ "$(count_calls '^open')" -eq 0 ] || fail "open still opened the page after the server check failed"
pass "a server that keeps losing the public host refuses instead of looping"

# --- the hostname comes from ngrok, not from memory --------------------------------
new_case other-domain
fm_lavish_world_tunnel "$WORLD" lavish https://moved-domain.example.test
run_lavish open "$PAGE"
[ "$RC" -eq 0 ] || fail "open failed on a tunnel with a different domain: $ERR"
assert_contains "$OUT" "link: https://moved-domain.example.test/session/5e55101d0000abcd" \
  "the link did not follow the domain ngrok reports"
assert_contains "$(calls)" "server link=moved-domain.example.test" \
  "the server was not started for the domain ngrok reports"
pass "the public hostname is read from ngrok's API"

# --- refusals --------------------------------------------------------------------
new_case unconfigured
rm -f "$HOME_DIR/config/lavish-tunnel"
run_lavish open "$PAGE"
[ "$RC" -ne 0 ] || fail "open succeeded with no tunnel configured"
assert_not_contains "$OUT" "link:" "open printed a link with no tunnel configured"
assert_contains "$ERR" "config/lavish-tunnel are both absent" "the missing configuration was not named"
[ -z "$(calls)" ] || fail "an unconfigured open still ran ngrok or lavish-axi: $(calls)"
pass "with no tunnel configured, open refuses rather than printing a local link"

new_case bad-config
printf 'two words\n' > "$HOME_DIR/config/lavish-tunnel"
run_lavish open "$PAGE"
[ "$RC" -ne 0 ] || fail "open accepted a malformed tunnel name"
assert_contains "$ERR" "must contain one ngrok tunnel name" "the malformed configuration was not named"
pass "a malformed config/lavish-tunnel refuses"

new_case config-blocked
rm -rf "$HOME_DIR/config"
printf 'not a directory\n' > "$HOME_DIR/config"
run_lavish poll "$PAGE"
[ "$RC" -ne 0 ] || fail "an uninspectable config/lavish-tunnel was treated as absent"
assert_contains "$ERR" "must be a readable regular file" "the uninspectable configuration was not named"
[ "$(count_calls '^poll')" -eq 0 ] || fail "poll ran after the tunnel configuration could not be inspected"
pass "a tunnel configuration that cannot be inspected never reads as switched off"

new_case open-edge
fm_lavish_world_tunnel "$WORLD"
fm_lavish_world_allow "$WORLD" "$HOST"
printf '200\n' > "$WORLD/edge-status"
run_lavish open "$PAGE"
[ "$RC" -ne 0 ] || fail "open handed out a link to a tunnel that serves without a password"
assert_contains "$ERR" "without a password" "the missing password was not named"
[ "$(count_calls '^open')" -eq 0 ] || fail "open opened the page behind a passwordless tunnel"
pass "a tunnel that does not ask for a password refuses"

new_case wrong-port
fm_lavish_world_tunnel "$WORLD" lavish "https://$HOST" "http://localhost:3000"
run_lavish open "$PAGE"
[ "$RC" -ne 0 ] || fail "open accepted a tunnel forwarding to another port"
assert_contains "$ERR" "listens on port $LAVISH_AXI_PORT" "the port mismatch was not named"
pass "a tunnel forwarding anywhere but the Lavish port refuses"

new_case plain-http
fm_lavish_world_tunnel "$WORLD" lavish "http://$HOST"
run_lavish open "$PAGE"
[ "$RC" -ne 0 ] || fail "open accepted a tunnel without https"
assert_contains "$ERR" "not a plain https origin" "the non-https tunnel was not named"
pass "a tunnel without an https public URL refuses"

new_case ngrok-broken
: > "$WORLD/ngrok-broken"
run_lavish open "$PAGE"
[ "$RC" -ne 0 ] || fail "open succeeded while ngrok could not start the tunnel"
assert_contains "$ERR" "did not come up" "the failed tunnel start was not reported"
assert_contains "$ERR" "ERR_NGROK_334" "the ngrok log was not shown"
pass "a tunnel that cannot start refuses and shows ngrok's own error"

new_case user-ended
fm_lavish_world_tunnel "$WORLD"
fm_lavish_world_allow "$WORLD" "$HOST"
printf 'user-ended\n' > "$WORLD/open-status"
run_lavish open "$PAGE"
[ "$RC" -ne 0 ] || fail "open reported success on a session the captain ended"
assert_contains "$ERR" "pass --reopen only when" "the ended session was not explained"
assert_not_contains "$OUT" "link:" "open printed a link to a session the captain ended"
printf 'opened\n' > "$WORLD/open-status"
run_lavish open "$PAGE" --reopen
[ "$RC" -eq 0 ] || fail "open --reopen failed: $ERR"
assert_contains "$(calls)" "open $PAGE --reopen" "--reopen was not passed to lavish-axi"
pass "a session the captain ended refuses unless --reopen is explicit"

# --- concurrent opens share one tunnel --------------------------------------------
new_case concurrent
( run_lavish open "$PAGE"; printf '%s\n' "$RC" > "$CASE/rc1" ) &
first=$!
( run_lavish open "$PAGE"; printf '%s\n' "$RC" > "$CASE/rc2" ) &
second=$!
wait "$first" "$second"
[ "$(cat "$CASE/rc1")" -eq 0 ] && [ "$(cat "$CASE/rc2")" -eq 0 ] || fail "concurrent opens did not both succeed"
[ "$(count_calls '^ngrok start')" -eq 1 ] || fail "two concurrent opens started the tunnel $(count_calls '^ngrok start') times"
[ "$(count_calls '^server')" -eq 1 ] || fail "two concurrent opens started the server $(count_calls '^server') times"
pass "concurrent opens start the tunnel and the server once"

# --- the poll carries the same environment ----------------------------------------
new_case poll
run_lavish poll "$PAGE" --agent-reply "applied your notes"
[ "$RC" -eq 0 ] || fail "poll failed: $ERR"
assert_contains "$OUT" "status: feedback" "poll did not print lavish-axi's response"
assert_contains "$(calls)" "poll poll $PAGE --agent-reply applied your notes link=$HOST allowed=$HOST" \
  "the poll did not run with the public environment and its reply"
assert_contains "$(calls)" "server link=$HOST" "a poll that had to start the server did not start it for the public host"
pass "poll brings the tunnel and server up and polls with the public environment"

new_case poll-unconfigured
rm -f "$HOME_DIR/config/lavish-tunnel"
run_lavish poll "$PAGE"
[ "$RC" -eq 0 ] || fail "an unconfigured poll failed: $ERR"
assert_contains "$(calls)" "poll poll $PAGE link=unset allowed=unset" "an unconfigured poll changed the Lavish environment"
[ "$(count_calls '^ngrok')" -eq 0 ] || fail "an unconfigured poll ran ngrok"
pass "with no tunnel configured, poll polls locally"

new_case poll-broken
: > "$WORLD/ngrok-broken"
run_lavish poll "$PAGE"
[ "$RC" -ne 0 ] || fail "poll ran while the configured tunnel could not start"
[ "$(count_calls '^poll')" -eq 0 ] || fail "poll started lavish-axi without the public environment"
pass "a configured poll refuses rather than starting a server the phone cannot reach"
