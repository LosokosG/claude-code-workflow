---
name: prep
description: Use to take an S- or F-lane change from idea to a reviewed, drive-ready plan in one window — "prep <change>", "get this ready to drive", "research, plan and review this". Chains /start-change → /research-wave (only for open decisions) → /phase-plan → /plan-review, with the user present at every judgement point. Not for running plans (/drive) and not for Q-sized work (/quick).
argument-hint: "<change-id | idea> [--lane S|F] [--deep]"
allowed-tools:
  - Read
  - Grep
  - Glob
  - Edit
  - Write
  - Bash
  - Agent
  - Skill
  - AskUserQuestion
---

# prep

One window from idea to a plan you can drive. Prep automates the **plumbing** — which
stage is next, dispatching it, keeping the files straight — and deliberately does not
automate the **judgement**: the user sets scope, answers the plan's questions and decides
what to do with review findings.

Prep is a thin conductor over the other skills. `/start-change`, `/research-wave`,
`/phase-plan` and `/plan-review` run unmodified; prep never re-implements a stage and never
touches product code.

```
resolve (change, lane, stage)
→ research     only when change.md lists open decisions
→ plan         interactive, in THIS window
→ plan review  one fresh sub-agent, document-only (--deep on F)
→ walk the findings → checkpoint commit → hand-off
```

If the ask touches no reserved surface and looks like ~300 changed lines or less, say it
is Q-sized, route to `/quick`, and stop.

## Resolve

`/prep <change-id | idea> [--lane S|F] [--deep]`

1. **Find the main checkout** (`git rev-parse --show-toplevel`; in a linked worktree also
   `git rev-parse --path-format=absolute --git-common-dir` → its parent).
2. **Resolve the argument.** An existing `work/changes/<id>/` → use it. An idea → confirm a
   change id in one question, then run `/start-change <id>` through the Skill tool.
3. **Read the lane** from `change.md`. Missing → derive it as `/start-change` does and
   write it in.
4. **Work out the stage from files, never from memory**: which of `research/synthesis.md`,
   `plan.md`, `reviews/plan-review.md` exist. Print the stage and what is left, one line
   each.

If `bash scripts/drive/drive-ctl.sh status <id>` shows a live drive for this change, stop —
re-planning under a running drive is a different job. A drive of a *different* change is
normal and does not matter.

## Research — only for named decisions

Read `## Open decisions` in `change.md`. None listed → skip, say so in one line, ask
nothing. One or more → `/research-wave <id>` through the Skill tool. On `lane: S`, ask once
whether the decisions really need research; often the plan can decide them inside a phase.

Check what comes back: an empty result or a usage-limit message means the lane did not
run, so it is not done. Re-run it after the reset or hand back with the resume command. A
lane is done only when its file exists and answers its decision.

## Plan — in this window

Run `/phase-plan <id>` through the **Skill** tool here — never in a sub-agent. A
sub-agent's questions do not reach the user, and relaying them strips the content the
questions are about; the user ends up approving things they could not see.

**A question has to carry its evidence in a place that renders.** Text printed before a
tool call may never be shown. In order of preference: put the content in the question text
itself; use option previews when choosing between artifacts; or print it as the final
message of the turn and take the answer in chat.

`/phase-plan` owns its single question round (at most four questions). Do not wrap it,
pre-answer it, or add a round of your own.

## Plan review — a fresh sub-agent, told nothing

Dispatch one sub-agent without a `model` parameter, so the reviewer inherits this
session's tier; a review gate is never moved to a cheaper model to save money. Add `--deep`
only on `lane: F`. The prompt is exactly this, filled in, and nothing more:

```
Run the plan-review skill (read its SKILL.md fully and follow it) on change <change-id>
with --report-only. Repository root: <absolute path>. Save the report to
work/changes/<change-id>/reviews/plan-review.md and reply only with the report path and
the verdict line.
```

The point of a fresh context is that the reviewer knows nothing you know. Add no summary
of the plan, no history of this session, no hints about intent, no expected verdict, no
areas to focus on or skip. If you feel the reviewer "needs context to understand the
intent", that feeling is the bias — the plan must carry its own intent. If the dispatch
cannot keep this shape, do not dispatch; give the user a bare `/plan-review <change-id>`
for a fresh window instead.

**Walk the findings with the user here**, from the saved report, the way `/plan-review`
describes it: apply LOW-effort single-fix findings by default and list them, ask about the
rest one at a time with at most four options. A **REWORK** verdict whose fixes changed the
plan materially earns one more review, with the same bare prompt.

## Close-out

1. **Checkpoint commit** — ask once (no answer → commit). Stage only
   `work/changes/<change-id>/`, by explicit path.
2. **Drive readiness** — read back the plan's `## Drive Readiness` in at most eight lines:
   phase order, manual gates, and anything missing **today** (a variable not in `.env`, a
   seed that does not exist, a credential). That last list is the user's pre-drive
   checklist; name it as such. If the section is missing, write it now, including
   `parallel-safe:`.
3. **Hand off:**

```
Prep done — <change-id>: lane <S|F> · research <n decisions | skipped> · plan <k> lines · review <verdict>
Before driving: <missing env / seeds / credentials, or "nothing — ready now">
Next: /drive <change-id>   (fresh window; first run bounded: /drive <change-id> phase 1)
```

**Never start the drive yourself.** A run that takes hours and spends money is the user's
call.

## Temptations, and why not

| Tempting | Instead |
| --- | --- |
| giving the reviewer "a bit of context" | that context is the bias — bare prompt, or hand it off |
| researching with no open decision "to be safe" | research is per named decision; none, no lane |
| accepting a lane that hit a limit but wrote partial notes | not done — re-run or hand back with the reset time |
| running /phase-plan in a sub-agent because it is context-heavy | the user then answers blind; interactive stages run here |
| relaying a sub-agent's question with a summary | a summary is not the evidence; show the content, then ask |
| letting a timeout pick a scope answer | defaults settle mechanics, never scope — park it as "confirm or change" |
| starting the drive because the plan is approved | hand over the command |
| writing the change folder inside a worktree | change folders are created in the main checkout's branch, by /start-change |

## Notes

- Prep can be re-run at any point: it re-derives the stage from files and continues, and it
  never re-runs a stage whose output exists (it offers to refine it instead).
- The files are the state, not this window's history. If the context degrades, a fresh
  `/prep <change-id>` continues without loss.
- A question cut off by a session limit is asked again on resume. A scope or gate decision
  taken on a timeout default is listed at close-out under "decided by default — confirm or
  change"; a scope chosen by a timeout is not a user decision.
- `/change-status` is the read-only counterpart: it says where things are; prep moves them.
