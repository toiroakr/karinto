#!/usr/bin/env node
// Refresh the major-version alias Worker for the just-released version and
// prune stale per-patch pinned Workers. Invoked from
// `scripts/release-publish.sh` after the exact-version snapshot
// (`karinto-vX-Y-Z`) has been deployed and smoke-checked.
//
// Retention (see README "Versioning & pinning"):
//
//   keep = (latest patch within each major)
//        ∪ (top N versions by SemVer descending)
//        ∪ { just-released version }
//
// `karinto-vX` major aliases are deployed on every release whose version is
// the new top within its major, so users who pin to `karinto-v0` always hit
// the latest 0.Y.Z. Aliases are never auto-deleted — they represent the
// "track the current major" contract and outlive any particular patch.
//
// A version-pinned Worker is dropped from the keep set only after a strictly
// newer release in the same major has shipped (so the "latest patch within
// each major" still has a frozen pin to point at), which means pruning lags
// the deletion-as-API-break risk by at least one release per major.
//
// Run from `cf/` so `npx wrangler` picks up wrangler.jsonc, and so the
// alias smoke check can shell out to `bash smoke.sh`.
//
// Required env:
//   CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID — same scope as deploy.
//   RELEASE_VERSION — the X.Y.Z just deployed (no `v` prefix).
//
// Optional env:
//   PINNED_KEEP_RECENT — default 50. Top-N retention by SemVer descending.
//   The Cloudflare free tier caps at 100 Worker scripts; 50 leaves
//   comfortable headroom for prod/staging/maintenance + per-PR previews +
//   major aliases.
//   GITHUB_PUBLIC_READ_TOKEN — public-read PAT mirrored into the alias Worker
//   as a secret so whole-repo discovery authenticates its GitHub API calls.
//   Unset → the alias serves whole-repo mode anonymously (60 req/hour/IP).
//   REPO_MODE_ENABLED — truthy turns on repo mode on the alias Worker (the
//   GitHub-fetching `/owner/repo[/...]` endpoints). Unset/empty → off.
//
// Failure semantics: alias deploy/smoke failures exit non-zero (CI users
// pinned to `karinto-vX` would otherwise see a stale alias). Individual
// prune failures only warn — stale snapshots are an inventory concern,
// not a correctness one, and next release retries.

import { execFileSync } from "node:child_process";

const API = "https://api.cloudflare.com/client/v4";

const TOKEN = process.env.CLOUDFLARE_API_TOKEN;
const ACCOUNT = process.env.CLOUDFLARE_ACCOUNT_ID;
const VERSION = process.env.RELEASE_VERSION;
// `||` (not `??`): GitHub Actions exports `vars.PINNED_KEEP_RECENT` as the
// empty string when the repo variable is unset, which `??` would pass
// through and `Number("")` would convert to 0 — silently disabling the
// top-N retention. `||` treats "" as missing. `"0"` is still truthy as a
// string, so an explicit `PINNED_KEEP_RECENT=0` (keep only latest-per-major
// + release) is honored.
const KEEP_RECENT_RAW = process.env.PINNED_KEEP_RECENT || "50";

if (!TOKEN || !ACCOUNT) {
  fail("CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID are required");
}
const release = parseVersion(VERSION);
if (!release) {
  fail(`RELEASE_VERSION must be X.Y.Z (got ${JSON.stringify(VERSION)})`);
}
const KEEP_RECENT = Number(KEEP_RECENT_RAW);
if (!Number.isInteger(KEEP_RECENT) || KEEP_RECENT < 0) {
  fail(`PINNED_KEEP_RECENT must be a non-negative integer (got ${KEEP_RECENT_RAW})`);
}

function parseVersion(s) {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(s ?? "");
  if (!m) return null;
  return { major: +m[1], minor: +m[2], patch: +m[3], raw: s };
}

function cmpVersion(a, b) {
  if (a.major !== b.major) return a.major - b.major;
  if (a.minor !== b.minor) return a.minor - b.minor;
  return a.patch - b.patch;
}

function pinnedName(v) {
  return `karinto-v${v.major}-${v.minor}-${v.patch}`;
}

function aliasName(major) {
  return `karinto-v${major}`;
}

function aliasUrl(major) {
  return `https://${aliasName(major)}.toiroakr.workers.dev`;
}

async function listScripts() {
  // Free-tier accounts cap at 100 Workers, so one page suffices; bump
  // per_page defensively in case CF's default is smaller.
  const res = await fetch(
    `${API}/accounts/${ACCOUNT}/workers/scripts?per_page=100`,
    { headers: { authorization: `Bearer ${TOKEN}` } },
  );
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`list scripts: ${res.status} ${text}`);
  }
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    throw new Error(`list scripts: non-JSON response ${text.slice(0, 200)}`);
  }
  if (!data?.success) {
    throw new Error(`list scripts: ${JSON.stringify(data?.errors ?? data)}`);
  }
  return (data.result ?? []).map((s) => s.id);
}

async function deleteScript(name) {
  const res = await fetch(
    `${API}/accounts/${ACCOUNT}/workers/scripts/${encodeURIComponent(name)}?force=true`,
    { method: "DELETE", headers: { authorization: `Bearer ${TOKEN}` } },
  );
  if (!res.ok) {
    throw new Error(`delete ${name}: ${res.status} ${await res.text()}`);
  }
}

function fail(msg) {
  console.error(`manage-pinned-workers: ${msg}`);
  process.exit(1);
}

function shell(cmd, args) {
  execFileSync(cmd, args, { stdio: "inherit" });
}

// Mirror the optional GITHUB_PUBLIC_READ_TOKEN repo secret into a Worker as an
// encrypted secret so whole-repo discovery mode authenticates its GitHub
// contents-API calls (60 → 5000 req/hour/IP). No-op when the env var is unset.
// Piped via stdin so the value never lands in argv (`ps`).
function putGithubToken(targetArgs) {
  const token = process.env.GITHUB_PUBLIC_READ_TOKEN;
  if (!token) return;
  execFileSync(
    "npx",
    ["wrangler", "secret", "put", "GITHUB_PUBLIC_READ_TOKEN", ...targetArgs],
    { input: token, stdio: ["pipe", "inherit", "inherit"] },
  );
}

const scripts = await listScripts();
const versioned = [];
for (const name of scripts) {
  const m = /^karinto-v(\d+)-(\d+)-(\d+)$/.exec(name);
  if (!m) continue;
  versioned.push({
    major: +m[1],
    minor: +m[2],
    patch: +m[3],
    raw: `${m[1]}.${m[2]}.${m[3]}`,
    name,
  });
}

// Include the just-released version in the universe even if the listing
// hasn't propagated it yet — guards against API eventual consistency.
const universe = versioned.slice();
if (!universe.some((v) => cmpVersion(v, release) === 0)) {
  universe.push({ ...release, name: pinnedName(release) });
}
universe.sort((a, b) => cmpVersion(b, a));

const latestPerMajor = new Map();
for (const v of universe) {
  if (!latestPerMajor.has(v.major)) latestPerMajor.set(v.major, v);
}

const keep = new Set([pinnedName(release)]);
for (const v of latestPerMajor.values()) keep.add(v.name);
for (const v of universe.slice(0, KEEP_RECENT)) keep.add(v.name);

console.log(`Pinned-Worker inventory (release ${release.raw}):`);
console.log(`  existing versioned scripts: ${versioned.length}`);
console.log(`  retention: latest-per-major ∪ top ${KEEP_RECENT} ∪ {release}`);
console.log(`  keep: ${[...keep].sort().join(", ") || "(none)"}`);

const releaseMajorTop = latestPerMajor.get(release.major);
if (releaseMajorTop && cmpVersion(releaseMajorTop, release) === 0) {
  const alias = aliasName(release.major);
  console.log(`Deploying alias ${alias} -> ${release.raw}`);
  // Mirror release-publish.sh's repo-mode gate onto the alias (off by default).
  const repoModeFlag = ["--var", `REPO_MODE_ENABLED:${process.env.REPO_MODE_ENABLED || "false"}`];
  shell("npx", ["wrangler", "deploy", "--env=", "--name", alias, ...repoModeFlag]);
  putGithubToken(["--env=", "--name", alias]);
  shell("bash", ["smoke.sh", aliasUrl(release.major)]);
} else {
  console.log(
    `Skipping alias update for major ${release.major}: ${release.raw} is not the new top (top is ${releaseMajorTop?.raw}).`,
  );
}

const toDelete = versioned.filter((v) => !keep.has(v.name));
if (toDelete.length === 0) {
  console.log("No stale pinned Workers to prune.");
} else {
  console.log(
    `Pruning ${toDelete.length} stale Worker(s): ${toDelete.map((v) => v.name).join(", ")}`,
  );
  for (const v of toDelete) {
    try {
      await deleteScript(v.name);
      console.log(`  deleted ${v.name}`);
    } catch (e) {
      // Best-effort: a delete failure leaves a stale script around but
      // doesn't compromise the release itself, so warn and move on.
      console.warn(`  ! ${e?.message ?? e} (continuing)`);
    }
  }
}
