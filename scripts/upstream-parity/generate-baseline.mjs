#!/usr/bin/env node
// One-shot: generate baseline allowlist entries from the parity hard
// divergences. Each `file` plus its observed `missing`/`extra` tags is
// recorded so PR #13 lands green while regressions on NEW divergences
// (different file or different tag) still fail.
//
// Usage: node scripts/upstream-parity/generate-baseline.mjs
//
// Writes the merged result back to scripts/upstream-parity/allowlist.json.

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..", "..");
const ALLOWLIST = resolve(HERE, "allowlist.json");

function mise(bin) {
  const r = spawnSync("mise", ["which", bin], { encoding: "utf8" });
  if (r.status === 0) return r.stdout.trim();
  const r2 = spawnSync("which", [bin], { encoding: "utf8" });
  return r2.stdout.trim();
}

const args = [
  "scripts/upstream-parity/compare.mjs",
  "--actionlint", mise("actionlint"),
  "--zizmor", mise("zizmor"),
  "--ghalint", mise("ghalint"),
  "--summary-path", "/tmp/parity-baseline.md",
];
spawnSync("node", args, { cwd: REPO_ROOT, stdio: "inherit" });
const md = readFileSync("/tmp/parity-baseline.md", "utf8");

const sections = md.split(/^## /m).slice(1);
const newEntries = [];
for (const sec of sections) {
  const [head, ...rest] = sec.split("\n");
  const source = head.trim();
  const body = rest.join("\n");
  const hardSection = body.split("### Hard divergences")[1]?.split("<details>")[0] ?? "";
  for (const line of hardSection.split("\n")) {
    const m = line.match(/^- `([^`]+)` (.+)$/);
    if (!m) continue;
    const file = m[1];
    const rest = m[2];
    const tags = [];
    let missing = rest.match(/missing=\[([^\]]+)\]/);
    if (missing) for (const id of missing[1].split(",").map(s => s.trim())) tags.push(`missing:${id}`);
    let extra = rest.match(/extra=\[([^\]]+)\]/);
    if (extra) for (const id of extra[1].split(",").map(s => s.trim())) tags.push(`extra:${id}`);
    if (rest.includes("upstream-fired-karinto-silent")) tags.push("upstream-only");
    if (rest.includes("karinto-fired-upstream-silent")) tags.push("karinto-only");
    if (rest.includes("karinto-error=")) tags.push("ignore");
    if (rest.includes("upstream-error=")) tags.push("ignore");
    if (tags.length === 0) continue;
    newEntries.push({
      file,
      expect: tags,
      reason: `baseline: tracked at PR #13. Source=${source}. Remove this entry once karinto catches up.`,
    });
  }
}

const existing = JSON.parse(readFileSync(ALLOWLIST, "utf8"));
const byFile = new Map();
for (const e of existing.entries ?? []) byFile.set(e.file, e);
for (const e of newEntries) {
  const prior = byFile.get(e.file);
  if (prior) {
    const merged = new Set([...(prior.expect ?? []), ...e.expect]);
    prior.expect = [...merged];
    if (!prior.reason) prior.reason = e.reason;
  } else {
    byFile.set(e.file, e);
  }
}
existing.entries = [...byFile.values()].sort((a, b) => a.file.localeCompare(b.file));
writeFileSync(ALLOWLIST, JSON.stringify(existing, null, 2) + "\n");
console.log(`wrote ${existing.entries.length} entries to ${ALLOWLIST}`);
