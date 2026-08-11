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
//   node scripts/replay.mjs --check-rules      # load-only; no target, no R2
//
// Required env (not needed for --check-rules):
//   R2_ACCESS_KEY_ID      R2 bucket-scoped access key
//   R2_SECRET_ACCESS_KEY  matching secret
//   R2_ACCOUNT_ID         Cloudflare account ID (for the S3 endpoint host)
// Optional env:
//   R2_BUCKET             defaults to "karinto-captures"
//   REPLAY_SUMMARY_PATH   if set, writes a markdown summary for sticky-comment
//   REPLAY_REPORT_PATH    if set, writes JSON per-rule match attribution
//                         (consumed by prune-diff-rules.yml)

import { createHash, createHmac } from "node:crypto";
import { writeFile } from "node:fs/promises";

// Response comparison and rule evaluation are shared with
// scripts/rebaseline-captures.mjs — the rule contract is written against the
// diff shapes produced there, so both scripts must use one implementation.
import {
  RULES_DIR,
  computeDiff,
  loadRules,
  matchRules,
  normalize,
} from "./lib/replay-diff.mjs";

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
    } else if (a === "--check-rules") args.checkRules = true;
    else if (a === "--help" || a === "-h") args.help = true;
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

// Per-request network timeout so a stuck DNS/TLS/connection can't leave a
// CI job hanging until the workflow-level timeout fires. Each fetch site
// (`r2List`, `r2Get`, `replayOne`) goes through `fetchWithTimeout`.
const FETCH_TIMEOUT_MS = 30000;

async function fetchWithTimeout(url, init = {}, timeoutMs = FETCH_TIMEOUT_MS) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: ctrl.signal });
  } catch (err) {
    if (err?.name === "AbortError") {
      throw new Error(`request to ${url} timed out after ${timeoutMs}ms`);
    }
    throw err;
  } finally {
    clearTimeout(timer);
  }
}

async function r2List(env, prefix, continuationToken) {
  const params = new URLSearchParams({ "list-type": "2", prefix });
  if (continuationToken) params.set("continuation-token", continuationToken);
  const url = `${env.endpoint}/${env.bucket}?${params}`;
  const headers = sigv4Headers("GET", url, env.accessKey, env.secretKey);
  const res = await fetchWithTimeout(url, { headers });
  if (!res.ok) {
    throw new Error(`R2 list failed (${res.status}): ${await res.text()}`);
  }
  return parseListObjects(await res.text());
}

async function r2Get(env, key) {
  const url = `${env.endpoint}/${env.bucket}/${encodeURI(key)}`;
  const headers = sigv4Headers("GET", url, env.accessKey, env.secretKey);
  const res = await fetchWithTimeout(url, { headers });
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

async function replayOne(targetUrl, request) {
  const body = new URLSearchParams();
  if (request.type) body.set("type", request.type);
  if (request.disable) body.set("disable", request.disable);
  if (request.content) body.set("content", request.content);
  // Forward every verdict-changing input captured by `normalizeRequest`
  // (cf/index.js). Omitting any of these replays the request without it, so
  // the PR worker computes a different verdict and the diff is spurious.
  if (request.forbidden) body.set("forbidden", request.forbidden);
  if (request.archived) body.set("archived", request.archived);
  if (request.ghalint) body.set("ghalint", request.ghalint);
  if (request.zizmor) body.set("zizmor", request.zizmor);
  if (request.config) body.set("config", request.config);
  if (request.path) body.set("path", request.path);
  if (request.persona) body.set("persona", request.persona);
  // Opt out of capture on the replay target so PR-side requests don't
  // pollute the bucket (defense-in-depth — PR Workers also lack the binding).
  body.set("no_capture", "1");

  const res = await fetchWithTimeout(targetUrl, {
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

  // A rule that throws stops suppressing without saying so — its diffs just
  // resurface as "unexpected". Surface it in the comment rather than leaving it
  // buried in stderr, since the fix is to repair the rule, not to add another.
  if (summary.threwByRule.size > 0) {
    lines.push("");
    lines.push("### Rules that errored");
    lines.push("");
    for (const [id, count] of summary.threwByRule) {
      lines.push(`- **${id}** threw on ${count} capture(s) — it suppressed nothing there.`);
    }
    lines.push("");
    lines.push("Fix the rule; see the job log for the thrown message.");
  }

  await writeFile(path, lines.join("\n"));
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  // Load-only mode: verify every rule module still imports and exposes the
  // expected shape, then exit. Needs no target and no R2 credentials.
  // prune-diff-rules.yml runs this after deleting rule files, because
  // `loadRules` throws when a surviving rule still imports a deleted delegate
  // and the pruner's importer guard is a grep heuristic — without this check a
  // hole in that heuristic would ship a PR whose replay dies at rule-load time.
  if (args.checkRules) {
    const { rules, skipped } = await loadRules(RULES_DIR);
    console.log(`loaded ${rules.length} ignore rule(s)`);
    for (const r of rules) {
      console.log(`  ${r.id}\t(${r.file})\tprunable=${r.prunable}`);
    }
    const problems = [];
    // A file that imports but exports no `matches` is not "no rule" — it is a
    // rule that silently never fires, and it would slip past the `prunable`
    // check below too because it never reaches the loaded set.
    if (skipped.length > 0) {
      problems.push(
        `exports no \`matches\` function: ${skipped.join(", ")} — every .mjs in ` +
          `scripts/diff-rules must be a rule`,
      );
    }
    const undeclared = rules.filter((r) => r.prunable === null);
    if (undeclared.length > 0) {
      problems.push(
        `missing \`prunable\` declaration: ${undeclared.map((r) => r.file).join(", ")}`,
      );
    }
    if (problems.length > 0) {
      for (const p of problems) console.error(p);
      console.error("see scripts/diff-rules/README.md");
      process.exit(1);
    }
    return;
  }

  if (args.help || !args.target) {
    console.error("usage: replay.mjs --target <url> [--limit N] | --check-rules");
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

  const { rules, skipped } = await loadRules(RULES_DIR);
  console.log(`loaded ${rules.length} ignore rule(s)`);
  if (skipped.length > 0) {
    // Loud but non-fatal here: lint.yml's `--check-rules` is what rejects this
    // at authoring time, and a replay run is more useful reporting the diffs
    // than refusing to start.
    console.error(
      `WARNING: ignoring ${skipped.join(", ")} — exports no \`matches\` function, ` +
        `so it suppresses nothing. Run \`node scripts/replay.mjs --check-rules\`.`,
    );
  }

  const captures = await fetchCaptures(env, args.limit);
  console.log(`fetched ${captures.length} capture(s) from r2://${env.bucket}`);

  const summary = {
    target: args.target,
    replayed: captures.length,
    matched: 0,
    ignored: 0,
    ignoredEntries: [],
    unexpected: [],
    // ruleId -> how many captures its `matches()` threw on. A rule that throws
    // silently stops suppressing, and its match counts become meaningless — so
    // the pruner must not read "shipped" or "not shipped" out of them.
    threwByRule: new Map(),
  };

  for (const cap of captures) {
    const replayed = await replayOne(args.target, cap.request);
    const diff = computeDiff(normalize(cap.response), normalize(replayed));

    if (diff.length === 0) {
      summary.matched++;
      continue;
    }

    // Every rule is evaluated, not just the first to match — see matchRules for
    // why first-match attribution would undercount the report that
    // prune-diff-rules.yml consumes. The first match still decides suppression
    // and the display attribution.
    const { matched, threw } = matchRules(rules, cap, replayed, diff);
    for (const t of threw) {
      summary.threwByRule.set(t.rule.id, (summary.threwByRule.get(t.rule.id) || 0) + 1);
      console.error(`rule ${t.rule.id} threw: ${t.reason}`);
    }
    const matchedRule = matched[0] || null;
    const matchedIds = matched.map((r) => r.id);

    if (matchedRule) {
      summary.ignored++;
      summary.ignoredEntries.push({
        hash: cap.hash,
        ruleId: matchedRule.id,
        reason: matchedRule.reason,
        matchedRuleIds: matchedIds,
      });
      const alsoBy = matchedIds.filter((id) => id !== matchedRule.id);
      console.log(
        `  ignore  ${cap.hash.slice(0, 12)}  via ${matchedRule.id}` +
          (alsoBy.length > 0 ? `  (also explained by ${alsoBy.join(", ")})` : ""),
      );
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

  // Machine-readable per-rule attribution for prune-diff-rules.yml.
  //
  // `matchCount` counts every capture whose diff the rule EXPLAINS, including
  // ones another rule was credited with suppressing — see the all-rules loop
  // above for why first-match attribution would undercount.
  //
  // A rule with matchCount > 0 explains a real prod-vs-capture diff this run,
  // so when the target is prod and the rule declares `prunable = true`, its fix
  // has shipped and it can be removed. matchCount > 0 alone is NOT sufficient:
  // a permanent rule (`prunable = false`) also matches against prod whenever
  // its out-of-band state has drifted, and deleting one of those would break
  // replay for good. `threwCount > 0` means the rule errored on at least one
  // capture, so neither its match count nor its silence says anything about
  // whether the fix shipped. The pruner gates on all three fields.
  //
  // Written regardless of exit code so the pruner can report the matched rules
  // even when there are also unmatched (drift) diffs.
  if (process.env.REPLAY_REPORT_PATH) {
    const byRule = new Map(rules.map((r) => [r.id, 0]));
    for (const e of summary.ignoredEntries) {
      for (const id of e.matchedRuleIds) {
        byRule.set(id, (byRule.get(id) || 0) + 1);
      }
    }
    const report = {
      target: summary.target,
      replayed: summary.replayed,
      matched: summary.matched,
      ignored: summary.ignored,
      unexpected: summary.unexpected.length,
      rules: rules.map((r) => ({
        id: r.id,
        file: r.file,
        matchCount: byRule.get(r.id) || 0,
        threwCount: summary.threwByRule.get(r.id) || 0,
        prunable: r.prunable,
      })),
    };
    await writeFile(process.env.REPLAY_REPORT_PATH, JSON.stringify(report, null, 2));
  }

  process.exit(summary.unexpected.length > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error(err);
  process.exit(2);
});
