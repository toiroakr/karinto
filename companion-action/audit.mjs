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
const FAIL_ON = (process.env.FAIL_ON || "error").toLowerCase();

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
function bareRepo(name) {
  const parts = name.split("/");
  return parts.length >= 2 ? `${parts[0]}/${parts[1]}` : null;
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

// Default branch of a repo, cached. null = could not determine (missing repo,
// rate limit, error).
const defaultBranchCache = new Map();
async function defaultBranch(repo) {
  if (defaultBranchCache.has(repo)) return defaultBranchCache.get(repo);
  const res = await gh(`/repos/${repo}`);
  let branch = null;
  if (res && res.ok) {
    const data = await res.json().catch(() => null);
    branch = data?.default_branch ?? null;
  }
  defaultBranchCache.set(repo, branch);
  return branch;
}

// impostor-commit: is the pinned SHA reachable from one of `owner/repo`'s own
// refs, or does it only live in a fork (or not at all)?
//
// `GET /repos/{repo}/commits/{sha}` is NOT a membership test: GitHub serves
// commits across the whole fork *network*, so a SHA that exists only in a fork
// — the canonical impostor — returns 200. Instead we test reachability:
//   1. compare `sha...defaultBranch`: "ahead"/"identical" ⇒ sha is in the
//      default branch's history (the common, legitimate case); 404 ⇒ the SHA
//      isn't in the network at all (typo / deleted) ⇒ impostor.
//   2. otherwise it may still be a non-default branch head, or a tagged release
//      off the default branch — check `branches-where-head` and the tag list.
//   3. reachable from none of those ⇒ impostor (fork-only or unreachable).
// Returns "ok" | "impostor" | "unknown" (unknown = rate-limited / API error, so
// the caller warns instead of asserting either way).
async function classifyCommit(repo, sha) {
  const branch = await defaultBranch(repo);
  if (!branch) return "unknown";

  // `sha` is hex and `branch` a ref name; the `...` separator must stay literal.
  const cmp = await gh(`/repos/${repo}/compare/${sha}...${branch}`);
  if (!cmp) return "unknown";
  if (cmp.status === 404 || cmp.status === 422) return "impostor"; // unknown to the network
  if (isRateLimited(cmp) || !cmp.ok) return "unknown";
  const status = (await cmp.json().catch(() => null))?.status;
  if (status === "ahead" || status === "identical") return "ok"; // in default history

  // Not on the default branch — accept a branch head or a tagged-release commit.
  const head = await isBranchHead(repo, sha);
  if (head !== "no") return head === "ok" ? "ok" : "unknown";
  const tagged = await isTaggedCommit(repo, sha);
  if (tagged !== "no") return tagged === "ok" ? "ok" : "unknown";
  return "impostor";
}

// Is `sha` the HEAD of some branch of `repo`? "ok" | "no" | "unknown".
async function isBranchHead(repo, sha) {
  const res = await gh(`/repos/${repo}/commits/${sha}/branches-where-head`);
  if (!res || isRateLimited(res)) return "unknown";
  if (!res.ok) return "no";
  const arr = await res.json().catch(() => null);
  return Array.isArray(arr) && arr.length > 0 ? "ok" : "no";
}

// Is `sha` the commit of one of `repo`'s tags? Paginates a bounded number of
// pages; if the cap is hit without a match we return "unknown" (not "no") so a
// repo with thousands of tags can't produce a false impostor. "ok"|"no"|"unknown".
async function isTaggedCommit(repo, sha) {
  const PAGES = 3;
  const PER = 100;
  const want = sha.toLowerCase();
  for (let page = 1; page <= PAGES; page++) {
    const res = await gh(`/repos/${repo}/tags?per_page=${PER}&page=${page}`);
    if (!res || isRateLimited(res)) return "unknown";
    if (!res.ok) return "no";
    const arr = await res.json().catch(() => null);
    if (!Array.isArray(arr) || arr.length === 0) return "no";
    if (arr.some((t) => t?.commit?.sha?.toLowerCase() === want)) return "ok";
    if (arr.length < PER) return "no"; // last page reached
  }
  return "unknown"; // more tags exist beyond the cap — don't over-claim impostor
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
  const data = await res.json();
  // Annotated tags point at a tag object; dereference to the commit.
  if (data?.object?.type === "tag") {
    const r2 = await fetch(data.object.url, { headers: GH_HEADERS });
    if (!r2.ok) return null;
    const tagObj = await r2.json();
    return tagObj?.object?.sha ?? null;
  }
  return data?.object?.sha ?? null;
}

function annotate(level, file, message) {
  // `level` is "error" or "warning"; GitHub renders these as annotations.
  console.log(`::${level} file=${file}::${message}`);
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
      if (c.pin !== "sha") continue;
      const repo = bareRepo(c.name);
      if (!repo) continue;
      const sha = c.ref.slice(c.ref.lastIndexOf("@") + 1);

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
      if (verdict === "unknown") {
        skipped++;
        annotate(
          "warning",
          file,
          `impostor-commit: could not verify \`${c.ref}\` against ${repo} ` +
            `(GitHub API rate limit or error) — re-run to confirm`,
        );
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
