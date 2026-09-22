#!/usr/bin/env bash
# tests/lavish-tunnel-helpers.sh - a hermetic stand-in for the machine's ngrok
# tunnel and Lavish server, shared by the suites that drive bin/fm-lavish-lib.sh.
#
# Source after tests/lib.sh. fm_lavish_world_start <dir> starts one small HTTP
# server (python3) that plays three roles on one port:
#   /api/tunnels        ngrok's local API, listing <dir>/tunnels.json
#   /health, /session/  the Lavish server: 200 for a Host in <dir>/allowed (or
#                       loopback), 403 {"error":"forbidden host"} otherwise, and
#                       an empty reply (no server) while <dir>/server-down exists
#   /edge/...           the public edge: HTTP <dir>/edge-status, default 401
# and exports the library's test hooks plus an isolated LAVISH_AXI_PORT (the
# world's own port, so the tunnel "forwards" to it) and LAVISH_AXI_STATE_DIR, so
# nothing reaches the real tunnel, server, lock, or logs. The server stops by
# itself when the test shell exits, and after 30 minutes at the latest; it
# spawns no processes while it waits.
#
# fm_lavish_world_fakebin <dir> <fakebin> writes a fake `ngrok` (start publishes
# the tunnel unless <dir>/ngrok-broken exists) and a fake `lavish-axi`
# (stop/server/open/poll act on the world and log their environment to
# <dir>/calls). Suites with their own lavish-axi stub can use only the world.

FM_LAVISH_WORLD_HOST=fake-lavish.example.test

fm_lavish_world_start() {  # <dir>
  local dir=$1 _
  mkdir -p "$dir" "$dir/lavish-state"
  cat > "$dir/world.py" <<'PY'
import http.server, json, os, sys, time

world, owner, lifetime = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])

def path(name):
    return os.path.join(world, name)

def read(name, default=""):
    try:
        with open(path(name)) as f:
            return f.read()
    except FileNotFoundError:
        return default

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        with open(path("requests"), "a") as log:
            log.write("%s %s\n" % (self.headers.get("Host", ""), self.path))
        if self.path == "/api/tunnels":
            return self.reply(200, json.loads(read("tunnels.json", '{"tunnels": []}')))
        if self.path.startswith("/edge"):
            return self.reply(int(read("edge-status", "401").strip() or 401), {})
        if os.path.exists(path("server-down")):
            self.close_connection = True
            return
        host = self.headers.get("Host", "").split(":")[0].lower()
        if host in ("127.0.0.1", "localhost") or host in read("allowed").split():
            return self.reply(200, {"ok": True, "app": "lavish-axi", "version": "0.0.0"})
        return self.reply(403, {"error": "forbidden host"})

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
server.timeout = 0.2
with open(path("port.tmp"), "w") as f:
    f.write(str(server.server_address[1]))
os.rename(path("port.tmp"), path("port"))
deadline = time.time() + lifetime
while time.time() < deadline:
    try:
        os.kill(owner, 0)
    except OSError:
        break
    server.handle_request()
PY
  python3 "$dir/world.py" "$dir" "$$" 1800 >/dev/null 2>&1 &
  for _ in $(seq 1 100); do
    [ -s "$dir/port" ] && break
    sleep 0.05
  done
  [ -s "$dir/port" ] || fail "the fake ngrok and Lavish world did not start"
  FM_LAVISH_WORLD_PORT=$(cat "$dir/port")
  export LAVISH_AXI_PORT=$FM_LAVISH_WORLD_PORT
  export LAVISH_AXI_STATE_DIR="$dir/lavish-state"
  export FM_LAVISH_NGROK_API="http://127.0.0.1:$FM_LAVISH_WORLD_PORT"
  export FM_LAVISH_EDGE_OVERRIDE="http://127.0.0.1:$FM_LAVISH_WORLD_PORT/edge"
  export FM_LAVISH_TUNNEL_WAIT=5 FM_LAVISH_SERVER_WAIT=3
  unset LAVISH_AXI_HOST LAVISH_AXI_LINK_HOST LAVISH_AXI_ALLOWED_HOSTS
}

# Publish a running tunnel named <name> in the fake ngrok API.
fm_lavish_world_tunnel() {  # <dir> [name] [public-url] [addr]
  local dir=$1 name=${2:-lavish} url=${3:-https://$FM_LAVISH_WORLD_HOST}
  local addr=${4:-http://127.0.0.1:$(cat "$1/port")}
  printf '{"tunnels":[{"name":"%s","public_url":"%s","proto":"https","config":{"addr":"%s","inspect":true}}]}\n' \
    "$name" "$url" "$addr" > "$dir/tunnels.json"
}

# Mark the fake Lavish server as started with <hosts> allowed.
fm_lavish_world_allow() {  # <dir> [hosts...]
  local dir=$1
  shift
  printf '%s\n' "$*" > "$dir/allowed"
  rm -f "$dir/server-down"
}

fm_lavish_world_fakebin() {  # <dir> <fakebin>
  local dir=$1 fakebin=$2
  mkdir -p "$fakebin"
  cat > "$fakebin/ngrok" <<SH
#!/usr/bin/env bash
world='$dir'
printf 'ngrok %s\n' "\$*" >> "\$world/calls"
[ "\${1-}" = start ] || exit 1
if [ -e "\$world/ngrok-broken" ]; then
  echo 't=0 lvl=eror msg="failed to start tunnel" err="ERR_NGROK_334 domain in use"'
  exit 1
fi
printf '{"tunnels":[{"name":"%s","public_url":"https://$FM_LAVISH_WORLD_HOST","proto":"https","config":{"addr":"http://127.0.0.1:%s","inspect":true}}]}\n' \
  "\$2" "\$(cat "\$world/port")" > "\$world/tunnels.json"
echo 't=0 lvl=info msg="started tunnel"'
SH
  cat > "$fakebin/lavish-axi" <<SH
#!/usr/bin/env bash
world='$dir'
env_line="link=\${LAVISH_AXI_LINK_HOST-unset} allowed=\${LAVISH_AXI_ALLOWED_HOSTS-unset} no_open=\${LAVISH_AXI_NO_OPEN-unset}"
case "\${1-}" in
  stop)
    printf 'stop\n' >> "\$world/calls"
    : > "\$world/server-down"
    ;;
  server)
    printf 'server %s\n' "\$env_line" >> "\$world/calls"
    if [ -e "\$world/plain-restarter" ]; then
      : > "\$world/allowed"
    else
      printf '%s %s\n' "\${LAVISH_AXI_LINK_HOST-}" "\${LAVISH_AXI_ALLOWED_HOSTS-}" > "\$world/allowed"
    fi
    rm -f "\$world/server-down"
    ;;
  poll)
    printf 'poll %s %s\n' "\$*" "\$env_line" >> "\$world/calls"
    printf 'session:\n  status: feedback\n'
    ;;
  *.html)
    printf 'open %s %s\n' "\$*" "\$env_line" >> "\$world/calls"
    status=\$(cat "\$world/open-status" 2>/dev/null || echo opened)
    printf 'session:\n  file: %s\n  url: "http://%s:4387/session/5e55101d0000abcd"\n  status: %s\nnext_step: "run lavish-axi poll"\n' \
      "\$1" "\${LAVISH_AXI_LINK_HOST:-127.0.0.1}" "\$status"
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/ngrok" "$fakebin/lavish-axi"
}
