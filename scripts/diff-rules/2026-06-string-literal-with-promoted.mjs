import { matches as promotedMatches } from "./2026-05-promote-zizmor-planned-rules.mjs";

export const id = "string-literal-fix-with-promoted-rule";
export const reason =
  "Composite of two already-merged-but-unshipped behaviours colliding on a single capture: PR #55's single-quoted-string-literal fix (drops the spurious `unknown context` finding whose head is a string literal like 'replay-summary.md') and PR #14's zizmor rule promotion (adds findings such as `cache-poisoning`). Each is individually covered by its own rule (`unknown-context-string-literal-fix`, `promote-zizmor-planned-rules`), but those rules each require *every* moving diagnostic to fall in their own category, so a capture that simultaneously loses a string-literal artifact *and* gains a promoted finding is matched by neither. This rule suppresses exactly that intersection: the removed side may contain string-literal context artifacts, and once those are set aside the residual movement must be fully explained by the promote-zizmor rule (delegated, so its `promoted` set stays the single source of truth). A genuine regression — a removed finding that is neither a string-literal artifact nor promoted, or an added finding outside the promoted set — is still surfaced. Self-expiring: delete alongside its two parent rules once #55/#14 have shipped and prod captures roll over (~30 days post-release).";

function isStringLiteralContextArtifact(x) {
  return (
    x.rule === "unknown-context-or-function" &&
    x.message.startsWith("unknown context `")
  );
}

export function matches(capture, replayed, diff) {
  // Only fire on the genuine intersection — a single diagnostics entry that
  // both drops a string-literal artifact and moves a promoted finding. Pure
  // string-literal or pure promoted diffs are left to their single-purpose
  // rules (suppression only needs one rule to match).
  let sawComposite = false;
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;
    const removedArtifacts = d.onlyInCaptured.filter(
      isStringLiteralContextArtifact,
    );
    const removedRest = d.onlyInCaptured.filter(
      (x) => !isStringLiteralContextArtifact(x),
    );
    if (
      removedArtifacts.length > 0 &&
      (removedRest.length > 0 || d.onlyInReplayed.length > 0)
    ) {
      sawComposite = true;
    }
    // Whatever is left after removing the string-literal artifacts must be
    // fully attributable to the promote-zizmor rule set.
    const residual = { ...d, onlyInCaptured: removedRest };
    if (!promotedMatches(capture, replayed, [residual])) return false;
  }
  return sawComposite;
}
