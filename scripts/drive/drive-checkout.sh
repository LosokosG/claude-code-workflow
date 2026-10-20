#!/usr/bin/env bash
# Make a change's branch drivable and print the checkout to drive it from.
#
#   bash scripts/drive/drive-checkout.sh <change-id>
#
# The engine (`drive.sh`) runs on whatever checkout it is invoked in and never touches
# branches. The main checkout is shared by every session on the machine and is usually
# standing on some other branch, so a driven change gets its own linked worktree:
#
#   <main checkout>/.claude/worktrees/<change-id>     (gitignore it; the same place
#                                                     Claude Code puts its own worktrees)
#
# If the change's branch is ALREADY checked out somewhere (the main checkout right after
# /start-change, or an earlier worktree), that checkout is reused — git refuses to check
# one branch out twice, and a second copy would only drift.
#
# Idempotent — every step is "make it so", not "do it once":
#   1. find the change: `<work>/changes/<id>/change.md` in the main checkout's working
#      tree, else on the change's branch (`branch:` in change.md, else the id)
#   2. a checkout exists on that branch; the branch is created from origin/main when it
#      exists nowhere yet (local `main` when the repo has no remote)
#   3. main is merged in (a conflict aborts the merge and exits 3 — a human resolves
#      it; the engine never drives on top of a half-merge)
#   4. .env is present (copied from the main checkout; never printed)
#   5. dependencies match the lockfile (DRIVE_INSTALL_CMD, default `npm ci`, run through
#      `sfw` when it is installed; skipped while there is no package.json)
#   6. `<work>/setup-worktree.sh <id> <checkout>` when the project provides one (a
#      per-worktree database branch, ports, seeds — whatever the project needs)
#
# Last stdout line is the checkout path; everything else goes to stderr. Exit 2 on a
# usage/precondition failure, 3 on a merge conflict.
set -uo pipefail

CHANGE_ID="${1:?usage: drive-checkout.sh <change-id>}"
say() { echo "drive-checkout: $*" >&2; }

common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || { say "not inside a git checkout"; exit 2; }
MAIN="$(dirname "$common")"
WORK="${DRIVE_WORK_DIR:-work}"; WORK="${WORK%/}"
CHANGE_REL="$WORK/changes/$CHANGE_ID"

# ---------------------------------------------------------------- 1. the change
BRANCH=""
if [ -f "$MAIN/$CHANGE_REL/change.md" ]; then
  BRANCH="$(sed -n 's/^branch:[[:space:]]*//p' "$MAIN/$CHANGE_REL/change.md" | head -1 | tr -d '[:space:]')"
elif git -C "$MAIN" show-ref -q --verify "refs/heads/$CHANGE_ID" \
     && git -C "$MAIN" cat-file -e "$CHANGE_ID:$CHANGE_REL/change.md" 2>/dev/null; then
  BRANCH="$(git -C "$MAIN" show "$CHANGE_ID:$CHANGE_REL/change.md" | sed -n 's/^branch:[[:space:]]*//p' | head -1 | tr -d '[:space:]')"
else
  say "no change at $CHANGE_REL/ — not in the main checkout ($MAIN) and not on a branch named '$CHANGE_ID'"
  exit 2
fi
BRANCH="${BRANCH:-$CHANGE_ID}"
case "$BRANCH" in main | master) say "change.md names '$BRANCH' as its branch — a drive never commits to it"; exit 2 ;; esac

HAS_ORIGIN=0
if git -C "$MAIN" remote get-url origin >/dev/null 2>&1; then
  HAS_ORIGIN=1
  git -C "$MAIN" fetch -q origin || say "fetch failed — continuing with what is local"
else
  say "no 'origin' remote — branching from and merging local main"
fi
# The integration ref: origin/main when there is a remote, the local main otherwise.
BASE_REF=""
if [ "$HAS_ORIGIN" = 1 ] && git -C "$MAIN" show-ref -q --verify refs/remotes/origin/main; then
  BASE_REF=origin/main
elif git -C "$MAIN" show-ref -q --verify refs/heads/main; then
  BASE_REF=main
fi

# ---------------------------------------------------------------- 2. the checkout
# Where is BRANCH checked out right now, if anywhere?
WT="$(git -C "$MAIN" worktree list --porcelain | awk -v b="refs/heads/$BRANCH" '
  /^worktree / { wt = substr($0, 10) }
  $0 == "branch " b { print wt; exit }')"
if [ -n "$WT" ]; then
  say "branch $BRANCH is already checked out at $WT — reusing it"
else
  WT="$MAIN/.claude/worktrees/$CHANGE_ID"
  if git -C "$MAIN" show-ref -q --verify "refs/heads/$BRANCH"; then
    say "adding worktree for existing branch $BRANCH"
    git -C "$MAIN" worktree add -q "$WT" "$BRANCH" || exit 2
  elif [ "$HAS_ORIGIN" = 1 ] && git -C "$MAIN" show-ref -q --verify "refs/remotes/origin/$BRANCH"; then
    say "adding worktree for origin/$BRANCH"
    git -C "$MAIN" worktree add -q --track -b "$BRANCH" "$WT" "origin/$BRANCH" || exit 2
  else
    [ -n "$BASE_REF" ] || { say "branch $BRANCH exists nowhere and there is no main to branch from"; exit 2; }
    say "branch $BRANCH exists nowhere yet — creating it from $BASE_REF"
    git -C "$MAIN" worktree add -q -b "$BRANCH" "$WT" "$BASE_REF" || exit 2
  fi
fi

# A dirty checkout means a previous run (or a human) left work uncommitted; merging on
# top of it would tangle that work with main's. Say so and stop.
if [ -n "$(git -C "$WT" status --porcelain --untracked-files=no)" ]; then
  say "checkout $WT has uncommitted changes — commit or discard them first:"
  git -C "$WT" status --short --untracked-files=no >&2
  exit 2
fi

# ---------------------------------------------------------------- 3. main merged in
if [ -n "$BASE_REF" ]; then
  behind="$(git -C "$WT" rev-list --count "$BRANCH..$BASE_REF" 2>/dev/null || echo 0)"
  if [ "${behind:-0}" -gt 0 ]; then
    say "merging $BASE_REF ($behind commits) into $BRANCH"
    if ! git -C "$WT" merge -q --no-edit "$BASE_REF" >/dev/null 2>&1; then
      git -C "$WT" merge --abort 2>/dev/null
      say "CONFLICT merging $BASE_REF into $BRANCH — resolve it in $WT and re-run"
      exit 3
    fi
  fi
fi

# ---------------------------------------------------------------- 4. env file
if [ "$WT" != "$MAIN" ] && [ ! -f "$WT/.env" ] && [ -f "$MAIN/.env" ]; then
  cp "$MAIN/.env" "$WT/.env" && say "copied .env from the main checkout (never paste its contents into a chat)"
fi

# ---------------------------------------------------------------- 5. dependencies
if [ ! -f "$WT/package.json" ]; then
  say "no package.json — skipping dependency install"
elif [ ! -f "$WT/node_modules/.package-lock.json" ] \
     || { [ -f "$WT/package-lock.json" ] && [ "$WT/package-lock.json" -nt "$WT/node_modules/.package-lock.json" ]; }; then
  install="${DRIVE_INSTALL_CMD:-npm ci --no-audit --no-fund}"
  # A package manager wrapper that vets installs (Socket Firewall's `sfw`) is used when it
  # is present: a bare install runs every package's lifecycle scripts with this user's
  # credentials.
  [ -z "${DRIVE_INSTALL_CMD:-}" ] && command -v sfw >/dev/null 2>&1 && install="sfw $install"
  say "installing dependencies ($install)"
  (cd "$WT" && eval "$install" >/dev/null 2>&1) || { say "'$install' failed in $WT"; exit 2; }
fi

# ---------------------------------------------------------------- 6. project setup hook
if [ -f "$MAIN/$WORK/setup-worktree.sh" ]; then
  say "project setup: $WORK/setup-worktree.sh $CHANGE_ID $WT"
  (cd "$WT" && bash "$MAIN/$WORK/setup-worktree.sh" "$CHANGE_ID" "$WT") \
    || { say "$WORK/setup-worktree.sh failed — fix it or remove it, then re-run"; exit 2; }
fi

echo "$WT"
