#!/usr/bin/env node
// Compares karinto output to actionlint / zizmor / ghalint on the vendored
// upstream fixtures. Per-rule parity for zizmor + ghalint; source-level
// aggregate for actionlint (its `Kind` field is too coarse for per-rule —
// see lib/run-actionlint.mjs).
//
// Exit codes:
//   0  parity holds (or only allowlisted / Planned-rule divergences)
//   1  hard divergence found
//   2  configuration error (missing binary, build, etc.)
//
// Required env / args:
//   --bundle <path>          Path to the built worker.js
//   --actionlint <bin>       Path to actionlint binary
//   --zizmor <bin>           Path to zizmor binary
//   --ghalint <bin>          Path to ghalint binary
//   --catalog <path>         rules_catalog.mbt (default: ./rules_catalog.mbt)
//   --fixtures <path>        fixtures/upstream dir (default: ./fixtures/upstream)
//   --allowlist <path>       allowlist JSON (default: alongside this script)
//   --summary-path <path>    write markdown report (default: $GITHUB_STEP_SUMMARY)
//   --soft                   exit 0 even on hard divergences (for main-branch runs)

import { existsSync, readFileSync, readdirSync, statSync, writeFileSync, appendFileSync } from "node:fs";
import { resolve, relative, join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { loadCatalog } from "./lib/mapping.mjs";
import { lintFixture as lintKarinto } from "./lib/run-karinto.mjs";
import { lintFixture as lintActionlint } from "./lib/run-actionlint.mjs";
import { lintFixture as lintZizmor } from "./lib/run-zizmor.mjs";
import { lintFixture as lintGhalint } from "./lib/run-ghalint.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..", "..");

const args = parseArgs(process.argv.slice(2));
const bundle = args.bundle ?? resolve(REPO_ROOT, "_build/js/release/build/worker/worker.js");
const actionlintBin = args.actionlint ?? "actionlint";
const zizmorBin = args.zizmor ?? "zizmor";
const ghalintBin = args.ghalint ?? "ghalint";
const catalogPath = args.catalog ?? resolve(REPO_ROOT, "rules_catalog.mbt");
const fixturesRoot = args.fixtures ?? resolve(REPO_ROOT, "fixtures/upstream");
const allowlistPath = args.allowlist ?? resolve(HERE, "allowlist.json");
const summaryPath = args["summary-path"] ?? process.env.GITHUB_STEP_SUMMARY ?? null;
const soft = !!args.soft;

if (!existsSync(catalogPath)) die(2, `rules catalog not found: ${catalogPath}`);
if (!existsSync(bundle)) die(2, `karinto JS bundle not found: ${bundle} (build with \`moon build --target js --release\`)`);

const catalog = loadCatalog(catalogPath);
const allowlist = loadAllowlist(allowlistPath);

const reports = [];
let hardDivergences = 0;

for (const source of ["actionlint", "zizmor", "ghalint"]) {
  const dir = join(fixturesRoot, source);
  if (!existsSync(dir)) {
    reports.push({ source, status: "skipped", reason: `no fixtures vendored at ${relative(REPO_ROOT, dir)}` });
    continue;
  }
  const files = listYaml(dir);
  if (files.length === 0) {
    reports.push({ source, status: "skipped", reason: "no yaml files found" });
    continue;
  }
  reports.push(await runSource(source, files));
}

writeReport(reports);

if (hardDivergences > 0 && !soft) {
  console.error(`upstream-parity: ${hardDivergences} hard divergence(s)`);
  process.exit(1);
}
process.exit(0);

// ---------------------------------------------------------------------------

async function runSource(source, files) {
  const results = [];
  for (const file of files) {
    const rel = relative(REPO_ROOT, file);
    const karinto = await lintKarinto({ bundlePath: bundle, file });
    let upstream;
    switch (source) {
      case "actionlint":
        upstream = lintActionlint({ bin: actionlintBin, file });
        break;
      case "zizmor":
        upstream = lintZizmor({ bin: zizmorBin, file });
        break;
      case "ghalint":
        upstream = lintGhalint({ bin: ghalintBin, file });
        break;
    }
    const cmp = classify(source, rel, karinto, upstream);
    results.push({ file: rel, karinto, upstream, ...cmp });
    if (cmp.hard) hardDivergences++;
  }
  return { source, status: "ran", count: files.length, results };
}

function classify(source, file, karinto, upstream) {
  // Per-rule for zizmor + ghalint.
  if (source === "zizmor" || source === "ghalint") {
    const m = catalog.bySource[source];
    const upstreamHits = new Set(upstream.ok ? upstream.ruleIds : []);
    const karintoHits = new Set(karinto.ok ? karinto.ruleIds : []);

    // Rules with an origin in this source.
    const inSource = new Set();
    for (const [, entry] of m) inSource.add(entry.id);

    // Expected karinto IDs: upstream fired a rule that maps to a karinto
    // Implemented rule.
    const expected = new Set();
    const planned = new Set();
    const unmapped = new Set();
    for (const id of upstreamHits) {
      const hit = m.get(id);
      if (!hit) {
        unmapped.add(id);
        continue;
      }
      if (hit.status === "Implemented") expected.add(hit.id);
      else planned.add(`${hit.id} (${hit.status})`);
    }
    // Actual karinto IDs we count: only rules that have a this-source origin.
    const actual = new Set([...karintoHits].filter((id) => inSource.has(id)));

    const missing = [...expected].filter((id) => !actual.has(id)); // karinto should fire but didn't
    const extra = [...actual].filter((id) => !expected.has(id));   // karinto fired but upstream didn't

    const allow = allowlist.byFile.get(file);
    const filteredMissing = allow ? missing.filter((id) => !allow.has(`missing:${id}`)) : missing;
    const filteredExtra = allow ? extra.filter((id) => !allow.has(`extra:${id}`)) : extra;

    const hard = filteredMissing.length > 0 || filteredExtra.length > 0;
    return {
      hard,
      missing: filteredMissing,
      extra: filteredExtra,
      planned: [...planned],
      unmapped: [...unmapped],
      mode: "per-rule",
    };
  }

  // Aggregate for actionlint.
  const upstreamFired = upstream.ok && upstream.findings && upstream.findings.length > 0;
  const inSource = new Set();
  for (const [, entry] of catalog.bySource.actionlint) {
    if (entry.status === "Implemented") inSource.add(entry.id);
  }
  const karintoFired = karinto.ok && (karinto.ruleIds ?? []).some((id) => inSource.has(id));

  const allow = allowlist.byFile.get(file);
  const expectUpstreamOnly = allow?.has("upstream-only");
  const expectKarintoOnly = allow?.has("karinto-only");
  const ignore = allow?.has("ignore");

  let hard = false;
  let mismatch = null;
  if (ignore) {
    // allowlisted
  } else if (upstreamFired && !karintoFired && !expectUpstreamOnly) {
    hard = true;
    mismatch = "upstream-fired-karinto-silent";
  } else if (!upstreamFired && karintoFired && !expectKarintoOnly) {
    hard = true;
    mismatch = "karinto-fired-upstream-silent";
  }
  return {
    hard,
    mismatch,
    upstreamFindings: upstreamFired ? upstream.findings.length : 0,
    karintoRules: karinto.ok ? (karinto.ruleIds ?? []).filter((id) => inSource.has(id)) : [],
    mode: "aggregate",
  };
}

// ---------------------------------------------------------------------------

function listYaml(root) {
  const out = [];
  function walk(p) {
    let st;
    try { st = statSync(p); } catch { return; }
    if (st.isDirectory()) {
      for (const name of readdirSync(p)) walk(join(p, name));
    } else if (/\.(ya?ml)$/i.test(p)) {
      out.push(p);
    }
  }
  walk(root);
  out.sort();
  return out;
}

function loadAllowlist(path) {
  const byFile = new Map();
  if (!existsSync(path)) return { byFile };
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch (err) {
    die(2, `failed to parse allowlist at ${path}: ${err.message}`);
  }
  for (const entry of parsed.entries ?? []) {
    if (!entry.file) continue;
    const tags = new Set();
    for (const e of entry.expect ?? []) tags.add(e);
    byFile.set(entry.file, tags);
  }
  return { byFile };
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) {
      args[key] = true;
    } else {
      args[key] = next;
      i++;
    }
  }
  return args;
}

function die(code, msg) {
  console.error(`upstream-parity: ${msg}`);
  process.exit(code);
}

function writeReport(reports) {
  const md = renderMarkdown(reports);
  if (summaryPath) {
    try {
      appendFileSync(summaryPath, md + "\n");
    } catch (err) {
      writeFileSync(summaryPath, md + "\n");
    }
  }
  // Also print to stdout so the action log shows the same info.
  process.stdout.write(md + "\n");
}

function renderMarkdown(reports) {
  const lines = [];
  lines.push("# Upstream parity report");
  lines.push("");
  let totalFiles = 0;
  let totalHard = 0;
  for (const r of reports) {
    if (r.status !== "ran") continue;
    totalFiles += r.count;
    for (const x of r.results) if (x.hard) totalHard++;
  }
  lines.push(`- fixtures compared: **${totalFiles}**`);
  lines.push(`- hard divergences: **${totalHard}**`);
  lines.push("");

  for (const r of reports) {
    lines.push(`## ${r.source}`);
    if (r.status !== "ran") {
      lines.push(`_skipped_: ${r.reason}`);
      lines.push("");
      continue;
    }
    const hard = r.results.filter((x) => x.hard);
    const soft = r.results.filter(
      (x) => !x.hard && (x.missing?.length || x.extra?.length || x.planned?.length || x.unmapped?.length || x.mismatch),
    );
    lines.push(`- fixtures: ${r.count}`);
    lines.push(`- hard divergences: ${hard.length}`);
    lines.push("");
    if (hard.length) {
      lines.push("### Hard divergences");
      for (const h of hard) lines.push(renderRow(h));
      lines.push("");
    }
    if (soft.length) {
      lines.push("<details><summary>Soft divergences (informational)</summary>");
      lines.push("");
      for (const s of soft) lines.push(renderRow(s));
      lines.push("");
      lines.push("</details>");
      lines.push("");
    }
  }
  return lines.join("\n");
}

function renderRow(x) {
  const parts = [`- \`${x.file}\``];
  if (x.mode === "per-rule") {
    if (x.missing?.length) parts.push(`missing=[${x.missing.join(", ")}]`);
    if (x.extra?.length) parts.push(`extra=[${x.extra.join(", ")}]`);
    if (x.planned?.length) parts.push(`planned=[${x.planned.join(", ")}]`);
    if (x.unmapped?.length) parts.push(`unmapped=[${x.unmapped.join(", ")}]`);
  } else {
    if (x.mismatch) parts.push(x.mismatch);
    if (x.upstreamFindings) parts.push(`upstream=${x.upstreamFindings}`);
    if (x.karintoRules?.length) parts.push(`karinto=[${x.karintoRules.join(", ")}]`);
  }
  if (x.karinto && x.karinto.ok === false) parts.push(`karinto-error=${x.karinto.error}`);
  if (x.upstream && x.upstream.ok === false) parts.push(`upstream-error=${x.upstream.error}`);
  return parts.join(" — ");
}
