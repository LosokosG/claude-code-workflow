---
name: drive
description: Use when the user wants an approved, reviewed phase plan executed hands-free instead of running implement → review → fix by hand and clearing context between phases. Triggers — "drive the plan", "run the remaining phases", "auto-pilot this change", "drive phase N through M", `/drive`. Only for a plan with a `## Progress` table that has been through /plan-review. The chat it runs in becomes the run's control room.
argument-hint: <change-id> [phase N | through N] [--shutdown]
allowed-tools:
  - Read
  - Grep
  - Bash
  - Monitor
  - AskUserQuestion
  - PushNotification
---

# drive

**You are not the engine.** `scripts/drive/drive.sh` is: a bash runner that gives every
step a fresh model context, triages review output deterministically, and keeps its state
in the plan's `## Progress` table plus git. Your job is one checkout, one read-back, one
launch, and then being the place the user talks to the run. Running the phase loop inside
this conversation is the exact failure the engine exists to remove — context fills up,
phases blur together, and "done" stops meaning anything.

Paths below assume the engine is vendored at `scripts/drive/` and change folders live in
`work/changes/<id>/` (`DRIVE_WORK_DIR` moves them). Adjust if the project says otherwise.

## 1. Get a checkout to drive

The main checkout is shared and is usually on some other branch. Run

```bash
bash scripts/drive/drive-checkout.sh <change-id>
```

It is idempotent: it reuses the checkout that already has the change's branch, or makes a
worktree at `.claude/worktrees/<change-id>`, merges main in, copies `.env`, installs
dependencies when there is a `package.json`, and runs `work/setup-worktree.sh` if the
project has one. Its last stdout line is the checkout path — call it `WT`. **Run every
command below from `WT`.** Exit 3 = merge conflict: show the message, let the user resolve
it, run it again. Exit 2 = a precondition (dirty checkout, no change folder, install
failed): relay it as written and stop.

Then `bash scripts/drive/drive-ctl.sh status <id>` in `WT`. If a run is already
`running`, `paused` or `waiting-limit`, do not launch a second one — go to §4 and attach.
If it is `needs-input`, go to §5.

## 2. Read the plan back, once

Read `WT/work/changes/<id>/plan.md` and collect:

- **Scope** — one line on what the phases in range ship, one on what `## Out of scope`
  says they will not. A scope surprise at hand-back costs a day.
- **Phases in range** — the `[ ]` rows the bound selects. `[~]` rows are owed to a human
  and are skipped.
- **Risk** — rows with a `risk:` tag other than `none`, or touching a path in
  `work/surface-globs.json`. Those get two review lenses (drift, safety) in parallel.
- **Missing env** — the variable *names* the phases need, checked against
  `grep -oE '^[A-Z_]+=' WT/.env`. Never print values.

Run `node scripts/check-plan-progress.mjs WT/work/changes/<id>/plan.md`. A blocking
finding means the plan is not drivable yet: show it and stop.

Then **one** `AskUserQuestion`: go / no-go on that scope, and `--shutdown` yes / no.
After that, ask nothing. There are no mid-run questions; the engine stops and writes
`needs-input.md` when it needs a human.

Refuse to launch when the plan has no `## Progress` table, the change folder is under
`work/archive/`, or `WT` is on `main`.

## 3. Launch

```bash
cd WT && bash scripts/drive/drive.sh <change-id> [phase N|through N] [--shutdown] --bg
```

`--bg` detaches the run (nohup + its own session) so it outlives this chat. Print the line
it returns, then these, exactly:

```
status: bash scripts/drive/drive-ctl.sh status <id>      log:  bash scripts/drive/drive-ctl.sh log <id> -f
steer:  bash scripts/drive/drive-ctl.sh steer <id> "…"   ask:  bash scripts/drive/drive-ctl.sh ask <id> "…"
stop:   bash scripts/drive/drive-ctl.sh stop <id>        (all from WT)
```

## 4. Be the control room

Arm one persistent `Monitor` on the heartbeat ledger so progress arrives without polling.
Filter to lines a human acts on, never the raw stream:

```bash
tail -n 0 -F WT/work/changes/<id>/drive-log.md | grep --line-buffered -E 'RESULT |needs-input|limit|## Hand-back'
```

Relay each event in one line. Between events, do nothing. When the user speaks:

| They say | You run |
| --- | --- |
| "how is it going", "where is it" | `drive-ctl status` — never guess the state |
| "tell it …", "make sure it …" | `drive-ctl steer <id> "…"` (read by the next step) |
| a question about what the run did | `drive-ctl ask <id> "…"` (answers from the record) |
| "pause", "resume", "stop" | the matching `drive-ctl` command |

**Unfixed findings.** When needs-input names findings the fix pass could not close, the
engine will not start the next phase on top of them. Read `drive/unfixed-p<N>.md`, close
each one (fix it here at session tier, or record why it can wait), then
`drive-ctl ack <id> <N> "<what you did>"` and relaunch. Never ack just to clear the gate —
the next phase inherits whatever is still open.

On `## Hand-back`: relay the block, send a PushNotification, stop the monitor. The run
never pushes and never archives. Offer `git push` + a PR update, and moving the change
folder to `work/archive/`, as the user's next moves.

## 5. needs-input

The run exits 3 and writes `WT/work/changes/<id>/drive/needs-input.md`. Read it, put its
**Why** in front of the user together with the decision it asks for, and resolve it here —
edit the plan row, fix the blocker, or record the user's call. Then relaunch (§3); the
engine re-reads the table and resumes where it stopped.
