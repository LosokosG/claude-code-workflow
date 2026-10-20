# Review floor — cost pressure never routes verification down

When dispatching an independent reviewer or verifier for work that gates a merge/commit or
touches a security surface (auth, RLS/tenant isolation, migrations, payments, secrets):
dispatch at the tier that produced the work **or higher** — omit the Agent tool's `model`
param to inherit the session model. **This floor is absolute: a budget or cost directive
does not apply to it.** Under cost pressure, economize on mechanical work instead (grep
sweeps, formatting, file discovery → explicit `haiku`/`sonnet`), never on the gate.

Why: a weak reviewer passing broken security work is the most expensive failure available —
it manufactures false confidence, which is worse than no review at all.

Unaffected: routing mechanical, checklist-shaped work with verifiable output DOWN a tier
remains right and encouraged. A skill or engine that pins its own per-role model policy
(with the reviewer never below the implementer) may apply that policy instead.
