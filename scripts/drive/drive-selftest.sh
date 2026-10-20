#!/usr/bin/env bash
# drive engine self-test.
#
# Deterministic checks, all inside a throwaway git repository under $TMPDIR, so nothing
# here can touch a real checkout. Most checks run with DRIVE_STEP_STUB=1: no model is
# called, but every side effect is real — files created, Progress rows flipped, commits
# made, locks taken and released, children killed. That is the point: the assertions are
# about the engine's behaviour, not about a mock's value.
#
# Checks 22 and 23 do NOT stub the engine. They drive a real phase against a shimmed
# `claude` binary that records its argv, writes real files and returns a canned
# structured_output, because the thing under test is the command line the backend builds,
# the parsing that follows it, and the wall-clock timeout around it.
#
# The `claude` shim sits on PATH for the WHOLE run and logs every invocation with the
# step that made it. That log is what turns "the orchestrator spends no tokens" from a
# printed claim into a measurement: any model call without a step marker is a call the
# orchestrator made itself.
#
#   bash scripts/drive/drive-selftest.sh              all 26 deterministic checks
#   bash scripts/drive/drive-selftest.sh --real       plus one real phase on the installed
#                                                     `claude` CLI (spends tokens)
#   bash scripts/drive/drive-selftest.sh --only 4,6   narrow to the listed checks
#
# Needs: git, bash 4+, node. No package.json, no network, no origin remote.
set -uo pipefail

ENGINE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_SRC="$(cd "$ENGINE_SRC/.." && pwd)"
STAMP="$(date +%Y%m%d%H%M%S)-$$"
WT="${TMPDIR:-/tmp}/drive-selftest-$STAMP"
# OUTSIDE the toy repo on purpose: `reset_toy` runs `git clean -fd`, which removes every
# untracked path under $WT — including the shim dir.
SHIM="${TMPDIR:-/tmp}/drive-selftest-$STAMP.shim"
MODEL_CALLS="${TMPDIR:-/tmp}/drive-selftest-$STAMP.model-calls.log"
RUN_REAL=0
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --real) RUN_REAL=1 ;;
    --no-real) RUN_REAL=0 ;;
    --only) ONLY="$2"; shift ;;
  esac
  shift
done
skip() { [ -n "$ONLY" ] && ! printf '%s' ",$ONLY," | grep -q ",$1,"; }

PASS=0; FAIL=0; RESULTS=()
check() {
  local n="$1" desc="$2" ok="$3" detail="${4:-}"
  if [ "$ok" = 0 ]; then
    RESULTS+=("$(printf '%2d. PASS  %s' "$n" "$desc")"); PASS=$((PASS + 1))
  else
    RESULTS+=("$(printf '%2d. FAIL  %s%s' "$n" "$desc" "${detail:+  — $detail}")"); FAIL=$((FAIL + 1))
  fi
}

cleanup() {
  [ -n "${DRIVE_SELFTEST_KEEP:-}" ] && { echo "drive-selftest: toy repo kept at $WT (shims: $SHIM)"; return; }
  rm -rf "$WT" "$SHIM" "$SHIM.real" "$MODEL_CALLS"
}
trap cleanup EXIT

echo "drive-selftest: toy repo $WT"
mkdir -p "$WT" "$SHIM"
git -C "$WT" init -q -b main
git -C "$WT" config user.name "drive selftest"
git -C "$WT" config user.email "selftest@example.invalid"
git -C "$WT" config commit.gpgsign false

# The engine is vendored into the toy repo exactly as a project would vendor it.
install_engine() {
  mkdir -p "$WT/scripts/drive/schemas" "$WT/scripts/drive/stubs" "$WT/scripts/lib"
  cp "$ENGINE_SRC"/drive*.sh "$ENGINE_SRC"/drive-*.mjs "$WT/scripts/drive/"
  cp "$ENGINE_SRC"/schemas/*.json "$WT/scripts/drive/schemas/"
  cp "$ENGINE_SRC"/stubs/*.json "$WT/scripts/drive/stubs/"
  cp "$SCRIPTS_SRC"/check-plan-progress.mjs "$WT/scripts/"
  cp "$SCRIPTS_SRC"/lib/plan-format.mjs "$WT/scripts/lib/"
  chmod +x "$WT"/scripts/drive/*.sh
  return 0
}
install_engine
mkdir -p "$WT/work"
: >"$WT/work/proposed-lessons.md"
printf '{ "surfaces": ["db/migrations/**"] }\n' >"$WT/work/surface-globs.json"
printf 'work/changes/*/drive/\n.claude/worktrees/\nlast-run.log\n*.log\n' >"$WT/.gitignore"
git -C "$WT" add -A >/dev/null 2>&1
git -C "$WT" -c core.hooksPath=/dev/null commit -qm "chore: vendored drive engine" >/dev/null 2>&1
git -C "$WT" checkout -q -b toy

# `systemctl` is shimmed so check 12 can assert that a limit pause never schedules a
# poweroff — an assertion you cannot make by reading the code.
cat >"$SHIM/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >>"$SHIM/systemctl-calls.log"
EOF
chmod +x "$SHIM/systemctl"
# systemd-inhibit is skipped: the re-exec would lose the shimmed PATH and the test's env.
cat >"$SHIM/systemd-inhibit" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in --*) shift ;; *) break ;; esac; done
exec "$@"
EOF
chmod +x "$SHIM/systemd-inhibit"

# The `claude` shim. It logs WHO dispatched it (DRIVE_IN_STEP is exported by run_step
# around a backend call, so an invocation logged as ORCHESTRATOR is a model call nobody
# attributed to a step), then answers the way the real CLI does for `--output-format
# json`: an envelope whose structured_output matches the schema it was given. The
# implement shape has a real side effect — files, a Progress flip, a commit — so the
# engine downstream cannot tell it from a model. SELFTEST_CLAUDE_SLEEP makes it hang
# first, which is the window the timeout check needs.
: >"$MODEL_CALLS"
cat >"$SHIM/claude" <<EOF
#!/usr/bin/env bash
{ printf 'claude|%s|%s|' "\${DRIVE_IN_STEP:-ORCHESTRATOR}" "\$PPID"
  printf '%s ' "\$@" | tr '\n' ' '; printf '\n'; } >>"$MODEL_CALLS"
[ -n "\${SELFTEST_CLAUDE_SLEEP:-}" ] && sleep "\$SELFTEST_CLAUDE_SLEEP"
schema=""; prev=""
for a in "\$@"; do
  case "\$prev" in --json-schema) schema="\$a" ;; esac
  prev="\$a"
done
case "\$schema" in
  *"Implementation step result"*)
    mkdir -p "$WT/src"
    printf 'export const toy = 1;\n' >"$WT/src/toy.ts"
    printf 'import { toy } from "./toy";\nexpect(toy).toBe(1);\n' >"$WT/src/toy.test.ts"
    node -e '
      const fs=require("fs"); const p=process.argv[1];
      fs.writeFileSync(p, fs.readFileSync(p,"utf8").replace(/^(\|\s*P1[^|]*\|\s*)\[ \]/m, "\$1[x]"));
    ' "$WT/work/changes/toy/plan.md"
    git -C "$WT" -c core.hooksPath=/dev/null add -- src/toy.ts src/toy.test.ts work/changes/toy/plan.md >/dev/null 2>&1
    git -C "$WT" -c core.hooksPath=/dev/null commit -qm "feat(toy): toy module (toy p1)" >/dev/null 2>&1
    sha="\$(git -C "$WT" rev-parse --short HEAD)"
    printf '{"is_error":false,"total_cost_usd":0.42,"permission_denials":[],"structured_output":{"status":"committed","commit_sha":"%s","touched_files":["src/toy.ts","src/toy.test.ts"],"out_of_scope":[],"diff_lines":4,"gate_recorded":true,"notes":"claude shim implement"}}\n' "\$sha"
    ;;
  *"Implementation review result"*)
    printf '{"is_error":false,"total_cost_usd":0.11,"structured_output":{"verdict":"APPROVED","phase":"1","base":"HEAD~1","head":"HEAD","gate_recorded":true,"findings":[],"observations":[]}}\n'
    ;;
  *"Fixer step result"*)
    printf '{"is_error":false,"total_cost_usd":0.05,"structured_output":{"finding_id":"T1","applied":true,"commit_sha":null,"touched_files":["src/toy.ts"],"declared_extra":[],"note":"claude shim fix"}}\n'
    ;;
  *"Live verification result"*)
    printf '{"is_error":false,"total_cost_usd":0.07,"structured_output":{"verdict":"SKIPPED","flows":[],"screenshots":[],"db_asserts":[],"notes":"claude shim verify"}}\n'
    ;;
  *"Ask result"*)
    printf '{"is_error":false,"total_cost_usd":0.01,"structured_output":{"answer":"SHIM ANSWER","evidence":[]}}\n'
    ;;
  *)
    printf '{"is_error":false,"structured_output":null,"result":"{}"}\n'
    ;;
esac
exit 0
EOF
chmod +x "$SHIM/claude"

TOY="$WT/work/changes/toy"
mkdir -p "$TOY"
cat >"$TOY/change.md" <<'EOF'
# toy

status: plan-reviewed
lane: S
branch: toy
created: 2026-10-08
updated: 2026-10-08

Throwaway change used by drive-selftest.sh. Never committed to a real branch.
EOF

# A plan that also passes scripts/check-plan-progress.mjs (check 24 proves it): one
# unflagged row, one row flagged by its `risk:` line, and one row that claims `risk: none`
# but touches a reserved surface (a migration) — the surface list has to flag it.
write_plan() {
  cat >"$TOY/plan.md" <<'EOF'
# toy — plan

Lane: S. Fixture plan for the drive engine self-test.

## Phases

### P1 — Toy module

Changes: create `src/toy.ts` exporting `export const toy = 1;` and a unit test next to it
at `src/toy.test.ts` asserting it equals 1. Nothing else — no barrel export, no README,
no refactor of anything nearby.
Done when: `node --test src/toy.test.ts` passes.
Verify: import `toy` from `src/toy.ts` in a node REPL and read `1`.
route: implement
risk: none
paths: `src/toy.ts`, `src/toy.test.ts`
size: 50

### P2 — Toy contract

Changes: one exported schema in `src/contracts/toy.ts`.
Done when: the file exists and the project's type check passes.
route: implement
risk: data
paths: `src/contracts/toy.ts`
size: 50

### P3 — Toy migration

Changes: one migration file, so the reserved-surface list has something to fire on.
Done when: `db/migrations/0001_toy.sql` exists.
route: implement
risk: none
paths: `db/migrations/0001_toy.sql`
size: 50

## Progress

| Phase                 | Status | Notes |
| --------------------- | ------ | ----- |
| P1 Toy module         | [ ]    |       |
| P2 Toy contract       | [ ]    |       |
| P3 Toy migration      | [ ]    |       |

## Drive Readiness

Fixture only. parallel-safe: no.
EOF
  git -C "$WT" add -f work/changes/toy >/dev/null 2>&1
  git -C "$WT" -c core.hooksPath=/dev/null commit -qm "test(toy): fixture plan" >/dev/null 2>&1
}

reset_toy() {
  git -C "$WT" -c core.hooksPath=/dev/null reset -q --hard "$BASE_SHA" >/dev/null 2>&1
  git -C "$WT" clean -qfd >/dev/null 2>&1
  rm -rf "$TOY/drive" "$TOY/drive-log.md"
  rm -rf "$(git -C "$WT" rev-parse --absolute-git-dir)/drive-toy.lock.d"
  write_plan
}

write_plan
git -C "$WT" -c core.hooksPath=/dev/null tag -f selftest-base >/dev/null 2>&1
BASE_SHA="$(git -C "$WT" rev-parse selftest-base)"

drive() {
  ( cd "$WT" && PATH="$SHIM:$PATH" DRIVE_STEP_STUB=1 DRIVE_LIMIT_MARGIN_SECONDS=1 \
      DRIVE_LIMIT_POLL_SECONDS=3 "$@" bash scripts/drive/drive.sh toy "${DRIVE_ARGS[@]}" ) \
    >"$WT/last-run.log" 2>&1
}
ctl() { ( cd "$WT" && PATH="$SHIM:$PATH" bash scripts/drive/drive-ctl.sh "$@" ); }
progress_of() { sed -n "s/^|[[:space:]]*P$1[^|]*|[[:space:]]*\[\(.\)\].*/\1/p" "$TOY/plan.md" | head -1; }
TOY_TS="$WT/src/toy.ts"
lockf() { printf '%s/drive-toy.lock.d' "$(git -C "$WT" rev-parse --absolute-git-dir)"; }

# ---------------------------------------------------------------- 1
if ! skip 1; then
reset_toy
DRIVE_ARGS=(through 3)
drive env; rc=$?
ok=1
if [ "$(progress_of 1)" = x ] && [ "$(progress_of 2)" = x ] && [ "$(progress_of 3)" = x ] \
   && [ -f "$TOY_TS" ] && [ -f "$WT/src/toy.test.ts" ] \
   && [ -f "$WT/src/contracts/toy.ts" ] && [ -f "$WT/db/migrations/0001_toy.sql" ] \
   && [ -n "$(git -C "$WT" log --oneline -- db/migrations/0001_toy.sql 2>/dev/null | head -1)" ] \
   && grep -q 'DISPATCH implement p1' "$TOY/drive-log.md" && grep -q 'DISPATCH review-safety p2' "$TOY/drive-log.md" \
   && grep -q 'DISPATCH review-safety p3' "$TOY/drive-log.md" && ! grep -q 'DISPATCH review-safety p1' "$TOY/drive-log.md" \
   && grep -q 'RESULT implement p3' "$TOY/drive-log.md" && grep -q '## Hand-back' "$TOY/drive-log.md"; then
  ok=0
fi
check 1 "three phases land IN THE BRANCH (files + commits), Progress rows flip, both lenses run on the risk-tagged row AND on the row the surface list flagged, none on the plain row, hand-back written" "$ok" "rc=$rc rows=$(progress_of 1)$(progress_of 2)$(progress_of 3)"

fi

# ---------------------------------------------------------------- 2
if ! skip 2; then
reset_toy
( cd "$WT" && PATH="$SHIM:$PATH" DRIVE_STEP_STUB=1 bash scripts/drive/drive.sh toy phase 1 ) >/dev/null 2>&1
touch "$TOY/drive/pause.flag"
( cd "$WT" && PATH="$SHIM:$PATH" DRIVE_STEP_STUB=1 bash scripts/drive/drive.sh toy through 3 ) >/dev/null 2>&1 &
bgpid=$!
LOCKF="$(lockf)"
for _ in $(seq 1 40); do [ -s "$TOY/drive/state.json" ] && grep -q paused "$TOY/drive/state.json" && break; sleep 0.5; done
# kill -9 the ENGINE, not the subshell wrapping it — an orphaned drive.sh would keep
# writing the plan under the later checks and make them nondeterministic.
kill -9 "$(sed -n 's/^pid=//p' "$LOCKF/meta" 2>/dev/null)" 2>/dev/null
kill -9 "$bgpid" 2>/dev/null; wait "$bgpid" 2>/dev/null
rm -f "$TOY/drive/pause.flag"
before="$(progress_of 2)"
( cd "$WT" && PATH="$SHIM:$PATH" DRIVE_STEP_STUB=1 bash scripts/drive/drive.sh toy through 3 ) >"$WT/resume.log" 2>&1
ok=1
[ "$before" = " " ] && [ "$(progress_of 1)" = x ] && [ "$(progress_of 2)" = x ] && [ "$(progress_of 3)" = x ] \
  && grep -q 'stale lock' "$WT/resume.log" && ok=0
check 2 "resume after kill -9 reclaims the lock and continues at the next open row" "$ok" "p2 was '$before'"

fi

# ---------------------------------------------------------------- 3
if ! skip 3; then
reset_toy
mkdir -p "$TOY/drive"; touch "$TOY/drive/pause.flag"
( cd "$WT" && PATH="$SHIM:$PATH" DRIVE_STEP_STUB=1 bash scripts/drive/drive.sh toy through 3 ) >/dev/null 2>&1 &
bgpid=$!
LOCKF="$(lockf)"
for _ in $(seq 1 40); do [ -e "$LOCKF" ] && break; sleep 0.5; done
had_lock=$([ -e "$LOCKF" ] && echo yes || echo no)
ctl stop toy >/dev/null 2>&1
wait "$bgpid" 2>/dev/null
ok=1
[ "$had_lock" = yes ] && [ ! -e "$LOCKF" ] && ! kill -0 "$bgpid" 2>/dev/null && ok=0
check 3 "stop halts the run and releases the lock" "$ok" "lock-was=$had_lock lock-now=$([ -e "$LOCKF" ] && echo present || echo gone)"

fi

# ---------------------------------------------------------------- 4
if ! skip 4; then
reset_toy
DRIVE_ARGS=(phase 2)
drive env DRIVE_STUB_VARIANT_review=critical; rc=$?
ok=1
[ "$rc" = 3 ] && [ -f "$TOY/drive/needs-input.md" ] \
  && grep -q 'survived one fix pass and one re-review' "$TOY/drive/needs-input.md" \
  && grep -q 'DISPATCH fix p2' "$TOY/drive-log.md" \
  && grep -q 'DISPATCH rereview p2' "$TOY/drive-log.md" && ok=0
check 4 "CRITICAL → fixer → re-review → still CRITICAL → needs-input, exit 3" "$ok" "rc=$rc"

fi

# ---------------------------------------------------------------- 5
if ! skip 5; then
reset_toy
DRIVE_ARGS=(phase 1)
drive env DRIVE_STUB_VARIANT_implement=unplanned DRIVE_STUB_VARIANT_fix=unplanned; rc=$?
ok=1
grep -q '"unplanned' "$TOY/drive/triage-p1.json" 2>/dev/null \
  && grep -q 'sneaky' "$TOY/drive/triage-p1.json" && ok=0
undeclared_ok=$ok
reset_toy
drive env DRIVE_STUB_VARIANT_implement=declared; rc2=$?
declared_findings="$(node -pe 'try{JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).findings.length}catch{0}' "$TOY/drive/triage-p1.json" 2>/dev/null || echo 0)"
[ "$undeclared_ok" = 0 ] && [ "${declared_findings:-0}" = 0 ] && ok=0 || ok=1
check 5 "undeclared out-of-scope file → 'unplanned' WARNING; a declared one passes through" "$ok" "declared findings=$declared_findings"

fi

# ---------------------------------------------------------------- 6
if ! skip 6; then
reset_toy
DRIVE_ARGS=(phase 2)
drive env DRIVE_STUB_VARIANT_review=critical DRIVE_STUB_VARIANT_fix=outoffence; rc=$?
ok=1
grep -q 'REJECTED — touched a file outside the fence' "$TOY/drive-log.md" \
  && [ "$(grep -c 'DISPATCH fix p2' "$TOY/drive-log.md")" -ge 2 ] && ok=0
check 6 "fixer touching an undeclared extra file is rejected once and re-dispatched" "$ok"

fi

# ---------------------------------------------------------------- 7
# A usage limit: the run records it, sleeps to the stated reset plus the margin, and
# resumes by itself — the only limit path a single-provider engine has.
if ! skip 7; then
reset_toy
DRIVE_ARGS=(phase 1)
drive env CLAUDE_LIMIT_SIMULATE=1 DRIVE_FAKE_RESET_SECONDS=3; rc=$?
waits="$(grep -c 'LIMIT-WAIT' "$TOY/drive-log.md" 2>/dev/null)"
remembered="$(node -pe 'try{const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));s.claude?.until?"yes":"no"}catch{"none"}' "$TOY/drive/limits.json" 2>/dev/null)"
ok=1
[ "$rc" = 0 ] && [ "${waits:-0}" = 1 ] && grep -q 'sleeping 4s (reset + 1s margin)' "$TOY/drive-log.md" \
  && [ "$remembered" = yes ] && [ "$(progress_of 1)" = x ] && ok=0
check 7 "Claude limited: ONE sleep to reset + margin, the limit is remembered in limits.json, then the step self-resumes" "$ok" "rc=$rc waits=$waits remembered=$remembered"

fi

# ---------------------------------------------------------------- 8
if ! skip 8; then
reset_toy
DRIVE_ARGS=(phase 2)
drive env DRIVE_MODEL_review=sonnet DRIVE_MODEL_implement=opus; rc=$?
ok=1
{ grep -q 'floor violation' "$TOY/drive-log.md" || grep -q 'floor violation' "$WT/last-run.log"; } \
  && [ -f "$TOY/drive/needs-input.md" ] && ok=0
check 8 "a reviewer below the implementer's tier is refused with the floor error" "$ok" "rc=$rc"

fi

# ---------------------------------------------------------------- 9
if ! skip 9; then
reset_toy
DRIVE_ARGS=(phase 1)
drive env DRIVE_STUB_VARIANT_implement=budget; rc=$?
ok=1
[ "$rc" = 3 ] && grep -q 'budget-kill → reset + retry' "$TOY/drive-log.md" \
  && [ ! -f "$TOY_TS" ] \
  && grep -q 'budget-kill twice' "$TOY/drive/needs-input.md" && ok=0
check 9 "budget-kill resets the step's paths, retries once at a doubled cap, then needs-input" "$ok" "rc=$rc toy.ts=$([ -f "$TOY_TS" ] && echo present || echo reset)"

fi

# ---------------------------------------------------------------- 10
if ! skip 10; then
reset_toy
ctl steer toy "use X, not Y" >/dev/null 2>&1
DRIVE_ARGS=(phase 1)
drive env; rc=$?
steered=1
grep -q 'use X, not Y' "$TOY/drive/prompt-implement-p1.txt" 2>/dev/null \
  && ls "$TOY/drive"/steer-consumed-*.md >/dev/null 2>&1 && steered=0
asked=1
( cd "$WT" && PATH="$SHIM:$PATH" DRIVE_STEP_STUB=1 bash scripts/drive/drive-ctl.sh ask toy "did phase 1 land?" ) \
  >"$WT/ask.log" 2>&1
grep -q 'STUB ANSWER' "$WT/ask.log" && asked=0
ok=1; [ "$steered" = 0 ] && [ "$asked" = 0 ] && ok=0
check 10 "steer text reaches the next step's prompt and is archived; ask returns an answer" "$ok" "steer=$steered ask=$asked"

fi

# ---------------------------------------------------------------- 11
if ! skip 11; then
reset_toy
mkdir -p "$TOY/drive"
LESS="$WT/work/proposed-lessons.md"
before_lines=$(wc -l <"$LESS" 2>/dev/null || echo 0)
( cd "$WT" && node scripts/drive/drive-triage.mjs --phase 9 --out "$TOY/drive/triage-obs.json" \
    --review scripts/drive/stubs/review-observations.json ) >/dev/null 2>&1
trc=$?
n_findings="$(node -pe 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).findings.length' "$TOY/drive/triage-obs.json" 2>/dev/null)"
after_lines=$(wc -l <"$LESS" 2>/dev/null || echo 0)
ok=1
[ "$trc" = 0 ] && [ "$n_findings" = 0 ] && [ "$after_lines" -gt "$before_lines" ] && ok=0
check 11 "triage never actions an OBSERVATION; it files them to proposed-lessons" "$ok" "rc=$trc findings=$n_findings lessons +$((after_lines - before_lines))"

fi

# ---------------------------------------------------------------- 12
if ! skip 12; then
reset_toy
: >"$SHIM/systemctl-calls.log"
( cd "$WT" && PATH="$SHIM:$PATH" DRIVE_STEP_STUB=1 CLAUDE_LIMIT_SIMULATE=1 \
    DRIVE_FAKE_RESET_SECONDS=600 DRIVE_LIMIT_MARGIN_SECONDS=1 bash scripts/drive/drive.sh toy phase 1 --shutdown ) >/dev/null 2>&1 &
bgpid=$!
LOCKF="$(lockf)"
for _ in $(seq 1 60); do grep -q 'LIMIT-WAIT' "$TOY/drive-log.md" 2>/dev/null && break; sleep 0.5; done
paused_ok=$(grep -q 'LIMIT-WAIT' "$TOY/drive-log.md" 2>/dev/null && echo 0 || echo 1)
calls=$(wc -c <"$SHIM/systemctl-calls.log")
ctl stop toy >/dev/null 2>&1
kill -9 "$(sed -n 's/^pid=//p' "$LOCKF/meta" 2>/dev/null)" 2>/dev/null
kill -9 "$bgpid" 2>/dev/null; wait "$bgpid" 2>/dev/null
ok=1
[ "$paused_ok" = 0 ] && [ "$calls" = 0 ] && ok=0
check 12 "--shutdown never schedules a poweroff during a limit pause" "$ok" "limit-wait=$paused_ok systemctl-bytes=$calls"

fi

# ---------------------------------------------------------------- 13
if ! skip 13; then
reset_toy
DRIVE_ARGS=(phase 2)
drive env DRIVE_STUB_VARIANT_review=critical DRIVE_STUB_VARIANT_fix=declined; rc=$?
ok=1
[ "$rc" = 3 ] \
  && [ "$(grep -c 'DISPATCH fix p2' "$TOY/drive-log.md")" -ge 2 ] \
  && grep -q 'DECLINED' "$TOY/drive-log.md" \
  && grep -q 'UNFIXED after two dispatches' "$TOY/drive-log.md" \
  && ! grep -q 'T1 applied' "$TOY/drive-log.md" \
  && grep -q 'declined CRITICAL finding' "$TOY/drive/needs-input.md" && ok=0
check 13 "a fixer returning applied:false is re-dispatched once, then escalated — never logged as applied" "$ok" "rc=$rc"

fi

# ---------------------------------------------------------------- 14
# Stage-level resume. Phase 2 is risk-flagged, so it has a review stage to re-enter at;
# DRIVE_STUB_SLEEP_review is the window the kill needs.
if ! skip 14; then
reset_toy
( cd "$WT" && PATH="$SHIM:$PATH" DRIVE_STEP_STUB=1 DRIVE_STUB_SLEEP_review=8 \
    bash scripts/drive/drive.sh toy phase 2 ) >"$WT/resume-stage.log" 2>&1 &
bgpid=$!
LOCKF="$(lockf)"
for _ in $(seq 1 80); do grep -q 'DISPATCH review-drift p2' "$TOY/drive-log.md" 2>/dev/null && break; sleep 0.25; done
enginepid="$(sed -n 's/^pid=//p' "$LOCKF/meta" 2>/dev/null)"
for kid in $(pgrep -P "${enginepid:-0}" 2>/dev/null); do kill -9 "$kid" 2>/dev/null; done
kill -9 "${enginepid:-0}" 2>/dev/null
kill -9 "$bgpid" 2>/dev/null; wait "$bgpid" 2>/dev/null
row_after_kill="$(progress_of 2)"
stage_after_kill="$(node -pe 'try{JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).phases["2"]}catch{""}' "$TOY/drive/state.json" 2>/dev/null)"
impl_before="$(grep -c 'DISPATCH implement p2' "$TOY/drive-log.md" 2>/dev/null)"
rev_before="$(grep -c 'DISPATCH review-drift p2' "$TOY/drive-log.md" 2>/dev/null)"
( cd "$WT" && PATH="$SHIM:$PATH" DRIVE_STEP_STUB=1 bash scripts/drive/drive.sh toy phase 2 ) >"$WT/resume-stage2.log" 2>&1
impl_after="$(grep -c 'DISPATCH implement p2' "$TOY/drive-log.md" 2>/dev/null)"
rev_after="$(grep -c 'DISPATCH review-drift p2' "$TOY/drive-log.md" 2>/dev/null)"
ok=1
[ "$row_after_kill" = x ] && [ "$stage_after_kill" = implemented ] \
  && grep -q 'resuming at review' "$TOY/drive-log.md" \
  && grep -q 'resuming unfinished review/fix stage(s) on phase(s): 2' "$WT/resume-stage2.log" \
  && [ "${impl_before:-0}" = "${impl_after:-9}" ] \
  && [ "${rev_after:-0}" -gt "${rev_before:-9}" ] && ok=0
check 14 "a kill between implement and review resumes AT review — the [x] row is not re-implemented" "$ok" \
  "row=$row_after_kill stage=$stage_after_kill implement ${impl_before:-?}→${impl_after:-?} review-drift ${rev_before:-?}→${rev_after:-?}"

fi

# ---------------------------------------------------------------- 15
# `stop` kills the running child BEFORE it releases ownership. Ordering is observed with
# timestamps, not read off a log line the script prints unconditionally.
if ! skip 15; then
reset_toy
( cd "$WT" && PATH="$SHIM:$PATH" DRIVE_STEP_STUB=1 DRIVE_STUB_SLEEP_implement=40 \
    bash scripts/drive/drive.sh toy phase 1 ) >/dev/null 2>&1 &
bgpid=$!
LOCKF="$(lockf)"
enginepid=""; childpid=""
for _ in $(seq 1 80); do
  enginepid="$(sed -n 's/^pid=//p' "$LOCKF/meta" 2>/dev/null)"
  [ -n "$enginepid" ] && childpid="$(pgrep -P "$enginepid" 2>/dev/null | head -1)"
  [ -n "$childpid" ] && break
  sleep 0.25
done
ORDER="$WT/stop-order.txt"; : >"$ORDER"
( cgone=""; lgone=""
  for _ in $(seq 1 2000); do
    [ -z "$cgone" ] && ! kill -0 "${childpid:-0}" 2>/dev/null && { cgone=$(date +%s%N); echo "child=$cgone" >>"$ORDER"; }
    [ -z "$lgone" ] && [ ! -e "$LOCKF" ] && { lgone=$(date +%s%N); echo "lock=$lgone" >>"$ORDER"; }
    [ -n "$cgone" ] && [ -n "$lgone" ] && break
    sleep 0.01
  done ) &
watcher=$!
ctl stop toy >/dev/null 2>&1
wait "$watcher" 2>/dev/null
kill -9 "$bgpid" 2>/dev/null; wait "$bgpid" 2>/dev/null
child_ts="$(sed -n 's/^child=//p' "$ORDER" | head -1)"
lock_ts="$(sed -n 's/^lock=//p' "$ORDER" | head -1)"
ok=1
[ -n "$childpid" ] && [ -n "$child_ts" ] && [ -n "$lock_ts" ] && [ "$child_ts" -le "$lock_ts" ] \
  && ! kill -0 "${childpid:-0}" 2>/dev/null && [ ! -e "$LOCKF" ] && ok=0
check 15 "stop terminates the step's running child BEFORE the lock dir is released (timestamp order)" "$ok" \
  "child=${childpid:-none} child_gone=${child_ts:-never} lock_gone=${lock_ts:-never}"

fi

# ---------------------------------------------------------------- 16
# A budget kill must restore what the USER had in the scope, not just delete what the step
# left. Check 9 kills a step over a CLEAN tree, so the snapshot half is exercised here.
if ! skip 16; then
reset_toy
mkdir -p "$WT/src"
printf 'export const toy = 0; // human WIP, untracked\n' >"$TOY_TS"
toy_before="$(md5sum <"$TOY_TS")"
DRIVE_ARGS=(phase 1)
drive env DRIVE_STUB_VARIANT_implement=budget; rc=$?
toy_after="$([ -f "$TOY_TS" ] && md5sum <"$TOY_TS" || echo GONE)"
ok=1
[ "$rc" = 3 ] && [ "$toy_before" = "$toy_after" ] \
  && grep -q 'budget-kill → reset + retry' "$TOY/drive-log.md" && ok=0
check 16 "a budget kill restores a pre-existing dirty file in scope byte-identical" "$ok" \
  "rc=$rc toy.ts=$([ "$toy_before" = "$toy_after" ] && echo intact || echo "$toy_after")"

fi

# ---------------------------------------------------------------- 17
if ! skip 17; then
reset_toy
mkdir -p "$TOY/drive"
ctl steer toy "do not lose me" >/dev/null 2>&1
steer_before="$(md5sum <"$TOY/drive/steer.md")"
( cd "$WT" && PATH="$SHIM:$PATH" DRIVE_STEP_STUB=1 bash scripts/drive/drive-ctl.sh ask toy "did phase 1 land?" ) \
  >"$WT/ask-steer.log" 2>&1
steer_after="$([ -f "$TOY/drive/steer.md" ] && md5sum <"$TOY/drive/steer.md" || echo GONE)"
consumed="$(ls "$TOY/drive"/steer-consumed-*.md 2>/dev/null | wc -l)"
ok=1
[ "$steer_before" = "$steer_after" ] && [ "${consumed:-1}" = 0 ] \
  && grep -q 'STUB ANSWER' "$WT/ask-steer.log" && ok=0
check 17 "drive-ctl ask answers WITHOUT consuming the queued steer.md" "$ok" \
  "steer=$([ "$steer_before" = "$steer_after" ] && echo intact || echo "$steer_after") consumed-files=$consumed"

fi

# ---------------------------------------------------------------- 18
# --bg runs BEFORE the inhibitor re-exec (which would drop the flag) and setsid puts the
# run in its own process group — which is what makes `stop` able to own its group at all.
if ! skip 18; then
reset_toy
bg_out="$( cd "$WT" && PATH="$SHIM:$PATH" DRIVE_STEP_STUB=1 DRIVE_STUB_SLEEP_implement=5 \
    bash scripts/drive/drive.sh toy phase 1 --bg 2>&1 )"
LOCKF="$(lockf)"
for _ in $(seq 1 80); do [ -s "$LOCKF/meta" ] && break; sleep 0.25; done
bg_pgid="$(sed -n 's/^pgid=//p' "$LOCKF/meta" 2>/dev/null)"
bg_pid="$(sed -n 's/^pid=//p' "$LOCKF/meta" 2>/dev/null)"
self_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
for _ in $(seq 1 160); do [ "$(progress_of 1)" = x ] && break; sleep 0.25; done
ok=1
printf '%s' "$bg_out" | grep -q 'running in background' \
  && [ -n "$bg_pgid" ] && [ "$bg_pgid" != "$self_pgid" ] && [ "$bg_pgid" = "$bg_pid" ] \
  && [ "$(progress_of 1)" = x ] && ok=0
check 18 "--bg survives the inhibitor re-exec and detaches: its pgid is its own, not the caller's" "$ok" \
  "pgid=$bg_pgid pid=$bg_pid caller-pgid=$self_pgid row=$(progress_of 1)"

fi

# ---------------------------------------------------------------- 19
# `stop` may only signal a process GROUP the run owns. A foreground drive inherits its
# launcher's group; signalling that group kills the launcher's unrelated siblings.
if ! skip 19; then
reset_toy
: >"$WT/sleeper.pid"
cat >"$WT/group-launcher.sh" <<EOF
#!/usr/bin/env bash
sleep 300 &
printf '%s' "\$!" >"$WT/sleeper.pid"
cd "$WT" || exit 1
PATH="$SHIM:\$PATH" DRIVE_STEP_STUB=1 DRIVE_STUB_SLEEP_implement=40 \\
  bash scripts/drive/drive.sh toy phase 1 >/dev/null 2>&1
EOF
chmod +x "$WT/group-launcher.sh"
setsid bash "$WT/group-launcher.sh" >/dev/null 2>&1 &
groupbg=$!
LOCKF="$(lockf)"
enginepid=""
for _ in $(seq 1 80); do
  enginepid="$(sed -n 's/^pid=//p' "$LOCKF/meta" 2>/dev/null)"
  [ -n "$enginepid" ] && [ -s "$WT/sleeper.pid" ] && break
  sleep 0.25
done
sleeper="$(cat "$WT/sleeper.pid" 2>/dev/null)"
engine_pgid="$(sed -n 's/^pgid=//p' "$LOCKF/meta" 2>/dev/null)"
ctl stop toy >/dev/null 2>&1
sleep 1
alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }
sleeper_alive=$(alive "$sleeper" && echo yes || echo no)
engine_alive=$(alive "$enginepid" && echo yes || echo no)
ok=1
[ -n "$sleeper" ] && [ -n "$enginepid" ] && [ "$engine_pgid" != "$enginepid" ] \
  && [ "$sleeper_alive" = yes ] && [ "$engine_alive" = no ] && [ ! -e "$LOCKF" ] && ok=0
check 19 "stop never signals a process group the run does not own — an unrelated sibling survives" "$ok" \
  "engine=$enginepid pgid=$engine_pgid sibling-alive=$sleeper_alive engine-alive=$engine_alive"
[ -n "$sleeper" ] && kill -9 "$sleeper" 2>/dev/null
kill -9 "$groupbg" 2>/dev/null; wait "$groupbg" 2>/dev/null

fi

# ---------------------------------------------------------------- 20
# The Progress flip must reach HEAD. `implement-plandirty` flips the row and commits
# without it; the engine has to commit the flip itself.
if ! skip 20; then
reset_toy
head_before="$(git -C "$WT" rev-parse HEAD)"
( cd "$WT" && PATH="$SHIM:$PATH" DRIVE_STEP_STUB=1 DRIVE_STUB_VARIANT_implement=plandirty \
    bash scripts/drive/drive.sh toy phase 1 ) >"$WT/planflip.log" 2>&1
rc=$?
row_in_head="$(git -C "$WT" show HEAD:work/changes/toy/plan.md 2>/dev/null \
  | sed -n 's/^|[[:space:]]*P1[^|]*|[[:space:]]*\[\(.\)\].*/\1/p' | head -1)"
dirty="$(git -C "$WT" status --porcelain -uno -- work/changes/toy src 2>/dev/null | head -5)"
flip_sha="$(git -C "$WT" log --format='%H %s' -3 | grep -m1 'docs(toy): P1 progress (toy p1)' | cut -d' ' -f1)"
flip_files="$(git -C "$WT" show --name-only --format= "${flip_sha:-HEAD}" 2>/dev/null | grep -v '^$' | tr '\n' ' ')"
flip_trailer="$(git -C "$WT" log -1 --format='%b' "${flip_sha:-HEAD}" 2>/dev/null | grep -c 'Co-Authored-By:')"
ok=1
[ "$rc" = 0 ] && [ "$row_in_head" = x ] && [ -z "$dirty" ] \
  && [ -n "$flip_sha" ] && [ "$flip_files" = "work/changes/toy/plan.md " ] \
  && [ "${flip_trailer:-0}" -ge 1 ] \
  && [ "$head_before" != "$(git -C "$WT" rev-parse HEAD)" ] \
  && grep -q 'PLAN-FLIP-COMMITTED' "$TOY/drive-log.md" && ok=0
check 20 "an implementer that leaves the Progress flip uncommitted: the engine commits it, tree clean after the phase" "$ok" \
  "rc=$rc row-in-HEAD=${row_in_head:-none} flip=${flip_sha:0:7} files=[${flip_files% }] trailers=$flip_trailer dirty=[$(printf '%s' "$dirty" | tr '\n' ';')]"

fi

# ---------------------------------------------------------------- 21
# A WARNING two fenced fixers declined: one escalation at the top tier with the fence widened to
# the phase's paths, and — if that declines too — the NEXT phase refuses to dispatch until
# `drive-ctl ack` records that a human took the decision.
if ! skip 21; then
reset_toy
DRIVE_ARGS=(phase 2)
drive env DRIVE_STUB_VARIANT_review=warning DRIVE_STUB_VARIANT_fix=declined; rc1=$?
p2_row="$(progress_of 2)"
fix_dispatches="$(grep -c 'DISPATCH fix p2' "$TOY/drive-log.md")"
escalated=$(grep -q 'T1 ESCALATING to the top worker tier' "$TOY/drive-log.md" && echo yes || echo no)
esc_model="$(grep 'DISPATCH fix p2' "$TOY/drive-log.md" | tail -1 | grep -o 'model=[a-z0-9-]*')"
unfixed_ok=$(grep -q 'escalation declined' "$TOY/drive/unfixed-p2.md" 2>/dev/null && echo yes || echo no)
DRIVE_ARGS=(phase 3)
drive env; rc2=$?
gated=$(grep -q 'would build on findings the fix pass could not close: p2' "$TOY/drive/needs-input.md" 2>/dev/null && echo yes || echo no)
p3_before=$(grep -c 'DISPATCH implement p3' "$TOY/drive-log.md")
ctl ack toy 2 "closed by hand in the self-test" >/dev/null 2>&1; ack_rc=$?
drive env; rc3=$?
p3_after=$(grep -c 'DISPATCH implement p3' "$TOY/drive-log.md")
ok=1
[ "$rc1" = 0 ] && [ "$p2_row" = x ] \
  && [ "$fix_dispatches" = 3 ] && [ "$escalated" = yes ] && [ "$esc_model" = "model=opus" ] \
  && [ "$unfixed_ok" = yes ] \
  && [ "$rc2" = 3 ] && [ "$gated" = yes ] && [ "$p3_before" = 0 ] \
  && [ "$ack_rc" = 0 ] && [ -f "$TOY/drive/unfixed-p2.ack" ] \
  && [ "$p3_after" -ge 1 ] && ok=0
check 21 "a declined WARNING escalates once at opus with a widened fence, then GATES the next phase until drive-ctl ack" "$ok" \
  "rc1=$rc1 row=$p2_row fix-dispatches=$fix_dispatches escalated=$escalated $esc_model unfixed=$unfixed_ok rc2=$rc2 gated=$gated p3-before=$p3_before ack=$ack_rc rc3=$rc3 p3-after=$p3_after"

fi

# ---------------------------------------------------------------- 22
# The REAL backend path (no DRIVE_STEP_STUB) against the claude shim: the argv the engine
# builds, the envelope it parses, and the attribution of every model call to a step.
if ! skip 22; then
reset_toy
: >"$MODEL_CALLS"
( cd "$WT" && PATH="$SHIM:$PATH" DRIVE_LIMIT_MARGIN_SECONDS=1 DRIVE_LIMIT_POLL_SECONDS=3 \
    bash scripts/drive/drive.sh toy phase 1 ) >"$WT/backend.log" 2>&1
backend_rc=$?
impl_line="$(grep '^claude|implement:' "$MODEL_CALLS" | head -1)"
verify_line="$(grep '^claude|verify:' "$MODEL_CALLS" | head -1)"
argv_ok=1
if [ -n "$impl_line" ] && printf '%s' "$impl_line" | grep -q -- '--model opus --effort high' \
   && printf '%s' "$impl_line" | grep -q -- '--max-budget-usd 25' \
   && printf '%s' "$impl_line" | grep -q -- '--output-format json' \
   && printf '%s' "$impl_line" | grep -q -- '--json-schema' \
   && printf '%s' "$impl_line" | grep -q -- '--dangerously-skip-permissions' \
   && printf '%s' "$impl_line" | grep -q '/implement-phase toy phase 1' \
   && ! printf '%s' "$impl_line" | grep -q -- '--disallowedTools' \
   && [ -n "$verify_line" ] && printf '%s' "$verify_line" | grep -q -- '--model sonnet --effort high' \
   && printf '%s' "$verify_line" | grep -q -- '--agent drive-verifier' \
   && printf '%s' "$verify_line" | grep -q -- '--disallowedTools Edit Write NotebookEdit' \
   && printf '%s' "$verify_line" | grep -q -- '--max-budget-usd 5'; then
  argv_ok=0
fi
orphans="$(grep -c 'ORCHESTRATOR' "$MODEL_CALLS" 2>/dev/null)"; orphans="${orphans:-0}"
calls="$(grep -c '^claude|' "$MODEL_CALLS" 2>/dev/null)"; calls="${calls:-0}"
dispatches="$(grep -c 'DISPATCH' "$TOY/drive-log.md" 2>/dev/null)"; dispatches="${dispatches:-0}"
ok=1
[ "$backend_rc" = 0 ] && [ "$argv_ok" = 0 ] && [ "$(progress_of 1)" = x ] && [ -f "$TOY_TS" ] \
  && grep -q 'RESULT implement p1 model=opus effort=high → ok cost=\$0.42' "$TOY/drive-log.md" \
  && grep -q 'SKIPPED — no runnable surface' "$TOY/drive-log.md" \
  && [ "$orphans" = 0 ] && [ "$calls" = 2 ] && [ "$calls" = "$dispatches" ] && ok=0
check 22 "claude backend: argv carries tier/effort/cap/schema/agent per role, structured_output and cost are parsed, every model call belongs to a step and matches the ledger" "$ok" \
  "rc=$backend_rc argv=$argv_ok row=$(progress_of 1) calls=$calls dispatches=$dispatches orphans=$orphans"

fi

# ---------------------------------------------------------------- 23
# The per-step wall clock: a hung CLI is killed at DRIVE_STEP_TIMEOUT, retried once, and
# then handed to a human — never left holding the lock.
if ! skip 23; then
reset_toy
: >"$MODEL_CALLS"
t0=$(date +%s)
( cd "$WT" && PATH="$SHIM:$PATH" SELFTEST_CLAUDE_SLEEP=60 DRIVE_STEP_TIMEOUT=2 \
    bash scripts/drive/drive.sh toy phase 1 ) >"$WT/timeout.log" 2>&1
timeout_rc=$?
t1=$(date +%s)
calls="$(grep -c '^claude|' "$MODEL_CALLS" 2>/dev/null)"; calls="${calls:-0}"
LOCKF="$(lockf)"
ok=1
[ "$timeout_rc" = 3 ] && [ "$calls" = 2 ] && [ $((t1 - t0)) -lt 40 ] \
  && grep -q 'timed out after 2s → retry 2' "$TOY/drive-log.md" \
  && grep -q 'timed out twice (DRIVE_STEP_TIMEOUT=2s)' "$TOY/drive/needs-input.md" \
  && [ ! -e "$LOCKF" ] && [ "$(progress_of 1)" = " " ] \
  && ! pgrep -f "SELFTEST_CLAUDE_SLEEP" >/dev/null 2>&1 && ok=0
check 23 "a step that exceeds DRIVE_STEP_TIMEOUT is killed, retried once, then needs-input — lock released, no stray child" "$ok" \
  "rc=$timeout_rc calls=$calls took=$((t1 - t0))s"

fi

# ---------------------------------------------------------------- 24
# The toy plan is a valid fixture: check-plan-progress reports it clean, and the same
# plan with one phase's `paths:` line removed is refused.
if ! skip 24; then
reset_toy
clean_out="$( cd "$WT" && node scripts/check-plan-progress.mjs "$TOY/plan.md" 2>&1 )"; clean_rc=$?
grep -v '^paths: `src/contracts/toy.ts`$' "$TOY/plan.md" >"$WT/plan-nopaths.md"
bad_out="$( cd "$WT" && node scripts/check-plan-progress.mjs "$WT/plan-nopaths.md" 2>&1 )"; bad_rc=$?
ok=1
[ "$clean_rc" = 0 ] && printf '%s' "$clean_out" | grep -q 'OK: Progress and phases agree (3 phases, 3 rows)' \
  && ! printf '%s' "$clean_out" | grep -q 'WARNING' \
  && [ "$bad_rc" = 1 ] && printf '%s' "$bad_out" | grep -q 'P2 .* has no `paths:` line' && ok=0
check 24 "check-plan-progress: the toy plan is clean; dropping one phase's \`paths:\` line fails it" "$ok" \
  "clean-rc=$clean_rc bad-rc=$bad_rc"

fi

# ---------------------------------------------------------------- 25
# The hand-back is where "PASS without artifacts is not a PASS" becomes visible: a verifier
# flow reported PASS with no evidence must be printed as UNVERIFIED, and an evidenced one
# keeps its status and cites its file.
if ! skip 25; then
reset_toy
mkdir -p "$TOY/drive"
printf '%s\n' '{"verdict":"PASS","flows":[{"name":"export","status":"PASS","evidence":[]},{"name":"import","status":"PASS","evidence":["drive/verify-p1/import.txt"]}],"screenshots":[],"db_asserts":[]}' >"$TOY/drive/verify-claim.json"
hb="$( cd "$WT" && bash scripts/drive/drive-handback.sh toy "1" "$TOY/drive/verify-claim.json" 2>&1 )"; hb_rc=$?
ok=1
[ "$hb_rc" = 0 ] && printf '%s' "$hb" | grep -q 'export: UNVERIFIED — NO ARTIFACT (claim discarded)' \
  && printf '%s' "$hb" | grep -q 'import: PASS — drive/verify-p1/import.txt' \
  && printf '%s' "$hb" | grep -q 'This run never pushed and never archived' && ok=0
check 25 "hand-back: a PASS flow with no evidence is printed as UNVERIFIED; an evidenced flow keeps PASS and cites its file" "$ok" "rc=$hb_rc"

fi

# ---------------------------------------------------------------- 26
# drive-checkout: a change whose branch is already checked out (the main checkout right
# after /start-change) is driven from that checkout; once the main checkout moves back to
# main, a worktree is created and re-runs return the same one; an unknown change exits 2.
if ! skip 26; then
CO="$WT.checkout"
rm -rf "$CO"; mkdir -p "$CO"
( cd "$CO" && git init -q -b main && git config user.name selftest && git config user.email selftest@example.invalid \
  && git config commit.gpgsign false && printf 'x\n' >README && git add README && git commit -qm init \
  && git switch -q -c demo && mkdir -p work/changes/demo \
  && printf '# demo\n\nstatus: open\nlane: S\nbranch: demo\n' >work/changes/demo/change.md \
  && git add work && git commit -qm "chore(demo): open change" ) >/dev/null 2>&1
reuse="$( cd "$CO" && bash "$ENGINE_SRC/drive-checkout.sh" demo 2>/dev/null | tail -1 )"; reuse_rc=$?
git -C "$CO" switch -q main
made="$( cd "$CO" && bash "$ENGINE_SRC/drive-checkout.sh" demo 2>/dev/null | tail -1 )"
again="$( cd "$CO" && bash "$ENGINE_SRC/drive-checkout.sh" demo 2>/dev/null | tail -1 )"
( cd "$CO" && bash "$ENGINE_SRC/drive-checkout.sh" nosuch ) >/dev/null 2>&1; missing_rc=$?
ok=1
[ "$reuse_rc" = 0 ] && [ "$reuse" = "$CO" ] && [ "$made" = "$CO/.claude/worktrees/demo" ] && [ "$again" = "$made" ] \
  && [ "$(git -C "$made" branch --show-current 2>/dev/null)" = demo ] && [ -f "$made/work/changes/demo/change.md" ] \
  && [ "$missing_rc" = 2 ] && ok=0
check 26 "drive-checkout: reuses the checkout that already has the branch, otherwise creates one worktree and returns it again; unknown change exits 2" "$ok" \
  "reuse=$reuse made=$made again=$again missing-rc=$missing_rc"
git -C "$CO" worktree remove --force "$CO/.claude/worktrees/demo" >/dev/null 2>&1
rm -rf "$CO"

fi

# ---------------------------------------------------------------- the real run
REAL_LINE="real run: skipped (pass --real to spend tokens on one)"
REAL_OK=0
if [ "$RUN_REAL" = 1 ]; then
  reset_toy
  # The safety shims (systemctl, systemd-inhibit) stay; the CLAUDE shim does NOT. With
  # $SHIM on PATH the "real" run would call the shim, which never reaches a model.
  REALSHIM="$SHIM.real"
  mkdir -p "$REALSHIM"
  for b in systemctl systemd-inhibit; do ln -sf "$SHIM/$b" "$REALSHIM/$b"; done
  REAL_CLAUDE="$(PATH="$REALSHIM:$PATH" command -v claude 2>/dev/null)"
  case "${REAL_CLAUDE:-}" in
    "$SHIM"/* | "$REALSHIM"/* | "")
      REAL_OK=1
      REAL_LINE="real run: NOT RUN — no claude binary outside the shim dir (resolved: ${REAL_CLAUDE:-none})"
      echo "drive-selftest: $REAL_LINE" >&2
      RUN_REAL=0 ;;
  esac
fi
if [ "$RUN_REAL" = 1 ]; then
  echo "drive-selftest: real run (no stubs, sonnet, cap \$3) via $REAL_CLAUDE — this calls the model."
  t0=$(date +%s)
  ( cd "$WT" && PATH="$REALSHIM:$PATH" DRIVE_MODEL_implement=sonnet DRIVE_EFFORT_implement=medium \
      DRIVE_BUDGET_implement=3 bash scripts/drive/drive.sh toy phase 1 ) \
      >"$WT/real-run.log" 2>&1
  real_rc=$?
  [ "$real_rc" = 0 ] || REAL_OK=1
  t1=$(date +%s)
  real_sha="$(git -C "$WT" log --oneline -1 --format='%h %s' 2>/dev/null)"
  landed=$([ "$(progress_of 1)" = x ] && echo yes || echo no)
  tokens="$(grep -oE 'cost=\$[0-9.]+' "$TOY/drive-log.md" 2>/dev/null | head -1)"
  [ -n "$tokens" ] || tokens="$(grep -oE '→ ok.*' "$TOY/drive-log.md" 2>/dev/null | head -1)"
  REAL_LINE="real run: rc=$real_rc · landed=$landed · $(( (t1 - t0) / 60 ))m$(( (t1 - t0) % 60 ))s · ${tokens:-cost unrecorded} · commit: ${real_sha:-none} · binary: $REAL_CLAUDE"
  echo "$REAL_LINE"
  rm -rf "$REALSHIM"
fi

# ---------------------------------------------------------------- report
echo
echo "================ drive-selftest — $PASS PASS / $FAIL FAIL ================"
printf '%s\n' "${RESULTS[@]}"
echo
# Measured, not asserted in prose: the shim logged every CLI invocation with the step
# that made it (check 22 fails the gate when either number is wrong).
echo "model invocations this run: $(grep -c '|' "$MODEL_CALLS" 2>/dev/null) · unattributed to a step (orchestrator): $(grep -c 'ORCHESTRATOR' "$MODEL_CALLS" 2>/dev/null)"
echo "$REAL_LINE"
# A failed live proof fails the gate: a real run that never reached a model must not
# report success.
[ "$FAIL" = 0 ] || exit 1
[ "$REAL_OK" = 0 ] || exit 1
