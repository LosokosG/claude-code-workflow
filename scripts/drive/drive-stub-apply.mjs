// Stub backend side-effect applier — the deterministic self-test seam for drive-step.sh.
//
//   node drive-stub-apply.mjs <stub.json> <out.json> <repo> <change-dir, repo-relative> <phase>
//
// A canned JSON result alone would prove nothing: "the Progress row flipped" and "the
// fixer touched an undeclared file" are assertions about EFFECTS. So a stub declares its
// effects (`touched_files`, `stub_commit`) and this script performs them for real — files
// created, row flipped, commit made — then hands back the result with the real SHA
// patched in. The engine downstream cannot tell a stub from a model; that is the point.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const [, , stubPath, outPath, repo, changeRel, phase] = process.argv;
const changeId = changeRel ? path.basename(changeRel) : "";
const stub = JSON.parse(fs.readFileSync(stubPath, "utf8"));
const result = { ...stub };
delete result.stub_commit;
delete result.stub_outcome;
delete result.stub_body;
delete result.stub_plan_dirty;

const git = (...args) => execFileSync("git", ["-C", repo, ...args], { encoding: "utf8" });

if (stub.stub_commit) {
  const touched = [...(stub.touched_files ?? [])];
  for (const rel of touched) {
    const abs = path.join(repo, rel);
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    if (!fs.existsSync(abs)) fs.writeFileSync(abs, stub.stub_body ?? `export const stub = ${phase || 1};\n`);
    else fs.appendFileSync(abs, `// stub touch p${phase}\n`);
  }

  // Flip this phase's Progress row, the way a real implementer would.
  const planPath = path.join(repo, changeRel ?? "", "plan.md");
  if (changeId && phase && fs.existsSync(planPath)) {
    const lines = fs.readFileSync(planPath, "utf8").split("\n");
    const re = new RegExp(`^\\|\\s*P${phase}\\b`);
    for (let i = 0; i < lines.length; i++) {
      if (re.test(lines[i]) && lines[i].includes("[ ]")) {
        lines[i] = lines[i].replace("[ ]", "[x]");
        break;
      }
    }
    fs.writeFileSync(planPath, lines.join("\n"));
    // `stub_plan_dirty` reproduces the plan-flip regression the self-test pins: an implementer that
    // flips the row and commits WITHOUT it, leaving plan.md dirty for somebody else to
    // fold in. The engine's drive_commit_plan_flip is what has to notice.
    if (!stub.stub_plan_dirty) touched.push(path.relative(repo, planPath));
  }

  for (const rel of touched) git("add", "--", rel);
  const staged = git("diff", "--cached", "--name-only").trim();
  if (staged) {
    git(
      "-c", "core.hooksPath=/dev/null",
      "commit", "-m", `stub(${changeId}): phase ${phase} (${changeId} p${phase})`,
    );
    result.commit_sha = git("rev-parse", "--short", "HEAD").trim();
    if ("diff_lines" in result && !result.diff_lines) {
      const stat = git("diff", "--shortstat", "HEAD~1..HEAD");
      const add = Number(/(\d+) insertion/.exec(stat)?.[1] ?? 0);
      const del = Number(/(\d+) deletion/.exec(stat)?.[1] ?? 0);
      result.diff_lines = add + del;
    }
  }
}

fs.writeFileSync(outPath, JSON.stringify(result, null, 2));
