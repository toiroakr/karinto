// PR #147 (issue #146, GitHub spec freshness) teaches karinto about the
// `cache-mode` workflow/job key GitHub added. This masks the resulting
// prod-vs-capture diffs, same shape as 2026-08-github-spec-freshness.mjs:
// a document using `cache-mode:` with a valid value stops tripping
// unexpected-keys, and one with an out-of-enum value swaps that removed
// unexpected-keys finding for a newly-appearing invalid-mapping-values one
// (the key itself is accepted now, but the value is checked).
export const id = "cache-mode-key";
export const prunable = true;
export const reason =
  "PR #147 (issue #146) adds `cache-mode` to the workflow_top_keys/job_keys allowlists (unexpected-keys no longer flags `cache-mode:`) and teaches invalid-mapping-values to flag a `cache-mode:` value outside GitHub's read/write/write-only/none enum (previously silent, since the key itself was rejected first). Older captures of workflows using `cache-mode:` still carry the pre-fix findings; replaying them against the fixed worker changes those findings.";

// A finding that used to fire and no longer does: the key is now allowlisted.
function isNewlySilent(finding) {
  return (
    finding?.rule === "unexpected-keys" &&
    (finding?.message ?? "").includes("unknown key `cache-mode`")
  );
}

// A finding that didn't fire before and now does: an out-of-enum value,
// only checkable once the key itself stopped being rejected outright.
function isNewlyFlagged(finding) {
  return (
    finding?.rule === "invalid-mapping-values" &&
    (finding?.message ?? "").includes("`cache-mode` must be one of")
  );
}

export function matches(_capture, _replayed, diff) {
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;
    if (!(d.onlyInCaptured ?? []).every(isNewlySilent)) return false;
    if (!(d.onlyInReplayed ?? []).every(isNewlyFlagged)) return false;
  }
  return true;
}
