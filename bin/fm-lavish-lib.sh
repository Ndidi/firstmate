#!/usr/bin/env bash
# fm-lavish-lib.sh - the one owner of how a Lavish page reaches the captain's
# phone through the machine's ngrok tunnel. Sourced by bin/fm-lavish.sh (the
# open and poll command), bin/fm-procevent-lavish.sh (the armed-source poll),
# and bin/fm-bearings-board.sh (the fleet board), so every path that opens or
# polls a Lavish page applies the same environment without anyone remembering
# it.
#
# OPT-IN AND FAIL-CLOSED. The optional local, gitignored config/lavish-tunnel
# names the ngrok tunnel, defined in the machine's own ngrok configuration,
# that forwards to the Lavish server. When it is absent this home has no public
# route and fm_lavish_public_env returns 3, which the opener refuses and a poll
# treats as "poll locally". When it is present every step below must succeed or
# the caller gets a nonzero return and a diagnostic; nothing falls back to a
# loopback or LAN link.
#
# fm_lavish_public_env [--edge], in order, under one machine-wide lock:
#   1. Find the named tunnel in ngrok's local API (127.0.0.1:4040, then the
#      next ports ngrok moves to when another agent holds 4040). When it is not
#      there, start `ngrok start <name>` detached into its own session, so it
#      outlives the shell and harness that asked for it, and wait for it. A
#      running tunnel is never started twice. Nothing here kills ngrok by
#      command-line match: `pkill -f` on a pattern also matches the shell that
#      runs it.
#   2. Take the public hostname from the tunnel's https public_url rather than
#      assuming a reserved domain, and refuse a tunnel that forwards anywhere
#      but the Lavish port (LAVISH_AXI_PORT, default 4387).
#   3. Export LAVISH_AXI_LINK_HOST and LAVISH_AXI_ALLOWED_HOSTS for that host.
#      A Lavish server only reads them on the call that STARTS it, so probe the
#      tunnel's own forwarding address with that Host header: 200 means the
#      running server already accepts it; 403 ("forbidden host") means it was
#      started without them, so stop it and start it again with them; no
#      answer means start it. Stopping the server interrupts every running
#      `lavish-axi poll` and armed Lavish source on the machine; the armed
#      sources' own retry reattaches them (bin/fm-procevent-lavish.sh), a
#      foreground poll must be re-run, and FM_LAVISH_RESTARTED=1 tells the
#      caller this happened.
#   4. With --edge, prove the public URL itself demands a password: an
#      unauthenticated request must get 401. A tunnel serving pages without
#      basic auth would expose a server that reads arbitrary local files, and
#      Google OAuth is not a substitute because Lavish's sandboxed frame loads
#      /sdk.js without the OAuth cookie and every queue button stops working.
# On success it sets FM_LAVISH_PUBLIC_HOST.
#
# fm_lavish_public_link <lavish-axi-output> prints https://<host>/session/<id>.
# lavish-axi builds its own http://<link-host>:<port>/session/<id> string, which
# is never the link to send.
#
# Test hooks, never operator configuration: FM_LAVISH_NGROK_API replaces the
# list of ngrok API origins, FM_LAVISH_EDGE_OVERRIDE replaces the public origin
# the --edge probe requests, and FM_LAVISH_TUNNEL_WAIT, FM_LAVISH_SERVER_WAIT
# shorten the start deadlines. The machine-wide lock and the detached ngrok log
# live beside Lavish's own state (LAVISH_AXI_STATE_DIR, default ~/.lavish-axi),
# because the server and tunnel they guard are per machine, not per home.

FM_LAVISH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_lavish_err() { printf 'fm-lavish: %s\n' "$*" >&2; }

fm_lavish_port() { printf '%s\n' "${LAVISH_AXI_PORT:-4387}"; }

fm_lavish_state_dir() { printf '%s\n' "${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}"; }

# Print the configured tunnel name. Returns 0 when configured, 1 when the file
# is absent, and 2 (with a diagnostic) when it is present but unusable.
fm_lavish_tunnel_name() {
  local file="${FM_HOME%/}/config/lavish-tunnel" name rc
  # Only a genuinely missing file means "not configured": a path that cannot
  # be inspected must never quietly turn the public route off.
  name=$(perl -MFcntl=:mode -e '
    my ($path) = @ARGV;
    if (!lstat $path) { exit($!{ENOENT} ? 10 : 11) }
    open my $file, "<", $path or exit 11;
    my @stat = stat $file;
    exit 11 unless @stat && S_ISREG($stat[2]);
    local $/;
    my $text = <$file>;
    exit 11 unless defined $text;
    print $text;
  ' "$file")
  rc=$?
  case "$rc" in
    0) ;;
    10) return 1 ;;
    *)
      fm_lavish_err "config/lavish-tunnel must be a readable regular file"
      return 2
      ;;
  esac
  if ! [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    fm_lavish_err "config/lavish-tunnel must contain one ngrok tunnel name (letters, digits, dot, dash, underscore)"
    return 2
  fi
  printf '%s\n' "$name"
}

# fm_lavish_http_status <url> [host-header] [timeout-seconds]: print the HTTP
# status, or 000 when nothing answered. Loopback probes bypass any proxy.
fm_lavish_http_status() {
  local url=$1 host=${2-} timeout=${3:-5} code
  local -a args=(-s -o /dev/null -w '%{http_code}' --max-time "$timeout")
  case "$url" in
    http://127.0.0.1[:/]* | http://localhost[:/]* | http://\[::1\][:/]*) args+=(--noproxy '*') ;;
  esac
  [ -z "$host" ] || args+=(-H "Host: $host")
  code=$(curl "${args[@]}" "$url" 2>/dev/null) || true
  case "$code" in
    [0-9][0-9][0-9]) ;;
    *) code=000 ;;
  esac
  printf '%s\n' "$code"
}

fm_lavish_ngrok_apis() {
  if [ -n "${FM_LAVISH_NGROK_API-}" ]; then
    printf '%s\n' "$FM_LAVISH_NGROK_API"
    return 0
  fi
  local port apis=''
  for port in 4040 4041 4042 4043 4044 4045 4046 4047 4048 4049; do
    apis+="http://127.0.0.1:$port "
  done
  printf '%s\n' "${apis% }"
}

# fm_lavish_tunnel_lookup <name>: print "<public_url>\t<addr>" for the running
# tunnel with that exact name, or return 1 when no ngrok API lists it.
fm_lavish_tunnel_lookup() {
  local name=$1 api body found
  for api in $(fm_lavish_ngrok_apis); do
    body=$(curl -s --noproxy '*' --max-time 3 "${api%/}/api/tunnels" 2>/dev/null) || continue
    [ -n "$body" ] || continue
    if found=$(printf '%s' "$body" | perl -MJSON::PP -e '
      my ($name) = @ARGV;
      local $/;
      my $doc = eval { JSON::PP->new->decode(<STDIN>) };
      exit 1 unless ref $doc eq "HASH" && ref $doc->{tunnels} eq "ARRAY";
      for my $t (@{ $doc->{tunnels} }) {
        next unless ref $t eq "HASH" && defined $t->{name} && $t->{name} eq $name;
        my $url = defined $t->{public_url} ? $t->{public_url} : "";
        my $addr = ref $t->{config} eq "HASH" && defined $t->{config}{addr} ? $t->{config}{addr} : "";
        print "$url\t$addr\n";
        exit 0;
      }
      exit 1;
    ' "$name"); then
      printf '%s\n' "$found"
      return 0
    fi
  done
  return 1
}

# fm_lavish_detach <log> <command...>: run a command in its own session with its
# output appended to <log>, so it survives the shell, process group, and harness
# that started it. Portable to macOS, which ships no setsid(1).
fm_lavish_detach() {
  local log=$1
  shift
  perl -MPOSIX=setsid -e '
    my $log = shift;
    defined(my $pid = fork) or die "fork: $!\n";
    exit 0 if $pid;
    setsid() or die "setsid: $!\n";
    defined($pid = fork) or die "fork: $!\n";
    exit 0 if $pid;
    open STDIN, "<", "/dev/null" or die "stdin: $!\n";
    open STDOUT, ">>", $log or die "log: $!\n";
    open STDERR, ">&", \*STDOUT or die "stderr: $!\n";
    exec @ARGV or die "exec $ARGV[0]: $!\n";
  ' "$log" "$@"
}

fm_lavish_log_tail() {  # <log>
  [ -f "$1" ] || return 0
  tail -n 5 -- "$1" 2>/dev/null | sed 's/^/  /' >&2
}

# fm_lavish_tunnel_ensure <name>: print "<public_url>\t<addr>" for the running
# tunnel, starting it first when no ngrok API lists it.
fm_lavish_tunnel_ensure() {
  local name=$1 found log wait deadline
  if found=$(fm_lavish_tunnel_lookup "$name"); then
    printf '%s\n' "$found"
    return 0
  fi
  if ! command -v ngrok >/dev/null 2>&1; then
    fm_lavish_err "ngrok is not installed, so the '$name' tunnel config/lavish-tunnel names cannot be started"
    return 1
  fi
  log="$(fm_lavish_state_dir)/fm-ngrok-$name.log"
  mkdir -p "$(fm_lavish_state_dir)" || { fm_lavish_err "cannot create $(fm_lavish_state_dir)"; return 1; }
  fm_lavish_detach "$log" ngrok start "$name" --log=stdout \
    || { fm_lavish_err "cannot start ngrok tunnel '$name'"; return 1; }
  wait=${FM_LAVISH_TUNNEL_WAIT:-20}
  deadline=$((SECONDS + wait))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if found=$(fm_lavish_tunnel_lookup "$name"); then
      printf '%s\n' "$found"
      return 0
    fi
    sleep 0.25
  done
  fm_lavish_err "ngrok tunnel '$name' did not come up within ${wait}s; is it defined in the ngrok config, and is the domain free? Last lines of $log:"
  fm_lavish_log_tail "$log"
  return 1
}

# fm_lavish_public_host <public_url>: print the host of an https public URL.
fm_lavish_public_host() {
  local url=$1 host
  host=$(printf '%s' "$url" | sed -n -E 's#^https://([A-Za-z0-9.-]+)/?$#\1#p')
  if [ -z "$host" ]; then
    fm_lavish_err "the tunnel's public URL is not a plain https origin: ${url:-none}"
    return 1
  fi
  printf '%s\n' "$host"
}

# fm_lavish_forward_base <addr>: print the http origin the tunnel forwards to,
# refusing any port but the Lavish server's.
fm_lavish_forward_base() {
  local addr=$1 base port
  case "$addr" in
    '') fm_lavish_err "the tunnel reports no forwarding address"; return 1 ;;
    *[!0-9]*) ;;
    *) addr="localhost:$addr" ;;
  esac
  case "$addr" in
    http://*) base=$addr ;;
    *://*) fm_lavish_err "the tunnel forwards to $addr, but the Lavish server speaks plain http"; return 1 ;;
    *) base="http://$addr" ;;
  esac
  base=${base%/}
  port=$(printf '%s' "$base" | sed -n -E 's#^http://.*:([0-9]+)$#\1#p')
  if [ "$port" != "$(fm_lavish_port)" ]; then
    fm_lavish_err "the tunnel forwards to $base, but the Lavish server listens on port $(fm_lavish_port)"
    return 1
  fi
  printf '%s\n' "$base"
}

# Wait until the probe answers something other than <while-code>.
fm_lavish_wait_while() {  # <base> <host> <while-code> <seconds>
  local deadline=$((SECONDS + $4))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$(fm_lavish_http_status "$1/health" "$2" 2)" != "$3" ] && return 0
    sleep 0.2
  done
  return 1
}

fm_lavish_server_start() {
  local log
  log="$(fm_lavish_state_dir)/server.log"
  mkdir -p "$(fm_lavish_state_dir)" || { fm_lavish_err "cannot create $(fm_lavish_state_dir)"; return 1; }
  fm_lavish_detach "$log" env LAVISH_AXI_NO_OPEN=1 lavish-axi server --port "$(fm_lavish_port)"
}

# fm_lavish_server_ensure <base> <host>: leave a Lavish server answering the
# tunnel's forwarding address that accepts <host>. Environment must already be
# exported by the caller.
fm_lavish_server_ensure() {
  local base=$1 host=$2 code actions=0 wait=${FM_LAVISH_SERVER_WAIT:-10}
  command -v lavish-axi >/dev/null 2>&1 || { fm_lavish_err "lavish-axi is not installed"; return 1; }
  while :; do
    code=$(fm_lavish_http_status "$base/health" "$host")
    case "$code" in
      200) return 0 ;;
      403 | 000) ;;
      *)
        fm_lavish_err "the Lavish server at $base answered HTTP $code instead of its health check"
        return 1
        ;;
    esac
    if [ "$actions" -ge 3 ]; then
      if [ "$code" = 403 ]; then
        fm_lavish_err "the Lavish server keeps coming back without $host in its allowed hosts; something is starting it with a plain lavish-axi call instead of bin/fm-lavish.sh"
      else
        fm_lavish_err "no Lavish server answers at $base, where the tunnel forwards; if config/lavish-axi-host binds the server to another address, the tunnel cannot reach it. Last lines of $(fm_lavish_state_dir)/server.log:"
        fm_lavish_log_tail "$(fm_lavish_state_dir)/server.log"
      fi
      return 1
    fi
    actions=$((actions + 1))
    if [ "$code" = 403 ]; then
      lavish-axi stop >/dev/null 2>&1 || true
      fm_lavish_wait_while "$base" "$host" 403 "$wait" || true
      # shellcheck disable=SC2034 # Read by callers after fm_lavish_public_env.
      FM_LAVISH_RESTARTED=1
    fi
    fm_lavish_server_start || { fm_lavish_err "cannot start the Lavish server"; return 1; }
    fm_lavish_wait_while "$base" "$host" 000 "$wait" || true
  done
}

# fm_lavish_edge_check <host>: the public origin must demand a password.
fm_lavish_edge_check() {
  local host=$1 origin code
  origin=${FM_LAVISH_EDGE_OVERRIDE:-https://$host}
  code=$(fm_lavish_http_status "${origin%/}/health" '' 15)
  case "$code" in
    401) return 0 ;;
    000)
      fm_lavish_err "https://$host did not answer from this machine, so the captain's phone cannot reach it either"
      ;;
    2[0-9][0-9] | 3[0-9][0-9])
      fm_lavish_err "https://$host answered HTTP $code without a password; the tunnel must use basic auth (never OAuth), because an open tunnel exposes a server that serves local files"
      ;;
    *)
      fm_lavish_err "https://$host answered HTTP $code instead of asking for its password"
      ;;
  esac
  return 1
}

# Add <host> to LAVISH_AXI_ALLOWED_HOSTS once, keeping whatever was already set.
fm_lavish_allow_host() {
  local host=$1 existing=${LAVISH_AXI_ALLOWED_HOSTS-} item
  for item in $existing; do
    [ "$item" != "$host" ] || return 0
  done
  export LAVISH_AXI_ALLOWED_HOSTS="${existing:+$existing }$host"
}

fm_lavish_public_env_locked() {  # <tunnel-name>
  local found url addr host base
  found=$(fm_lavish_tunnel_ensure "$1") || return 1
  url=${found%%$'\t'*}
  addr=${found#*$'\t'}
  host=$(fm_lavish_public_host "$url") || return 1
  base=$(fm_lavish_forward_base "$addr") || return 1
  export LAVISH_AXI_LINK_HOST=$host
  fm_lavish_allow_host "$host"
  fm_lavish_server_ensure "$base" "$host" || return 1
  FM_LAVISH_PUBLIC_HOST=$host
}

# fm_lavish_public_env [--edge]: see the header. Returns 0 ready, 3 when this
# home configures no tunnel, and 1 on any failure.
fm_lavish_public_env() {
  local edge=0 name rc lock
  [ "${1-}" != --edge ] || edge=1
  # shellcheck disable=SC2034 # Read by callers after fm_lavish_public_env.
  FM_LAVISH_RESTARTED=0
  FM_LAVISH_PUBLIC_HOST=
  if name=$(fm_lavish_tunnel_name); then
    :
  else
    rc=$?
    [ "$rc" -eq 1 ] && return 3
    return 1
  fi
  if ! command -v fm_lock_acquire_wait_bounded >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$FM_LAVISH_LIB_DIR/fm-wake-lib.sh"
  fi
  mkdir -p "$(fm_lavish_state_dir)" || { fm_lavish_err "cannot create $(fm_lavish_state_dir)"; return 1; }
  lock="$(fm_lavish_state_dir)/fm-lavish.lock"
  if ! fm_lock_acquire_wait_bounded "$lock" 60; then
    fm_lavish_err "another Lavish tunnel or server check still holds $lock"
    return 1
  fi
  if fm_lavish_public_env_locked "$name"; then
    rc=0
  else
    rc=1
  fi
  fm_lock_release "$lock"
  [ "$rc" -eq 0 ] || return 1
  if [ "$edge" -eq 1 ]; then
    fm_lavish_edge_check "$FM_LAVISH_PUBLIC_HOST" || return 1
  fi
  return 0
}

# fm_lavish_session_id <lavish-axi-output>: the id from its session url line.
fm_lavish_session_id() {
  printf '%s\n' "$1" | sed -n -E 's#^[[:space:]]*url:[[:space:]]*"?[a-z]+://[^/]+/session/([A-Za-z0-9_-]+).*#\1#p' | head -n 1
}

fm_lavish_public_link() {  # <lavish-axi-output>
  local id
  id=$(fm_lavish_session_id "$1")
  if [ -z "$id" ] || [ -z "${FM_LAVISH_PUBLIC_HOST-}" ]; then
    fm_lavish_err "cannot read a session id from lavish-axi's output"
    return 1
  fi
  printf 'https://%s/session/%s\n' "$FM_LAVISH_PUBLIC_HOST" "$id"
}
