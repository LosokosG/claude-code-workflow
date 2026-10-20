# claude-code-workflow

Skills, two sub-agents and a small bash engine that let Claude Code carry a multi-phase
change from an approved plan to reviewed commits — one phase at a time, each step in a
fresh context, with the plan file and git as the only state.

## The problem

Long changes done with an AI coding agent drift. Phases get merged or quietly skipped.
"Done" gets declared without anything that proves it. A review written in the same
conversation that wrote the code agrees with it. And by phase four, the context holding the
decisions from phase one is gone.

## How it works

```
/start-change ──► /prep ──────────────────────────────────────────► /drive
                   ├─ /research-wave   (only for named open decisions)
                   ├─ /phase-plan      plan.md: phases + a Progress table
                   └─ /plan-review     a fresh reviewer reads the plan cold

drive.sh, for each open phase:
  implement ─► scope check ─► review ─► triage ─► fixer per finding ─► ≤1 re-review ─► next
  (claude -p)   (paths, size)  (1 or 2    (script,   (fenced, escalates
                               lenses)     no model)  once, then gates)
after the last phase:
  verifier (evidence files or UNVERIFIED) ─► hand-back block in drive-log.md
```

**The plan** (`work/changes/<id>/plan.md`) is short and delta-shaped. Every phase has
`Changes:`, `Done when:` (a check that can fail), `risk:` and `paths:` (the declared
scope). A `## Progress` table with one row per phase — `[ ]`, `[x]` or `[~]` — is the
state. `scripts/check-plan-progress.mjs` lints that contract.

**The engine** (`scripts/drive/`) is bash and Node, not an LLM. Each step is a separate
`claude -p` call with a JSON schema for its result: `/implement-phase` (or `/tdd-phase`)
writes and commits one phase and flips its row; `/phase-review` reviews exactly that
commit range, as two parallel lenses (drift, safety) when the phase is risk-tagged or
touches a reserved path; `drive-triage.mjs` merges the review streams and builds one fixer
brief per finding; the `drive-fixer` agent applies each fix inside a declared file fence;
the `drive-verifier` agent runs every `Done when:` command and saves the output. The
session that launched the run only watches it — `drive-ctl.sh` gives status, log, steer,
ask, pause, resume, stop and ack.

**Supporting skills:** `/quick` (small surface-free work on a short branch, no plan),
`/change-status` (where everything is, one recommended command), `/lesson-capture`
(recurring problems become path-scoped rule files that later sessions and drive reviews
load), `/integrate-lane` (land the second of two parallel branches on a moved main: merge,
full gate, live check, then land).

## Design decisions that are actually implemented

Each of these is enforced in the engine and covered by a deterministic check in
`scripts/drive/drive-selftest.sh` or the Node tests; [`docs/design-decisions.md`](docs/design-decisions.md)
maps every decision to its code and its check.

- **A fresh context per step, and an orchestrator that spends no tokens.** The self-test's
  `claude` shim logs every invocation with the step that made it; a call without a step
  marker fails the test.
- **State is the Progress table plus git.** A resume after a crash, `kill -9` or an
  overnight usage limit just reads the table again. A per-phase stage file makes a resume
  re-enter a committed-but-unreviewed phase at review, not at implement.
- **A PASS without artifacts is not a PASS.** The verifier must save evidence files; a
  flow without them is reported as UNVERIFIED in the hand-back.
- **The reviewer is never below the implementer's model tier.** The engine refuses to
  dispatch such a review and stops for a human instead of degrading.
- **Triage is code, not judgement.** Findings are merged by file and mechanism; a CRITICAL
  without `file:line` and a failure scenario is recorded as a WARNING; confidence under 80
  is dropped; notes go to a lessons queue and are never "fixed".
- **The fixer finds the problem again at HEAD.** By symbol, not line number; an obsolete
  finding is declined, not forced. A declined fix is re-dispatched once, then escalated
  once with a wider fence; if that fails too, the next phase will not start until a human
  runs `drive-ctl ack`.
- **Out-of-scope work is allowed when declared.** An undeclared file becomes an
  "unplanned" WARNING for review; nothing is ever auto-reverted.
- **At most one re-review per phase.** A CRITICAL that survives it is a human decision.
- **Failures are classified, not retried blindly.** A usage limit sleeps until the stated
  reset plus a margin and does not count as a failure; a budget kill resets only the
  step's declared paths and restores files the user already had dirty, byte for byte; a
  hung step is killed at a wall-clock limit and retried once.
- **The run never pushes and never archives.** Both stay with the user.

## Limits

- **Built for my own projects on Claude Code.** It depends on `claude -p` with
  `--json-schema`, `--agent`, `--max-budget-usd` and `--dangerously-skip-permissions`.
  I have used it on my own repositories; it has not been tried on anyone else's setup.
- **No metrics.** The self-test proves the engine's control flow with stubbed and shimmed
  model calls. It says nothing about the quality of what a model produces, which depends on
  the model and the plan.
- **Codex:** the `needs-input` alert hook has a Codex version, and the skills use the
  `SKILL.md` frontmatter format Codex also reads, but I have not verified the skills in
  Codex, and the engine only drives the `claude` CLI.
- **Linux first.** Needs bash 4+, git, Node (24 in CI), GNU coreutils (`timeout`,
  `date -d`), `ps`, `pgrep`, `setsid`, `flock`. Optional: `gh`, `notify-send`,
  `systemd-inhibit`, `systemctl`. macOS is untested.
- **Steps run with permissions skipped.** Run a PreToolUse guard hook that denies
  irreversible commands (force pushes, destructive database commands, secret writes). The
  engine exports `DRIVE_RUN=1` so a guard can be stricter during a drive. Mine lives in a
  separate repository, agent-dev-guardrails; this one does not include a guard.
- **`hooks/worktree-bootstrap.sh` copies `.env` from the main checkout into each new
  worktree**, so secrets exist on disk once per worktree until it is removed.
  `drive-checkout.sh` does the same for the worktrees it creates.

## Install

Per project (or put skills and agents in `~/.claude/` to share them across projects):

```bash
P=/path/to/your/project
mkdir -p "$P/.claude/skills" "$P/.claude/agents" "$P/scripts"
cp -r skills/* "$P/.claude/skills/"
cp agents/*.md "$P/.claude/agents/"
cp -r scripts/drive scripts/lib scripts/check-plan-progress.mjs "$P/scripts/"
printf '.claude/worktrees/\nwork/changes/*/drive/\n' >> "$P/.gitignore"
```

Optional:

- `rules/*.md` → `.claude/rules/` (`research.md` and `dependencies.md` are path-scoped;
  the other four are general working rules).
- `hooks/*.sh` → `.claude/hooks/` (and `hooks/needs-input-alert.sh` → `~/.claude/hooks/`),
  then merge `hooks/claude-settings.example.json` into your settings. For Codex:
  `hooks/codex/needs-input-alert.sh` → `~/.codex/hooks/` and
  `hooks/codex/hooks.example.json` into `~/.codex/hooks.json`.
- `work/surface-globs.json` — `{ "surfaces": ["db/migrations/**", …] }` — paths that
  always get both review lenses, whatever a phase's `risk:` line says.
- `work/setup-worktree.sh <id> <checkout>` — run by `drive-checkout.sh` for per-worktree
  setup (a database branch, seed data).

Change folders live in `work/changes/<id>/`; set `DRIVE_WORK_DIR` to use another
directory. Then start with `/start-change <id>`.

## Layout

| Path | What |
| --- | --- |
| `skills/drive/` | launches and watches a run; the chat becomes its control room |
| `skills/phase-plan/` | writes `plan.md`; `references/progress-format.md` is the contract |
| `skills/plan-review/` | cold review of a plan; `scripts/verify-claims.mjs` for `--deep` |
| `skills/implement-phase/`, `skills/tdd-phase/` | build one phase, one commit |
| `skills/phase-review/` | review a commit range against its phase row |
| `skills/start-change/`, `skills/prep/` | open a change; idea → reviewed plan |
| `skills/research-wave/` | parallel research lanes for open decisions; `scripts/wave-workflow.mjs` |
| `skills/change-status/`, `skills/quick/`, `skills/lesson-capture/`, `skills/integrate-lane/` | supporting skills |
| `agents/` | `drive-verifier`, `drive-fixer` |
| `scripts/drive/` | the engine: `drive.sh`, `drive-ctl.sh`, `drive-checkout.sh`, step runner, triage, scope check, schemas, self-test and its stubs |
| `scripts/check-plan-progress.mjs`, `scripts/lib/` | plan linter |
| `rules/`, `hooks/` | small standalone rules and hooks I use alongside the workflow |
| `tests/` | Node tests: skill/agent validator, plan linter, triage and scope check |
| `docs/design-decisions.md` | the decisions above, with where each is enforced |

## Tests

```bash
node --test 'tests/*.test.mjs'          # validator, plan linter, triage, scope check
bash scripts/drive/drive-selftest.sh    # 26 engine checks in throwaway repos, no model calls
bash scripts/drive/drive-selftest.sh --real   # plus one real phase on your claude CLI (spends tokens)
```

CI runs the first two and `shellcheck` on every push.

## Origin

I built these between July and October 2026 while working on my own products. The
phase-based plan → implement → review workflow is a common pattern; I first used it in a
course and later rewrote the tooling around it in my own words.

## License

MIT — see [LICENSE](LICENSE).
