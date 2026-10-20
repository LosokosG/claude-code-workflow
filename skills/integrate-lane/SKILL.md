---
name: integrate-lane
description: Use when a change built in its own worktree has to land on a main that moved while it was being built — typically the second of two changes driven in parallel, or when the user says "integrate <change>", "land the other branch", "merge the second lane". `--rehearse` records conflict resolutions in advance while both are still running. Not for the first or only change (a plain merge) and not for archiving.
argument-hint: "<change-id> [--rehearse]"
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
  - PushNotification
---

# integrate-lane

One guarantee, borrowed from merge queues: **main always passes, because you test the
merged result — never the branch on its own — and you land one branch at a time.**
Everything below serves that.

Why a skill and not `git merge`:

- **A clean merge proves nothing.** The typical failure of parallel agent work is the
  *semantic* conflict: textually clean, behaviorally broken — a function renamed on one
  side and newly called by its old name on the other; a contract changed on one side and
  newly consumed in its old shape on the other. Only the full gate plus a live check on
  the merged tree catches that.
- **Results go stale.** Tests that passed against the main a branch started from say
  nothing about the main it lands on.
- **Leftovers accumulate.** Worktrees and branches left after landing turn into stale
  locks, phantom "running" lanes and stray `.env` copies.

```
pre-flight → merge main INTO the branch → full gate on the merged tree
→ live check of this change's main flow → land on main → clean up
```

## Invocation

- `/integrate-lane <change-id>` — land it.
- `/integrate-lane <change-id> --rehearse` — record only: merge main into a scratch copy,
  let `git rerere` record how each conflict was resolved, report the conflict surface,
  abort. Nothing lands. The real landing later replays those resolutions.
- Run it from the **main checkout**, in a fresh window. Landing always happens in the main
  checkout; a worktree never owns `main`.

## Pre-flight — stop early, with the reason

1. **The change exists.** `work/changes/<id>/` is present and not archived; the branch
   from its `change.md` (`branch:`, else the id) exists.
2. **There is something to land, and main has moved.** `git merge-base --is-ancestor
   <branch> main` is false, and `git rev-list --count <branch>..main` is above zero. If
   main has not moved, this is an ordinary merge: say so, merge, run the gate, done.
3. **The other lane went first** (full mode). If the plan or drive log names a partner
   change that was meant to land first, check that main contains it — the partner branch
   is an ancestor of main, or main has a merge commit naming it. Squash merges defeat both
   checks; if neither is conclusive, ask the user rather than guess. Landing out of the
   agreed order silently reverses a decision.
4. **This change's drive is finished.** No live drive lock
   (`bash scripts/drive/drive-ctl.sh status <id>`), no open CRITICAL in its reviews, and
   no `[ ]` row left unless the user explicitly chooses to land a partial change (record
   that).
5. **Both checkouts are clean.** No uncommitted tracked changes in the lane's worktree or
   the main checkout. A landing must not sweep up stray work.
6. **rerere is on.** `git config rerere.enabled true` and `git config rerere.autoUpdate
   true` if not already — that is what makes rehearsals pay off.
7. **Ask before landing.** Before the land step: "gate and live check are green on the
   merged tree — land <branch> on main now?" If nobody can answer (an unattended or
   sub-agent context), do not land: stop after the gate and check, with the hand-back
   reading "READY TO LAND — re-run attended". `--rehearse` never asks; it never lands.

## 1. Merge main into the branch

In the lane's worktree (or a temporary one: `git worktree add <tmp> <branch>`):

```bash
git merge main
```

Merge, not rebase, on purpose: plans and drive logs refer to phase commits by SHA, and a
rebase rewrites every one of them. A merge keeps them true, satisfies the guarantee (test
the merged state, land one at a time), and keeps conflicts identical between a rehearsal
and the real landing.

Resolve conflicts in this order:

- **Replayed resolutions first.** With `autoUpdate`, rehearsed resolutions are already
  staged. `git rerere remaining` printing nothing is the signal that all were replayed —
  not the merge's exit code, which is non-zero even when everything was replayed.
- **The rest by hand**, with both changes' `plan.md` and `change.md` read for intent.
  Conflicts in shared registries (type unions, route lists, style tokens, manifests) are
  usually additive: keep both sides and de-duplicate. A conflict in feature code the two
  plans claimed was disjoint is a finding: resolve it and report it in the hand-back.
- **Security-relevant files** (access rules, auth, middleware, migrations): resolve toward
  the stricter side and flag it for the user. Never pick the looser behavior silently.
- Then `git rerere` to record anything new, and commit:
  `merge(<change-id>): integrate main (<n> conflicts resolved)`.

`--rehearse` instead: resolve, `git rerere`, then **`git merge --abort`** (the recorded
resolutions survive the abort — that is the point), report files, count and anything that
looks semantic, and stop.

## 2. Full gate on the merged tree

Run the project's complete gate — every check CI runs (type check, lint, the full test
suite, build), not a scoped subset — on the merged branch. Red → fix on the branch in a
follow-up commit and run the whole gate again. Never continue past red; never
`--no-verify`. This step is where semantic conflicts surface, and it is the reason this
skill is more than an alias.

## 3. Live check of this change's main flow

As mandatory as the gate. Dispatch one `drive-verifier` agent in smoke mode against the
merged branch: the change's main flow end to end plus one bad input, with evidence files
(command output, persisted-state checks, console and network excerpts, screenshots where a
browser is involved). A PASS without artifacts is not a PASS.

**When the two changes touched any of the same shared files** (a route registry, a shared
layout, global styles, shared types), also open the *other* change's entry point once and
check it renders without errors. That shared file is exactly where cross-lane breakage
lives; "not my change" is not a reason to skip it.

## 4. Land

In the main checkout:

```bash
git switch main
git rev-parse main     # must equal the main you merged in step 1
git merge --no-ff <branch>
git diff main <branch> # must be empty
```

If main moved since step 1, go back to step 1 — the guarantee only covers the tree you
actually tested. Never land two branches in one run; land this one, then run the skill
again for the next after its own gate.

## 5. Clean up

1. `git worktree remove <lane path>` (it is clean by now) and `git worktree prune`.
2. The lane's `.env` copy goes with the worktree — it held secrets, so that is intended.
3. Offer, do not do: `git branch -d <branch>` (safe after the merge) and `git push`.
   Pushing is always the user's call.
4. Remove any leftover drive lock for this change.

## Hand-back

```
integrate-lane — <change-id> — landed on main @ <sha>   (or: REHEARSED, nothing landed | STOPPED: <reason>)
Conflicts:   <n> resolved (<m> replayed) — files: <list> · plans under-declared overlap: <yes: files | no>
Gate:        <green | what failed and the fix commit>
Live check:  <flow results + evidence paths>
Security:    <conflicts in sensitive files resolved toward the stricter side — please review | none>
Cleanup:     worktree removed · branch <kept — delete with git branch -d <branch>> · push offered, not done
Next:        move work/changes/<change-id>/ to work/archive/ when you are done with it
```

## Stop and correct when you catch yourself thinking

| Thought | Reality |
| --- | --- |
| "the merge was clean, so the gate is redundant" | semantic conflicts are invisible to git; gate the merged tree every time |
| "the other change's page is not my problem" | with a shared file, the cross-check is required — that is where the breakage is |
| "the tests passed on the branch yesterday" | against which main? Anything before the merge is void |
| "the merge exited non-zero, so something is unresolved" | after a replay, `git rerere remaining` decides, not the exit code |
| "both lanes at once saves time" | one at a time is the guarantee |
| "I'll rebase to tidy the history" | the merge exists to keep recorded SHAs valid; never rewrite landed history |
| "the migration conflict — take this branch's side" | sensitive conflicts go to the stricter side, with a flag |
| "keep the worktree around just in case" | it becomes ghost state: clean, land, remove, prune |
| "I'll push too, the user is waiting" | offer it; pushing is theirs |
