export const id = "unknown-context-string-literal-fix";
export const reason =
  "PR #55 fixes a false positive where single-quoted string literals containing a dot (e.g. hashFiles('replay-summary.md'), a bare 'a.b') were misread as `<head>.<member>` context access, so the literal's head (`replay-summary`, `a`, …) was reported as an `unknown context`. Prod still serves the pre-fix worker, so captures — regardless of capture date — still carry those spurious findings; replaying them against the fixed worker drops them. This rule suppresses a diff only when every moving diagnostic is an `unknown-context-or-function` finding that the PR *removed*: `onlyInReplayed` must be empty (the fix only deletes false positives, it never adds findings), and every removed diagnostic must be a context finding (message starts with \"unknown context `\"). A legitimate unknown context (e.g. a real `githab` typo) is unaffected by the literal fix and stays in both responses, so it never appears in the diff. No capture-date gate: unlike the PR #46 rule, this fix has not shipped yet, so even at/after-cutoff captures legitimately carry the bug. Delete once the fix has shipped and prod captures roll over (~30 days post-release).";

function isStringLiteralContextArtifact(x) {
  return (
    x.rule === "unknown-context-or-function" &&
    x.message.startsWith("unknown context `")
  );
}

export function matches(capture, _replayed, diff) {
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;
    // The fix only removes spurious findings; nothing new should appear.
    if (d.onlyInReplayed.length > 0) return false;
    if (!d.onlyInCaptured.every(isStringLiteralContextArtifact)) return false;
  }
  return true;
}
