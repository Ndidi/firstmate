---
name: investigation-framing
description: >-
  Agent-only procedure for settling what question an investigation will answer, before a scout is dispatched.
  Use before scaffolding any scout brief, and when confirming an investigation's framing with the captain.
  Owns the recorded framing check, the cheap confirmation, when to escalate into a full discovery, and the discovery-scout declaration.
user-invocable: false
metadata:
  internal: true
---

# investigation-framing

A scout answers a question.
That question is almost never the captain's sentence: it is firstmate's reading of their sentence.
This skill exists because that reading was never written down or checked, and two investigations were dispatched on 2026-08-20 against questions the captain rejected the moment the answers came back.

Both had real, faithfully recorded captain input.
Neither had a requirement document, and neither had its question put back to the captain.
One of them investigated "how a newly commissioned Figma component declares its colour slots", a framing the captain had never used and did not accept: *"Why this is even a question I don't understand."*
A worker given the wrong question answers it well, and the whole investigation is wasted.

`requirement-elicitation` owns how an implementation's scope is established.
This skill owns the narrower judgement in front of an investigation, and it is the only owner of that judgement.

## The rule

**Firstmate may treat an investigation's framing as the captain's only when it can state the scout's question in the captain's own words.**

That is not a figure of speech, and it is not firstmate's to grade.
`bin/fm-scout-framing.sh` records both texts and classifies them, and `bin/fm-brief.sh` refuses `--scope-given` on a scout brief without a verdict that permits it.

The check is deliberately mechanical, and it runs on the captain's literal sentence rather than on firstmate's summary of it.
That is the whole point of the design: the previous rule failed not because it was worded badly but because firstmate assessed its own reading and found it generous.
Two independent tests must both hold, and the script's own header owns their exact definitions:

1. The captain's own words state a question at all, rather than naming a subject and an activity.
2. The question introduces no content word the captain did not use.

Either failing yields `confirm-required`.
The script can only ever demand a confirmation; it never certifies a framing on thin evidence.

## Running it

```
bin/fm-scout-framing.sh <task-id> --captain-words '<their exact request>' --question '<the one question this scout would answer>'
```

Paste the captain's request verbatim, from this session or from the durable record that carries it.
Do not tidy it, complete it, or merge two separate remarks into one quote.
A paraphrase is the one failure this check cannot detect, and it is the one thing the record makes permanently visible if you commit it.

Write the question as the single sentence you would put at the top of the brief.
If you cannot write it in one sentence, the framing is not settled, and that is itself the answer.

Read `bin/fm-scout-framing.sh --help` for flags, file-based input, the verdicts, and what the record contains.

## When the verdict is confirm-required

This is the common case, and it must stay cheap.
It is a confirmation, not a discovery.

Put the question to the captain in their own terms, in the terminal, in one or two lines - the question you would send, and what you would leave out.
Take their answer as the framing, write it to this task's `requirement.md` in `data/<task-id>/`, and scaffold the scout with `--requirement`.

Escalate into `requirement-elicitation`'s light or deep path only when their answer shows the question is not yet knowable: when the boundary depends on how the project actually works today, or when they reject the premise rather than adjust it.
Do not open a discovery on a question the captain settled in one line.

## When the verdict is captain-framed

Scaffold with `--scope-given` and dispatch.
Nothing more is owed.
The verbatim quote in the record is the evidence for that exemption, and a later reader can check it against what the captain actually said.

## Reaching Crucible

Crucible's `discover` is reachable for an investigation, not only for an implementation.
Until this skill existed an investigation never reached the elicitation at all, so it never reached Crucible either - which is exactly what the captain was asking for when they described Crucible grilling them about a feature.

When an escalated framing lands on a Crucible-managed project, take `requirement-elicitation`'s deep path, which runs Crucible's own `discover` inside the project where it can read `CONTEXT.md`, the existing specifications, and the ADR record.
That skill owns the detection rule and both paths; do not restate them here.

A discovery scout declares itself before scaffolding:

```
bin/fm-scout-framing.sh <task-id> --discovery
```

That verdict permits `--scope-given` because it commits the task to more elicitation, not less: the worker must run the discovery with the captain and write `requirement.md` beside its report.
Claiming it for an ordinary investigation buys nothing, because it produces a worker that interviews the captain.

## What this must not become

An interview in front of every task is a failure of this skill, not a cautious success.
The captain's standing warning holds: running a discovery on "fix this typo" turns a two-minute task into an interview, and they will stop tolerating it within a day.

Three things bound the cost, and all three must stay true:

- It applies to scout briefs only.
  A typo, a rename, a version bump, a bug fix with a reproduction, and a settled follow-up are all ship tasks, and none of them touch this path.
- `requirement-elicitation`'s own fire test for implementation work is unchanged.
  This skill neither widens nor narrows it.
- The `confirm-required` action is one or two lines in the terminal, not a discovery.
  Reach for a discovery only on the escalation above.

## What the check cannot do

It cannot tell a verbatim quote from a convincing paraphrase.
Nothing in a script can.
What it does guarantee is that the framing is written down, attributed, dated, and kept: the record is append-only, so a framing re-recorded until it passed stays visible in the record rather than being erased from it.
That turns a judgement nobody could inspect into a claim anyone can falsify against what the captain actually said.
