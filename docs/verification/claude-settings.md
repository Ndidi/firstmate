# Verification: claude hook settings load from outside the worktree

Active empirical evidence that firstmate can deliver a claude crewmate's per-task lifecycle hooks from a path outside the task worktree.
[`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts and [`bin/fm-spawn.sh`](../../bin/fm-spawn.sh) owns the mechanics; this record owns how those facts were established.

## Subject

| Field | Value |
|---|---|
| Version | `2.1.235 (Claude Code)` |
| Verified | 2026-08-19 |
| Platform | Linux x86_64 (6.8.0-137-generic) |

## Why the location matters

A project may version its own pre-approved tool permissions by tracking `.claude/settings.local.json`.
Firstmate used to write its hooks to that exact path inside the task worktree, which replaced a tracked file no worker authored.
The guarantee below is what lets firstmate keep its hooks entirely out of a project's files.

## All four hook events fire from a `--settings` path

The lab is a git repo that tracks `.claude/settings.local.json`, plus a hooks file outside it whose four commands each touch a distinct marker.

```
$ claude --version
2.1.235 (Claude Code)

$ claude --settings "$LAB/fm.json" --dangerously-skip-permissions -p "Reply with exactly: OK" < /dev/null
Ignoring 1 permissions.allow entry from .claude/settings.local.json: this workspace has not been trusted. Run Claude Code interactively here once and accept the trust dialog, or set projects["<lab>"].hasTrustDialogAccepted: true in /home/ndidi/.claude.json.
OK

$ ls submit stop stopfail sessionend
ls: cannot access 'stopfail': No such file or directory
sessionend
stop
submit
```

`UserPromptSubmit`, `Stop`, and `SessionEnd` all fired.
`StopFailure` correctly did not fire on a turn that succeeded, and its presence in the same document did not cause the file to be rejected, which matters because a settings file that fails validation is silently ignored under `--dangerously-skip-permissions`.

## The hooks outrank the workspace trust gate

The warning line above is the load-bearing part: this workspace was untrusted, so claude dropped the project's own `permissions.allow` entry, yet every `--settings` hook still fired.
Hooks supplied on the command line are therefore not subject to the project trust dialog that a worktree-resident settings file sits behind.
The external path is more reliable than the one it replaced, not merely safer for the project.

## The tracked project file is untouched

```
$ git status --porcelain .claude/
(no output)

sha before=461e08d8ad692132accdbb7e30a75233851f8c55 after=461e08d8ad692132accdbb7e30a75233851f8c55
```

## A missing settings path is a hard startup error

```
$ claude --settings "$LAB/does-not-exist.json" --dangerously-skip-permissions -p "Reply with exactly: OK" < /dev/null
Error: Settings file not found: <lab>/does-not-exist.json
```

Claude refuses to start rather than continuing without the file.
This is why `bin/fm-spawn.sh` passes `--settings` only when it actually wrote the file: a secondmate launch arms no busy wiring, so an unconditional flag would break every claude secondmate.

## Refreshing this record

Re-run the commands above after a Claude Code upgrade.
The portable regression that pins firstmate's side of this, with no live harness, is `test_claude_never_writes_into_a_tracked_project_settings_file` in [`tests/fm-busy-adapter-wiring.test.sh`](../../tests/fm-busy-adapter-wiring.test.sh).
