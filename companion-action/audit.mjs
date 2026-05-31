// Companion to karinto for the two audits that need live GitHub API access:
//
//   - impostor-commit      : a `uses: owner/repo@<sha>` whose SHA does not
//                            belong to `owner/repo` (it only exists in a fork).
//   - ref-version-mismatch : a `uses: owner/repo@<sha> # vN` whose pinned SHA
//                            does not match the tag `vN` of `owner/repo`.
//
// karinto extracts the candidate refs (`online_audit_candidates`) but does not
// resolve them — that is delegated here. This is a reference implementation:
// it reports findings directly as GitHub Actions annotations and sets the job
// status per `FAIL_ON`. The impostor check verifies the pinned SHA is
// *reachable* from one of `owner/repo`'s own refs (see `classifyCommit`);
// zizmor's audit is the rigorous reference if you need exact parity.

import { readFile, readdir } from "node:fs/promises";
import path from "node:path";

const KARINTO_URL = process.env.KARINTO_URL || "https://karinto.toiroakr.workers.dev";
const TOKEN = process.env.GH_TOKEN || "";
// Validate fail-on so a typo (e.g. "errors") can't silently mean "never fail".
const FAIL_ON_VALUES = ["error", "warning", "none"];
const FAIL_ON_RAW = (process.env.FAIL_ON || "error").toLowerCase();
const FAIL_ON = FAIL_ON_VALUES.includes(FAIL_ON_RAW) ? FAIL_ON_RAW : "error";
if (FAIL_ON !== FAIL_ON_RAW) {
  console.log(
    `::warning::karinto-companion: unknown fail-on "${FAIL_ON_RAW}" — ` +
      `expected one of ${FAIL_ON_VALUES.join(", ")}; defaulting to "error"`,
  );
}

const GH_HEADERS = {
  "user-agent": "karinto-companion",
  accept: "application/vnd.github+json",
  ...(TOKEN ? { authorization: `Bearer ${TOKEN}` } : {}),
};

async function listWorkflowFiles() {
  const dir = ".github/workflows";
  try {
    const names = await readdir(dir);
    return names
      .filter((n) => n.endsWith(".yml") || n.endsWith(".yaml"))
      .map((n) => path.join(dir, n));
  } catch {
    return [];
  }
}

function resolveFiles() {
  const raw = (process.env.FILES || "").trim();
  if (!raw) return listWorkflowFiles();
  return Promise.resolve(
    raw
      .split(/[\n,]/)
      .map((s) => s.trim())
      .filter(Boolean),
  );
}

// Ask karinto for the candidates in one file.
async function candidatesFor(content, kind) {
  const body = new URLSearchParams({ content, type: kind });
  const res = await fetch(KARINTO_URL, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!res.ok) throw new Error(`karinto ${res.status}`);
  const json = await res.json();
  return Array.isArray(json.online_audit_candidates)
    ? json.online_audit_candidates
    : [];
}

// Split `owner/repo[/subpath]` (the candidate `name`) into the bare repo.
// `owner/repo` from the candidate `name`, validated before it ever reaches an
// API URL — a malformed name (e.g. `../..`, spaces) must not be interpolated
// into github.com paths. Returns null to skip such candidates.
const REPO_SEGMENT = /^[A-Za-z0-9._-]+$/;
function bareRepo(name) {
  if (typeof name !== "string") return null;
  const parts = name.split("/");
  if (parts.length < 2) return null;
  const [owner, repo] = parts;
  if (!REPO_SEGMENT.test(owner) || !REPO_SEGMENT.test(repo)) return null;
  if ([".", ".."].includes(owner) || [".", ".."].includes(repo)) return null;
  return `${owner}/${repo}`;
}

// GitHub GET with shared headers. Returns the Response, or null on a network
// error (so callers can map that to "unknown" rather than throwing).
async function gh(apiPath) {
  try {
    return await fetch(`https://api.github.com${apiPath}`, { headers: GH_HEADERS });
  } catch {
    return null;
  }
}
const isRateLimited = (res) => res && (res.status === 403 || res.status === 429);

// Repo metadata (default branch), cached. On failure the `error` field
// classifies *why* so the caller can give actionable guidance — crucially,
// telling apart "private repo the token can't read" (404) from a rate limit or
// a bad token. GitHub returns 404 (not 403) for private repos you can't see, so
// "no-access" also covers a genuinely missing/renamed repo.
const repoMetaCache = new Map();
async function repoMeta(repo) {
  if (repoMetaCache.has(repo)) return repoMetaCache.get(repo);
  const res = await gh(`/repos/${repo}`);
  let out;
  if (!res) out = { error: "unverified" };
  else if (res.ok) {
    const data = await res.json().catch(() => null);
    out = data?.default_branch ? { branch: data.default_branch } : { error: "unverified" };
  } else if (res.status === 401) out = { error: "bad-token" };
  else if (res.status === 404) out = { error: "no-access" };
  else if (isRateLimited(res)) out = { error: "rate-limited" };
  else out = { error: "unverified" };
  repoMetaCache.set(repo, out);
  return out;
}

// impostor-commit: is the pinned SHA reachable from one of `owner/repo`'s own
// refs (a real branch/tag or their history), or does it only live in a fork
// (or not at all)? This mirrors zizmor's audit.
//
// `GET /repos/{repo}/commits/{sha}` is NOT a membership test: GitHub serves
// commits across the whole fork *network*, so a fork-only SHA — the canonical
// impostor — returns 200. We instead ask which of the repo's own refs contain
// the commit, two ways:
//   1. Fast path (public repos): GitHub's own `branch_commits` endpoint — the
//      data behind the web UI's "N branches / M tags containing this commit".
//      It returns `{branches, tags}`; empty ⇒ impostor, non-empty ⇒ reachable.
//      One request, authoritative. It needs a web session, so private repos
//      (and any format change) fall through.
//   2. Fallback (private repos / endpoint unavailable): the documented API —
//      classify access first (token can read it?), then walk every branch and
//      tag and `compare` it against the SHA; "behind"/"identical" means that
//      ref contains the commit. Reachable from none ⇒ impostor.
//
// Returns: "ok" | "impostor" | "no-access" | "bad-token" | "rate-limited" |
// "unverified". Everything but ok/impostor is inconclusive — the caller
// surfaces it as a (non-failing) warning rather than passing or false-flagging.
async function classifyCommit(repo, sha) {
  const fast = await branchCommitsContains(repo, sha);
  if (fast === "yes") return "ok";
  if (fast === "no") return "impostor";

  // Endpoint unavailable (private repo, or shape changed) → documented API.
  const meta = await repoMeta(repo);
  if (meta.error) return meta.error; // no-access / bad-token / rate-limited / unverified
  return reachableByApi(repo, sha);
}

// GitHub's undocumented `branch_commits` endpoint (the web UI's containing-refs
// data). With `Accept: application/json` it returns `{branches:[…], tags:[…]}`.
// Unauthenticated github.com web route — works for public repos only; anything
// else (private/login, non-JSON, error) returns "unavailable" to fall back.
// "yes" | "no" | "unavailable".
async function branchCommitsContains(repo, sha) {
  let res;
  try {
    res = await fetch(`https://github.com/${repo}/branch_commits/${sha}`, {
      headers: { "user-agent": "karinto-companion", accept: "application/json" },
    });
  } catch {
    return "unavailable";
  }
  if (!res.ok) return "unavailable";
  if (!(res.headers.get("content-type") || "").includes("json")) return "unavailable";
  const data = await res.json().catch(() => null);
  if (!data || !Array.isArray(data.branches) || !Array.isArray(data.tags)) return "unavailable";
  return data.branches.length > 0 || data.tags.length > 0 ? "yes" : "no";
}

// Documented-API reachability: every branch/tag tip, then `compare` each tip
// against the SHA ("behind"/"identical" ⇒ that ref contains it). Used for
// private repos (the token authenticates these calls). "ok" | "impostor" |
// "rate-limited" | "unverified".
async function reachableByApi(repo, sha) {
  const refs = await listRefTips(repo);
  if (refs.error) return refs.error;
  const want = sha.toLowerCase();
  if (refs.tips.has(want)) return "ok"; // pinned to a ref tip

  let sawError = false;
  for (const tip of refs.tips) {
    const c = await refContains(repo, tip, sha);
    if (c === "yes") return "ok";
    if (c === "rate") return "rate-limited";
    if (c === "error") sawError = true;
  }
  // Reachable from no listed ref. If the listing was truncated or some compare
  // errored, we can't be certain — don't over-claim impostor.
  if (refs.capped || sawError) return "unverified";
  return "impostor";
}

// Collect the tip SHAs of every branch and tag (lowercased). `capped` = there
// were more than we paged through. { tips:Set, capped:bool } | { error }.
async function listRefTips(repo) {
  const PAGES = 10; // up to 1000 of each — effectively all for normal repos
  const PER = 100;
  const tips = new Set();
  let capped = false;
  for (const kind of ["branches", "tags"]) {
    for (let page = 1; page <= PAGES; page++) {
      const res = await gh(`/repos/${repo}/${kind}?per_page=${PER}&page=${page}`);
      if (!res) return { error: "unverified" };
      if (isRateLimited(res)) return { error: "rate-limited" };
      if (!res.ok) return { error: "unverified" };
      const arr = await res.json().catch(() => null);
      if (!Array.isArray(arr) || arr.length === 0) break;
      for (const r of arr) {
        const tip = r?.commit?.sha?.toLowerCase();
        if (tip) tips.add(tip);
      }
      if (arr.length < PER) break;
      if (page === PAGES) capped = true; // more pages remain
    }
  }
  return { tips, capped };
}

// Does the ref at `baseTip` contain `sha`? compare base=tip, head=sha: the SHA
// is reachable from the tip when the comparison is "behind" or "identical".
// "yes" | "no" | "rate" | "error".
async function refContains(repo, baseTip, sha) {
  const res = await gh(`/repos/${repo}/compare/${baseTip}...${sha}`);
  if (!res) return "error";
  if (res.status === 404 || res.status === 422) return "no"; // divergent / unknown
  if (isRateLimited(res)) return "rate";
  if (!res.ok) return "error";
  const status = (await res.json().catch(() => null))?.status;
  return status === "behind" || status === "identical" ? "yes" : "no";
}

// ref-version-mismatch: resolve the tag named in the trailing comment to its
// SHA and compare with the pinned SHA. Returns the resolved tag SHA, or null
// when the tag cannot be resolved (then we cannot assert a mismatch).
async function tagSha(repo, tag) {
  const res = await fetch(
    `https://api.github.com/repos/${repo}/git/ref/tags/${encodeURIComponent(tag)}`,
    { headers: GH_HEADERS },
  );
  if (!res.ok) return null;
  const data = await res.json().catch(() => null);
  // Annotated tags point at a tag object; dereference to the commit.
  if (data?.object?.type === "tag") {
    const r2 = await fetch(data.object.url, { headers: GH_HEADERS });
    if (!r2.ok) return null;
    const tagObj = await r2.json().catch(() => null);
    return tagObj?.object?.sha ?? null;
  }
  return data?.object?.sha ?? null;
}

// Escape per the GitHub workflow-command spec. Without this, values that flow
// from the linted YAML (`c.ref`, `c.comment`, the file path) could contain
// newlines or `::` and inject extra workflow commands (forge findings, mask
// output, etc.) — `c.comment` especially is free-form and unvalidated.
const escapeData = (s) =>
  String(s).replace(/%/g, "%25").replace(/\r/g, "%0D").replace(/\n/g, "%0A");
const escapeProp = (s) => escapeData(s).replace(/:/g, "%3A").replace(/,/g, "%2C");

function annotate(level, file, message) {
  // `level` is "error" or "warning"; GitHub renders these as annotations.
  console.log(`::${level} file=${escapeProp(file)}::${escapeData(message)}`);
}

// Warning text for an inconclusive impostor check — tells access problems
// (actionable: pass a token) apart from transient ones (actionable: re-run).
function unverifiedMessage(verdict, repo, ref) {
  const prefix = `impostor-commit: could not verify \`${ref}\` against ${repo}`;
  switch (verdict) {
    case "no-access":
      return (
        `${prefix} — it may be private (the token lacks read access) or no ` +
        `longer exist. The default GITHUB_TOKEN only reads this workflow's own ` +
        `repo; pass a token with read access via the \`github-token\` input to ` +
        `audit private actions.`
      );
    case "bad-token":
      return `${prefix} — the GitHub token is invalid or expired (set \`github-token\`).`;
    case "rate-limited":
      return (
        `${prefix} — hit the GitHub API rate limit; re-run later, or provide a ` +
        `higher-quota token via \`github-token\`.`
      );
    default:
      return `${prefix} (GitHub API error) — re-run to confirm.`;
  }
}

function guessKind(file) {
  if (file.endsWith("action.yml") || file.endsWith("action.yaml")) return "action";
  if (file.includes(".github/workflows/")) return "workflow";
  return "";
}

async function main() {
  const files = await resolveFiles();
  let errors = 0;
  let warnings = 0;
  let skipped = 0; // unverifiable (rate limit / API error) — annotated, never fails

  for (const file of files) {
    let content;
    try {
      content = await readFile(file, "utf8");
    } catch {
      annotate("warning", file, `karinto-companion: could not read ${file}`);
      continue;
    }
    let candidates;
    try {
      candidates = await candidatesFor(content, guessKind(file));
    } catch (e) {
      annotate("warning", file, `karinto-companion: ${String(e.message || e)}`);
      continue;
    }

    for (const c of candidates) {
      // Isolate each candidate: a malformed entry or a one-off API throw must
      // not abort the rest of the audit.
      try {
        if (c?.pin !== "sha") continue;
        const repo = bareRepo(c.name);
        if (!repo) continue;
        // Guard the SHA: candidate `ref` must be `owner/repo@<7–40 hex>`.
        const sha =
          typeof c.ref === "string" && c.ref.includes("@")
            ? c.ref.slice(c.ref.lastIndexOf("@") + 1)
            : "";
        if (!/^[0-9a-f]{7,40}$/i.test(sha)) continue; // not a usable SHA pin

        // impostor-commit
        const verdict = await classifyCommit(repo, sha);
        if (verdict === "impostor") {
          errors++;
          annotate(
            "error",
            file,
            `impostor-commit: uses \`${c.ref}\` — SHA is not reachable from any ` +
              `branch or tag of ${repo} (it only exists in a fork, or was never pushed)`,
          );
          continue; // an impostor SHA can't meaningfully be version-checked
        }
        if (verdict !== "ok") {
          skipped++; // inconclusive — annotate but never fail the job
          annotate("warning", file, unverifiedMessage(verdict, repo, c.ref));
          continue; // can't reliably version-check either
        }

        // ref-version-mismatch (only when a trailing version comment is present)
        if (c.comment) {
          const want = await tagSha(repo, c.comment);
          if (want && want.toLowerCase() !== sha.toLowerCase()) {
            warnings++;
            annotate(
              "warning",
              file,
              `ref-version-mismatch: uses \`${c.ref}\` # ${c.comment} — ` +
                `tag ${c.comment} of ${repo} is ${want.slice(0, 12)}`,
            );
          }
        }
      } catch (e) {
        skipped++;
        annotate(
          "warning",
          file,
          `karinto-companion: error auditing \`${c?.ref ?? "candidate"}\`: ` +
            `${String(e?.message || e)} — re-run to confirm`,
        );
      }
    }
  }

  console.log(
    `karinto-companion: ${errors} impostor-commit error(s), ` +
      `${warnings} ref-version-mismatch warning(s), ` +
      `${skipped} unverifiable across ${files.length} file(s)`,
  );

  const fail =
    (FAIL_ON === "error" && errors > 0) ||
    (FAIL_ON === "warning" && (errors > 0 || warnings > 0));
  if (fail) process.exit(1);
}

main().catch((e) => {
  console.log(`::error::karinto-companion failed: ${String(e?.stack || e)}`);
  process.exit(1);
});
