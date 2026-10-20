---
name: quick
description: The Q lane — a small change that touches no reserved surface, worked conversationally on a short branch with no change folder, no plan and no review document. Invoked explicitly as /quick; never chosen automatically.
disable-model-invocation: true
argument-hint: "<one-line intent> | done"
allowed-tools:
  - Read
  - Grep
  - Glob
  - Edit
  - Write
  - Bash
  - AskUserQuestion
---

# /quick — the Q lane

Q is for work that touches **none of the project's reserved surfaces** and looks like
**about 300 changed lines or less**. It skips the change folder, the plan and the review
document. What it keeps is everything that applies in every session anyway — rules,
hooks, the project's fast gate, a human reading the diff — and `/quick done` refuses to
commit if the work turned out not to be Q.

**Reserved surfaces** are whatever the project declares sensitive — typically access
control, data schema and migrations, secrets and logging of personal data, billing, CI and
deploy. If the project keeps the list as globs in `work/surface-globs.json`, read that
file rather than trusting a summary.

## `/quick <one-line intent>`

1. **Check the intent against the surfaces and the size.** If a reserved surface is
   obviously involved — a migration, an access rule, a deploy config — name it in one line
   and route:

   ```
   That touches <surface>, which Q does not cover.
   → /start-change <change-id>   (lane S)
   ```

   Do the same when the intent is plainly much bigger than ~300 lines. Do not negotiate the
   lane down.

2. **Branch.** `git switch -c quick/<slug> main` — from `main`, not from whatever is
   checked out; stacking would drag someone else's unreviewed work into this PR. Slug =
   kebab-case intent, at most four words. If the working tree is dirty, say so and stop
   rather than stashing.

3. **Say where you are and what applies**, four lines:

   ```
   Branch quick/<slug> (from main @ <short sha>) — everything here lands on this branch; /quick done opens the PR.
   Rules: CLAUDE.md, the path-scoped .claude/rules/ files (including lessons) for the files touched.
   Checks: the project's per-edit hooks, and its fast gate at /quick done.
   Finish: /quick done → surface + size check → gate → commit → draft PR.
   ```

4. **Work conversationally.** No plan, no phases, no Progress. The user reads the diff;
   that is the review.

## `/quick done`

In this order — each step can change the next:

1. **Surface check on what is staged.** `git add` the files that belong, then:

   ```bash
   git diff --cached --name-only | node scripts/drive/drive-scope-check.mjs --surface-list work/surface-globs.json
   ```

   (Without a surface file, compare the staged paths to the project's documented list by
   hand.) Any hit means the work outgrew Q: say so, run `/start-change <change-id>` to open
   a change for it, and continue there — plan what is left instead of finishing it here.

2. **Size check.** `git diff --cached --stat`. Over ~300 changed lines → say so and ask the
   one question `/quick` is allowed: split into two commits/PRs, or land it as one. Landing
   it whole is a legitimate answer; the point is that the user decides.

3. **Fast gate.** The project's type check, linter and unit tests — whatever it defines
   (read `package.json`, `Makefile` or similar). Red → fix and re-run. Never `--no-verify`.

4. **Commit.** `git add <path>` per file, never `-A` or `.`. A conventional commit subject,
   no phase suffix (Q has no phases). Never `--amend`, never `--no-verify`.

5. **Draft PR.**

   ```bash
   git push -u origin quick/<slug>
   gh pr create --draft --base main --head quick/<slug> --title "<intent>"
   ```

   Without `gh`, print the commands for the user instead of skipping the PR.

6. **Merge the same day.** A `quick/` branch still open the next day was not Q — say so and
   move what is left into a change.

## Offering Q

When a request looks Q-sized and the user has not typed `/quick`, offer it once in one
`AskUserQuestion`: "/quick (short branch, no plan, draft PR at the end)" against "open a
change with /start-change". Recommend `/quick`. Never assume the lane, and never ask twice.

## What Q gives up, and why that is fine

No plan, no phase gates, no `/phase-review`, no Progress rows. The safety net is the rules
that load by path, the per-edit hooks, the fast gate, the surface check, and a person
reading a draft PR. Escalation goes one way only: Q work that turns out to touch a
reserved surface becomes a change — it never stays Q with an exception.
