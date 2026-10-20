---
name: implement-phase
description: Use to build exactly one phase of a reviewed plan in work/changes/<id>/plan.md and land it as one commit with its Progress row flipped — "implement phase 2", "do the next phase", or a drive step. The test-first variant is /tdd-phase. Not for unplanned work (that is /quick).
argument-hint: "<change-id> phase <n>"
allowed-tools:
  - Read
  - Grep
  - Glob
  - Edit
  - Write
  - Bash
  - AskUserQuestion
---

# implement-phase

You build **one phase**, not the plan. The phase's `### P<n>` section is the brief, its
`Done when:` is the gate, and its commit is what the reviewer reads. `/tdd-phase` is the
test-first sibling; both write the same Progress row and can be mixed in one plan.

## Pick the phase

`/implement-phase <change-id> phase <n>` works on `work/changes/<change-id>/plan.md`
(a direct path to a plan also works). No phase given → the first `[ ]` row; say which one
you picked before starting.

Refuse a change folder under `work/archive/` — say it is archived and that new work needs
a new change (`/start-change`) — and stop.

**Read only what this phase needs:**

1. From the plan: the header line (lane), `## Decisions`, `## Out of scope`,
   `## Hard guarantees`. Not the other phases.
2. This phase's `### P<n>` section.
3. `implementation-notes/p<n>.md` if the section names it. It belongs to this phase only.
4. The files in the section's `paths:`.

Lesson files under `.claude/rules/` load on their own for the paths you touch; the plan's
Hard guarantees already name the ones in reach. Do not go reading the whole lesson set.

## Build it

Follow the section's intent and adapt to what you find — and say when you adapt, because a
silent adaptation looks like drift to the reviewer.

**When the plan and the code disagree, stop and say so:**

```
Plan mismatch in P<n>
  The plan says: <what the section expects>
  The code has:  <what is actually there>
  Consequence:   <one line>
```

Then one `AskUserQuestion`: adapt and continue (say how) / skip that part / stop and
re-plan. Under a drive (`DRIVE_RUN=1`) nobody is there to answer: return
`status: needs_input` with that block in `notes` and stop.

**Keep a list of every file you write.** Each `Edit`/`Write` adds its repo-relative path.
That list — plus `plan.md` and `change.md`, which you will update — is what gets staged,
not whatever `git status` shows. A dirty file you did not touch is not yours to commit. On
a change's first phase, also include the untracked files inside the change folder so the
folder lands with its first commit.

**Scope.** A file outside `paths:` is not forbidden; it is *undeclared*. Touch it when the
work truly needs it and list it in `out_of_scope[]` with the reason. The engine flags
undeclared files; the reviewer judges the reasons of declared ones.

**Fixed rules inside any phase:**

- The plan's Hard guarantees hold. No phase relaxes one.
- Never log secrets, tokens, keys or personal data — log identifiers.
- `git add <path>` explicitly, never `-A` or `.`. Never `--amend`, never `--no-verify`.
  When a pre-commit hook fails, fix what it complains about and commit again.
- A manual check nobody performed is never `[x]`.

## Check it

Run every `Done when:` criterion, as written. Where the section names a negative control,
do it: introduce the violation, watch the check go red, revert, and note that you did.

Write the gate result as one line in your notes — the reviewer reads that line instead of
re-running a green gate (`gate_recorded: true`).

A red gate is never a commit point. Fix and re-run.

## Land it

1. **Manual checks first.** If `Done when:` includes something a person must look at,
   print what passed automatically and what they need to check, and pause. Under a drive,
   do not pause: land the automated part, mark the row `[~]` with
   `deferred: human-judgment — <what is owed>`, and say so in `notes`.
2. **Flip the Progress row before staging.** `[ ]` → `[x]` with
   `<date> · <one clause on what shipped or deviated>`, or `[~]` with
   `deferred: <category> — <why>`. Only this phase's row; never the phase body. No SHA in
   the notes — you cannot know it yet, and the commit subject carries the link.
3. **`change.md`**: `status: in-progress`, `updated: <today>`; on the last phase,
   `status: implemented`.
4. **Stage by path** from your list, always including `plan.md` and `change.md`. The row
   flip belongs in the same commit as the code it describes: a flip left dirty is a HEAD
   that still says `[ ]` for work that landed, and HEAD is what every later reader uses.
   If other dirty paths exist, name them and ask (planned set only / everything / abort);
   under a drive, always the planned set.
5. **Commit**, message on stdin:

   ```bash
   git commit -F - <<'MSG'
   <type>(<change-id>): <what the phase delivers> (<change-id> p<n>)

   <2–5 lines: what changed, what deviated, what was deferred>
   MSG
   ```

One phase, one commit: code, tests, `plan.md` and `change.md` together. If something must
land after it (a result you only get post-commit), that is a second commit in the same
phase — not a dirty tree handed to the next one.

## Report

End with this JSON block and nothing after it. It must validate against
`scripts/drive/schemas/impl.json`.

```json
{
  "status": "committed",
  "commit_sha": "abc1234",
  "touched_files": ["src/import/adapter.ts", "src/import/adapter.test.ts", "work/changes/import/plan.md"],
  "out_of_scope": [{ "file": "src/types.ts", "reason": "the adapter's return type has to be exported" }],
  "diff_lines": 184,
  "gate_recorded": true,
  "notes": "Retry ceiling set to 5 per D2; negative control on the size guard went red, then reverted."
}
```

`blocked` and `needs_input` carry `commit_sha: null` and explain in `notes`. Reporting a
partial phase as `committed` is the most expensive mistake available here — say plainly
what you could not do.

## After

**Under a drive** (`DRIVE_RUN=1`): print the result block and stop. The engine handles
review, fixes and the next phase. Ask nothing.

**With a person:** one `AskUserQuestion` — continue to P<n+1> here / clear context and run
`/implement-phase <change-id> phase <n+1>` / review this phase first
(`/phase-review <change-id> phase <n>`). If they asked for several phases in a row, skip
the question between them.
