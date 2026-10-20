---
description: Supply-chain rules for adding, upgrading or removing any npm dependency. Follow before touching a manifest or the lockfile.
paths:
  - "**/package.json"
  - "package-lock.json"
  - ".npmrc"
  - ".github/dependabot.yml"
---

# Dependencies and supply chain

The failure this prevents: a malicious release, a lockfile pointing at an unvetted host,
or a silent bump that breaks a gate. npm supply-chain attacks are an active threat, so
every dependency change is security-relevant.

- Install only through Socket Firewall: `sfw npm ci`, `sfw npm install <pkg>`. The
  `guard-npm-install` hook denies a bare `npm install|ci|add|update`. If `sfw` blocks a
  package, stop and tell the owner; do not work around it.
- Vet every new package with `npx npq install <pkg>` first (age, typosquatting,
  provenance, install scripts). If npq flags it, stop and tell the owner. Prefer the
  standard library or a small local helper over a new dependency.
- No `npm update`, no `npx npm-check-updates -u`, no wholesale bumps. Upgrades arrive as
  Dependabot PRs with a cooldown; read the changelog before merging. An intentional single
  upgrade pins the exact version and is vetted with npq.
- Hold back a major version when a tool the project depends on has not caught up with it
  yet; record the reason and the issue link next to the pin, and configure Dependabot to
  ignore that major until it is resolved.
- `package-lock.json` is authoritative and committed. Install with `npm ci` for
  reproducible installs. Lint the lockfile in CI (for example `lockfile-lint`) to reject
  non-registry hosts and non-HTTPS URLs.
- No git-URL, tarball or local-path dependencies; they bypass registry integrity. Ask the
  owner if one seems necessary.
- Every package a module imports directly is a declared dependency of that workspace. An
  import that resolves only through workspace hoisting is an undeclared supply-chain
  dependency.
