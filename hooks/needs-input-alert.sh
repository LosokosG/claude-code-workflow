#!/usr/bin/env bash
# Notification-event hook: visible + audible alert when Claude Code needs input
# (permission prompt, question waiting). Payload arrives as JSON on stdin.
set -u

payload="$(cat 2>/dev/null || true)"
msg="$(printf '%s' "$payload" | jq -r '.message // .title // "Claude Code needs your input"' 2>/dev/null)"
[ -z "$msg" ] || [ "$msg" = "null" ] && msg="Claude Code needs your input"

icon=/usr/share/icons/hicolor/256x256/apps/claude-desktop.png
[ -f "$icon" ] || icon=dialog-question
notify-send -u critical -a "Claude Code" -i "$icon" "Claude Code" "$msg" 2>/dev/null || true

sound=/usr/share/sounds/freedesktop/stereo/message-new-instant.oga
[ -f "$sound" ] || sound=/usr/share/sounds/freedesktop/stereo/complete.oga
if [ -f "$sound" ]; then
  { pw-play "$sound" 2>/dev/null || paplay "$sound" 2>/dev/null; } &
fi

exit 0
