// PR #115 (issue #111) refreshed several hardcoded GitHub Actions spec
// tables. This masks the resulting prod-vs-capture diffs: values newly
// recognized stop being flagged, values newly retired start being flagged.
export const id = "github-spec-freshness";
export const prunable = true;
export const reason =
  "PR #115 (issue #111) refreshes hardcoded GitHub Actions spec tables. Newly-recognized values (permission scopes artifact-metadata/code-quality/copilot-requests/vulnerability-alerts; runner labels ubuntu-26.04(-arm)/windows-2025-vs2026/windows-11-vs2026-arm/the macos-26 family/xcode-27(-xlarge); webhook event image_version; job/step keys snapshot/background/wait/wait-all/cancel/parallel; the `$/` uses: syntax) stop being flagged, and newly-retired values (permission scopes repository-projects/models; runner labels ubuntu-20.04/windows-2019/macos-12/macos-13; webhook events project/project_card/project_column) start being flagged.";

const ADDED_PERM_SCOPES = [
  "artifact-metadata",
  "code-quality",
  "copilot-requests",
  "vulnerability-alerts",
];
const REMOVED_PERM_SCOPES = ["repository-projects", "models"];

const ADDED_RUNNER_LABELS = [
  "ubuntu-26.04",
  "ubuntu-26.04-arm",
  "windows-2025-vs2026",
  "windows-11-vs2026-arm",
  "macos-26",
  "macos-15-intel",
  "macos-26-intel",
  "macos-26-large",
  "macos-26-xlarge",
  "xcode-27",
  "xcode-27-xlarge",
];
const REMOVED_RUNNER_LABELS = ["ubuntu-20.04", "windows-2019", "macos-12", "macos-13"];

const ADDED_EVENTS = ["image_version"];
const REMOVED_EVENTS = ["project", "project_card", "project_column"];

const ADDED_KEYS = ["snapshot", "background", "wait", "wait-all", "cancel", "parallel"];

// A finding that used to fire and no longer does: one of the values this PR
// taught the tables about.
function isNewlySilent(finding) {
  const message = finding?.message ?? "";
  switch (finding?.rule) {
    case "permissions-syntax":
      return ADDED_PERM_SCOPES.some((s) => message.includes(`unknown permission scope \`${s}\``));
    case "unknown-runner-label":
      return ADDED_RUNNER_LABELS.some((l) => message.includes(`unknown runner label \`${l}\``));
    case "webhook-events":
      return ADDED_EVENTS.some((e) => message.includes(`unknown webhook event \`${e}\``));
    case "unexpected-keys":
      return ADDED_KEYS.some((k) => message.includes(`unknown key \`${k}\``));
    case "uses-syntax":
      // `uses: $/path` no longer misreported as missing `@ref`.
      return /uses `\$\//.test(message);
    default:
      return false;
  }
}

// A finding that didn't fire before and now does: one of the values this PR
// retired from the tables.
function isNewlyFlagged(finding) {
  const message = finding?.message ?? "";
  switch (finding?.rule) {
    case "permissions-syntax":
      return REMOVED_PERM_SCOPES.some((s) => message.includes(`unknown permission scope \`${s}\``));
    case "unknown-runner-label":
      return REMOVED_RUNNER_LABELS.some((l) => message.includes(`unknown runner label \`${l}\``));
    case "webhook-events":
      return REMOVED_EVENTS.some((e) => message.includes(`unknown webhook event \`${e}\``));
    default:
      return false;
  }
}

export function matches(_capture, _replayed, diff) {
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;
    if (!(d.onlyInCaptured ?? []).every(isNewlySilent)) return false;
    if (!(d.onlyInReplayed ?? []).every(isNewlyFlagged)) return false;
  }
  return true;
}
