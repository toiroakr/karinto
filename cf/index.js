// Cloudflare Workers entry point for karinto.
//
// Accepts GET or POST. Parameters can come from the URL path
// (`/owner/repo/commit[/target]`, or a domain-swapped GitHub file URL
// `/owner/repo/{blob,tree,raw}/<ref>/<target>`), the URL query string, the
// request body (raw `key=value&...`, JSON, or a YAML blob as the whole body),
// or a mix of all three. Body > query > path on conflicts.
//
// Keys:
//   - type      "workflow" | "action" | "" (auto-detect, default)
//   - content   YAML source
//   - disable   comma-separated rule-ID glob patterns to skip
//   - repo      "owner/name" — fetch files from a public GitHub repo. Repo
//               mode (this plus the `/owner/repo[/...]` path forms) is opt-in
//               via the REPO_MODE_ENABLED deployment variable; off by default.
//   - commit    commit SHA (7-64 hex chars); an immutable pin. Either this or
//               `ref` is required in explicit-target mode (`targets=` or a
//               URL-path target); whole-repo discovery (no targets) defaults to
//               the repo's default branch when neither is given.
//   - ref       branch / tag / `HEAD` / SHA to fetch at (mutable; resolves to
//               that ref's latest commit). Use it to lint the default branch
//               (`ref=HEAD`) or any branch by name. Takes precedence over
//               `commit`. A domain-swapped GitHub URL fills this from the path.
//   - targets   comma-separated literal paths. With `repo`, either
//               `targets=` or a single target via the URL path
//               (`/owner/repo/commit/target/...`) must be supplied
//   - osv       "1" / "true" → query OSV.dev for known-vulnerable actions
//               (adds ~50-300ms latency depending on action count)
//   - forbidden comma-separated globs for the `forbidden-uses` denylist
//   - archived  comma-separated `owner/repo` for `archived-uses` (merged with
//               the KV-cached baseline refreshed by the daily cron)
//
// The response also carries `online_audit_candidates`: the external `uses:`
// refs that need a live GitHub API lookup (`impostor-commit`,
// `ref-version-mismatch`). karinto does not resolve these; the companion
// action (see docs/action-context.md) checks them and reports directly.
//
// The handler logs a one-line JSON record per request to stdout.
//
// YAML parsing is delegated to the MoonBit engine (the in-tree `yamlpos` parser).
// When the YAML is malformed the engine returns a `parse_error` field which
// the handler propagates verbatim.

// Stamped onto every response as `engine_version` so callers can detect when
// the deployed engine has moved underneath them. Sourced from the
// changesets-managed root manifest (kept in lockstep with `moon.mod` by
// `scripts/sync-moon-version.mjs`), inlined by wrangler/esbuild at deploy
// time, so the always-latest endpoint and each pinned
// `karinto-vX-Y-Z.toiroakr.workers.dev` report exactly the version they ship.
import pkg from "../package.json";
const ENGINE_VERSION = pkg.version;
// Committed archived-uses baseline (maintained by refresh-archived.yml). Bundled
// as a seed so a fresh deploy / fork has a baseline before KV is populated; the
// live KV value (also written by the CI job) is merged on top on the request
// path. Kept in sync with KV by the CI job — see ARCHIVED_KV_KEY below.
import ARCHIVED_SEED from "./archived.json";

// MoonBit's compiled JS seeds a hashmap RNG at module load via
// `crypto.getRandomValues`, which CF Workers forbids in global scope. Defer
// the import until the first request so it runs inside a handler.
let _workerPromise;
function getWorker() {
  if (!_workerPromise) {
    _workerPromise = import("../_build/js/release/build/worker/worker.js");
  }
  return _workerPromise;
}

// Reject obviously oversized payloads before they reach the linter. GitHub
// workflow YAML files are well under 100 KB in practice; cap at 1 MiB to keep
// `count_lines` / `walk_strings` / rule passes bounded.
const MAX_BODY_BYTES = 1_048_576;
// Defensive caps on user-controlled fan-out fields. `disable` patterns and
// `targets` lists are otherwise unbounded inputs.
const MAX_DISABLE_PATTERNS = 64;
const MAX_DISABLE_PATTERN_LEN = 128;
const MAX_TARGETS = 50;
// Caller-supplied augmentation lists (`forbidden` / `archived`) feed rules
// whose verdict depends on data the caller resolved out-of-band (GitHub API).
// They are comma-separated `uses:` refs or globs, so the entries are short and
// few in practice.
const MAX_USES_ENTRIES = 200;
const MAX_USES_ENTRY_LEN = 256;
// KV-published baseline of archived `owner/repo` slugs (the `archived-uses`
// rule reads this on the request path). It is maintained out-of-band by the
// .github/workflows/refresh-archived.yml CI job, which drains the D1 `pending`
// worklist this Worker fills, verifies each repo against the GitHub API, and
// writes this key — so the Worker never calls the API on the hot path. Merged
// into the `archived` augmentation so callers get the popular cases for free.
// Memoized per-isolate with a TTL so we don't read KV on every request (same
// pattern as the /meta cache).
const ARCHIVED_KV_KEY = "archived:list";
const ARCHIVED_TTL_MS = 6 * 60 * 60 * 1000;
let _archivedPromise;
let _archivedExpiresAt = 0;
// At most this many `uses:` repos enqueued into D1 per request (non-blocking).
const PENDING_ENQUEUE_MAX = 100;

export default {
  async fetch(request, env, ctx) {
    const started = Date.now();
    try {
      await enforceRateLimit(request, env, ctx);
      const { params, pathTarget } = await readParams(request);
      const result = await handle(params, env, pathTarget);
      const elapsed = Date.now() - started;
      const targetsStr = Object.prototype.hasOwnProperty.call(params, "targets")
        ? String(params.targets ?? "")
        : pathTarget || "";
      log("request", {
        method: request.method,
        type: params.type || "(auto)",
        disable: params.disable || "",
        repo: params.repo || "",
        commit: params.commit || "",
        ref: params.ref || "",
        targets: targetsStr,
        content_lines: params.content ? params.content.split("\n").length : 0,
        // SARIF responses carry no `files` array, so fall back to the request
        // inputs: target count in repo mode, 1 for a content lint.
        files: result.files?.length ??
          (targetsStr
            ? targetsStr.split(",").filter((s) => s.trim()).length
            : params.content ? 1 : 0),
        elapsed_ms: elapsed,
      });
      // SARIF responses are already serialized by the MoonBit side and
      // bypass capture/replay and the archived-uses enqueue — both consume
      // the JSON envelope shape.
      if (result && typeof result.sarif === "string") {
        return sarifResponse(result.sarif);
      }
      // Only register the waitUntil promise when CAPTURES is actually bound
      // (production env). Preview/staging skip the wrapper entirely so
      // non-production traffic doesn't pay the Promise/catch overhead on
      // the hot path.
      if (env?.CAPTURES) {
        ctx.waitUntil(
          captureRequest(env, params, result, request.headers).catch((err) => {
            log("capture_error", { message: String(err?.message ?? err) });
          }),
        );
      }
      // Enqueue the external `uses:` repos for the daily archived-status sweep.
      // Non-blocking and best-effort; INSERT OR IGNORE dedups in D1.
      if (env?.DB) {
        ctx.waitUntil(
          enqueuePending(env, candidateRepos(result)).catch((err) => {
            log("enqueue_error", { message: String(err?.message ?? err) });
          }),
        );
      }
      return json({ ...result, engine_version: ENGINE_VERSION });
    } catch (err) {
      const status = err?.status ?? 400;
      log("error", { status, message: String(err?.message ?? err) });
      return json(
        { ok: false, error: String(err?.message ?? err), engine_version: ENGINE_VERSION },
        status,
      );
    }
  },

  // Daily cron — refresh the GitHub Actions IP allow-list so per-IP rate
  // limiting can exempt CI traffic. On fetch failure we leave whatever is
  // already in KV; the request path falls back to a direct fetch if KV is
  // empty (e.g. immediately after a fresh deploy). The archived-uses baseline
  // (`archived:list`) is NOT maintained here — the .github/workflows/
  // refresh-archived.yml CI job verifies repos against the GitHub API (no
  // Worker subrequest/rate-limit ceilings) and writes the KV key directly.
  async scheduled(_event, env, ctx) {
    ctx.waitUntil(refreshMetaCache(env));
  },
};

// Per-IP rate limit. Traffic from GitHub-hosted Actions runners is exempt
// because they share egress IPs across unrelated tenants — a noisy CI user
// would otherwise 429 unrelated CI traffic as collateral. Falls open if
// the binding is missing (e.g. `wrangler dev` without `--remote`).
//
// We always consult the limiter first so the hot path stays a single
// Workers binding call. The (potentially slow) /meta lookup only runs
// when the limiter says no — this keeps the DoS protection independent
// of GitHub's availability even on a cold isolate.
async function enforceRateLimit(request, env, ctx) {
  if (!env?.RATE_LIMITER_IP) return;
  const ip = request.headers.get("cf-connecting-ip");
  const { success } = await env.RATE_LIMITER_IP.limit({ key: ip || "unknown" });
  if (success) return;
  if (await isFromGitHubActions(ip, env, ctx)) return;
  throw httpError("rate limit exceeded", 429);
}

// --- GitHub Actions IP allow-list -------------------------------------------
// Source: `api.github.com/meta`'s `.actions` field, refreshed by a daily
// cron trigger into KV. The request path reads from KV (memoized for the
// lifetime of the isolate) and falls back to a direct fetch on miss so a
// fresh deploy keeps working before the first cron run.

const META_URL = "https://api.github.com/meta";
const META_KV_KEY = "actions_cidrs";
const META_FETCH_TIMEOUT_MS = 5000;
// Cap the in-isolate memo so the daily cron's KV write propagates to
// long-lived isolates without waiting for recycle. 10 min is short enough
// that runner CIDR churn (rare in practice) is bounded, long enough that
// KV reads stay cheap.
const RANGES_TTL_MS = 10 * 60 * 1000;

let _rangesPromise; // isolate-level memo; reset by TTL or on isolate recycle.
let _rangesExpiresAt = 0;

async function isFromGitHubActions(ip, env, ctx) {
  if (!ip) return false;
  try {
    const ranges = await getActionsRanges(env, ctx);
    return ipInRanges(ip, ranges);
  } catch {
    return false;
  }
}

function getActionsRanges(env, ctx) {
  const now = Date.now();
  if (!_rangesPromise || now >= _rangesExpiresAt) {
    _rangesPromise = loadActionsRanges(env, ctx).catch((e) => {
      _rangesPromise = undefined; // retry on the next request
      _rangesExpiresAt = 0;
      throw e;
    });
    _rangesExpiresAt = now + RANGES_TTL_MS;
  }
  return _rangesPromise;
}

async function loadActionsRanges(env, ctx) {
  if (env?.KV) {
    const raw = await env.KV.get(META_KV_KEY);
    if (raw) {
      try {
        return compileRanges(JSON.parse(raw)?.actions || []);
      } catch {
        // fall through to direct fetch
      }
    }
  }
  const meta = await fetchMeta();
  if (!meta) {
    // Don't memoize an empty range set: a transient /meta outage during a
    // cold deploy would otherwise strip the GitHub Actions exemption for
    // 10 minutes. Throw so `getActionsRanges` clears the memo and the next
    // request retries (in-flight requests share the same rejected promise,
    // so this is bounded to one /meta call per fetchMeta-timeout window).
    throw new Error("meta unavailable");
  }
  if (env?.KV && ctx) {
    ctx.waitUntil(env.KV.put(META_KV_KEY, JSON.stringify(meta)));
  }
  return compileRanges(meta.actions || []);
}

async function refreshMetaCache(env) {
  const meta = await fetchMeta();
  if (!meta) {
    log("cron_meta_fetch_failed", {});
    return;
  }
  if (env?.KV) {
    await env.KV.put(META_KV_KEY, JSON.stringify(meta));
  }
  log("cron_meta_refreshed", { actions: (meta.actions || []).length });
}

// Bare `owner/repo` slugs of the external `uses:` refs in a lint result — the
// candidates the CI archived-status sweep verifies. Subpaths (reusable-workflow
// paths) are collapsed to `owner/repo`.
function candidateRepos(result) {
  const out = new Set();
  const add = (cands) => {
    for (const c of cands || []) {
      const repo = bareOwnerRepo(c.name);
      if (repo) out.add(repo);
    }
  };
  add(result.online_audit_candidates);
  for (const f of result.files || []) add(f.online_audit_candidates);
  return [...out];
}

function bareOwnerRepo(name) {
  if (typeof name !== "string") return null;
  const parts = name.split("/");
  return parts.length >= 2 ? `${parts[0]}/${parts[1]}`.toLowerCase() : null;
}

// Enqueue repos into the D1 `pending` worklist (INSERT OR IGNORE dedups). Runs
// best-effort off the request hot path via `ctx.waitUntil`.
async function enqueuePending(env, repos) {
  if (!env?.DB || repos.length === 0) return;
  const stmt = env.DB.prepare("INSERT OR IGNORE INTO pending (repo) VALUES (?)");
  const batch = repos
    // Match the CI verifier's accepted shape (lowercased owner/repo) so only
    // rows refresh-archived.mjs can actually verify land in the worklist.
    .filter((r) => /^[a-z0-9._-]+\/[a-z0-9._-]+$/.test(r))
    .slice(0, PENDING_ENQUEUE_MAX)
    .map((r) => stmt.bind(r));
  if (batch.length) await env.DB.batch(batch);
}

async function fetchMeta() {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), META_FETCH_TIMEOUT_MS);
  try {
    const res = await fetch(META_URL, {
      headers: { "user-agent": "karinto-worker" },
      signal: ctrl.signal,
    });
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

// --- CIDR matching ----------------------------------------------------------

function compileRanges(cidrs) {
  const v4 = [];
  const v6 = [];
  for (const cidr of cidrs) {
    if (typeof cidr !== "string") continue;
    const slash = cidr.indexOf("/");
    if (slash < 0) continue;
    const base = cidr.slice(0, slash);
    const bitsRaw = cidr.slice(slash + 1);
    if (!/^\d+$/.test(bitsRaw)) continue;
    const bits = Number(bitsRaw);
    if (base.includes(":")) {
      const baseBig = ipv6ToBigInt(base);
      if (baseBig !== null && bits <= 128) v6.push({ base: baseBig, bits });
    } else {
      const baseInt = ipv4ToInt(base);
      if (baseInt !== null && bits <= 32) v4.push({ base: baseInt, bits });
    }
  }
  return { v4, v6 };
}

function ipInRanges(ip, ranges) {
  if (ip.includes(":")) {
    const big = ipv6ToBigInt(ip);
    if (big === null) return false;
    for (const r of ranges.v6) {
      if (r.bits === 0) return true;
      const mask = ((1n << BigInt(r.bits)) - 1n) << BigInt(128 - r.bits);
      if ((big & mask) === (r.base & mask)) return true;
    }
    return false;
  }
  const int = ipv4ToInt(ip);
  if (int === null) return false;
  for (const r of ranges.v4) {
    if (r.bits === 0) return true;
    const mask = r.bits === 32 ? 0xffffffff : ((0xffffffff << (32 - r.bits)) >>> 0);
    if ((int & mask) === (r.base & mask)) return true;
  }
  return false;
}

function ipv4ToInt(ip) {
  const parts = ip.split(".");
  if (parts.length !== 4) return null;
  let n = 0;
  for (const p of parts) {
    if (!/^\d{1,3}$/.test(p)) return null;
    const v = Number(p);
    if (v < 0 || v > 255) return null;
    n = (n << 8) | v;
  }
  return n >>> 0;
}

function ipv6ToBigInt(ip) {
  if (!ip.includes(":")) return null;
  const dc = ip.split("::");
  if (dc.length > 2) return null;
  const head = dc[0] ? dc[0].split(":") : [];
  const tail = dc.length === 2 ? (dc[1] ? dc[1].split(":") : []) : null;
  let parts;
  if (tail === null) {
    parts = head;
    if (parts.length !== 8) return null;
  } else {
    const fill = 8 - head.length - tail.length;
    if (fill < 0) return null;
    parts = [...head, ...Array(fill).fill("0"), ...tail];
  }
  let n = 0n;
  for (const p of parts) {
    if (!/^[0-9a-fA-F]{1,4}$/.test(p)) return null;
    n = (n << 16n) | BigInt(parseInt(p, 16));
  }
  return n;
}

function httpError(message, status) {
  const e = new Error(message);
  e.status = status;
  return e;
}

async function readParams(request) {
  const url = new URL(request.url);
  const path = parsePath(url.pathname);
  const params = {};
  if (path.repo) params.repo = path.repo;
  if (path.commit) params.commit = path.commit;
  if (path.ref) params.ref = path.ref;
  for (const [k, v] of url.searchParams) params[k] = v;

  const cl = Number(request.headers.get("content-length"));
  if (Number.isFinite(cl) && cl > MAX_BODY_BYTES) {
    throw httpError(`request body too large (max ${MAX_BODY_BYTES} bytes)`, 413);
  }

  if (request.method !== "GET" && request.method !== "HEAD") {
    const ct = request.headers.get("content-type") || "";
    const raw = await readBoundedText(request);
    if (raw) mergeBody(params, raw, ct);
  } else if (request.method === "GET" && request.body) {
    // curl --data-urlencode + GET also sends a body.
    const raw = await readBoundedText(request);
    if (raw) mergeBody(params, raw, request.headers.get("content-type") || "");
  }
  return { params, pathTarget: path.pathTarget };
}

// `/owner/repo/commit[/target/...]` → `{ repo, commit, pathTarget? }`, or a
// domain-swapped GitHub file URL `/owner/repo/{blob,tree,raw}/<ref>/<target>`
// → `{ repo, ref, pathTarget? }`. Segments after the commit/ref are joined as
// a single target path (so nested paths like `.github/workflows/ci.yml` work).
// Returned separately from the `params` map so a client cannot inject
// `pathTarget`/`ref` via query / body. Multi-target requests still need to come
// through `targets=` query/body.
//
// Only paths that look like one of the repo-mode patterns are interpreted;
// anything else (e.g. `/favicon.ico`, a deploy prefix `/api/karinto/...`,
// malformed percent-encoding) returns `{}` so the request falls through to the
// regular content/repo body parameters. This keeps the Worker mountable
// under arbitrary path prefixes without bricking unrelated requests.
function parsePath(pathname) {
  const rawSegments = pathname.split("/").filter(Boolean);
  if (rawSegments.length < 2) return {};
  let segments;
  try {
    segments = rawSegments.map((s) => decodeURIComponent(s));
  } catch {
    return {};
  }
  const [owner, repo, marker, ...rest] = segments;
  if (!/^[A-Za-z0-9_.\-]+$/.test(owner) || !/^[A-Za-z0-9_.\-]+$/.test(repo)) return {};
  const base = { repo: `${owner}/${repo}` };

  // Bare `/owner/repo` — no ref, no target. Lints every workflow on the default
  // branch (whole-repo discovery in `handleRepo`). This widens the set of paths
  // the Worker claims (a 2-segment path under a mount prefix now reads as a
  // repo), but the owner/repo charset still gates it and an unrelated path just
  // yields a clean "repo / workflows not found" error rather than bricking.
  if (rest.length === 0 && marker === undefined) return base;

  // GitHub web / raw file URL shape: `/owner/repo/{blob,tree,raw}/<ref>/<path>`.
  // Domain-swapping a `github.com/.../blob/<branch>/<file>` URL lands here, so
  // a bare domain swap can lint a branch's latest commit. Only the first
  // post-marker segment is taken as the ref — a multi-segment branch name
  // (e.g. `release/1.x`) is ambiguous against the file path without a GitHub
  // API probe, so those callers must use `?ref=` + `targets=`. The ref is
  // validated downstream in `resolveRef`.
  if (/^(blob|tree|raw)$/.test(marker) && rest.length >= 1) {
    const [ref, ...pathRest] = rest;
    const out = { ...base, ref };
    if (pathRest.length > 0) out.pathTarget = pathRest.join("/");
    return out;
  }

  // Bare shape: `/owner/repo/<commit>/<path...>`. The 3rd segment must be a hex
  // SHA — a non-hex value falls through to `{}` so the Worker stays mountable
  // under arbitrary path prefixes. Branch/tag refs in the bare shape come
  // through `?ref=` instead (the raw.githubusercontent.com URL has no marker
  // segment, so a domain-swapped raw URL only auto-works for SHA refs).
  if (!/^[0-9a-fA-F]{7,64}$/.test(marker)) return {};
  const out = { ...base, commit: marker };
  if (rest.length > 0) out.pathTarget = rest.join("/");
  return out;
}

// Stream the body and abort once `MAX_BODY_BYTES` is exceeded so a client
// can't bypass the content-length check by omitting / lying about the header.
async function readBoundedText(request) {
  return readBoundedStream(request.body, "request body");
}

async function readBoundedResponse(response) {
  return readBoundedStream(response.body, "response body");
}

async function readBoundedStream(body, label) {
  if (!body) return "";
  const reader = body.getReader();
  const decoder = new TextDecoder("utf-8");
  let total = 0;
  let out = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_BODY_BYTES) {
      await reader.cancel().catch(() => {});
      throw httpError(`${label} too large (max ${MAX_BODY_BYTES} bytes)`, 413);
    }
    out += decoder.decode(value, { stream: true });
  }
  out += decoder.decode();
  return out;
}

const KNOWN_KEYS = new Set([
  "content",
  "type",
  "disable",
  "repo",
  "commit",
  "ref",
  "targets",
  "osv",
  "no_capture",
  "forbidden",
  "archived",
  "format",
  "path",
]);

function mergeBody(params, raw, ct) {
  if (ct.includes("application/json") || raw.trimStart().startsWith("{")) {
    try {
      Object.assign(params, JSON.parse(raw));
      return;
    } catch {
      // fall through to other strategies
    }
  }
  // Try form-encoded only when the body looks like a single-line querystring
  // with at least one known key. The newline guard prevents a YAML body that
  // happens to contain `no_capture=` (or any other known key) on some line
  // from being parsed via URLSearchParams — form bodies don't span lines.
  // We can't fall back to Content-Type alone because `curl --data-binary`
  // (the documented usage) sends `application/x-www-form-urlencoded` even
  // when the payload is raw YAML.
  if (!raw.includes("\n") && KNOWN_KEYS_RE.test(raw)) {
    const sp = new URLSearchParams(raw);
    let matched = false;
    for (const [k, v] of sp) {
      if (KNOWN_KEYS.has(k)) {
        params[k] = v;
        matched = true;
      }
    }
    if (matched) return;
  }
  // Anything else is treated as the YAML body itself.
  if (!params.content && !params.repo) {
    params.content = raw;
  }
}

const KNOWN_KEYS_RE = /(^|&)(content|type|disable|repo|commit|ref|targets|osv|no_capture|forbidden|archived|format|path)=/;

async function handle(params, env, pathTarget) {
  const disable = sanitizeDisable(params.disable ?? "");
  const forbidden = sanitizeUsesList(params.forbidden, "forbidden");
  const callerArchived = sanitizeUsesList(params.archived, "archived");
  const type = params.type || "";
  const format = parseFormat(params.format);
  const useOsv = isTrue(params.osv);
  const worker = await getWorker();
  // Merge the caller's `archived` list with the live KV baseline and the
  // bundled seed (cold-start fallback before KV is populated). The engine also
  // carries its own hardcoded baseline, so all are additive.
  const kvArchived = await getArchivedList(env);
  const archived = [callerArchived, kvArchived.join(","), ARCHIVED_SEED.join(",")]
    .filter(Boolean)
    .join(",");

  if (params.repo) {
    // Repo mode — fetching workflow / action files from GitHub by `owner/repo`
    // (+ optional commit/ref/path, or whole-repo discovery) — is opt-in. It
    // makes the Worker fetch arbitrary public content and, in discovery mode,
    // spend the shared GitHub API budget, so it stays off unless the deployment
    // sets the `REPO_MODE_ENABLED` variable (see DEVELOPMENT.md). Posting the
    // YAML as `content` is always available.
    if (!isTrue(env?.REPO_MODE_ENABLED)) {
      throw httpError(
        "repo mode is disabled on this deployment; POST the workflow `content` " +
          "directly, or enable it by setting the REPO_MODE_ENABLED variable",
        403,
      );
    }
    return await handleRepo(
      params, pathTarget, disable, type, useOsv, worker, forbidden, archived, format, env,
    );
  }
  if (!params.content) {
    throw new Error("missing `content` (or `repo`) parameter");
  }
  if (params.content.length > MAX_BODY_BYTES) {
    throw httpError(`content too large (max ${MAX_BODY_BYTES} bytes)`, 413);
  }
  const vuln = useOsv ? await fetchVulnUses(params.content, worker) : "";
  if (format === "sarif") {
    return {
      sarif: worker.lint_string_sarif(
        params.content, type, disable, vuln, forbidden, archived,
        sanitizePathLabel(params.path),
      ),
    };
  }
  return {
    ...JSON.parse(
      worker.lint_string(params.content, type, disable, vuln, forbidden, archived),
    ),
    online_audit_candidates: collectOnlineAuditCandidates(params.content),
  };
}

// `format=sarif` swaps the JSON envelope for a SARIF 2.1.0 document (#33).
// Absent / "" / "json" keep the envelope so existing callers are unaffected.
function parseFormat(raw) {
  if (raw == null || raw === "") return "json";
  if (typeof raw !== "string") {
    throw httpError("`format` must be a string", 400);
  }
  if (raw === "json" || raw === "sarif") return raw;
  throw httpError(
    `invalid format: ${truncatePreview(raw)} (expected 'json' or 'sarif')`,
    400,
  );
}

// Optional artifact label for `format=sarif` content mode — it becomes the
// SARIF `artifactLocation.uri`, so it must look like a safe relative path
// (same shape rules as repo-mode targets). Without it, results carry
// logical (job/step) locations only, which GitHub Code Scanning can't
// anchor to a file.
function sanitizePathLabel(raw) {
  if (raw == null || raw === "") return "";
  if (typeof raw !== "string") {
    throw httpError("`path` must be a string", 400);
  }
  validateTargetPath(raw);
  return raw;
}

// Read the KV-cached archived baseline, memoized per-isolate with a TTL.
// Fails open (empty list) so a KV outage never blocks linting.
function getArchivedList(env) {
  const now = Date.now();
  if (!_archivedPromise || now >= _archivedExpiresAt) {
    _archivedPromise = loadArchivedList(env).catch(() => []);
    _archivedExpiresAt = now + ARCHIVED_TTL_MS;
  }
  return _archivedPromise;
}

async function loadArchivedList(env) {
  if (!env?.KV) return [];
  const raw = await env.KV.get(ARCHIVED_KV_KEY);
  if (!raw) return [];
  try {
    const arr = JSON.parse(raw);
    return Array.isArray(arr) ? arr.filter((x) => typeof x === "string") : [];
  } catch {
    return [];
  }
}

// Reject overly long / numerous / multi-star `disable=` patterns. The matcher
// itself is linear, but limiting each pattern to at most one `*` keeps the
// API simple and rules out any future regression in the matcher.
function sanitizeDisable(raw) {
  if (raw == null || raw === "") return "";
  if (typeof raw !== "string") {
    throw httpError("`disable` must be a string", 400);
  }
  const pieces = raw
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (pieces.length === 0) return "";
  if (pieces.length > MAX_DISABLE_PATTERNS) {
    throw httpError(
      `too many disable patterns (max ${MAX_DISABLE_PATTERNS})`,
      400,
    );
  }
  for (const p of pieces) {
    if (p.length > MAX_DISABLE_PATTERN_LEN) {
      throw httpError(
        `disable pattern too long (max ${MAX_DISABLE_PATTERN_LEN} chars, got ${p.length}; starts: ${truncatePreview(p)})`,
        400,
      );
    }
    if (countChar(p, "*") > 1) {
      throw httpError(
        `disable pattern allows at most one '*' (got: ${truncatePreview(p)})`,
        400,
      );
    }
  }
  return pieces.join(",");
}

// Caller-supplied augmentation for `forbidden-uses` / `archived-uses`. The
// Worker does not fetch these itself — a caller (or the KV baseline) supplies
// them. Each is a comma-separated list; an empty/absent value leaves the rule
// on its offline baseline (see `worker/worker.mbt`).
function sanitizeUsesList(raw, label) {
  if (raw == null || raw === "") return "";
  if (typeof raw !== "string") {
    throw httpError(`\`${label}\` must be a string`, 400);
  }
  const pieces = raw
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (pieces.length === 0) return "";
  if (pieces.length > MAX_USES_ENTRIES) {
    throw httpError(
      `too many ${label} entries (max ${MAX_USES_ENTRIES})`,
      400,
    );
  }
  for (const p of pieces) {
    if (p.length > MAX_USES_ENTRY_LEN) {
      throw httpError(
        `${label} entry too long (max ${MAX_USES_ENTRY_LEN} chars, got ${p.length}; starts: ${truncatePreview(p)})`,
        400,
      );
    }
  }
  return pieces.join(",");
}

function truncatePreview(s) {
  const max = 32;
  return s.length <= max ? s : s.slice(0, max) + "…";
}

function countChar(s, ch) {
  let n = 0;
  for (let i = 0; i < s.length; i++) if (s[i] === ch) n++;
  return n;
}

// Reject target paths that could escape the pinned commit prefix once
// interpolated into `https://raw.githubusercontent.com/<repo>/<commit>/<path>`.
// `..` segments would be URL-normalized by fetch / GitHub's edge and let a
// caller fetch from a different ref entirely; `\` and absolute paths likewise
// undermine the prefix. We also reject `%` as defense-in-depth: even though
// the per-segment `encodeURIComponent` in `handleRepo` already neutralizes
// percent-encoded escapes like `%2e%2e%2f` (they become literal filename
// bytes), bailing out at validation time keeps the error clear instead of
// silently fetching a nonsense path.
function validateTargetPath(path) {
  if (typeof path !== "string" || path.length === 0) {
    throw httpError("target path must be a non-empty string", 400);
  }
  if (path.length > 256) {
    throw httpError(`target path too long (max 256 chars): ${truncatePreview(path)}`, 400);
  }
  if (path.startsWith("/") || path.includes("\\") || path.includes("%")) {
    throw httpError(`invalid target path: ${truncatePreview(path)}`, 400);
  }
  for (const seg of path.split("/")) {
    if (seg === "" || seg === "." || seg === "..") {
      throw httpError(`invalid target path: ${truncatePreview(path)}`, 400);
    }
  }
}

async function handleRepo(
  params, pathTarget, disable, type, useOsv, worker, forbidden, archived, format, env,
) {
  const repo = params.repo;
  if (typeof repo !== "string" || !/^[A-Za-z0-9_.\-]+\/[A-Za-z0-9_.\-]+$/.test(repo)) {
    throw httpError(`invalid repo: ${repo}`, 400);
  }

  const explicitTargets = collectTargets(params, pathTarget);
  // The ref the response echoes back; the fetch URL itself comes from `spec.url`
  // below. `isSha` gates whether we also echo `commit`. In discovery mode with
  // no ref supplied, `reportedRef` is "HEAD" (the default branch).
  let reportedRef;
  let isSha;
  let specs; // [{ path, url, size? }]
  let discoveredCount = 0;

  if (explicitTargets.length === 0) {
    // Whole-repo mode: no targets named, so discover every workflow under
    // `.github/workflows` on the chosen ref (default branch when none given).
    // This is the only code path that calls the GitHub API on the request hot
    // path — directory listing has no raw.githubusercontent equivalent.
    const resolved = refFromParams(params);
    const ref = resolved?.ref;
    isSha = resolved?.isSha ?? false;
    reportedRef = ref || "HEAD";
    const discovered = await discoverWorkflows(repo, ref, env);
    if (discovered.length === 0) {
      throw httpError(
        `no workflow files under \`${WORKFLOW_DIR}\` in ${repo}${ref ? ` @ ${ref}` : ""}`,
        404,
      );
    }
    discoveredCount = discovered.length;
    specs = discovered.slice(0, MAX_TARGETS);
  } else {
    // Explicit-target mode keeps the pin contract: a ref/commit is required.
    const resolved = resolveRef(params);
    reportedRef = resolved.ref;
    isSha = resolved.isSha;
    if (explicitTargets.length > MAX_TARGETS) {
      throw httpError(
        `too many targets (max ${MAX_TARGETS}, got ${explicitTargets.length})`,
        400,
      );
    }
    for (const path of explicitTargets) validateTargetPath(path);
    // Encode each segment so a `?` / `#` / `%` / space in a filename (or a
    // branch name) cannot be reinterpreted as a URL delimiter by fetch; keep
    // `/` as the segment separator so nested paths / slashy refs still resolve.
    const encodedRef = reportedRef.split("/").map(encodeURIComponent).join("/");
    specs = explicitTargets.map((path) => {
      const encodedPath = path.split("/").map(encodeURIComponent).join("/");
      return {
        path,
        url: `https://raw.githubusercontent.com/${repo}/${encodedRef}/${encodedPath}`,
      };
    });
  }

  // In SARIF mode the per-file lint runs inside `lint_files_sarif` so the
  // whole batch lands in one SARIF run; this loop only gathers inputs.
  // Fetch failures become `{path, error}` items there (the MoonBit side
  // turns them into tool execution notifications) instead of the envelope's
  // `{path, ok: false, error}` entries.
  const sarif = format === "sarif";
  const files = [];
  const sarifFiles = [];
  const pushFailure = (path, error) => {
    if (sarif) sarifFiles.push({ path, error });
    else files.push({ path, ok: false, error });
  };
  for (const spec of specs) {
    const { path } = spec;
    // `spec.size` is set in discovery mode (from the contents API listing);
    // short-circuit oversized files before fetching.
    if (Number.isFinite(spec.size) && spec.size > MAX_BODY_BYTES) {
      pushFailure(path, `file too large (${spec.size} > ${MAX_BODY_BYTES} bytes)`);
      continue;
    }
    // `spec.url` is the prebuilt raw URL (explicit targets) or the contents
    // API `download_url` (discovery); both are on raw.githubusercontent.com.
    const res = await fetch(spec.url, { headers: { "user-agent": "karinto-worker" } });
    if (!res.ok) {
      pushFailure(path, `GET raw → ${res.status}`);
      continue;
    }
    const cl = Number(res.headers.get("content-length"));
    if (Number.isFinite(cl) && cl > MAX_BODY_BYTES) {
      pushFailure(path, `file too large (${cl} > ${MAX_BODY_BYTES} bytes)`);
      continue;
    }
    let raw;
    try {
      raw = await readBoundedResponse(res);
    } catch (e) {
      pushFailure(path, String(e?.message ?? e));
      continue;
    }
    const guessKind = type || guessKindFromPath(path);
    const vuln = useOsv ? await fetchVulnUses(raw, worker) : "";
    if (sarif) {
      sarifFiles.push({ path, content: raw, kind: guessKind, vuln });
      continue;
    }
    files.push({
      path,
      ...JSON.parse(
        worker.lint_string(raw, guessKind, disable, vuln, forbidden, archived),
      ),
      online_audit_candidates: collectOnlineAuditCandidates(raw),
    });
  }
  if (sarif) {
    return {
      sarif: worker.lint_files_sarif(
        JSON.stringify(sarifFiles), disable, forbidden, archived,
      ),
    };
  }
  return {
    ok: files.every((f) => f.ok !== false),
    repo,
    ref: reportedRef,
    // Echo `commit` only for an immutable SHA pin, so callers can keep keying
    // off it; for a mutable branch/tag/HEAD ref there is no resolved SHA on the
    // hot path (the Worker never calls the GitHub API for content), so `ref` is
    // the only handle.
    ...(isSha ? { commit: reportedRef } : {}),
    targets: specs.map((s) => s.path),
    // Signal when discovery found more workflows than the per-request cap so a
    // caller knows the result is partial rather than the whole default branch.
    ...(discoveredCount > specs.length
      ? { truncated: true, discovered: discoveredCount }
      : {}),
    files,
  };
}

// The directory karinto enumerates in whole-repo (discovery) mode. GitHub only
// runs workflows defined directly here, so this is the complete set.
const WORKFLOW_DIR = ".github/workflows";

// Build the working set of literal target paths from `targets=` or the URL
// path. Returns `[]` when none are supplied (→ whole-repo discovery mode).
function collectTargets(params, pathTarget) {
  if (Object.prototype.hasOwnProperty.call(params, "targets")) {
    const rawTargets = params.targets ?? "";
    if (typeof rawTargets !== "string") {
      throw httpError("`targets` must be a string", 400);
    }
    const parsed = rawTargets
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean);
    // A present-but-empty `targets=` (blank, or only whitespace/commas) is
    // almost always an un-filled template, not an intent to scan the whole
    // repo. Treating it as discovery would silently spend the GitHub API /
    // rate-limit budget, so reject it: whole-repo discovery is opted into by
    // *omitting* `targets` entirely (see README *Whole-repo mode*).
    if (parsed.length === 0) {
      throw httpError(
        "`targets=` is present but empty; supply at least one path, or omit " +
          "`targets` entirely to lint the whole repo's workflows",
        400,
      );
    }
    return parsed;
  }
  return pathTarget ? [pathTarget] : [];
}

// List every `*.yml` / `*.yaml` workflow under `.github/workflows` at `ref`
// (the repo's default branch when `ref` is undefined) via the GitHub contents
// API. This is the one place the Worker calls the GitHub API on the request
// path; it fails loudly (with an actionable message) on rate-limit / outage so
// the caller can fall back to explicit `targets=`. A `GITHUB_PUBLIC_READ_TOKEN`
// binding, when present, raises the unauthenticated 60 req/hour/IP ceiling to
// 5000/hour.
async function discoverWorkflows(repo, ref, env) {
  const refQuery = ref ? `?ref=${encodeURIComponent(ref)}` : "";
  const url = `https://api.github.com/repos/${repo}/contents/${WORKFLOW_DIR}${refQuery}`;
  let res;
  try {
    res = await fetch(url, { headers: githubApiHeaders(env) });
  } catch (e) {
    throw httpError(`GitHub API request failed: ${String(e?.message ?? e)}`, 502);
  }
  if (res.status === 404) {
    throw httpError(
      `no \`${WORKFLOW_DIR}\` directory in ${repo}${ref ? ` @ ${ref}` : ""}`,
      404,
    );
  }
  // 429, or a 403 carrying the rate-limit signal (`x-ratelimit-remaining: 0`
  // or a `retry-after` header), means "back off" — surface a 429 with the
  // escape hatches. GitHub also returns 403 for non-rate-limit cases (a private
  // repo the token can't see, blocked/forbidden content), so a 403 *without*
  // that signal is a real permission error and must not masquerade as a rate
  // limit (that would send callers chasing the wrong fix).
  const rateLimited =
    res.status === 429 ||
    (res.status === 403 &&
      (res.headers.get("x-ratelimit-remaining") === "0" ||
        res.headers.get("retry-after") != null));
  if (rateLimited) {
    throw httpError(
      "GitHub API rate limit reached while listing workflows; retry later, " +
        "pass explicit `targets=`, or deploy with a GITHUB_PUBLIC_READ_TOKEN",
      429,
    );
  }
  if (res.status === 403) {
    throw httpError(
      `GitHub contents API → 403 while listing workflows in ${repo}; the repo ` +
        "may be private or the GITHUB_PUBLIC_READ_TOKEN lacks access to it",
      403,
    );
  }
  if (!res.ok) {
    throw httpError(`GitHub contents API → ${res.status}`, 502);
  }
  let list;
  try {
    list = await res.json();
  } catch {
    throw httpError("GitHub contents API returned non-JSON", 502);
  }
  if (!Array.isArray(list)) {
    // A path that resolves to a file (not a directory) comes back as an object.
    throw httpError(`\`${WORKFLOW_DIR}\` is not a directory in ${repo}`, 422);
  }
  return list
    .filter(
      (e) =>
        e &&
        e.type === "file" &&
        typeof e.download_url === "string" &&
        typeof e.path === "string" &&
        /\.ya?ml$/i.test(e.name || ""),
    )
    .map((e) => ({ path: e.path, url: e.download_url, size: Number(e.size) }))
    // Deterministic order so the response (and any downstream diffing) is stable.
    .sort((a, b) => a.path.localeCompare(b.path));
}

function githubApiHeaders(env) {
  const headers = {
    "user-agent": "karinto-worker",
    accept: "application/vnd.github+json",
  };
  if (env?.GITHUB_PUBLIC_READ_TOKEN) {
    headers.authorization = `Bearer ${env.GITHUB_PUBLIC_READ_TOKEN}`;
  }
  return headers;
}

// Required-ref resolution for explicit-target mode. Delegates to
// `refFromParams` and rejects the "neither supplied" case.
function resolveRef(params) {
  const resolved = refFromParams(params);
  if (!resolved) {
    throw new Error(
      "`commit` or `ref` is required with `repo` (commit SHA, or `ref=` for a branch/tag/HEAD)",
    );
  }
  return resolved;
}

// Resolve the git ref to fetch from. `ref` (branch / tag / `HEAD` / SHA) takes
// precedence over `commit` (SHA-only pin). Returns `{ ref, isSha }`, or `null`
// when neither is supplied (or both are blank) — the caller decides whether
// that is an error (explicit targets) or the default-branch case (discovery).
function refFromParams(params) {
  if (params.ref !== undefined) {
    if (typeof params.ref !== "string") {
      throw httpError("`ref` must be a string", 400);
    }
    const ref = params.ref.trim();
    if (!ref) return null; // `ref=` → default branch
    validateRef(ref);
    return { ref, isSha: /^[0-9a-fA-F]{7,64}$/.test(ref) };
  }
  if (params.commit !== undefined && typeof params.commit !== "string") {
    throw httpError("`commit` must be a string", 400);
  }
  const commit = (params.commit || "").trim();
  if (!commit) return null;
  // `commit` is SHA-only by contract (an immutable pin). Accept the same range
  // Git uses for abbreviated SHAs (7-64 hex). An all-hex value of this shape
  // could technically collide with a branch/tag of the same name (e.g.
  // `deadbee`); we accept that trade-off for ergonomics. Branch/tag refs go
  // through `ref=` so the SHA-pin guarantee here stays unambiguous.
  if (!/^[0-9a-fA-F]{7,64}$/.test(commit)) {
    throw new Error(
      `invalid commit: ${commit} (expected 7-64 hex characters; use \`ref=\` for a branch/tag name)`,
    );
  }
  return { ref: commit, isSha: true };
}

// Validate a git ref before it is interpolated into
// `https://raw.githubusercontent.com/<repo>/<ref>/<path>`. Mirrors
// `validateTargetPath`: reject anything that could escape the ref into a
// different path (`..`, leading/trailing `/`, `\`, `%`) and restrict to the
// characters git permits in ref names (the charset already rules out space /
// `~^:?*[` and other delimiters).
function validateRef(ref) {
  if (ref.length > 256) {
    throw httpError(`ref too long (max 256 chars): ${truncatePreview(ref)}`, 400);
  }
  if (
    ref.startsWith("/") ||
    ref.endsWith("/") ||
    ref.includes("..") ||
    ref.includes("\\") ||
    ref.includes("%") ||
    !/^[A-Za-z0-9._/-]+$/.test(ref)
  ) {
    throw httpError(`invalid ref: ${truncatePreview(ref)}`, 400);
  }
  for (const seg of ref.split("/")) {
    if (seg === "" || seg === "." || seg === "..") {
      throw httpError(`invalid ref: ${truncatePreview(ref)}`, 400);
    }
  }
}

function isTrue(v) {
  if (!v) return false;
  const s = String(v).toLowerCase();
  return s === "1" || s === "true" || s === "yes" || s === "on";
}

// Extract every `uses: owner/repo[/subpath]@ref` reference (excluding local
// `./` and `docker://` forms) and ask OSV.dev whether any are listed in a
// security advisory. OSV's GitHub Actions ecosystem doesn't filter by version
// server-side, so we collect the advisory ranges here and let MoonBit's
// `osv_match` apply them against the user's tags. Fails open: a network or
// schema error yields "" so linting still works.
const USES_RE = /^\s*-?\s*uses:\s*["']?([^"'\s#]+)["']?\s*(?:#.*)?$/gm;

async function fetchVulnUses(yaml, worker) {
  const refs = collectUsesRefs(yaml);
  if (refs.length === 0) return "";

  const uniqueActions = [...new Set(refs.map((r) => r.name))];
  const queries = uniqueActions.map((name) => ({
    package: { ecosystem: "GitHub Actions", name },
  }));

  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 2500);
    const res = await fetch("https://api.osv.dev/v1/querybatch", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ queries }),
      signal: ctrl.signal,
    });
    clearTimeout(timer);
    if (!res.ok) return "";
    const data = await res.json();
    if (!Array.isArray(data?.results)) return "";

    // Build action → advisory ranges map. `querybatch` returns only IDs;
    // each advisory's `affected.ranges` ship via `/v1/vulns/{id}`.
    const advisories = {};
    const idActions = new Map();
    for (let i = 0; i < uniqueActions.length; i++) {
      const ids = (data.results[i]?.vulns ?? []).map((v) => v.id).filter(Boolean);
      for (const id of ids) idActions.set(id, uniqueActions[i]);
    }
    if (idActions.size === 0) return "";

    await Promise.all(
      [...idActions.entries()].map(async ([id, _]) => {
        const r = await fetch(`https://api.osv.dev/v1/vulns/${id}`);
        if (!r.ok) return;
        const v = await r.json();
        for (const a of v.affected ?? []) {
          if (a.package?.ecosystem !== "GitHub Actions") continue;
          const name = a.package.name;
          for (const rg of a.ranges ?? []) {
            if (rg.type !== "ECOSYSTEM") continue;
            (advisories[name] ??= []).push({ events: rg.events ?? [] });
          }
        }
      }),
    );

    const usesCsv = refs.map((r) => r.original).join(",");
    return worker.osv_match(usesCsv, JSON.stringify(advisories));
  } catch {
    return "";
  }
}

function collectUsesRefs(yaml) {
  const out = [];
  const seen = new Set();
  for (const match of yaml.matchAll(USES_RE)) {
    const ref = match[1];
    if (!ref || ref.startsWith("./") || ref.startsWith("docker://")) continue;
    const at = ref.lastIndexOf("@");
    if (at < 0) continue;
    const fullName = ref.slice(0, at);
    const version = ref.slice(at + 1);
    if (!fullName || !version) continue;
    // OSV uses the action repo (owner/name), strip any reusable-workflow path.
    const slash = fullName.indexOf("/", fullName.indexOf("/") + 1);
    const name = slash > 0 ? fullName.slice(0, slash) : fullName;
    const key = `${ref}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({ name, version, original: ref });
  }
  return out;
}

// Like USES_RE but also captures any trailing `# comment`, which the companion
// action needs for `ref-version-mismatch` (the comment names the version the
// pinned SHA is supposed to be).
const USES_WITH_COMMENT_RE =
  /^\s*-?\s*uses:\s*["']?([^"'\s#]+)["']?\s*(?:#\s*(.*?))?\s*$/gm;

// Every external `uses:` ref, classified for two consumers:
//   1. the companion action, which audits the SHA-pinned ones
//      (`impostor-commit`: SHA repo-membership; `ref-version-mismatch`:
//      tag → SHA vs. the trailing comment) and reports directly;
//   2. `candidateRepos`, which feeds the archived-uses worklist.
// `pin` is `"sha"` for a 7–40 hex pin (the companion's audit candidates) or
// `"tag"` otherwise; `comment`, when present, is the trailing `# vN` text.
// Tag-pinned entries are intentionally included: archived actions are usually
// referenced by tag (e.g. `actions/setup-ruby@v1`), so dropping them would
// hide the common case from the archived sweep. The companion just skips
// non-`sha` entries.
function collectOnlineAuditCandidates(yaml) {
  const out = [];
  const seen = new Set();
  for (const match of yaml.matchAll(USES_WITH_COMMENT_RE)) {
    const ref = match[1];
    if (!ref || ref.startsWith("./") || ref.startsWith("docker://")) continue;
    const at = ref.lastIndexOf("@");
    if (at < 0) continue;
    const name = ref.slice(0, at);
    const rev = ref.slice(at + 1);
    if (!name || !rev) continue;
    if (seen.has(ref)) continue;
    seen.add(ref);
    const entry = {
      ref,
      name,
      pin: /^[0-9a-f]{7,40}$/i.test(rev) ? "sha" : "tag",
    };
    const comment = (match[2] || "").trim();
    if (comment) entry.comment = comment;
    out.push(entry);
  }
  return out;
}

function guessKindFromPath(path) {
  // GitHub runs every YAML under `.github/workflows/` as a workflow whatever
  // its basename (even `action.yml`), so match that path segment first — then
  // treat only an exact `action.yml`/`action.yaml` basename as an action, not
  // any `*action.yml` (e.g. a `release-action.yml` workflow). Mirrors the CLI's
  // `kind_from_path` and ghalint's path globs (`^\.github/workflows/.*\.ya?ml$`
  // for workflows, `action.ya?ml` basenames for actions).
  if (path.startsWith(".github/workflows/") || path.includes("/.github/workflows/")) {
    return "workflow";
  }
  if (path.startsWith(".github/dependabot.") || path.includes("/.github/dependabot.")) {
    return "dependabot";
  }
  const basename = path.slice(path.lastIndexOf("/") + 1);
  if (basename === "action.yml" || basename === "action.yaml") return "action";
  return "";
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      // Public, credential-less API — allow browser-based clients (e.g. the
      // GitHub Pages playground at docs/index.html) to read the response.
      "access-control-allow-origin": "*",
    },
  });
}

// `format=sarif` body — already a serialized SARIF 2.1.0 document.
function sarifResponse(body) {
  return new Response(body, {
    status: 200,
    headers: {
      "content-type": "application/sarif+json; charset=utf-8",
      "access-control-allow-origin": "*",
    },
  });
}

// Dark-launch capture: persist successful prod requests + their canonical
// response to R2 so PR Workers can replay them and diff for regressions.
// Only runs when `env.CAPTURES` is bound (production env). Skipped for:
//   - `osv=1` (external state),
//   - `repo` mode (external GitHub state),
//   - content > CAPTURE_CONTENT_LIMIT_KIB (free-tier hygiene; default 100),
//   - opt-out via `no_capture=1` param or `X-Karinto-No-Capture` header.
const DEFAULT_CAPTURE_CONTENT_LIMIT_KIB = 100;

// Numeric tuning vars come in from wrangler `--var` as strings. Treat
// missing / non-finite / non-positive values as "use the default" so a
// malformed GitHub variable can't silently disable the guard.
function positiveNumber(raw, fallback) {
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

async function captureRequest(env, params, result, headers) {
  if (!env?.CAPTURES) return;
  if (isTrue(params.osv)) return;
  if (params.repo) return;
  if (!params.content) return;
  if (!result?.ok) return;
  // Opt-out checks run before the TextEncoder pass so opted-out requests
  // (replay traffic, callers that pass `no_capture=1` or
  // `x-karinto-no-capture`) skip the byte-length encode entirely on the
  // hot path.
  if (isTrue(params.no_capture)) return;
  if (isTrue(headers?.get("x-karinto-no-capture"))) return;
  const limitKib = positiveNumber(env.CAPTURE_CONTENT_LIMIT_KIB, DEFAULT_CAPTURE_CONTENT_LIMIT_KIB);
  // length counts UTF-16 code units; capture size is determined by UTF-8
  // bytes, so non-ASCII YAML would otherwise sneak past the limit.
  const byteLen = new TextEncoder().encode(params.content).byteLength;
  if (byteLen > limitKib * 1024) return;

  const normalized = normalizeRequest(params);
  const hash = await sha256Hex(JSON.stringify(normalized));
  const key = `captures/${hash}.json`;

  const payload = JSON.stringify({
    request: normalized,
    response: result,
    first_seen: new Date().toISOString(),
  });

  // R2's `put` with `onlyIf: etagDoesNotMatch: "*"` returns `null` (no throw)
  // when the precondition fails because the key already exists. That's the
  // expected dedup path — same normalized request was seen before — so we
  // don't log it. Real put errors still surface via the caller's `.catch`.
  await env.CAPTURES.put(key, payload, {
    onlyIf: { etagDoesNotMatch: "*" },
    httpMetadata: { contentType: "application/json" },
  });
}

function normalizeRequest(params) {
  const out = { content: params.content };
  if (params.type) out.type = params.type;
  if (params.disable) out.disable = normalizeCsvField(params.disable);
  // Caller-supplied augmentation changes the verdict, so capture it too or a
  // replay would diverge from the original response. (The KV-cached archived
  // baseline is intentionally NOT captured — it is a moving server-side input,
  // not part of the request.)
  if (params.forbidden) out.forbidden = normalizeCsvField(params.forbidden);
  if (params.archived) out.archived = normalizeCsvField(params.archived);
  return out;
}

function normalizeCsvField(raw) {
  return raw
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .sort()
    .join(",");
}

async function sha256Hex(str) {
  const buf = new TextEncoder().encode(str);
  const digest = await crypto.subtle.digest("SHA-256", buf);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function log(event, data) {
  // Cloudflare Workers ships console.log to `wrangler tail`.
  console.log(JSON.stringify({ event, time: new Date().toISOString(), ...data }));
}
