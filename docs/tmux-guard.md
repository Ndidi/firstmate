# tmux-guard PreToolUse seatbelt

This document is the authoritative human-readable contract for the tmux-guard PreToolUse seatbelt.
`bin/fm-tmux-command-policy.mjs` is the single decision owner.
`bin/fm-tmux-pretool-check.sh` is the stable harness transport and output renderer.
The tracked harness adapters forward command text without classifying it.

It is the fourth member of a family of guards that share the same cross-harness hook machinery:
the watcher-arm PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, `docs/arm-pretool-check.md`), the cd-guard (`bin/fm-cd-pretool-check.sh`, `docs/cd-guard.md`), and the turn-end supervision guard (`bin/fm-turnend-guard.sh`, `docs/turnend-guard.md`).

## Purpose and boundary

Firstmate runs the captain's session and every worker window on ONE tmux server.
A `tmux kill-server` from any agent pane therefore ends the captain's session, that agent, and every sibling worker at once.

That has actually happened.
On 2026-08-11 a worker set `TMUX_TMPDIR=$(mktemp -d)`, believed it had obtained a private server, and ended its script with `tmux kill-server`.
The isolation was a no-op, so every command in that script addressed the live shared server, and the final `kill-server` destroyed the captain's session, the worker itself, and three other working agents.
Nothing appeared in any system log, because a deliberate `kill-server` is an orderly shutdown.

The seatbelt denies exactly that class of command - a tmux command that would destroy a session, window, pane, or the server itself on the shared server - before it runs.

This guard is not a general sandbox.
It classifies shell command positions only; it never evaluates, expands, sources, or runs any byte of the submitted command.
Its threat model is agent mistakes, the same as its siblings: a worker that believes it is isolated and is not, rather than a deliberately obfuscated bypass.

## Scope: every agent, primary and worker alike

The guard binds **everyone**: firstmate's primary session and every crewmate or scout task worktree.
This is a deliberate inversion of the cd-guard, which is inert in a linked worktree because only the primary's working directory is worth protecting.
Here the worker is the threat, so there is no checkout-shape scoping at all.

`bin/fm-tmux-pretool-check.sh` confirms only that it sits in a firstmate checkout (`AGENTS.md` and `bin/` are present) and is a silent no-op (exit 0, no output) anywhere else.
Any failure to confirm the checkout is treated as inert, never as a block.

### The control plane needs no carve-out

Firstmate's own scripts legitimately run destructive tmux commands: `bin/backends/tmux.sh` kills a task window, and `bin/fm-afk-launch.sh` kills its dedicated daemon session.
Neither is affected, because **this guard is a tool-boundary check**.
It only ever sees the command string an agent submits to its shell tool.
Those scripts call tmux from inside a script process, which no PreToolUse hook observes, so their calls are outside the guard's aperture by construction rather than by an exemption that could be spoofed.

The sanctioned path for the control plane is therefore the existing one: window and session teardown runs through `bin/fm-teardown.sh` and `bin/fm-control.sh`, never a hand-typed `tmux kill-*`.
An agent that types a destructive tmux command directly is denied, primary included, and the deny message names those scripts.

`tests/fm-tmux-pretool-check.test.sh` proves both halves: the control-plane kill shapes still remove their targets and only their targets on a live private server, and the tool-boundary commands that drive those scripts are allowed.

## Block vs allow

The discriminator is **which tmux server the command addresses**, not the mere presence of the token `tmux`.

The guard **blocks** a destructive tmux command that is not proven to address an isolated server:

- `kill-server` in any form.
- `kill-session`, with or without a target.
- `kill-window` and `kill-pane`, with or without a target.

This covers the command-name prefixes tmux itself resolves and its documented aliases, any list or compound form where the command still runs (`(tmux kill-server)`, `tmux kill-server &`, `tmux kill-server | cat`, `true && tmux kill-server`, newline-separated lists, `2>/dev/null` redirection), a literal `bash -c` / `sh -c` / `zsh -c` payload one level down, leading assignments, quoted or escaped command words that cook to `tmux`, a path-qualified `/usr/bin/tmux`, and tmux's own `\;` multi-command separator.

The guard **allows** everything else, including these forms that must never attract friction:

- An explicitly named socket: `tmux -L <socket>` (any name but `default`), `-L<socket>` clustered, or `tmux -S <path>` naming a socket other than the live server's own.
- The genuinely private-tmpdir form: `env -u TMUX TMUX_TMPDIR=<dir> tmux ...`, in either word order.
- Every non-destructive tmux command: `list-sessions`, `list-windows`, `new-session`, `new-window`, `send-keys`, `capture-pane`, `display-message`, `has-session`.
- The firstmate scripts that own teardown: `bin/fm-teardown.sh`, `bin/fm-control.sh`, `bin/fm-afk-launch.sh`.
- The token as data: quoted text, a `printf` payload, a `grep` pattern, or a different program entirely (`tmuxinator`, `killall`, `pkill`, `kill`).

### Why `kill-session` and `kill-window` are denied even with an explicit target

On the shared server there is no session an agent may legitimately kill: the session hosting its own pane **is** the captain's.
Killing "its own" session takes the captain's session and every sibling worker with it.
A targeted `kill-window` is likewise indistinguishable, at classification time, from taking a sibling worker's window, and an untargeted one takes the attached client's current window or this very pane.

Denying the whole class is simpler than a target-identity test the guard cannot perform reliably, and the cost asymmetry justifies it: a false block costs one retry with `-L`, while a false allow costs the captain's session and every running worker.
The escape hatch is always available and is the same one an agent should have used anyway.

### Why `env -u TMUX` alone is NOT treated as isolation

This is the guard's most important divergence from intuition, and it is empirically grounded (see the validation record below).

Unsetting `$TMUX` removes the inherited server binding, but tmux then falls back to its **default** socket - which is exactly where the captain's server lives.
`env -u TMUX tmux kill-server` therefore still destroys the shared server.
`env -u TMUX` is necessary for isolation but not sufficient; a socket must also be named, or `TMUX_TMPDIR` must relocate the default socket into a private directory.

Accepting `env -u TMUX` on its own would have left the incident reproducible behind a twelve-character prefix that reads as safe, so the guard requires the socket.

### Accepted non-goals

Consistent with the agent-mistake threat model, the guard deliberately does not chase every obfuscated bypass:

- A destructive command inside a separate script file (`bash /tmp/repro.sh`) is not seen, because the guard classifies the submitted command, not files it would have to read and execute.
- A `tmux` word reconstructed by a command substitution, or a non-literal `bash -c "$VAR"` payload, is not resolved, because the guard never expands.
- `tmux source-file` and `tmux run-shell` payloads are not followed.

Unlike the cd-guard, malformed or untokenizable syntax **fails closed** when the raw text mentions a tmux kill, returning `unclassifiable-tmux-kill`.
The cd-guard prioritizes zero false blocks because a blocked backlog write is a correctness hazard; here a false allow destroys the fleet, so the asymmetry points the other way.

## Stable reason codes

Every deny carries one stable code in square brackets before its prose reason.

| Code | Meaning |
| --- | --- |
| `shared-tmux-kill-server` | A `kill-server` would end the tmux server hosting the captain's session, this pane, and every sibling worker. |
| `shared-tmux-kill-session` | A `kill-session` would take the captain's own session and every worker in it. |
| `shared-tmux-kill-window` | A `kill-window` or `kill-pane` would take this pane, the attached client's current window, or a sibling worker's window. |
| `unclassifiable-tmux-kill` | Unsupported or malformed shell syntax contains a tmux kill, so isolation cannot be proven. |

An ambiguous command-name prefix that could reach more than one of these reports the most severe reachable command.

### The deny message must teach the fix

A refusal that leaves the agent guessing gets worked around, and the worked-around form is the one that killed the fleet.
Every deny therefore names the isolated form (`env -u TMUX tmux -L fm-test-$$ <args>`), states that `TMUX_TMPDIR` is ignored while `$TMUX` is set, states that unsetting `$TMUX` alone falls back to the default socket, gives the pre-flight isolation check, and names the firstmate scripts that own real teardown.
`tests/fm-tmux-pretool-check.test.sh` pins those contents so the teaching cannot be dropped.

## Transport and fail-open behavior

`bin/fm-tmux-pretool-check.sh` supports all five harness-engine entry shapes used by the tracked adapters, with pi-signed sharing Pi's shape:

- Claude sends stdin JSON at `.tool_input.command` and adds `--claude` to preserve Claude's stderr-only deny requirement.
- Codex sends stdin JSON at `.tool_input.command` without `--claude`.
- Grok sends stdin JSON at `.toolInput.command`.
- OpenCode sends the exact command string through `--command <exact string>`.
- Pi and pi-signed send the exact command string through `--command <exact string>`.

Processing order is cheapest-first: a strict-superset prefilter, then the firstmate-checkout confirmation, then the Node policy owner.
The prefilter removes ordinary single quotes, double quotes, backslashes, carriage returns, and newlines before fast-allowing any command that carries no `tmux` substring and no quoting-decoder marker (`$'` ANSI-C or `$"` locale), so quoted or escaped command-word fragments delegate to the policy while most commands never pay for the Node process.
The quoting-decoder marker set is coupled to the classifier's decoder set in `bin/fm-arm-command-policy.mjs`: adding any new quote or expansion form the classifier decodes requires extending the prefilter marker set in the same change, or it stops being a strict superset.

The transport passes the live server's socket path (`${TMUX%%,*}`) to the policy as `--socket`, so an explicit `-S` that merely spells out the shared server's own socket is still denied.

Empty stdin, unparseable JSON, missing `jq` on the stdin path, missing Node, a missing policy owner, or an invalid policy response all fail open with exit 0 and no output.
A broken hook must never deny every shell tool call.
Note that this transport-level fail-open is distinct from the policy's classification-level fail-closed: a working guard refuses an unclassifiable tmux kill, while a broken guard steps aside entirely.

## Output contract

Identical in shape to `docs/cd-guard.md`:

- Allow (and inert-outside-firstmate) returns exit 0 with both streams empty.
- Deny returns exit 2 and writes `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[<code>] reason"}` to stderr.
- Default deny mode also writes `{"decision":"deny","reason":"[<code>] reason"}` to stdout for Grok.
- `--claude` suppresses stdout completely because Claude ignores a PreToolUse deny when stdout is nonempty.
- Codex blocks on exit 2 and displays stderr.
- OpenCode throws only when the checker exits 2.
- Pi and pi-signed return `{block: true}` only when the checker exits 2.

## Shared classifier ownership

`bin/fm-tmux-command-policy.mjs` imports the shell tokenizer and command-position analysis (`Lexer`, `splitProgram`, `commandPosition`) from `bin/fm-arm-command-policy.mjs`, the sole owner of firstmate's shell classification.
The tmux-guard never duplicates shell lexing; it adds only the tmux-specific decision on top of that shared classifier.
`bin/fm-arm-command-policy.mjs` runs its own CLI entry point only when invoked directly, never on import, so the policies stay independent CLIs over one parser.

Unlike the cd policy, this one does not skip a node for running in a subshell, a pipeline, or the background: none of those contain the damage, so every executed position is inspected, and subshell groups, brace groups, substitutions, and literal shell payloads are scanned recursively to a bounded depth.

## Harness wiring

| Harness | Entry | Adapter behavior on checker exit 2 |
| --- | --- | --- |
| Claude | `.claude/settings.json` PreToolUse Bash hook forwarding stdin with `--claude` | Blocks the tool call; stderr deny object, stdout empty. |
| Codex | `.codex/hooks.json` PreToolUse hook that anchors from `pwd -P`, verifies the hook-loaded firstmate root, and forwards the payload | Blocks on exit 2 and displays stderr. |
| Grok | `.grok/hooks/fm-tmux-check.json` PreToolUse hook anchored on `${GROK_WORKSPACE_ROOT:-}` | Consumes the stdout `decision=deny` object. |
| OpenCode | `.opencode/plugins/fm-tmux-check.js` `tool.execute.before` | Throws, which surfaces as the failed tool result. |
| Pi | `.pi/extensions/fm-primary-turnend-guard.ts` `tool_call` handler | Returns `{block: true}`; piggybacks on the already-loaded primary extension so no extra `-e` flag is needed. |

Each harness runs the tmux-guard alongside the watcher-arm and cd seatbelts; the three are independent checks, and any deny blocks the command.
Every shell variable reference in the Grok hook command carries an inline default (`${GROK_WORKSPACE_ROOT:-}`) because Grok expands the raw hook command before `bash -lc` runs it, the same requirement documented in `docs/arm-pretool-check.md`.

### Known residual gaps

These are named rather than silently accepted, and none of them is a regression: they are the existing reach of this repo's hook wiring.

- **Worker coverage depends on the harness loading this repo's hook config.**
  Claude (`.claude/settings.json`) and OpenCode (`.opencode/plugins/`) load project configuration from the worktree automatically, so a firstmate-repo worker on those harnesses is covered.
  Codex and Grok gate project hooks behind folder trust, which `bin/fm-spawn.sh` does not establish for a worker pane.
  A Pi worker loads only the per-task extension `bin/fm-spawn.sh` generates (`state/<task-id>.pi-ext.ts`), not `.pi/extensions/fm-primary-turnend-guard.ts`, so it currently receives none of the three PreToolUse seatbelts - a pre-existing gap that predates this guard and applies equally to the watcher-arm and cd guards.
- **`kimi` and `muse` have no PreToolUse hook mechanism configured in this repo at all**, so they carry none of the four guards.
- **Workers on a project clone load that project's configuration, not firstmate's**, so the guard does not reach them.
  The incident worker was a firstmate-repo worker, which is covered.

Closing the Pi per-task and trust-gated paths means changing `bin/fm-spawn.sh` launch plumbing and belongs in follow-up work.

## Automated validation

`tests/fm-tmux-pretool-check.test.sh` owns the acceptance matrix.
Every block and allow case runs through Codex-shaped stdin, Claude-shaped stdin, Grok-shaped stdin, OpenCode-shaped CLI, and Pi-shaped CLI entry forms.
The suite also proves the end-to-end incident regression, the control-plane calls still working, the scoping (fires in a crewmate/scout linked worktree and in the primary, inert outside a firstmate checkout), the deny message's teaching content, the fail-open transport behavior, the prefilter fast path, the policy CLI output contract, and the per-harness wiring.

The incident regression is a real reproduction, not a fixture assertion.
It stands up a throwaway tmux server on a private socket as a stand-in for the captain's, confirms that a pane on that server inherits a `$TMUX` pointing at the private socket before anything destructive runs, then executes the incident's script byte for byte inside that pane and asserts the stand-in server died - proving `TMUX_TMPDIR` was a no-op - before asserting that the guard denies the exact same command text.
The test refuses to run its destructive fixture at all if the pre-flight socket check does not match.

Run:

```sh
bash -n bin/fm-tmux-pretool-check.sh
shellcheck bin/fm-tmux-pretool-check.sh tests/fm-tmux-pretool-check.test.sh
node --check bin/fm-tmux-command-policy.mjs
node --check bin/fm-arm-command-policy.mjs
tests/fm-tmux-pretool-check.test.sh
tests/fm-turnend-guard.test.sh
```

`tests/fm-turnend-guard.test.sh` is listed because it owns the cross-cutting assertion that every tracked `.claude/settings.json` entry runs under native Claude and stays inert under Grok, which this guard's entry must satisfy.

## Empirical record, 2026-08-11 (tmux 3.7b, Linux)

These facts are what the classifier's shape rests on, and each was measured on an isolated server (`env -u TMUX tmux -L fm-test-$$ ...`) or through a read-only listing.

- **`$TMUX` overrides `TMUX_TMPDIR`.** With `$TMUX` set, `TMUX_TMPDIR=/tmp/claude-1000/privtest tmux list-sessions` returned the captain's `firstmate: 3 windows (attached)`, not an empty private server. This is the incident's root cause, reproduced read-only.
- **`env -u TMUX` alone is not isolation.** `env -u TMUX tmux list-sessions` also returned `firstmate: 3 windows (attached)`, because tmux falls back to the default socket, which is where that server lives.
- **`env -u TMUX` plus `TMUX_TMPDIR` is genuine isolation.** `env -u TMUX TMUX_TMPDIR=/tmp/claude-1000/privtest tmux new-session -d -s priv` created a server whose socket was `<TMUX_TMPDIR>/tmux-1000/default`, separate from the captain's.
- **tmux resolves unambiguous command-name prefixes.** `tmux kill-serv` exited 0 and ended the server. `tmux kill-w` and `tmux kill-p` resolved to `kill-window` and `kill-pane`. `tmux k`, `tmux kill`, and `tmux kill-s` were rejected as ambiguous, which is why over-approximating the ambiguous prefixes costs nothing.
- **The destructive alias set is exactly `killp` and `killw`.** `tmux list-commands -F '#{command_list_name} | #{command_list_alias}'` shows `kill-pane | killp`, `kill-window | killw`, and no alias for `kill-server` or `kill-session`.
- **Every tmux command name beginning with `k` is a kill command.** Filtering the full 169-name command and alias list for `^k` yields only the four `kill-*` names plus `killp` and `killw`, so treating "is a prefix of a destructive name" as destructive cannot catch a benign command.

Refresh this record after a tmux major-version upgrade; the alias set and prefix-resolution behavior are the parts most likely to move.

## Live per-harness validation

Not yet run.
The cross-harness entry shapes are covered by `tests/fm-tmux-pretool-check.test.sh`, and the Claude entry's grok-inertness and native-Claude liveness are covered by `tests/fm-turnend-guard.test.sh`, but no harness has been launched against this guard.
Live validation follows the procedure and launch commands in `docs/cd-guard.md` "Live validation record", substituting a top-level `tmux kill-server` (must be denied) and `env -u TMUX tmux -L fm-test-$$ kill-server` against a throwaway private server (must run) as the probe pair.
