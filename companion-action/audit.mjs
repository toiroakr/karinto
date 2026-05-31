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
// status per `FAIL_ON`. The impostor membership check below is a pragmatic
// heuristic (see the comment on `isImpostor`); zizmor's audit is the rigorous
// reference if you need exact parity.

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

// impostor-commit: a pinned SHA that `owner/repo` does not know about. The
// rigorous check (zizmor) walks the repo's reachable refs; here we use the
// pragmatic signal that `GET /repos/{repo}/commits/{sha}` 404s for a SHA the
// repo has never seen. A 200 is treated as "belongs to the repo". This catches
// the common fork-only / typo'd-SHA case without enumerating every ref.
async function isImpostor(repo, sha) {
  const res = await fetch(
    `https://api.github.com/repos/${repo}/commits/${sha}`,
    { headers: GH_HEADERS },
  );
  if (res.status === 404 || res.status === 422) return true;
  return false; // 200 (known) or transient/other → don't flag
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
      if (await isImpostor(repo, sha)) {
        errors++;
        annotate(
          "error",
          file,
          `impostor-commit: uses \`${c.ref}\` — SHA does not exist in ${repo}`,
        );
        continue; // an impostor SHA can't meaningfully be version-checked
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
      `${warnings} ref-version-mismatch warning(s) across ${files.length} file(s)`,
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
