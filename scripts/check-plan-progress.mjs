#!/usr/bin/env node
// Deterministic lint for a phase plan (plan.md). The format is described in
// skills/phase-plan/references/progress-format.md.
//
//   node scripts/check-plan-progress.mjs <plan.md> [--risk-tags tag1,tag2,…]
//
// Exit 0 = no blocking findings (warnings may still print), 1 = blocking findings (one per
// line), 2 = usage or read error.
//
// Why a script: a malformed Progress table is the one defect that silently breaks the
// drive engine (it reads the table to decide what to run), and it is exactly the kind of
// thing a model reviewer skims past. Run it before every plan review.
//
// `risk:` values: `none`, or one or more comma-separated lowercase tags. Pass the allowed
// tags with --risk-tags (or PLAN_RISK_TAGS) to reject typos; without a list any
// well-formed tag is accepted.

import { readFileSync } from "node:fs";

import { detectFormat, findProgress } from "./lib/plan-format.mjs";

const argv = process.argv.slice(2);
const tagIdx = argv.indexOf("--risk-tags");
const tagList = tagIdx === -1 ? (process.env.PLAN_RISK_TAGS ?? "") : (argv[tagIdx + 1] ?? "");
const file = argv.find((a, i) => !a.startsWith("--") && (tagIdx === -1 || i !== tagIdx + 1));
if (!file) {
  console.error("usage: node scripts/check-plan-progress.mjs <plan.md> [--risk-tags a,b,c]");
  process.exit(2);
}
const allowedTags = new Set(
  tagList
    .split(",")
    .map((t) => t.trim().toLowerCase())
    .filter(Boolean),
);

let text;
try {
  text = readFileSync(file, "utf8");
} catch (e) {
  console.error(`error: cannot read ${file}: ${e.message}`);
  process.exit(2);
}

const lines = text.split("\n");
const blocking = [];
const warnings = [];
const at = (i) => `line ${i + 1}`;

// ---------------------------------------------------------------- Progress section
const progress = findProgress(lines);
if (progress.count === 0) blocking.push("CRITICAL: no `## Progress` section");
if (progress.count > 1)
  blocking.push(
    `CRITICAL: ${progress.count} \`## Progress\` headings (${progress.headings.map(at).join(", ")}) — keep exactly one`,
  );
const bodyEnd = progress.start === -1 ? lines.length : progress.start;

const detected = detectFormat(text);
if (progress.count > 0 && detected.format === "none")
  blocking.push("CRITICAL: `## Progress` has no `| Phase | Status | Notes |` table header near its top");
if (detected.badHeader)
  blocking.push(
    `CRITICAL: Progress table header must name both \`Phase\` and \`Status\` (${at(detected.badHeader.line)}: \`${detected.badHeader.text.slice(0, 60)}\`)`,
  );

// ---------------------------------------------------------------- phase sections
const phases = [];
for (let i = 0; i < bodyEnd; i++) {
  const m = lines[i].match(/^### P(\d+)\b\s*[—:-]?\s*(.*)$/);
  if (m) phases.push({ n: Number(m[1]), title: m[2].trim(), line: i });
}
if (phases.length === 0) blocking.push("CRITICAL: no `### P<n> — <title>` phase headings before `## Progress`");

const fieldRe = (name) => new RegExp(`^\\s*\\**\\s*${name}\\s*\\**\\s*:`, "i");
const TAG_RE = /^[a-z0-9][a-z0-9-]*$/;

phases.forEach((ph, k) => {
  const end = k + 1 < phases.length ? phases[k + 1].line : bodyEnd;
  // A phase body stops at the next phase or at the next `## ` section, whichever is first.
  let stop = end;
  for (let i = ph.line + 1; i < end; i++) {
    if (lines[i].startsWith("## ")) {
      stop = i;
      break;
    }
  }
  const body = lines.slice(ph.line + 1, stop);
  const value = (name) => {
    const re = fieldRe(name);
    const hit = body.find((l) => re.test(l));
    return hit === undefined ? null : hit.replace(re, "").trim();
  };
  const where = `phase P${ph.n} (${at(ph.line)})`;

  for (const [name, label] of [
    ["changes", "Changes:"],
    ["done[ -]when", "Done when:"],
  ]) {
    const v = value(name);
    if (v === null) blocking.push(`CRITICAL: ${where} has no \`${label}\` line`);
    else if (!v) blocking.push(`CRITICAL: ${where} has an empty \`${label}\` line`);
  }

  const risk = value("risk");
  if (risk === null) {
    blocking.push(`CRITICAL: ${where} has no \`risk:\` line (write \`risk: none\` when it touches nothing reserved)`);
  } else {
    const tags = risk
      .split(/[,+]/)
      .map((t) => t.trim().toLowerCase())
      .filter(Boolean);
    if (tags.length === 0) blocking.push(`CRITICAL: ${where} has an empty \`risk:\` value`);
    else if (tags.includes("none") && tags.length > 1)
      blocking.push(`CRITICAL: ${where} mixes \`none\` with other risk tags`);
    else if (!(tags.length === 1 && tags[0] === "none")) {
      const malformed = tags.filter((t) => !TAG_RE.test(t));
      if (malformed.length)
        blocking.push(`CRITICAL: ${where} has malformed \`risk:\` tag(s) ${malformed.map((t) => `\`${t}\``).join(", ")}`);
      if (allowedTags.size) {
        const unknown = tags.filter((t) => TAG_RE.test(t) && !allowedTags.has(t));
        if (unknown.length)
          blocking.push(
            `CRITICAL: ${where} has unknown \`risk:\` tag(s) ${unknown.map((t) => `\`${t}\``).join(", ")} — allowed: none, ${[...allowedTags].join(", ")}`,
          );
      }
    }
  }

  const paths = value("paths");
  if (paths === null) blocking.push(`CRITICAL: ${where} has no \`paths:\` line`);
  else if (
    paths
      .split(",")
      .map((t) => t.trim())
      .filter((t) => t && t.toLowerCase() !== "none").length === 0
  )
    blocking.push(`CRITICAL: ${where} has an empty \`paths:\` list — declare the scope, however small`);

  const size = value("size");
  if (size !== null && !/^\d+$/.test(size)) warnings.push(`WARNING: ${where} has a non-numeric \`size:\` (\`${size}\`) — the engine falls back to 300`);
});

// ---------------------------------------------------------------- Progress rows
const rows = [];
if (progress.start !== -1 && detected.format === "table" && !detected.badHeader) {
  for (let i = progress.start + 1; i < progress.end; i++) {
    const raw = lines[i].trim();
    if (!raw || i <= detected.headerLine) continue;
    if (!raw.startsWith("|")) {
      blocking.push(`CRITICAL: non-table line inside \`## Progress\` (${at(i)}): \`${raw.slice(0, 60)}\``);
      continue;
    }
    const cells = raw
      .replace(/^\|/, "")
      .replace(/\|$/, "")
      .split("|")
      .map((c) => c.trim());
    if (cells.every((c) => /^:?-{3,}:?$/.test(c))) continue;
    const [phaseCell = "", status = "", ...rest] = cells;
    const notes = rest.join(" ");
    const pm = phaseCell.match(/^P(\d+)\b/);
    if (!pm) {
      blocking.push(`CRITICAL: Progress row (${at(i)}) does not start with \`P<n>\`: \`${phaseCell.slice(0, 40)}\``);
      continue;
    }
    if (!["[ ]", "[x]", "[~]"].includes(status))
      blocking.push(`CRITICAL: Progress row P${pm[1]} (${at(i)}) has status \`${status}\` — use \`[ ]\`, \`[x]\` or \`[~]\``);
    if (status === "[~]" && !/\bdeferred:/i.test(notes))
      blocking.push(`CRITICAL: Progress row P${pm[1]} (${at(i)}) is \`[~]\` without a \`deferred: <category> — <why>\` note`);
    rows.push({ n: Number(pm[1]), line: i });
  }
}

const seen = new Set();
for (const r of rows) {
  if (seen.has(r.n)) blocking.push(`CRITICAL: two Progress rows for P${r.n} (${at(r.line)})`);
  seen.add(r.n);
  if (!phases.some((p) => p.n === r.n)) blocking.push(`CRITICAL: Progress row P${r.n} (${at(r.line)}) has no \`### P${r.n}\` section`);
}
for (const p of phases)
  if (!rows.some((r) => r.n === p.n)) blocking.push(`CRITICAL: \`### P${p.n} — ${p.title}\` (${at(p.line)}) has no Progress row`);

// ---------------------------------------------------------------- size, by lane
// Advisory only. Over the cap means cut the plan, not raise the cap.
const LANE_CAPS = { S: 250, F: 400 };
let lane = null;
for (let i = 0; i < Math.min(lines.length, 15); i++) {
  const m = lines[i].match(/^\s*lane:\s*([QSF])\b/i);
  if (m) {
    lane = m[1].toUpperCase();
    break;
  }
}
const total = lines[lines.length - 1] === "" ? lines.length - 1 : lines.length;
if (!lane) warnings.push("WARNING: no `Lane: <S|F>` in the first lines — size cap not checked");
else if (lane === "Q") warnings.push("WARNING: `Lane: Q` — Q-lane work has no plan; use /quick");
else if (total > LANE_CAPS[lane])
  warnings.push(`WARNING: ${total} lines is over the lane ${lane} cap of ${LANE_CAPS[lane]} — cut, don't raise the cap`);

for (const f of blocking) console.log(f);
for (const w of warnings) console.log(w);
if (blocking.length) {
  console.log(`\n${blocking.length} blocking finding(s) in ${file}`);
  process.exit(1);
}
console.log(`OK: Progress and phases agree (${phases.length} phases, ${rows.length} rows)`);
