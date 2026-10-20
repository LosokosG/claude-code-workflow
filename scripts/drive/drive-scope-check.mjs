// Scope controls for the drive engine.
//
// The principle: out-of-scope work is ALLOWED when declared with a reason; the violation
// is doing it silently. Nothing here ever reverts anything — an undeclared file becomes a
// WARNING "unplanned" that the reviewer resolves as declare-or-revert.
//
// Modes:
//   drive-scope-check.mjs <impl.json> <paths-file> <declared-size> <out.json> [--bookkeeping <change-dir>]
//       Writes review-shaped findings for undeclared out-of-scope files. Files under the
//       change folder itself (plan.md, change.md, drive-log.md, drive/) are bookkeeping
//       and never count. exit 0 clean · 1 size trigger only · 2 unplanned files · 3 both.
//   drive-scope-check.mjs --surface <impl.json> <surface-globs.json>
//       exit 0 when a touched file matches a reserved surface (→ risk-flag the phase),
//       1 when none does. Silent.
//   drive-scope-check.mjs --surface-list <surface-globs.json>   (paths on stdin)
//       Prints every stdin path that matches a reserved surface; exit 0 when at least one
//       does, 1 when none does. `git diff --cached --name-only | …` is the intended input.
//   drive-scope-check.mjs --fence <fix.json> <fence-file>
//       exit 0 when touched_files ⊆ (fence ∪ declared_extra), 1 otherwise. Prints the
//       offending paths.
//
// surface-globs.json is either an array of globs or `{ "surfaces": [ … ] }`.
import fs from "node:fs";

const readJson = (p) => JSON.parse(fs.readFileSync(p, "utf8"));
const norm = (p) =>
  String(p ?? "")
    .replace(/^\.\//, "")
    .trim();

// `**` crosses separators, a single `*` does not. Deliberately small — a plan's `paths:`
// are directory prefixes and filenames, not brace expansions.
const globToRe = (g) => {
  const SEP = "\u0000";
  const body = String(g)
    .replace(/[.+^${}()|[\]\\]/g, "\\$&")
    .replace(/\*\*/g, SEP)
    .replace(/\*/g, "[^/]*")
    .split(SEP)
    .join(".*")
    .replace(/\?/g, ".");
  return new RegExp("^" + body + "(/.*)?$");
};

const matchesAny = (file, globs) => globs.some((g) => globToRe(g).test(file));
const surfaceGlobs = (p) => {
  const raw = readJson(p);
  return (Array.isArray(raw) ? raw : (raw.surfaces ?? [])).map(String);
};

const args = process.argv.slice(2);

if (args[0] === "--surface") {
  const impl = readJson(args[1]);
  const globs = surfaceGlobs(args[2]);
  const touched = (impl.touched_files ?? []).map(norm);
  process.exit(touched.some((f) => matchesAny(f, globs)) ? 0 : 1);
}

if (args[0] === "--surface-list") {
  const globs = surfaceGlobs(args[1]);
  const hits = fs
    .readFileSync(0, "utf8")
    .split("\n")
    .map(norm)
    .filter(Boolean)
    .filter((f) => matchesAny(f, globs));
  for (const h of hits) console.log(h);
  process.exit(hits.length ? 0 : 1);
}

if (args[0] === "--fence") {
  const fix = readJson(args[1]);
  const fence = fs.readFileSync(args[2], "utf8").split("\n").map(norm).filter(Boolean);
  const declared = (fix.declared_extra ?? []).map((d) => norm(d.file));
  const allowed = [...fence, ...declared];
  const offending = (fix.touched_files ?? [])
    .map(norm)
    .filter((f) => !allowed.some((a) => f === a || matchesAny(f, [a])));
  if (offending.length) {
    console.error(`drive-scope-check: fence violation — undeclared: ${offending.join(", ")}`);
    process.exit(1);
  }
  process.exit(0);
}

const bkIdx = args.indexOf("--bookkeeping");
const bookkeepingDir = bkIdx === -1 ? "" : norm(args[bkIdx + 1]).replace(/\/$/, "");
const positional = bkIdx === -1 ? args : args.filter((_, i) => i !== bkIdx && i !== bkIdx + 1);
const [implPath, pathsFile, sizeRaw, outPath] = positional;
if (!implPath || !pathsFile) {
  console.error("usage: drive-scope-check.mjs <impl.json> <paths-file> <declared-size> <out.json> [--bookkeeping <change-dir>]");
  process.exit(64);
}
const impl = readJson(implPath);
const globs = fs.readFileSync(pathsFile, "utf8").split("\n").map(norm).filter(Boolean);
const declaredSize = Number(sizeRaw) || 300;

const declared = new Set((impl.out_of_scope ?? []).map((o) => norm(o.file)));
const touched = (impl.touched_files ?? []).map(norm).filter(Boolean);

// The plan and the change folder are the engine's own bookkeeping — every phase writes
// them, so no row has to declare them.
const isBookkeeping = (f) => Boolean(bookkeepingDir) && (f === bookkeepingDir || f.startsWith(bookkeepingDir + "/"));

const findings = [];
let n = 1;
for (const f of touched) {
  if (isBookkeeping(f)) continue;
  if (matchesAny(f, globs)) continue;
  if (declared.has(f)) continue;
  findings.push({
    id: `S${n++}`,
    severity: "WARNING",
    confidence: 100,
    file: f,
    line: null,
    summary: `unplanned: \`${f}\` is neither in the row's \`paths:\` nor declared in out_of_scope[] with a reason`,
    fix: "Declare it in out_of_scope[] with the reason it was necessary, or revert it. Declare-or-revert is the implementer's or the user's call — never auto-reverted.",
    dimension: "drift",
  });
}

const oversized = Number(impl.diff_lines ?? 0) > 2 * declaredSize;
const observations = oversized
  ? [
      `Phase diff is ${impl.diff_lines} lines against a declared size of ${declaredSize} (>2x) — a full review pass was forced. Keep or split into a new row; this is a conscious call, not a block.`,
    ]
  : [];

if (outPath) fs.writeFileSync(outPath, JSON.stringify({ findings, observations }, null, 2));
if (findings.length) {
  console.error(`drive-scope-check: ${findings.length} unplanned file(s): ${findings.map((f) => f.file).join(", ")}`);
}
if (oversized) {
  console.error(`drive-scope-check: diff ${impl.diff_lines} > 2x declared size ${declaredSize} — forcing a review`);
}

process.exit((findings.length ? 2 : 0) + (oversized ? 1 : 0));
