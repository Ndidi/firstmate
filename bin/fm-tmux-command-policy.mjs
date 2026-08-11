#!/usr/bin/env node
// Semantic policy for the tmux-guard: would a shell command destroy a tmux
// session, window, or pane on the SHARED server the captain and the whole fleet
// live on?
//
// Firstmate runs the captain's session and every worker window on one tmux
// server. A worker that runs `tmux kill-server` there destroys the captain's
// session, its own pane, and every sibling worker at once, and leaves no trace
// in any system log because a deliberate kill-server is an orderly shutdown.
// This policy blocks exactly that class of command at the tool boundary; the
// harness plumbing lives in the bin/fm-tmux-pretool-check.sh transport, not
// here. See docs/tmux-guard.md for the full contract.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification, so this guard never duplicates shell lexing. This policy
// never evaluates, expands, sources, or runs any byte of the submitted command;
// it inspects lexical command positions only.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import path from "node:path";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

// The one fix every deny must teach. A refusal that leaves the agent guessing
// gets worked around, and the worked-around form is the one that killed the
// fleet: TMUX_TMPDIR looks like isolation and is not.
const REMEDY =
  "Run tmux work on an isolated server instead: `env -u TMUX tmux -L fm-test-$$ <args>`, tearing it down with `env -u TMUX tmux -L fm-test-$$ kill-server`. " +
  "Setting TMUX_TMPDIR alone is NOT isolation: a tmux client reads its socket path out of $TMUX, which overrides TMUX_TMPDIR completely, so while $TMUX is set every command still addresses the captain's shared server. " +
  "Unsetting $TMUX alone is NOT isolation either: tmux then falls back to the DEFAULT socket, which is where the captain's server already lives - you must also name a socket with -L or -S. " +
  "Prove isolation before experimenting: `env -u TMUX tmux -L fm-test-$$ list-sessions` must not list the firstmate session. " +
  "Firstmate's own window and session teardown runs through bin/fm-teardown.sh and bin/fm-control.sh, never a hand-typed tmux kill.";

const REASONS = {
  "shared-tmux-kill-server":
    `tmux kill-server on the shared server is blocked; it would end the tmux server that hosts the captain's session, this pane, and every sibling worker. ${REMEDY}`,
  "shared-tmux-kill-session":
    `tmux kill-session on the shared server is blocked; the session hosting this pane is the captain's own, so killing it takes the captain's session and every sibling worker with it. ${REMEDY}`,
  "shared-tmux-kill-window":
    `tmux kill-window/kill-pane on the shared server is blocked; with no target it takes this pane or the attached client's current window, and with a target it can take a sibling worker's window. ${REMEDY}`,
  "unclassifiable-tmux-kill":
    `unsupported or malformed shell syntax contains a tmux kill command, so this guard cannot prove it addresses an isolated server. ${REMEDY}`,
};

// Every tmux command name that destroys a session, window, pane, or the server,
// including tmux's own documented aliases (killp, killw; kill-server and
// kill-session have none). Verified against tmux 3.7b `list-commands`.
const DESTRUCTIVE_COMMANDS = ["kill-server", "kill-session", "kill-window", "kill-pane", "killp", "killw"];

// tmux global options, from `tmux -h` on 3.7b:
//   tmux [-2CDhlNuVv] [-c shell-command] [-f file] [-L socket-name]
//        [-S socket-path] [-T features] [command [flags]]
const TMUX_FLAGS_NO_ARGUMENT = new Set(["2", "C", "D", "h", "l", "N", "u", "V", "v"]);
const TMUX_FLAGS_WITH_ARGUMENT = new Set(["c", "f", "L", "S", "T"]);

// tmux's own default socket name. `-L default` names the very server this guard
// is protecting, so it is explicitly NOT an isolated socket.
const DEFAULT_SOCKET_NAME = "default";

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function deny(code) {
  return { decision: "deny", code, reason: REASONS[code] };
}

// tmux resolves any UNAMBIGUOUS prefix of a command name, so `tmux kill-serv`
// ends the server just as `tmux kill-server` does (verified on 3.7b). Treat a
// word as destructive when it is a prefix of any destructive name. This
// deliberately over-approximates the ambiguous prefixes (`k`, `kill`,
// `kill-s`), which costs nothing: tmux rejects those outright, so a command
// this guard blocks was never going to run in the first place. The
// over-approximation is safe in the other direction too - every tmux command
// name beginning with `k` is a kill command, so no benign command can be caught
// by it.
function destructiveCategory(word) {
  if (!word) return "";
  const matches = DESTRUCTIVE_COMMANDS.filter((name) => name.startsWith(word));
  if (matches.length === 0) return "";
  // Report the most severe reachable command when a prefix is ambiguous.
  if (matches.includes("kill-server")) return "shared-tmux-kill-server";
  if (matches.includes("kill-session")) return "shared-tmux-kill-session";
  return "shared-tmux-kill-window";
}

// Walk tmux's own global options to find where its subcommand begins, and
// capture any explicit socket selection on the way.
function parseTmuxGlobalOptions(words, start) {
  let index = start;
  let socketName = null;
  let socketPath = null;
  let unresolved = false;

  while (index < words.length) {
    const value = words[index].value;
    if (value === "--") {
      index += 1;
      break;
    }
    if (!value.startsWith("-") || value === "-") break;

    let consumedArgument = false;
    for (let offset = 1; offset < value.length; offset += 1) {
      const flag = value[offset];
      if (TMUX_FLAGS_NO_ARGUMENT.has(flag)) continue;
      if (!TMUX_FLAGS_WITH_ARGUMENT.has(flag)) {
        unresolved = true;
        break;
      }
      let argument;
      if (offset + 1 < value.length) {
        argument = value.slice(offset + 1);
        index += 1;
      } else {
        if (!words[index + 1]) {
          unresolved = true;
          break;
        }
        argument = words[index + 1].value;
        index += 2;
      }
      if (flag === "L") socketName = argument;
      if (flag === "S") socketPath = argument;
      consumedArgument = true;
      break;
    }
    if (unresolved) break;
    if (!consumedArgument) index += 1;
  }

  return { index, socketName, socketPath, unresolved };
}

// tmux accepts several commands in one invocation, separated by a literal `;`
// argument (`tmux new-session -d \; kill-server`). Only the first word of each
// such slot is a command name.
function destructiveCategoriesIn(words, start) {
  const categories = [];
  let expectCommandName = true;
  for (let index = start; index < words.length; index += 1) {
    const value = words[index].value;
    if (value === ";") {
      expectCommandName = true;
      continue;
    }
    if (!expectCommandName) continue;
    expectCommandName = false;
    const category = destructiveCategory(value);
    if (category) categories.push(category);
  }
  return categories;
}

// `env -u TMUX` / `env --unset TMUX`, in any of the spellings env accepts.
function unsetsTmuxVariable(position) {
  const prefix = position.words.slice(0, position.index);
  for (let index = 0; index < prefix.length; index += 1) {
    const value = prefix[index].value;
    if (value === "--unset=TMUX") return true;
    if ((value === "--unset" || /^-[A-Za-z]*u$/.test(value)) && prefix[index + 1]?.value === "TMUX") return true;
    if (/^-[A-Za-z]*uTMUX$/.test(value)) return true;
  }
  return false;
}

// A non-empty TMUX_TMPDIR assignment anywhere in this command's prefix, whether
// written as a shell assignment (`TMUX_TMPDIR=x env ...`) or handed to env
// itself (`env -u TMUX TMUX_TMPDIR=x tmux ...`).
function setsPrivateTmpdir(position) {
  return position.words
    .slice(0, position.index)
    .some((word) => /^TMUX_TMPDIR=./.test(word.value));
}

// Does this invocation provably address a server other than the shared one?
//
// Only an explicitly named socket proves it, because socket selection is the
// single thing that decides which server a tmux client talks to. The one
// exception is the genuinely private-tmpdir form: with $TMUX unset AND
// TMUX_TMPDIR pointing somewhere private, tmux's default socket resolves under
// that private directory instead (verified on tmux 3.7b).
function addressesIsolatedServer(position, invocation, liveSocketPath) {
  if (invocation.socketPath !== null) {
    if (!invocation.socketPath) return false;
    if (liveSocketPath && path.normalize(invocation.socketPath) === path.normalize(liveSocketPath)) return false;
    return true;
  }
  if (invocation.socketName !== null) {
    return Boolean(invocation.socketName) && invocation.socketName !== DEFAULT_SOCKET_NAME;
  }
  return unsetsTmuxVariable(position) && setsPrivateTmpdir(position);
}

function rawMentionsTmuxKill(source) {
  return /(?:^|[/\s'"`($;&|])tmux\b/.test(source) && /kill/.test(source);
}

// Literal `sh -c` / `bash -c` / `zsh -c` payloads, so a kill one level down is
// still seen. A non-literal payload (one carrying an expansion or a
// substitution) is left alone: this guard classifies, it never expands.
function shellCommandPayload(position) {
  if (!position.command) return null;
  if (!["sh", "bash", "zsh"].includes(basename(position.command.value))) return null;
  const words = position.words;
  for (let index = position.index + 1; index < words.length; index += 1) {
    if (!/^-[A-Za-z]*c[A-Za-z]*$/.test(words[index].value)) continue;
    let payloadIndex = index + 1;
    if (words[payloadIndex]?.value === "--") payloadIndex += 1;
    const payload = words[payloadIndex];
    if (!payload || !payload.literal || payload.subs.length > 0) return null;
    return payload.value;
  }
  return null;
}

function evalCommandPayload(position) {
  if (!position.command || basename(position.command.value) !== "eval") return null;
  const payloads = position.words.slice(position.index + 1);
  if (payloads.length === 0) return null;
  if (payloads.some((payload) => !payload.literal || payload.subs.length > 0)) return null;
  return payloads.map((payload) => payload.value).join(" ");
}

// Unlike the sibling cd-guard, this scan never skips a node for running in a
// subshell, a pipeline, or the background: none of those contain the damage.
// `(tmux kill-server)` and `tmux kill-server &` end the shared server exactly
// as the bare form does, so every executed position is inspected.
function scanProgram(source, liveSocketPath, depth = 0) {
  if (depth > 8) return rawMentionsTmuxKill(source) ? "unclassifiable-tmux-kill" : "";

  const lexed = new Lexer(source).tokenize();
  if (lexed.error) {
    // Fail CLOSED on syntax this classifier cannot tokenize, but only when the
    // raw text looks like a tmux kill. The sibling cd-guard fails open because a
    // false block there costs a wrong-directory write; here a false ALLOW costs
    // the captain's session and every running worker, so an unclassifiable
    // command that mentions a tmux kill is refused rather than waved through.
    return rawMentionsTmuxKill(source) ? "unclassifiable-tmux-kill" : "";
  }

  const { nodes } = splitProgram(lexed.tokens);
  for (const tokens of nodes) {
    const position = commandPosition(tokens);

    // Recurse into every nested program this node carries: subshell and brace
    // groups, command and process substitutions, and literal shell payloads.
    for (const token of tokens) {
      if (token.type === "group") {
        const nested = scanProgram(token.content, liveSocketPath, depth + 1);
        if (nested) return nested;
      }
      if (token.type === "word") {
        for (const substitution of token.subs) {
          const nested = scanProgram(substitution.content, liveSocketPath, depth + 1);
          if (nested) return nested;
        }
      }
    }
    for (const payload of [shellCommandPayload(position), evalCommandPayload(position)]) {
      if (payload === null) continue;
      const nested = scanProgram(payload, liveSocketPath, depth + 1);
      if (nested) return nested;
    }

    if (!position.command) continue;
    if (basename(position.command.value) !== "tmux") continue;

    const invocation = parseTmuxGlobalOptions(position.words, position.index + 1);
    const categories = destructiveCategoriesIn(position.words, invocation.index);
    if (categories.length === 0) continue;
    // An option this classifier cannot account for may itself be `-L`, so the
    // invocation is no longer provably isolated.
    if (invocation.unresolved) return "unclassifiable-tmux-kill";
    if (addressesIsolatedServer(position, invocation, liveSocketPath)) continue;
    return categories[0];
  }

  return "";
}

function decision(command, liveSocketPath = "") {
  const code = scanProgram(command, liveSocketPath);
  return code ? deny(code) : { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false, socket: "" };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command" || name === "--socket") {
      if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
      if (name === "--command") {
        result.command = argv[i + 1];
        result.commandSet = true;
      } else {
        result.socket = argv[i + 1];
      }
      i += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    if (name.startsWith("--socket=")) {
      result.socket = name.slice("--socket=".length);
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command, args.socket);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
