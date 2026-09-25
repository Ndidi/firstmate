#!/usr/bin/env bash
# tests/fm-lavish-tailscale.test.sh - with config/lavish-tailscale present,
# bin/fm-lavish.sh puts a page on the captain's phone over the tailnet, with no
# password, or refuses.
#
# The defect this guards: the captain chose Tailscale as the standing route for
# his Lavish pages, yet links kept arriving through ngrok because the route
# lived in a hand-started server nobody could reproduce. Every case drives the
# real command against a fake `tailscale` on PATH and
# tests/lavish-tunnel-helpers.sh's stand-in for the Lavish server's host check.
# The fake tailnet address is 127.0.0.2, a second loopback address, so the
# relay the library starts on "the tailnet address" really listens there and
# really forwards to the stand-in server on 127.0.0.1 at the same port.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lavish-tunnel-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/lavish-tunnel-helpers.sh"

command -v python3 >/dev/null 2>&1 || fail "python3 is required for the fake Lavish world"

TAILNET_IP=127.0.0.2
TAILNET_NAME=fake-laptop.tail0000.ts.net
# Linux routes all of 127/8 to loopback; macOS needs an alias for 127.0.0.2.
if ! perl -MIO::Socket::INET -e 'IO::Socket::INET->new(LocalAddr => $ARGV[0], LocalPort => 0, Listen => 1) or exit 1' "$TAILNET_IP"; then
  printf 'ok - SKIP this machine cannot bind %s, the stand-in tailnet address (add a loopback alias to run it)\n' "$TAILNET_IP"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-lavish-tailscale)

# One world per case, so a case's server, relay, and call log start clean.
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
  write_fake_tailscale
  tailscale_reports Running "\"$TAILNET_IP\", \"fd7a:115c:a1e0::1\"" "$TAILNET_NAME."
  : > "$HOME_DIR/config/lavish-tailscale"
  : > "$WORLD/server-down"
  PORT=$LAVISH_AXI_PORT
  LINK="http://$TAILNET_IP:$PORT/session/5e55101d0000abcd"
  PIDFILE="$LAVISH_AXI_STATE_DIR/fm-tailnet-relay.pid"
}

write_fake_tailscale() {
  cat > "$FAKEBIN/tailscale" <<SH
#!/usr/bin/env bash
printf 'tailscale %s\n' "\$*" >> '$WORLD/calls'
[ "\$*" = 'status --json' ] || exit 2
[ ! -e '$WORLD/tailscale-broken' ] || exit 1
cat '$WORLD/tailscale.json'
SH
  chmod +x "$FAKEBIN/tailscale"
}

tailscale_reports() {  # <backend-state> <ips-json-list> <dns-name>
  printf '{"BackendState": "%s", "Self": {"HostName": "fake-laptop", "DNSName": "%s", "TailscaleIPs": [%s], "Online": true}}\n' \
    "$1" "$3" "$2" > "$WORLD/tailscale.json"
}

run_lavish() {  # <args...>
  OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-lavish.sh" "$@" 2>"$CASE/stderr")
  RC=$?
  ERR=$(cat "$CASE/stderr")
}

calls() { cat "$WORLD/calls" 2>/dev/null || true; }
count_calls() { calls | grep -c -- "$1" || true; }
tailnet_status() { curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 3 -H "Host: $TAILNET_IP:$PORT" "http://$TAILNET_IP:$PORT/health" || true; }

# --- the whole path from nothing running ---------------------------------------
new_case cold
printf 'lavish\n' > "$HOME_DIR/config/lavish-tunnel"
printf '200\n' > "$WORLD/edge-status"
run_lavish open "$PAGE"
[ "$RC" -eq 0 ] || fail "open over the tailnet failed from a cold machine: $ERR"
assert_contains "$OUT" "link: $LINK" "open did not print the tailnet link"
assert_not_contains "$OUT" "https://" "open printed a tunnel link while config/lavish-tailscale was present"
[ "$(count_calls '^ngrok')" -eq 0 ] || fail "the tailnet route still started ngrok: $(calls)"
assert_not_contains "$(cat "$WORLD/requests")" "/edge" "the tailnet route ran the tunnel's password check"
server_line=$(calls | grep '^server ' || true)
assert_contains "$server_line" "link=$TAILNET_IP " "the server was not started with the tailnet address as its link host"
for allowed in "$TAILNET_IP" "$TAILNET_IP:$PORT" "$TAILNET_NAME" "$TAILNET_NAME:$PORT" 127.0.0.1 "127.0.0.1:$PORT" localhost "localhost:$PORT"; do
  printf '%s\n' "${server_line#*allowed=}" | tr ' ' '\n' | grep -qx -- "$allowed" \
    || fail "the server's allowed hosts miss $allowed: $server_line"
done
assert_contains "$(calls)" "open $PAGE link=$TAILNET_IP" "the page was not opened with the tailnet environment"
assert_contains "$(calls)" "no_open=1" "the page was opened with a local browser tab"
assert_contains "$(cat "$WORLD/requests")" "$TAILNET_IP:$PORT /health" \
  "the server was never probed through the tailnet address with the tailnet Host header"
[ -s "$PIDFILE" ] || fail "no relay recorded its pid after the cold start"
[ "$(tailnet_status)" = 200 ] || fail "the tailnet address does not reach the server after open"
pass "config/lavish-tailscale wins over the tunnel, starts the relay and the server, and prints the tailnet link"

# --- a second open touches nothing that already works --------------------------
relay_pid=$(cat "$PIDFILE")
: > "$WORLD/calls"
run_lavish open "$PAGE"
[ "$RC" -eq 0 ] || fail "a second open failed: $ERR"
assert_contains "$OUT" "link: $LINK" "the second open did not print the same link"
[ "$(count_calls '^stop')" -eq 0 ] || fail "open stopped a server that already answered for the tailnet host"
[ "$(count_calls '^server')" -eq 0 ] || fail "open started a second server"
[ "$(cat "$PIDFILE")" = "$relay_pid" ] || fail "open started a second relay"
assert_not_contains "$OUT" "server-restarted" "a warm open reported a restart"
pass "a server that already answers 200 for the tailnet host is left running"

# --- the relay stops when its pid file goes away -------------------------------
rm -f "$PIDFILE"
for _ in $(seq 1 30); do
  [ "$(tailnet_status)" = 000 ] && break
  sleep 0.1
done
[ "$(tailnet_status)" = 000 ] || fail "the relay kept listening after its pid file was removed"
pass "the relay exits once its pid file is removed"

# --- a server started without the tailnet host is restarted --------------------
new_case misbound
fm_lavish_world_allow "$WORLD"
run_lavish open "$PAGE"
[ "$RC" -eq 0 ] || fail "open could not recover a server started without the tailnet host: $ERR"
assert_contains "$(calls)" $'stop\nserver link='"$TAILNET_IP" \
  "a server answering 403 to the tailnet host was not stopped and started with it"
assert_contains "$OUT" "server-restarted:" "open did not say it interrupted running polls"
assert_contains "$OUT" "link: $LINK" "open did not print the link after the restart"
pass "a server that rejects the tailnet host is restarted with it, and the caller is told"

# --- the poll carries the same environment -------------------------------------
new_case poll
run_lavish poll "$PAGE"
[ "$RC" -eq 0 ] || fail "poll over the tailnet failed: $ERR"
assert_contains "$(calls)" "server link=$TAILNET_IP" "a poll that had to start the server did not start it for the tailnet"
assert_contains "$(calls)" "poll poll $PAGE link=$TAILNET_IP" "the poll did not run with the tailnet environment"
[ "$(tailnet_status)" = 200 ] || fail "the poll left the server unreachable from the tailnet address"
pass "poll brings the relay and server up for the tailnet"

# --- refusals ------------------------------------------------------------------
new_case stopped
tailscale_reports Stopped "\"$TAILNET_IP\"" "$TAILNET_NAME."
run_lavish open "$PAGE"
[ "$RC" -ne 0 ] || fail "open succeeded while Tailscale was stopped"
assert_contains "$ERR" "its state is Stopped" "the stopped Tailscale was not named"
assert_not_contains "$OUT" "link:" "open printed a link while Tailscale was stopped"
[ "$(count_calls '^open\|^server')" -eq 0 ] || fail "open ran lavish-axi while Tailscale was stopped: $(calls)"
pass "a stopped Tailscale refuses"

new_case no-ipv4
tailscale_reports Running '"fd7a:115c:a1e0::1"' "$TAILNET_NAME."
run_lavish open "$PAGE"
[ "$RC" -ne 0 ] || fail "open succeeded with no tailnet IPv4 address"
assert_contains "$ERR" "no IPv4 address" "the missing address was not named"
pass "a tailnet with no IPv4 address for this machine refuses"

new_case status-fails
: > "$WORLD/tailscale-broken"
run_lavish poll "$PAGE"
[ "$RC" -ne 0 ] || fail "poll ran while tailscale status failed"
assert_contains "$ERR" "is Tailscale running" "the failed status call was not named"
[ "$(count_calls '^poll')" -eq 0 ] || fail "poll started lavish-axi without the tailnet environment"
pass "a failing tailscale status refuses a configured poll rather than polling locally"

new_case not-empty
printf 'ndidi-frmwrk-13\n' > "$HOME_DIR/config/lavish-tailscale"
printf 'lavish\n' > "$HOME_DIR/config/lavish-tunnel"
run_lavish open "$PAGE"
[ "$RC" -ne 0 ] || fail "open accepted content in the config/lavish-tailscale presence flag"
assert_contains "$ERR" "presence flag and must be empty" "the unexpected content was not named"
[ "$(count_calls '^ngrok')" -eq 0 ] || fail "an unusable config/lavish-tailscale fell back to the tunnel"
pass "a config/lavish-tailscale with content refuses rather than falling back"

new_case unreadable
rm -f "$HOME_DIR/config/lavish-tailscale"
mkdir "$HOME_DIR/config/lavish-tailscale"
run_lavish open "$PAGE"
[ "$RC" -ne 0 ] || fail "a config/lavish-tailscale that is not a file read as absent"
assert_contains "$ERR" "config/lavish-tailscale must be a readable regular file" "the unusable flag was not named"
pass "a config/lavish-tailscale that cannot be read never reads as switched off"
