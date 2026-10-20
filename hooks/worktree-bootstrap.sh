#!/usr/bin/env bash
# SessionStart hook: make a linked git worktree usable without manual setup.
#
# Worktrees do not inherit untracked files, so `.env` is missing in every new one — which
# breaks database connections, integration tests and dev servers, and tempts an agent to
# paste secrets into the chat as a workaround. This hook:
#
#   1. COPIES `.env` FROM THE MAIN CHECKOUT INTO THE WORKTREE when the worktree has none.
#      The copy holds real secrets; it lives and dies with the worktree (removing the
#      worktree removes it). Do not use this hook if your secrets must never be duplicated
#      on disk.
#   2. Tells the session it is running in a linked worktree, so it resolves relative paths
#      against the right root.
#   3. Gives the worktree its own dev-server ports, deterministic from the directory name,
#      so two parallel sessions never fight over one port. Variable names come from
#      WORKTREE_PORT_VARS (space-separated, default "DEV_PORT"); your dev scripts must read
#      them and fall back to their defaults when unset.
#
# Does nothing in the main checkout. Never prints .env contents.
set -euo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$root" ] && exit 0

common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
[ -z "$common" ] && exit 0
main="$(dirname "$common")"

# Main checkout — nothing to bootstrap.
[ "$root" = "$main" ] && exit 0

msgs=("worktree-bootstrap: this session runs in the LINKED WORKTREE $root (main checkout: $main) — resolve relative paths against this root, not the main checkout.")

if [ ! -f "$root/.env" ] && [ -f "$main/.env" ]; then
  cp "$main/.env" "$root/.env"
  msgs+=("worktree-bootstrap: copied .env from the main checkout into this worktree. Never read, print or paste .env contents — the file is already here.")
fi

# Per-worktree ports: one block of numbers per worktree, one number per variable.
if [ -f "$root/.env" ]; then
  read -r -a port_vars <<<"${WORKTREE_PORT_VARS:-DEV_PORT}"
  first="${port_vars[0]:-}"
  if [ -n "$first" ] && ! grep -q "^${first}=" "$root/.env"; then
    hash=$(printf '%s' "$(basename "$root")" | cksum | cut -d' ' -f1)
    off=$((hash % 400))
    assigned=()
    {
      printf '\n# per-worktree ports (worktree-bootstrap)\n'
      i=0
      for v in "${port_vars[@]}"; do
        port=$((4400 + i * 400 + off))
        printf '%s=%s\n' "$v" "$port"
        i=$((i + 1))
      done
    } >>"$root/.env"
    for v in "${port_vars[@]}"; do assigned+=("$v=$(sed -n "s/^${v}=//p" "$root/.env" | tail -1)"); done
    msgs+=("worktree-bootstrap: this worktree's ports — ${assigned[*]}. Never bind the defaults here; the main checkout or another worktree may own them.")
  fi
fi

printf '%s\n' "${msgs[@]}"
