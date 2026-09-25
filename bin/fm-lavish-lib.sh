#!/usr/bin/env bash
# fm-lavish-lib.sh - the one owner of how a Lavish page reaches the captain's
# phone, over Tailscale or through the machine's ngrok tunnel. Sourced by
# bin/fm-lavish.sh (the open and poll command), bin/fm-procevent-lavish.sh (the
# armed-source poll), and bin/fm-bearings-board.sh (the fleet board), so every
# path that opens or polls a Lavish page applies the same environment without
# anyone remembering it.
#
# OPT-IN AND FAIL-CLOSED. Two optional local, gitignored files select the
# route. config/lavish-tailscale, an empty presence flag, selects the tailnet
# route and wins whenever it is present. Otherwise config/lavish-tunnel names
# the ngrok tunnel, defined in the machine's own ngrok configuration, that
# forwards to the Lavish server. When neither is present this home has no
# phone route and fm_lavish_public_env returns 3, which the opener refuses and
# a poll treats as "poll locally". When one is present every step below must
# succeed or the caller gets a nonzero return and a diagnostic; nothing falls
# back to a loopback or LAN link, and a present file that cannot be read or
# holds the wrong content refuses rather than reading as absent.
#
# fm_lavish_public_env [--edge], under one machine-wide lock:
#
# Tailnet route (config/lavish-tailscale):
#   1. Read this machine's own tailnet identity from `tailscale status --json`
#      (Self): the first IPv4 address in TailscaleIPs and the MagicDNS name.
#      Refuse when the tailscale CLI is missing, the backend is not Running,
#      or Self has no IPv4 address.
#   2. Export LAVISH_AXI_LINK_HOST as that IPv4 address and add to
#      LAVISH_AXI_ALLOWED_HOSTS the address and the MagicDNS name, each with
#      and without the Lavish port, alongside 127.0.0.1 and localhost.
#   3. Keep the Lavish server on its default loopback bind and make it
#      reachable from the tailnet through a small relay this library starts,
#      listening only on <tailnet-ipv4>:<port> and forwarding raw TCP to
#      127.0.0.1:<port>, so the Host header reaches Lavish unchanged. The bind
#      is deliberate. Binding the server itself to the tailnet address would
#      keep it off the LAN, but lavish-axi's client side (open, poll, stop, and
#      every armed source) connects to LAVISH_AXI_HOST or else 127.0.0.1, and
#      measured on lavish-axi 0.1.47 a plain local call that cannot reach a
#      tailnet-only server silently starts a second server on 127.0.0.1 that
#      shares the first one's state file. Binding 0.0.0.0 avoids that but
#      exposes an unauthenticated server that reads local files to every LAN
#      the laptop joins. The relay gives both: plain local calls keep finding
#      the one loopback server, and nothing off the tailnet can connect. The
#      relay runs detached like the ngrok tunnel, writes its pid to
#      fm-tailnet-relay.pid beside Lavish's state once it listens, and exits by
#      itself within a second when that file is removed or names another
#      process. When something already accepts connections on the tailnet
#      address (a server started bound to 0.0.0.0, or a relay that is already
#      running) no relay is started.
#   4. Probe http://<tailnet-ipv4>:<port>/health, the path the phone takes,
#      with Host <tailnet-ipv4>:<port>, three ways as on the tunnel route
#      below: 200 keeps the running server untouched, 403 restarts it with the
#      exported environment, and no answer starts it.
#   The --edge password check is for the public tunnel only and does not apply
#   here: a tailnet peer is already authenticated by Tailscale, which is the
#   captain's ruling that his own pages need no login.
#
# Tunnel route (config/lavish-tunnel):
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
#
# On success it sets FM_LAVISH_PUBLIC_HOST and FM_LAVISH_PUBLIC_ORIGIN
# (https://<host> on the tunnel route, http://<tailnet-ipv4>:<port> on the
# tailnet route).
#
# fm_lavish_public_link <lavish-axi-output> prints <origin>/session/<id>.
# lavish-axi builds its own http://<link-host>:<port>/session/<id> string, which
# is never the link to send.
#
# Test hooks, never operator configuration: FM_LAVISH_NGROK_API replaces the
# list of ngrok API origins, FM_LAVISH_EDGE_OVERRIDE replaces the public origin
# the --edge probe requests, and FM_LAVISH_TUNNEL_WAIT, FM_LAVISH_SERVER_WAIT
# shorten the start deadlines. The machine-wide lock, the detached ngrok and
# relay logs, and the relay's pid file live beside Lavish's own state
# (LAVISH_AXI_STATE_DIR, default ~/.lavish-axi), because the server, tunnel,
# and relay they guard are per machine, not per home.

FM_LAVISH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_lavish_err() { printf 'fm-lavish: %s\n' "$*" >&2; }

fm_lavish_port() { printf '%s\n' "${LAVISH_AXI_PORT:-4387}"; }

fm_lavish_state_dir() { printf '%s\n' "${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}"; }

# fm_lavish_config_read <name>: print config/<name>'s content. Returns 0 when
# present, 1 when the file is absent, and 2 (with a diagnostic) when it cannot
# be read.
fm_lavish_config_read() {
  local file="${FM_HOME%/}/config/$1" text rc
  # Only a genuinely missing file means "not configured": a path that cannot
  # be inspected must never quietly turn a route off.
  text=$(perl -MFcntl=:mode -e '
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
    0) printf '%s' "$text" ;;
    10) return 1 ;;
    *)
      fm_lavish_err "config/$1 must be a readable regular file"
      return 2
      ;;
  esac
}

# Print the configured tunnel name. Returns 0 when configured, 1 when the file
# is absent, and 2 (with a diagnostic) when it is present but unusable.
fm_lavish_tunnel_name() {
  local name
  name=$(fm_lavish_config_read lavish-tunnel) || return
  if ! [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    fm_lavish_err "config/lavish-tunnel must contain one ngrok tunnel name (letters, digits, dot, dash, underscore)"
    return 2
  fi
  printf '%s\n' "$name"
}

# fm_lavish_tailscale_selected: returns 0 when config/lavish-tailscale selects
# the tailnet route, 1 when the file is absent, and 2 (with a diagnostic) when
# it is present but unusable. The file is a presence flag and must be empty, so
# a line someone meant as a setting is refused rather than silently ignored.
fm_lavish_tailscale_selected() {
  local text
  text=$(fm_lavish_config_read lavish-tailscale) || return
  if [[ $text =~ [^[:space:]] ]]; then
    fm_lavish_err "config/lavish-tailscale is a presence flag and must be empty; it takes no settings"
    return 2
  fi
}

# fm_lavish_tailnet_self: print "<ipv4>\t<magicdns-name>" for this machine, read
# from `tailscale status --json`, or refuse with a diagnostic. The name is
# empty when MagicDNS is off.
fm_lavish_tailnet_self() {
  local json found rc
  if ! command -v tailscale >/dev/null 2>&1; then
    fm_lavish_err "tailscale is not installed, so config/lavish-tailscale cannot put pages on the tailnet"
    return 1
  fi
  if ! json=$(tailscale status --json 2>/dev/null) || [ -z "$json" ]; then
    fm_lavish_err "tailscale status --json failed; is Tailscale running on this machine?"
    return 1
  fi
  found=$(printf '%s' "$json" | perl -MJSON::PP -e '
    local $/;
    my $doc = eval { JSON::PP->new->decode(<STDIN>) };
    exit 10 unless ref $doc eq "HASH";
    my $state = defined $doc->{BackendState} ? $doc->{BackendState} : "";
    if ($state ne "Running") { print $state eq "" ? "unknown" : $state; exit 11 }
    my $self = $doc->{Self};
    exit 12 unless ref $self eq "HASH" && ref $self->{TailscaleIPs} eq "ARRAY";
    my ($ip) = grep { defined && /^\d{1,3}(?:\.\d{1,3}){3}$/ } @{ $self->{TailscaleIPs} };
    exit 12 unless defined $ip;
    my $name = defined $self->{DNSName} ? lc $self->{DNSName} : "";
    $name =~ s/\.$//;
    $name = "" unless $name =~ /^[a-z0-9][a-z0-9.-]*$/;
    print "$ip\t$name\n";
  ')
  rc=$?
  case "$rc" in
    0) printf '%s\n' "$found" ;;
    11) fm_lavish_err "Tailscale is not running on this machine (its state is $found); start it and sign in, then open the page again" ;;
    12) fm_lavish_err "Tailscale reports no IPv4 address for this machine, so there is no tailnet link to print" ;;
    *) fm_lavish_err "tailscale status --json printed something that is not its status document" ;;
  esac
  return "$rc"
}

# fm_lavish_http_status <url> [host-header] [timeout-seconds]: print the HTTP
# status, or 000 when nothing answered. Loopback and IP-literal probes, which
# here only ever name this machine (its loopback or its own tailnet address),
# bypass any proxy.
fm_lavish_http_status() {
  local url=$1 host=${2-} timeout=${3:-5} code
  local -a args=(-s -o /dev/null -w '%{http_code}' --max-time "$timeout")
  case "$url" in
    http://localhost[:/]* | http://\[::1\][:/]* | http://[0-9]*) args+=(--noproxy '*') ;;
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

# fm_lavish_server_ensure <base> <host> [prepare-command]: leave a Lavish
# server answering <base>, the address the phone's route reaches, that accepts
# <host>. Environment must already be exported by the caller. The optional
# prepare command runs before every probe and after stopping a server, so the
# tailnet route can bring its relay back when the stopped server was the one
# listening on the tailnet address.
fm_lavish_server_ensure() {
  local base=$1 host=$2 prepare=${3-} code actions=0 wait=${FM_LAVISH_SERVER_WAIT:-10}
  command -v lavish-axi >/dev/null 2>&1 || { fm_lavish_err "lavish-axi is not installed"; return 1; }
  while :; do
    [ -z "$prepare" ] || $prepare || return 1
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
        fm_lavish_err "no Lavish server answers at $base, where the phone's route reaches it; if config/lavish-axi-host binds the server to another address, the tunnel or tailnet relay cannot reach it. Last lines of $(fm_lavish_state_dir)/server.log:"
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
      [ -z "$prepare" ] || $prepare || return 1
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

# fm_lavish_tcp_accepts <address> <port>: succeed when something accepts a TCP
# connection there.
fm_lavish_tcp_accepts() {
  perl -MIO::Socket::INET -e '
    IO::Socket::INET->new(PeerAddr => $ARGV[0], PeerPort => $ARGV[1], Proto => "tcp", Timeout => 2) or exit 1;
  ' "$1" "$2" 2>/dev/null
}

# The relay: listen on <address>:<port> only, and copy bytes both ways between
# each accepted connection and 127.0.0.1:<port>, one forked child per
# connection. Once listening it writes its pid to <pid-file>; it exits within a
# second when that file is removed or names another process.
# shellcheck disable=SC2016 # Perl source, expanded by perl rather than the shell.
FM_LAVISH_RELAY_PERL='
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
my ($addr, $port, $pidfile) = @ARGV;
my $listener = IO::Socket::INET->new(
  LocalAddr => $addr, LocalPort => $port, Proto => "tcp", Listen => 64, ReuseAddr => 1,
) or die "fm-lavish relay: cannot listen on $addr:$port: $!\n";
open my $out, ">", "$pidfile.$$" or die "fm-lavish relay: $pidfile: $!\n";
print {$out} "$$\n";
close $out;
rename "$pidfile.$$", $pidfile or die "fm-lavish relay: $pidfile: $!\n";
print STDERR "fm-lavish relay $$ listening on $addr:$port\n";
$SIG{CHLD} = "IGNORE";
my $accepting = IO::Select->new($listener);
sub still_owner {
  open my $in, "<", $pidfile or return 0;
  my $pid = <$in>;
  return defined $pid && $pid =~ /^(\d+)$/ && $1 == $$;
}
while (still_owner()) {
  next unless $accepting->can_read(1);
  my $client = $listener->accept or next;
  my $child = fork;
  if (!defined $child || $child) { close $client; next }
  close $listener;
  $SIG{PIPE} = "IGNORE";
  my $upstream = IO::Socket::INET->new(PeerAddr => "127.0.0.1", PeerPort => $port, Proto => "tcp") or exit 0;
  my %peer = ($client => $upstream, $upstream => $client);
  my $open = IO::Select->new($client, $upstream);
  while ($open->count) {
    for my $from ($open->can_read) {
      my $to = $peer{$from};
      my $got = sysread $from, my $buf, 65536;
      if (!$got) {
        exit 0 unless defined $got;
        $open->remove($from);
        shutdown $to, 1;
        next;
      }
      for (my $done = 0; $done < $got;) {
        my $wrote = syswrite $to, $buf, $got - $done, $done;
        exit 0 unless $wrote;
        $done += $wrote;
      }
    }
  }
  exit 0;
}
'

# fm_lavish_relay_ensure <tailnet-ipv4>: leave something accepting connections
# on <tailnet-ipv4>:<port>, starting the relay when nothing does.
fm_lavish_relay_ensure() {
  local addr=$1 port log pidfile deadline
  port=$(fm_lavish_port)
  fm_lavish_tcp_accepts "$addr" "$port" && return 0
  log="$(fm_lavish_state_dir)/fm-tailnet-relay.log"
  pidfile="$(fm_lavish_state_dir)/fm-tailnet-relay.pid"
  fm_lavish_detach "$log" perl -e "$FM_LAVISH_RELAY_PERL" "$addr" "$port" "$pidfile" \
    || { fm_lavish_err "cannot start the tailnet relay"; return 1; }
  deadline=$((SECONDS + ${FM_LAVISH_SERVER_WAIT:-10}))
  while [ "$SECONDS" -lt "$deadline" ]; do
    fm_lavish_tcp_accepts "$addr" "$port" && return 0
    sleep 0.2
  done
  fm_lavish_err "the tailnet relay did not start listening on $addr:$port. Last lines of $log:"
  fm_lavish_log_tail "$log"
  return 1
}

fm_lavish_tailnet_env_locked() {
  local self addr name port item
  self=$(fm_lavish_tailnet_self) || return 1
  addr=${self%%$'\t'*}
  name=${self#*$'\t'}
  port=$(fm_lavish_port)
  export LAVISH_AXI_LINK_HOST=$addr
  for item in "$addr" "$addr:$port" ${name:+"$name" "$name:$port"} 127.0.0.1 "127.0.0.1:$port" localhost "localhost:$port"; do
    fm_lavish_allow_host "$item"
  done
  fm_lavish_server_ensure "http://$addr:$port" "$addr:$port" "fm_lavish_relay_ensure $addr" || return 1
  # shellcheck disable=SC2034 # Read by fm_lavish_public_link and callers.
  FM_LAVISH_PUBLIC_ORIGIN="http://$addr:$port"
  FM_LAVISH_PUBLIC_HOST=$addr
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
  # shellcheck disable=SC2034 # Read by fm_lavish_public_link and callers.
  FM_LAVISH_PUBLIC_ORIGIN="https://$host"
  FM_LAVISH_PUBLIC_HOST=$host
}

# fm_lavish_public_env [--edge]: see the header. Returns 0 ready, 3 when this
# home configures no phone route, and 1 on any failure.
fm_lavish_public_env() {
  local edge=0 name='' rc lock
  [ "${1-}" != --edge ] || edge=1
  # shellcheck disable=SC2034 # Read by callers after fm_lavish_public_env.
  FM_LAVISH_RESTARTED=0
  FM_LAVISH_PUBLIC_HOST=
  FM_LAVISH_PUBLIC_ORIGIN=
  if fm_lavish_tailscale_selected; then
    edge=0
  else
    rc=$?
    [ "$rc" -eq 1 ] || return 1
    if name=$(fm_lavish_tunnel_name); then
      :
    else
      rc=$?
      [ "$rc" -eq 1 ] && return 3
      return 1
    fi
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
  if [ -z "$name" ] && fm_lavish_tailnet_env_locked; then
    rc=0
  elif [ -n "$name" ] && fm_lavish_public_env_locked "$name"; then
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
  if [ -z "$id" ] || [ -z "${FM_LAVISH_PUBLIC_ORIGIN-}" ]; then
    fm_lavish_err "cannot read a session id from lavish-axi's output"
    return 1
  fi
  printf '%s/session/%s\n' "$FM_LAVISH_PUBLIC_ORIGIN" "$id"
}
