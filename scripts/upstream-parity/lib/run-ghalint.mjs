// Runs `ghalint` on a fixture file and returns the set of policy names that
// fired. ghalint 1.5.x has two quirks the parity engine has to work around:
//
//   1. It emits human-readable logfmt on stderr (no JSON), with ANSI colours.
//      We strip ANSI then pull `policy_name=<token>` out of each line.
//   2. `ghalint run` does not accept file paths — it walks `.github/workflows/`
//      from the CWD. For workflow fixtures we stage the file into a temp
//      `.github/workflows/` and invoke ghalint there. Action fixtures use
//      `ghalint run-action <path>` which does accept file args.
//
// karinto's catalogue keys ghalint rules by `policy_name` (e.g.
// `deny_inherit_secrets`), matching the snake_case token ghalint logs.

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, copyFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";

const ANSI = /\x1B\[[0-9;]*[A-Za-z]/g;
const POLICY = /policy_name=([A-Za-z0-9_]+)/g;

export function lintFixture({ bin, file }) {
  const isAction = /action\.ya?ml$/i.test(file);
  let r;
  let cleanup = null;
  if (isAction) {
    r = spawnSync(bin, ["run-action", file], { encoding: "utf8" });
  } else {
    const stage = mkdtempSync(join(tmpdir(), "karinto-ghalint-"));
    mkdirSync(join(stage, ".github", "workflows"), { recursive: true });
    copyFileSync(file, join(stage, ".github", "workflows", basename(file)));
    r = spawnSync(bin, ["run"], { encoding: "utf8", cwd: stage });
    cleanup = () => rmSync(stage, { recursive: true, force: true });
  }
  const stderr = (r.stderr || "").replace(ANSI, "");
  const ids = new Set();
  for (const line of stderr.split(/\r?\n/)) {
    if (!line) continue;
    POLICY.lastIndex = 0;
    let m;
    while ((m = POLICY.exec(line)) !== null) {
      ids.add(m[1]);
    }
  }
  if (cleanup) cleanup();
  // ghalint exits non-zero only on real CLI errors (unknown flag, bad config).
  // Violations are surfaced via stderr but the process still exits 0.
  if (r.status !== 0 && ids.size === 0) {
    return {
      ok: false,
      error: `ghalint exited with status ${r.status}: ${stderr.trim().slice(0, 400)}`,
      ruleIds: [],
    };
  }
  return { ok: true, ruleIds: [...ids] };
}
