// Cloudflare Workers entry point for karinto.
//
// Accepts GET or POST. Parameters can come from the URL path
// (`/owner/repo/commit[/target]`), the URL query string, the request body
// (raw `key=value&...`, JSON, or a YAML blob as the whole body), or a mix
// of all three. Body > query > path on conflicts.
//
// Keys:
//   - type      "workflow" | "action" | "" (auto-detect, default)
//   - content   YAML source
//   - disable   comma-separated rule-ID glob patterns to skip
//   - repo      "owner/name" — fetch files from a public GitHub repo
//   - commit    commit SHA (7-64 hex chars); required whenever `repo` is set
//   - targets   comma-separated literal paths (required with `repo`)
//   - osv       "1" / "true" → query OSV.dev for known-vulnerable actions
//               (adds ~50-300ms latency depending on action count)
//
// The handler logs a one-line JSON record per request to stdout.
//
// YAML parsing is delegated to the MoonBit engine (`@moonbit-community/yaml`).
// When the YAML is malformed the engine returns a `parse_error` field which
// the handler propagates verbatim.

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

export default {
  async fetch(request, env, ctx) {
    const started = Date.now();
    try {
      await enforceRateLimit(request, env, ctx);
      const params = await readParams(request);
      const result = await handle(params, env);
      const elapsed = Date.now() - started;
      log("request", {
        method: request.method,
        type: params.type || "(auto)",
        disable: params.disable || "",
        repo: params.repo || "",
        commit: params.commit || "",
        targets: Object.prototype.hasOwnProperty.call(params, "targets")
          ? String(params.targets ?? "")
          : params._pathTarget || "",
        content_lines: params.content ? params.content.split("\n").length : 0,
        files: result.files?.length ?? (params.content ? 1 : 0),
        elapsed_ms: elapsed,
      });
      return json(result);
    } catch (err) {
      const status = err?.status ?? 400;
      log("error", { status, message: String(err?.message ?? err) });
      return json({ ok: false, error: String(err?.message ?? err) }, status);
    }
  },

  // Daily cron — refresh the GitHub Actions IP allow-list so per-IP rate
  // limiting can exempt CI traffic. On fetch failure we leave whatever is
  // already in KV; the request path falls back to a direct fetch if KV
  // is empty (e.g. immediately after a fresh deploy).
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
  const params = {};
  Object.assign(params, parsePath(url.pathname));
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
  return params;
}

// `/owner/repo/commit[/target/...]` → `{ repo, commit, _pathTarget? }`.
// Segments after the commit are joined as a single target path (so nested
// paths like `.github/workflows/ci.yml` work) and stored under a private
// key, so a literal `,` in the path is not split into multiple targets the
// way the comma-delimited `targets=` field is. Multi-target requests still
// need to come through `targets=` query/body.
//
// Only paths that look like the repo-mode pattern are interpreted; anything
// else (e.g. `/favicon.ico`, a deploy prefix `/api/karinto/...`) is left to
// the regular content/repo body parameters. This keeps the Worker mountable
// under arbitrary path prefixes without bricking unrelated requests.
function parsePath(pathname) {
  const segments = pathname.split("/").filter(Boolean).map((s) => decodeURIComponent(s));
  if (segments.length < 3) return {};
  const [owner, repo, commit, ...rest] = segments;
  if (!/^[A-Za-z0-9_.\-]+$/.test(owner) || !/^[A-Za-z0-9_.\-]+$/.test(repo)) return {};
  if (!/^[0-9a-fA-F]{7,64}$/.test(commit)) return {};
  const out = { repo: `${owner}/${repo}`, commit };
  if (rest.length > 0) out._pathTarget = rest.join("/");
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
  "targets",
  "osv",
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
  // Try form-encoded only when at least one known key appears as `key=...`.
  if (KNOWN_KEYS_RE.test(raw)) {
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

const KNOWN_KEYS_RE = /(^|&)(content|type|disable|repo|commit|targets|osv)=/;

async function handle(params, env) {
  const disable = sanitizeDisable(params.disable ?? "");
  const type = params.type || "";
  const useOsv = isTrue(params.osv);
  const worker = await getWorker();

  if (params.repo) {
    return await handleRepo(params, disable, type, useOsv, worker);
  }
  if (!params.content) {
    throw new Error("missing `content` (or `repo`) parameter");
  }
  if (params.content.length > MAX_BODY_BYTES) {
    throw httpError(`content too large (max ${MAX_BODY_BYTES} bytes)`, 413);
  }
  const vuln = useOsv ? await fetchVulnUses(params.content, worker) : "";
  return JSON.parse(worker.lint_string(params.content, type, disable, vuln));
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
// undermine the prefix. We also reject `%` so percent-encoded variants like
// `%2e%2e%2f` can't bypass the segment check (path-from-path-prefix is already
// decoded, path-from-body/query is forwarded verbatim into the URL — easier
// to disallow `%` outright than to track two normalization layers).
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

async function handleRepo(params, disable, type, useOsv, worker) {
  const repo = params.repo;
  if (typeof repo !== "string" || !/^[A-Za-z0-9_.\-]+\/[A-Za-z0-9_.\-]+$/.test(repo)) {
    throw httpError(`invalid repo: ${repo}`, 400);
  }
  const commit = params.commit || "";
  if (!commit) {
    throw new Error("`commit` is required with `repo` (commit SHA, full or abbreviated)");
  }
  // Accept the same range Git itself uses for abbreviated SHAs (7-64 hex).
  // An all-hex value of this shape could technically collide with a branch
  // or tag of the same name (e.g. `deadbee`); we accept that trade-off for
  // ergonomics. Callers who need ironclad immutability should pass the full
  // 40-char SHA.
  if (!/^[0-9a-fA-F]{7,64}$/.test(commit)) {
    throw new Error(`invalid commit: ${commit} (expected 7-64 hex characters)`);
  }
  let targets;
  if (Object.prototype.hasOwnProperty.call(params, "targets")) {
    const rawTargets = params.targets ?? "";
    if (typeof rawTargets !== "string") {
      throw httpError("`targets` must be a string", 400);
    }
    targets = rawTargets
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean);
  } else if (params._pathTarget) {
    targets = [params._pathTarget];
  } else {
    targets = [];
  }
  if (targets.length === 0) {
    throw new Error("`targets` is required with `repo` (comma-separated literal paths)");
  }
  if (targets.length > MAX_TARGETS) {
    throw httpError(
      `too many targets (max ${MAX_TARGETS}, got ${targets.length})`,
      400,
    );
  }
  for (const path of targets) validateTargetPath(path);

  const files = [];
  for (const path of targets) {
    const url = `https://raw.githubusercontent.com/${repo}/${commit}/${path}`;
    const res = await fetch(url, { headers: { "user-agent": "karinto-worker" } });
    if (!res.ok) {
      files.push({ path, ok: false, error: `GET raw → ${res.status}` });
      continue;
    }
    const cl = Number(res.headers.get("content-length"));
    if (Number.isFinite(cl) && cl > MAX_BODY_BYTES) {
      files.push({ path, ok: false, error: `file too large (${cl} > ${MAX_BODY_BYTES} bytes)` });
      continue;
    }
    let raw;
    try {
      raw = await readBoundedResponse(res);
    } catch (e) {
      files.push({ path, ok: false, error: String(e?.message ?? e) });
      continue;
    }
    const guessKind = type || guessKindFromPath(path);
    const vuln = useOsv ? await fetchVulnUses(raw, worker) : "";
    files.push({ path, ...JSON.parse(worker.lint_string(raw, guessKind, disable, vuln)) });
  }
  return {
    ok: files.every((f) => f.ok !== false),
    repo,
    commit,
    targets,
    files,
  };
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

function guessKindFromPath(path) {
  if (path.endsWith("action.yml") || path.endsWith("action.yaml")) return "action";
  if (path.startsWith(".github/workflows/")) return "workflow";
  return "";
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function log(event, data) {
  // Cloudflare Workers ships console.log to `wrangler tail`.
  console.log(JSON.stringify({ event, time: new Date().toISOString(), ...data }));
}
