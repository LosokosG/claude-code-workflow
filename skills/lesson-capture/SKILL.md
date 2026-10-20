---
name: lesson-capture
description: Use to turn a problem that keeps coming back into a short rule future sessions load automatically — "remember this as a lesson", "add a lesson", "this keeps happening", or draining the queue of review notes in work/proposed-lessons.md after a drive. Writes path-scoped files under .claude/rules/. Not for one-off bug write-ups.
argument-hint: "[the rule in a sentence] | --drain"
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - AskUserQuestion
---

# lesson-capture

A lesson is worth writing when it would have changed how past work was framed or fixed,
and the same situation will come up again. A single incident, however painful, is a commit
message — not a lesson.

Lessons live in `.claude/rules/lessons-<area>.md`. Each file has `paths:` frontmatter, so
Claude Code loads it whenever a session touches matching files, and the drive engine
appends all of them to its review and verify steps (code read through `git diff` does not
trigger path-scoped loading). No lesson loads in a session that never comes near its
paths — keep it that way.

## Two ways in

- **`/lesson-capture <sentence>`** — write one lesson. The sentence is a draft of the rule,
  not the final wording.
- **`/lesson-capture --drain`** — go through `work/proposed-lessons.md`, the queue that
  reviews and drive triage append notes to. For each line: promote it to a lesson (then
  follow the steps below), merge it into an existing lesson, or discard it. Remove handled
  lines from the queue. Most lines are discards; that is the queue working.

## 1. Collect four facts

Ask with `AskUserQuestion` — in one round or four. Do not pre-fill answers: the user's
wording is the point. A seed sentence from the invocation may be shown as a suggestion
next to the rule question, never as the default.

| Fact | What a good answer looks like |
| --- | --- |
| **Seen** | the observable failure, described as a shape rather than a story ("the cache key ignores the locale, so a second language serves the first one's page") |
| **Rule** | imperative, one or two sentences, quotable in a future review ("Include every request dimension that changes the output in the cache key.") |
| **Because** | the mechanism — why the obvious approach fails and why existing checks miss it |
| **Check** | the grep, test, command or deliberate violation that exposes a breach; if there is none, say "no check yet" — that gap is useful information |

## 2. Choose the file

The file is decided by **where a future agent will be editing** when the rule matters —
not by where the problem was first noticed. List the existing
`.claude/rules/lessons-*.md` files with their `paths:` and propose the best match, with a
one-line reason, in one `AskUserQuestion` (best match first, then the others, then "new
file"). For a new file, ask for the area name and the globs.

A new lessons file starts like this:

```markdown
---
description: Lessons for <area>. Loaded when a matching file is touched.
paths:
  - "<glob>"
---

# <area>: recurring rules
```

## 3. Show the entry, then write it

The entry, exactly in this shape:

```markdown
## <the rule as a short imperative title>

- **Id:** <area>-<NN> · added <YYYY-MM-DD>
- **Seen:** …
- **Rule:** …
- **Because:** …
- **Check:** …
```

The id is the next free number in that file (`grep -o "<area>-[0-9]*" <file> | sort -V | tail -1`).
The title is what people scan, so keep it short.

Show the entry and ask: write it / change it / cancel. On "write", append it to the end of
the file. Do not reorder, reword or merge existing entries — revising a lesson is a
deliberate, separate edit, never a side effect of adding one.

## 4. Confirm

Re-read the file, confirm the new entry is last and the frontmatter is intact, and print:

```
Lesson added: .claude/rules/lessons-<area>.md — <area>-<NN> "<title>"
Loads for: <globs>
```

Then stop. Do not continue into other skills.

## Keep files small

A lessons file is loaded whole every time it matches, so every line costs context in every
matching session. Four fields per entry, nothing else. When a file passes about 150 lines,
tell the user; splitting it is a separate task. One lesson per run — batching produces
half-finished entries.
