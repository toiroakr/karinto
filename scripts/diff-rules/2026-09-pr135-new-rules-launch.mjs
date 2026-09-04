// PR #135 (zizmor 1.30.0 parity refresh) shipped four brand-new
// karinto-original rules in one go: `self-repository` (uses `./...` instead
// of GitHub's `$/...` self-repository syntax), `adhoc-packages` (installs a
// package outside a lockfile), `typosquat-uses`, and `unsound-ternary`. None
// existed before PR #135 shipped, so every capture taken before then is
// missing whatever they now find on replay — a one-directional "newly
// appears" drift, same shape as 2026-08-shell-rules-launch.mjs for the shell
// rules. Some of those older captures also predate PR #116 and trip its own
// new findings in the same diagnostics diff, so this rule accepts either
// new-rule family together rather than only PR #135's rules alone.
export const id = "pr135-new-rules-launch";
export const prunable = true;
export const reason =
  "PR #135 adds the self-repository/adhoc-packages/typosquat-uses/unsound-ternary rules (zizmor 1.30.0 parity), none of which existed when older captures were taken. Replaying those captures against current code surfaces new findings from these rules — sometimes alongside shell-quote-safety/shell-undefined-var findings from the same pre-PR#116 captures — that simply were not possible at capture time: an addition, not a regression.";

const PR135_NEW_RULES = new Set(["self-repository", "adhoc-packages", "typosquat-uses", "unsound-ternary"]);
const SHELL_RULES_LAUNCH_RULES = new Set(["shell-quote-safety", "shell-undefined-var"]);
const NEW_RULES = new Set([...PR135_NEW_RULES, ...SHELL_RULES_LAUNCH_RULES]);

export function matches(_capture, _replayed, diff) {
  // A diff made up entirely of shell-rules-launch findings, with no PR #135
  // finding at all, is that sibling rule's own territory — matching it here
  // too would credit two rules for one diff (see the "one-file-per-rule
  // independence" note in 2026-08-shell-rules-spec-freshness-overlap.mjs for
  // why that matters to rebaseline-captures.mjs's attribution). Require at
  // least one PR #135 finding so this rule only covers what's actually new.
  let sawPr135Rule = false;
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;
    // Captures predate these rules, so nothing should ever disappear because
    // of them — only new findings appearing on replay is expected.
    if ((d.onlyInCaptured ?? []).length > 0) return false;
    const replayed = d.onlyInReplayed ?? [];
    if (replayed.some((f) => PR135_NEW_RULES.has(f?.rule))) sawPr135Rule = true;
    if (!replayed.every((f) => NEW_RULES.has(f?.rule))) return false;
  }
  return sawPr135Rule;
}
