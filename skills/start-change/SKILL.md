---
name: start-change
description: Use to open a new unit of planned work — "start a change for X", "open a change", "new feature branch for X", or when /quick or /change-status routes here. Checks that main is clean and current, picks the lane, creates the branch and work/changes/<id>/change.md, and commits it. Q-sized work is sent to /quick instead.
argument-hint: "<change-id> [--lane S|F] [\"one-line intent\"]"
allowed-tools:
  - Read
  - Glob
  - Grep
  - Write
  - Bash
  - AskUserQuestion
---

# start-change

Everything later in the workflow — `/phase-plan`, `/plan-review`, `/drive` — assumes three
things exist: a branch that started from an up-to-date `main`, a folder at
`work/changes/<id>/`, and a `change.md` in it saying which lane the work is in. This skill
creates exactly those and nothing else. It writes no plan and no code.

## Inputs

- **Change id** — lowercase kebab-case, at most 40 characters, describing the outcome
  (`invoice-export`, not `feature-1`). It becomes the folder name, the branch name and the
  commit suffix, so it should read well in all three. If none was given, propose one from
  the intent and confirm it.
- **Intent** — one or two sentences on what will be different and for whom. Ask if it is
  missing; it goes into `change.md`.
- **Lane** — `--lane` if the user gave it; otherwise decided in step 2.

The id must be unused: no `work/changes/<id>/`, no `work/archive/<id>/`, no local or remote
branch `<id>`. If any exists, say which and stop — an existing change is resumed with
`/change-status`, not reopened.

## 1. Main must be clean and current

Run these from the main checkout (the parent of
`git rev-parse --path-format=absolute --git-common-dir`):

```bash
git status --porcelain --untracked-files=no     # must print nothing
git fetch -q origin 2>/dev/null                 # skip when there is no remote
git rev-list --count main..origin/main          # must be 0 when origin exists
```

- Uncommitted tracked changes → list them and stop. Do not stash or commit someone
  else's work to make room.
- Local `main` behind `origin/main` → offer `git switch main && git pull --ff-only`; if
  the user declines, stop. A change that starts from a stale main inherits a merge it did
  not need.
- The checkout is on another branch with a clean tree → fine; the new branch is created
  from `main` regardless of what is checked out.

## 2. Pick the lane

Decide from the intent and a quick look at the files it will likely touch. Reserved
surfaces are whatever the project marks as sensitive (its CLAUDE.md, and
`work/surface-globs.json` if present).

| Lane | When | What it gets |
| --- | --- | --- |
| **Q** | no reserved surface, roughly 300 changed lines or less | nothing from this skill — route to `/quick` and stop |
| **S** | touches a reserved surface, or is bigger than Q | plan of at most 250 lines, review lenses on risk-tagged phases |
| **F** | a wrong call would be expensive to undo: a new permission model, a data migration, several reserved surfaces at once, a new external integration | plan of at most 400 lines, optional research wave, `--deep` plan review |

When the lane is not obvious, ask one `AskUserQuestion` with your recommendation first and
a one-line reason per option. Surface beats size: a ten-line change to an access rule is
S, not Q.

## 3. Create the branch and the folder

```bash
base=origin/main; git rev-parse -q --verify origin/main >/dev/null || base=main
git switch -c <id> "$base"
mkdir -p work/changes/<id>
```

Write `work/changes/<id>/change.md`:

```markdown
# <id>

status: open
lane: <S|F>
created: <YYYY-MM-DD>
branch: <id>
updated: <YYYY-MM-DD>

## Intent

<two to four sentences: what will be different, for whom, and why now>

## Open decisions

- <each question that must be answered before or during planning — or "none">

## Out of scope

- <what someone might expect from this change that it will not do — or "nothing yet">
```

`status:` moves through `open → planned → plan-reviewed → in-progress → implemented` as
the later skills run. `branch:` is what the drive engine checks before it commits anything.

## 4. Commit it

Stage only the new folder:

```bash
git add work/changes/<id>/change.md
git commit -m "chore(<id>): open change"
```

Then one `AskUserQuestion`: push and open a draft PR now (recommended when the project
reviews through PRs) / keep it local for now. For a draft PR:

```bash
git push -u origin <id>
gh pr create --draft --base main --head <id> --title "<id>: <intent in a few words>"
```

## 5. Hand off

```
Change opened — <id>: lane <S|F> · branch <id> from <base> @ <short sha>
Folder: work/changes/<id>/change.md · Open decisions: <n>
Next: /prep <id>        (or /phase-plan <id> when there is nothing to research)
```

The branch is now checked out in this checkout. `/drive` will reuse it as is, or put it in
its own worktree if this checkout is needed for something else by then.
