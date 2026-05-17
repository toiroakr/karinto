// Cloudflare Workers entry point for curllint.
//
// Accepts GET or POST. Parameters can come from the URL query string,
// the request body (raw `key=value&...`, JSON, or a YAML blob as the whole
// body), or a mix of both.
//
// Keys:
//   - type      "workflow" | "action" | "" (auto-detect, default)
//   - content   YAML source
//   - disable   comma-separated rule-ID glob patterns to skip
//   - repo      "owner/name" — fetch files from a public GitHub repo
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

export default {
  async fetch(request, env, ctx) {
    const started = Date.now();
    try {
      const params = await readParams(request);
      const result = await handle(params, env);
      const elapsed = Date.now() - started;
      log("request", {
        method: request.method,
        type: params.type || "(auto)",
        disable: params.disable || "",
        repo: params.repo || "",
        targets: params.targets || "",
        content_lines: params.content ? params.content.split("\n").length : 0,
        files: result.files?.length ?? (params.content ? 1 : 0),
        elapsed_ms: elapsed,
      });
      return json(result);
    } catch (err) {
      log("error", { message: String(err?.message ?? err) });
      return json({ ok: false, error: String(err?.message ?? err) }, 400);
    }
  },
};

async function readParams(request) {
  const url = new URL(request.url);
  const params = {};
  for (const [k, v] of url.searchParams) params[k] = v;

  if (request.method !== "GET" && request.method !== "HEAD") {
    const ct = request.headers.get("content-type") || "";
    const raw = await request.text();
    if (raw) mergeBody(params, raw, ct);
  } else if (request.method === "GET" && request.body) {
    // curl --data-urlencode + GET also sends a body.
    const raw = await request.text();
    if (raw) mergeBody(params, raw, request.headers.get("content-type") || "");
  }
  return params;
}

const KNOWN_KEYS = new Set(["content", "type", "disable", "repo", "targets", "osv"]);

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

const KNOWN_KEYS_RE = /(^|&)(content|type|disable|repo|targets|osv)=/;

async function handle(params, env) {
  const disable = params.disable || "";
  const type = params.type || "";
  const useOsv = isTrue(params.osv);
  const worker = await getWorker();

  if (params.repo) {
    return await handleRepo(params, disable, type, useOsv, worker);
  }
  if (!params.content) {
    throw new Error("missing `content` (or `repo`) parameter");
  }
  const vuln = useOsv ? await fetchVulnUses(params.content, worker) : "";
  return JSON.parse(worker.lint_string(params.content, type, disable, vuln));
}

async function handleRepo(params, disable, type, useOsv, worker) {
  const repo = params.repo;
  if (!/^[A-Za-z0-9_.\-]+\/[A-Za-z0-9_.\-]+$/.test(repo)) {
    throw new Error(`invalid repo: ${repo}`);
  }
  const targets = (params.targets || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (targets.length === 0) {
    throw new Error("`targets` is required with `repo` (comma-separated literal paths)");
  }

  const files = [];
  for (const path of targets.slice(0, 50)) {
    const url = `https://raw.githubusercontent.com/${repo}/HEAD/${path}`;
    const res = await fetch(url, { headers: { "user-agent": "curllint-worker" } });
    if (!res.ok) {
      files.push({ path, ok: false, error: `GET raw → ${res.status}` });
      continue;
    }
    const raw = await res.text();
    const guessKind = type || guessKindFromPath(path);
    const vuln = useOsv ? await fetchVulnUses(raw, worker) : "";
    files.push({ path, ...JSON.parse(worker.lint_string(raw, guessKind, disable, vuln)) });
  }
  return {
    ok: files.every((f) => f.ok !== false),
    repo,
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
