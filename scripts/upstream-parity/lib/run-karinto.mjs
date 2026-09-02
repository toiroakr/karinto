// Runs karinto's lint engine on a fixture YAML via the JS bundle the Worker
// uses. Caller must have built it first with:
//   moon build --target js --release
// otherwise the dynamic import fails with a clear error.

import { readFileSync } from "node:fs";
import { ensureInitNode } from "../../../shell-ts-adapter/index.mjs";

let lintString = null;

async function loadLint(bundlePath) {
  if (lintString) return lintString;
  try {
    // The compiled bundle's `lint_string` runs tree-sitter-bash-backed shell
    // rules (github-env, unpinned-tools, use-trusted-publishing, shell-quote-
    // safety, shell-undefined-var, …) through `ts_parse_json`, which returns
    // `None` — silently, no error — until the Node tree-sitter runtime has
    // been initialized. Every other caller (the CLI, scripts/test-shell-
    // rules.mjs) awaits this first; missing it here made every shell-AST rule
    // a silent no-op in this parity check without ever failing loudly.
    await ensureInitNode();
    const mod = await import(bundlePath);
    lintString = mod.lint_string;
    if (typeof lintString !== "function") {
      throw new Error("lint_string export not found on the JS bundle");
    }
    return lintString;
  } catch (err) {
    throw new Error(
      `Failed to import karinto JS bundle at ${bundlePath} — run \`moon build --target js --release\` first. (${err.message})`,
    );
  }
}

export async function lintFixture({ bundlePath, file }) {
  const lint = await loadLint(bundlePath);
  const content = readFileSync(file, "utf8");
  // lint_string signature: (content, kind_str, disable_str, vuln_uses_str).
  // Pass "" for kind to let karinto auto-detect from YAML structure, mirroring
  // the Worker's behaviour when no `kind` query param is supplied.
  let raw;
  try {
    raw = lint(content, "", "", "");
  } catch (err) {
    return { ok: false, error: `lint_string threw: ${err.message}`, ruleIds: [] };
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    return {
      ok: false,
      error: `lint_string returned non-JSON: ${err.message}`,
      ruleIds: [],
    };
  }
  if (parsed.ok === false) {
    return { ok: false, error: parsed.error ?? "lint failed", ruleIds: [] };
  }
  const diags = parsed.result?.diagnostics ?? [];
  const ruleIds = new Set(diags.map((d) => d.rule));
  return { ok: true, ruleIds: [...ruleIds] };
}
