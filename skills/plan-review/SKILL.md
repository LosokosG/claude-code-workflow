---
name: plan-review
description: Use after /phase-plan and before any code — an independent read of plan.md that checks whether the phases can actually reach the stated goal, whether the plan contradicts itself, and whether its file and symbol claims match the repo. Triggers — "review the plan", "is this plan ready to drive", `/plan-review <id>`. Saves a report, then walks the findings with the user.
argument-hint: <change-id> | <plan-path> [--deep] [--report-only]
---

# plan-review — a cold read before any code

The cheapest place to find a wrong assumption is before the first phase runs; after that,
every phase built on it has to be redone. This skill is a reviewer that did not write the
plan reading it cold. It does not judge code — `/phase-review` does that once code exists.

**Default: the document plus mechanical grounding.** One reviewer, the plan, the repo. No
sub-agents. `--deep` adds parallel claim verifiers and is meant for `lane: F` plans
(a new permission model, a data migration, a payment or key-handling surface, several
surfaces at once).

The same confidence floor as `/phase-review` applies: under 80, a concern is not reported.
A row in the plan's own Decisions table is settled and is not review material.

## Arguments

| Input | Behavior |
| --- | --- |
| a saved report (contains `<!-- PLAN-REVIEW -->`) | resume at the walkthrough |
| `<change-id>` or a plan path | review `work/changes/<id>/plan.md` |
| nothing | offer the newest plans (by `updated:` in change.md) in one question |
| `--deep` | add the claim verifiers; on an S-lane plan, say you are skipping them and why |
| `--report-only` | analyse, save, print the path, stop — the mode an orchestrator dispatches |

A plan under `work/archive/` is refused: archived changes do not get new reviews.

## A. Mechanical checks first

Run `node scripts/check-plan-progress.mjs <plan>` and copy its output into the report as
is. Its blocking lines are findings under *Completeness*; they cost no judgement and do
not count toward the finding cap. A malformed Progress table stops the drive engine cold,
so this is never a nit.

Then ground the plan in the repo, quickly:

- `ls -l` at least five paths the plan says it will modify. A path that does not exist,
  for a file the plan edits rather than creates, is a CRITICAL.
- `grep` the functions, exports and config keys it names.

One line in the report: `Grounding: 5/5 paths, 3/3 symbols`. Only failures become
findings.

**Tier check.** If the plan touches auth, data isolation, migrations, payments or
secrets, this review is a security gate and must run at a model tier at least equal to the
one that wrote the plan. If you are on a lower tier, say so at the top of the report and
recommend a re-run.

## B. Read the plan against itself

Read the whole plan, plus `change.md`'s open decisions and `research/synthesis.md` if they
exist. The most valuable findings are the ones the author half-saw:

- **Self-contradiction.** A limitation stated in one section and ignored by a phase; an
  out-of-scope item that reappears in a phase; a phase relying on behavior the plan calls
  broken elsewhere.
- **Unbacked promises.** Every outcome the plan promises needs a phase that builds it.
  "Retries are bounded" with no phase adding the bound is a gap the implementer will hit
  mid-build.
- **Open decisions left open.** A decision is closed by an answer or a written deferral —
  not by the pipeline moving on. Still open and a phase depends on it → CRITICAL. Still
  open but safely deferrable → WARNING, and the fix is writing the deferral down.
- **Broken hand-offs.** When step B needs something step A produces (an id, a column, an
  event), check that A actually produces it. Anything the implementer would have to guess
  is a finding.
- **Contract changes.** If the plan renames or reshapes something other code or other
  services consume, it must say so and describe the migration.

## C. Claim verification (`--deep` only)

Choose the **three to five claims** that would force the most rework if wrong, plus the
symbols and endpoints the plan changes. Run `scripts/verify-claims.mjs` (in this skill's
folder) through the `Workflow` tool:

```
Workflow({
  scriptPath: "<skill dir>/scripts/verify-claims.mjs",
  args: { planPath, changeId,
          claims: [{ id: "C1", claim: "…", anchors: "<paths / symbols to start from>" }],
          blastRadius: { symbols: ["…"] },
          patternAreas: ["…"] }   // or [] when the plan adds no new pattern
})
```

Each `CONTRADICTED` or `PARTIAL` claim and each unlisted caller is finding material; a
reported duplicate pattern belongs to *Fit*. An id under `unverified` means that verifier
did not return — the claim is unchecked, not confirmed; say so. Without the `Workflow`
tool, give the same claims to one general-purpose sub-agent, or skip this step and label
the review document-only.

## D. Judge the substance

Five lenses. Report real problems only; never fill a lens with "no issues".

- **Reaches the goal** — walking the phases in order, does the system end up where the plan
  says? Could every `Done when:` pass while the goal is still missed?
- **Lean** — for each phase: if it were removed, would the goal still be reachable? Look for
  abstractions nobody needs yet, "while we are here" work, a framework where a function
  would do.
- **Fit** — does it match how the codebase already works? A second way of doing something
  the repo already does; dependency direction; risky edits to widely shared code; vague
  "refactor as needed" steps.
- **Gaps** — unhappy paths, rollback if phase 3 fails, cost at real usage, a changed default
  that multiplies cost or time, security boundaries.
- **Completeness** — concrete paths and changes, runnable checks, no TBDs.

## E. Filter and size the findings

- Confidence under 80 → gone.
- A CRITICAL cites the plan line (and the code line, when it is about the code) and names
  what the implementer will hit. Argue against it once; if the counter-argument holds,
  downgrade or drop.
- Severity answers *will this break?*: CRITICAL = the plan will not work as written;
  WARNING = it works, but worse or riskier than it should. Anything lower is a note, at
  most five, never walked.
- At most 10 findings; merge beyond that.
- **Effort** is separate from severity: LOW (one obvious edit), MEDIUM or HIGH (a real
  choice). Give one fix; give two only when each has an advantage the other lacks, and star
  the one you recommend. MEDIUM/HIGH fixes add a line each on upside, cost and what the
  fix itself might miss.

Verdict: **READY** (drive it), **AMEND** (apply the fixes, then proceed without another
review), or **REWORK** (the approach is wrong). Only a REWORK earns a second review, and
only one.

## F. Save

Write `work/changes/<change-id>/reviews/plan-review.md` (re-running overwrites it) and set
`change.md` to `status: plan-reviewed`, `updated: <today>`.

```markdown
<!-- PLAN-REVIEW -->
# <change-id> · plan verdict

Verdict **AMEND** · mode document-only · YYYY-MM-DD · 1 critical, 2 warning
Checker: OK · Grounding: 5/5 paths, 3/3 symbols

| ID | Sev | Conf | Effort | Lens | Where |
| -- | --- | ---- | ------ | ---- | ----- |
| F1 | CRITICAL | 90 | HIGH | Gaps | P3 |

### F1 — <title>
The plan says: …  ·  Actually: …  (plan line / `file:line`)
Fix ⭐: …   |   Alternative: …
Decision: PENDING

## Notes, not actionable
- …
```

Print the report and go straight into the walkthrough without asking whether to:
`Saved <path> — walking the findings now; say "stop" to end here and resume later with
/plan-review <path>.` With `--report-only`, stop after saving.

## G. Walk the findings with the user

`AskUserQuestion` takes at most four options; "Other" is added for free text.

- **LOW-effort findings with one fix:** apply them all in one pass, then list them under
  "applied by default — tell me which to undo". Do not ask one by one.
- **Everything else**, most severe first, one question each: apply the starred fix / apply
  the alternative (or "different fix") / accept the risk / dismiss. Put severity,
  confidence, location, the claim-versus-reality line and the fix text in the question.
- Apply → show the exact plan edit, apply it, mark FIXED. Different fix → ask how, apply,
  mark FIXED. Accept → ACCEPTED. Dismiss → DISMISSED, without arguing.
- No answer (user away) → apply the starred fix, mark it "applied by default while away",
  continue, and list every such default prominently at the end.

Update each `Decision:` line in the saved report as you go, then print a summary: fixed,
applied by default, accepted, dismissed, and the verdict after fixes.

**Then offer a checkpoint commit** (recommended): stage only
`work/changes/<change-id>/`, never unrelated files. Put the summary — especially the
defaults — in the question itself, since a printed block may not render. No answer →
commit; it is trivially revertable.

Close with: `Next: /drive <change-id> in a fresh window (first run bounded:
/drive <change-id> phase 1)`.

Edit the plan only through the walkthrough, and minimally. Be concrete ("P3 adds a second
event bus beside the one in `src/core/events.ts`", not "architecture concerns"). If the
plan is good, say so in a line and stop.
