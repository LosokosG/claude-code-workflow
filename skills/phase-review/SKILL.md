---
name: phase-review
description: Use to review what a phase (or a whole change) actually committed against the plan row that asked for it — drift, safety, correctness, patterns, tests — and produce findings a fixer can act on. Triggers — "review phase N", "review the implementation", a drive review step, or `/phase-review <id>`. Reviews code that exists; for reviewing a plan before code, use /plan-review.
argument-hint: <change-id> [phase N] [--base <sha> --head <sha>] [--lens drift|safety] [--rereview]
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - Edit
  - Write
  - AskUserQuestion
---

# phase-review

One reviewer, a fresh context, one pass. Hold the commits against the phase row that
asked for them and report only what a competent engineer would act on. No sub-agents, no
second panel — you are the reviewer.

If the project has `.claude/rules/code-review.md`, read it first; its rubric adds to the
one here. Lessons: under a drive they arrive in your system prompt. Otherwise read the
`.claude/rules/lessons-*.md` files whose paths match the diff — path-scoped rules do not
load for code you only read through `git diff`.

## Arguments

| Argument | Meaning |
| --- | --- |
| `<change-id>` | `work/changes/<id>/plan.md` (a plan path also works) |
| `phase N` | that phase; without it, every `[x]` phase |
| `--base <sha> --head <sha>` | review exactly this range (the engine names the phase's range in its prompt instead; treat that the same way) |
| `--lens drift` / `--lens safety` | review one half (see Lenses) |
| `--rereview` | convergence pass after fixes (see Re-review) |
| nothing | the change with the newest `updated:` and `status: in-progress` or `implemented`; confirm with one question |

A change under `work/archive/` is refused: say archived changes are not reviewed, and stop.

## 1. Establish what to compare

1. Read **only** the phase section(s) under review, the Decisions table and the out-of-scope
   list. Not the whole plan.
2. Read the implementer's report if there is one (`drive/implement-p<N>.json`):
   `touched_files`, `out_of_scope` with reasons, and the recorded gate line.
3. Get the range: `BASE="${base:-$(git merge-base main HEAD)}"`, then
   `git diff --name-only "$BASE"..HEAD` and `git diff --stat "$BASE"..HEAD`.
4. Sort the changed files into three groups: in the row and in the diff (check the
   intent), in the diff but not the row (drift), in the row but not the diff (missing).
   Read the files your findings will cite; do not read all of them up front.

**Do not re-run a green gate.** The implementer recorded its gate result — in the drive
log or the report's notes. Read it and set `gate_recorded: true`. Only when there is no
such record, run that phase's automated `Done when:` checks yourself and set
`gate_recorded: false`.

**Manual checks are yours to judge.** For each human-judged criterion the row marks done,
ask: could it have failed at all, and does the diff contain anything that shows it
passed? "No" to either is a `tests` finding.

## 2. What to look for

**drift — always first.** Did the phase build what its row says, no more, no less?
A row item done differently in substance, or skipped → finding. A file in `out_of_scope`
→ judge the **reason**, not the file; a weak or missing reason is a WARNING. A file in the
diff that is neither in the row nor declared → WARNING "unplanned"; the remedy is declare
or revert, chosen by the implementer or the user — never revert it yourself. A diff over
twice the row's `size:` → one line saying so; that is a keep-or-split decision, not a
finding.

**safety.** The project's reserved surfaces (whatever its CLAUDE.md and
`work/surface-globs.json` name) plus the universal ones: access control and data
isolation, secrets and personal data in logs, input from outside the process, money and
quotas, injection, data loss, destructive migrations.

**correctness.** The bug that actually ships: wrong branch, swallowed error, race,
unbounded growth, a name or label the code does not live up to.

**patterns.** A real mismatch with how this codebase already solves the same problem.
Never style, never naming taste.

**tests.** Missing coverage only where the row's `Done when:` relied on it, or on a safety
path. A broken, empty or disabled test is a `correctness` finding.

## Lenses

No `--lens` = the full pass over all five. On a risk-tagged phase the engine instead runs
two lenses in parallel and merges them:

- `--lens drift` covers drift, correctness, patterns and tests.
- `--lens safety` covers safety in depth — every reserved surface the diff touches, plus
  data loss and injection paths.

Each dimension belongs to exactly one lens, so nothing is reviewed twice or not at all.
The engine's triage (`scripts/drive/drive-triage.mjs`) merges the two reports by **file
and mechanism** — same file, same underlying defect, regardless of wording. The merged
severity is the highest one a stream *proved*; confidence is the highest reported. A
finding only one lens reports is kept: the lenses are built not to overlap.

## 3. Filter before writing

- **Confidence.** Score each candidate 0–100. Anything under 80 is dropped completely —
  not softened into prose, not mentioned.
- **Argue against every CRITICAL.** For each, write down to yourself the strongest reason
  it is wrong: a guard upstream, an unreachable caller, a database constraint. If that
  reason holds, downgrade to WARNING or drop it. A CRITICAL that survives cites `file:line`
  and a concrete failure path (input, state, order of calls). No failure path, no
  CRITICAL — triage downgrades it anyway.
- **Only CRITICAL and WARNING are actionable.** Anything lower is a note: append it as
  one line to `work/proposed-lessons.md` and list it in the report, at most five. Notes
  are never fixed.
- **At most 10 findings.** Merge related ones beyond that.

Do not flag: style and formatting, naming preferences, test-case wish lists, refactors the
row did not ask for, anything the plan's Decisions table already settled, and
pre-existing problems outside the diff unless the phase made them worse.

## 4. Write the report

Save to `work/changes/<change-id>/reviews/phase-<N>[-<lens>].md` (`phase-all.md` for a
whole-change pass). Verdict: **REJECTED** if any CRITICAL, **NEEDS_ATTENTION** if any
WARNING, otherwise **APPROVED**.

````markdown
<!-- PHASE-REVIEW -->
# <change-id> · P<N> review<, lens <lens>>

| Verdict | Range | Gate | Critical | Warning | Date |
| ------- | ----- | ---- | -------- | ------- | ---- |
| NEEDS_ATTENTION | `a1b2c3d..e4f5a6b` | read from log | 0 | 2 | YYYY-MM-DD |

## Checked and sound

- <three to six lines, each something you confirmed in the code; nothing you did not check>

## To fix

| ID | Sev | Conf | Area | Where | Problem | Fix |
| -- | --- | ---- | ---- | ----- | ------- | --- |
| F1 | WARNING | 88 | drift | `src/import/adapter.ts:57` | … | … |

### F1 failure path   (CRITICAL findings only)

<input → state → call order → bad outcome>

## Notes, not actionable

- <one line each, at most five; also appended to work/proposed-lessons.md>

```json
{ "verdict": "NEEDS_ATTENTION", "phase": "2", "base": "a1b2c3d", "head": "e4f5a6b", "gate_recorded": true,
  "findings": [ { "id": "F1", "severity": "WARNING", "confidence": 88, "file": "src/import/adapter.ts",
    "line": 57, "summary": "…", "fix": "…", "dimension": "drift" } ],
  "observations": ["…"] }
```
````

The report **ends** with that fenced `json` block, and it must validate against
`scripts/drive/schemas/review.json` — triage parses it. `findings` holds actionable items
only; `observations` holds the notes as strings.

## 5. Re-review (`--rereview`)

**One per phase, at most.** Read the previous report and the fix commits, and report only:

1. whether each earlier CRITICAL and WARNING is really closed — check the changed lines
   yourself; a commit message is not evidence;
2. regressions the fixes introduced.

No new WARNINGs or notes on lines the fixes did not touch. A CRITICAL you newly see is
always reportable, wherever it is. If a CRITICAL is still open after this pass, the engine
stops for a human; there is no second re-review.

## 6. What happens to the findings

**Under a drive** (`DRIVE_RUN=1`): write the report and stop. Triage routes it — CRITICAL
to a fixer and then the one re-review, WARNING to a fixer, notes to the lessons queue. Ask
nothing, change nothing.

**With a person:**

- One `AskUserQuestion` per CRITICAL (apply the fix / fix it differently / accept the risk
  / dismiss). Nothing else gets its own question.
- All WARNINGs in one question: "apply all N?". On yes, apply each WARNING whose fix is
  prescriptive and stays in one file; list the rest with their fix lines.
- Notes are never asked about.
- Record each answer as a `Decision:` line under the finding in the saved report.

Edit code only when this step authorizes it, and only the lines the finding names. A phase
can break an assumption an earlier phase made — check the seam, not just the new files. If
the plan itself asked for something unsafe, say so as a finding against the plan.
