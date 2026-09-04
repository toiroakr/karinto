// PR #135 (zizmor 1.30.0 parity refresh) shipped a brand-new karinto rule,
// `self-repository`: flags a `uses:` value starting with `./` and recommends
// GitHub's `$/...` self-repository syntax instead. The rule didn't exist
// before PR #135 shipped, so every capture taken before then is missing
// whatever it now finds on replay — a one-directional "newly appears" drift,
// same shape as 2026-08-shell-rules-launch.mjs for the shell rules. Some of
// those older captures also trip shell-rules-launch's own new findings in the
// same diagnostics diff, so this rule accepts either new-rule family
// together rather than only `self-repository` alone.
export const id = "self-repository-launch";
export const prunable = true;
export const reason =
  "PR #135 adds the self-repository rule (zizmor 1.30.0 parity), which did not exist when older captures were taken. Replaying those captures against current code surfaces new self-repository findings — sometimes alongside shell-quote-safety/shell-undefined-var findings from the same pre-PR#116 captures — that simply were not possible at capture time: an addition, not a regression.";

const SHELL_RULES_LAUNCH_RULES = new Set(["shell-quote-safety", "shell-undefined-var"]);
const NEW_RULES = new Set(["self-repository", ...SHELL_RULES_LAUNCH_RULES]);

export function matches(_capture, _replayed, diff) {
  // A diff made up entirely of shell-rules-launch findings, with no
  // self-repository finding at all, is that sibling rule's own territory —
  // matching it here too would credit two rules for one diff (see the
  // "one-file-per-rule independence" note in
  // 2026-08-shell-rules-spec-freshness-overlap.mjs for why that matters to
  // rebaseline-captures.mjs's attribution). Require at least one
  // self-repository finding so this rule only covers what's actually new.
  let sawSelfRepository = false;
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;
    // Captures predate the rule, so nothing should ever disappear because of
    // it — only new findings appearing on replay is expected.
    if ((d.onlyInCaptured ?? []).length > 0) return false;
    const replayed = d.onlyInReplayed ?? [];
    if (replayed.some((f) => f?.rule === "self-repository")) sawSelfRepository = true;
    if (!replayed.every((f) => NEW_RULES.has(f?.rule))) return false;
  }
  return sawSelfRepository;
}
