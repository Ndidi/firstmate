import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

// PreToolUse seatbelt for OpenCode: block a tmux command that would destroy a
// session, window, or pane on the shared tmux server the captain and the whole
// fleet live on (see bin/fm-tmux-pretool-check.sh and docs/tmux-guard.md).
// This mirrors fm-primary-cd-check.js, calling the tmux-guard owner instead of
// the cd one. tool.execute.before can block by throwing (verified 2026-07-09
// against OpenCode 1.17.15 for the watcher-arm plugin; the same mechanism
// carries this guard).
//
// Deliberately UNLIKE the cd-guard: the owner script here is NOT inert in a
// crewmate/scout task worktree, because a worker is exactly the agent this
// guard exists to bind. It stays inert outside a firstmate checkout.

function runProcess(command, args) {
  return new Promise((resolvePromise) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolvePromise({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolvePromise({ code: code ?? 0, stdout, stderr }));
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

export const FmTmuxCheck = async ({ directory, worktree }) => {
  const root = worktree ? (() => {
    try {
      return realpathSync(worktree);
    } catch {
      return resolve(worktree);
    }
  })() : await resolveRoot(directory);

  return {
    "tool.execute.before": async (input, output) => {
      if (!root || input?.tool !== "bash") return;
      const command = output?.args?.command;
      if (!command || typeof command !== "string") return;

      const result = await runProcess(`${root}/bin/fm-tmux-pretool-check.sh`, ["--command", command]);
      if (result.code !== 2) return;

      const reason = result.stderr.trim() || "denied by the tmux-guard PreToolUse seatbelt";
      throw new Error(reason);
    },
  };
};
