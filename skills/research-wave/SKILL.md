---
name: research-wave
description: Use when a change has named open decisions that need outside evidence or codebase archaeology before planning — "research wave", "research these decisions in parallel", or /prep finding open decisions in change.md. Runs one independent research lane per decision, screens each result, and writes a short synthesis the plan can cite. Sits between /start-change and /phase-plan.
argument-hint: "<change-id> [--prompts | --synthesize]"
allowed-tools:
  - Read
  - Grep
  - Glob
  - Edit
  - Write
  - Bash
  - Agent
  - Workflow
  - AskUserQuestion
---

# research-wave

A wave exists to **settle named decisions**. It is not general information gathering, and
being asked for one does not by itself create anything to research.

```
plan the lanes with the user → one fresh critic checks the lane plan
→ lanes run in parallel, each result screened → one fresh synthesis over the lane files
→ hand-back
```

## When to refuse

Check these first and stop at the first that applies:

1. **No open decisions.** `work/changes/<id>/change.md` has no `## Open decisions` list,
   or it says none. Without a named decision there is nothing to settle; route to
   `/phase-plan`, which decides small questions inside the phase that meets them.
2. **A Q-lane task.** Q work has no change folder, so it has no wave.

A single decision is fine — a one-lane wave is still cheaper than a wrong plan. On
`lane: S`, say once that a wave is unusual for S and continue only if the user confirms.

## Budget

- **One lane per decision.** Lanes must be independent; a lane that needs another lane's
  result is an ordering mistake, not a lane.
- **Lane deliverable: at most 300 lines.** A lane that needs more is answering two
  questions — split it or narrow it.
- **Synthesis: at most 150 lines** for the whole wave.
- **At most one page per decision reaches the plan.** The rest stays in the lane file.

## Setup

`/research-wave <change-id>` (`--prompts` to get copy-paste prompts instead of dispatching,
`--synthesize` to resume after prompts were run elsewhere).

Find the repository root (`git rev-parse --show-toplevel`; in a linked worktree, also the
main checkout) and confirm `work/changes/<id>/` exists there. If it does not, stop — never
create a change folder in whatever directory you happen to be in.

Read `change.md`, any existing `research/`, and — if they exist — `plan.md` and
`reviews/`. If a plan already settled a question, a lane that reopens it is **leakage**.
If `research-wave.md` exists, resume from its tracker and never re-run a lane marked done.

## 1. Plan the wave with the user

One `AskUserQuestion` per topic, at most four options, recommendation attached:

1. **Decisions** — propose the `## Open decisions` list as written; the user removes and
   adds.
2. **Settled** — what must not be reopened, each with where it was settled. On a
   research-heavy change this list is often the most valuable part of the file.
3. **Lanes and tools** — the split, and per lane which sources to use: library docs tools
   for APIs, code search for examples and benchmarks, the vendor's own pages for pricing
   and limits, the repository for archaeology. Every claim is later marked verified or
   inferred (see `.claude/rules/research.md` if the project uses it).

Write `work/changes/<id>/research-wave.md`: the decisions, the settled list, and a tracker:

| lane | decision it settles | read first | sources | deliverable | status |
| ---- | ------------------- | ---------- | ------- | ----------- | ------ |

Deliverables are `research/L<n>-<slug>.md` in the tracker and absolute paths inside lane
briefs. Status moves `pending → dispatched → done | limit-killed | incomplete`.

## 2. One critic before anything runs

Give the lane plan to one fresh sub-agent that edits nothing and reports on: coverage
(every decision has a lane), overlap (two lanes answering one thing), independence (hidden
dependencies), leakage (a lane reopening a settled point), and deliverable paths. Apply its
fixes, then ask: dispatch now / adjust lanes / give me prompts instead. One cheap critic
protecting several expensive lanes is worth it in `--prompts` mode too.

## 3. Run the lanes

Keep lane briefs short — the lane agent already has the project's CLAUDE.md and rules:

```
Research lane <Ln> for change <id>. Repository root: <absolute path> — confirm with
`git rev-parse --show-toplevel`; do not assume your working directory.
Read first: <anchors>. Already settled, do not reopen: <one line>.
Decision to settle: <the question>.
Sources: <per the plan>. Compare options; do not copy blindly.
Write your findings to <absolute deliverable path>, at most 300 lines, marking each claim
[V] verified against a cited source or [I] inferred; finish with a five-line summary in
chat. Do not commit. Do not edit anything outside that file.
```

With the `Workflow` tool, dispatch through `scripts/wave-workflow.mjs` in this skill's
folder: it runs the lanes in parallel, screens each deliverable as its lane finishes, and
writes the synthesis in the same run when every lane screens done (`allDone: true` means
step 4 already happened — check `research/synthesis.md` exists and go to the hand-back).
To re-run only failed lanes, pass `allPaths` with **every** lane's deliverable so the
synthesis still reads the whole wave. Without the tool, start the lanes as parallel
`Agent` calls and screen the results yourself.

**Screen every result before accepting it.** Empty output, or a usage-limit message
("you've hit your limit", "resets at …"), means the lane did **not** run: mark it
`limit-killed`, never `done`, and do not count it as an attempt. A file that exists but
does not answer its decision → `incomplete`: one retry with a sharper brief, then hand
back.

Do not stall: when lanes come back, update the tracker and keep going in the same turn.
The user should never have to type "continue".

`--prompts` appends a `## Lane prompts` section to `research-wave.md` (one fenced block
per lane) and prints the resume command; `--synthesize` later checks each deliverable,
updates its row, and continues to step 4.

## 4. Synthesize

One fresh sub-agent reads **all** lane files — the files, not chat summaries — and writes
`research/synthesis.md`, at most 150 lines: for each decision, the answer, which lane file
supports it, confidence, and remaining gaps. Where lanes disagree it reports the
disagreement instead of averaging it away.

## Hand-back

```
Research wave — <id>: <n>/<m> lanes done (<limit-killed or missing: which, and when the limit resets>)
Files: research-wave.md · research/L*.md · research/synthesis.md
Decisions settled: <k>/<total> — open: <one line each>
Next: /phase-plan <id>   (or re-run the failed lanes: <command>)
```

## Ground rules

- The files are the output. A lane whose findings exist only in chat is `incomplete`.
- The tracker holds lane status, updated the moment it changes, so a cold resume works.
- Never re-run a `done` lane; never mark a lane `done` without its file on disk.
- The wave never edits code and never commits.
