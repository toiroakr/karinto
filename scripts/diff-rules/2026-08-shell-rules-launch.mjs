// PR #116 (issue #113) shipped tree-sitter-bash shell script analysis,
// including two brand-new karinto-original rules: `shell-quote-safety`
// (unquoted expansion of a `${{ }}`-derived env var) and
// `shell-undefined-var` (a shell variable reference with no declared `env:`
// source). Neither rule existed before PR #116 shipped, so every capture
// taken before then is missing whatever these rules now find on replay —
// this masks that one-directional "newly appears" drift until the affected
// captures age out.
export const id = "shell-rules-launch";
export const prunable = true;
export const reason =
  "PR #116 (issue #113) adds the shell-quote-safety and shell-undefined-var rules, which did not exist when older captures were taken. Replaying those captures against current code surfaces new shell-quote-safety/shell-undefined-var findings that simply were not possible at capture time — an addition, not a regression.";

const NEW_RULES = new Set(["shell-quote-safety", "shell-undefined-var"]);

export function matches(_capture, _replayed, diff) {
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;
    // Captures predate the rules, so nothing should ever disappear because
    // of them — only new findings appearing on replay is expected.
    if ((d.onlyInCaptured ?? []).length > 0) return false;
    if (!(d.onlyInReplayed ?? []).every((f) => NEW_RULES.has(f?.rule))) return false;
  }
  return true;
}
