# Design decisions

What the workflow commits to, why, where it is enforced, and what tests it. Check numbers
refer to `scripts/drive/drive-selftest.sh`; "node" means `tests/*.test.mjs`.

## The engine

| # | Decision | Why | Enforced in | Tested by |
| - | -------- | --- | ----------- | --------- |
| 1 | Every step is its own `claude -p` call with a JSON schema; the launching session only watches. | A long conversation that drives all phases forgets early decisions and grades its own work. | `drive-step.sh` (`run_step`, `drive_backend_claude`) | check 22: every model call carries a step marker; calls = DISPATCH lines; 0 unattributed |
| 2 | State is the plan's Progress table plus git; nothing is remembered between steps. A per-phase stage file records implemented → reviewed → fixed → verified. | A resume after a crash, `kill -9` or a usage limit must not depend on memory. | `drive-lib.sh` (`plan_open_phases`, `drive_stage_*`) | checks 2, 14 |
| 3 | If the implementer leaves its Progress flip uncommitted, the engine commits it as a plan-only commit, with hooks running. | Every later reader (a resume, a reviewer, status) reads HEAD, not the working tree. | `drive-phase.sh` (`drive_commit_plan_flip`) | check 20 |
| 4 | Review depth follows risk: a `risk:` tag, or a path listed in `work/surface-globs.json`, gets two parallel lenses (drift, safety); an untagged phase is reviewed only when its diff exceeds twice its `size:` or leaves its `paths:`. | Review cost goes where a mistake is expensive; the surface list catches a phase that under-declared its risk. | `drive-phase.sh` | check 1 |
| 5 | The reviewer's model tier is never below the implementer's; otherwise the engine stops for a human. | A weaker reviewer passing stronger work produces confidence nobody checks. | `drive-step.sh` (tier ranks) | check 8 |
| 6 | Triage is a script. Merge by file and mechanism; severity = highest *proven* (a CRITICAL needs `file:line` and a failure scenario, else it is recorded as WARNING); confidence < 80 dropped; notes go to `work/proposed-lessons.md` and are never fixed. | Turning review prose into actions is where an LLM orchestrator would quietly drop or inflate findings. | `drive-triage.mjs` | check 11; node: triage tests |
| 7 | One fixer per finding, inside a fence of the files the reviewer named plus files it declares with a reason. Undeclared edits are rejected once, then the run stops. | A fix that wanders is a new, unreviewed change. Cross-file fixes are allowed — declared. | `drive-lib.sh` (`triage_and_fix`), `drive-scope-check.mjs --fence` | check 6; node: fence test |
| 8 | A declined fix is re-dispatched once, then escalated once to the top worker tier with the phase's paths as the fence; if it is still open, the next phase does not start until `drive-ctl ack`. | An unfixed finding is a decision, not a non-event; the next phase would build on it. | `drive-lib.sh` (`drive_gate_unfixed`), `drive-ctl.sh ack` | checks 13, 21 |
| 9 | At most one re-review per phase, and only after a CRITICAL was fixed. A CRITICAL that survives it stops the run. | Review loops converge or they burn money; the second round is a human's. | `drive-lib.sh` | check 4 |
| 10 | Out-of-scope edits are allowed when declared with a reason; an undeclared file becomes an "unplanned" WARNING; nothing is auto-reverted. | Real work needs the odd extra file; silent scope growth is the failure, not the file. | `drive-scope-check.mjs` | check 5; node: scope tests |
| 11 | The verifier must save evidence files; a flow reported PASS without them is printed as UNVERIFIED. | "It works" without output to look at is a claim, not a result. | `agents/drive-verifier.md`, `schemas/verify.json`, `drive-handback.sh` | check 25 |
| 12 | Usage limits: sleep until the stated reset plus a margin and resume; never counted as a failed attempt; a repeating banner is capped. `--shutdown` fires only at a terminal hand-back, never during a limit pause. | Overnight runs hit limits; they should finish, not fail or power off mid-run. | `drive-step.sh`, `drive.sh` | checks 7, 12 |
| 13 | A budget kill resets only the step's declared paths and restores any file the user already had dirty there, byte for byte. A hung step is killed at `DRIVE_STEP_TIMEOUT` and retried once. | Cleaning up after a killed step must never destroy someone else's work. | `drive-step.sh` (snapshot, `drive_reset_scope`, backend timeout) | checks 9, 16, 23 |
| 14 | The lock is a directory created with `mkdir`; `stop` kills the step's children before releasing it, signals a process group only when the run owns it, and checks the pid's start time so a recycled pid is never signalled. | Two runs on one checkout, or a stop that kills an unrelated process, are both worse than no automation. | `drive.sh`, `drive-ctl.sh stop` | checks 3, 15, 18, 19 |
| 15 | Steering and questions go through files: `steer` is consumed by the next step's prompt; `ask` answers from the run's own record without consuming queued steering. | The user can talk to a running drive without a model in the loop holding state. | `drive-step.sh`, `drive-ctl.sh` | checks 10, 17 |
| 16 | The run never pushes and never archives. | Both are visible to other people; they stay with the user. | absence of either in the engine; the hand-back says so | check 25 |
| 17 | The plan is a linted contract: one row per phase, three statuses, `deferred:` notes on `[~]`, required fields per phase, lane-sized caps as warnings. | A malformed table silently changes what the engine runs. | `scripts/check-plan-progress.mjs` | check 24; node: plan tests |

## Conventions in the skills (instructions to the model, not machine-checked)

- **One question round when planning**, at most four questions; everything else is decided
  and written into the plan's Decisions table.
- **Plan review in a fresh context with a bare prompt** — no summary, no expected verdict.
  The reviewer inherits the session's model; a review gate is never moved down a tier to
  save money (`rules/review-floor.md`).
- **One phase, one commit**, with the Progress flip in the same commit and a
  `(<change-id> p<n>)` suffix in the subject instead of SHAs written back into the plan.
- **Test-first only while the code is absent** (`/tdd-phase` refuses otherwise).
- **Lessons are path-scoped rule files**, loaded only when matching files are touched,
  and handed to drive reviews explicitly because `git diff` reading does not trigger them.
- **Lanes:** Q (no reserved surface, small — `/quick`, no plan), S (plan ≤ 250 lines),
  F (plan ≤ 400 lines, research wave and deep plan review available).
