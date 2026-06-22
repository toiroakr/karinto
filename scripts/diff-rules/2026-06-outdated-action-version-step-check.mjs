export const id = "outdated-action-version-step-check";
export const reason =
  "PR #64 extends the `outdated-action-version` rule to workflow step `uses:` references. Previously the rule only checked action.yml `runs.using` fields; step-level references to known-outdated actions (e.g. actions/checkout@v3, actions/setup-go@v3) were silently ignored. Captures taken before this PR shipped do not carry these findings, so replaying them against the PR worker produces new `outdated-action-version` diagnostics. This rule suppresses those diffs. Self-expiring: once prod captures roll over (~30 days after release) all captures will already contain these findings and no diff is produced.";

// Only suppress diffs where the PR adds new step-level outdated-action-version
// diagnostics and nothing is removed. The step-level check emits messages of
// the form "action `owner/repo@vN` uses a deprecated Node.js runtime; …".
// Action.yml-level findings ("runtime `nodeXX` is deprecated; …") are excluded
// so they are never masked by this rule.
function isOutdatedActionVersion(x) {
  return (
    x.rule === "outdated-action-version" &&
    typeof x.message === "string" &&
    x.message.startsWith("action `") &&
    x.message.includes("uses a deprecated Node.js runtime")
  );
}

export function matches(_capture, _replayed, diff) {
  let sawNewFinding = false;
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;
    // We must not suppress cases where existing findings disappear.
    if (d.onlyInCaptured.length > 0) return false;
    // Every new finding must be attributed to this rule.
    if (!d.onlyInReplayed.every(isOutdatedActionVersion)) return false;
    if (d.onlyInReplayed.length > 0) sawNewFinding = true;
  }
  // Require at least one new finding to avoid matching trivially-empty diffs.
  return sawNewFinding;
}
