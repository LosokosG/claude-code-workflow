// Shared parsing helpers for plan.md files (see skills/phase-plan/references/progress-format.md).
//
// A plan's `## Progress` section is a markdown table whose header names both `Phase` and
// `Status`. The header is looked for among the first few non-blank lines, so a one-line
// lead-in note above the table does not hide it. A `|`-header that names Phase but not
// Status is reported as a botched header rather than silently ignored.

export const DETECT_SCAN_LINES = 5;

/**
 * Locate the `## Progress` section.
 * @param {string[]} lines plan.md split on "\n"
 * @returns {{ start: number, end: number, count: number }} 0-based heading index, the index
 *   of the next `## ` heading (or lines.length), and how many `## Progress` headings exist.
 */
export function findProgress(lines) {
  const headings = [];
  lines.forEach((l, i) => {
    if (/^## Progress\s*$/.test(l)) headings.push(i);
  });
  const start = headings[0] ?? -1;
  let end = lines.length;
  if (start !== -1) {
    for (let i = start + 1; i < lines.length; i++) {
      if (lines[i].startsWith("## ")) {
        end = i;
        break;
      }
    }
  }
  return { start, end, count: headings.length, headings };
}

/**
 * @param {string} planText full plan.md contents
 * @returns {{ format: "table", headerLine: number } | { format: "table", badHeader: { line: number, text: string } } | { format: "none" }}
 *   Line numbers are 0-based indices into `planText.split("\n")`.
 */
export function detectFormat(planText) {
  const lines = planText.split("\n");
  const { start, end } = findProgress(lines);
  if (start === -1) return { format: "none" };

  let scanned = 0;
  for (let i = start + 1; i < end && scanned < DETECT_SCAN_LINES; i++) {
    const l = lines[i].trim();
    if (!l) continue;
    scanned++;
    if (!l.startsWith("|")) continue;
    const hasPhase = /\bphase\b/i.test(l);
    const hasStatus = /\bstatus\b/i.test(l);
    if (hasPhase && hasStatus) return { format: "table", headerLine: i };
    if (hasPhase) return { format: "table", badHeader: { line: i, text: l } };
  }
  return { format: "none" };
}
