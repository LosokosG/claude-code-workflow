// drive triage — merge every review stream into one ordered fix list.
//
//   node drive-triage.mjs --phase 3 --out drive/triage-p3.json \
//        --review a.json --review b.json [--scope-findings scope.json] \
//        [--lessons work/proposed-lessons.md]
//
// Inputs are the JSON results of the review lenses (schema-shaped, or a fenced ```json
// tail inside prose) plus the engine's own scope findings ("unplanned" files, and any
// finding a project-specific check marks `advisory`). They are near-disjoint by design,
// so this is not a voting scheme:
//
//   * merge by (file, mechanism) — the same file AND the same underlying defect, judged on
//     a normalised token set, not on wording;
//   * severity = the maximum any stream PROVES (CRITICAL needs file:line + a failure
//     scenario; an unevidenced CRITICAL is recorded as WARNING, not dropped);
//   * confidence = the maximum across the streams reporting it;
//   * a finding only one stream reports is KEPT — single-stream is the expected case;
//   * every stream carries a `status` in the artifact, because a stream nobody could parse
//     must never be indistinguishable from a stream that found nothing.
//
// OBSERVATIONs never enter the fix list. They are appended to proposed-lessons.md, which a
// human drains via /lesson-capture. There is no OBSERVATION fix pass, ever.
//
// A finding marked `advisory: true` is recorded with `fix_profile: "advisory"` and never
// dispatched to a fixer; it does not move the exit code.
//
// Exit: 0 nothing actionable · 1 warnings only · 2 at least one critical.
import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
const opt = (name, fallback = null) => {
  const i = args.indexOf(name);
  return i === -1 ? fallback : args[i + 1];
};
const many = (name) => args.flatMap((a, i) => (a === name ? [args[i + 1]] : []));

const phase = opt("--phase", "x");
const range = opt("--range", "");
const outPath = opt("--out", `drive/triage-p${phase}.json`);
const lessonsPath = opt("--lessons", `${process.env.DRIVE_WORK_DIR || "work"}/proposed-lessons.md`);
const reviewPaths = many("--review");
const scopePath = opt("--scope-findings");

const STOPWORDS = new Set([
  "the",
  "a",
  "an",
  "is",
  "are",
  "was",
  "were",
  "be",
  "been",
  "to",
  "of",
  "in",
  "on",
  "for",
  "with",
  "and",
  "or",
  "not",
  "no",
  "that",
  "this",
  "it",
  "its",
  "as",
  "at",
  "by",
  "from",
  "but",
  "if",
  "then",
  "than",
  "has",
  "have",
  "had",
  "does",
  "do",
  "did",
  "can",
  "could",
  "should",
  "would",
  "will",
  "may",
  "might",
]);

// A finding's "mechanism" is what it says is wrong, stripped of phrasing. Two reports
// describing one defect share most of these tokens; two different defects in one file
// do not.
const mechanism = (f) => {
  const text = `${f.summary ?? ""} ${f.fix ?? ""}`;
  const tokens = text
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .split(/\s+/)
    .filter((t) => t.length > 2 && !STOPWORDS.has(t));
  return new Set(tokens);
};

const jaccard = (a, b) => {
  if (!a.size || !b.size) return 0;
  let shared = 0;
  for (const t of a) if (b.has(t)) shared++;
  return shared / (a.size + b.size - shared);
};

const normFile = (p) =>
  String(p ?? "")
    .replace(/^\.\//, "")
    .replace(/^\/+/, "")
    .trim();

// ---------------------------------------------------------------- read the streams
// A stream is either the schema-shaped JSON object itself or prose with a fenced
// ```json tail (the LAST parseable block wins — it is the final report). Anything else
// is `unparseable`; an unreadable or empty file is `missing`. Neither is ever counted as
// a clean stream: drive-phase.sh turns them into a heartbeat and judges the phase on the
// streams that did parse.
//
//   parsed-json · unparseable · missing
const readStream = (p) => {
  const name = path.basename(p, ".json");
  let text;
  try {
    text = fs.readFileSync(p, "utf8");
  } catch (err) {
    console.error(`drive-triage: missing stream ${p}: ${err.message}`);
    return { name, path: p, status: "missing", data: null };
  }
  if (!text.trim()) {
    console.error(`drive-triage: missing stream ${p}: the stream is empty`);
    return { name, path: p, status: "missing", data: null };
  }
  try {
    const parsed = JSON.parse(text);
    if (parsed && typeof parsed === "object") return { name, path: p, status: "parsed-json", data: parsed };
  } catch {
    /* fall through to the fenced tail */
  }
  const fenced = [...text.matchAll(/```json\s*([\s\S]*?)```/g)];
  for (let i = fenced.length - 1; i >= 0; i--) {
    try {
      const parsed = JSON.parse(fenced[i][1]);
      if (parsed && typeof parsed === "object") return { name, path: p, status: "parsed-json", data: parsed };
    } catch {
      /* try the block before it */
    }
  }
  console.error(
    `drive-triage: UNPARSEABLE stream ${p} — neither a JSON object nor a fenced json tail. NOT counted as a clean stream.`,
  );
  return { name, path: p, status: "unparseable", data: null };
};

const streamRecords = [];
for (const p of reviewPaths) streamRecords.push(readStream(p));
if (scopePath && fs.existsSync(scopePath)) {
  const r = readStream(scopePath);
  r.name = "scope-check";
  if (Array.isArray(r.data)) r.data = { findings: r.data, observations: [] };
  streamRecords.push(r);
}
// Only a stream with data enters the merge; the rest survive in `stream_status`, which is
// what keeps an unjudged stream from reading as a clean one.
const streams = streamRecords.filter((s) => s.data);

// ---------------------------------------------------------------- observations first
const observations = [];
for (const s of streams)
  for (const o of s.data.observations ?? []) observations.push({ stream: s.name, text: String(o) });
if (observations.length) {
  const abs = path.isAbsolute(lessonsPath) ? lessonsPath : path.join(process.cwd(), lessonsPath);
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  const today = new Date().toISOString().slice(0, 10);
  const body = observations.map((o) => `- ${today} · p${phase} · ${o.stream} · ${o.text}`).join("\n");
  fs.appendFileSync(abs, (fs.existsSync(abs) && fs.readFileSync(abs, "utf8").endsWith("\n") ? "" : "\n") + body + "\n");
}

// ---------------------------------------------------------------- merge the findings
const groups = [];
const advisories = [];
for (const s of streams) {
  for (const f of s.data.findings ?? []) {
    const confidence = Number(f.confidence ?? 0);
    // The schema already forbids <80; a hand-written stream might not.
    if (confidence < 80) continue;
    if (f.advisory) {
      advisories.push({ stream: s.name, ...f });
      continue;
    }
    const file = normFile(f.file);
    const proves = Boolean(file && f.line != null && String(f.failure_scenario ?? "").trim());
    const severity = f.severity === "CRITICAL" && !proves ? "WARNING" : f.severity;
    const cand = {
      stream: s.name,
      id: f.id,
      file,
      line: f.line ?? null,
      severity,
      claimed_severity: f.severity,
      confidence,
      summary: String(f.summary ?? ""),
      fix: String(f.fix ?? ""),
      failure_scenario: f.failure_scenario ?? null,
      dimension: f.dimension ?? "correctness",
      tokens: mechanism(f),
    };
    const hit = groups.find((g) => g.file === cand.file && jaccard(g.tokens, cand.tokens) >= 0.5);
    if (hit) {
      hit.members.push(cand);
      for (const t of cand.tokens) hit.tokens.add(t);
    } else {
      groups.push({ file: cand.file, tokens: new Set(cand.tokens), members: [cand] });
    }
  }
}

const SEV_RANK = { CRITICAL: 2, WARNING: 1 };
// A repo-relative path with at least one directory and an extension. URLs are excluded by
// the leading-character class (a `:` or `/` before the path never matches).
const PATH_RE = /(?:^|[\s`'"(])((?:[A-Za-z0-9_@.-]+\/)+[A-Za-z0-9_@.-]+\.[A-Za-z0-9]+)/g;
const DIAGNOSIS_RE = /\b(investigate|diagnos|root cause|unclear|figure out|determine why|not sure|somewhere)\b/i;

const findings = groups.map((g, i) => {
  const best = [...g.members].sort(
    (a, b) => (SEV_RANK[b.severity] ?? 0) - (SEV_RANK[a.severity] ?? 0) || b.confidence - a.confidence,
  )[0];
  const severity = g.members.reduce(
    (m, c) => ((SEV_RANK[c.severity] ?? 0) > (SEV_RANK[m] ?? 0) ? c.severity : m),
    "WARNING",
  );
  const confidence = Math.max(...g.members.map((m) => m.confidence));
  const scenario = g.members.map((m) => m.failure_scenario).find(Boolean) ?? null;
  const downgraded = g.members.filter((m) => m.claimed_severity === "CRITICAL" && m.severity !== "CRITICAL");

  // The fence is every file the reviewer NAMED, wherever it named it. A fix text alone
  // usually cites one file while the summary and failure scenario carry the producer and
  // consumer the invariant runs through — fencing a cross-file finding to a single file
  // is how every such fix gets declined.
  const extra = new Set();
  for (const m of g.members) {
    for (const match of `${m.fix} ${m.summary ?? ""} ${m.failure_scenario ?? ""}`.matchAll(PATH_RE)) {
      const p = normFile(match[1]);
      if (p && p !== g.file) extra.add(p);
    }
  }
  const diagnosis = g.members.some((m) => DIAGNOSIS_RE.test(`${m.summary} ${m.fix}`)) || !best.fix.trim();
  const fix_profile = diagnosis ? "diagnosis-needed" : extra.size ? "multi-file" : "single-file-prescriptive";

  // Grouping merges two reports of ONE defect. It can also merge two genuinely distinct
  // required edits in the same file (two missing bounds on two columns), and keeping only
  // `best.fix` silently dropped the other one — the fix pass then "resolved" a finding
  // whose second half was never made. Every constituent remedy rides the brief.
  const remedies = [...new Set(g.members.map((m) => m.fix.trim()).filter(Boolean))];
  const summaries = [...new Set(g.members.map((m) => m.summary.trim()).filter(Boolean))];

  const id = `T${i + 1}`;
  const files = [g.file, ...extra].filter(Boolean);
  const brief = [
    `FINDING ${id} (${severity}, confidence ${confidence}, dimension ${best.dimension})`,
    `Location: ${g.file}${best.line != null ? `:${best.line}` : ""}`,
    `What is wrong: ${best.summary}`,
    ...(summaries.length > 1 ? summaries.slice(1).map((t) => `  also reported as: ${t}`) : []),
    scenario ? `Failure scenario: ${scenario}` : null,
    remedies.length > 1 ? "Fix — EVERY one of these edits is required, not the first one only:" : `Fix: ${best.fix}`,
    ...(remedies.length > 1 ? remedies.map((r) => `  - ${r}`) : []),
    "",
    `FENCE: you may modify ${files.map((f) => `\`${f}\``).join(", ")} and nothing else.`,
    "Any other file you must touch has to be declared in `declared_extra[]` with its reason;",
    "an undeclared file is rejected and the fix is re-dispatched. Do not fix anything the",
    "brief does not name — other findings have their own steps.",
    "Return JSON validating against the fix schema (schemas/fix.json in the drive engine).",
  ]
    .filter(Boolean)
    .join("\n");

  return {
    id,
    severity,
    confidence,
    file: g.file,
    line: best.line,
    files,
    summary: best.summary,
    fix: best.fix,
    fixes: remedies,
    failure_scenario: scenario,
    dimension: best.dimension,
    fix_profile,
    streams: g.members.map((m) => `${m.stream}:${m.id ?? "?"}`),
    downgraded: downgraded.length
      ? `claimed CRITICAL by ${downgraded.map((d) => d.stream).join(", ")} without file:line + failure scenario — recorded as WARNING`
      : null,
    fixer_brief: brief,
  };
});

findings.sort((a, b) => (SEV_RANK[b.severity] ?? 0) - (SEV_RANK[a.severity] ?? 0) || b.confidence - a.confidence);

// Advisories ride the artifact AFTER the actionable findings, with no brief and no files:
// drive-lib.sh's fix loop skips `fix_profile: "advisory"`, so they are visible without
// ever costing a dispatch.
for (const a of advisories) {
  findings.push({
    id: `A${findings.filter((f) => f.fix_profile === "advisory").length + 1}`,
    severity: "WARNING",
    confidence: Number(a.confidence ?? 100),
    file: a.file ?? null,
    line: null,
    files: [],
    summary: String(a.summary ?? ""),
    fix: String(a.fix ?? ""),
    fixes: [],
    failure_scenario: null,
    dimension: a.dimension ?? "drift",
    fix_profile: "advisory",
    streams: [`${a.stream}:${a.id ?? "?"}`],
    downgraded: null,
    fixer_brief: "",
  });
}

const actionable = findings.filter((f) => f.fix_profile !== "advisory");
const out = {
  phase,
  range,
  generated: new Date().toISOString(),
  streams: streams.map((s) => s.name),
  // Every stream that was ASKED for, judged or not. `streams` above counts only the ones
  // that actually contributed, so the two lists differing is the audit trail for a phase
  // that was reviewed by fewer eyes than it was dispatched to.
  stream_status: streamRecords.map((s) => ({ name: s.name, path: s.path, status: s.status })),
  streams_counted: streams.length,
  streams_unparseable: streamRecords.filter((s) => s.status === "unparseable" || s.status === "missing").length,
  critical: actionable.filter((f) => f.severity === "CRITICAL").length,
  warning: actionable.filter((f) => f.severity === "WARNING").length,
  advisory: advisories.length,
  observations_filed: observations.length,
  findings,
};

const outAbs = path.isAbsolute(outPath) ? outPath : path.join(process.cwd(), outPath);
fs.mkdirSync(path.dirname(outAbs), { recursive: true });
fs.writeFileSync(outAbs, JSON.stringify(out, null, 2));

console.log(
  `drive-triage: p${phase} — ${out.critical} critical, ${out.warning} warning, ${out.advisory} advisory, ` +
    `${out.observations_filed} observation(s) filed, ${streams.length} stream(s) counted` +
    `${
      out.streams_unparseable
        ? `, ${out.streams_unparseable} NOT counted (${streamRecords
            .filter((s) => !s.data)
            .map((s) => `${s.name}=${s.status}`)
            .join(", ")})`
        : ""
    }` +
    ` → ${outPath}`,
);
process.exit(out.critical ? 2 : out.warning ? 1 : 0);
