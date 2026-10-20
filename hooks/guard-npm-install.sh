#!/usr/bin/env bash
# PreToolUse(Bash) — Socket Firewall install guard.
#
# Blocks package installs that bypass `sfw` (Socket Firewall), enforcing the project's
# supply-chain rule (rules/dependencies.md) deterministically instead of relying on memory.
#
# Blocks (in any segment NOT prefixed with `sfw`): npm install|i|ci|add|update|up
# Allows: `sfw …` segments (already firewalled), npm run/test/start/exec/ls/view,
#         and npx (incl. `npx npq install <pkg>`, the dependency-vetting path).
# Each `;`, `&&`, `||`, `|` segment is judged on its own, so `sfw npm ci && npm install x`
# still denies the second install.
#
# Mechanism: PreToolUse + JSON `permissionDecision: "deny"` blocks the tool call
# and shows the reason to the agent so it can reissue the command via sfw.

input=$(cat 2>/dev/null)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$cmd" ] && exit 0

install_re='(^|[[:space:]]|[(])npm[[:space:]]+(install|i|ci|add|update|up)([[:space:])]|$)'

denied=0
while IFS= read -r seg; do
  trimmed=$(printf '%s' "$seg" | sed -e 's/^[[:space:](]*//')
  case "$trimmed" in
    sfw\ * | sfw) continue ;;
  esac
  if printf '%s' "$seg" | grep -Eq "$install_re"; then
    denied=1
    break
  fi
done < <(printf '%s\n' "$cmd" | sed -E 's/(&&|\|\||;|\|)/\n/g')

if [ "$denied" = 1 ]; then
  reason="Install bypasses Socket Firewall. Use 'sfw npm …' instead (e.g. 'sfw npm ci' for reproducible installs, 'sfw npm install <pkg>' to add). For a NEW dependency, vet it first with 'npx npq install <pkg>'. This is the project's supply-chain rule — do not work around it; if sfw blocks a package, surface it to the user."
  jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
