export const id = "promote-zizmor-planned-rules";
export const reason =
  "PR #14 promotes every Planned zizmor rule to Implemented (plus actionlint:yaml-anchor-issues) and broadens several already-Implemented rules. When the PR worker replays a request that was captured in prod before this PR shipped, the replayed response may add new findings, drop superseded ones, or rewrite severity/message of existing ones — all attributable to the rules listed below. This rule suppresses such diffs as long as *every* added or removed diagnostic's `rule` is in that set.";

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
    // Both sides may move: added findings from freshly-firing audits,
    // removed/replaced findings from broadened audits whose severity or
    // message text was rewritten. Either is fine so long as every moving
    // diagnostic belongs to a rule promoted/broadened by this PR.
    if (!d.onlyInCaptured.every((x) => promoted.has(x.rule))) return false;
    if (!d.onlyInReplayed.every((x) => promoted.has(x.rule))) return false;
  }
  return true;
}
