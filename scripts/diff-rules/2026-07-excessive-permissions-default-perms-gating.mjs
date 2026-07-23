export const id = "excessive-permissions-default-perms-gating";
export const reason =
  "This PR corrects excessive-permissions's persona gating for the \"default permissions used due to no permissions: block\" finding (workflow- and job-level) to match zizmor's actual conditions — Pedantic iff the workflow has a single job, every job declares its own permissions, or the workflow is reusable-only (on: lists only workflow_call); Regular otherwise — replacing the blanket workflow-always-Pedantic / job-always-Regular split shipped in c50ee67 (2026-06-17), which was itself only a partial fix (correct for single-job workflows, wrong for the general case). Prod captures first seen before FIX_CUTOFF (2026-08-01T00:00:00Z, a conservative post-rollout bound) still carry that partial-fix gating: multi-job non-reusable workflows show no workflow-level finding at persona=regular (the corrected worker now shows it — onlyInReplayed), and normal jobs in reusable-only workflows show a job-level finding at persona=regular (the corrected worker now hides it — onlyInCaptured). This rule suppresses a diff only when (a) the capture predates FIX_CUTOFF and (b) every moving diagnostic, in either direction, is exactly this finding (the workflow-level exact message, or the job-level \"job `<name>`: ...\" variant) — never any other rule, and never a diagnostic disappearing/appearing outside this exact text. Self-expiring: once these pre-fix captures roll out of the 30-day window it matches nothing, and any capture at/after FIX_CUTOFF (a real regression) is never suppressed.";

// Conservative post-rollout bound. Captures first seen before FIX_CUTOFF may
// still carry the pre-this-PR gating; at/after it prod should already serve
// the corrected worker, so a diff on this finding would be a real
// regression — never suppressed.
const FIX_CUTOFF = Date.parse("2026-08-01T00:00:00Z");

function capturedBeforeFix(capture) {
  const t = Date.parse(capture?.first_seen ?? capture?.uploaded ?? "");
  // Unknown / unparseable timestamp → treat as recent (do not suppress).
  return !Number.isNaN(t) && t < FIX_CUTOFF;
}

const JOB_LEVEL_RE =
  /^job `[^`]+`: default permissions used due to no permissions: block$/;

// Matches both the workflow-level (no job prefix) and job-level ("job
// `<name>`: ...") forms of the "default permissions used" finding — the only
// two shapes this PR's gating change can move in either direction.
function isDefaultPermsArtifact(x) {
  return (
    x.rule === "excessive-permissions" &&
    (x.message === "default permissions used due to no permissions: block" ||
      JOB_LEVEL_RE.test(x.message))
  );
}

export function matches(capture, _replayed, diff) {
  if (!capturedBeforeFix(capture)) return false;
  let sawArtifact = false;
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;
    if (!d.onlyInCaptured.every(isDefaultPermsArtifact)) return false;
    if (!d.onlyInReplayed.every(isDefaultPermsArtifact)) return false;
    if (d.onlyInCaptured.length > 0 || d.onlyInReplayed.length > 0) {
      sawArtifact = true;
    }
  }
  return sawArtifact;
}
