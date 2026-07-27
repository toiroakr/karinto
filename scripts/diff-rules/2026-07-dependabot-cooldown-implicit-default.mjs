export const id = "dependabot-cooldown-implicit-default";
// Transient "shipped fix" rule — safe for prune-diff-rules.yml to remove once
// it matches against prod (prod serves the new behaviour, the captures are
// just stale).
export const prunable = true;
export const reason =
  "This PR follows zizmor 1.28.0's dependabot-cooldown changes (upstream #2193, GitHub's new implicit three-day default cooldown). Three things move: (a) the \"missing cooldown configuration\" and \"no default-days configured\" messages collapse into the single \"insufficient implicit default-days (less than 7)\" wording upstream now uses, (b) the pedantic-only \"multi-ecosystem-group cooldowns do not batch updates correctly\" finding is gone — zizmor 1.28.0 reports nothing for a multi-ecosystem group that configures a sufficient cooldown, and karinto firing it was the hard divergence that failed upstream-parity on this PR, and (c) every remaining arm of the audit is promoted from info to warning, mirroring upstream, so the otherwise-unchanged \"insufficient default-days configured (less than 7)\" finding also moves. This rule suppresses a diff only when every moving diagnostic is a dependabot-cooldown finding on the expected side of that transition: on the captured side an info-severity finding carrying one of the three retired messages or the unchanged one, on the replayed side a warning-severity finding carrying the new implicit message or the unchanged one. Any other rule, an info-severity finding appearing, a warning-severity finding disappearing, or a dependabot-cooldown message outside this set is a real regression and is never suppressed. Self-expiring: delete once the change has shipped and prod captures roll over (~30 days post-release).";

// Wordings this PR retires. A capture predating the change can still carry
// any of them; none should ever appear on the replayed side.
const RETIRED_MESSAGES = new Set([
  "missing cooldown configuration",
  "no default-days configured",
  "multi-ecosystem-group cooldowns do not batch updates correctly",
]);

// The single wording that replaces the first two. The multi-ecosystem finding
// has no replacement — it simply disappears.
const NEW_MESSAGE = "insufficient implicit default-days (less than 7)";

// Text-wise untouched, but it moves too because of the info → warning bump,
// so it shows up on both sides of the diff.
const UNCHANGED_MESSAGE = "insufficient default-days configured (less than 7)";

function isCapturedSide(x) {
  return (
    x.rule === "dependabot-cooldown" &&
    x.severity === "info" &&
    (RETIRED_MESSAGES.has(x.message) || x.message === UNCHANGED_MESSAGE)
  );
}

function isReplayedSide(x) {
  return (
    x.rule === "dependabot-cooldown" &&
    x.severity === "warning" &&
    (x.message === NEW_MESSAGE || x.message === UNCHANGED_MESSAGE)
  );
}

export function matches(_capture, _replayed, diff) {
  let sawArtifact = false;
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;
    if (!d.onlyInCaptured.every(isCapturedSide)) return false;
    if (!d.onlyInReplayed.every(isReplayedSide)) return false;
    if (d.onlyInCaptured.length > 0 || d.onlyInReplayed.length > 0) {
      sawArtifact = true;
    }
  }
  return sawArtifact;
}
