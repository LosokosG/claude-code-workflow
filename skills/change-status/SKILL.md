---
name: change-status
description: Use when the user asks where things stand or what to do next — "what's the status", "where did we leave off", "is <change> done", "what should I run now" — or at the start of a session when it is unclear which skill comes next. Read-only; ends with exactly one recommended command.
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
---

# change-status

Answer three things from what is on disk right now: **where every open change is**, **what
is next**, and **the one command to run**. This skill never edits anything.

Every statement must come from a file or a git command run in **this** invocation — never
from earlier in the conversation. Stages get misremembered across a context clear.

## Gather

- `ls work/changes/` and `ls work/archive/`.
- For each open change: `change.md` (`lane:`, `status:`, `updated:`), which artifacts exist
  (`plan.md`, `reviews/plan-review.md`, `reviews/phase-*.md`, `research/`), and the
  `## Progress` table. A folder without `change.md` is not a change — mention it and move on.
- The drive state for each change: `bash scripts/drive/drive-ctl.sh status <id> --json`
  (run it in the checkout that holds the branch).
- Git in the **main checkout** (`git rev-parse --path-format=absolute --git-common-dir`,
  then its parent): current branch and `git log --oneline -5`. Flag a branch that does not
  match the change being worked on. In a linked worktree, report both.
- When `git worktree list` shows more than one checkout: path · branch · whether a drive
  lock is live · dirty or clean.
- `work/proposed-lessons.md`: count the queued lines.
- A roadmap, if the project keeps one (for example `work/roadmap.md`).

## Read Progress

Count rows in the table: `[ ]` pending, `[x]` done, `[~]` owed to a human (list those
separately — they are a person's queue, not the engine's). The next phase is the first
`[ ]`. Run `node scripts/check-plan-progress.mjs <plan>` when the table looks odd.

What is on disk wins over `status:` in change.md, which is only advisory. A mismatch that
changes the recommendation is a **finding**. A phase reviewed while the next is not yet
reviewed is normal, not a contradiction.

## Route

| State | Next |
| --- | --- |
| no change; the ask touches no reserved surface and looks small | `/quick <intent>` |
| `change.md` only | `/prep <id>` |
| `plan.md`, no `reviews/plan-review.md` | `/plan-review <id>` in a fresh window |
| reviewed plan, every row `[ ]` | checkpoint commit, then `/drive <id>` |
| some rows `[x]`, some `[ ]` | `/drive <id>` — it resumes at the first `[ ]` |
| a drive is `running` / `paused` / `waiting-limit` | attach: `/drive <id>` reconnects without relaunching |
| a drive is `needs-input` | read `drive/needs-input.md`; `/drive <id>` walks it |
| every row `[x]`, or only `[~]` left | check the `[~]` rows yourself → `/lesson-capture --drain` → move the folder to `work/archive/` |

Working one phase by hand instead of driving: the row's `route:` decides —
`/implement-phase` by default, `/tdd-phase` for `route: tdd`.

## Report

```
Changes:   <id> — lane <S|F> — <stage> — next: <exact command>      (one line each)
Drives:    <id>: <state> phase <n> step <step>                       (omit when none)
Branch:    <branch> (<matches | mismatch>; worktree noted if relevant)
Checkouts: <only when more than one: path · branch · driving | idle · dirty?>
Owed:      <[~] rows across open changes, one line each — omit when none>
Lessons:   <n> queued in work/proposed-lessons.md
Findings:  <contradictions, one line each — omit when none>
Recommended next step: <ONE exact command>
Run it in: <this window | a fresh window | it is a drive — walk away>
```

Where to run things: status questions → this window. `/phase-plan`, `/plan-review`,
`/phase-review`, `/prep` → a fresh window (a clean context and an unbiased review). A
drive → a fresh window; it manages its own contexts. Never send a review into a window
that already holds the implementation discussion.

One recommendation, not a menu. If two moves are genuinely tied, say why in one line and
still pick one. If the state contradicts itself, report the contradiction instead of
smoothing it over.
