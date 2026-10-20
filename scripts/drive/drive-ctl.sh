#!/usr/bin/env bash
# drive control surface. The stable contract any external watcher (a status-bar widget,
# a cron check, the control-room chat) is built on — it polls this, never the engine's
# internals.
#
#   drive-ctl.sh status <change-id> [--json]
#   drive-ctl.sh log    <change-id> [-f]
#   drive-ctl.sh ask    <change-id> "<question>"
#   drive-ctl.sh steer  <change-id> "<text>"
#   drive-ctl.sh pause  <change-id>
#   drive-ctl.sh resume <change-id>
#   drive-ctl.sh stop   <change-id>
#   drive-ctl.sh ack    <change-id> <phase> ["<note>"]   unblock the unfixed-findings gate
#
# `status --json` shape — additive changes only; a consumer may rely on every key:
#
#   {
#     "change":    "<change-id>",
#     "phase":     "<n>"        | "",     the phase currently being driven
#     "step":      "implement" | "review" | "review-safety" | "fix-T1" | "rereview"
#                | "verify"    | "",
#     "state":     "idle" | "running" | "paused" | "waiting-limit" | "needs-input" | "done",
#     "started":   "<ISO 8601>" | "",     when the run took its lock
#     "heartbeat": "<ISO 8601>" | "",     last state write (staleness signal)
#     "last_log":  "<the newest drive-log line>",
#     "pids":      [<pid>, …],            empty when nothing is running
#     "needs_input": true | false
#   }
#
# `state` is derived, not trusted: a `running` state whose pid is gone reports `idle`.
set -uo pipefail

DRIVE_ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVE_REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "drive-ctl: run me from inside the checkout the drive runs in." >&2; exit 2; }
cd "$DRIVE_REPO" || exit 1

CMD="${1:-}"; CHANGE_ID="${2:-}"
[ -n "$CMD" ] && [ -n "$CHANGE_ID" ] || {
  sed -n '6,13p' "$0" >&2; exit 2
}
shift 2

# shellcheck source=scripts/drive/drive-lib.sh
. "$DRIVE_ENGINE/drive-lib.sh"
drive_paths_init "$CHANGE_ID"
RUN_DIR="$DRIVE_RUN_DIR"
LOG="$DRIVE_LOG"
LOCK="$(drive_lock_dir "$CHANGE_ID")"
LOCK_META="$LOCK/meta"
mkdir -p "$RUN_DIR"

live_pid() {
  local p
  p="$(sed -n 's/^pid=//p' "$LOCK_META" 2>/dev/null | head -1)"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p"
}

# Every descendant, depth first. A drive's tree is engine → lens subshell → CLI → the
# CLI's own tool processes; `pkill -P <engine>` reaches only the second level.
descendants() {
  local pid="$1" kid
  for kid in $(pgrep -P "$pid" 2>/dev/null); do
    descendants "$kid"
    echo "$kid"
  done
}

case "$CMD" in
  status)
    pid="$(live_pid)"
    node -e '
      const fs = require("fs");
      const [stateFile, logFile, lockFile, changeId, pid, mode] = process.argv.slice(1);
      let s = {};
      try { s = JSON.parse(fs.readFileSync(stateFile, "utf8")); } catch {}
      const needsInput = fs.existsSync(stateFile.replace(/state\.json$/, "needs-input.md"));
      const paused = fs.existsSync(stateFile.replace(/state\.json$/, "pause.flag"));
      let state = s.state ?? "idle";
      if (!pid && !["needs-input", "done"].includes(state)) state = "idle";
      if (needsInput) state = "needs-input";
      else if (pid && paused) state = "paused";
      let lastLog = "";
      try {
        const lines = fs.readFileSync(logFile, "utf8").trimEnd().split("\n");
        lastLog = lines[lines.length - 1] ?? "";
      } catch {}
      let started = s.started ?? "";
      try { started = /^started=(.*)$/m.exec(fs.readFileSync(lockFile, "utf8"))?.[1] ?? started; } catch {}
      const out = {
        change: changeId, phase: String(s.phase ?? ""), step: s.step ?? "", state,
        started, heartbeat: s.heartbeat ?? "",
        last_log: lastLog, pids: pid ? [Number(pid)] : [], needs_input: needsInput,
      };
      if (mode === "--json") { console.log(JSON.stringify(out, null, 2)); process.exit(0); }
      console.log(`${out.change}  phase ${out.phase || "-"}  step ${out.step || "-"}  [${out.state}]`);
      console.log(`  started   ${out.started || "-"}`);
      console.log(`  heartbeat ${out.heartbeat || "-"}`);
      console.log(`  pids      ${out.pids.join(", ") || "-"}`);
      if (out.last_log) console.log(`  last      ${out.last_log}`);
      if (out.needs_input) console.log(`  NEEDS INPUT → ${stateFile.replace(/state\.json$/, "needs-input.md")}`);
    ' "$RUN_DIR/state.json" "$LOG" "$LOCK_META" "$CHANGE_ID" "$pid" "${1:-}"
    ;;

  log)
    [ -f "$LOG" ] || { echo "drive-ctl: no drive log yet at $LOG" >&2; exit 1; }
    if [ "${1:-}" = "-f" ]; then tail -f "$LOG"; else tail -60 "$LOG"; fi
    ;;

  steer)
    text="${1:?drive-ctl: steer needs text}"
    # The engine CONSUMES steer.md by renaming it. An append whose file descriptor was
    # already open when the rename happened would write into the archived file and be
    # lost, so writer and reader take the same lock.
    if command -v flock >/dev/null 2>&1; then
      ( flock 9; printf '%s\n' "$text" >>"$RUN_DIR/steer.md" ) 9>"$RUN_DIR/steer.lock"
    else
      printf '%s\n' "$text" >>"$RUN_DIR/steer.md"
    fi
    echo "drive-ctl: steering queued — the next step's prompt carries it, then it is archived."
    ;;

  pause)
    touch "$RUN_DIR/pause.flag"
    echo "drive-ctl: pause requested — the run stops at the next step boundary (a half-finished step is worse than a late pause)."
    ;;

  resume)
    rm -f "$RUN_DIR/pause.flag"
    echo "drive-ctl: resumed."
    ;;

  ack)
    # The engine refuses to dispatch phase N+1 while an earlier phase's unfixed-p<N>.md has
    # no matching .ack — a WARNING nobody closed is a decision, not a non-event. The ack
    # records that the human took it (fixed by hand, or decided it can wait); the hand-back
    # still lists the findings.
    n="${1:?drive-ctl: ack needs a phase number}"
    [ -s "$RUN_DIR/unfixed-p$n.md" ] || { echo "drive-ctl: nothing unfixed on phase $n (no $RUN_DIR/unfixed-p$n.md)" >&2; exit 1; }
    printf 'acknowledged %s%s\n' "$(date -Iseconds)" "${2:+ — $2}" >"$RUN_DIR/unfixed-p$n.ack"
    echo "drive-ctl: phase $n's unfixed findings acknowledged — the gate lets the next phase dispatch. Resume with: $(drive_cmd drive) $CHANGE_ID"
    ;;

  stop)
    # The lock is released LAST, and only after the whole tree is confirmed gone. Releasing
    # it while a reviewer or its tools were still alive let a resumed drive overlap the
    # previous run on the same checkout.
    rm -f "$RUN_DIR/pause.flag"
    touch "$RUN_DIR/stop.flag"
    pid="$(live_pid)"
    pgid="$(sed -n 's/^pgid=//p' "$LOCK_META" 2>/dev/null | head -1)"
    want_start="$(sed -n 's/^pidstart=//p' "$LOCK_META" 2>/dev/null | head -1)"
    self_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
    # A pid outlives the process that recorded it. Before signalling ANYTHING, prove this
    # pid is still the process the lock was written for — a reused pid is a stranger's.
    if [ -n "$pid" ] && [ -n "$want_start" ]; then
      have_start="$(ps -o lstart= -p "$pid" 2>/dev/null | tr -d '\n' | sed -e 's/^ *//' -e 's/ *$//')"
      if [ -n "$have_start" ] && [ "$have_start" != "$want_start" ]; then
        echo "drive-ctl: the lock's pid $pid is a different process now (started '$have_start', the lock says '$want_start') — signalling nothing, just releasing the lock." >&2
        pid=""
      fi
    fi
    # Signal a process GROUP only when the run owns it. `--bg` calls setsid, so the engine
    # is its own group leader (pgid == pid). A foreground run inherits its LAUNCHER's group,
    # and `kill -- -$pgid` from another session then terminates the launcher and every
    # unrelated sibling in it. Descendant-walking still reaches the whole tree in that
    # case; it just cannot borrow the group as a shortcut.
    group_ok=0
    case "$pgid" in
      '' | *[!0-9]* | 0 | 1) ;;
      *) [ -n "$pid" ] && [ "$pgid" = "$pid" ] && [ "$pgid" != "$self_pgid" ] && group_ok=1 ;;
    esac
    if [ -n "$pid" ]; then
      [ "$group_ok" = 1 ] && kill -TERM -- "-$pgid" 2>/dev/null
      for d in $(descendants "$pid"); do kill -TERM "$d" 2>/dev/null; done
      kill -TERM "$pid" 2>/dev/null
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        still=0
        kill -0 "$pid" 2>/dev/null && still=1
        [ "$group_ok" = 1 ] && pgrep -g "$pgid" >/dev/null 2>&1 && still=1
        [ -n "$(descendants "$pid")" ] && still=1
        [ "$still" = 0 ] && break
        sleep 1
      done
      [ "$group_ok" = 1 ] && kill -KILL -- "-$pgid" 2>/dev/null
      for d in $(descendants "$pid"); do kill -KILL "$d" 2>/dev/null; done
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    fi
    rm -rf "$LOCK"
    echo "drive-ctl: stopped${pid:+ (pid $pid)} — tree terminated, lock released. Resume with: $(drive_cmd drive) $CHANGE_ID"
    ;;

  ask)
    question="${1:?drive-ctl: ask needs a question}"
    # A one-shot read-only step over the run's own record. Cheapest tier by design: the
    # answer is a lookup in the log and the plan, not a judgment call.
    export DRIVE_REPO DRIVE_ENGINE DRIVE_RUN_DIR DRIVE_CHANGE_ID="$CHANGE_ID"
    export DRIVE_PHASE="ask"
    drive_heartbeat() { :; }
    drive_state_set() { :; }
    # shellcheck source=scripts/drive/drive-step.sh
    . "$DRIVE_ENGINE/drive-step.sh"
    : >"$RUN_DIR/ask-scope.txt"
    run_step ask "Answer this question about the running drive of \`$CHANGE_ID\`, from its own record only:

  $question

Sources, in this order: \`$LOG\` (the heartbeat ledger — every DISPATCH/RESULT line),
\`$RUN_DIR/\` (step results, triage output, needs-input.md if present), and the phase rows
in \`$PLAN\`. Quote the lines you relied on in \`evidence\`. If the record does not answer
it, say so plainly — do not infer what the run did.

Return JSON validating against $DRIVE_ENGINE_REL/schemas/ask.json." \
      "$DRIVE_ENGINE/schemas/ask.json" "$RUN_DIR/ask-scope.txt"
    if [ "$STEP_STATUS" = ok ]; then
      node -e '
        const a = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        console.log(a.answer);
        for (const e of a.evidence ?? []) console.log(`  · ${e}`);
      ' "$STEP_OUT"
    else
      echo "drive-ctl: ask failed — $STEP_NOTE" >&2; exit 1
    fi
    ;;

  *)
    echo "drive-ctl: unknown command '$CMD'" >&2; sed -n '6,13p' "$0" >&2; exit 2 ;;
esac
