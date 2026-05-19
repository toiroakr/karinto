#!/usr/bin/env node
// Weekly upstream-fixture refresh. Queries GitHub for the latest release tag
// of each pinned upstream, and when newer than what mise.toml has, bumps
// mise.toml + re-vendors the matching testdata subdir into
// fixtures/upstream/<name>/.
//
// Emits a JSON summary on stdout (consumed by upstream-refresh.yml to
// compose the PR body). Filesystem changes are left for the workflow to
// commit via peter-evans/create-pull-request.
//
// Requires: `gh` CLI authenticated (env: GH_TOKEN or interactive),
//           `git` on PATH.

import { existsSync, readFileSync, writeFileSync, mkdirSync, rmSync, readdirSync, cpSync } from "node:fs";
import { resolve, join, dirname } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..", "..");

// Each `vendor` entry copies <repo>/<from> → fixtures/upstream/<name>/<to>.
// Keep destination paths flat ("tests", "testdata", "pkg") regardless of where
// fixtures live in the upstream repo.
const TOOLS = [
  {
    name: "actionlint",
    miseKey: "aqua:rhysd/actionlint",
    repo: "rhysd/actionlint",
    vendor: [{ from: "testdata", to: "testdata" }],
  },
  {
    name: "zizmor",
    miseKey: "ubi:zizmorcore/zizmor",
    repo: "zizmorcore/zizmor",
    // zizmor's snapshot/integration fixtures live under the workspace crate.
    vendor: [{ from: "crates/zizmor/tests", to: "tests" }],
  },
  {
    name: "ghalint",
    miseKey: "aqua:suzuki-shunsuke/ghalint",
    repo: "suzuki-shunsuke/ghalint",
    // ghalint scatters per-policy testdata under pkg/policy/; vendor the
    // whole pkg/ tree and let the comparison engine pick up .yml files.
    vendor: [{ from: "pkg", to: "pkg" }],
  },
];

const misePath = resolve(REPO_ROOT, "mise.toml");
const fixturesRoot = resolve(REPO_ROOT, "fixtures/upstream");

if (!existsSync(misePath)) die(`mise.toml not found at ${misePath}`);

const miseSrc = readFileSync(misePath, "utf8");
const currentVersions = parseMiseVersions(miseSrc);

const updates = [];
let newMise = miseSrc;

for (const tool of TOOLS) {
  const cur = currentVersions.get(tool.miseKey);
  if (!cur) {
    console.error(`warn: ${tool.miseKey} not pinned in mise.toml — skipping`);
    continue;
  }
  // Bootstrap: if fixtures for this tool are absent or empty, vendor at the
  // currently pinned version regardless of upstream movement. This lets the
  // first run on a fresh checkout populate fixtures without waiting for an
  // upstream release.
  const dst = join(fixturesRoot, tool.name);
  const needsBootstrap = !existsSync(dst) || readdirSync(dst).length === 0;
  if (needsBootstrap) {
    const tag = `v${cur}`;
    console.error(`bootstrap: ${tool.name} ${cur}`);
    vendor(tool, tag);
    updates.push({
      name: tool.name,
      repo: tool.repo,
      from: cur,
      to: cur,
      tag,
      url: `https://github.com/${tool.repo}/releases/tag/${tag}`,
      bootstrap: true,
    });
    continue;
  }
  const latest = fetchLatestRelease(tool.repo);
  if (!latest) {
    console.error(`warn: failed to fetch latest release for ${tool.repo} — skipping`);
    continue;
  }
  const latestVer = stripV(latest.tag_name);
  if (!semverGt(latestVer, cur)) {
    console.error(`up-to-date: ${tool.name} ${cur}`);
    continue;
  }
  console.error(`bumping: ${tool.name} ${cur} -> ${latestVer}`);
  newMise = bumpMiseVersion(newMise, tool.miseKey, cur, latestVer);
  vendor(tool, latest.tag_name);
  updates.push({
    name: tool.name,
    repo: tool.repo,
    from: cur,
    to: latestVer,
    tag: latest.tag_name,
    url: latest.html_url ?? `https://github.com/${tool.repo}/releases/tag/${latest.tag_name}`,
  });
}

if (updates.length > 0) {
  writeFileSync(misePath, newMise);
}

const summary = { changed: updates.length > 0, updates };
process.stdout.write(JSON.stringify(summary, null, 2) + "\n");

// ---------------------------------------------------------------------------

function parseMiseVersions(src) {
  // Match lines like:  "aqua:rhysd/actionlint" = "1.7.12"
  const out = new Map();
  const re = /^\s*"([^"]+)"\s*=\s*"([^"]+)"\s*$/gm;
  let m;
  while ((m = re.exec(src))) out.set(m[1], m[2]);
  return out;
}

function bumpMiseVersion(src, key, from, to) {
  const re = new RegExp(
    `(^\\s*"${escapeRe(key)}"\\s*=\\s*")${escapeRe(from)}("\\s*$)`,
    "m",
  );
  if (!re.test(src)) die(`failed to locate "${key}" = "${from}" in mise.toml`);
  return src.replace(re, `$1${to}$2`);
}

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function stripV(tag) {
  return tag.replace(/^v/, "");
}

function semverGt(a, b) {
  const as = a.split(".").map((x) => parseInt(x, 10) || 0);
  const bs = b.split(".").map((x) => parseInt(x, 10) || 0);
  const n = Math.max(as.length, bs.length);
  for (let i = 0; i < n; i++) {
    const x = as[i] ?? 0;
    const y = bs[i] ?? 0;
    if (x > y) return true;
    if (x < y) return false;
  }
  return false;
}

function fetchLatestRelease(repo) {
  const r = spawnSync("gh", ["api", `repos/${repo}/releases/latest`], {
    encoding: "utf8",
  });
  if (r.status !== 0) {
    console.error(`gh api failed for ${repo}: ${r.stderr.trim()}`);
    return null;
  }
  try {
    return JSON.parse(r.stdout);
  } catch (err) {
    console.error(`gh api returned non-JSON for ${repo}: ${err.message}`);
    return null;
  }
}

function vendor(tool, tag) {
  const dst = join(fixturesRoot, tool.name);
  const tmp = join(tmpdir(), `karinto-upstream-${tool.name}-${process.pid}`);
  // Clean any prior aborted run.
  rmSync(tmp, { recursive: true, force: true });
  // Shallow-clone the exact tag, no blobs we don't need.
  const cloneUrl = `https://github.com/${tool.repo}.git`;
  const clone = spawnSync(
    "git",
    ["clone", "--depth", "1", "--branch", tag, cloneUrl, tmp],
    { stdio: "inherit" },
  );
  if (clone.status !== 0) die(`git clone ${tool.repo}@${tag} failed`);

  // Replace dst entirely with the vendored subdirs.
  rmSync(dst, { recursive: true, force: true });
  mkdirSync(dst, { recursive: true });
  let copied = 0;
  const summary = [];
  for (const entry of tool.vendor) {
    const fromAbs = join(tmp, entry.from);
    if (!existsSync(fromAbs)) {
      console.error(`warn: ${tool.repo}@${tag} has no ${entry.from}/; skipping that subdir`);
      continue;
    }
    cpSync(fromAbs, join(dst, entry.to), { recursive: true });
    copied++;
    summary.push(entry.from === entry.to ? entry.from : `${entry.from} -> ${entry.to}`);
  }
  if (copied === 0) {
    // No content vendored; leave dst empty so the bootstrap check retries.
    rmSync(dst, { recursive: true, force: true });
    rmSync(tmp, { recursive: true, force: true });
    die(`vendor: ${tool.repo}@${tag} produced no fixtures`);
  }
  // Drop a small marker so the vendored copy carries the tag in the diff.
  writeFileSync(
    join(dst, "UPSTREAM.txt"),
    `${tool.repo}@${tag}\nvendored: ${summary.join(", ")}\n`,
  );
  rmSync(tmp, { recursive: true, force: true });
}

function die(msg) {
  console.error(`refresh: ${msg}`);
  process.exit(2);
}
