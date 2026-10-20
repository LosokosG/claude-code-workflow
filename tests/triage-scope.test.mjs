// scripts/drive/drive-triage.mjs and scripts/drive/drive-scope-check.mjs as black boxes.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const TRIAGE = path.join(ROOT, "scripts", "drive", "drive-triage.mjs");
const SCOPE = path.join(ROOT, "scripts", "drive", "drive-scope-check.mjs");
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "drive-triage-test-"));
process.on("exit", () => fs.rmSync(TMP, { recursive: true, force: true }));

let n = 0;
const write = (obj, ext = "json") => {
  const p = path.join(TMP, `f${++n}.${ext}`);
  fs.writeFileSync(p, typeof obj === "string" ? obj : JSON.stringify(obj));
  return p;
};
const node = (script, args, opts = {}) => spawnSync(process.execPath, [script, ...args], { encoding: "utf8", cwd: TMP, ...opts });

const finding = (over) => ({
  id: "F1",
  severity: "WARNING",
  confidence: 90,
  file: "src/a.ts",
  line: 10,
  summary: "retry loop has no upper bound on attempts",
  fix: "cap retries at five attempts",
  dimension: "correctness",
  ...over,
});
const review = (findings, observations = []) => ({
  verdict: "NEEDS_ATTENTION", phase: "1", base: "a", head: "b", gate_recorded: true, findings, observations,
});
const triage = (reviews, extra = []) => {
  const out = path.join(TMP, `triage-${++n}.json`);
  const lessons = path.join(TMP, `lessons-${n}.md`);
  const r = node(TRIAGE, ["--phase", "1", "--out", out, "--lessons", lessons, ...reviews.flatMap((p) => ["--review", p]), ...extra]);
  return { code: r.status, log: r.stdout + r.stderr, out: fs.existsSync(out) ? JSON.parse(fs.readFileSync(out, "utf8")) : null, lessons };
};

test("the same defect reported by two lenses merges into one finding at the highest proven severity", () => {
  const a = write(review([finding()]));
  const b = write(review([finding({ id: "F7", severity: "CRITICAL", confidence: 95, failure_scenario: "a flaky upstream loops forever", summary: "retry loop has no bound on attempts and spins" })]));
  const t = triage([a, b]);
  assert.equal(t.code, 2, t.log);
  assert.equal(t.out.findings.length, 1);
  assert.equal(t.out.findings[0].severity, "CRITICAL");
  assert.equal(t.out.findings[0].confidence, 95);
  assert.equal(t.out.findings[0].streams.length, 2);
});

test("different defects in one file stay separate; single-stream findings are kept", () => {
  const a = write(review([finding(), finding({ id: "F2", summary: "log line prints the raw access token", fix: "log the token id instead" })]));
  const t = triage([a]);
  assert.equal(t.code, 1);
  assert.equal(t.out.findings.length, 2);
});

test("a CRITICAL without file:line and a failure scenario is recorded as WARNING", () => {
  const t = triage([write(review([finding({ severity: "CRITICAL" })]))]);
  assert.equal(t.code, 1);
  assert.equal(t.out.findings[0].severity, "WARNING");
  assert.match(t.out.findings[0].downgraded, /without file:line \+ failure scenario/);
});

test("confidence under 80 is dropped; observations go to the lessons queue, never the fix list", () => {
  const t = triage([write(review([finding({ confidence: 60 })], ["naming drifts from the module next door"]))]);
  assert.equal(t.code, 0);
  assert.equal(t.out.findings.length, 0);
  assert.equal(t.out.observations_filed, 1);
  assert.match(fs.readFileSync(t.lessons, "utf8"), /naming drifts/);
});

test("a fenced json tail in prose is parsed; an unparseable stream is counted as not judged", () => {
  const prose = write("# Review\n\nlooks fine except\n\n```json\n" + JSON.stringify(review([finding()])) + "\n```\n", "md");
  const junk = write("no json here at all", "md");
  const t = triage([prose, junk]);
  assert.equal(t.out.findings.length, 1);
  assert.equal(t.out.streams_unparseable, 1);
  assert.deepEqual(t.out.stream_status.map((s) => s.status), ["parsed-json", "unparseable"]);
});

test("file paths named in the summary or scenario widen the fence and make it multi-file", () => {
  const t = triage([write(review([finding({ summary: "src/a.ts returns a shape src/b/consumer.ts no longer reads" })]))]);
  assert.deepEqual(t.out.findings[0].files, ["src/a.ts", "src/b/consumer.ts"]);
  assert.equal(t.out.findings[0].fix_profile, "multi-file");
  assert.match(t.out.findings[0].fixer_brief, /FENCE: you may modify `src\/a.ts`, `src\/b\/consumer.ts`/);
});

test("advisory findings are recorded but never actionable", () => {
  const scope = write({ findings: [{ id: "A", severity: "WARNING", confidence: 100, file: "src/a.ts", summary: "tests outweigh code 3:1", fix: "", advisory: true }], observations: [] });
  const t = triage([], ["--scope-findings", scope]);
  assert.equal(t.code, 0);
  assert.equal(t.out.advisory, 1);
  assert.equal(t.out.findings[0].fix_profile, "advisory");
});

test("scope check: undeclared files are unplanned, declared ones and bookkeeping are not", () => {
  const impl = write({ touched_files: ["src/a.ts", "src/extra.ts", "src/declared.ts", "work/changes/x/plan.md"], out_of_scope: [{ file: "src/declared.ts", reason: "shared type" }], diff_lines: 40 });
  const paths = write("src/a.ts\n", "txt");
  const out = path.join(TMP, "scope.json");
  const r = node(SCOPE, [impl, paths, "100", out, "--bookkeeping", "work/changes/x"]);
  assert.equal(r.status, 2, r.stderr);
  const s = JSON.parse(fs.readFileSync(out, "utf8"));
  assert.deepEqual(s.findings.map((f) => f.file), ["src/extra.ts"]);
});

test("scope check: a diff over twice the declared size forces review (exit 1) without findings", () => {
  const impl = write({ touched_files: ["src/a.ts"], out_of_scope: [], diff_lines: 250 });
  const r = node(SCOPE, [impl, write("src/**\n", "txt"), "100", path.join(TMP, "s2.json")]);
  assert.equal(r.status, 1);
});

test("scope check: fence mode accepts declared extras and rejects the rest", () => {
  const fence = write("src/a.ts\n", "txt");
  assert.equal(node(SCOPE, ["--fence", write({ touched_files: ["src/a.ts", "src/b.ts"], declared_extra: [{ file: "src/b.ts", reason: "consumer" }] }), fence]).status, 0);
  const bad = node(SCOPE, ["--fence", write({ touched_files: ["src/a.ts", "src/c.ts"], declared_extra: [] }), fence]);
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /undeclared: src\/c.ts/);
});

test("scope check: surface modes match globs (** crosses directories, * does not)", () => {
  const globs = write({ surfaces: ["db/migrations/**", "config/*.yml"] });
  assert.equal(node(SCOPE, ["--surface", write({ touched_files: ["db/migrations/2026/001.sql"] }), globs]).status, 0);
  assert.equal(node(SCOPE, ["--surface", write({ touched_files: ["config/deep/x.yml"] }), globs]).status, 1);
  const list = node(SCOPE, ["--surface-list", globs], { input: "src/a.ts\nconfig/app.yml\ndb/migrations/1.sql\n" });
  assert.equal(list.status, 0);
  assert.deepEqual(list.stdout.trim().split("\n"), ["config/app.yml", "db/migrations/1.sql"]);
  assert.equal(node(SCOPE, ["--surface-list", globs], { input: "src/a.ts\n" }).status, 1);
});
