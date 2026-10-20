#!/usr/bin/env bash
# shellcheck disable=SC2034  # DRIVE_STEP_NAME is read by drive-lib.sh (needs_input, heartbeat)
# drive — one phase, end to end. Sourced by drive.sh.
#
#   run_phase <n>
#
# implement → scope check → review (two Claude lenses in parallel when the phase is
# risk-flagged, a single mandatory pass when the diff outgrew its row or left its declared
# paths) → triage → fixers →
# at most one re-review.
#
# It lives in its own file for the same reason drive-lib.sh does: drive.sh stays short,
# and the resume-stage, phase-range and mandatory-review logic all land inside this
# function.
#
# Expects from its caller: DRIVE_REPO, DRIVE_ENGINE, the paths drive_paths_init sets, and
# drive-lib.sh + drive-step.sh already sourced.

# ---------------------------------------------------------------- the Progress flip
# The implementer flips its `## Progress` row AFTER its own commit (the row carries that
# commit's SHA, so it cannot be staged with it), which leaves plan.md dirty and relies on
# "the next phase folds it in". Nothing enforced that: a run that stopped, a phase whose
# successor staged only its own paths, or a final phase without the close-out commit all
# left a plan whose HEAD says `[ ]` for work that landed. Every later reader — a resume,
# `/change-status`, a reviewer reading the range — reads HEAD, not the working tree.
#
# So the engine closes it: one docs commit carrying only plan.md, made BEFORE the phase
# range is captured so the review lenses see the row they are reviewing. Hooks run
# normally (no --no-verify, no hooksPath override). A failed commit is logged, never
# retried with a bypass flag: a red hook is a real finding.
#
# The skills stage plan.md with the code wherever they still can; this is the backstop
# for the SHA-bearing flip that structurally cannot be.
drive_commit_plan_flip() {
  local n="$1" rel="$CHANGE_REL/plan.md"
  git -C "$DRIVE_REPO" diff --quiet HEAD -- "$rel" 2>/dev/null && return 0
  git -C "$DRIVE_REPO" add -- "$rel" || {
    drive_heartbeat "RESULT" "implement" "PLAN-FLIP-FAILED could not stage $rel"; return 0; }
  local trailers="Co-Authored-By: ${DRIVE_COAUTHOR:-Claude Opus 5.5 <noreply@anthropic.com>}"
  [ -n "${DRIVE_SESSION_URL:-}" ] && trailers="$trailers
Claude-Session: ${DRIVE_SESSION_URL}"
  if git -C "$DRIVE_REPO" commit -q -F - <<EOF
docs($CHANGE_ID): P$n progress ($CHANGE_ID p$n)

The implementer left the Progress flip for phase $n uncommitted. Committed by the
drive engine so plan.md in HEAD matches the phase that just landed.

$trailers
EOF
  then
    drive_heartbeat "RESULT" "implement" "PLAN-FLIP-COMMITTED $(git -C "$DRIVE_REPO" rev-parse --short HEAD 2>/dev/null) — $rel"
  else
    drive_heartbeat "RESULT" "implement" "PLAN-FLIP-FAILED commit rejected (hook?) — $rel stays dirty"
  fi
}

run_phase() {
  local n="$1"
  export DRIVE_PHASE="$n"
  local route risk paths_file size notes_file
  route="$(plan_field "$n" route)"; [ -n "$route" ] || route=implement
  risk="$(plan_field "$n" risk)"; [ -n "$risk" ] || risk=none
  size="$(plan_field "$n" size)"; [ -n "$size" ] || size=300
  paths_file="$DRIVE_RUN_DIR/paths-p$n.txt"; plan_paths_file "$n" "$paths_file"
  export DRIVE_ROW_ROUTE="$route"
  notes_file="$CHANGE_DIR/implementation-notes/p$n.md"

  # `route: e2e` has no skill of its own: browser-level work is still one implement step
  # whose `Done when:` names the end-to-end check.
  local skill=/implement-phase
  case "$route" in tdd) skill=/tdd-phase ;; esac

  # ---- implement
  # A phase is not one step. The implementer flips its Progress row to `[x]` as soon as it
  # commits, so a run that then stopped on a surviving CRITICAL left a row that LOOKS done
  # with its review and fixes unfinished — and the documented resume command skipped it.
  # The per-phase stage in drive/state.json is what a resume re-enters at.
  local stage impl_json range_file="$DRIVE_RUN_DIR/range-p$n.txt"
  stage="$(drive_stage_get "$n")"
  impl_json="$DRIVE_RUN_DIR/implement-p$n.json"
  case "$stage" in
    implemented | reviewed) [ -s "$impl_json" ] || stage="" ;;
    *) stage="" ;;
  esac

  # One range for the whole phase, captured once and shared by every lens: the HEAD the
  # implementer started from, and the HEAD it left behind. `HEAD~1..HEAD` is wrong the
  # moment a phase makes two commits — and the final phase is explicitly told to make a
  # separate close-out-plan commit, so the feature commit would fall outside the review.
  local phase_base phase_head
  if [ -n "$stage" ]; then
    phase_base="$(sed -n '1p' "$range_file" 2>/dev/null)"
    phase_head="$(sed -n '2p' "$range_file" 2>/dev/null)"
    drive_heartbeat "RESULT" "implement" "phase $n already committed (stage=$stage) — resuming at review"
  else
    DRIVE_STEP_NAME="implement"; check_control
    phase_base="$(git -C "$DRIVE_REPO" rev-parse --short HEAD 2>/dev/null)"
    local prompt="$skill $CHANGE_ID phase $n"
    [ -f "$notes_file" ] && prompt="$prompt

Depth for this phase is in \`$CHANGE_REL/implementation-notes/p$n.md\` — read it."
    run_step implement "$prompt" "$DRIVE_ENGINE/schemas/impl.json" "$paths_file" \
      --note "route=$route risk=$risk"
    case "$STEP_STATUS" in
      ok) ;;
      needs-input) needs_input "Implement step for phase $n could not run: $STEP_NOTE" ;;
      *) needs_input "Implement step for phase $n failed twice: $STEP_NOTE" ;;
    esac
    impl_json="$STEP_OUT"
    drive_heartbeat "RESULT" "implement" "$STEP_NOTE"

    local status; status="$(node -pe 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).status' "$impl_json" 2>/dev/null)"
    case "$status" in
      committed)
        # Denials on a step that still delivered are a ledger entry (already heartbeated).
        # Denials on one that did NOT deliver are the blocked case.
        ;;
      blocked|needs_input)
        needs_input "Phase $n returned \`$status\`: $(node -pe 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).notes' "$impl_json" 2>/dev/null)${STEP_DENIALS:+

A guard also denied $STEP_DENIALS action(s) during this step: ${STEP_DENIAL_TEXT:-unrecorded}}" ;;
      *) needs_input "Phase $n returned an unreadable result (no status) — see $impl_json" ;;
    esac
    drive_commit_plan_flip "$n"
    phase_head="$(git -C "$DRIVE_REPO" rev-parse --short HEAD 2>/dev/null)"
    printf '%s\n%s\n' "$phase_base" "$phase_head" >"$range_file"
    drive_stage_set "$n" implemented
  fi
  [ -n "$phase_base" ] || phase_base="$(git -C "$DRIVE_REPO" rev-parse --short HEAD~1 2>/dev/null)"
  [ -n "$phase_head" ] || phase_head="$(git -C "$DRIVE_REPO" rev-parse --short HEAD 2>/dev/null)"
  export DRIVE_PHASE_BASE="$phase_base" DRIVE_PHASE_HEAD="$phase_head"
  local range_note="Review exactly the phase range \`git diff $phase_base..$phase_head\` — nothing outside it."

  # ---- scope check: undeclared out-of-scope files and an oversized diff over the phase
  # range.
  local scope_json="$DRIVE_RUN_DIR/scope-p$n.json" force_review=0
  node "$DRIVE_ENGINE/drive-scope-check.mjs" "$impl_json" "$paths_file" "$size" "$scope_json" \
    --bookkeeping "$CHANGE_REL"
  case $? in
    1) force_review=1 ;;   # size trigger only
    2) force_review=1 ;;   # unplanned files (already written as findings)
    3) force_review=1 ;;
  esac

  # ---- review
  # A phase is risk-flagged by its own `risk:` line, or — when the project keeps a
  # reserved-surface list at <work>/surface-globs.json — by touching one of those paths
  # whatever the row claimed.
  local risk_flagged=0 surfaces="$WORK_ROOT/surface-globs.json"
  [ "$risk" != "none" ] && risk_flagged=1
  if [ "$risk_flagged" = 0 ] && [ -f "$surfaces" ] \
     && node "$DRIVE_ENGINE/drive-scope-check.mjs" --surface "$impl_json" "$surfaces"; then
    risk_flagged=1
  fi

  local -a review_files=()
  if [ "$risk_flagged" = 1 ]; then
    DRIVE_STEP_NAME="review"
    for lens in drift safety; do
      ( run_step review "/phase-review $CHANGE_ID phase $n --lens $lens

$range_note" \
          "$DRIVE_ENGINE/schemas/review.json" "$paths_file" --lens "$lens" \
          --note "risk=$risk lens=$lens"
        echo "$STEP_STATUS|$STEP_NOTE" >"$DRIVE_RUN_DIR/review-$lens-p$n.status" ) &
    done
    wait
    for lens in drift safety; do
      local st note
      st="$(cut -d'|' -f1 <"$DRIVE_RUN_DIR/review-$lens-p$n.status" 2>/dev/null)"
      note="$(cut -d'|' -f2- <"$DRIVE_RUN_DIR/review-$lens-p$n.status" 2>/dev/null)"
      if [ "$st" = ok ] && [ -s "$DRIVE_RUN_DIR/review-$lens-p$n.json" ]; then
        review_files+=("$DRIVE_RUN_DIR/review-$lens-p$n.json")
        drive_heartbeat "RESULT" "review-$lens" "ok"
      elif [ "$st" = needs-input ]; then
        # A refused dispatch (tier floor, a guard's deny) is a decision, not a flaky step.
        # Degrading past it is how a false APPROVED gets manufactured.
        needs_input "Reviewer lens \`$lens\` on phase $n refused to run: $note"
      else
        drive_heartbeat "RESULT" "review-$lens" "unavailable — ${st:-no result}; merging the remaining lens"
      fi
    done
    # A risk-flagged phase with zero surviving review lenses is unreviewed, and an
    # unreviewed surface phase is exactly what this engine exists to prevent.
    [ "${#review_files[@]}" -gt 0 ] || needs_input "Phase $n is risk-flagged (\`risk: $risk\`) but both review lenses failed. It is committed and unreviewed — review it before going further."
  elif [ "$force_review" = 1 ]; then
    DRIVE_STEP_NAME="review"
    run_step review "/phase-review $CHANGE_ID phase $n

$range_note" \
      "$DRIVE_ENGINE/schemas/review.json" "$paths_file" \
      --note "full pass (size/scope trigger)"
    drive_heartbeat "RESULT" "review" "$STEP_NOTE"
    # This review is MANDATORY — the phase either blew past 2x its declared size or
    # touched files it never declared. Treating a failed mandatory review as optional let
    # triage see only the scope report, return clean, and finish the drive.
    case "$STEP_STATUS" in
      ok) review_files+=("$STEP_OUT") ;;
      needs-input) needs_input "The mandatory size/scope review of phase $n refused to run: $STEP_NOTE" ;;
      *) needs_input "Phase $n triggered a mandatory review (diff over 2x its declared \`size:\`, or undeclared files) and that review failed twice: $STEP_NOTE. The phase is committed and unreviewed." ;;
    esac
  else
    drive_heartbeat "RESULT" "review" "skipped — phase not risk-flagged and diff within 2x the row's size"
    # No review means no triage, so an advisory in the scope report would otherwise die in
    # the gitignored run log. It goes to the tracked ledger instead.
    local adv
    while IFS= read -r adv; do
      [ -n "$adv" ] && drive_heartbeat "RESULT" "advisory" "$adv — no fixer dispatched"
    done < <(node -e '
      try { const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
        for (const f of s.findings||[]) if (f.advisory) console.log(String(f.summary).replace(/\n/g," ")); } catch {}' \
      "$scope_json" 2>/dev/null)
    drive_stage_set "$n" fixed
    return 0
  fi
  drive_stage_set "$n" reviewed

  # ---- triage + fixes
  triage_and_fix "$n" "$scope_json" "${review_files[@]}"
  drive_stage_set "$n" fixed
}
