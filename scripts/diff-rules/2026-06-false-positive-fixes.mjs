export const id = "false-positive-fixes";
export const reason =
  "PR #46 fixed four false positives: invalid-mapping-values (string-form `concurrency` is valid), unknown-context-or-function (hyphenated `needs.<job-id>` ids were split on `-`, so the fix both drops bogus findings and surfaces the genuine whole-id ones the split previously masked), unknown-runner-label (`ubuntu-slim` is an official runner), and github-app-limit-permissions (granular `permission-*` inputs). Captures taken from prod before that fix shipped still carry those findings, so replaying them against the fixed worker drops/rewrites them. This rule suppresses such diffs as long as *every* added or removed diagnostic's `rule` is one PR #46 touched — anything outside the set is still a genuine regression.";

// Rules whose firing behaviour PR #46 corrected. A replay diff is suppressed
// only when every moving diagnostic (captured-only or replayed-only) belongs
// to one of these.
const fixed = new Set([
  "invalid-mapping-values",
  "unknown-context-or-function",
  "unknown-runner-label",
  "github-app-limit-permissions",
]);

export function matches(_capture, _replayed, diff) {
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;
    if (!d.onlyInCaptured.every((x) => fixed.has(x.rule))) return false;
    if (!d.onlyInReplayed.every((x) => fixed.has(x.rule))) return false;
  }
  return true;
}
