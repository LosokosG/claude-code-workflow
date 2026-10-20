// Structural checks over skills/, agents/ and every file that names them:
//   - each skills/<dir>/SKILL.md has frontmatter whose `name` equals <dir> and a non-empty
//     `description`;
//   - each agents/<file>.md has frontmatter whose `name` equals <file> and a description;
//   - every `/skill-name` invocation written anywhere in the repo resolves to a skill here
//     (Claude Code's own built-in commands are allow-listed);
//   - every `--agent <name>` the engine passes resolves to an agent here.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

export function parseFrontmatter(text) {
  const m = /^---\n([\s\S]*?)\n---\n/.exec(text);
  if (!m) return null;
  const out = {};
  const lines = m[1].split("\n");
  for (let i = 0; i < lines.length; i++) {
    const kv = /^([A-Za-z][\w-]*):\s?(.*)$/.exec(lines[i]);
    if (!kv) continue;
    let value = kv[2].trim();
    if (value === ">" || value === "|" || value === ">-" || value === "|-" || value === "") {
      const block = [];
      while (i + 1 < lines.length && /^\s+\S/.test(lines[i + 1])) block.push(lines[++i].trim());
      value = value === "" && block.every((b) => b.startsWith("- ")) ? block : block.join(" ");
    }
    out[kv[1]] = value;
  }
  return out;
}

const listFiles = (dir, pred) => {
  const out = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      if (e.name === ".git" || e.name === "node_modules") continue;
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (pred(p)) out.push(p);
    }
  };
  walk(dir);
  return out;
};

const skillDirs = fs
  .readdirSync(path.join(ROOT, "skills"), { withFileTypes: true })
  .filter((e) => e.isDirectory())
  .map((e) => e.name);
const agentFiles = fs.readdirSync(path.join(ROOT, "agents")).filter((f) => f.endsWith(".md"));

test("there are skills and agents to check", () => {
  assert.ok(skillDirs.length >= 10, `expected at least 10 skills, found ${skillDirs.length}`);
  assert.ok(agentFiles.length >= 2);
});

for (const dir of skillDirs) {
  test(`skills/${dir}/SKILL.md has valid frontmatter`, () => {
    const file = path.join(ROOT, "skills", dir, "SKILL.md");
    assert.ok(fs.existsSync(file), "SKILL.md missing");
    const fm = parseFrontmatter(fs.readFileSync(file, "utf8"));
    assert.ok(fm, "no frontmatter block");
    assert.equal(fm.name, dir, "frontmatter name must equal the folder name");
    assert.equal(typeof fm.description, "string");
    assert.ok(fm.description.length >= 40, "description too short to route on");
    assert.ok(fm.description.length <= 1024, "description over 1024 characters");
    assert.match(dir, /^[a-z][a-z0-9]*(-[a-z0-9]+)*$/, "folder name must be kebab-case");
  });
}

for (const f of agentFiles) {
  test(`agents/${f} has valid frontmatter`, () => {
    const fm = parseFrontmatter(fs.readFileSync(path.join(ROOT, "agents", f), "utf8"));
    assert.ok(fm, "no frontmatter block");
    assert.equal(fm.name, f.replace(/\.md$/, ""));
    assert.ok(fm.description && fm.description.length >= 40);
  });
}

// Claude Code's own slash commands, which may be mentioned without being skills here.
const BUILTIN = new Set(["clear", "compact", "mcp", "code-review", "simplify", "loop", "model", "help", "config", "hooks", "agents", "init"]);
// Absolute directories that read like an invocation in prose.
const NOT_COMMANDS = new Set(["tmp", "dev", "usr", "etc"]);
// A slash invocation: `/name` preceded by start, whitespace, a backtick, a quote or an
// opening bracket, and NOT followed by another path segment, a dot or a word character —
// so `/dev/null`, `src/x.ts` and `and/or` never count.
const INVOCATION = /(?:^|[\s`"'(])\/([a-z][a-z0-9]*(?:-[a-z0-9]+)*)(?![\w/.*$-])/g;

test("every /skill invocation in the repo names a skill that exists", () => {
  const files = listFiles(ROOT, (p) => /\.(md|mjs|sh|json)$/.test(p) && !p.includes(`${path.sep}tests${path.sep}`));
  const missing = [];
  let seen = 0;
  for (const file of files) {
    const text = fs.readFileSync(file, "utf8");
    // In code, a one-word `/x/` is a regex or a sed expression far more often than a
    // command; every skill the engine dispatches has a hyphenated name.
    const isCode = /\.(sh|mjs|json)$/.test(file);
    for (const m of text.matchAll(INVOCATION)) {
      const name = m[1];
      if (BUILTIN.has(name) || NOT_COMMANDS.has(name)) continue;
      if (isCode && !name.includes("-")) continue;
      seen++;
      if (!skillDirs.includes(name)) missing.push(`${path.relative(ROOT, file)}: /${name}`);
    }
  }
  assert.ok(seen > 20, `suspiciously few invocations found (${seen}) — is the pattern broken?`);
  assert.deepEqual([...new Set(missing)], []);
});

test("every --agent the engine dispatches exists in agents/", () => {
  const files = listFiles(path.join(ROOT, "scripts"), (p) => /\.(sh|mjs)$/.test(p));
  const names = new Set();
  for (const file of files)
    for (const m of fs.readFileSync(file, "utf8").matchAll(/--agent\s+([a-z][a-z0-9-]*)/g)) names.add(m[1]);
  assert.ok(names.size >= 2, "expected the engine to dispatch at least two agents");
  for (const n of names) assert.ok(agentFiles.includes(`${n}.md`), `agent ${n} is dispatched but agents/${n}.md is missing`);
});

test("frontmatter parser handles folded descriptions", () => {
  const fm = parseFrontmatter("---\nname: x\ndescription: >\n  first line\n  second line\n---\nbody\n");
  assert.equal(fm.description, "first line second line");
});
