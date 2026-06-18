import { matches as stringLiteralMatches } from "./2026-06-unknown-context-string-literal.mjs";

export const id = "expression-syntax-stray-brace-fix";
export const reason =
  "PR #62 stops flagging a stray `}}` as an `expression-syntax` error: a literal `{{ }}` template (e.g. docker/metadata-action's `pattern={{version}}`) is not a GitHub expression, only an unterminated `${{` is. Prod still serves the pre-fix worker, so captures carry the spurious `expression syntax error: stray `}}`` finding; replaying against the fixed worker drops it. `onlyInReplayed` must be empty (the fix only deletes a false positive, never adds findings). Some captures lose the stray-`}}` finding alongside other already-merged-but-unshipped removals on the same response: PR #55's single-quoted-string-literal `unknown-context-or-function` artifacts, and the already-shipped `unknown runner label `ubuntu-slim`` drop (current prod and the PR worker agree it should not fire; only the older snapshot still carries it). Each existing single-purpose rule requires *every* moving diagnostic to be its own category, so a capture mixing the stray-`}}` removal with those is matched by none. This rule suppresses exactly that: it fires only when a stray-`}}` removal is present, sets it (and the ubuntu-slim runner-label drop) aside, and requires the residual to be fully explained by PR #55's string-literal fix (delegated, so that rule stays the source of truth). A genuine regression — any added finding, or a removed finding outside this set — is still surfaced. Self-expiring: delete once #62/#55 ship and prod captures roll over (~30 days post-release).";

function isStrayBrace(x) {
  return (
    x.rule === "expression-syntax" &&
    x.message === "expression syntax error: stray `}}`"
  );
}

function isUbuntuSlimRunnerLabel(x) {
  return (
    x.rule === "unknown-runner-label" &&
    x.message === "unknown runner label `ubuntu-slim`"
  );
}

export function matches(capture, replayed, diff) {
  let sawStray = false;
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;
    // The fix only removes a false positive; nothing new should appear.
    if (d.onlyInReplayed.length > 0) return false;
    if (d.onlyInCaptured.some(isStrayBrace)) sawStray = true;
    // After setting aside this PR's stray-`}}` removals and the already-shipped
    // ubuntu-slim runner-label drop, the residual must be fully attributable to
    // PR #55's string-literal fix.
    const residual = d.onlyInCaptured.filter(
      (x) => !isStrayBrace(x) && !isUbuntuSlimRunnerLabel(x),
    );
    if (
      !stringLiteralMatches(capture, replayed, [
        { ...d, onlyInCaptured: residual, onlyInReplayed: [] },
      ])
    ) {
      return false;
    }
  }
  return sawStray;
}
