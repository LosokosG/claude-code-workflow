#!/usr/bin/env bash
# drive hand-back block — appended to drive-log.md at every terminal stop.
#
#   drive-handback.sh <change-id> "<phases>" [verify.json]
#
# The failure it prevents: a run that "finished" but whose user never learns what it
# decided, what it did NOT ship, or how to see the thing working. Every line below is
# there because a hand-back once omitted it.
set -uo pipefail

DRIVE_ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVE_REPO="${DRIVE_REPO:-$(git rev-parse --show-toplevel)}"
CHANGE_ID="${1:?usage: drive-handback.sh <change-id> \"<phases>\" [verify.json]}"
PHASES="${2:-}"
VERIFY="${3:-}"
# shellcheck source=scripts/drive/drive-lib.sh
. "$DRIVE_ENGINE/drive-lib.sh"
drive_paths_init "$CHANGE_ID"
REPO="$DRIVE_REPO"
LOG="$DRIVE_LOG"

row_title() { sed -n "s/^|[[:space:]]*\(P$1[^|]*\)|.*/\1/p" "$PLAN" | head -1 | sed 's/[[:space:]]*$//'; }
# The `Verify:` line of a phase section, when the plan carries one.
phase_verify_line() {
  awk -v n="$1" '
    $0 ~ "^### P" n "([^0-9]|$)" {inside=1; next}
    inside && /^### P/ {exit}
    inside && /^## / {exit}
    inside && /^[Vv]erify:/ {sub(/^[Vv]erify:[[:space:]]*/, ""); print; exit}
  ' "$PLAN"
}

echo
echo "## Hand-back — $(date -Iseconds)"
echo

echo "**Phases landed this run:**"
for p in $PHASES; do
  # The commit trailer `(<id> pN)` is the index. --fixed-strings because the trailer's
  # parentheses are not a regex.
  sha="$(git -C "$REPO" log -1 --fixed-strings --grep="($CHANGE_ID p$p)" --format='%h' 2>/dev/null)"
  echo "- $(row_title "$p") — ${sha:-no commit carries the trailer ($CHANGE_ID p$p)}"
done
echo

echo "**Delivered vs plan:** what these phases shipped is exactly their \`Changes:\` lines in"
echo "\`$PLAN\`. Read the \`## Out of scope\` section there for what this change does NOT cover —"
echo "scope surprises at hand-back are the expensive kind."
echo

echo -n "**Live verification:** "
if [ -n "$VERIFY" ] && [ -s "$VERIFY" ]; then
  node -e '
    const v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    if (v.verdict === "SKIPPED") { console.log("SKIPPED — no runnable surface in these phases."); }
    else {
      console.log(v.verdict);
      for (const f of v.flows ?? []) {
        const ev = (f.evidence ?? []).length ? ` — ${f.evidence.join("; ")}` : " — NO ARTIFACT (claim discarded)";
        console.log(`  - ${f.name}: ${(f.evidence ?? []).length ? f.status : "UNVERIFIED"}${ev}`);
      }
      for (const d of v.db_asserts ?? []) console.log(`  - persisted: ${d.action} → ${d.result}`);
    }
  ' "$VERIFY"
else
  echo "UNVERIFIED — the verifier step produced no result. Walk the surface yourself before trusting these phases."
fi
echo

echo "**Decisions taken:**"
if grep -q '^## Decisions' "$LOG" 2>/dev/null; then
  sed -n '/^## Decisions/,/^## /p' "$LOG" | grep '^- ' | tail -20
else
  echo "- none recorded this run"
fi
echo

echo "**Findings the fixer did not resolve (nothing here was silently dropped):**"
unfixed=""
for f in "$CHANGE_DIR"/drive/unfixed-p*.md; do
  [ -f "$f" ] || continue
  unfixed=1
  ack="${f%.md}.ack"
  echo "- from $(basename "$f" .md | sed 's/^unfixed-//')$([ -f "$ack" ] && echo " ($(head -1 "$ack"))" || echo " (NOT acknowledged — the next phase will not dispatch until \`drive-ctl ack\`)"):"
  sed 's/^/  /' "$f"
done
[ -n "$unfixed" ] || echo "- none — every triaged finding was either applied or escalated"
echo

echo "**Deferred rows (never \`[x]\` — a human owns these):**"
if grep -qE '^\|[^|]*\|[[:space:]]*\[~\]' "$PLAN"; then
  grep -E '^\|[^|]*\|[[:space:]]*\[~\]' "$PLAN" | sed 's/^/- /'
else
  echo "- none"
fi
echo

echo "**See it running:**"
echo "1. start the project the way it normally runs locally"
step=2
for p in $PHASES; do
  v="$(phase_verify_line "$p")"
  [ -n "$v" ] || continue
  echo "$step. P$p: $v"
  step=$((step + 1))
done
[ "$step" = 2 ] && { echo "2. exercise the flow the landed phases describe (their \`Changes:\` lines — no \`Verify:\` line was given)"; step=3; }
echo "$step. then one malformed input to the same flow"
echo "$((step + 1)). expected: no console errors, no error responses, and every write visible in the persisted state"
echo

LESSONS="$WORK_ROOT/proposed-lessons.md"
n_lessons=0
[ -f "$LESSONS" ] && n_lessons="$(grep -c "^- $(date +%Y-%m-%d) " "$LESSONS" 2>/dev/null)"
# grep -c exits 1 on zero matches, and `|| echo 0` inside a substitution would emit BOTH
# the count and the fallback. Normalise here instead.
case "$n_lessons" in "" | *[!0-9]*) n_lessons=0 ;; esac
echo "**Lesson candidates filed:** $n_lessons today → \`$DRIVE_WORK_DIR/proposed-lessons.md\` (drain via /lesson-capture)"
echo

echo "**Resume:** \`$(drive_cmd drive) $CHANGE_ID\` (picks up at the first open \`[ ]\` row)."
echo "**Next:** review the diff · push when you are happy · move the folder to \`$DRIVE_WORK_DIR/archive/\` when the slice is done."
echo "This run never pushed and never archived — both are yours."
