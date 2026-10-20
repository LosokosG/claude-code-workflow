// Workflow script for /plan-review --deep: check a plan's riskiest claims against the
// code, in parallel, one read-only verifier per claim.
//
// args: {
//   planPath, changeId,
//   claims: [{ id, claim, anchors }],      // anchors = paths / symbols to start reading from
//   blastRadius: { symbols: [ … ] },       // what the plan changes; callers it does not list
//   patternAreas: [ … ]                    // areas where the plan introduces a new pattern; [] to skip
// }
// returns: { claims: [ … ], unverified: [ids], callers: { … }, patterns: { … } | null }
//
// No model is pinned on purpose: every verifier inherits the session's model, because this
// is a review gate and a gate is never routed below the tier that wrote the work.

export const meta = {
  name: "plan-claim-verifiers",
  description: "Verify a plan's riskiest claims, unlisted callers and duplicated patterns against the codebase",
  phases: [{ title: "Verify", detail: "one read-only agent per claim, plus callers and patterns" }],
};

const input = typeof args === "string" ? JSON.parse(args) : args;
const where = `plan ${input.planPath} (change ${input.changeId})`;

const CLAIM = {
  type: "object",
  required: ["id", "result", "evidence"],
  properties: {
    id: { type: "string" },
    result: { enum: ["HOLDS", "CONTRADICTED", "PARTIAL", "CANNOT_TELL"] },
    evidence: { type: "string" },
    consequence: { type: "string" },
  },
};
const CALLERS = {
  type: "object",
  required: ["unlisted"],
  properties: {
    unlisted: {
      type: "array",
      items: {
        type: "object",
        required: ["symbol", "file"],
        properties: { symbol: { type: "string" }, file: { type: "string" }, why: { type: "string" } },
      },
    },
  },
};
const PATTERNS = {
  type: "object",
  required: ["duplicates"],
  properties: {
    duplicates: {
      type: "array",
      items: {
        type: "object",
        required: ["planned", "existing"],
        properties: { planned: { type: "string" }, existing: { type: "string" }, why: { type: "string" } },
      },
    },
  },
};

const jobs = input.claims.map(
  (c) => () =>
    agent(
      `You are checking one statement made in ${where}. Do not edit anything.\n\n` +
        `Statement ${c.id}: ${c.claim}\nStart reading at: ${c.anchors}\n\n` +
        `Read the code and decide: HOLDS, CONTRADICTED, or PARTIAL. Use CANNOT_TELL only when ` +
        `the code genuinely cannot settle it. Quote file:line for whatever you conclude, and ` +
        `when it does not hold, say what that means for the plan. Return id "${c.id}".`,
      { label: `claim ${c.id}`, phase: "Verify", schema: CLAIM },
    ),
);
jobs.push(() =>
  agent(
    `For ${where}: the plan changes these symbols or endpoints: ${JSON.stringify(input.blastRadius?.symbols ?? [])}. ` +
      `Search the repository for every caller or importer of them that the plan does not mention. ` +
      `List only those, with file paths. Do not edit anything.`,
    { label: "unlisted callers", phase: "Verify", schema: CALLERS },
  ),
);
const wantPatterns = Array.isArray(input.patternAreas) && input.patternAreas.length > 0;
if (wantPatterns) {
  jobs.push(() =>
    agent(
      `For ${where}: the plan introduces new ways of doing things in these areas: ` +
        `${JSON.stringify(input.patternAreas)}. For each, check whether the codebase already ` +
        `has an established way to do the same thing. Report each case as planned-versus-existing ` +
        `with file paths. Do not edit anything.`,
      { label: "existing patterns", phase: "Verify", schema: PATTERNS },
    ),
  );
}

const results = await parallel(jobs);
const n = input.claims.length;
const claims = results.slice(0, n).filter(Boolean);
return {
  claims,
  unverified: input.claims.filter((c) => !claims.some((r) => r.id === c.id)).map((c) => c.id),
  callers: results[n] ?? { unlisted: [], note: "the caller search returned nothing — treat as unchecked" },
  patterns: wantPatterns ? (results[n + 1] ?? { duplicates: [], note: "the pattern check returned nothing" }) : null,
};
