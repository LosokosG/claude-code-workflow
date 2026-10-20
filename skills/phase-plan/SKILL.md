---
name: phase-plan
description: Use when an opened change (work/changes/<id>/change.md exists) needs its plan.md — "plan this change", "write the plan", "break this into phases", or /prep reaching its plan stage. Writes a short, delta-shaped plan with one Progress row per phase that /plan-review can check and /drive can execute. Not for Q-lane work (that is /quick).
argument-hint: "<change-id> [--lane S|F]"
allowed-tools:
  - Read
  - Grep
  - Glob
  - Edit
  - Write
  - Bash
  - AskUserQuestion
---

# phase-plan

A plan here is the **delta**: what will be different, in which order, and how each step
proves it worked. It does not describe the system, it is not a design document, and it
does not re-explain what the code already shows. The engine reads it, so its shape is a
contract (see `references/progress-format.md`).

**The size cap is part of the contract.** `lane: S` → at most 250 lines; `lane: F` → at
most 400. `scripts/check-plan-progress.mjs` warns past the cap, and the warning means
*cut*. A plan that will not fit needs fewer phases, or depth moved into
`implementation-notes/p<n>.md`, which only the phase that owns it reads.

**Q-lane work gets no plan.** If the ask touches none of the project's reserved surfaces
and looks like roughly 300 changed lines or less, say so in one line and route to
`/quick`. Do not create a change folder for it.

## What to read — and where to stop

`/phase-plan <change-id>` works in `work/changes/<change-id>/`. Read these, in order, and
nothing more:

1. `change.md`. Its `lane:` picks the cap. If it is missing, derive it (reserved surface
   first, size second) and write it in.
2. The `## Open decisions` list in `change.md`, and `research/synthesis.md` if a research
   wave ran. Research only exists for a named open decision; anything else is decided
   inside the phase that meets it, and that phase's `Done when:` says how it was checked.
3. The files this change will actually touch. Targeted reads, not a survey.
4. The project's lessons — `.claude/rules/lessons-*.md` that match those files. Any lesson
   in reach of this change becomes a line in `## Hard guarantees`.

A change folder under `work/archive/` is refused: archived work is not re-planned.

## One round of questions

Before writing, ask **one** batched `AskUserQuestion` with **at most four** questions,
recommended answer first and labelled.

Ask only what changes the plan's shape and cannot be settled from what you read: a fork in
the architecture, where the scope ends, a trade-off that costs something either way. Do
not ask the user to re-confirm settled points, to rate complexity, or to approve a phase
list — the plan is the proposal, and they will read it.

Everything you did not ask about, **decide**, and write it in the Decisions table with the
reason. A default you chose is still a decision; leaving it unrecorded is the failure.

## The file

Write `work/changes/<change-id>/plan.md` with these sections in this order. None is
optional.

```markdown
# <change-id> — plan

Lane: <S|F> (<why: which reserved surface, or the size>). <How it runs: /drive, or by hand one phase at a time.>

## Decisions

| #   | Question (3–6 words)  | Choice and why                    |
| --- | --------------------- | --------------------------------- |
| D1  | …                     | …                                 |

## Out of scope

<What a reader would reasonably expect here and will not get — each with where it went:
a follow-up change, a later phase, or "not doing".>

## Hard guarantees

<Project rules this change could break, one line each, copied from CLAUDE.md, the
matching `.claude/rules/` files and lessons (cite the lesson id). Only the ones in reach.
Reviewers hold every phase to these.>

## Phases

### P1 — <title>

Changes: <the delta — files, behavior, contracts that end up different>
Done when: <a check that could fail: the command or observation, plus a negative control
where a guard is involved>
route: implement | tdd          (omit for implement)
risk: none | <tag>[, <tag>]     (the reserved surfaces this phase touches)
paths: <the paths this phase is declared to touch>
size: <expected changed lines>  (optional; default 300)
notes: implementation-notes/p1.md   (only when the phase needs more than ~15 lines of depth)

## Progress

| Phase      | Status | Notes |
| ---------- | ------ | ----- |
| P1 <title> | [ ]    |       |

## Drive Readiness

<At most 8 lines: phase order and dependencies; anything that must exist before P1 runs
(env var, seed data, credential), named; which phases have a manual gate; how to roll back
each phase.>
parallel-safe: yes | no | unknown

## Open risks

- <one line each: what could still go wrong and what the plan does about it>
```

## Writing the fields

- **`Changes:` states a difference.** "Add `lane:` to change.md and fill it for the
  three open changes" — not a paragraph about what change.md is for.
- **`Done when:` has to be able to fail.** "Tests pass" is not enough; name the command,
  and say what a failure would look like. Something only a human can judge is still a
  criterion — that row will end up `[~]` until they do it.
- **Guards get a negative control.** When the phase adds a check (an access rule, a
  validation, a lint), `Done when:` names the deliberate violation that must turn it red,
  and says it is reverted afterwards.
- **Test count is a ceiling.** The tests a row names are the most it needs, not a minimum
  to exceed.
- **`risk:`** lists the project's reserved-surface tags the phase touches, or `none`.
  A tagged phase gets both review lenses; `none` gets one pass, and only when its diff
  grows past twice its `size:` or leaves its `paths:`. Guessing low is how a sensitive
  change ships with a light review.
- **`paths:`** is the declared scope, and the engine diffs against it. A file outside it
  is not forbidden; it is *undeclared*, and the fix is declare-with-a-reason or revert.
  Keep the list honest, not wide.

## How many phases

One phase = one commit = one reviewable diff. Split when a phase would need two unrelated
families of `Done when:` checks, or when its second half depends on a human looking at the
first. Do not split to look thorough. A phase whose whole content is "run the tests" or
"update the docs" is not a phase — it is a `Done when:` line on the phase that caused it.

## Progress statuses

- `[ ]` — not started.
- `[x]` — landed **and** verified. Notes: `<date> · <what shipped or deviated, one clause>`.
- `[~]` — landed with something still owed. Notes: `deferred: <category> — <why>`, where
  the category is `human-judgment`, `env-blocked` or `out-of-lane`. Anything else is not a
  deferral and the row stays `[ ]`.

A manual check nobody performed is never `[x]`. The commit subject's `(<change-id> p<n>)`
suffix is the link from code back to its phase; nothing writes SHAs into the plan body.

## Before handing it over

1. `node scripts/check-plan-progress.mjs work/changes/<change-id>/plan.md` — no blocking
   findings. Pass `--risk-tags` if the project keeps a tag list.
2. `wc -l` against the lane cap.
3. Every phase has `Changes:`, `Done when:`, `risk:` and `paths:`.
4. Every open decision from `change.md` is a Decisions row or the explicit subject of a
   phase.
5. `change.md`: `status: planned`, `updated: <today>`.

Then print:

```
Plan — <change-id>: lane <S|F> · <n> phases · <k> lines (cap <cap>)
Decisions: <n> · Open risks: <n>
Next: /plan-review <change-id>   (in a fresh window)
```
