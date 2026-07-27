export const id = "false-positive-fixes-batch2";
export const reason =
  "This PR fixes two false positives: `use-trusted-publishing`'s run-based detection no longer fires on pkg-pr-new invoked via pnpm dlx/yarn dlx/npm exec (not an npm registry publish), and `github-app-limit-repositories` no longer fires when a GitHub App token request omits both `owner:` and `repositories:` (ghalint's own ghl-009 doc treats that as compliant — token scoped to the current repository). Captures first seen before FIX_CUTOFF (2026-08-04T00:00:00Z, a conservative post-rollout bound) still carry those findings, so replaying them against the fixed worker drops them. This rule suppresses a diff only when (a) the capture predates FIX_CUTOFF and (b) every moving diagnostic is one of those two specific findings, or (c) — for a capture that also predates the still-active `excessive-permissions-default-perms-gating` rule's own FIX_CUTOFF — that rule's exact artifact (duplicated here, not imported, so each rule's expiry stays independent). Self-expiring: once the pre-fix captures roll out of the 30-day window it matches nothing, and any capture at/after FIX_CUTOFF (a real regression) is never suppressed.";

// Conservative post-rollout bound. Captures first seen before FIX_CUTOFF may
// still carry the pre-this-PR findings; at/after it prod should already serve
// the fixed worker, so a diff on these rules would be a real regression —
// never suppressed.
const FIX_CUTOFF = Date.parse("2026-08-04T00:00:00Z");

function capturedBeforeFix(capture) {
  const t = Date.parse(capture?.first_seen ?? capture?.uploaded ?? "");
  // Unknown / unparseable timestamp → treat as recent (do not suppress).
  return !Number.isNaN(t) && t < FIX_CUTOFF;
}

// Duplicated from 2026-07-excessive-permissions-default-perms-gating.mjs
// (still active independently): a capture old enough to carry this PR's
// pre-fix findings can, in the same request, also carry that other
// still-unexpired rule's artifact in the same "diagnostics" diff entry —
// computeDiff emits one entry per capture, not one per cause. Not imported,
// so this rule keeps working (and expires on its own schedule) after that
// file is eventually deleted.
const OLD_DEFAULT_PERMS_CUTOFF = Date.parse("2026-08-01T00:00:00Z");
const OLD_JOB_LEVEL_DEFAULT_PERMS_RE =
  /^job `[^`]+`: default permissions used due to no permissions: block$/;

function isOldDefaultPermsArtifact(capture, x) {
  const t = Date.parse(capture?.first_seen ?? capture?.uploaded ?? "");
  if (Number.isNaN(t) || t >= OLD_DEFAULT_PERMS_CUTOFF) return false;
  return (
    x.rule === "excessive-permissions" &&
    (x.message === "default permissions used due to no permissions: block" ||
      OLD_JOB_LEVEL_DEFAULT_PERMS_RE.test(x.message))
  );
}

// A moving diagnostic is attributable to this PR only if it is the exact
// finding one of the two fixes removes.
function isFixArtifact(x) {
  switch (x.rule) {
    case "use-trusted-publishing":
      return x.message === "publish command uses a long-lived token; prefer OIDC trusted publishing";
    case "github-app-limit-repositories":
      return x.message === "GitHub App token request is missing `repositories:` scope";
    default:
      return false;
  }
}

export function matches(capture, _replayed, diff) {
  if (!capturedBeforeFix(capture)) return false;
  let sawArtifact = false;
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;
    // This PR's two fixes only ever remove a finding (false positive dropped),
    // never add one — so isFixArtifact is only legitimate in onlyInCaptured.
    // Permitting it in onlyInReplayed too would mask a real regression where
    // the worker newly starts emitting one of these findings for an old
    // capture that never had it.
    if (
      !d.onlyInCaptured.every((x) => {
        if (isFixArtifact(x)) {
          sawArtifact = true;
          return true;
        }
        return isOldDefaultPermsArtifact(capture, x);
      })
    ) {
      return false;
    }
    // onlyInReplayed may only carry the other (genuinely bidirectional) rule's
    // artifact — never this PR's own fixes.
    if (!d.onlyInReplayed.every((x) => isOldDefaultPermsArtifact(capture, x))) {
      return false;
    }
  }
  return sawArtifact;
}
