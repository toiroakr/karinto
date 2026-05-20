export const id = "promote-zizmor-planned-rules";
export const reason =
  "PR #14 promotes every Planned zizmor rule to Implemented (plus actionlint:yaml-anchor-issues), so prod captures predating this PR see additional Info/Warning findings on the workflows they were taken from. Only suppresses *new* findings whose `rule` is one of the freshly-firing or freshly-broadened zizmor audits.";

// Every rule promoted (or whose scope was broadened) by PR #14. If the
// replayed worker emits a diagnostic whose `rule` is outside this list, the
// diff is *not* suppressed — that is a genuine regression.
const promoted = new Set([
  "anonymous-definition",
  "archived-uses",
  "artipacked",
  "cache-poisoning",
  "dependabot-cooldown",
  "dependabot-execution",
  "excessive-permissions",
  "forbidden-uses",
  "github-app",
  "github-env",
  "impostor-commit",
  "insecure-commands",
  "misfeature",
  "obfuscation",
  "overprovisioned-secrets",
  "ref-version-mismatch",
  "self-hosted-runner",
  "superfluous-actions",
  "template-injection",
  "undocumented-permissions",
  "unpinned-images",
  "unpinned-tools",
  "unredacted-secrets",
  "unsound-condition",
  "use-trusted-publishing",
  "yaml-anchor-issues",
  // also broadened: concurrency-limits was already implemented but its scope
  // is reached more often now that other rules no longer short-circuit.
  "concurrency-limits",
]);

export function matches(_capture, _replayed, diff) {
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;
    // Nothing should disappear — PR only adds findings.
    if (d.onlyInCaptured.length > 0) return false;
    if (!d.onlyInReplayed.every((x) => promoted.has(x.rule))) return false;
  }
  return true;
}
