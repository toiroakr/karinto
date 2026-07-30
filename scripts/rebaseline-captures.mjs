#!/usr/bin/env node
// scripts/rebaseline-captures.mjs
//
// Capture rebaseline — the "bake-in" step of the dark-launch replay system.
//
// Captures are create-only (`onlyIf: { etagDoesNotMatch: "*" }`, see
// cf/index.js): once a normalized request is first seen, its stored prod
// response is frozen and never overwritten. That is what makes replay a
// stable regression baseline — but it also means that after a release changes
// behaviour, the frozen captures keep the OLD response. A PR replayed against
// them then shows the *already-shipped* change as a diff forever, until the
// capture ages out of R2's ~30-day lifecycle. The interim cost is a
// self-expiring `scripts/diff-rules/*.mjs` ignore rule per shipped change.
//
// This script collapses that wait: it replays every stored capture's request
// against prod (now serving the new logic) and OVERWRITES the stored response
// with the fresh one (plain put, no `onlyIf`), preserving `first_seen` and
// stamping `rebaselined_at`. Afterwards the captures reflect current prod, so
// future replays diff only against current behaviour and the matching ignore
// rule can be deleted.
//
// Overwriting the baseline is exactly what replay exists to guard against, so
// this must run ONLY when a human has signalled that the shipped change is
// intentional — by merging the deletion of the corresponding expected-diff
// ignore rule into `main`. The workflow
// (`.github/workflows/rebaseline-captures.yml`) gates on that signal (a removed
// `scripts/diff-rules/*.mjs` file in the pushed range); this script trusts
// it and refreshes the whole bucket. It never invents findings: a capture is
// rewritten only when prod returns an `ok` response that differs from the
// stored one, so a prod outage cannot bake an error into the baseline.
//
// Which rules a rebaseline kills, and why this script has to be the one to say
// so
// ------------------------------------------------------------------------
// Refreshing the bucket does not only clear the diff the pruned rule covered —
// it clears EVERY prod-vs-capture diff, so every other transient rule that was
// masking one stops matching too. Those rules are then dead code that
// prune-diff-rules.yml can never remove: it gates on `matchCount > 0` as proof
// the fix shipped, and they now match nothing.
//
// The pruner cannot recover this by relaxing that gate, because `matchCount == 0`
// conflates two opposite states — "the fix has not shipped yet" (prod and
// captures both still serve the old behaviour, so no diff exists and the rule
// is about to become necessary) and "the captures are already fresh" (the rule
// is genuinely dead). A gate keyed on age or on absence of match would delete
// rules whose release is still pending.
//
// This script can tell them apart, because it is the causal agent and it looks
// before it writes: for each capture it is about to overwrite it asks which
// rules explain the diff that is about to be destroyed. A rule in that set was
// demonstrably suppressing a real prod-vs-capture diff — the same evidence
// standard as the pruner's gate — and is invalidated by this run. A
// not-yet-shipped rule matches nothing pre-write, so it is correctly left out.
// The result is reported, never acted on: see `attributeInvalidatedRules`.
//
// Usage:
//   node scripts/rebaseline-captures.mjs --target <prod-url> [--limit N] [--dry-run]
//
// Required env:
//   R2_ACCESS_KEY_ID      R2 bucket-scoped access key (read + write)
//   R2_SECRET_ACCESS_KEY  matching secret
//   R2_ACCOUNT_ID         Cloudflare account ID (for the S3 endpoint host)
// Optional env:
//   R2_BUCKET                  defaults to "karinto-captures"
//   REBASELINE_SUMMARY_PATH    if set, writes a markdown summary to this path
//   GITHUB_STEP_SUMMARY        if set, the markdown summary is appended here too
//   REBASELINE_REPORT_PATH     if set, writes JSON per-rule invalidation
//                              attribution (consumed by
//                              rebaseline-captures.yml to open a pruning PR)

import { createHash, createHmac } from "node:crypto";
import { appendFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

// Response comparison and rule evaluation are shared with scripts/replay.mjs.
// The rule contract `matches(capture, replayed, diff)` is written against the
// diff shapes produced there, so attribution here has to use the same
// implementation replay uses — a second one would drift and silently
// mis-attribute.
import {
  canonicalJson,
  collectDiagnostics,
  computeDiff,
  loadRules,
  matchRules,
  multisetSubtract,
  normalize,
} from "./lib/replay-diff.mjs";

const DEFAULT_BUCKET = "karinto-captures";
const EMPTY_SHA256 = createHash("sha256").update("").digest("hex");
// No cap by default: a signalled rebaseline must refresh the WHOLE bucket so no
// capture is left carrying the pre-release response. `--limit N` is only for
// emergency partial runs. MAX_LIST_PAGES still bounds a runaway listing.
const DEFAULT_LIMIT = Infinity;
const FETCH_TIMEOUT_MS = 30000;
// 1000 objects/page; the bucket is capped at ~7 GiB by cf/maintenance.js, so
// this bounds a runaway bucket from listing forever (mirrors replay.mjs).
const MAX_LIST_PAGES = 200;

function parseArgs(argv) {
  const args = { limit: DEFAULT_LIMIT, dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--target") args.target = argv[++i];
    else if (a === "--dry-run") args.dryRun = true;
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
// sigv4 signing for the R2 S3 endpoint (read GET + write PUT)
// ---------------------------------------------------------------------------

function hmac(key, data) {
  return createHmac("sha256", key).update(data).digest();
}

// Generalised over the body: `payload` is "" for GET/list (hashes to the
// well-known empty digest) and the request body for PUT. R2 requires the
// payload hash in `x-amz-content-sha256` and in the canonical request.
function sigv4Headers(method, url, accessKey, secretKey, payload = "") {
  const u = new URL(url);
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:\-]|\.\d{3}/g, "");
  const dateStamp = amzDate.slice(0, 8);
  const payloadHash =
    payload === "" ? EMPTY_SHA256 : createHash("sha256").update(payload).digest("hex");

  const canonicalUri = u.pathname || "/";
  const params = [...u.searchParams.entries()].sort((a, b) =>
    a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0,
  );
  const canonicalQuery = params
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join("&");

  const headers = {
    host: u.host,
    "x-amz-content-sha256": payloadHash,
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
    payloadHash,
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

// Preflight: verify the token can write before doing any real work. The probe
// key lives outside `captures/` so fetchCaptures never lists it; on 403 the
// error message tells the operator exactly which permission to grant.
async function verifyWriteAccess(env) {
  const probeKey = "_rebaseline-write-probe.json";
  const body = JSON.stringify({ ts: new Date().toISOString(), purpose: "write-preflight" });
  const url = `${env.endpoint}/${env.bucket}/${encodeURI(probeKey)}`;
  const headers = sigv4Headers("PUT", url, env.accessKey, env.secretKey, body);
  headers["content-type"] = "application/json";
  const res = await fetchWithTimeout(url, { method: "PUT", headers, body });
  if (!res.ok) {
    const text = await res.text();
    // R2 answers 403 for several distinct auth failures: AccessDenied (the token
    // lacks the permission), SignatureDoesNotMatch (secret is wrong / mangled),
    // NotEntitled (account not subscribed to R2). Only the first means "grant
    // write scope" — telling an operator to widen a token that is already
    // correct would send them chasing the wrong fix, so key off the error code.
    const code = text.match(/<Code>([^<]*)<\/Code>/)?.[1] ?? "";
    if (res.status === 403 && code === "AccessDenied") {
      throw new Error(
        `R2 write preflight failed (403 AccessDenied). The configured token has ` +
          `read-only access. Create a token scoped to "Object Read & Write" on the ` +
          `${env.bucket} bucket and set R2_WRITE_ACCESS_KEY_ID / R2_WRITE_SECRET_ACCESS_KEY ` +
          `as repo secrets. See DEVELOPMENT.md § "Dark-launch (capture & replay)" for details.`,
      );
    }
    throw new Error(
      `R2 write preflight failed (${res.status}${code ? ` ${code}` : ""}): ${text}`,
    );
  }
  console.log("write preflight: OK");
}

async function r2Put(env, key, body) {
  const url = `${env.endpoint}/${env.bucket}/${encodeURI(key)}`;
  const headers = sigv4Headers("PUT", url, env.accessKey, env.secretKey, body);
  headers["content-type"] = "application/json";
  const res = await fetchWithTimeout(url, { method: "PUT", headers, body });
  if (!res.ok) {
    throw new Error(`R2 put ${key} failed (${res.status}): ${await res.text()}`);
  }
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
    if (!Number.isFinite(limit)) {
      // Default (whole-bucket) run, but the listing was cut off — we can no
      // longer guarantee a complete rebaseline. Fail hard rather than silently
      // leave the baseline in a mixed state. An operator who deliberately wants
      // a bounded pass can pass `--limit N` to acknowledge a partial run.
      throw new Error(
        `captures/ list truncated at ${MAX_LIST_PAGES} pages (${all.length} objects) ` +
          `during a full rebaseline; refusing to rewrite a partial bucket. ` +
          `Re-run with an explicit --limit N for a bounded partial pass.`,
      );
    }
    console.warn(
      `captures/ list truncated at ${MAX_LIST_PAGES} pages (${all.length} objects); ` +
        `rebaselining the most recently modified ${limit} from the listed subset.`,
    );
  }

  // Selection (matters only for `--limit`): newest first by the R2 object's
  // LastModified — the only freshness signal the list response carries
  // (first_seen lives inside each object body, so sorting on it would require
  // fetching every object up front and defeat the point of `--limit`). So
  // `--limit N` processes the N most recently modified captures.
  all.sort((a, b) => new Date(b.lastModified) - new Date(a.lastModified));
  const slice = all.slice(0, limit);

  // Write order: oldest first. Each rebaseline put bumps LastModified to "now",
  // so processing ascending-by-age makes the genuinely most-recent captures end
  // up with the newest LastModified — preserving the freshness ordering
  // replay.mjs relies on (it, too, selects by LastModified). Writing newest
  // first would invert that ordering after a full run.
  slice.reverse();

  const captures = [];
  for (const obj of slice) {
    try {
      const data = JSON.parse(await r2Get(env, obj.key));
      captures.push({ key: obj.key, hash: obj.key.replace(/^captures\//, "").replace(/\.json$/, ""), ...data });
    } catch (e) {
      console.error(`failed to fetch ${obj.key}: ${e.message}`);
    }
  }
  return captures;
}

// ---------------------------------------------------------------------------
// Replay + diff (response comparison mirrors scripts/replay.mjs)
// ---------------------------------------------------------------------------

async function replayOne(targetUrl, request) {
  const body = new URLSearchParams();
  if (request.type) body.set("type", request.type);
  if (request.disable) body.set("disable", request.disable);
  if (request.content) body.set("content", request.content);
  if (request.forbidden) body.set("forbidden", request.forbidden);
  if (request.archived) body.set("archived", request.archived);
  if (request.ghalint) body.set("ghalint", request.ghalint);
  if (request.path) body.set("path", request.path);
  if (request.persona) body.set("persona", request.persona);
  // Never let the rebaseline traffic itself create captures.
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

// ---------------------------------------------------------------------------
// Invalidated-rule attribution
// ---------------------------------------------------------------------------

// Ask which rules explain the diff that this capture's overwrite is about to
// destroy. Called with the PRE-write responses, so the answer is "what was this
// rule still doing for us", not "what is left afterwards" (afterwards the answer
// is always "nothing", which is exactly the ambiguity the header comment
// describes).
//
// Purely observational: it records counts and never influences whether the
// capture is written. `main` also wraps the whole attribution pass so that a
// failure here degrades the report to "unavailable" rather than aborting a
// bake-in half-way through the bucket — a partially rewritten baseline is the
// worst outcome this workflow can produce.
export function attributeInvalidatedRules(rules, cap, replayed, stats) {
  const diff = computeDiff(normalize(cap.response), normalize(replayed));
  // No diff the rules can see. This happens even for captures being rewritten:
  // the responses differ as JSON, but only in fields outside what computeDiff
  // compares (see its note). Nothing was being suppressed here, so nothing is
  // invalidated.
  if (diff.length === 0) return;

  stats.ruleVisible++;
  const { matched, threw } = matchRules(rules, cap, replayed, diff);
  for (const t of threw) {
    stats.threwByRule.set(t.rule.id, (stats.threwByRule.get(t.rule.id) || 0) + 1);
    console.error(`rule ${t.rule.id} threw during attribution: ${t.reason}`);
  }
  for (const r of matched) {
    stats.invalidatedByRule.set(r.id, (stats.invalidatedByRule.get(r.id) || 0) + 1);
  }
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

export function buildSummary(summary) {
  const lines = [];
  lines.push("## Capture rebaseline");
  lines.push("");
  lines.push(`Replayed **${summary.replayed}** captures against \`${summary.target}\`.`);
  lines.push("");
  lines.push("| | count |");
  lines.push("|---|---|");
  lines.push(`| Rebaselined (response changed) | ${summary.rebaselined} |`);
  lines.push(`| Unchanged | ${summary.unchanged} |`);
  lines.push(`| Skipped (prod not ok) | ${summary.skipped} |`);
  if (summary.dryRun) {
    lines.push("");
    lines.push("> **Dry run** — no captures were written.");
  }

  const ruleRows = [...summary.ruleDeltas.entries()].sort((a, b) =>
    b[1].added + b[1].removed - (a[1].added + a[1].removed),
  );
  if (ruleRows.length) {
    lines.push("");
    lines.push("### Diagnostic deltas by rule");
    lines.push("");
    lines.push("| rule | added | removed |");
    lines.push("|---|---|---|");
    for (const [rule, d] of ruleRows) {
      lines.push(`| \`${rule}\` | ${d.added} | ${d.removed} |`);
    }
  }

  // The rules this run killed. Without this section the only trace is that some
  // rule quietly stops matching, which the pruner reads as "not shipped yet".
  const a = summary.attribution;
  lines.push("");
  lines.push("### Ignore rules invalidated by this rebaseline");
  lines.push("");
  if (!a.available) {
    lines.push(`Attribution unavailable: ${a.unavailableReason}`);
    lines.push("");
    lines.push("The rebaseline itself completed; only this report is missing.");
  } else {
    const invalidated = classifyInvalidated(a);
    if (invalidated.length === 0) {
      lines.push("None — no rule explained any diff this run baked in.");
    } else {
      lines.push("| rule | captures | prunable | verdict |");
      lines.push("|---|---|---|---|");
      for (const r of invalidated) {
        lines.push(
          `| \`${r.id}\` | ${r.invalidatedCount}${r.threwCount ? ` (+${r.threwCount} threw)` : ""} ` +
            `| ${r.prunable === null ? "_undeclared_" : `\`${r.prunable}\``} | ${r.verdict} |`,
        );
      }
      const deletable = invalidated.filter((r) => r.deletable);
      lines.push("");
      if (deletable.length > 0) {
        lines.push(
          `**${deletable.length} rule(s) are now dead** and can be deleted: ` +
            deletable.map((r) => `\`scripts/diff-rules/${r.file}\``).join(", ") + ".",
        );
        lines.push("");
        lines.push(
          "They each explained a real prod-vs-capture diff that this run has now " +
            "baked in, so they suppress nothing from here on. `prune-diff-rules.yml` " +
            "cannot find them on its own: it gates on `matchCount > 0` as proof the " +
            "fix shipped, and that evidence no longer exists.",
        );
      } else {
        lines.push("No rule is proposed for deletion — see the verdicts above.");
      }
    }
    if (a.partial) {
      lines.push("");
      lines.push(
        `> **Partial run** — \`--limit\` examined only ${summary.replayed} capture(s), ` +
          "so absence from this table does not prove a rule is dead elsewhere in the bucket.",
      );
    }
    // A skipped capture keeps its stale response, so its diff survives this run
    // and was never attributed. That cannot produce a bogus "safe to delete"
    // on its own — the verdict is earned from diffs actually destroyed — but a
    // rule listed here could still be carrying one of these, so say so.
    if (summary.skipped > 0) {
      lines.push("");
      lines.push(
        `> **${summary.skipped} capture(s) skipped** (prod did not return \`ok\`) and were ` +
          "left stale, so they were not examined. If a rule below is the only thing " +
          "explaining one of them, deleting it will resurface that diff — re-run once " +
          "prod is healthy to get a clean reading.",
      );
    }
  }

  if (summary.changed.length) {
    lines.push("");
    lines.push("<details><summary>Rebaselined captures</summary>");
    lines.push("");
    for (const c of summary.changed.slice(0, 50)) {
      lines.push(`- \`${c.hash.slice(0, 12)}\` — +${c.added} / -${c.removed} diagnostic(s)`);
    }
    if (summary.changed.length > 50) {
      lines.push(`- _…and ${summary.changed.length - 50} more_`);
    }
    lines.push("");
    lines.push("</details>");
  }
  return lines.join("\n") + "\n";
}

// ---------------------------------------------------------------------------

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || !args.target) {
    console.error("usage: rebaseline-captures.mjs --target <prod-url> [--limit N] [--dry-run]");
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

  // Verify write access up front — even for --dry-run, because dry-run skips
  // the per-capture r2Put and would otherwise never surface a 403. Catching it
  // here gives an actionable error before any slow replay work starts.
  await verifyWriteAccess(env);

  // Load the ignore rules so each overwrite can be attributed to the rules it
  // invalidates (see the header). Attribution is a reporting feature, so a load
  // failure must not stop the bake-in: record why it is unavailable and carry on
  // with an empty rule set. `loadRules` throws when a surviving rule imports a
  // deleted delegate — exactly the state a just-merged pruning PR can leave — and
  // refusing to rebaseline then would strand the captures stale with the rules
  // already gone, which is the situation this whole workflow exists to end.
  const attribution = {
    available: true,
    unavailableReason: null,
    // Only meaningful for a whole-bucket run. With `--limit N` the unexamined
    // captures may still hold diffs that some rule explains, so absence from
    // the invalidated set proves nothing.
    partial: Number.isFinite(args.limit),
    rules: [],
    // ruleId -> captures whose about-to-be-destroyed diff this rule explained.
    invalidatedByRule: new Map(),
    // ruleId -> captures where `matches()` threw. A rule that throws explains
    // nothing, so its silence must not be read as "not invalidated".
    threwByRule: new Map(),
    // Rewritten captures whose diff the rules could actually see. The rest
    // differ only outside computeDiff's comparison, so no rule could have been
    // suppressing them.
    ruleVisible: 0,
  };
  try {
    const { rules, skipped } = await loadRules();
    attribution.rules = rules;
    console.log(`loaded ${rules.length} ignore rule(s) for invalidation attribution`);
    if (skipped.length > 0) {
      console.error(
        `WARNING: ignoring ${skipped.join(", ")} — exports no \`matches\` function, ` +
          `so it suppresses nothing and cannot be attributed.`,
      );
    }
  } catch (e) {
    attribution.available = false;
    attribution.unavailableReason = e instanceof Error ? e.message : String(e);
    console.error(
      `WARNING: could not load ignore rules; invalidated-rule attribution is ` +
        `unavailable for this run: ${attribution.unavailableReason}`,
    );
  }

  const captures = await fetchCaptures(env, args.limit);
  console.log(`fetched ${captures.length} capture(s) from r2://${env.bucket}`);

  const summary = {
    target: args.target,
    dryRun: args.dryRun,
    replayed: captures.length,
    rebaselined: 0,
    unchanged: 0,
    skipped: 0,
    ruleDeltas: new Map(),
    changed: [],
    attribution,
  };

  for (const cap of captures) {
    const replayed = await replayOne(args.target, cap.request);
    // Never bake a prod error / outage into the baseline — only refresh from a
    // healthy `ok` response (mirrors cf/index.js capture's `!result?.ok` skip).
    if (!replayed?.ok) {
      summary.skipped++;
      console.log(`  skip    ${cap.hash.slice(0, 12)}  (prod not ok)`);
      continue;
    }

    if (canonicalJson(normalize(cap.response)) === canonicalJson(normalize(replayed))) {
      summary.unchanged++;
      continue;
    }

    const cap2 = collectDiagnostics(normalize(cap.response));
    const rep2 = collectDiagnostics(normalize(replayed));
    const removed = multisetSubtract(cap2, rep2);
    const added = multisetSubtract(rep2, cap2);
    for (const d of added) {
      const e = summary.ruleDeltas.get(d.rule) || { added: 0, removed: 0 };
      e.added++;
      summary.ruleDeltas.set(d.rule, e);
    }
    for (const d of removed) {
      const e = summary.ruleDeltas.get(d.rule) || { added: 0, removed: 0 };
      e.removed++;
      summary.ruleDeltas.set(d.rule, e);
    }

    summary.changed.push({ hash: cap.hash, added: added.length, removed: removed.length });

    // Attribute BEFORE the write, while the diff still exists. Runs under
    // --dry-run too: nothing is written there, but "which rules would this bake
    // in kill" is exactly what a dry run is for. Wrapped so a misbehaving rule
    // cannot abort the loop and leave the bucket half-rewritten.
    if (attribution.available) {
      try {
        attributeInvalidatedRules(attribution.rules, cap, replayed, attribution);
      } catch (e) {
        attribution.available = false;
        attribution.unavailableReason = e instanceof Error ? e.message : String(e);
        console.error(
          `WARNING: invalidated-rule attribution failed and is disabled for the ` +
            `rest of this run; the rebaseline continues: ${attribution.unavailableReason}`,
        );
      }
    }

    if (!args.dryRun) {
      // Plain put (no `onlyIf`): the whole point is to overwrite the frozen
      // response. Preserve `first_seen` — the timestamp diff-rule cutoffs
      // compare against (e.g. FIX_CUTOFF) and the original-capture record — and
      // stamp `rebaselined_at`. This overwrite bumps the object's LastModified
      // (which replay.mjs orders by) to now; the loop processes captures
      // oldest-first (see fetchCaptures) so that ordering stays monotonic with
      // capture age. first_seen is preserved in the body but does not drive
      // replay ordering.
      const payload = JSON.stringify({
        request: cap.request,
        response: replayed,
        first_seen: cap.first_seen,
        rebaselined_at: new Date().toISOString(),
      });
      await r2Put(env, cap.key, payload);
    }
    summary.rebaselined++;
    console.log(`  ${args.dryRun ? "would " : ""}rebaseline ${cap.hash.slice(0, 12)}  +${added.length} / -${removed.length}`);
  }

  console.log("");
  console.log(`replayed:    ${summary.replayed}`);
  console.log(`rebaselined: ${summary.rebaselined}${args.dryRun ? " (dry run)" : ""}`);
  console.log(`unchanged:   ${summary.unchanged}`);
  console.log(`skipped:     ${summary.skipped}`);

  const invalidated = classifyInvalidated(attribution);
  console.log("");
  if (!attribution.available) {
    console.log(`invalidated rules: unavailable (${attribution.unavailableReason})`);
  } else {
    console.log(
      `rule-visible diffs: ${attribution.ruleVisible} of ${summary.rebaselined} ` +
        `rebaselined capture(s)`,
    );
    if (invalidated.length === 0) {
      console.log("invalidated rules: none — no rule explained any diff baked in here");
    } else {
      console.log("invalidated rules:");
      for (const r of invalidated) {
        console.log(
          `  ${r.id}\tcaptures=${r.invalidatedCount}\tthrew=${r.threwCount}\t` +
            `prunable=${r.prunable}\t${r.verdict}`,
        );
      }
    }
    if (attribution.partial) {
      console.log(
        `NOTE: --limit run — only ${summary.replayed} capture(s) were examined, so ` +
          `absence from this list does NOT mean a rule is still needed elsewhere.`,
      );
    }
    if (summary.skipped > 0) {
      console.log(
        `NOTE: ${summary.skipped} capture(s) were skipped (prod not ok) and left stale, ` +
          `so their diffs were not attributed.`,
      );
    }
  }

  const md = buildSummary(summary);
  if (process.env.REBASELINE_SUMMARY_PATH) {
    await writeFile(process.env.REBASELINE_SUMMARY_PATH, md);
  }
  if (process.env.GITHUB_STEP_SUMMARY) {
    await appendFile(process.env.GITHUB_STEP_SUMMARY, md);
  }

  // Machine-readable attribution for rebaseline-captures.yml.
  //
  // `deletable` is the only field the workflow acts on, and it is deliberately
  // narrow: the rule explained at least one diff this run destroyed, never threw
  // while doing so, declares `prunable = true`, and the run covered the whole
  // bucket. Anything else is reported but not proposed for deletion — a rule that
  // threw says nothing either way, a `prunable = false` rule masks drift that will
  // come back (`archived-uses-baseline`), and a `--limit` run has not looked at
  // enough of the bucket to conclude anything.
  if (process.env.REBASELINE_REPORT_PATH) {
    const report = {
      target: summary.target,
      dryRun: summary.dryRun,
      replayed: summary.replayed,
      rebaselined: summary.rebaselined,
      unchanged: summary.unchanged,
      skipped: summary.skipped,
      attributionAvailable: attribution.available,
      attributionUnavailableReason: attribution.unavailableReason,
      partial: attribution.partial,
      ruleVisibleDiffs: attribution.ruleVisible,
      rules: invalidated,
    };
    await writeFile(process.env.REBASELINE_REPORT_PATH, JSON.stringify(report, null, 2));
  }
}

// Turn the raw counters into a per-rule verdict. Only rules that actually
// explained a destroyed diff appear — a rule that matched nothing was either
// not yet shipped or already dead, and this run has no evidence to tell those
// apart (see the header comment).
export function classifyInvalidated(attribution) {
  const out = [];
  for (const r of attribution.rules) {
    const invalidatedCount = attribution.invalidatedByRule.get(r.id) || 0;
    const threwCount = attribution.threwByRule.get(r.id) || 0;
    if (invalidatedCount === 0 && threwCount === 0) continue;
    let verdict;
    if (threwCount > 0) {
      verdict = "unattributable (matches() threw; repair the rule)";
    } else if (r.prunable === true) {
      verdict = attribution.partial
        ? "shipped, but --limit run — verify over the whole bucket before deleting"
        : "safe to delete";
    } else if (r.prunable === false) {
      verdict = "keep (permanent rule — the drift it masks will reopen)";
    } else {
      verdict = "keep (no `prunable` declaration — add one, see scripts/diff-rules/README.md)";
    }
    out.push({
      id: r.id,
      file: r.file,
      reason: r.reason,
      invalidatedCount,
      threwCount,
      prunable: r.prunable,
      deletable: threwCount === 0 && r.prunable === true && !attribution.partial,
      verdict,
    });
  }
  out.sort((a, b) => b.invalidatedCount - a.invalidatedCount);
  return out;
}

// Only start a rebaseline when invoked as a CLI. The attribution helpers above
// are exported for scripts/rebaseline-captures.test.mjs, and importing this file
// must not begin overwriting the production baseline as a side effect.
if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch((err) => {
    console.error(err);
    process.exit(2);
  });
}
