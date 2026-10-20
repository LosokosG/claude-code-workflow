# The plan contract

`plan.md` is read by people and by tooling. The people need it short; the tooling
(`scripts/check-plan-progress.mjs`, the drive engine, `/change-status`) needs a few lines
to look exactly the same in every plan. This page is the tooling side.

## Phase sections

Every phase is a level-3 heading that starts with `P` and a number, before `## Progress`:

```markdown
### P2 — Import adapter
```

Inside it, one line per field, `name: value`, anywhere in the section:

| Field | Required | Read by |
| --- | --- | --- |
| `Changes:` | yes | reviewers |
| `Done when:` | yes | implementer, verifier |
| `risk:` | yes — `none` or tags | engine (review lenses), checker |
| `paths:` | yes — comma-separated, may be backticked globs | engine (scope check), checker |
| `route:` | no — `implement` (default) or `tdd` | engine (which skill runs the phase) |
| `size:` | no — integer, default 300 | engine (diff over 2× forces a review) |
| `notes:` | no — `implementation-notes/p<n>.md` | implementer |
| `Verify:` | no — one line a human can follow | hand-back |

## The Progress table

```markdown
## Progress

| Phase             | Status | Notes                                        |
| ----------------- | ------ | -------------------------------------------- |
| P1 Data model     | [x]    | 2026-09-11 · added the index the review asked for |
| P2 Import adapter | [~]    | deferred: env-blocked — API key not issued yet |
| P3 Admin screen   | [ ]    |                                              |
```

What the checker enforces:

- Exactly one `## Progress` heading. Its table header, within the first five non-blank
  lines, names both `Phase` and `Status`.
- One row per phase section and one phase section per row, matched on the number after
  `P`. The rest of the first cell is a label and may be shortened.
- The status cell is exactly `[ ]`, `[x]` or `[~]`.
- A `[~]` row's notes contain `deferred:` followed by a category (`human-judgment`,
  `env-blocked`, `out-of-lane`) and the reason.
- Only table lines inside the section — no prose between rows.

What the engine relies on:

- The next phase to run is the first `[ ]` row in document order.
- `[x]` means landed and verified; `[~]` is owed to a human and the engine never runs or
  flips it.
- The implementer flips its own row in the same commit as the code. If a flip is left
  uncommitted, the engine commits it as `docs(<id>): P<n> progress`.

Sections after `## Progress` (`## Drive Readiness`, `## Open risks`) are allowed and
expected.

## Deliberately absent

No SHAs written back into phase bodies (the commit subject's `(<id> p<n>)` suffix is the
link), no per-step checkboxes, no owners or estimates, no status sidecar files. State is
the table plus git, and nothing else.
