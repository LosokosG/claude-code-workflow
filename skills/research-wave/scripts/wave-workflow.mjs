// Workflow script for /research-wave: run the lanes in parallel, screen each deliverable
// as soon as its lane returns, and synthesize only when every lane screened done.
//
// args: {
//   changeId, repoRoot,
//   lanes: [{ id, brief, path, decision }],   // brief = the full lane prompt; path = ABSOLUTE deliverable path
//   synthesis: { path, decisions },           // path absolute; decisions = the list being settled, as text
//   allPaths?: [absolute paths],              // re-runs: EVERY lane's deliverable, done ones included,
//                                             // so the synthesis still reads the whole wave
// }
// returns: { lanes: [{ id, status, summary, gaps }], allDone, synthesis }
//
// Models: lanes and synthesis do research and run on the strong tier; the screen is a
// mechanical "does this file answer that question" check and runs cheap.

export const meta = {
  name: "research-wave",
  description: "Parallel research lanes, a screen per deliverable, one synthesis when all lanes are done",
  phases: [
    { title: "Lanes", detail: "one research agent per decision", model: "opus" },
    { title: "Screen", detail: "does the file answer its decision?", model: "sonnet" },
    { title: "Synthesis", detail: "one agent over every lane file", model: "opus" },
  ],
};

const input = typeof args === "string" ? JSON.parse(args) : args;

const SCREEN = {
  type: "object",
  required: ["exists", "answers", "summary"],
  properties: {
    exists: { type: "boolean" },
    answers: { type: "boolean" },
    summary: { type: "string" },
    gaps: { type: "string" },
  },
};

const screened = await pipeline(
  input.lanes,
  (lane) => agent(lane.brief, { label: lane.id, phase: "Lanes", model: "opus" }),
  async (result, lane) => {
    // A null result means the lane agent never produced anything (a usage limit or a hard
    // failure). It did not run, so it is not an attempt and not "done".
    if (result === null) {
      return { id: lane.id, status: "limit-killed", summary: "the lane returned nothing — it did not run", gaps: "" };
    }
    const check = await agent(
      `Open ${lane.path}. If it is missing or empty, set exists=false. The decision this file ` +
        `must settle: ${lane.decision}. Judge the FILE, not what the lane said about it: does ` +
        `it actually settle that decision? Summarise its answer in at most five lines and name ` +
        `any gaps. Read only; change nothing.`,
      { label: `screen ${lane.id}`, phase: "Screen", model: "sonnet", effort: "low", schema: SCREEN },
    );
    if (!check) {
      return { id: lane.id, status: "incomplete", summary: "the screen did not return — check the file by hand", gaps: "" };
    }
    return {
      id: lane.id,
      status: check.exists && check.answers ? "done" : "incomplete",
      summary: check.summary,
      gaps: check.gaps ?? "",
    };
  },
);

const lanes = screened.filter(Boolean);
const done = lanes.filter((l) => l.status === "done").length;
const allDone = lanes.length === input.lanes.length && done === input.lanes.length;

let synthesis = null;
if (allDone) {
  const paths = input.allPaths ?? input.lanes.map((l) => l.path);
  synthesis = await agent(
    `Write the synthesis for the research wave of change ${input.changeId} ` +
      `(repository root ${input.repoRoot}). Read every one of these files in full — the ` +
      `files themselves, not summaries: ${paths.join(", ")}.\n\n` +
      `Decisions being settled:\n${input.synthesis.decisions}\n\n` +
      `Write ${input.synthesis.path}, at most 150 lines. For each decision: the answer, the ` +
      `lane file that supports it, your confidence, and what is still open. Where lanes ` +
      `disagree, report the disagreement rather than splitting the difference. Then reply ` +
      `with at most ten lines on what is settled and what is not.`,
    { label: "synthesis", phase: "Synthesis", model: "opus" },
  );
} else {
  log(`No synthesis: ${done}/${input.lanes.length} lanes done — the caller re-runs or hands back`);
}

return { lanes, allDone, synthesis };
