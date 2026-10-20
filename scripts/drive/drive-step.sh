#!/usr/bin/env bash
# shellcheck disable=SC2034  # STEP_* and DRIVE_* are read by the files that source this one
# drive step runner. Sourced by drive.sh and drive-ctl.sh.
#
#   run_step <role> <prompt> <schema> <scope-paths-file> [--lens X] [--tag T] [--note N]
#
# One step = one fresh model context. The runner owns everything that is a property of
# the DISPATCH rather than of the work: which tier takes it, under which budget, how long
# it may run, and what to do when the CLI says "you've hit your limit".
#
# It sets, on return:
#   STEP_STATUS    ok | needs-input | failed
#   STEP_OUT       path to the result JSON (schema-shaped; empty on failure)
#   STEP_MODEL / STEP_EFFORT
#   STEP_NOTE      one line for the heartbeat
#
# Test seams (used only by drive-selftest.sh):
#   DRIVE_STEP_STUB=1          return canned JSON from stubs/, call no CLI
#   DRIVE_STUB_VARIANT=<v>     pick <role>-<v>.json (and <role>-<v>-<attempt>.json)
#   CLAUDE_LIMIT_SIMULATE=1    the claude backend returns a usage-limit banner
#   DRIVE_FAKE_RESET_SECONDS=N a simulated limit resets N seconds from now
#   DRIVE_STUB_SLEEP_<role>=N  the stub backend naps N seconds before returning, so a
#                              self-test has a window to kill or stop the run inside a step
#   DRIVE_MODEL_<role> / DRIVE_EFFORT_<role>   override the floor (the floor assertion still runs)
#   DRIVE_STEP_TIMEOUT=N       wall-clock seconds a `claude -p` may run (default 5400)

# ---------------------------------------------------------------- tiers and floors
# Tier order, so "reviewer >= implementer" can be asserted on the alias alone.
drive_tier_rank() {
  case "$1" in
    haiku) echo 1 ;;
    sonnet) echo 2 ;;
    opus) echo 3 ;;
    fable) echo 4 ;;
    *) echo 0 ;;
  esac
}

# Rank a concrete dispatch. Model ids are the alias, or alias-prefixed (`opus-4-1`).
drive_rank_of() {
  drive_tier_rank "${1%%-*}"
}

# Per-role floor. The reviewer is never routed below the implementer (asserted in
# run_step); a prescriptive single-file fix is the only work that drops a tier.
drive_floor_model() {
  case "$1" in
    implement) echo opus ;;
    review) echo opus ;;
    fix) [ -n "${DRIVE_FIX_PRESCRIPTIVE:-}" ] && echo sonnet || echo opus ;;
    verify) echo sonnet ;;
    ask) echo haiku ;;
    *) echo opus ;;
  esac
}
drive_floor_effort() {
  case "$1" in
    implement) echo high ;;
    review) echo high ;;
    fix) [ -n "${DRIVE_FIX_PRESCRIPTIVE:-}" ] && echo medium || echo high ;;
    verify) echo high ;;
    ask) echo low ;;
    *) echo high ;;
  esac
}
drive_budget_cap() {
  # DRIVE_BUDGET_<role> lowers a cap for a scoped run (the self-test's real pass); it never
  # raises one silently — a budget-kill retry doubles the cap explicitly and says so.
  local o; o="$(eval "printf '%s' \"\${DRIVE_BUDGET_$1:-}\"")"
  [ -n "$o" ] && { echo "$o"; return; }
  case "$1" in
    implement) echo 25 ;; review) echo 10 ;; fix) echo 8 ;; verify) echo 5 ;; ask) echo 1 ;;
    *) echo 5 ;;
  esac
}
# Wall-clock ceiling for one `claude -p`. A step that hangs — a tool call waiting on a
# server that never answers, a CLI stuck on a prompt it cannot see — would otherwise hold
# the lock forever. 90 minutes is longer than any honest phase and shorter than a night.
drive_step_timeout() {
  local t="${DRIVE_STEP_TIMEOUT:-5400}"
  case "$t" in '' | *[!0-9]*) t=5400 ;; esac
  echo "$t"
}

# Is this path inside the step's DECLARED scope? Used to bound a reset to what the step
# said it would touch — `**` behaves as `*` in a `case` pattern, which matches across `/`.
drive_path_in_scope() {
  local p="${1#./}" file="$2" g
  [ -n "$file" ] && [ -s "$file" ] || return 0
  while IFS= read -r g; do
    g="${g#./}"; g="${g%/}"
    [ -n "$g" ] || continue
    # shellcheck disable=SC2254
    case "$p" in $g | $g/*) return 0 ;; esac
  done <"$file"
  return 1
}

# ---------------------------------------------------------------- limit memory
# A limit is remembered for the run, with its reset time, so a banner whose reset time
# could not be parsed still sleeps against the last one that could.
DRIVE_LIMITS_FILE=""
drive_limits_file() {
  DRIVE_LIMITS_FILE="${DRIVE_RUN_DIR:-/tmp}/limits.json"
  [ -f "$DRIVE_LIMITS_FILE" ] || printf '{}\n' >"$DRIVE_LIMITS_FILE"
  printf '%s' "$DRIVE_LIMITS_FILE"
}
drive_limit_record() {
  local provider="$1" secs="${2:-}" until_ts
  [ -n "$secs" ] && [ "$secs" -gt 0 ] 2>/dev/null || secs="${DRIVE_LIMIT_POLL_SECONDS:-900}"
  until_ts=$(( $(date +%s) + secs ))
  node -e '
    const fs=require("fs"); const [f,p,until]=process.argv.slice(1);
    let s={}; try{s=JSON.parse(fs.readFileSync(f,"utf8"));}catch{}
    s[p]={until:Number(until)};
    fs.writeFileSync(f,JSON.stringify(s));
  ' "$(drive_limits_file)" "$provider" "$until_ts" 2>/dev/null
}
drive_limit_remaining() {
  local provider="$1" until_ts now
  until_ts="$(node -pe 'try{JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))[process.argv[2]]?.until??""}catch{""}' \
    "$(drive_limits_file)" "$provider" 2>/dev/null)"
  case "$until_ts" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date +%s)
  [ "$until_ts" -gt "$now" ] && echo $((until_ts - now))
}
drive_limit_active() {
  local r; r="$(drive_limit_remaining "$1")"
  [ -n "$r" ]
}

# ---------------------------------------------------------------- limit detection
# The CLI announces a usage limit in prose; there is no stable machine code for it. Any
# banner we cannot parse a reset time out of is treated as "limited, unknown reset" and
# polled — never guessed at. The pattern is anchored to the CLI's own wording and is only
# ever matched against the CLI's stderr or an is_error envelope — never the model's
# result text, which may legitimately discuss rate limits of the product being built.
DRIVE_LIMIT_RE="hit your [a-z0-9 -]*limit|usage limit reached|rate_limit_error|error type rate_limit"

drive_is_limit_banner() { grep -qiE "$DRIVE_LIMIT_RE" "$1" 2>/dev/null; }

# Limited = the CLI's stderr carries the banner, or the JSON envelope is an error whose
# result carries it. Call BEFORE the envelope is appended to the raw log.
drive_step_limited() {
  local stderr_log="$1" env_json="$2"
  drive_is_limit_banner "$stderr_log" && return 0
  node -e '
    const re=new RegExp(process.argv[2],"i");
    try{const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      process.exit(j.is_error && re.test(String(j.result??"")+" "+String(j.subtype??"")) ? 0 : 1);}
    catch{process.exit(1)}' "$env_json" "$DRIVE_LIMIT_RE" 2>/dev/null
}

# Seconds until the reset named in the text, or "" when there is none to parse.
drive_parse_reset_seconds() {
  local file="$1" raw now target
  [ -n "${DRIVE_FAKE_RESET_SECONDS:-}" ] && { echo "$DRIVE_FAKE_RESET_SECONDS"; return; }
  raw="$(grep -oiE '(resets?|try again) (at|in) [^.,)]*' "$file" 2>/dev/null | head -1)"
  [ -n "$raw" ] || return 0
  now=$(date +%s)
  if printf '%s' "$raw" | grep -qiE ' in '; then
    local n unit
    n="$(printf '%s' "$raw" | grep -oE '[0-9]+' | head -1)"
    unit="$(printf '%s' "$raw" | grep -oiE '(second|minute|hour|day)' | head -1 | tr 'A-Z' 'a-z')"
    [ -n "$n" ] || return 0
    case "$unit" in
      second) echo "$n" ;; minute) echo $((n * 60)) ;; hour) echo $((n * 3600)) ;;
      day) echo $((n * 86400)) ;; *) echo $((n * 60)) ;;
    esac
    return
  fi
  local at; at="$(printf '%s' "$raw" | sed -E 's/.*(at) //I')"
  target=$(date -d "$at" +%s 2>/dev/null) || return 0
  [ "$target" -le "$now" ] && target=$((target + 86400))
  echo $((target - now))
}

# ---------------------------------------------------------------- lessons pack
# Lessons ride the review and verify dispatches as an appended system prompt. Path-scoped
# rule files do not load for code a reviewer reads through `git diff`, so the engine hands
# them over explicitly. Sources, in order: DRIVE_LESSONS_FILES (space-separated paths),
# else `.claude/rules/lessons-*.md` plus `<work>/lessons.md`. Capped so a large lesson set
# cannot crowd out the review itself. Returns non-zero when there is nothing to send.
#   drive_lessons_pack <out-file>
drive_lessons_pack() {
  local out="$1" repo="${DRIVE_REPO:-.}" cap="${DRIVE_LESSONS_MAX_BYTES:-40000}" f
  local -a files=()
  if [ -n "${DRIVE_LESSONS_FILES:-}" ]; then
    read -r -a files <<<"$DRIVE_LESSONS_FILES"
  else
    for f in "$repo"/.claude/rules/lessons-*.md "$repo/${DRIVE_WORK_DIR:-work}/lessons.md"; do
      [ -s "$f" ] && files+=("$f")
    done
  fi
  [ "${#files[@]}" -gt 0 ] || return 1
  { echo "# Project lessons (treat as review priors)"; echo
    for f in "${files[@]}"; do [ -s "$f" ] && { cat "$f"; echo; }; done
  } | head -c "$cap" >"$out"
  [ -s "$out" ]
}

# ---------------------------------------------------------------- the backend
# Returns 0 ok / 10 limited / 11 budget-kill / 13 timed out / 1 failed. Raw output lands
# in $raw_log, the schema-shaped result in $out.
drive_backend_claude() {
  local role="$1" prompt="$2" schema="$3" model="$4" effort="$5" cap="$6" out="$7" raw_log="$8"
  if [ "${CLAUDE_LIMIT_SIMULATE:-}" = "1" ]; then
    printf "You've hit your session limit. Your limit resets in %s seconds.\n" \
      "${DRIVE_FAKE_RESET_SECONDS:-900}" >"$raw_log"
    return 10
  fi
  local args=(-p "$prompt" --output-format json --model "$model" --effort "$effort"
    --dangerously-skip-permissions --max-budget-usd "$cap")
  [ -n "$schema" ] && args+=(--json-schema "$(cat "$schema")")
  case "$role" in
    review | verify | ask) args+=(--disallowedTools Edit Write NotebookEdit) ;;
  esac
  [ "$role" = verify ] && args+=(--agent drive-verifier)
  [ "$role" = fix ] && args+=(--agent drive-fixer)
  case "$role" in
    review | verify)
      local pack="${DRIVE_RUN_DIR:-.}/lessons-${DRIVE_STEP_TAG:-$role}-p${DRIVE_PHASE:-x}.md"
      drive_lessons_pack "$pack" && args+=(--append-system-prompt-file "$pack")
      ;;
  esac

  local env_json rc secs; env_json="$(mktemp)"; secs="$(drive_step_timeout)"
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 30 "$secs" claude "${args[@]}" </dev/null >"$env_json" 2>"$raw_log"
    rc=$?
  else
    # No coreutils `timeout`: a watchdog subshell does the same job.
    claude "${args[@]}" </dev/null >"$env_json" 2>"$raw_log" &
    local cpid=$! wpid
    ( sleep "$secs"; kill -TERM "$cpid" 2>/dev/null; sleep 30; kill -KILL "$cpid" 2>/dev/null ) &
    wpid=$!
    wait "$cpid"; rc=$?
    if kill -0 "$wpid" 2>/dev/null; then
      kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
    else
      rc=124
    fi
  fi
  local limited=0
  drive_step_limited "$raw_log" "$env_json" && limited=1
  cat "$env_json" >>"$raw_log"
  if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
    printf '\ndrive-step: step exceeded DRIVE_STEP_TIMEOUT=%ss and was killed\n' "$secs" >>"$raw_log"
    rm -f "$env_json"; return 13
  fi
  if [ $rc -ne 0 ] || [ ! -s "$env_json" ]; then
    [ "$limited" = 1 ] && { rm -f "$env_json"; return 10; }
    rm -f "$env_json"; return 1
  fi
  # A budget kill surfaces as is_error with the cap named; treat it as infra, not failure.
  if node -e '
      const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      process.exit(j.is_error && /budget|max-budget|cost limit/i.test(JSON.stringify(j.result||j.subtype||"")) ? 0 : 1);
    ' "$env_json" 2>/dev/null; then
    rm -f "$env_json"; return 11
  fi
  # .structured_output is the parsed object; .result is the same content as a string on
  # older CLIs or schema-less steps.
  if ! node -e '
      const fs=require("fs"); const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      let o=j.structured_output;
      if (o==null) { try { o=JSON.parse(String(j.result??"")); } catch { o=null; } }
      if (o==null) process.exit(2);
      fs.writeFileSync(process.argv[2], JSON.stringify(o,null,2));
    ' "$env_json" "$out" 2>>"$raw_log"; then
    [ "$limited" = 1 ] && { rm -f "$env_json"; return 10; }
    rm -f "$env_json"; return 1
  fi
  STEP_COST="$(node -e 'try{console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).total_cost_usd??"")}catch{}' "$env_json" 2>/dev/null)"
  STEP_DENIALS="$(node -e 'try{const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).permission_denials;console.log(Array.isArray(d)&&d.length?d.length:"")}catch{}' "$env_json" 2>/dev/null)"
  # The heartbeat ledger (`<work>/changes/<id>/drive-log.md`) is TRACKED. The
  # denials this engine manufactures are exactly the credential-bearing ones: a step denied
  # a write to a credential file carries the key inside `tool_input`. So the ledger gets the tool
  # name and a count, nothing else; the full payload goes to the gitignored run dir.
  STEP_DENIAL_TEXT="$(node -e '
    const fs = require("fs");
    const [src, dump] = process.argv.slice(1);
    let d = [];
    try { d = JSON.parse(fs.readFileSync(src, "utf8")).permission_denials ?? []; } catch {}
    if (!d.length) process.exit(0);
    try { fs.writeFileSync(dump, JSON.stringify(d, null, 2)); } catch {}
    const counts = new Map();
    for (const x of d) { const k = String(x.tool_name ?? "?"); counts.set(k, (counts.get(k) ?? 0) + 1); }
    console.log([...counts].map(([k, n]) => (n > 1 ? `${k}x${n}` : k)).join(", ").slice(0, 120));
  ' "$env_json" "$DRIVE_RUN_DIR/denials-$(date +%Y%m%d-%H%M%S)-$$.log" 2>/dev/null)"
  rm -f "$env_json"
  return 0
}

# ---------------------------------------------------------------- the stub backend
# Deterministic self-tests need the engine's control flow exercised without a model.
# The stub returns canned JSON AND reproduces the step's observable side effects — an
# implement stub creates its touched_files, flips the phase's Progress row and commits —
# so "the Progress row flipped" is a real assertion, not a mocked one.
drive_backend_stub() {
  local role="$1" prompt="$2" out="$3" attempt="$4"
  # The simulated limit belongs to the BACKEND, so it has to fire here too — otherwise
  # the limit-wait path is the one thing the self-test could never exercise.
  [ "${CLAUDE_LIMIT_SIMULATE:-}" = "1" ] && return 10

  # A step that returns instantly gives a self-test no window to kill or stop it in. This
  # nap is the window, and nothing else reads it.
  local nap; nap="$(eval "printf '%s' \"\${DRIVE_STUB_SLEEP_${role}:-}\"")"
  [ -n "$nap" ] && sleep "$nap"

  # Per-role variants beat the run-wide one; a phase-keyed stub is the fallback so a
  # multi-phase run can give each row its own canned result without any variant at all.
  local dir="$DRIVE_ENGINE/stubs" v f=""
  v="$(eval "printf '%s' \"\${DRIVE_STUB_VARIANT_${role}:-\${DRIVE_STUB_VARIANT:-}}\"")"
  local -a cands=()
  [ -n "$v" ] && cands+=("$dir/$role-$v-$attempt.json" "$dir/$role-$v.json")
  cands+=("$dir/$role-p${DRIVE_PHASE:-x}-$attempt.json" "$dir/$role-p${DRIVE_PHASE:-x}.json"
          "$dir/$role-$attempt.json" "$dir/$role.json")
  for cand in "${cands[@]}"; do [ -f "$cand" ] && { f="$cand"; break; }; done
  [ -n "$f" ] || { echo "drive-step: no stub for role=$role variant=$v phase=${DRIVE_PHASE:-x} attempt=$attempt" >&2; return 1; }

  mkdir -p "$DRIVE_RUN_DIR"
  printf '%s' "$prompt" >"$DRIVE_RUN_DIR/prompt-${DRIVE_STEP_TAG:-$role}-p${DRIVE_PHASE:-x}.txt"
  case "$(node -e 'try{console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).stub_outcome??"")}catch{}' "$f")" in
    limit) return 10 ;;
    budget-kill)
      # Simulate a step killed mid-edit: leave dirt behind so the reset is observable.
      local dirt="$DRIVE_REPO/${DRIVE_STUB_DIRT:-src/toy.ts}"
      mkdir -p "$(dirname "$dirt")"
      printf 'partial work from a killed step\n' >>"$dirt"
      return 11 ;;
  esac
  node "$DRIVE_ENGINE/drive-stub-apply.mjs" "$f" "$out" "$DRIVE_REPO" \
    "${CHANGE_REL:-}" "${DRIVE_PHASE:-}" >>"$DRIVE_RUN_DIR/stub.log" 2>&1 || return 1
  return 0
}

# ---------------------------------------------------------------- the step
run_step() {
  local role="$1" prompt="$2" schema="$3" scope_file="$4"; shift 4
  local lens="" note="" tag=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --lens) lens="$2"; shift 2 ;;
      --note) note="$2"; shift 2 ;;
      --tag)  tag="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  STEP_STATUS=failed; STEP_OUT=""; STEP_NOTE=""; STEP_COST=""; STEP_DENIALS=""; STEP_DENIAL_TEXT=""
  DRIVE_STEP_TAG="${tag:-${role}${lens:+-$lens}}"
  local out raw_log; out="$DRIVE_RUN_DIR/${role}${lens:+-$lens}-p${DRIVE_PHASE:-x}.json"
  raw_log="$DRIVE_RUN_DIR/${role}${lens:+-$lens}-p${DRIVE_PHASE:-x}.log"
  mkdir -p "$DRIVE_RUN_DIR"; : >"$raw_log"

  # Steer text is consumed here so every backend sees it identically — but only by an
  # ENGINE step. `drive-ctl ask` calls run_step in the same run dir; letting it swallow the
  # queue meant a user's steering was answered back at them instead of reaching the work.
  # The `mv` IS the consumption and comes first: an append racing it lands in a new file.
  # The rename and `drive-ctl steer`'s append take the SAME lock, so an append whose file
  # descriptor was already open when the rename happened cannot land in the archive.
  if [ "$role" != ask ] && [ -s "$DRIVE_RUN_DIR/steer.md" ]; then
    local steer_archive steer_moved=1
    steer_archive="$DRIVE_RUN_DIR/steer-consumed-$(date +%Y%m%d-%H%M%S)-$$.md"
    if command -v flock >/dev/null 2>&1; then
      ( flock 9; mv "$DRIVE_RUN_DIR/steer.md" "$steer_archive" ) 9>"$DRIVE_RUN_DIR/steer.lock" 2>/dev/null \
        && steer_moved=0
    else
      mv "$DRIVE_RUN_DIR/steer.md" "$steer_archive" 2>/dev/null && steer_moved=0
    fi
    if [ "$steer_moved" = 0 ]; then
      prompt="$prompt

STEERING FROM THE USER (mid-run, applies to this step):
$(cat "$steer_archive")"
    fi
  fi

  # The step's own starting point: a REPO-WIDE snapshot of every dirty or untracked file
  # with its blob. A budget kill's scope reset is bounded by it, so the engine can never
  # undo work that was not this step's.
  local snap
  snap="$DRIVE_RUN_DIR/snapshot-${DRIVE_STEP_TAG:-$role}-p${DRIVE_PHASE:-x}.json"
  drive_snapshot_scope "" "$snap"

  local attempt=1 limit_waits=0 cap; cap="$(drive_budget_cap "$role")"
  while :; do
    # ---- tier floor, asserted every attempt (never inherited from a session).
    local model effort role_up
    role_up="$(printf '%s' "$role" | tr 'a-z' 'A-Z')"
    model="$(eval "printf '%s' \"\${DRIVE_MODEL_${role}:-\${DRIVE_MODEL_${role_up}:-}}\"")"
    effort="$(eval "printf '%s' \"\${DRIVE_EFFORT_${role}:-\${DRIVE_EFFORT_${role_up}:-}}\"")"
    [ -n "$model" ] || model="$(drive_floor_model "$role")"
    [ -n "$effort" ] || effort="$(drive_floor_effort "$role")"
    STEP_MODEL="$model"; STEP_EFFORT="$effort"

    # Reviewer tier >= implementer tier. A reviewer weaker than the thing it reviews
    # manufactures a clean verdict nobody checks — the single most expensive failure
    # this engine can produce, so it aborts rather than degrades.
    if [ "$role" = review ] && [ -s "$DRIVE_RUN_DIR/impl-tier-p${DRIVE_PHASE:-x}" ]; then
      local impl_tier rev_tier
      impl_tier="$(head -1 "$DRIVE_RUN_DIR/impl-tier-p${DRIVE_PHASE:-x}" | tr -d '[:space:]')"
      rev_tier="$(drive_rank_of "$model")"
      if [ "$rev_tier" -lt "${impl_tier:-0}" ]; then
        STEP_NOTE="floor violation: reviewer $model (rank $rev_tier) below implementer rank $impl_tier — refusing to review"
        STEP_STATUS=needs-input; echo "drive-step: $STEP_NOTE" >&2; return 4
      fi
    fi
    [ "$role" = implement ] && drive_rank_of "$model" >"$DRIVE_RUN_DIR/impl-tier-p${DRIVE_PHASE:-x}"

    # ---- dispatch. The heartbeat is emitted HERE, not by the caller, because model and
    # effort are only settled once the floor check has run — a DISPATCH line written
    # earlier records `?` for exactly the fields the ledger exists to collect. A retry
    # (limit, budget, timeout, failure) emits its own line, which is the point.
    drive_heartbeat "DISPATCH" "${DRIVE_STEP_TAG:-$role}" "${note:-attempt $attempt}"
    local rc
    # DRIVE_IN_STEP is the attribution marker: it is exported ONLY around a backend
    # dispatch, so a model invocation carrying no marker came from somewhere that is not a
    # step. The self-test's CLI shim records it, which is what turns "the orchestrator
    # spends no tokens" from a printed claim into an assertion.
    export DRIVE_IN_STEP="${DRIVE_STEP_TAG:-$role}:$$"
    if [ "${DRIVE_STEP_STUB:-}" = "1" ]; then
      drive_backend_stub "$role" "$prompt" "$out" "$attempt"; rc=$?
    else
      drive_backend_claude "$role" "$prompt" "$schema" "$model" "$effort" "$cap" "$out" "$raw_log"; rc=$?
    fi
    unset DRIVE_IN_STEP

    case $rc in
      0)
        # A guard's deny is recorded, never swallowed — but it is not by itself a stop.
        # A step that was denied a bare install, reissued it through the approved wrapper,
        # and committed did exactly what the guard is for. The caller decides: denials + no usable result
        # is the blocked case; denials + a committed phase is a ledger entry.
        STEP_STATUS=ok; STEP_OUT="$out"
        STEP_NOTE="ok${STEP_COST:+ cost=\$$STEP_COST}${STEP_DENIALS:+ denials=$STEP_DENIALS}"
        [ -n "$STEP_DENIALS" ] && drive_heartbeat "RESULT" "${DRIVE_STEP_TAG:-$role}" \
          "guard denied $STEP_DENIALS action(s): ${STEP_DENIAL_TEXT:-unrecorded} — surfaced, not skipped"
        return 0 ;;
      11)
        # Budget kill = infra failure: reset this step's declared paths to HEAD,
        # retry once with a doubled cap, then hand it to a human.
        drive_reset_scope "$scope_file" "$snap"
        if [ "$attempt" -ge 2 ]; then
          STEP_NOTE="budget-kill twice (cap \$$cap) — tree reset, handing back"; STEP_STATUS=needs-input; return 7
        fi
        cap=$((cap * 2)); attempt=$((attempt + 1))
        drive_heartbeat "RESULT" "$role" "budget-kill → reset + retry at cap \$$cap"
        continue ;;
      10)
        # ---- usage limit. Never a retry budget item; the work never ran. Record it, then
        # sleep until the stated reset plus a margin and resume by itself.
        local wait_s
        # A banner that keeps coming back is not a limit any more; it is a step that cannot
        # run. Cap the waits so a misread never loops a drive forever.
        limit_waits=$((limit_waits + 1))
        if [ "$limit_waits" -gt "${DRIVE_LIMIT_MAX_WAITS:-12}" ]; then
          STEP_NOTE="usage-limit banner ${limit_waits} times in one step (DRIVE_LIMIT_MAX_WAITS=${DRIVE_LIMIT_MAX_WAITS:-12}) — handing back"
          STEP_STATUS=needs-input; return 7
        fi
        drive_limit_record claude "$(drive_parse_reset_seconds "$raw_log")"
        # +5 min past the stated reset: the banners round, and retrying one second early
        # burns the step and re-enters the wait. DRIVE_LIMIT_MARGIN_SECONDS exists so the
        # self-test can exercise this path in seconds instead of minutes.
        local margin="${DRIVE_LIMIT_MARGIN_SECONDS:-300}"
        wait_s="$(drive_parse_reset_seconds "$raw_log")"
        [ -n "$wait_s" ] || wait_s="$(drive_limit_remaining claude)"
        if [ -n "$wait_s" ] && [ "$wait_s" -gt 0 ] 2>/dev/null; then
          wait_s=$((wait_s + margin))
          drive_heartbeat "LIMIT-WAIT" "$role" "limited — sleeping ${wait_s}s (reset + ${margin}s margin)"
        else
          wait_s="${DRIVE_LIMIT_POLL_SECONDS:-900}"
          drive_heartbeat "LIMIT-WAIT" "$role" "limited, reset time unparsable — polling every $((wait_s / 60)) min"
        fi
        drive_state_set waiting-limit
        sleep "$wait_s"
        drive_state_set running
        # A simulated limit clears once, so the resumed step actually completes.
        [ -n "${DRIVE_FAKE_RESET_SECONDS:-}" ] && unset CLAUDE_LIMIT_SIMULATE
        continue ;;
      13)
        # Timed out = a failed step: one retry, then the human. The partial tree is left
        # for the retry to read — the engine never guesses what a killed step meant.
        if [ "$attempt" -ge 2 ]; then
          STEP_NOTE="timed out twice (DRIVE_STEP_TIMEOUT=$(drive_step_timeout)s) — handing back"
          STEP_STATUS=failed; return 1
        fi
        attempt=$((attempt + 1))
        drive_heartbeat "RESULT" "$role" "timed out after $(drive_step_timeout)s → retry $attempt"
        continue ;;
      *)
        if [ "$attempt" -ge 2 ]; then
          STEP_NOTE="failed twice: $(tail -3 "$raw_log" | tr '\n' ' ' | cut -c1-200)"
          STEP_STATUS=failed; return 1
        fi
        attempt=$((attempt + 1))
        drive_heartbeat "RESULT" "$role" "failed → retry $attempt"
        continue ;;
    esac
  done
}

# ---------------------------------------------------------------- working-tree snapshot
# `XY\037path` for every dirty or untracked entry. `--porcelain=v1 -z -uall` because a path
# may contain a space or a quote (v1's non-`-z` form escapes and quotes those), and because
# an untracked DIRECTORY reported as one entry would hide the files inside it. A rename
# record carries its old path as a second NUL field, which is read and dropped.
drive_status_records() {
  local rec st p
  while IFS= read -r -d '' rec; do
    st="${rec:0:2}"; p="${rec:3}"
    case "$st" in
      R* | C*) IFS= read -r -d '' _ || true ;;
    esac
    [ -n "$p" ] || continue
    printf '%s\037%s\n' "$st" "$p"
  done < <(git -C "$DRIVE_REPO" status --porcelain=v1 -z -uall 2>/dev/null)
}

# `status \037 worktree-sha \037 mode,index-sha \037 path`, one line per dirty entry.
# Arg 1 `w` also WRITES each blob into the object database — a snapshot has to survive the
# file being overwritten; a comparison pass only needs the hash. Arg 2 narrows to a
# declared scope. \037 (unit separator) and not a tab: a tab is IFS whitespace, so bash
# would collapse two of them and shift every field when a sha is empty.
drive_tree_records() {
  local write="${1:-}" scope="${2:-}" st p sha staged
  while IFS=$'\037' read -r st p; do
    [ -n "$p" ] || continue
    if [ -n "$scope" ] && ! drive_path_in_scope "$p" "$scope"; then continue; fi
    sha=""
    if [ -f "$DRIVE_REPO/$p" ]; then
      if [ "$write" = w ]; then
        sha="$(git -C "$DRIVE_REPO" hash-object -w -- "$p" 2>/dev/null)"
      else
        sha="$(git -C "$DRIVE_REPO" hash-object -- "$p" 2>/dev/null)"
      fi
    fi
    staged="$(git -C "$DRIVE_REPO" ls-files -s -- "$p" 2>/dev/null | awk 'NR==1{print $1","$2}')"
    printf '%s\037%s\037%s\037%s\n' "$st" "$sha" "$staged" "$p"
  done < <(drive_status_records)
}

# Snapshot the working tree BEFORE a step runs. Repo-wide when no scope file is given, and
# that is what every step takes: the question a reset asks is "was this file already dirty
# when the step started?", and that question has no scope.
declare -A DRIVE_SNAP_STATUS=() DRIVE_SNAP_SHA=() DRIVE_SNAP_STAGED=()
drive_snapshot_scope() {
  local file="${1:-}" out="$2" tmp="$2.rec"
  mkdir -p "$(dirname "$out")" 2>/dev/null
  drive_tree_records w "$file" >"$tmp" 2>/dev/null
  node -e '
    const fs = require("fs"); const US = String.fromCharCode(31);
    const [src, dst, pre] = process.argv.slice(1);
    const files = [];
    for (const line of fs.readFileSync(src, "utf8").split("\n")) {
      if (!line) continue;
      const [status, sha, staged, ...rest] = line.split(US);
      files.push({ path: rest.join(US), status, sha, staged });
    }
    fs.writeFileSync(dst, JSON.stringify({ pre_sha: pre, files }, null, 2));
  ' "$tmp" "$out" "$(git -C "$DRIVE_REPO" rev-parse HEAD 2>/dev/null)" 2>/dev/null \
    || printf '{"pre_sha":"","files":[]}\n' >"$out"
  rm -f "$tmp"
}

drive_snapshot_load() {
  local snap="${1:-}" st sha staged p
  DRIVE_SNAP_STATUS=(); DRIVE_SNAP_SHA=(); DRIVE_SNAP_STAGED=()
  [ -n "$snap" ] && [ -s "$snap" ] || return 0
  while IFS=$'\037' read -r st sha staged p; do
    [ -n "$p" ] || continue
    DRIVE_SNAP_STATUS["$p"]="$st"; DRIVE_SNAP_SHA["$p"]="$sha"; DRIVE_SNAP_STAGED["$p"]="$staged"
  done < <(node -e '
    const fs = require("fs"); const US = String.fromCharCode(31);
    let j = {}; try { j = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch {}
    for (const f of j.files ?? []) console.log([f.status ?? "", f.sha ?? "", f.staged ?? "", f.path ?? ""].join(US));
  ' "$snap" 2>/dev/null)
}

# Reset only the paths this step declared — never `git reset --hard`, which would also
# destroy a sibling's uncommitted work. And never the USER's work either: anything that
# was already dirty inside the scope before the step started is restored byte-for-byte
# from the snapshot. A blanket `checkout -- <glob>` discards an unstaged edit the step
# had not even touched; a `checkout` also RESURRECTS a file the user had deleted in the
# worktree, so a snapshot entry with no blob is re-deleted.
drive_reset_scope() {
  local file="$1" snap="${2:-}" p
  [ -s "$file" ] || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in *..*) continue ;; esac
    git -C "$DRIVE_REPO" checkout -- "$p" 2>/dev/null
    git -C "$DRIVE_REPO" clean -fd -- "$p" 2>/dev/null
  done <"$file"
  drive_snapshot_load "$snap"
  for p in "${!DRIVE_SNAP_STATUS[@]}"; do
    drive_path_in_scope "$p" "$file" || continue
    if [ -n "${DRIVE_SNAP_SHA[$p]}" ]; then
      mkdir -p "$DRIVE_REPO/$(dirname "$p")" 2>/dev/null
      git -C "$DRIVE_REPO" cat-file -p "${DRIVE_SNAP_SHA[$p]}" >"$DRIVE_REPO/$p" 2>/dev/null
    else
      rm -f "$DRIVE_REPO/$p"
    fi
  done
}
