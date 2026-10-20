#!/usr/bin/env bash
# drive shared library — sourced by drive.sh, drive-ctl.sh and drive-handback.sh, never
# run directly.
#
# Everything here is state the engine reads rather than remembers: the plan's Progress
# table, the heartbeat ledger, the run-dir flags. Keeping it out of drive.sh is what lets
# drive-ctl.sh answer `status` without starting a run.
#
# Expects from its caller: DRIVE_ENGINE and DRIVE_REPO; drive_paths_init sets the rest.

# ---------------------------------------------------------------- layout
# One variable moves every change folder: DRIVE_WORK_DIR (default `work`), relative to
# the checkout root. Change folders are `<work>/changes/<id>/`; lessons and the optional
# reserved-surface list sit directly under `<work>/`.
drive_paths_init() {
  local id="$1"
  DRIVE_WORK_DIR="${DRIVE_WORK_DIR:-work}"
  DRIVE_WORK_DIR="${DRIVE_WORK_DIR%/}"
  WORK_ROOT="$DRIVE_REPO/$DRIVE_WORK_DIR"
  CHANGE_ID="$id"
  CHANGE_REL="$DRIVE_WORK_DIR/changes/$id"
  CHANGE_DIR="$DRIVE_REPO/$CHANGE_REL"
  PLAN="$CHANGE_DIR/plan.md"
  DRIVE_RUN_DIR="$CHANGE_DIR/drive"
  DRIVE_LOG="$CHANGE_DIR/drive-log.md"
  # How to name the engine in printed commands: repo-relative when it is vendored into the
  # checkout, absolute when it lives elsewhere (a shared install).
  case "$DRIVE_ENGINE" in
    "$DRIVE_REPO"/*) DRIVE_ENGINE_REL="${DRIVE_ENGINE#"$DRIVE_REPO"/}" ;;
    *) DRIVE_ENGINE_REL="$DRIVE_ENGINE" ;;
  esac
  export DRIVE_WORK_DIR WORK_ROOT CHANGE_REL CHANGE_DIR PLAN DRIVE_RUN_DIR DRIVE_LOG DRIVE_ENGINE_REL
}

# `drive_cmd ctl` → "bash scripts/drive/drive-ctl.sh", for messages a human copies.
drive_cmd() {
  case "$1" in
    drive) printf 'bash %s/drive.sh' "$DRIVE_ENGINE_REL" ;;
    *) printf 'bash %s/drive-%s.sh' "$DRIVE_ENGINE_REL" "$1" ;;
  esac
}

# The lock lives in the git dir of THIS checkout, so two worktrees never share one.
drive_lock_dir() {
  printf '%s/drive-%s.lock.d' "$(git -C "$DRIVE_REPO" rev-parse --absolute-git-dir)" "$1"
}

# ---------------------------------------------------------------- heartbeat + state
# One line per dispatch and per result — the run's live progress signal ("is it still
# going?" = tail the drive-log) and the data that recalibrates the tiers.
drive_heartbeat() {
  printf '%s %s %s p%s model=%s effort=%s → %s\n' \
    "$(date -Iseconds)" "$1" "$2" "${DRIVE_PHASE:-?}" \
    "${STEP_MODEL:-?}" "${STEP_EFFORT:-?}" "$3" >>"$DRIVE_LOG"
}
drive_state_set() {
  local state="$1"
  node -e '
    const fs=require("fs"); const [f,state,change,phase,step,started,pid]=process.argv.slice(1);
    let s={}; try{s=JSON.parse(fs.readFileSync(f,"utf8"));}catch{}
    Object.assign(s,{change,phase,step,state,started,pid:Number(pid),heartbeat:new Date().toISOString()});
    fs.writeFileSync(f,JSON.stringify(s,null,2));
  ' "$DRIVE_RUN_DIR/state.json" "$state" "$CHANGE_ID" "${DRIVE_PHASE:-}" "${DRIVE_STEP_NAME:-}" \
    "${DRIVE_STARTED:-}" "$$" 2>/dev/null
}

# ---------------------------------------------------------------- per-phase stage
# A phase passes through implemented → reviewed → fixed → verified. The Progress row only
# records the FIRST of those: the implementer flips it to `[x]` when it commits, so a run
# that stopped on a surviving CRITICAL left a row that reads done with its review and
# fixes unfinished — and the resume command the run itself printed skipped that phase
# entirely. The stage map is what a resume re-enters at.
drive_stage_set() {
  local n="$1" stage="$2"
  node -e '
    const fs = require("fs"); const [f, n, stage] = process.argv.slice(1);
    let s = {}; try { s = JSON.parse(fs.readFileSync(f, "utf8")); } catch {}
    s.phases = s.phases ?? {};
    s.phases[n] = stage;
    fs.writeFileSync(f, JSON.stringify(s, null, 2));
  ' "$DRIVE_RUN_DIR/state.json" "$n" "$stage" 2>/dev/null
}
drive_stage_get() {
  node -pe 'try{JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).phases?.[process.argv[2]]??""}catch{""}' \
    "$DRIVE_RUN_DIR/state.json" "$1" 2>/dev/null
}
# Phase numbers whose recorded stage stopped before `fixed`.
drive_unfinished_phases() {
  node -e '
    const fs = require("fs");
    let s = {}; try { s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch {}
    for (const [n, stage] of Object.entries(s.phases ?? {})) {
      if (stage === "implemented" || stage === "reviewed") console.log(n);
    }
  ' "$DRIVE_RUN_DIR/state.json" 2>/dev/null
}

export -f drive_heartbeat drive_state_set drive_stage_set drive_stage_get 2>/dev/null || true

# ---------------------------------------------------------------- plan reading
# Progress rows: `| P<n> <title> | [ ] | notes |`. Open = `[ ]`, in order. `[~]` is a
# deliberately deferred manual gate and is skipped, never re-driven, never flipped to [x].
plan_open_phases() {
  sed -n 's/^|[[:space:]]*P\([0-9][0-9]*\)[^|]*|[[:space:]]*\[ \][[:space:]]*|.*/\1/p' "$PLAN"
}
plan_row_status() {
  sed -n "s/^|[[:space:]]*P$1[^0-9|][^|]*|[[:space:]]*\[\(.\)\][[:space:]]*|.*/\1/p" "$PLAN" | head -1
}
plan_phase_section() {
  awk -v n="$1" '
    $0 ~ "^### P" n "([^0-9]|$)" {inside=1}
    inside && /^### P/ && $0 !~ "^### P" n "([^0-9]|$)" {exit}
    inside && /^## / && !/^### /{exit}
    inside {print}
  ' "$PLAN"
}
# `field: value` lines inside the phase section (route / risk / impl / paths / size).
plan_field() {
  plan_phase_section "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1
}
# `paths:` is a comma-separated list of backticked globs.
plan_paths_file() {
  local n="$1" out="$2"
  plan_field "$n" paths | tr ',' '\n' | sed -e 's/`//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -v '^$' >"$out"
}

# ---------------------------------------------------------------- needs-input
needs_input() {
  local why="$1"
  drive_state_set needs-input
  {
    echo "# drive — $CHANGE_ID needs a human"
    echo
    echo "Stopped at **phase ${DRIVE_PHASE:-?}**, step **${DRIVE_STEP_NAME:-?}**, $(date -Iseconds)."
    echo
    echo "## Why"
    echo
    echo "$why"
    echo
    echo "## Where to look"
    echo
    echo "- drive log: \`$DRIVE_LOG\`"
    echo "- step artifacts: \`$DRIVE_RUN_DIR/\`"
    [ -f "$DRIVE_RUN_DIR/triage-p${DRIVE_PHASE:-x}.json" ] && echo "- triage: \`$DRIVE_RUN_DIR/triage-p${DRIVE_PHASE:-x}.json\`"
    echo
    echo "## Resume"
    echo
    echo "\`\`\`"
    echo "$(drive_cmd drive) $CHANGE_ID"
    echo "\`\`\`"
  } >"$DRIVE_RUN_DIR/needs-input.md"
  drive_heartbeat "RESULT" "${DRIVE_STEP_NAME:-drive}" "needs-input: $(printf '%s' "$why" | head -1 | cut -c1-160)"
  # A desktop notification when one is possible; a headless drive still exits cleanly on
  # this line.
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u critical -a "drive" "drive — $CHANGE_ID needs input" \
      "Phase ${DRIVE_PHASE:-?}: $(printf '%s' "$why" | head -1 | cut -c1-120)" 2>/dev/null
  fi
  echo "drive: NEEDS INPUT — $DRIVE_RUN_DIR/needs-input.md" >&2
  exit 3
}

# pause/resume are checked between steps only: a half-finished step is worse than a
# slightly late pause.
check_control() {
  [ -e "$DRIVE_RUN_DIR/stop.flag" ] && { echo "drive: stop requested."; drive_state_set idle; exit 0; }
  while [ -e "$DRIVE_RUN_DIR/pause.flag" ]; do
    drive_state_set paused; sleep 10
    [ -e "$DRIVE_RUN_DIR/stop.flag" ] && { drive_state_set idle; exit 0; }
  done
  drive_state_set running
}

# A finding the fix pass could not close is a human decision, not a non-event: the next
# phase builds on the defective contract. Before phase p dispatches, every EARLIER phase's
# unfixed-p<N>.md must carry an unfixed-p<N>.ack (`drive-ctl ack <id> <N>`), or the run
# hands back with exit 3.
drive_gate_unfixed() {
  local p="$1" f n open=""
  for f in "$DRIVE_RUN_DIR"/unfixed-p*.md; do
    [ -s "$f" ] || continue
    n="${f##*/unfixed-p}"; n="${n%.md}"
    [ "$n" -lt "$p" ] 2>/dev/null || continue
    [ -e "$DRIVE_RUN_DIR/unfixed-p$n.ack" ] && continue
    # An "obsolete" decline is a CLOSED finding (the code it names is already fixed or gone):
    # it stays in the file for the hand-back, but it is not something the next phase builds on.
    local live; live="$(grep '^- ' "$f" | grep -vcE 'declined twice[^:]*: *obsolete')"
    [ "$live" -gt 0 ] || continue
    open="${open:+$open, }p$n ($live finding(s))"
  done
  [ -n "$open" ] || return 0
  DRIVE_PHASE="$p"; DRIVE_STEP_NAME="gate"
  needs_input "Phase $p would build on findings the fix pass could not close: $open — see \`$DRIVE_RUN_DIR/unfixed-p<N>.md\`. Close them by hand (or decide they can wait), then acknowledge each phase with \`$(drive_cmd ctl) ack $CHANGE_ID <N>\` and resume. An unacknowledged unfixed finding never rides silently into the next phase."
}

triage_and_fix() {
  local n="$1" scope_json="$2"; shift 2
  local -a review_files=("$@")
  local triage="$DRIVE_RUN_DIR/triage-p$n.json"
  # Two statements, not one: `local a=… b=(…$a…)` declares every name first, so `$a` is
  # still unset when the array initialiser reads it — and `set -u` then kills the run.
  local args=(--phase "$n" --out "$triage")
  # The same phase range every stream reviewed, recorded in the triage artifact so the
  # audit trail says what was judged, not just what was found.
  [ -n "${DRIVE_PHASE_BASE:-}" ] && args+=(--range "${DRIVE_PHASE_BASE}..${DRIVE_PHASE_HEAD:-HEAD}")
  for f in "${review_files[@]}"; do args+=(--review "$f"); done
  [ -s "$scope_json" ] && args+=(--scope-findings "$scope_json")
  node "$DRIVE_ENGINE/drive-triage.mjs" "${args[@]}" | tee -a "$DRIVE_LOG"
  local triage_rc=${PIPESTATUS[0]}
  [ "$triage_rc" = 0 ] && { drive_heartbeat "RESULT" "triage" "clean"; return 0; }

  local count fixed_critical=0
  count="$(node -pe 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).findings.length' "$triage")"
  for i in $(seq 0 $((count - 1))); do
    check_control
    local fid sev profile brief fence
    fid="$(node -pe "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')).findings[$i].id" "$triage")"
    sev="$(node -pe "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')).findings[$i].severity" "$triage")"
    profile="$(node -pe "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')).findings[$i].fix_profile" "$triage")"
    # An advisory is recorded, never repaired: it is a signal for the human reading the
    # hand-back, not a defect with an edit that closes it.
    if [ "$profile" = advisory ]; then
      drive_heartbeat "RESULT" "fix" "$fid advisory — no fixer dispatched; $(node -pe "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')).findings[$i].summary" "$triage" | cut -c1-160)"
      continue
    fi
    brief="$(node -pe "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')).findings[$i].fixer_brief" "$triage")"
    fence="$DRIVE_RUN_DIR/fence-p$n-$fid.txt"
    node -e "const f=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')).findings[$i];require('fs').writeFileSync(process.argv[2],f.files.join('\n')+'\n')" "$triage" "$fence"

    # A prescriptive single-file fix routes down a tier; anything needing diagnosis
    # stays up. Cheap models grab plausible-but-wrong fixes on diagnosis work.
    DRIVE_FIX_PRESCRIPTIVE=""
    [ "$profile" = single-file-prescriptive ] && DRIVE_FIX_PRESCRIPTIVE=1
    export DRIVE_FIX_PRESCRIPTIVE

    local fix_attempt=1 declined=0 escalated=0
    local saved_model="${DRIVE_MODEL_fix-}" saved_effort="${DRIVE_EFFORT_fix-}" saved_budget="${DRIVE_BUDGET_fix-}"
    while :; do
      DRIVE_STEP_NAME="fix-$fid"
      run_step fix "$brief" "$DRIVE_ENGINE/schemas/fix.json" "$fence" \
        --note "$fid $sev $profile"
      if [ "$STEP_STATUS" != ok ]; then
        needs_input "Fixer for $fid ($sev) could not run: $STEP_NOTE"
      fi
      # `applied: false` is a legitimate outcome — the finding is obsolete, or it needs
      # diagnosis this fixer is not allowed to do. It is NOT a completed fix, and neither
      # is an empty touched_files. Both used to pass the fence check trivially and be
      # heartbeated as "<id> applied", which silently dropped every declined WARNING.
      local applied note touched_n
      applied="$(node -pe 'try{String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).applied)}catch{"true"}' "$STEP_OUT" 2>/dev/null)"
      note="$(node -pe 'try{String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).note??"")}catch{""}' "$STEP_OUT" 2>/dev/null)"
      touched_n="$(node -pe 'try{(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).touched_files??[]).length}catch{0}' "$STEP_OUT" 2>/dev/null)"
      if [ "$applied" = false ] || [ "${touched_n:-0}" = 0 ]; then
        if [ "$declined" = 0 ]; then
          declined=1
          drive_heartbeat "RESULT" "fix" "$fid DECLINED (applied=$applied, ${touched_n:-0} file(s)) — re-dispatching once: ${note:-no reason given}"
          brief="$brief

PREVIOUS ATTEMPT DECLINED THIS FIX. Its reported reason was: ${note:-none given}.
If the finding is genuinely obsolete or genuinely needs diagnosis you may decline again —
say so in \`note\` and leave \`applied\` false. Otherwise make the edit the brief names."
          continue
        fi
        if [ "$escalated" = 0 ]; then
          drive_heartbeat "RESULT" "fix" "$fid UNFIXED after two dispatches — ${note:-no reason given}"
          # Two fenced fixers declining is where every cross-file finding used to die and
          # ride silently into the next phase. An "obsolete" decline is final; anything
          # else gets ONE dispatch at the top worker tier (DRIVE_ESCALATION_MODEL, default
          # opus/high — never the session tier) with the fence widened to the phase's own
          # declared paths (declared_extra still covers the rest) and a cap doubled
          # explicitly, never silently.
          if ! printf '%s' "$note" | grep -qi '^[[:space:]]*obsolete'; then
            escalated=1
            local esc_cap; esc_cap="$(drive_budget_cap fix)"; esc_cap=$((esc_cap * 2))
            [ -s "$DRIVE_RUN_DIR/paths-p$n.txt" ] && cp "$DRIVE_RUN_DIR/paths-p$n.txt" "$fence"
            DRIVE_MODEL_fix="${DRIVE_ESCALATION_MODEL:-opus}"; DRIVE_EFFORT_fix=high; DRIVE_BUDGET_fix="$esc_cap"
            DRIVE_FIX_PRESCRIPTIVE=""; export DRIVE_FIX_PRESCRIPTIVE
            drive_heartbeat "RESULT" "fix" "$fid ESCALATING to the top worker tier (${DRIVE_ESCALATION_MODEL:-opus}/high, fence = the phase's declared paths, cap \$$esc_cap — doubled from \$$((esc_cap / 2)))"
            brief="$brief

ESCALATED. Two fenced fixers declined this finding; the last reason was:
${note:-none given}.
The fence is now the phase's declared paths ($(tr '\n' ' ' <"$fence")); any file outside
them goes in \`declared_extra[]\` with a reason. Diagnose the root cause, then apply the
fix across EVERY file the invariant spans — producer, consumer and the tests that pin the
old shape — in one coherent commit. Decline only if the fix hinges on a decision that is
the user's to make (a cost-versus-contract trade, a new paid eval, a plan amendment) and
name that decision in \`note\`."
            continue
          fi
        else
          drive_heartbeat "RESULT" "fix" "$fid UNFIXED after escalation — ${note:-no reason given}"
        fi
        if [ "$sev" = CRITICAL ]; then
          needs_input "The fixer declined CRITICAL finding $fid twice (\`applied: false\` or no files touched)$([ "$escalated" = 1 ] && echo ', and so did the escalation'). Reported reason: ${note:-none given}. A declined CRITICAL is not a fixed CRITICAL — see \`$triage\`."
        fi
        printf -- '- %s (%s) — fixer declined twice%s: %s\n' "$fid" "$sev" \
          "$([ "$escalated" = 1 ] && echo ' and the escalation declined')" "${note:-no reason given}" \
          >>"$DRIVE_RUN_DIR/unfixed-p$n.md"
        break
      fi
      if node "$DRIVE_ENGINE/drive-scope-check.mjs" --fence "$STEP_OUT" "$fence"; then
        drive_heartbeat "RESULT" "fix" "$fid applied"
        [ "$sev" = CRITICAL ] && fixed_critical=1
        break
      fi
      if [ "$fix_attempt" -ge 2 ]; then
        needs_input "Fixer for $fid touched files outside its fence twice. Fence: $(tr '\n' ' ' <"$fence")"
      fi
      drive_heartbeat "RESULT" "fix" "$fid REJECTED — touched a file outside the fence; re-dispatching once with the fence restated"
      brief="$brief

REJECTED: your previous attempt modified a file this brief does not allow. The fence is
absolute: $(tr '\n' ' ' <"$fence"). Anything else must appear in declared_extra[] with a
reason BEFORE you touch it. Redo the fix within the fence."
      fix_attempt=$((fix_attempt + 1))
    done
    # The escalation's tier/cap overrides are per finding; a standing DRIVE_*_fix from the
    # caller's environment survives them.
    DRIVE_MODEL_fix="$saved_model"; DRIVE_EFFORT_fix="$saved_effort"; DRIVE_BUDGET_fix="$saved_budget"
    [ -n "$saved_model" ] || unset DRIVE_MODEL_fix
    [ -n "$saved_effort" ] || unset DRIVE_EFFORT_fix
    [ -n "$saved_budget" ] || unset DRIVE_BUDGET_fix
  done

  # ---- one re-review, and only when a CRITICAL was fixed.
  if [ "$fixed_critical" = 1 ]; then
    DRIVE_STEP_NAME="rereview"; check_control
    run_step review "/phase-review $CHANGE_ID phase $n --rereview" \
      "$DRIVE_ENGINE/schemas/review.json" "$DRIVE_RUN_DIR/paths-p$n.txt" \
      --tag rereview --note "Important-only convergence pass"
    if [ "$STEP_STATUS" = ok ]; then
      local rtriage="$DRIVE_RUN_DIR/triage-p$n-rereview.json"
      node "$DRIVE_ENGINE/drive-triage.mjs" --phase "$n" --out "$rtriage" --review "$STEP_OUT" \
        ${DRIVE_PHASE_BASE:+--range "${DRIVE_PHASE_BASE}..${DRIVE_PHASE_HEAD:-HEAD}"} | tee -a "$DRIVE_LOG"
      if [ "${PIPESTATUS[0]}" = 2 ]; then
        drive_heartbeat "RESULT" "rereview" "CRITICAL still open"
        needs_input "A CRITICAL finding on phase $n survived one fix pass and one re-review. A second re-review is not authorized — this is yours. See \`$rtriage\`."
      fi
      drive_heartbeat "RESULT" "rereview" "converged"
    else
      needs_input "Re-review after a CRITICAL fix on phase $n could not run: $STEP_NOTE"
    fi
  fi
}
