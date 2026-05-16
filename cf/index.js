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
//   - repo      "owner/name" — fetch workflow files from a public GitHub repo
//   - targets   comma-separated path globs (used with `repo`)
//
// The handler logs a one-line JSON record per request to stdout.

import jsYaml from "js-yaml";

// MoonBit's compiled JS seeds a hashmap RNG at module load via
// `crypto.getRandomValues`, which CF Workers forbids in global scope. Defer
// the import until the first request so it runs inside a handler.
let _lintStringPromise;
function getLintString() {
  if (!_lintStringPromise) {
    _lintStringPromise = import("../_build/js/release/build/worker/worker.js")
      .then((m) => m.lint_string);
  }
  return _lintStringPromise;
}

const DEFAULT_TARGETS = [".github/workflows/*.yml", ".github/workflows/*.yaml"];

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

const KNOWN_KEYS = new Set(["content", "type", "disable", "repo", "targets"]);

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

const KNOWN_KEYS_RE = /(^|&)(content|type|disable|repo|targets)=/;

async function handle(params, env) {
  const disable = params.disable || "";
  const type = params.type || "";
  const lint_string = await getLintString();

  if (params.repo) {
    return await handleRepo(params, disable, type, lint_string);
  }
  if (!params.content) {
    throw new Error("missing `content` (or `repo`) parameter");
  }
  // Validate YAML up-front via js-yaml so we can return better errors,
  // but pass the *original* text to MoonBit so positions stay meaningful.
  try {
    jsYaml.loadAll(params.content);
  } catch (e) {
    return {
      ok: false,
      parse_error: `yaml parse error: ${e.message}`,
      result: null,
    };
  }
  const text = lint_string(params.content, type, disable);
  return JSON.parse(text);
}

async function handleRepo(params, disable, type, lint_string) {
  const repo = params.repo;
  const targets = (params.targets || DEFAULT_TARGETS.join(","))
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (!/^[A-Za-z0-9_.\-]+\/[A-Za-z0-9_.\-]+$/.test(repo)) {
    throw new Error(`invalid repo: ${repo}`);
  }
  // Discover files via the GitHub Trees API (public repos, no token).
  const tree = await ghFetch(
    `https://api.github.com/repos/${repo}/git/trees/HEAD?recursive=1`,
  );
  if (!tree.tree) throw new Error(`failed to fetch tree for ${repo}`);
  const matched = tree.tree
    .filter((node) => node.type === "blob")
    .filter((node) => targets.some((g) => globMatch(g, node.path)));

  const files = [];
  for (const node of matched.slice(0, 50)) {
    const raw = await ghFetchText(
      `https://raw.githubusercontent.com/${repo}/HEAD/${node.path}`,
    );
    const guessKind = type || guessKindFromPath(node.path);
    let body;
    try {
      jsYaml.loadAll(raw);
      body = JSON.parse(lint_string(raw, guessKind, disable));
    } catch (e) {
      body = { ok: false, parse_error: `yaml parse error: ${e.message}` };
    }
    files.push({ path: node.path, ...body });
  }
  return {
    ok: files.every((f) => f.ok !== false),
    repo,
    targets,
    files,
  };
}

function guessKindFromPath(path) {
  if (path.endsWith("action.yml") || path.endsWith("action.yaml")) return "action";
  if (path.startsWith(".github/workflows/")) return "workflow";
  return "";
}

async function ghFetch(url) {
  const res = await fetch(url, {
    headers: {
      "user-agent": "curllint-worker",
      accept: "application/vnd.github+json",
    },
  });
  if (!res.ok) throw new Error(`GET ${url} → ${res.status}`);
  return await res.json();
}

async function ghFetchText(url) {
  const res = await fetch(url, { headers: { "user-agent": "curllint-worker" } });
  if (!res.ok) throw new Error(`GET ${url} → ${res.status}`);
  return await res.text();
}

function globMatch(pattern, str) {
  // Convert simple glob (`*`, `?`) to RegExp.
  const re = new RegExp(
    "^" +
      pattern
        .split(/(\*\*|\*|\?)/)
        .map((part) => {
          if (part === "**") return ".*";
          if (part === "*") return "[^/]*";
          if (part === "?") return "[^/]";
          return part.replace(/[.+^${}()|[\]\\]/g, "\\$&");
        })
        .join("") +
      "$",
  );
  return re.test(str);
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
