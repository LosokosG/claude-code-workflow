// scripts/check-plan-progress.mjs and scripts/lib/plan-format.mjs, against small plans.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { detectFormat, findProgress } from "../scripts/lib/plan-format.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CHECKER = path.join(ROOT, "scripts", "check-plan-progress.mjs");
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "plan-progress-test-"));
process.on("exit", () => fs.rmSync(TMP, { recursive: true, force: true }));

const GOOD = `# demo — plan

Lane: S (touches the export format).

## Decisions

| #  | Question | Choice |
| -- | -------- | ------ |
| D1 | Format   | CSV, because every consumer reads it |

## Phases

### P1 — Exporter

Changes: add \`src/export.ts\` that writes rows as CSV.
Done when: \`node --test src/export.test.ts\` passes, and a row with a comma round-trips.
risk: none
paths: \`src/export.ts\`, \`src/export.test.ts\`
size: 120

### P2 — Endpoint

Changes: expose the exporter at \`GET /export\`.
Done when: the endpoint test passes and an unauthenticated call gets 401.
route: tdd
risk: auth
paths: \`src/routes/export.ts\`

## Progress

| Phase       | Status | Notes |
| ----------- | ------ | ----- |
| P1 Exporter | [x]    | 2026-10-01 · shipped as planned |
| P2 Endpoint | [ ]    |       |

## Drive Readiness

P1 then P2.
parallel-safe: yes
`;

let n = 0;
const run = (text, ...extra) => {
  const file = path.join(TMP, `plan-${++n}.md`);
  fs.writeFileSync(file, text);
  const r = spawnSync(process.execPath, [CHECKER, file, ...extra], { encoding: "utf8" });
  return { code: r.status, out: r.stdout + r.stderr };
};

test("a well-formed plan passes", () => {
  const r = run(GOOD);
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, /OK: Progress and phases agree \(2 phases, 2 rows\)/);
  assert.doesNotMatch(r.out, /WARNING/);
});

test("usage error without a file", () => {
  const r = spawnSync(process.execPath, [CHECKER], { encoding: "utf8" });
  assert.equal(r.status, 2);
});

test("a missing Done when: line is blocking", () => {
  const r = run(GOOD.replace(/^Done when: the endpoint.*\n/m, ""));
  assert.equal(r.code, 1);
  assert.match(r.out, /phase P2 .* has no `Done when:` line/);
});

test("a missing risk: or paths: line is blocking", () => {
  assert.match(run(GOOD.replace("risk: auth\n", "")).out, /P2 .* has no `risk:` line/);
  assert.match(run(GOOD.replace("paths: `src/routes/export.ts`\n", "")).out, /P2 .* has no `paths:` line/);
  assert.match(run(GOOD.replace("paths: `src/routes/export.ts`", "paths: none")).out, /empty `paths:` list/);
});

test("risk tags are checked against an allow-list when one is given", () => {
  assert.equal(run(GOOD, "--risk-tags", "auth,billing").code, 0);
  const r = run(GOOD, "--risk-tags", "billing");
  assert.equal(r.code, 1);
  assert.match(r.out, /unknown `risk:` tag\(s\) `auth`/);
  assert.match(run(GOOD.replace("risk: auth", "risk: none, auth")).out, /mixes `none`/);
});

test("statuses are limited to [ ], [x] and [~]", () => {
  const r = run(GOOD.replace("| P2 Endpoint | [ ]", "| P2 Endpoint | [X]"));
  assert.equal(r.code, 1);
  assert.match(r.out, /has status `\[X\]`/);
});

test("[~] needs a deferred: note", () => {
  const bad = run(GOOD.replace("| P2 Endpoint | [ ]    |       |", "| P2 Endpoint | [~]    | later |"));
  assert.equal(bad.code, 1);
  assert.match(bad.out, /without a `deferred:/);
  const ok = run(GOOD.replace("| P2 Endpoint | [ ]    |       |", "| P2 Endpoint | [~]    | deferred: env-blocked — no key yet |"));
  assert.equal(ok.code, 0, ok.out);
});

test("rows and phase sections must match one to one", () => {
  const extraRow = run(GOOD.replace("| P2 Endpoint | [ ]    |       |", "| P2 Endpoint | [ ]    |       |\n| P3 Ghost    | [ ]    |       |"));
  assert.match(extraRow.out, /row P3 .* has no `### P3` section/);
  const missingRow = run(GOOD.replace("| P2 Endpoint | [ ]    |       |\n", ""));
  assert.match(missingRow.out, /### P2 — Endpoint` .* has no Progress row/);
  const dup = run(GOOD.replace("| P2 Endpoint | [ ]    |       |", "| P2 Endpoint | [ ]    |       |\n| P2 Again    | [ ]    |       |"));
  assert.match(dup.out, /two Progress rows for P2/);
});

test("prose inside the Progress table is blocking", () => {
  const r = run(GOOD.replace("| P2 Endpoint | [ ]    |       |", "| P2 Endpoint | [ ]    |       |\nsome prose"));
  assert.match(r.out, /non-table line inside `## Progress`/);
});

test("Progress section problems", () => {
  assert.match(run(GOOD.replace("## Progress\n", "## Status\n")).out, /no `## Progress` section/);
  assert.match(run(GOOD + "\n## Progress\n\n| Phase | Status | Notes |\n").out, /2 `## Progress` headings/);
  assert.match(run(GOOD.replace("| Phase       | Status | Notes |", "| Phase       | State  | Notes |")).out, /must name both `Phase` and `Status`/);
});

test("lane cap is a warning, never blocking", () => {
  const long = GOOD.replace("## Open risks", "") + "\n" + "filler line\n".repeat(260);
  const r = run(long);
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, /over the lane S cap of 250/);
  assert.match(run(GOOD.replace("Lane: S", "Scope: S")).out, /no `Lane: <S\|F>`/);
});

test("detectFormat finds the table under a lead-in note and reports a botched header", () => {
  assert.equal(detectFormat(GOOD).format, "table");
  const lead = GOOD.replace("## Progress\n\n", "## Progress\n\n> One row per phase.\n\n");
  assert.equal(detectFormat(lead).format, "table");
  assert.ok(!detectFormat(lead).badHeader);
  const botched = detectFormat(GOOD.replace("| Phase       | Status | Notes |", "| Phase | Notes |"));
  assert.ok(botched.badHeader);
  assert.equal(detectFormat("# no progress here\n").format, "none");
});

test("findProgress returns the section bounds", () => {
  const lines = GOOD.split("\n");
  const p = findProgress(lines);
  assert.equal(p.count, 1);
  assert.equal(lines[p.start], "## Progress");
  assert.equal(lines[p.end], "## Drive Readiness");
});
