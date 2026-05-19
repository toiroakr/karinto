#!/usr/bin/env node
// scripts/replay.mjs
//
// Dark-launch replay: pull recent captured prod requests directly from the
// `karinto-captures` R2 bucket via Cloudflare's S3-compatible endpoint,
// replay each against a target URL (PR preview), and diff the responses.
// Diffs are filtered through any `scripts/diff-rules/*.mjs` "ignore rules"
// — a rule that returns `true` marks the diff as expected. Unmatched diffs
// fail the run.
//
// There is no replay-serving Worker endpoint: this script signs S3 requests
// with sigv4 using R2 access keys, which are the only credentials that can
// read the bucket. Cloudflare's R2 endpoint (`<account>.r2.cloudflarestorage.com`)
// is what enforces the auth.
//
// Usage:
//   node scripts/replay.mjs --target <url> [--limit N]
//
// Required env:
//   R2_ACCESS_KEY_ID      R2 bucket-scoped access key
//   R2_SECRET_ACCESS_KEY  matching secret
//   R2_ACCOUNT_ID         Cloudflare account ID (for the S3 endpoint host)
// Optional env:
//   R2_BUCKET             defaults to "karinto-captures"
//   REPLAY_SUMMARY_PATH   if set, writes a markdown summary for sticky-comment

import { createHash, createHmac } from "node:crypto";
import { readdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const RULES_DIR = join(__dirname, "diff-rules");
const DEFAULT_BUCKET = "karinto-captures";
const EMPTY_SHA256 = createHash("sha256").update("").digest("hex");

const DEFAULT_LIMIT = 200;

function parseArgs(argv) {
  const args = { limit: DEFAULT_LIMIT };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--target") args.target = argv[++i];
    else if (a === "--limit") {
      const raw = argv[++i];
      const n = parseInt(raw, 10);
      if (!Number.isFinite(n) || n <= 0) {
        throw new Error(`--limit must be a positive integer (got ${JSON.stringify(raw)})`);
      }
      args.limit = n;
    } else if (a === "--help" || a === "-h") args.help = true;
  }
  return args;
}

// ---------------------------------------------------------------------------
// sigv4 signing for R2 S3 endpoint
// ---------------------------------------------------------------------------

function hmac(key, data) {
  return createHmac("sha256", key).update(data).digest();
}

function sigv4Headers(method, url, accessKey, secretKey) {
  const u = new URL(url);
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:\-]|\.\d{3}/g, "");
  const dateStamp = amzDate.slice(0, 8);

  const canonicalUri = u.pathname || "/";
  const params = [...u.searchParams.entries()].sort((a, b) =>
    a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0,
  );
  const canonicalQuery = params
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join("&");

  const headers = {
    host: u.host,
    "x-amz-content-sha256": EMPTY_SHA256,
    "x-amz-date": amzDate,
  };
  const headerNames = Object.keys(headers).sort();
  const canonicalHeaders = headerNames.map((h) => `${h}:${headers[h]}\n`).join("");
  const signedHeaders = headerNames.join(";");

  const canonicalRequest = [
    method,
    canonicalUri,
    canonicalQuery,
    canonicalHeaders,
    signedHeaders,
    EMPTY_SHA256,
  ].join("\n");

  const credentialScope = `${dateStamp}/auto/s3/aws4_request`;
  const stringToSign = [
    "AWS4-HMAC-SHA256",
    amzDate,
    credentialScope,
    createHash("sha256").update(canonicalRequest).digest("hex"),
  ].join("\n");

  let signing = hmac(`AWS4${secretKey}`, dateStamp);
  signing = hmac(signing, "auto");
  signing = hmac(signing, "s3");
  signing = hmac(signing, "aws4_request");
  const signature = hmac(signing, stringToSign).toString("hex");

  headers.authorization =
    `AWS4-HMAC-SHA256 Credential=${accessKey}/${credentialScope}, ` +
    `SignedHeaders=${signedHeaders}, Signature=${signature}`;
  return headers;
}

// ---------------------------------------------------------------------------
// R2 S3 calls
// ---------------------------------------------------------------------------

async function r2List(env, prefix, continuationToken) {
  const params = new URLSearchParams({ "list-type": "2", prefix });
  if (continuationToken) params.set("continuation-token", continuationToken);
  const url = `${env.endpoint}/${env.bucket}?${params}`;
  const headers = sigv4Headers("GET", url, env.accessKey, env.secretKey);
  const res = await fetch(url, { headers });
  if (!res.ok) {
    throw new Error(`R2 list failed (${res.status}): ${await res.text()}`);
  }
  return parseListObjects(await res.text());
}

async function r2Get(env, key) {
  const url = `${env.endpoint}/${env.bucket}/${encodeURI(key)}`;
  const headers = sigv4Headers("GET", url, env.accessKey, env.secretKey);
  const res = await fetch(url, { headers });
  if (!res.ok) {
    throw new Error(`R2 get ${key} failed (${res.status})`);
  }
  return res.text();
}

function parseListObjects(xml) {
  const out = { objects: [], isTruncated: false, nextToken: null };
  for (const m of xml.matchAll(/<Contents>([\s\S]*?)<\/Contents>/g)) {
    const body = m[1];
    const key = body.match(/<Key>([^<]*)<\/Key>/)?.[1];
    const size = parseInt(body.match(/<Size>(\d+)<\/Size>/)?.[1] || "0", 10);
    const lastModified = body.match(/<LastModified>([^<]*)<\/LastModified>/)?.[1];
    if (key) out.objects.push({ key, size, lastModified });
  }
  out.isTruncated = /<IsTruncated>true<\/IsTruncated>/.test(xml);
  const token = xml.match(/<NextContinuationToken>([^<]*)<\/NextContinuationToken>/)?.[1];
  if (token) out.nextToken = token;
  return out;
}

// Safety cap on list pages (1000 objects/page). The bucket is capped at
// ~7 GiB by `cf/maintenance.js`, so in steady state this fits in ~hundreds
// of pages at most, but bound it explicitly so a runaway bucket can't make
// a CI replay job list forever / OOM.
const MAX_LIST_PAGES = 200;

async function fetchCaptures(env, limit) {
  let cursor = null;
  const all = [];
  let truncated = false;
  for (let page = 0; page < MAX_LIST_PAGES; page++) {
    const res = await r2List(env, "captures/", cursor);
    all.push(...res.objects);
    if (!res.isTruncated) {
      cursor = null;
      break;
    }
    cursor = res.nextToken;
    if (page === MAX_LIST_PAGES - 1) truncated = true;
  }
  if (truncated) {
    console.warn(
      `captures/ list truncated at ${MAX_LIST_PAGES} pages (${all.length} objects); ` +
      `picking the most recently first-seen ${limit} from the listed subset.`,
    );
  }

  // Captures are content-addressed and written with `etagDoesNotMatch: "*"`
  // for dedup, so `lastModified` is the timestamp we *first* saw a request
  // hash — repeats don't bump it. Sorting picks the most recently first-seen
  // unique requests, which favors new traffic patterns over repeats. That's
  // what we want for replay: cover the freshest distinct surface area.
  all.sort((a, b) => new Date(b.lastModified) - new Date(a.lastModified));
  const slice = all.slice(0, limit);

  const captures = [];
  for (const obj of slice) {
    try {
      const data = JSON.parse(await r2Get(env, obj.key));
      const hash = obj.key.replace(/^captures\//, "").replace(/\.json$/, "");
      captures.push({ hash, uploaded: obj.lastModified, ...data });
    } catch (e) {
      console.error(`failed to fetch ${obj.key}: ${e.message}`);
    }
  }
  return captures;
}

// ---------------------------------------------------------------------------
// Replay + diff
// ---------------------------------------------------------------------------

async function loadRules(dir) {
  let entries;
  try {
    entries = await readdir(dir);
  } catch {
    return [];
  }
  const rules = [];
  for (const f of entries.sort()) {
    if (!f.endsWith(".mjs")) continue;
    const mod = await import(pathToFileURL(join(dir, f)).href);
    if (typeof mod.matches !== "function") continue;
    rules.push({
      id: mod.id || f.replace(/\.mjs$/, ""),
      reason: mod.reason || "",
      matches: mod.matches,
    });
  }
  return rules;
}

async function replayOne(targetUrl, request) {
  const body = new URLSearchParams();
  if (request.type) body.set("type", request.type);
  if (request.disable) body.set("disable", request.disable);
  if (request.content) body.set("content", request.content);
  // Opt out of capture on the replay target so PR-side requests don't
  // pollute the bucket (defense-in-depth — PR Workers also lack the binding).
  body.set("no_capture", "1");

  const res = await fetch(targetUrl, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });
  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch {
    return { ok: false, error: `non-JSON response (status=${res.status}): ${text.slice(0, 200)}` };
  }
}

function normalize(resp) {
  if (!resp || typeof resp !== "object") return resp;
  const out = { ok: !!resp.ok };
  if (resp.error) out.error = resp.error;
  if (resp.result) {
    out.result = {
      kind: resp.result.kind,
      stats: resp.result.stats,
      diagnostics: sortDiagnostics(resp.result.diagnostics || []),
    };
  }
  if (Array.isArray(resp.files)) {
    out.files = resp.files.map((f) => ({
      path: f.path,
      ok: f.ok,
      error: f.error,
      result: f.result
        ? {
            kind: f.result.kind,
            stats: f.result.stats,
            diagnostics: sortDiagnostics(f.result.diagnostics || []),
          }
        : undefined,
    }));
  }
  return out;
}

function sortDiagnostics(diags) {
  return [...diags].sort((a, b) => {
    const ra = a.rule || "";
    const rb = b.rule || "";
    if (ra !== rb) return ra < rb ? -1 : 1;
    const sa = a.severity || "";
    const sb = b.severity || "";
    if (sa !== sb) return sa < sb ? -1 : 1;
    const ma = a.message || "";
    const mb = b.message || "";
    if (ma !== mb) return ma < mb ? -1 : 1;
    return 0;
  });
}

function computeDiff(captured, replayed) {
  const diffs = [];
  if (captured.ok !== replayed.ok) {
    diffs.push({ kind: "ok-mismatch", captured: captured.ok, replayed: replayed.ok });
  }

  // Diagnostic comparison uses count maps so a duplicate diagnostic
  // appearing N times in one side and M times in the other is treated as
  // a real diff (Set-based comparison would collapse multiplicity).
  const cap = collectDiagnostics(captured);
  const rep = collectDiagnostics(replayed);
  const onlyInCaptured = multisetSubtract(cap, rep);
  const onlyInReplayed = multisetSubtract(rep, cap);
  if (onlyInCaptured.length || onlyInReplayed.length) {
    diffs.push({ kind: "diagnostics", onlyInCaptured, onlyInReplayed });
  }

  // Catch-all for everything else `normalize()` exposes — result.kind,
  // result.stats, per-file ok/error, parse-error details, etc. Without this
  // a PR could regress documented response metadata without failing here.
  const capMeta = stripDiagnostics(captured);
  const repMeta = stripDiagnostics(replayed);
  // Use a canonical stringify (sorted object keys) so a different insertion
  // order between prod and PR does not register as a metadata diff — we only
  // want to flag semantic differences.
  if (canonicalJson(capMeta) !== canonicalJson(repMeta)) {
    diffs.push({ kind: "metadata", captured: capMeta, replayed: repMeta });
  }
  return diffs;
}

// Stable stringify for metadata diff comparison. The main purpose is to sort
// object keys so insertion order doesn't show up as a diff. Inside objects we
// drop `undefined` values (matching JSON.stringify) so `{a:1, b:undefined}`
// canonicalizes identically to `{a:1}`. Inside arrays — and at the top level —
// we emit `"null"` instead of JSON.stringify's literal `undefined`/`null`
// asymmetry, so any pair of inputs always produces a comparable string.
function canonicalJson(value) {
  if (value === undefined) return "null";
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) {
    return "[" + value.map(canonicalJson).join(",") + "]";
  }
  const parts = [];
  for (const k of Object.keys(value).sort()) {
    const v = value[k];
    if (v === undefined) continue;
    parts.push(JSON.stringify(k) + ":" + canonicalJson(v));
  }
  return "{" + parts.join(",") + "}";
}

function stripDiagnostics(resp) {
  if (!resp || typeof resp !== "object") return resp;
  const out = { ...resp };
  if (out.result) {
    const { diagnostics: _d, ...rest } = out.result;
    out.result = rest;
  }
  if (Array.isArray(out.files)) {
    out.files = out.files.map((f) => {
      if (!f.result) return f;
      const { diagnostics: _d, ...rest } = f.result;
      return { ...f, result: rest };
    });
  }
  return out;
}

function multisetSubtract(left, right) {
  const counts = new Map();
  for (const item of right) {
    const k = diagKey(item);
    counts.set(k, (counts.get(k) || 0) + 1);
  }
  const out = [];
  for (const item of left) {
    const k = diagKey(item);
    const c = counts.get(k) || 0;
    if (c > 0) counts.set(k, c - 1);
    else out.push(item);
  }
  return out;
}

function collectDiagnostics(resp) {
  if (resp.result?.diagnostics) {
    return resp.result.diagnostics.map((d) => ({
      rule: d.rule,
      severity: d.severity,
      message: d.message,
    }));
  }
  if (Array.isArray(resp.files)) {
    const out = [];
    for (const f of resp.files) {
      for (const d of f.result?.diagnostics || []) {
        out.push({
          file: f.path,
          rule: d.rule,
          severity: d.severity,
          message: d.message,
        });
      }
    }
    return out;
  }
  return [];
}

function diagKey(d) {
  return JSON.stringify([d.file || "", d.rule, d.severity, d.message]);
}

async function writeSummary(path, summary) {
  const lines = [];
  lines.push("## Dark-launch comparison");
  lines.push("");
  lines.push(`Replayed **${summary.replayed}** captures against \`${summary.target}\`.`);
  lines.push("");
  lines.push("| | count |");
  lines.push("|---|---|");
  lines.push(`| Matched | ${summary.matched} |`);
  lines.push(`| Ignored (expected diff) | ${summary.ignored} |`);
  lines.push(`| Unexpected diff | ${summary.unexpected.length} |`);

  if (summary.ignored > 0) {
    lines.push("");
    lines.push("<details><summary>Ignored diffs</summary>");
    lines.push("");
    for (const i of summary.ignoredEntries) {
      lines.push(`- \`${i.hash.slice(0, 12)}\` — via **${i.ruleId}**${i.reason ? `: ${i.reason}` : ""}`);
    }
    lines.push("");
    lines.push("</details>");
  }

  if (summary.unexpected.length > 0) {
    lines.push("");
    lines.push("### Unexpected diffs");
    lines.push("");
    for (const u of summary.unexpected.slice(0, 10)) {
      lines.push(`<details><summary><code>${u.hash.slice(0, 12)}</code></summary>`);
      lines.push("");
      lines.push("```json");
      lines.push(JSON.stringify(u.diff, null, 2));
      lines.push("```");
      lines.push("");
      lines.push("</details>");
    }
    if (summary.unexpected.length > 10) {
      lines.push("");
      lines.push(`_…and ${summary.unexpected.length - 10} more_`);
    }
    lines.push("");
    lines.push("If these are intentional, add an ignore rule under `scripts/diff-rules/`.");
  }

  await writeFile(path, lines.join("\n"));
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || !args.target) {
    console.error("usage: replay.mjs --target <url> [--limit N]");
    process.exit(args.help ? 0 : 2);
  }

  const env = {
    accessKey: process.env.R2_ACCESS_KEY_ID,
    secretKey: process.env.R2_SECRET_ACCESS_KEY,
    accountId: process.env.R2_ACCOUNT_ID,
    bucket: process.env.R2_BUCKET || DEFAULT_BUCKET,
  };
  if (!env.accessKey || !env.secretKey || !env.accountId) {
    console.error("R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, and R2_ACCOUNT_ID env vars are required");
    process.exit(2);
  }
  env.endpoint = `https://${env.accountId}.r2.cloudflarestorage.com`;

  const rules = await loadRules(RULES_DIR);
  console.log(`loaded ${rules.length} ignore rule(s)`);

  const captures = await fetchCaptures(env, args.limit);
  console.log(`fetched ${captures.length} capture(s) from r2://${env.bucket}`);

  const summary = {
    target: args.target,
    replayed: captures.length,
    matched: 0,
    ignored: 0,
    ignoredEntries: [],
    unexpected: [],
  };

  for (const cap of captures) {
    const replayed = await replayOne(args.target, cap.request);
    const diff = computeDiff(normalize(cap.response), normalize(replayed));

    if (diff.length === 0) {
      summary.matched++;
      continue;
    }

    let matchedRule = null;
    for (const r of rules) {
      try {
        if (r.matches(cap, replayed, diff)) {
          matchedRule = r;
          break;
        }
      } catch (e) {
        console.error(`rule ${r.id} threw: ${e.message}`);
      }
    }

    if (matchedRule) {
      summary.ignored++;
      summary.ignoredEntries.push({
        hash: cap.hash,
        ruleId: matchedRule.id,
        reason: matchedRule.reason,
      });
      console.log(`  ignore  ${cap.hash.slice(0, 12)}  via ${matchedRule.id}`);
    } else {
      summary.unexpected.push({ hash: cap.hash, diff, request: cap.request });
      console.log(`  DIFF    ${cap.hash.slice(0, 12)}`);
    }
  }

  console.log("");
  console.log(`replayed:   ${summary.replayed}`);
  console.log(`matched:    ${summary.matched}`);
  console.log(`ignored:    ${summary.ignored}`);
  console.log(`unexpected: ${summary.unexpected.length}`);

  if (process.env.REPLAY_SUMMARY_PATH) {
    await writeSummary(process.env.REPLAY_SUMMARY_PATH, summary);
  }

  process.exit(summary.unexpected.length > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error(err);
  process.exit(2);
});
