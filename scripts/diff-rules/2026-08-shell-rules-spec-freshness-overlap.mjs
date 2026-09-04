// A handful of captures predate BOTH transient drifts covered by the two
// sibling rules below, and their diff mixes findings from each:
//   - 2026-08-github-spec-freshness.mjs (PR #115, issue #111): a
//     permissions-syntax finding for a since-recognized scope (e.g.
//     `copilot-requests`), or a `uses-syntax` finding for the `$/...`
//     self-repository form, disappears on replay.
//   - 2026-08-shell-rules-launch.mjs (PR #116, issue #113): new
//     shell-quote-safety / shell-undefined-var findings appear on replay.
// `matchRules` (scripts/lib/replay-diff.mjs) requires a single rule to
// explain a whole diff, so a diff whose `onlyInCaptured` side is explained by
// one sibling rule and whose `onlyInReplayed` side is explained by the other
// matches neither individually. This rule covers exactly that overlap. The
// captured-side checks mirror 2026-08-github-spec-freshness.mjs's own
// `isNewlySilent` cases for `permissions-syntax` and `uses-syntax` —
// duplicated rather than imported, per this directory's one-file-per-rule
// independence. In practice the `uses-syntax` case dominates: most PR #115
// captures were silenced there, not on a newly-recognized permission scope.
export const id = "shell-rules-spec-freshness-overlap";
export const prunable = true;
export const reason =
  "A few captures predate both PR #115's GitHub Actions spec table refresh (issue #111) and PR #116's shell-quote-safety/shell-undefined-var rules (issue #113). Their diff combines a permissions-syntax or uses-syntax ($/... self-repository form) finding disappearing with new shell-undefined-var/shell-quote-safety findings appearing in the same diagnostics diff — neither 2026-08-github-spec-freshness.mjs nor 2026-08-shell-rules-launch.mjs alone can explain a diff split across both causes. (Originally this rule only recognized the permissions-syntax case, which meant it silently failed to match the far more common uses-syntax overlap — see PR #139's CI investigation.)";

const NEWLY_RECOGNIZED_PERM_SCOPES = [
  "artifact-metadata",
  "code-quality",
  "copilot-requests",
  "vulnerability-alerts",
];
const NEW_SHELL_RULES = new Set(["shell-quote-safety", "shell-undefined-var"]);

function isNewlySilencedBySpecFreshness(finding) {
  const message = finding?.message ?? "";
  if (finding?.rule === "permissions-syntax") {
    return NEWLY_RECOGNIZED_PERM_SCOPES.some((s) => message.includes(`unknown permission scope \`${s}\``));
  }
  if (finding?.rule === "uses-syntax") {
    // `uses: $/path` no longer misreported as missing `@ref`.
    return /uses `\$\//.test(message);
  }
  return false;
}

export function matches(_capture, _replayed, diff) {
  // A diff missing either side entirely is plain single-cause drift, not an
  // overlap: no `onlyInCaptured` is shell-rules-launch's own territory, and
  // no `onlyInReplayed` is github-spec-freshness's. Requiring at least one
  // entry on *both* sides keeps this rule's matches limited to genuine
  // overlaps, so rebaseline-captures.mjs's per-diff rule attribution stays
  // accurate instead of crediting two rules for one diff.
  let sawCapturedSide = false;
  let sawReplayedSide = false;
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;
    const captured = d.onlyInCaptured ?? [];
    const replayed = d.onlyInReplayed ?? [];
    if (captured.length > 0) sawCapturedSide = true;
    if (replayed.length > 0) sawReplayedSide = true;
    if (!captured.every(isNewlySilencedBySpecFreshness)) return false;
    if (!replayed.every((f) => NEW_SHELL_RULES.has(f?.rule))) return false;
  }
  return sawCapturedSide && sawReplayedSide;
}
