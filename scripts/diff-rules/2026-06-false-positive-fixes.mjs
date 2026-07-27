export const id = "false-positive-fixes";
// Transient "shipped fix" rule — safe for prune-diff-rules.yml to remove once
// it matches against prod (prod serves the fix, the captures are just stale).
export const prunable = true;
export const reason =
  "PR #46 fixed four false positives, which rolled out to prod during 2026-06-15. Captures first seen before FIX_CUTOFF (2026-06-16T00:00:00Z, a conservative end-of-rollout-day bound) still carry those findings, so replaying them against the fixed worker drops/rewrites them. This rule suppresses a diff only when (a) the capture predates FIX_CUTOFF and (b) every moving diagnostic is one of those specific fixes — matched on exact message where possible. Self-expiring: once the pre-fix captures roll out of the 30-day window it matches nothing, and any capture at/after FIX_CUTOFF (a real regression) is never suppressed.";

// Conservative rollout bound: the end of the 2026-06-15 ship day. Captures
// first seen before FIX_CUTOFF are pre-fix; at/after it prod already served the
// fixed worker, so a diff on these rules would be a real regression — never
// suppressed.
const FIX_CUTOFF = Date.parse("2026-06-16T00:00:00Z");

function capturedBeforeFix(capture) {
  const t = Date.parse(capture?.first_seen ?? capture?.uploaded ?? "");
  // Unknown / unparseable timestamp → treat as recent (do not suppress).
  return !Number.isNaN(t) && t < FIX_CUTOFF;
}

// A moving diagnostic is attributable to PR #46 only if it is the exact finding
// that PR removed/changed. `unknown-context-or-function` is matched by rule
// alone because the hyphenated-id fix rewrites arbitrary context names (the
// previously-split fragments, plus the whole-id finding it now surfaces); the
// capture-time gate is what bounds it.
function isFixArtifact(x) {
  switch (x.rule) {
    case "invalid-mapping-values":
      return x.message === "workflow: `concurrency` must be a mapping (got string)";
    case "unknown-runner-label":
      return x.message.includes("`ubuntu-slim`");
    case "github-app-limit-permissions":
      return x.message.includes("missing `permissions:` scope");
    case "unknown-context-or-function":
      return true;
    default:
      return false;
  }
}

export function matches(capture, _replayed, diff) {
  if (!capturedBeforeFix(capture)) return false;
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;
    if (!d.onlyInCaptured.every(isFixArtifact)) return false;
    if (!d.onlyInReplayed.every(isFixArtifact)) return false;
  }
  return true;
}
