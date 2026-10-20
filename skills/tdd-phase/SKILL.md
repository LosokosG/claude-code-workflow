---
name: tdd-phase
description: Use to build one plan phase test-first, but only while the behavior it describes does not exist yet — a plan row with `route: tdd`, or the user asking for test-first, red/green, or failing-test-first work on a phase. Anything already partly built, or with no assertable outcome, goes to /implement-phase instead.
argument-hint: "<change-id> phase <n>"
allowed-tools:
  - Read
  - Grep
  - Glob
  - Edit
  - Write
  - Bash
  - AskUserQuestion
---

# tdd-phase

Same plan, same Progress row, same commit and report as `/implement-phase`. One thing
differs: each behavior gets a failing test **before** the code that satisfies it. Because
that order is the whole value, this skill refuses phases where the code already exists.

```
fail   → one test that pins the next behavior, failing for the expected reason
pass   → the least production code that makes it pass
tidy   → clean up with the test still passing
```

## Load the phase

`/tdd-phase <change-id> phase <n>` works on `work/changes/<change-id>/plan.md`. Refuse a
change under `work/archive/` and stop.

Read what `/implement-phase` reads and no more: the plan header, `## Decisions`,
`## Out of scope`, `## Hard guarantees`, this phase's section, its implementation notes if
named, and the files in `paths:`.

Then find the test runner — quickly. Locate the test config and one existing test, and
note how tests are imported, structured and mocked, and how a single file is run. If the
project has no test runner at all, stop and say so: setting one up is its own phase.

## Two checks before writing any test

Both must hold, or this is not a test-first phase.

**Nothing to drive yet.** Look for the files, exports, routes, migrations or UI the
section says it adds. If any of it is already there:

```
P<n> is already partly built, so its tests can no longer lead the code.
Evidence: <what you found>
→ /implement-phase <change-id> phase <n>
```

Do not write tests after the fact, do not flip the row, do not carry on.

**Something to assert.** There has to be an outcome a test can check before the code
exists.

| Fits test-first | Send to /implement-phase |
| --- | --- |
| parsing, validation, formatting, calculation | folders, config files, manifests |
| state transitions and reducers | CI, containers, environment, deploy wiring |
| request → response contracts (status, body, auth) | visual tweaks with nothing to assert |
| domain rules with clear inputs and outputs | spikes with no contract yet |
| flows across boundaries you can fake | thin glue a test would only restate |
| a bug fix (its reproduction is the first test) | docs and copy |

A phase that mixes both → one `AskUserQuestion`: test-first for the logic, build the
setup directly (recommended) / hand the whole phase to `/implement-phase` / test-first for
everything. Under a drive, take the recommended option and say so in `notes`.

A row marked `route: tdd` that fails either check is a planning problem. Return
`status: blocked` with the evidence; do not improvise around it.

## The cycle

Plan on **two to five tests** for the phase: the behaviors that show it works and would
catch a real regression. Not one per accessor.

**Fail.** Write one test, or a small group, for the next behavior, in the project's style.
Name it after the outcome ("rejects a file over 10 MB with 413"), not the mechanism
("calls checkSize"). Assert on results, output, responses and stored state — never on
private calls or call order. Run that file alone. It must fail **because the behavior is
missing**: a failed assertion, or an import of the module you are about to create. A
syntax error or a typo in an import is not a useful failure — fix it and run again. Never
skip a test to get through a phase.

**Pass.** Write the smallest production change that makes the test pass, and nothing the
test does not ask for; the next behavior earns its own failing test. Run again. If another
test broke, fix the code, not the test.

**Tidy.** Rename, deduplicate, tighten types — behavior unchanged, tests passing after
each step. Skip it when there is nothing to tidy.

Repeat until the phase's `Done when:` holds.

## Commit and report

Use `/implement-phase`'s **Check it**, **Land it** and **Report** sections exactly, with
these differences:

- Commit only when everything in scope passes. A failing test is something you show, not
  something you commit. Run the whole fast suite before committing, not only your file.
- Flip the Progress row before staging, and stage `plan.md` together with the tests and
  the code.
- Use `test` or `feat` as the commit type and say in the body that the tests came first.
  Keep the `(<change-id> p<n>)` suffix.
- The report block is the same `scripts/drive/schemas/impl.json` shape. A phase you sent
  to `/implement-phase` reports `status: blocked` with the reason, never `committed`.

All of `/implement-phase`'s fixed rules apply here unchanged.

## Test quality, briefly

A test here should read as a statement about behavior, break only when that behavior
breaks, survive refactoring, and need little setup. Fake the collaborators at the edges
(database, network, clock), never the unit under test. Avoid snapshot tests for logic,
near-duplicate tests, and assertions about internals.

If `Done when:` is too vague to turn into an assertion ("works correctly"), do not invent
the expectation: ask the user for the concrete outcome they want, then write the first test.
