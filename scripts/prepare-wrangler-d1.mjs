#!/usr/bin/env node
// Render a deploy-ready `wrangler.deploy.jsonc` from the tracked
// `wrangler.jsonc`, injecting the D1 `database_id` at deploy time.
//
// The tracked config keeps the id as the literal placeholder
// `REPLACE_WITH_D1_DATABASE_ID` so no account-specific value is ever committed
// — same self-host stance as `CLOUDFLARE_ACCOUNT_ID` and the R2 bucket name
// (see DEVELOPMENT.md). At deploy time the real id comes from the
// `D1_DATABASE_ID` env var, which CI sources from the repo variable of the
// same name. A fork supplies its own id the same way.
//
// Two modes:
//   - `D1_DATABASE_ID` set   → substitute it into every d1_databases entry.
//   - `D1_DATABASE_ID` unset → strip the d1_databases bindings entirely, so a
//     deploy that hasn't provisioned D1 still succeeds. The Worker already
//     no-ops when `env.DB` is absent (cf/index.js guards every use), so the
//     archived-uses sweep simply stays dormant.
//
// Run from `cf/` (like the other deploy scripts) so it reads `wrangler.jsonc`
// and writes `wrangler.deploy.jsonc` alongside it. The output is gitignored
// and disposable — CI regenerates it each run; never commit it. Deploys then
// pass `--config wrangler.deploy.jsonc`.
import { readFileSync, writeFileSync } from "node:fs";

const SRC = "wrangler.jsonc";
const OUT = "wrangler.deploy.jsonc";
const PLACEHOLDER = "REPLACE_WITH_D1_DATABASE_ID";

const id = (process.env.D1_DATABASE_ID || "").trim();
const config = JSON.parse(jsoncToJson(readFileSync(SRC, "utf8")));

// d1_databases can appear at the top level (PR previews / pinned snapshots)
// and inside each named env (production, staging).
const blocks = [config, ...Object.values(config.env || {})];

if (id) {
  let injected = 0;
  for (const block of blocks) {
    for (const db of block.d1_databases || []) {
      if (db.database_id === PLACEHOLDER) {
        db.database_id = id;
        injected++;
      }
    }
  }
  console.log(
    `prepare-wrangler-d1: injected D1_DATABASE_ID into ${injected} binding(s) -> ${OUT}`,
  );
} else {
  for (const block of blocks) delete block.d1_databases;
  console.log(
    `prepare-wrangler-d1: D1_DATABASE_ID unset — ${OUT} deploys without a D1 binding`,
  );
}

writeFileSync(OUT, JSON.stringify(config, null, 2) + "\n");

// Convert JSONC to JSON: strip `//` and `/* */` comments and drop trailing
// commas (`,]`/`,}`), both of which `JSON.parse` rejects but wrangler's own
// parser accepts. Comments and commas inside string values are left intact via
// the `inStr` state. The output is a throwaway artifact, so losing the original
// comments/formatting is fine.
function jsoncToJson(s) {
  let out = "";
  let inStr = false;
  let inLine = false;
  let inBlock = false;
  let esc = false;
  // A structural comma is held until the next significant char: if that char
  // closes the container (`}`/`]`) the comma was trailing and is dropped;
  // otherwise the comma (plus any whitespace seen since) is emitted.
  let comma = false;
  let gap = "";
  const flushComma = (drop) => {
    if (!comma) return;
    if (!drop) out += ",";
    out += gap;
    comma = false;
    gap = "";
  };
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    const n = s[i + 1];
    if (inLine) {
      if (c === "\n") inLine = false;
      continue;
    }
    if (inBlock) {
      if (c === "*" && n === "/") {
        inBlock = false;
        i++;
      }
      continue;
    }
    if (inStr) {
      out += c;
      if (esc) esc = false;
      else if (c === "\\") esc = true;
      else if (c === '"') inStr = false;
      continue;
    }
    if (c === "/" && n === "/") {
      inLine = true;
      i++;
      continue;
    }
    if (c === "/" && n === "*") {
      inBlock = true;
      i++;
      continue;
    }
    if (c === '"') {
      flushComma(false);
      inStr = true;
      out += c;
      continue;
    }
    if (c === ",") {
      flushComma(false); // a preceding held comma is a real separator
      comma = true;
      continue;
    }
    if (c === " " || c === "\t" || c === "\n" || c === "\r") {
      if (comma) gap += c;
      else out += c;
      continue;
    }
    flushComma(c === "}" || c === "]");
    out += c;
  }
  flushComma(false);
  return out;
}
