// Runs `zizmor` on a fixture file and returns the set of audit IDs that
// fired. zizmor's SARIF output puts the audit name in `results[].ruleId`,
// which corresponds 1:1 to karinto's `zizmor:<audit>` origin strings.

import { spawnSync } from "node:child_process";

export function lintFixture({ bin, file }) {
  // --format sarif emits a single JSON document on stdout; --no-online-audits
  // keeps the run hermetic (no GitHub API calls). --pedantic surfaces every
  // persona — karinto does not model the Pedantic-vs-Default split and aims
  // to match zizmor's full coverage, so we always run pedantic.
  const r = spawnSync(
    bin,
    [
      "--format",
      "sarif",
      "--no-online-audits",
      "--pedantic",
      "--quiet",
      file,
    ],
    { encoding: "utf8" },
  );
  // zizmor exits 0 on no findings, 13 on findings, other non-zero on error.
  if (r.status !== 0 && r.status !== 13) {
    return {
      ok: false,
      error: `zizmor exited with status ${r.status}: ${r.stderr.trim()}`,
      ruleIds: [],
    };
  }
  const out = r.stdout.trim();
  if (!out) return { ok: true, ruleIds: [] };
  let parsed;
  try {
    parsed = JSON.parse(out);
  } catch (err) {
    return {
      ok: false,
      error: `zizmor produced non-JSON: ${err.message}; stdout=${out.slice(0, 200)}`,
      ruleIds: [],
    };
  }
  const ids = new Set();
  for (const run of parsed.runs ?? []) {
    for (const res of run.results ?? []) {
      if (!res.ruleId) continue;
      // SARIF emits `zizmor/<audit>` — strip the namespace so the id lines up
      // with karinto's `zizmor:<audit>` origin keys.
      const id = res.ruleId.startsWith("zizmor/") ? res.ruleId.slice("zizmor/".length) : res.ruleId;
      ids.add(id);
    }
  }
  return { ok: true, ruleIds: [...ids] };
}
