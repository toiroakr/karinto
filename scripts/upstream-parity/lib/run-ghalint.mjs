// Runs `ghalint` on a fixture file and returns the set of policy IDs that
// fired. ghalint emits log-format=json on stderr with one JSON object per
// violation, including `rule_id` (e.g. "GHL-004") and `policy_name`
// (e.g. "deny_inherit_secrets"). We surface both since the karinto catalog
// references either form.

import { spawnSync } from "node:child_process";

export function lintFixture({ bin, file }) {
  // `ghalint run` lints by default but expects a workflow path. For action
  // files use `ghalint run-action`. We sniff filename heuristically.
  const sub = /action\.ya?ml$/i.test(file) ? "run-action" : "run";
  const r = spawnSync(bin, [sub, "--log-format=json", file], {
    encoding: "utf8",
  });
  // ghalint exits non-zero on findings; treat any status as parseable.
  const lines = (r.stderr || "").split(/\r?\n/).filter((l) => l.trim());
  const ids = new Set();
  for (const line of lines) {
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      continue;
    }
    if (obj.level !== "error" && obj.level !== "warn") continue;
    if (obj.rule_id) ids.add(String(obj.rule_id).toLowerCase());
    if (obj.policy_name) ids.add(obj.policy_name);
  }
  // If ghalint crashed (vs. found violations), surface the error.
  if (r.status !== 0 && ids.size === 0 && r.stderr.trim() !== "") {
    return {
      ok: false,
      error: `ghalint exited with status ${r.status}: ${r.stderr.trim().slice(0, 400)}`,
      ruleIds: [],
    };
  }
  return { ok: true, ruleIds: [...ids] };
}
