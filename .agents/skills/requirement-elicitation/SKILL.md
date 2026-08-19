---
name: requirement-elicitation
description: >-
  Agent-only procedure for establishing a task's scope with the captain before any brief is written.
  Use before writing a brief for work the captain described in a sentence or two, where the acceptance criteria, constraints, and scope would otherwise come from firstmate's own inference.
  Owns the fire and do-not-fire test, the light and deep discovery paths, the requirement document's location and shape, and how it reaches the worker.
user-invocable: false
metadata:
  internal: true
---

# requirement-elicitation

This skill is the single owner of how a task's scope is established before dispatch.
The captain ruled it on 2026-08-18 after weeks of briefs whose acceptance criteria firstmate had invented: firstmate "does absolutely nothing to help clarify the nature of the task that I want."

Crucible is the captain's own process system and its skills are already reachable from every firstmate session through `~/.claude/skills`.
`discover` and `plan` are the two used here.
Nothing needs installing, and Crucible's `discover` already accepts a caller-named destination, so it writes where firstmate tells it to.

## The test: does this fire?

Fire when **all** of these hold:

- The captain described the work in a sentence or two.
- The deliverable is a change to a project, not an answer to a question.
- Writing the brief would mean inventing the acceptance criteria, the constraints, or the boundary of what is in scope.

Do not fire for any of these, and this list wins on a tie:

- A request that already carries its own scope, however briefly stated.
- A bug fix. Load `diagnostic-reasoning` instead; a reproduction is the scope.
- A mechanical change: a rename, a typo, a version bump, a config value, a move.
- A follow-up that inherits a settled context from work already under way or just finished.
- Anything the captain has already specified, in this session or in a durable record.
- An investigation or audit the captain asked for directly, where the question they asked is the scope.

**Err toward not firing.**
A brief written from a clear request is fine.
An unnecessary interview is not: running a discovery on "fix this typo" turns a two-minute task into an interview, and the captain will stop tolerating it within a day.
When the call is genuinely close, ask the captain one plain question naming what you would otherwise guess, and take their answer as the scope rather than opening a discovery.

## Choosing light or deep

Both paths produce the same artifact at the same location.
They differ in who runs the elicitation and whether the code is present while it runs.

**Light** is the default.
Firstmate runs the elicitation itself at intake, in the current session.
It is cheap, needs no round trip, and is right for most work.
Its ceiling is real and worth knowing: firstmate reads projects but never works inside them, so a light discovery cannot ground its questions in the code the way a worker sitting in the worktree can.

Choose **deep** when any of these hold:

- The requirement depends on how the project actually works today, and firstmate would be guessing at the existing behavior rather than at the captain's intent.
- The work spans a subsystem large enough that the affected surface has to be found before it can be scoped.
- The project is Crucible-managed, so Crucible's own gates fire inside it and `discover` can reach `CONTEXT.md`, existing specifications, and the ADR record.

A project is Crucible-managed when its repository root carries the `<!-- crucible-project -->` marker in a regular (not symlinked) `CLAUDE.md`, or a `.out-of-scope/` or `docs/agents/` directory.
`~/.claude/hooks/crucible-project-detect.sh` is the authoritative detector and the same one Crucible's own hooks use.
Firstmate's own repo is not Crucible-managed: its `CLAUDE.md` is a symlink to `AGENTS.md`, which that detector deliberately excludes.

Cost is a tiebreaker, not the decision.
A deep discovery spends a worker and a round trip; a wrong requirement spends the whole implementation.

## Light path

Firstmate runs this in its own session, at intake, before writing the brief.

1. Invoke Crucible's `discover` skill, naming the destination explicitly: the document location for this run is the task's own `data/<task-id>/` directory, and the file is `requirement.md`.
   Naming it is mandatory. Crucible's unqualified default is `backlog/docs/` inside the project, which firstmate must never write to, and its default filename convention does not apply once firstmate has named the file.
2. Follow `discover` as written.
   Its batched question sets are exactly the case the captain's own surface rule already covers, so they go to a Lavish page; a lone yes-or-no that falls out of the run stays in the terminal.
   Do not interview the captain one question at a time.
3. Stop at the specification. `discover`'s later phases assume a project it can write into.
4. Write the result to `data/<task-id>/requirement.md`.

## Deep path

The deep path is an ordinary scout followed by an ordinary promotion.
It introduces no second dispatch mechanism, and every existing safety boundary applies to it unchanged.

1. Dispatch a scout against the project in the normal way, per `AGENTS.md` section 7.
   Scaffold its brief with `bin/fm-brief.sh <task-id> <repo> --scout --scope-given`: the scout's own scope is the discovery itself, which the captain's request already settles.
2. The scout's task text instructs it to run Crucible's `discover` and then `plan` inside its worktree, and to write the requirement to `data/<task-id>/requirement.md` rather than into the project.
   The scout still owes its report at `data/<task-id>/report.md`; the requirement document is a second artifact beside it, not a replacement.
3. The scout reaches the captain the way every scout does, through firstmate.
   Crewmates never address the captain, so the scout's questions come back as `needs-decision` and firstmate carries them, exactly as for any other worker.
4. When the captain authorizes implementation, promote the same scout in place with `bin/fm-promote.sh` rather than creating a duplicate task.
   The promoted worker keeps its window, its worktree, and the context it just built.
   Name the requirement document's absolute path in the ship instructions you steer to it, because promotion sends instructions rather than scaffolding a second brief.

## The requirement document

Location: `data/<task-id>/requirement.md`, beside the brief and the report that task already owns.
It is captain-private and gitignored with the rest of `data/`, and it survives the worktree.

It is the record the work is judged against, so it must stand on its own: the problem in the captain's terms, the acceptance criteria, the constraints, and what is explicitly out of scope.
Out of scope is not optional.
It is the half that stops a worker from helpfully widening the job.

## Reaching the worker

Pass the document to the scaffold: `bin/fm-brief.sh <task-id> <repo> --mode <mode> --requirement data/<task-id>/requirement.md`.
The generated brief then carries a `# Requirement` section pointing the worker at the file, and tells it to raise a conflict rather than choose when the document and the task text disagree.

`bin/fm-brief.sh` refuses to scaffold without one of `--requirement` or `--scope-given`, the same way it refuses to guess `--mode`.
`--scope-given` is the not-firing case above, declared rather than assumed.
Reach for it freely when the test at the top says not to fire; that is what it is for.
Do not reach for it to skip an elicitation the test says is due, because the whole cost of a thin brief lands on the worker and then on the captain reviewing what the worker built.

`bin/fm-spawn.sh` separately refuses to launch a brief whose task text is still the unfilled `{TASK}` placeholder.

This step changes the brief, not the worker.
Crewmates never read `data/captain.md` and are never told to run an elicitation of their own on a ship task; the scope arrives already settled, in their instructions.
