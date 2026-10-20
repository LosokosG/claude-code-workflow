#!/usr/bin/env bash
# drive — runs an approved phase plan, one fresh model context per step.
#
#   bash scripts/drive/drive.sh <change-id> [phase N | through N] [--bg] [--shutdown]
#
# This is a script, not an LLM orchestrator. State lives in exactly two places that
# already exist: the plan's `## Progress` table and git. Nothing is remembered across
# steps, so a resume — after a crash, a kill -9, or an overnight usage-limit pause — is
# just "read the table again".
#
# Per phase: implement → (risk-flagged ? two review lenses in parallel : size-triggered
# full pass) → deterministic triage → one fixer per actionable finding (two fenced
# dispatches, then one escalation with a widened fence) → at most one re-review → next
# phase. Anything a human must decide writes needs-input.md, notifies, and exits 3 —
# including a finding no fixer closed: the next phase does not dispatch until
# `drive-ctl ack`.
#
# The engine drives the git checkout it is launched from (cwd), wherever the engine
# files themselves live. Change folders are `$DRIVE_WORK_DIR/changes/<id>/` (default
# `work/changes/<id>/`).
#
# Env knobs: DRIVE_MODEL_<role> / DRIVE_EFFORT_<role> / DRIVE_BUDGET_<role> override a
# role's tier or cap for the whole run; DRIVE_STEP_TIMEOUT caps one step's wall clock;
# DRIVE_WORK_DIR moves the change folders.
set -uo pipefail

DRIVE_ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVE_REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "drive: run me from inside the git checkout you want driven." >&2; exit 2; }
cd "$DRIVE_REPO" || exit 1

# ---------------------------------------------------------------- args
CHANGE_ID=""; BOUND_KIND="all"; BOUND_N=""; BG=0; SHUTDOWN=0
while [ $# -gt 0 ]; do
  case "$1" in
    phase)      BOUND_KIND=one;     BOUND_N="${2:?phase needs a number}"; shift 2 ;;
    through)    BOUND_KIND=through; BOUND_N="${2:?through needs a number}"; shift 2 ;;
    --bg)       BG=1; shift ;;
    --shutdown) SHUTDOWN=1; shift ;;
    -h|--help)  sed -n '2,25p' "$0"; exit 0 ;;
    -*) echo "drive: unknown flag '$1'" >&2; exit 2 ;;
    *)  if [ -z "$CHANGE_ID" ]; then CHANGE_ID="$1"; else echo "drive: unexpected '$1'" >&2; exit 2; fi; shift ;;
  esac
done
[ -n "$CHANGE_ID" ] || { echo "drive: usage: drive.sh <change-id> [phase N|through N] [--bg] [--shutdown]" >&2; exit 2; }

# shellcheck source=scripts/drive/drive-lib.sh
. "$DRIVE_ENGINE/drive-lib.sh"
drive_paths_init "$CHANGE_ID"
[ -f "$PLAN" ] || { echo "drive: no plan at $PLAN" >&2; exit 2; }
# Engine commits are plain git and bypass the agent hooks, so the branch is checked here
# and not only in the skill: a drive started on main would land every phase directly on it.
CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
case "$CUR_BRANCH" in
  main | master | HEAD | "")
    echo "drive: refusing to drive on '${CUR_BRANCH:-no branch}'. Run '$(drive_cmd checkout) $CHANGE_ID' and launch from the checkout it prints." >&2
    exit 2 ;;
esac
WANT_BRANCH="$(sed -n 's/^branch:[[:space:]]*//p' "$CHANGE_DIR/change.md" 2>/dev/null | head -1 | tr -d '[:space:]')"
if [ -n "$WANT_BRANCH" ] && [ "$WANT_BRANCH" != "$CUR_BRANCH" ]; then
  echo "drive: change.md claims branch '$WANT_BRANCH' but this checkout is on '$CUR_BRANCH'. Run '$(drive_cmd checkout) $CHANGE_ID'." >&2
  exit 2
fi
export DRIVE_CHANGE_ID="$CHANGE_ID"
mkdir -p "$DRIVE_RUN_DIR"

# ---------------------------------------------------------------- background
# BEFORE the inhibitor re-exec, not after: the re-exec rebuilds the argument list, and
# --bg is the one flag it must drop. Backgrounding first also puts the run in its own
# session, which is what lets `drive-ctl stop` signal the whole process group instead of
# leaving a CLI and its tools orphaned.
rebuild_args() {
  [ "$BOUND_KIND" = one ] && printf '%s\n' phase "$BOUND_N"
  [ "$BOUND_KIND" = through ] && printf '%s\n' through "$BOUND_N"
  [ "$SHUTDOWN" = 1 ] && printf '%s\n' --shutdown
  return 0
}
mapfile -t RERUN_ARGS < <(rebuild_args)
if [ "$BG" = 1 ]; then
  launcher=(nohup)
  command -v setsid >/dev/null 2>&1 && launcher=(nohup setsid)
  "${launcher[@]}" bash "$0" "$CHANGE_ID" "${RERUN_ARGS[@]}" >>"$DRIVE_RUN_DIR/run.log" 2>&1 &
  echo "drive: running in background (pid $!) — log: $DRIVE_RUN_DIR/run.log"
  echo "  status: $(drive_cmd ctl) status $CHANGE_ID   ·   log: $(drive_cmd ctl) log $CHANGE_ID -f   ·   stop: $(drive_cmd ctl) stop $CHANGE_ID"
  exit 0
fi

# ---------------------------------------------------------------- sleep inhibitor
# An autonomous run produces no keyboard input, so the idle policy sees an abandoned
# machine and suspends it mid-review. Re-exec under an inhibitor once, then never again.
# Optional: a machine without systemd-inhibit simply runs uninhibited.
if [ -z "${DRIVE_INHIBITED:-}" ] && command -v systemd-inhibit >/dev/null 2>&1; then
  export DRIVE_INHIBITED=1
  exec systemd-inhibit --what=sleep:idle --mode=block --who="drive" \
    --why="$CHANGE_ID" bash "$0" "$CHANGE_ID" "${RERUN_ARGS[@]}"
fi

# ---------------------------------------------------------------- lock
# `mkdir` is the acquisition: it is atomic and it fails if the directory exists. A
# check-then-write lock let two runs started together both see no lock, both write one,
# and both drive the same Progress table while either one's EXIT trap removed the other's.
LOCK="$(drive_lock_dir "$CHANGE_ID")"
LOCK_META="$LOCK/meta"
if ! mkdir "$LOCK" 2>/dev/null; then
  old_pid="$(sed -n 's/^pid=//p' "$LOCK_META" 2>/dev/null | head -1)"
  # A lock directory with no metadata in it is a run that acquired it MICROSECONDS ago,
  # not a dead one: `mkdir` is the acquisition and the meta file is written straight after.
  if [ -z "$old_pid" ]; then
    sleep 1
    old_pid="$(sed -n 's/^pid=//p' "$LOCK_META" 2>/dev/null | head -1)"
    if [ -z "$old_pid" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin -1 2>/dev/null)" ]; then
      echo "drive: another run is acquiring the lock right now — $LOCK" >&2
      echo "drive: retry in a moment, or delete the lock if no run is alive." >&2
      exit 2
    fi
  fi
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "drive: another run holds the lock — $LOCK" >&2; cat "$LOCK_META" >&2
    echo "drive: stop it with '$(drive_cmd ctl) stop $CHANGE_ID', or delete the lock if that run is dead." >&2
    exit 2
  fi
  echo "drive: stale lock from a dead run (pid ${old_pid:-unknown}) — reclaiming and resuming."
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || { echo "drive: lost the race for the lock; another run took it." >&2; exit 2; }
fi
DRIVE_STARTED="$(date -Iseconds)"
# `pidstart` is the kernel's start time for THIS pid. `drive-ctl stop` compares it before
# signalling, so a recycled pid is never mistaken for this run.
printf 'pid=%s\npgid=%s\npidstart=%s\nstarted=%s\n' \
  "$$" "$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')" \
  "$(ps -o lstart= -p $$ 2>/dev/null | tr -d '\n' | sed -e 's/^ *//' -e 's/ *$//')" \
  "$DRIVE_STARTED" >"$LOCK_META"
rm -f "$DRIVE_RUN_DIR/stop.flag"
# needs-input.md is the artifact the run just told a human to read. Archiving it — never
# deleting it — is the difference between "resume after reading it" and "resume destroyed
# the reason it stopped".
[ -f "$DRIVE_RUN_DIR/needs-input.md" ] && \
  mv "$DRIVE_RUN_DIR/needs-input.md" "$DRIVE_RUN_DIR/needs-input-$(date +%Y%m%d-%H%M%S).md" 2>/dev/null

# DRIVE_RUN=1 tells every dispatched step (and any guard hook that cares) that nobody is
# at the keyboard: skills skip their questions and return needs_input instead.
export DRIVE_RUN=1 DRIVE_REPO DRIVE_ENGINE DRIVE_RUN_DIR
# shellcheck source=scripts/drive/drive-step.sh
. "$DRIVE_ENGINE/drive-step.sh"

cleanup() {
  local rc=$? kid
  # Ownership is released LAST, and only once this run's own children are gone. Dropping
  # the lock while a lens subshell or a CLI was still dying let a resumed drive overlap the
  # previous run on the same checkout.
  for kid in $(pgrep -P $$ 2>/dev/null); do kill -TERM "$kid" 2>/dev/null; done
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -z "$(pgrep -P $$ 2>/dev/null)" ] && break
    sleep 0.2
  done
  for kid in $(pgrep -P $$ 2>/dev/null); do kill -KILL "$kid" 2>/dev/null; done
  rm -rf "$LOCK"
  return $rc
}
trap cleanup EXIT
trap 'echo "drive: stopped by signal."; drive_state_set idle; exit 130' TERM INT

# shellcheck source=scripts/drive/drive-phase.sh
. "$DRIVE_ENGINE/drive-phase.sh"

# ---------------------------------------------------------------- run
drive_state_set running
echo "drive: $CHANGE_ID — bound=$BOUND_KIND${BOUND_N:+ $BOUND_N}"
mapfile -t OPEN < <(plan_open_phases)
# A `[x]` row whose recorded stage stopped short of `fixed` is NOT done: the implementer
# flips the row when it commits, before review and fixes run.
mapfile -t UNFINISHED < <(drive_unfinished_phases)
mapfile -t CANDIDATES < <(printf '%s\n' "${OPEN[@]}" "${UNFINISHED[@]}" | grep -E '^[0-9]+$' | sort -n -u)
[ "${#CANDIDATES[@]}" -gt 0 ] || { echo "drive: no open [ ] phases and no unfinished review/fix stages in $PLAN — nothing to drive."; drive_state_set "done"; exit 0; }

PHASES=()
case "$BOUND_KIND" in
  one)
    for p in "${CANDIDATES[@]}"; do [ "$p" = "$BOUND_N" ] && PHASES=("$BOUND_N"); done ;;
  through) for p in "${CANDIDATES[@]}"; do [ "$p" -le "$BOUND_N" ] && PHASES+=("$p"); done ;;
  all)     PHASES=("${CANDIDATES[@]}") ;;
esac
[ "${#PHASES[@]}" -gt 0 ] || { echo "drive: nothing in range (phase rows already [x] with their review and fixes complete, or [~])."; drive_state_set "done"; exit 0; }
[ "${#UNFINISHED[@]}" -gt 0 ] && echo "drive: resuming unfinished review/fix stage(s) on phase(s): ${UNFINISHED[*]}"
echo "drive: phases in range: ${PHASES[*]}"

for p in "${PHASES[@]}"; do
  echo "drive: === phase $p ==="
  drive_gate_unfixed "$p"
  run_phase "$p"
done

# ---------------------------------------------------------------- verify + hand-back
DRIVE_PHASE="${PHASES[-1]}"; DRIVE_STEP_NAME="verify"; check_control
VERIFY_JSON=""
VERIFY_SCRATCH="$DRIVE_RUN_DIR/verify-p${PHASES[-1]}"
mkdir -p "$VERIFY_SCRATCH"
run_step verify "You are the live verifier for $CHANGE_ID. Mode: smoke.

Phases landed this run: ${PHASES[*]} (see $CHANGE_REL/plan.md and $CHANGE_REL/drive-log.md).
Scratch directory for every artifact you produce: $VERIFY_SCRATCH

Prove the delivered phases work. For each landed phase, run its \`Done when:\` command(s)
from the plan verbatim and save the full output to a file under the scratch directory.
When the phases delivered a runnable surface (an HTTP route, a CLI, a page) and it is
ALREADY running, walk it: the main flow end to end, PLUS one degraded input per flow
(malformed, empty, oversized). Never start or stop a server yourself — no dev-server
launches, no pkill/kill/fuser -k. If nothing is running, record that flow as UNVERIFIED
and move on.

Evidence on EVERY flow: the saved command output · after every write action, a check of
the persisted state through whatever read-only query the project provides (a success
response with nothing persisted IS a defect) · console or network excerpts and
screenshots where a browser was involved. Assert persisted state, never response status.

A PASS without an artifact is not a PASS — report it as UNVERIFIED. Never edit product
code. If these phases delivered no runnable surface and no \`Done when:\` command, return
verdict SKIPPED and say so.

Return JSON validating against $DRIVE_ENGINE_REL/schemas/verify.json." \
  "$DRIVE_ENGINE/schemas/verify.json" "$DRIVE_RUN_DIR/paths-p${PHASES[-1]}.txt" \
  --note "smoke over the surface phases ${PHASES[*]} delivered"
[ "$STEP_STATUS" = ok ] && VERIFY_JSON="$STEP_OUT"
drive_heartbeat "RESULT" "verify" "$STEP_NOTE"
for p in "${PHASES[@]}"; do drive_stage_set "$p" verified; done

bash "$DRIVE_ENGINE/drive-handback.sh" "$CHANGE_ID" "${PHASES[*]}" "$VERIFY_JSON" >>"$DRIVE_LOG"
drive_state_set "done"
echo "drive: done — hand-back appended to $DRIVE_LOG"
command -v notify-send >/dev/null 2>&1 && \
  notify-send -a "drive" "drive — $CHANGE_ID finished" "Phases ${PHASES[*]} landed. Hand-back in drive-log.md." 2>/dev/null

# --shutdown is honoured ONLY here, at a terminal hand-back. A usage-limit pause is not a
# terminal state — the run is sleeping and will resume itself, and powering the machine
# off under it would strand the work.
if [ "$SHUTDOWN" = 1 ]; then
  rm -rf "$LOCK"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl poweroff --when=+5min
    echo "drive: poweroff scheduled in 5 minutes. Cancel with:  systemctl poweroff --when=cancel"
  fi
fi
exit 0
