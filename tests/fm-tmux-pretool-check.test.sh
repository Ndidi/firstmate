#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the tmux-guard PreToolUse seatbelt (docs/tmux-guard.md).
#
# bin/fm-tmux-command-policy.mjs is the single owner of the block/allow decision;
# it reuses the shell classifier owned by bin/fm-arm-command-policy.mjs.
# bin/fm-tmux-pretool-check.sh is the stable transport driving all five harness
# entry forms. This suite proves the decision matrix, the harness-output shaping,
# the deliberate scoping difference from the cd-guard (this guard is NOT inert in
# a crewmate/scout worktree), the fail-open transport behavior, the prefilter
# fast path, the end-to-end incident regression, and that firstmate's own
# control-plane tmux calls still work. No harness is spawned; live per-harness
# evidence lives in docs/tmux-guard.md.
#
# TMUX SAFETY: every tmux command in this file runs as
# `env -u TMUX tmux -L <private socket> ...`. $TMUX is unset because a tmux
# client reads its socket path out of $TMUX, which overrides TMUX_TMPDIR
# entirely; the socket is named explicitly because unsetting $TMUX alone falls
# back to the DEFAULT socket, which is a real server. The one deliberately
# destructive fixture runs INSIDE a pane of a private throwaway server, so the
# $TMUX it inherits points at that server and nothing else.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-tmux-pretool-check)

# End a private test server and remove the socket file it leaves behind, so
# repeated runs do not litter the tmux socket directory. Refuses the default
# socket name outright: nothing in this suite may ever address a real server.
kill_private_server() {  # <socket-name>
  local sock=$1
  case "$sock" in
    default|"") fail "kill_private_server refused a non-private socket name: '$sock'" ;;
  esac
  env -u TMUX tmux -L "$sock" kill-server 2>/dev/null || true
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$sock"
}

install_tmux_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-tmux-pretool-check.sh" "$dir/bin/fm-tmux-pretool-check.sh"
  cp "$ROOT/bin/fm-tmux-command-policy.mjs" "$dir/bin/fm-tmux-command-policy.mjs"
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/fm-arm-command-policy.mjs"
  chmod +x "$dir/bin/fm-tmux-pretool-check.sh" "$dir/bin/fm-tmux-command-policy.mjs"
}

make_primary_fixture() {
  local dir=$1
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_tmux_scripts "$dir"
  printf '%s\n' "$dir"
}

# A genuine linked git worktree - the shape bin/fm-spawn.sh hands crewmate/scout
# tasks, and the agent that caused the incident.
make_child_worktree_fixture() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/tmux-guard-test-branch
  : > "$dir/AGENTS.md"
  install_tmux_scripts "$dir"
  printf '%s\n' "$dir"
}

PRIMARY=$(make_primary_fixture "$TMP_ROOT/primary")
CHECK="$PRIMARY/bin/fm-tmux-pretool-check.sh"

# --- full cross-harness acceptance matrix ----------------------------------

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_COMMANDS=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_COMMANDS+=("$3")
}

# BLOCK: destroys a session, window, or pane on the shared server.
matrix_case B01 deny 'tmux kill-server'
matrix_case B02 deny 'tmux kill-server 2>/dev/null'
matrix_case B03 deny 'tmux kill-session'
matrix_case B04 deny 'tmux kill-session -t firstmate'
matrix_case B05 deny 'tmux kill-window'
matrix_case B06 deny 'tmux kill-window -t firstmate:fm-other-task'
matrix_case B07 deny 'tmux kill-pane'
matrix_case B08 deny 'tmux kill-pane -t %3'
# tmux resolves unambiguous command-name prefixes and documented aliases.
matrix_case B09 deny 'tmux kill-serv'
matrix_case B10 deny 'tmux killw -t firstmate:fm-other-task'
matrix_case B11 deny 'tmux killp'
matrix_case B12 deny 'tmux kill-w'
matrix_case B13 deny 'tmux kill-p'
# Ambiguous prefixes: tmux rejects these, so denying them costs nothing.
matrix_case B14 deny 'tmux kill'
matrix_case B15 deny 'tmux k'
# TMUX_TMPDIR is not isolation while $TMUX is set - the incident's exact error.
matrix_case B16 deny 'TMUX_TMPDIR=/tmp/private tmux kill-server'
matrix_case B17 deny 'export TMUX_TMPDIR=$(mktemp -d); tmux kill-server'
# Unsetting $TMUX alone falls back to the DEFAULT socket, still a real server.
matrix_case B18 deny 'env -u TMUX tmux kill-server'
matrix_case B19 deny 'env --unset TMUX tmux kill-server'
# -L default names the very server being protected.
matrix_case B20 deny 'tmux -L default kill-server'
# A subshell, pipeline, or background job does not contain the damage.
matrix_case B21 deny '(tmux kill-server)'
matrix_case B22 deny 'tmux kill-server &'
matrix_case B23 deny 'tmux kill-server | cat'
matrix_case B24 deny 'true && tmux kill-server'
matrix_case B25 deny 'echo go; tmux kill-server'
matrix_case B26 deny $'cleanup() { :; }\ntmux kill-server'
# One level of literal shell payload.
matrix_case B27 deny 'bash -c "tmux kill-server"'
matrix_case B28 deny "sh -c 'tmux kill-window -t other'"
# Quoted or path-qualified command words still cook to tmux.
matrix_case B29 deny '"tmux" kill-server'
matrix_case B30 deny '/usr/bin/tmux kill-server'
matrix_case B31 deny 'tm\ux kill-server'
# tmux's own multi-command separator.
matrix_case B32 deny 'tmux new-session -d \; kill-server'
# Leading assignments and global options before the subcommand.
matrix_case B33 deny 'FOO=1 tmux kill-server'
matrix_case B34 deny 'tmux -2 kill-server'
matrix_case B35 deny 'tmux -f /dev/null kill-server'

# ALLOW: an isolated server, a non-destructive tmux command, or not tmux.
# These are the forms the guard must never make friction for.
matrix_case A01 allow 'env -u TMUX tmux -L fm-test-1234 kill-server'
matrix_case A02 allow 'env -u TMUX tmux -L fm-test-1234 kill-session -t probe'
matrix_case A03 allow 'env -u TMUX tmux -L fm-test-1234 kill-window -t probe:victim'
matrix_case A04 allow 'env -u TMUX tmux -L fm-test-1234 kill-pane -t probe:0.1'
matrix_case A05 allow 'tmux -L fm-test-1234 kill-server'
matrix_case A06 allow 'tmux -Lfm-test-1234 kill-server'
matrix_case A07 allow 'tmux -S /tmp/fm-private/socket kill-server'
matrix_case A08 allow 'env -u TMUX TMUX_TMPDIR=/tmp/fm-private tmux kill-server'
matrix_case A09 allow 'TMUX_TMPDIR=/tmp/fm-private env -u TMUX tmux kill-server'
matrix_case A10 allow 'env -u TMUX tmux -L fm-test-1234 list-sessions'
matrix_case A11 allow 'tmux list-sessions'
matrix_case A12 allow 'tmux list-windows -a'
matrix_case A13 allow 'tmux new-session -d -s probe'
matrix_case A14 allow 'tmux new-window -d -n foo'
matrix_case A15 allow 'tmux send-keys -t firstmate:fm-task hello Enter'
matrix_case A16 allow 'tmux capture-pane -p -t firstmate:fm-task'
matrix_case A17 allow 'tmux display-message -p "#S"'
matrix_case A18 allow 'tmux has-session -t firstmate'
# The control plane reaches tmux through firstmate scripts, never a typed kill.
matrix_case A19 allow 'bin/fm-teardown.sh some-task'
matrix_case A20 allow 'bin/fm-control.sh some-task interrupt'
matrix_case A21 allow 'bin/fm-afk-launch.sh stop'
# The token as data, or another program entirely.
matrix_case A22 allow 'echo "tmux kill-server"'
matrix_case A23 allow "printf '%s\\n' 'tmux kill-server'"
matrix_case A24 allow 'grep -rn "tmux kill-server" docs/'
matrix_case A25 allow 'killall sleep'
matrix_case A26 allow 'pkill -f sleep'
matrix_case A27 allow 'git status'
matrix_case A28 allow 'kill -9 1234'
matrix_case A29 allow 'cat bin/backends/tmux.sh'
matrix_case A30 allow 'tmuxinator start foo'

MATRIX_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-tmux-policy-matrix.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$MATRIX_TMP")

run_matrix_entry() {
  local id=$1 expected=$2 entry=$3 cmd=$4 payload out_file err_file rc
  out_file="$MATRIX_TMP/$id-$entry.out"
  err_file="$MATRIX_TMP/$id-$entry.err"

  case "$entry" in
    codex)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    claude)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" --claude >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    grok)
      payload=$(jq -cn --arg command "$cmd" '{toolName:"run_terminal_command",toolInput:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    opencode|pi)
      "$CHECK" --command "$cmd" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    *)
      fail "unknown matrix entry form: $entry"
      ;;
  esac

  if [ "$expected" = allow ]; then
    [ "$rc" -eq 0 ] || fail "$id via $entry must allow, got exit $rc: $(cat "$err_file")"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must leave stdout empty: $(cat "$out_file")"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must leave stderr empty: $(cat "$err_file")"
    return
  fi

  [ "$rc" -eq 2 ] || fail "$id via $entry must deny, got exit $rc"
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("\\[(shared-tmux-kill-(server|session|window)|unclassifiable-tmux-kill)\\]"))' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must carry a tmux-guard reason code on stderr: $(cat "$err_file")"
  if [ "$entry" = claude ]; then
    [ ! -s "$out_file" ] || fail "$id via claude deny must leave stdout empty: $(cat "$out_file")"
  elif [ "$entry" = grok ]; then
    jq -e '.decision == "deny"' "$out_file" >/dev/null 2>&1 \
      || fail "$id via grok deny must carry decision=deny on stdout: $(cat "$out_file")"
  fi
}

test_full_acceptance_matrix() {
  local i entry
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    for entry in codex claude grok opencode pi; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "$entry" "${MATRIX_COMMANDS[$i]}"
    done
  done
  pass "tmux-guard acceptance matrix: ${#MATRIX_IDS[@]} cases x 5 harness entry forms, block/allow all correct"
}

# --- the deny message must teach the fix ------------------------------------

test_deny_message_teaches_the_isolated_form() {
  local err
  err=$("$CHECK" --claude --command 'tmux kill-server' 2>&1 >/dev/null)
  assert_contains "$err" 'env -u TMUX tmux -L fm-test-$$' \
    "deny must name the isolated form the agent should use instead"
  assert_contains "$err" 'TMUX_TMPDIR' \
    "deny must mention TMUX_TMPDIR, the trap that caused the incident"
  assert_contains "$err" 'overrides TMUX_TMPDIR' \
    "deny must state that \$TMUX overrides TMUX_TMPDIR"
  pass "tmux-guard: the deny message teaches the isolated form and the TMUX_TMPDIR trap"
}

# --- end-to-end incident regression ----------------------------------------

# Reproduces the 2026-08-11 incident for real, then proves the guard denies the
# exact command that caused it. The stand-in for the captain's server is a
# private throwaway socket; the destructive script runs inside a pane of THAT
# server, so the $TMUX it inherits can only point there.
test_e2e_incident_regression() {
  local sock script tmuxdir probe_out victim_socket rc out
  if ! command -v tmux >/dev/null 2>&1; then
    pass "tmux not installed, skipping the live incident reproduction"
    return
  fi

  sock="fm-test-victim-$$"
  tmuxdir="$TMP_ROOT/incident"
  mkdir -p "$tmuxdir"
  probe_out="$tmuxdir/inherited-tmux"
  script="$tmuxdir/incident.sh"

  # A stand-in for the captain's shared server, on a private socket.
  env -u TMUX tmux -L "$sock" new-session -d -s captain -n capwin 'sleep 300' \
    || { pass "cannot start a private tmux server here, skipping the live reproduction"; return; }

  # SAFETY GATE: confirm a pane on this server inherits a $TMUX that points at
  # the private socket, BEFORE anything destructive runs. If it does not, the
  # reproduction is abandoned rather than risking another server.
  env -u TMUX tmux -L "$sock" new-window -d "bash -c 'printf %s \"\$TMUX\" > $probe_out; sleep 300'"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$probe_out" ] && break
    sleep 0.2
  done
  victim_socket=$(cut -d, -f1 < "$probe_out" 2>/dev/null || true)
  case "$victim_socket" in
    *"$sock") ;;
    *)
      kill_private_server "$sock"
      fail "pane did not inherit the private socket in \$TMUX (got '$victim_socket'); refusing to run the destructive fixture"
      ;;
  esac

  # The incident's exact command, byte for byte from the transcript.
  cat > "$script" <<'INCIDENT'
export TMUX_TMPDIR=$(mktemp -d)
S=fmrepro$$
tmux new-session -d -s "$S" -n realwin 'sleep 300'
tmux kill-server 2>/dev/null; rm -rf "$TMUX_TMPDIR"
INCIDENT

  # Run it from a pane of the victim server, exactly as the worker did.
  env -u TMUX tmux -L "$sock" new-window -d "bash $script"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    env -u TMUX tmux -L "$sock" has-session -t captain 2>/dev/null || break
    sleep 0.2
  done

  # The reproduction: TMUX_TMPDIR was a no-op, so kill-server took the server
  # the pane was attached to - the stand-in for the captain's.
  if env -u TMUX tmux -L "$sock" has-session -t captain 2>/dev/null; then
    kill_private_server "$sock"
    fail "baseline: the incident did not reproduce, the victim server survived"
  fi
  kill_private_server "$sock"

  # With the guard, the exact command is denied before it can run.
  out=$("$CHECK" --claude --command "$(cat "$script")" 2>&1); rc=$?
  expect_code 2 "$rc" "guard must deny the exact incident command"
  assert_contains "$out" '[shared-tmux-kill-server]' "incident block must carry the kill-server reason code"
  pass "tmux-guard: reproduces the incident (TMUX_TMPDIR is a no-op) and denies the exact command"
}

# --- the control plane still works -----------------------------------------

# The guard is a TOOL-boundary check: it only ever sees the command an agent
# submits to its shell tool. bin/backends/tmux.sh and bin/fm-afk-launch.sh call
# tmux from inside script processes, which no PreToolUse hook observes. This
# proves both halves - the real control-plane function still kills its target,
# and the tool-boundary command that invokes it is allowed.
test_control_plane_kill_still_works() {
  local sock windows
  if ! command -v tmux >/dev/null 2>&1; then
    pass "tmux not installed, skipping the control-plane proof"
    return
  fi
  sock="fm-test-cp-$$"
  env -u TMUX tmux -L "$sock" new-session -d -s cp -n keepwin 'sleep 300' \
    || { pass "cannot start a private tmux server here, skipping the control-plane proof"; return; }
  env -u TMUX tmux -L "$sock" new-window -d -n fm-victim 'sleep 300'

  # bin/backends/tmux.sh's fm_backend_tmux_kill body, run against the private
  # server: an explicitly named target, exactly as the real function builds it.
  env -u TMUX tmux -L "$sock" kill-window -t '=cp:=fm-victim' 2>/dev/null || true
  windows=$(env -u TMUX tmux -L "$sock" list-windows -t cp -F '#{window_name}' 2>/dev/null | tr '\n' ' ')
  case "$windows" in
    *fm-victim*) kill_private_server "$sock"
                 fail "control-plane kill-window did not remove its target: $windows" ;;
  esac
  case "$windows" in
    *keepwin*) ;;
    *) kill_private_server "$sock"
       fail "control-plane kill-window removed the wrong window: $windows" ;;
  esac

  # bin/fm-afk-launch.sh's dedicated-session close, same shape.
  env -u TMUX tmux -L "$sock" new-session -d -s fm-afk-daemon 'sleep 300'
  env -u TMUX tmux -L "$sock" kill-session -t fm-afk-daemon 2>/dev/null || true
  if env -u TMUX tmux -L "$sock" has-session -t fm-afk-daemon 2>/dev/null; then
    kill_private_server "$sock"
    fail "control-plane kill-session did not remove its dedicated daemon session"
  fi
  env -u TMUX tmux -L "$sock" has-session -t cp 2>/dev/null \
    || { kill_private_server "$sock"
         fail "control-plane kill-session took the wrong session"; }
  kill_private_server "$sock"

  # And the tool-boundary commands that drive those scripts are never blocked.
  "$CHECK" --claude --command 'bin/fm-teardown.sh some-task' \
    || fail "guard must allow the teardown script at the tool boundary"
  "$CHECK" --claude --command 'bin/fm-control.sh some-task exit' \
    || fail "guard must allow the control script at the tool boundary"
  pass "tmux-guard: firstmate's control-plane window/session kills still work and stay allowed"
}

# --- scoping: unlike the cd-guard, workers are bound -------------------------

test_fires_in_child_worktree() {
  local base dir out rc
  base="$TMP_ROOT/child-base"
  dir="$TMP_ROOT/child-wt"
  make_child_worktree_fixture "$base" "$dir" >/dev/null
  out=$("$dir/bin/fm-tmux-pretool-check.sh" --claude --command 'tmux kill-server' 2>&1); rc=$?
  expect_code 2 "$rc" "tmux-guard MUST fire in a crewmate/scout worktree - that is the agent that caused the incident"
  assert_contains "$out" '[shared-tmux-kill-server]' "worktree block must carry the reason code"
  pass "tmux-guard: fires in a crewmate/scout task worktree (deliberately unlike the cd-guard)"
}

test_fires_in_primary_checkout() {
  local out rc
  out=$("$CHECK" --claude --command 'tmux kill-server' 2>&1); rc=$?
  expect_code 2 "$rc" "tmux-guard must bind the primary session too"
  assert_contains "$out" '[shared-tmux-kill-server]' "primary block must carry the reason code"
  pass "tmux-guard: binds firstmate's primary session as well as workers"
}

test_inert_when_not_firstmate_repo() {
  local dir out rc
  dir="$TMP_ROOT/not-firstmate"
  mkdir -p "$dir"
  install_tmux_scripts "$dir"   # bin/ present but no AGENTS.md
  out=$("$dir/bin/fm-tmux-pretool-check.sh" --claude --command 'tmux kill-server' 2>&1); rc=$?
  expect_code 0 "$rc" "tmux-guard must be inert without AGENTS.md (not a firstmate checkout)"
  [ -z "$out" ] || fail "tmux-guard produced output outside a firstmate checkout: $out"
  pass "tmux-guard: inert outside a firstmate checkout"
}

# --- fail-open transport behavior ------------------------------------------

test_fail_open_empty_stdin() {
  local out rc
  out=$("$CHECK" < /dev/null 2>&1); rc=$?
  expect_code 0 "$rc" "transport must exit 0 on empty stdin"
  [ -z "$out" ] || fail "transport produced output on empty stdin: $out"
  pass "tmux-guard: fails open on empty stdin"
}

test_fail_open_unparseable_json() {
  local out rc
  out=$(printf 'not json at all' | "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "transport must exit 0 on unparseable stdin JSON"
  [ -z "$out" ] || fail "transport produced output on unparseable JSON: $out"
  pass "tmux-guard: fails open on unparseable stdin JSON"
}

test_fail_open_missing_node() {
  local fakebin tool tool_path out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/nonode")
  for tool in bash sh git dirname cat printf sed tr jq; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  # node deliberately absent from this PATH.
  out=$(PATH="$fakebin" "$CHECK" --command 'tmux kill-server' 2>&1); rc=$?
  expect_code 0 "$rc" "transport must fail open when node is unavailable"
  [ -z "$out" ] || fail "transport produced output without node: $out"
  pass "tmux-guard: fails open (never blocks) when node is missing"
}

test_fail_open_missing_jq_on_stdin() {
  local fakebin tool tool_path out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/nojq")
  for tool in bash sh git dirname cat printf sed tr node; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  out=$(printf '{"tool_input":{"command":"tmux kill-server"}}' | PATH="$fakebin" "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "stdin transport must fail open when jq is unavailable"
  [ -z "$out" ] || fail "transport produced output without jq on the stdin path: $out"
  pass "tmux-guard: fails open on the stdin path when jq is missing"
}

# --- prefilter fast path ----------------------------------------------------

test_prefilter_skips_node_without_tmux_substring() {
  local dir fakebin marker tool tool_path out rc
  dir="$TMP_ROOT/prefilter"
  make_primary_fixture "$dir" >/dev/null
  fakebin=$(fm_fakebin "$TMP_ROOT/prefilter-fake")
  marker="$TMP_ROOT/prefilter-node-called"
  for tool in bash sh git dirname cat printf sed tr jq; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  cat > "$fakebin/node" <<EOF
#!/usr/bin/env bash
: > "$marker"
exit 0
EOF
  chmod +x "$fakebin/node"
  out=$(PATH="$fakebin" "$dir/bin/fm-tmux-pretool-check.sh" --command 'git status' 2>&1); rc=$?
  expect_code 0 "$rc" "prefilter must fast-allow a command with no tmux substring"
  [ -z "$out" ] || fail "prefilter fast-allow produced output: $out"
  [ ! -e "$marker" ] || fail "prefilter fast-allow still invoked the node policy owner"
  pass "tmux-guard: prefilter fast-allows (skips node) when no tmux substring is present"
}

# --- policy CLI contract ----------------------------------------------------

test_policy_cli_direct() {
  local policy
  policy="$ROOT/bin/fm-tmux-command-policy.mjs"
  [ "$(node "$policy" --command 'tmux kill-server' | cut -f1)" = deny ] \
    || fail "policy CLI must deny a bare tmux kill-server"
  [ "$(node "$policy" --command 'env -u TMUX tmux -L fm-test-1 kill-server')" = allow ] \
    || fail "policy CLI must allow an explicitly socketed kill-server"
  [ "$(node "$policy" --command 'tmux list-sessions')" = allow ] \
    || fail "policy CLI must allow a non-destructive tmux command"
  [ "$(node "$policy")" = allow ] \
    || fail "policy CLI must allow when no command is supplied"
  # --socket lets the transport name the live server, so an explicit -S that
  # merely spells out the shared socket is still denied.
  [ "$(node "$policy" --command 'tmux -S /tmp/tmux-1000/default kill-server' --socket /tmp/tmux-1000/default | cut -f1)" = deny ] \
    || fail "policy CLI must deny an -S that names the live shared socket"
  [ "$(node "$policy" --command 'tmux -S /tmp/private/sock kill-server' --socket /tmp/tmux-1000/default)" = allow ] \
    || fail "policy CLI must allow an -S that names a different socket"
  pass "tmux-guard: fm-tmux-command-policy.mjs CLI honors the deny/allow output contract"
}

# --- per-harness wiring -----------------------------------------------------

test_harness_wiring_present() {
  jq -e '[.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[].command]
         | any(test("fm-tmux-pretool-check\\.sh"))' "$ROOT/.claude/settings.json" >/dev/null \
    || fail "claude PreToolUse Bash matcher does not run the tmux-guard"
  jq -e '[.hooks.PreToolUse[].hooks[].command] | any(test("fm-tmux-pretool-check\\.sh"))' \
    "$ROOT/.codex/hooks.json" >/dev/null \
    || fail "codex PreToolUse hooks do not run the tmux-guard"
  jq -e '[.hooks.PreToolUse[].hooks[].command] | any(test("fm-tmux-pretool-check\\.sh"))' \
    "$ROOT/.grok/hooks/fm-tmux-check.json" >/dev/null \
    || fail "grok PreToolUse hook does not run the tmux-guard"
  grep -q 'fm-tmux-pretool-check.sh' "$ROOT/.opencode/plugins/fm-tmux-check.js" \
    || fail "opencode plugin does not run the tmux-guard"
  grep -q 'fm-tmux-pretool-check.sh' "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" \
    || fail "pi extension does not run the tmux-guard"
  pass "tmux-guard: wired into all five harness hook trees (claude, codex, grok, opencode, pi)"
}

test_grok_hook_variables_carry_defaults() {
  # Grok expands the raw hook command before bash -lc runs it, so every $VAR
  # must carry an inline default or the hook fails to launch at all.
  local command remaining
  command=$(jq -r '.hooks.PreToolUse[].hooks[].command' "$ROOT/.grok/hooks/fm-tmux-check.json")
  case "$command" in
    *'${GROK_WORKSPACE_ROOT:-}'*) ;;
    *) fail "grok hook must reference GROK_WORKSPACE_ROOT with an inline default" ;;
  esac
  # Delete every ${NAME:-...} / ${NAME:=...} form, then any surviving $ is a
  # reference without an inline default. Deleting first avoids the backtracking
  # a single negative pattern would be prone to.
  remaining=$(printf '%s' "$command" | sed -E 's/\$\{[A-Za-z_][A-Za-z0-9_]*:[-=][^}]*\}//g')
  case "$remaining" in
    *'$'*) fail "grok hook contains a variable reference without an inline default: $command" ;;
  esac
  pass "tmux-guard: grok hook variables all carry inline defaults"
}

test_scripts_are_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  shellcheck "$ROOT/bin/fm-tmux-pretool-check.sh" >/dev/null 2>&1 \
    || fail "bin/fm-tmux-pretool-check.sh is not shellcheck-clean"
  pass "bin/fm-tmux-pretool-check.sh is shellcheck-clean"
}

test_full_acceptance_matrix
test_deny_message_teaches_the_isolated_form
test_e2e_incident_regression
test_control_plane_kill_still_works
test_fires_in_child_worktree
test_fires_in_primary_checkout
test_inert_when_not_firstmate_repo
test_fail_open_empty_stdin
test_fail_open_unparseable_json
test_fail_open_missing_node
test_fail_open_missing_jq_on_stdin
test_prefilter_skips_node_without_tmux_substring
test_policy_cli_direct
test_harness_wiring_present
test_grok_hook_variables_carry_defaults
test_scripts_are_shellcheck_clean
