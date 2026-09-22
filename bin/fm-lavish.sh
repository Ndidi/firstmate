#!/usr/bin/env bash
# fm-lavish.sh - put a Lavish page on the captain's phone, and poll it.
#
# Usage:
#   fm-lavish.sh open <artifact.html> [--reopen]
#   fm-lavish.sh poll <artifact.html> [--agent-reply <text>]
#
# open   Make sure the ngrok tunnel config/lavish-tunnel names is up (starting
#        it once, never twice), read its public hostname from ngrok's local
#        API, make sure the Lavish server accepts that hostname (restarting it
#        with the right environment when it does not), prove the public URL
#        asks for a password, then open or resume the page's session without
#        popping a local browser tab. Output:
#          link: https://<host>/session/<id>     the ONLY link to send
#          status: <lavish-axi session status>
#          artifact: <absolute path>
#          server-restarted: running Lavish polls were interrupted ...
#                                               (only when it had to restart)
#        Running it on a page that is already open just resumes the session
#        and prints its link, so it is also how to get the phone link for a
#        page a worker or another tool opened. Without config/lavish-tunnel it
#        refuses: this command never prints a loopback or LAN link. A session
#        the captain ended from the page refuses unless --reopen is given,
#        which is only for when he asked for more review or something
#        important needs his eyes.
# poll   Wait for the captain's answers with the same environment, so a poll
#        that has to start the Lavish server starts it reachable through the
#        tunnel. It runs the published blocking `lavish-axi poll` in the
#        foreground and prints its response verbatim. Without
#        config/lavish-tunnel it polls locally. Pages Firstmate owns are
#        normally armed with bin/fm-procevent-lavish.sh instead, whose poll
#        applies the same environment.
#
# bin/fm-lavish-lib.sh owns every step and every refusal; this script is its
# command line. docs/configuration.md "Lavish public links" owns the setup.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-lavish-lib.sh
. "$SCRIPT_DIR/fm-lavish-lib.sh"

die() { printf 'fm-lavish: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

artifact_path() {  # <artifact>
  local real
  case "$1" in
    *.html | *.htm | *.HTML | *.HTM) ;;
    *) die "Lavish serves an .html file: $1" ;;
  esac
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null) \
    || die "artifact does not exist: $1"
  [ -f "$real" ] && [ -r "$real" ] || die "artifact is not a readable file: $1"
  printf '%s\n' "$real"
}

session_status() {  # <lavish-axi-output>
  printf '%s\n' "$1" | sed -n -E 's/^[[:space:]]+status:[[:space:]]*"?([A-Za-z_-]+)"?[[:space:]]*$/\1/p' | head -n 1
}

cmd_open() {
  local artifact='' reopen=0 real rc out status link
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reopen) reopen=1 ;;
      -*) usage ;;
      *)
        [ -z "$artifact" ] || usage
        artifact=$1
        ;;
    esac
    shift
  done
  [ -n "$artifact" ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  real=$(artifact_path "$artifact")
  fm_lavish_public_env --edge
  rc=$?
  case "$rc" in
    0) ;;
    3) die "no public tunnel is configured for Lavish (config/lavish-tunnel is absent), so this page could only open on this computer; see docs/configuration.md \"Lavish public links\"" ;;
    *) die "the page was not opened, because it could not be made reachable from the captain's phone" ;;
  esac
  if [ "$reopen" -eq 1 ]; then
    out=$(LAVISH_AXI_NO_OPEN=1 lavish-axi "$real" --reopen) || die "lavish-axi could not open $real"
  else
    out=$(LAVISH_AXI_NO_OPEN=1 lavish-axi "$real") || die "lavish-axi could not open $real"
  fi
  status=$(session_status "$out")
  case "$status" in
    user-ended)
      die "the captain ended this page's session from the page; pass --reopen only when he asked for more review or something important needs his attention"
      ;;
  esac
  link=$(fm_lavish_public_link "$out") || die "lavish-axi opened the page but printed no session link"
  printf 'link: %s\n' "$link"
  printf 'status: %s\n' "${status:-unknown}"
  printf 'artifact: %s\n' "$real"
  if [ "${FM_LAVISH_RESTARTED:-0}" = 1 ]; then
    printf 'server-restarted: the Lavish server was running without the public host and was restarted; armed Lavish sources reattach on their own, and any foreground lavish-axi poll that was running must be re-run\n'
  fi
}

cmd_poll() {
  local artifact=${1-} real rc
  [ -n "$artifact" ] || usage
  shift
  case "$#" in
    0) ;;
    2) [ "$1" = --agent-reply ] || usage ;;
    *) usage ;;
  esac
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  real=$(artifact_path "$artifact")
  fm_lavish_public_env
  rc=$?
  case "$rc" in
    0 | 3) ;;
    *) die "not polling, because the page could not be kept reachable from the captain's phone" ;;
  esac
  exec lavish-axi poll "$real" "$@"
}

case "${1-}" in
  open) shift; cmd_open "$@" ;;
  poll) shift; cmd_poll "$@" ;;
  -h | --help | help) usage ;;
  *) usage ;;
esac
