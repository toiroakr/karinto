// shell-undefined-var stops flagging positional parameters (`$0`, `$1`,
// `${10}`, …): tree-sitter-bash parses them as an all-digit `variable_name`,
// so a shell function reading its own arguments was reported as having no
// declared `env:` source. Older captures still carry those findings; replaying
// them against the fixed worker drops them and adds nothing.
export const id = "shell-undefined-var-positional-params";
export const prunable = true;
export const reason =
  "shell-undefined-var no longer flags positional parameters (`$0`, `$1`, `${10}`, …), which no `env:` key could supply. Older captures of `run:` scripts reading `$1`-style arguments still carry the pre-fix findings; replaying them against the fixed worker removes those findings and adds none.";

function isNewlySilent(finding) {
  return (
    finding?.rule === "shell-undefined-var" &&
    /^`\$\d+` has no declared `env:` source/.test(finding?.message ?? "")
  );
}

export function matches(_capture, _replayed, diff) {
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;
    if ((d.onlyInReplayed ?? []).length > 0) return false;
    if (!(d.onlyInCaptured ?? []).every(isNewlySilent)) return false;
  }
  return true;
}
