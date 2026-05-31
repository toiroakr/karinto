#!/usr/bin/env node
// Maintain the `archived-uses` baseline (KV key `archived:list`) from CI.
//
// The Worker can't do this itself: on the Workers Free plan a single
// invocation is capped at ~50 subrequests and unauthenticated GitHub calls
// share Cloudflare's egress IP (60 req/hour, effectively less). So instead the
// Worker just enqueues every external `uses:` repo it serves into the D1
// `pending` worklist, and this job — run from GitHub Actions, where the API
// budget is a full 5000 req/hour and there is no subrequest ceiling — does the
// actual verification:
//
//   1. read the current KV baseline + drain the D1 `pending` worklist,
//   2. confirm each repo's `archived` flag against the GitHub API
//      (re-checking the existing baseline too, so un-archives are caught),
//   3. write the updated baseline back to KV (only when it changed),
//   4. DELETE the resolved repos from `pending` — anything we couldn't reach
//      (rate-limit tail, transient error) stays queued for the next run and is
//      re-enqueued by traffic regardless.
//
// Run from `cf/` so the `wrangler --config wrangler.deploy.jsonc` calls pick up
// the rendered config (D1 id injected, KV binding). Required env:
//   CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID — D1 + KV write scope.
//   GH_TOKEN — GitHub token for the API (Actions `github.token` or a PAT).
import { execFileSync } from "node:child_process";
import { writeFileSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const CONFIG = "wrangler.deploy.jsonc";
const KV_KEY = "archived:list";
const DB_NAME = "karinto-archived";
const DRAIN_LIMIT = 1000; // pending rows verified per run
const DELETE_CHUNK = 50; // repos per DELETE statement (command-length safe)
const CONCURRENCY = 8; // parallel GitHub lookups
// owner/repo, already lowercased by the Worker's enqueue. Strict enough to be
// safe to inline as a SQL string literal (no quotes/whitespace).
const REPO_RE = /^[a-z0-9._-]+\/[a-z0-9._-]+$/;

const token = (process.env.GH_TOKEN || "").trim();
if (!token) {
  console.warn("refresh-archived: GH_TOKEN unset — using unauthenticated API");
}

const existing = new Set(readKv());
const pending = readPending().filter((r) => REPO_RE.test(r));

// Re-verify the existing baseline (to catch un-archives) plus the freshly-seen
// pending repos. Pending first so a rate-limited run still makes progress on
// new candidates.
const verifyList = [...new Set([...pending, ...existing])].filter((r) =>
  REPO_RE.test(r),
);

const archived = new Set(existing); // preserve unreached repos' prior status
const resolved = new Set();
let rateLimited = false;

await runPool(verifyList, CONCURRENCY, async (repo) => {
  if (rateLimited) return;
  const verdict = await classify(repo);
  if (verdict.rateLimited) {
    rateLimited = true;
    return;
  }
  if (!verdict.resolved) return; // transient error — leave as-is, retry next run
  resolved.add(repo);
  if (verdict.archived) archived.add(repo);
  else archived.delete(repo);
});

// Write KV only when the set changed.
const before = JSON.stringify([...existing].sort());
const after = JSON.stringify([...archived].sort());
if (after !== before) {
  writeKv(after);
  console.log(`refresh-archived: KV updated (${archived.size} archived repos)`);
} else {
  console.log(`refresh-archived: no change (${archived.size} archived repos)`);
}

// Drop only the repos we actually resolved from the worklist.
const toDelete = pending.filter((r) => resolved.has(r));
if (toDelete.length) deletePending(toDelete);

console.log(
  `refresh-archived: verified ${resolved.size}/${verifyList.length}, ` +
    `drained ${toDelete.length} pending` +
    (rateLimited ? " (stopped early on rate limit — rest queued)" : ""),
);

// ── GitHub ────────────────────────────────────────────────────────────────

async function classify(repo) {
  let res;
  try {
    res = await fetch(`https://api.github.com/repos/${repo}`, {
      headers: {
        "user-agent": "karinto-archived-refresh",
        accept: "application/vnd.github+json",
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
    });
  } catch {
    return { resolved: false }; // network blip — retry next run
  }
  // Rate limit: 429, or 403 with an exhausted/​retry-after signal. A plain 403
  // (e.g. a forbidden repo) is not a budget problem — skip just that repo
  // instead of aborting the whole run.
  const remaining = res.headers.get("x-ratelimit-remaining");
  if (
    res.status === 429 ||
    (res.status === 403 && (remaining === "0" || res.headers.get("retry-after")))
  ) {
    return { rateLimited: true };
  }
  if (res.status === 403) return { resolved: false }; // forbidden — skip, retry next run
  if (res.status === 404) return { resolved: true, archived: false }; // gone/renamed
  if (!res.ok) return { resolved: false };
  const data = await res.json().catch(() => null);
  return { resolved: true, archived: data?.archived === true };
}

async function runPool(items, concurrency, fn) {
  let i = 0;
  const workers = Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (i < items.length) await fn(items[i++]);
  });
  await Promise.all(workers);
}

// ── Cloudflare (via wrangler) ───────────────────────────────────────────────

function wrangler(args) {
  return execFileSync("npx", ["wrangler", ...args], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  });
}

function readKv() {
  try {
    const out = wrangler(["kv", "key", "get", KV_KEY, "--binding", "KV", "--config", CONFIG, "--remote"]);
    const arr = JSON.parse(out.trim());
    return Array.isArray(arr) ? arr.filter((x) => typeof x === "string") : [];
  } catch {
    return []; // key missing or unreadable — start from empty
  }
}

function writeKv(json) {
  const path = join(tmpdir(), "karinto-archived.json");
  writeFileSync(path, json);
  try {
    wrangler(["kv", "key", "put", KV_KEY, "--path", path, "--binding", "KV", "--config", CONFIG, "--remote"]);
  } finally {
    unlinkSync(path);
  }
}

function readPending() {
  const out = wrangler([
    "d1", "execute", DB_NAME, "--config", CONFIG, "--remote", "--json",
    "--command", `SELECT repo FROM pending ORDER BY repo LIMIT ${DRAIN_LIMIT}`,
  ]);
  const match = out.match(/\[[\s\S]*\]/);
  if (!match) return [];
  const parsed = JSON.parse(match[0]);
  const rows = parsed?.[0]?.results || [];
  return rows.map((r) => r.repo).filter((r) => typeof r === "string");
}

function deletePending(repos) {
  for (let i = 0; i < repos.length; i += DELETE_CHUNK) {
    // Re-assert REPO_RE at the inlining site so the SQL stays injection-safe
    // even if a caller ever passes unvalidated input (the values are inlined,
    // not bound). REPO_RE has no quotes/whitespace, so `'<repo>'` is safe.
    const chunk = repos.slice(i, i + DELETE_CHUNK).filter((r) => REPO_RE.test(r));
    if (chunk.length === 0) continue;
    const values = chunk.map((r) => `'${r}'`).join(",");
    wrangler([
      "d1", "execute", DB_NAME, "--config", CONFIG, "--remote",
      "--command", `DELETE FROM pending WHERE repo IN (${values})`,
    ]);
  }
}
