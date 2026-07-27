export const id = "dependabot-cooldown-implicit-default";
// Transient "shipped fix" rule — safe for prune-diff-rules.yml to remove once
// it matches against prod (prod serves the new wording, the captures are just
// stale).
export const prunable = true;
export const reason =
  "This PR follows zizmor 1.28.0's dependabot-cooldown changes (upstream #2193, GitHub's new implicit three-day default cooldown). Two things move: (a) the \"missing cooldown configuration\" and \"no default-days configured\" messages collapse into the single \"insufficient implicit default-days (less than 7)\" wording upstream now uses, and (b) the pedantic-only \"multi-ecosystem-group cooldowns do not batch updates correctly\" finding is gone — zizmor 1.28.0 reports nothing for a multi-ecosystem group that configures a sufficient cooldown, and karinto firing it was the hard divergence that failed upstream-parity on this PR. This rule suppresses a diff only when every moving diagnostic, in either direction, is a dependabot-cooldown finding carrying one of those exact messages: on the captured side the two retired wordings plus the retired multi-ecosystem message, on the replayed side the new implicit wording. Any other rule, or a dependabot-cooldown message outside this set (e.g. the unchanged \"insufficient default-days configured (less than 7)\" appearing or disappearing), is a real regression and is never suppressed. Self-expiring: delete once the change has shipped and prod captures roll over (~30 days post-release).";

// Wordings this PR retires. A capture predating the change can still carry
// any of them; none of them should ever appear on the replayed side.
const RETIRED_MESSAGES = new Set([
  "missing cooldown configuration",
  "no default-days configured",
  "multi-ecosystem-group cooldowns do not batch updates correctly",
]);

// The single wording that replaces the first two. The multi-ecosystem finding
// has no replacement — it simply disappears.
const NEW_MESSAGE = "insufficient implicit default-days (less than 7)";

function isRetired(x) {
  return x.rule === "dependabot-cooldown" && RETIRED_MESSAGES.has(x.message);
}

function isNew(x) {
  return x.rule === "dependabot-cooldown" && x.message === NEW_MESSAGE;
}

export function matches(_capture, _replayed, diff) {
  let sawArtifact = false;
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;
    if (!d.onlyInCaptured.every(isRetired)) return false;
    if (!d.onlyInReplayed.every(isNew)) return false;
    if (d.onlyInCaptured.length > 0 || d.onlyInReplayed.length > 0) {
      sawArtifact = true;
    }
  }
  return sawArtifact;
}
