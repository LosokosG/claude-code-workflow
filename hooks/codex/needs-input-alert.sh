#!/usr/bin/env bash
# Codex attention hook. Inspect only agent-role keys, then discard the payload;
# commands, paths, and credentials never enter notification or log text.
set -u

payload="$(cat 2>/dev/null || true)"

payload_is_delegated() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -e '
      type == "object" and (
        (((.agent_id? // .agentId? // "") | tostring | length) > 0) or
        (((.agent_type? // .agentType? // "") | tostring | length) > 0)
      )
    ' >/dev/null 2>&1
    return $?
  fi

  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$payload" | python3 -c '
import json
import sys
try:
    value = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
if not isinstance(value, dict):
    raise SystemExit(1)
keys = ("agent_id", "agentId", "agent_type", "agentType")
raise SystemExit(0 if any(value.get(key) not in (None, "") for key in keys) else 1)
' >/dev/null 2>&1
    return $?
  fi

  return 1
}

if payload_is_delegated; then
  unset payload
  exit 0
fi
unset payload

icon=/usr/share/icons/hicolor/256x256/apps/codex-desktop.png
[ -f "$icon" ] || icon=dialog-question
notify-send -u critical -a "Codex" -i "$icon" \
  "Codex" "Codex needs your attention" 2>/dev/null || true

sound=/usr/share/sounds/freedesktop/stereo/message-new-instant.oga
[ -f "$sound" ] || sound=/usr/share/sounds/freedesktop/stereo/complete.oga
if [ -f "$sound" ]; then
  { pw-play "$sound" 2>/dev/null || paplay "$sound" 2>/dev/null; } &
fi

exit 0
