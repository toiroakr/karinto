// Runs `actionlint` on a fixture file. actionlint's JSON output uses a
// coarse `Kind` field (one of ~15 categories like "syntax-check",
// "expression", "events") that doesn't map 1:1 to karinto's per-rule
// origins — `actionlint:unexpected-keys` and `actionlint:duplicate-job-step-ids`
// both surface as Kind="syntax-check", for example.
//
// We therefore compare actionlint output at the **source-level aggregate**:
// "does actionlint flag this file" vs. "does at least one karinto rule with
// an actionlint origin flag the same file". Per-rule parity for actionlint
// would require a fragile message-regex table; left as future work.

import { spawnSync } from "node:child_process";

export function lintFixture({ bin, file }) {
  const r = spawnSync(bin, ["-format", "{{json .}}", "-no-color", file], {
    encoding: "utf8",
  });
  // actionlint exits 1 when it finds issues, 0 when clean, >1 on internal errors.
  if (r.status !== 0 && r.status !== 1) {
    return {
      ok: false,
      error: `actionlint exited with status ${r.status}: ${r.stderr.trim()}`,
      findings: [],
    };
  }
  const out = r.stdout.trim();
  if (!out) return { ok: true, findings: [] };
  let parsed;
  try {
    parsed = JSON.parse(out);
  } catch (err) {
    return {
      ok: false,
      error: `actionlint produced non-JSON: ${err.message}; stdout=${out.slice(0, 200)}`,
      findings: [],
    };
  }
  const findings = parsed.map((e) => ({
    kind: e.kind ?? null,
    message: e.message ?? "",
    line: e.line ?? null,
    col: e.column ?? null,
  }));
  return { ok: true, findings };
}
