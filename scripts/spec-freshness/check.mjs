#!/usr/bin/env node
// Watches GitHub's public docs (github/docs) and actions/runner-images for
// spec additions/removals that karinto's hardcoded strict-validation tables
// in rules.mbt would otherwise miss.
//
// Why this exists: actionlint's tables went stale once its releases
// stopped shipping (see issue #111) — new permission scopes, runner
// labels, workflow keys, etc. piled up as unanswered issues instead of
// code changes. karinto's pitch is tracking the GitHub spec *faster* than
// that, which only holds if something actually watches for drift. This
// script is that something; it does NOT auto-edit rules.mbt (a scraped
// page and a hand-written MoonBit array are different enough shapes that
// blind auto-editing risks corrupting the source — see the `models`/
// `copilot-requests` judgment calls issue #111 already ran into by hand).
// It only *notices* drift and reports it; a human decides the edit.
//
// Exit codes:
//   0  every watched table matches its source(s)
//   1  drift found — a source lists a value the code doesn't have
//   2  configuration/fetch error (network, doc restructuring). NOT drift —
//      the workflow treats this as "couldn't check", not "found a gap"
//
// Usage:
//   node scripts/spec-freshness/check.mjs [--rules <path>] [--summary-path <path>]

import { readFileSync, appendFileSync, writeFileSync } from "node:fs";

function parseArgs(argv) {
  const args = {
    rules: "rules.mbt",
    summaryPath: process.env.GITHUB_STEP_SUMMARY ?? null,
  };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--rules") args.rules = argv[++i];
    else if (argv[i] === "--summary-path") args.summaryPath = argv[++i];
  }
  return args;
}

async function fetchText(url) {
  const res = await fetch(url, {
    headers: { "user-agent": "karinto-spec-freshness (github.com/toiroakr/karinto)" },
  });
  if (!res.ok) {
    throw new Error(`HTTP ${res.status} fetching ${url}`);
  }
  return res.text();
}

// workflow-syntax.md backs three watchers (workflow/job/step keys). Caching
// by URL — keyed on the in-flight promise, so concurrent watchers dedupe
// too — means it's fetched once per run instead of once per watcher.
const fetchCache = new Map();
function fetchTextCached(url) {
  if (!fetchCache.has(url)) {
    fetchCache.set(url, fetchText(url));
  }
  return fetchCache.get(url);
}

// Extracts the string literals out of `fn <fnName>() -> Array[String] { [
// "...", "...", ... ] }` in rules.mbt. Every watched table is written in
// this exact shape (see valid_perm_scopes/known_runner_labels/known_events/
// known_contexts/workflow_top_keys/job_keys/step_keys/action_top_keys) —
// this is not a general MoonBit parser, just a pattern match on that shape.
// Truncates each line at its first `//` that isn't inside a quoted string,
// so a comment like `// ... "Available Images" table` doesn't get read as a
// table entry.
function stripLineComments(text) {
  return text
    .split("\n")
    .map((line) => {
      let inString = false;
      for (let i = 0; i < line.length; i++) {
        const c = line[i];
        if (c === '"' && line[i - 1] !== "\\") {
          inString = !inString;
        } else if (!inString && c === "/" && line[i + 1] === "/") {
          return line.slice(0, i);
        }
      }
      return line;
    })
    .join("\n");
}

function extractMbtArray(source, fnName) {
  const fnStart = source.indexOf(`fn ${fnName}(`);
  if (fnStart < 0) {
    throw new Error(`function \`${fnName}\` not found in rules.mbt`);
  }
  const braceStart = source.indexOf("{", fnStart);
  const braceEnd = source.indexOf("\n}", braceStart);
  if (braceStart < 0 || braceEnd < 0) {
    throw new Error(`could not find the body of \`${fnName}\` in rules.mbt`);
  }
  const body = stripLineComments(source.slice(braceStart, braceEnd));
  const values = new Set();
  for (const m of body.matchAll(/"([^"]+)"/g)) values.add(m[1]);
  return values;
}

// --- per-table doc extractors ----------------------------------------------
// Each takes the raw text of one source and returns the Set of values that
// source documents. Regexes are deliberately narrow (anchored to the exact
// heading/table shape seen when this was written) so a doc restructuring
// makes the watcher throw (→ exit 2, "couldn't check") instead of silently
// extracting nothing and reporting every code value as spurious drift.

function extractPermissionScopes(text) {
  const fence = text.match(/```yaml\n(permissions:[\s\S]*?)\n```/);
  if (!fence) throw new Error("permissions fenced example not found");
  const values = new Set();
  for (const m of fence[1].matchAll(/^ {2}([a-z][\w-]*):\s*(?:read|write|none)/gm)) {
    values.add(m[1]);
  }
  if (values.size === 0) throw new Error("no permission scopes extracted");
  return values;
}

function extractRunnerLabelsFromDocsTable(text) {
  const values = new Set();
  for (const m of text.matchAll(/<code><a[^>]*>([a-z0-9.-]+)<\/a><\/code>/g)) {
    values.add(m[1]);
  }
  if (values.size === 0) throw new Error("no runner labels extracted from docs table");
  return values;
}

function extractRunnerLabelsFromLargerTable(text) {
  const values = new Set();
  for (const m of text.matchAll(/<code>([a-z0-9.-]+)<\/code>/g)) {
    values.add(m[1]);
  }
  if (values.size === 0) throw new Error("no runner labels extracted from larger-runners table");
  return values;
}

function extractRunnerLabelsFromImagesReadme(text) {
  const section = text.match(/## Available Images\n([\s\S]*?)\n### Label scheme/);
  if (!section) throw new Error("\"Available Images\" table not found in runner-images README");
  const values = new Set();
  for (const m of section[1].matchAll(/`([a-z0-9.-]+)`/g)) {
    values.add(m[1]);
  }
  if (values.size === 0) throw new Error("no runner labels extracted from runner-images README");
  return values;
}

function extractWebhookEvents(text) {
  const values = new Set();
  for (const line of text.split("\n")) {
    const m = line.match(/^## `([a-z_]+)`/);
    if (!m) continue;
    // e.g. "## `pull_request_comment` (use `issue_comment`)" documents a
    // deprecated alias, not a real trigger name — skip it.
    if (line.includes("(use `")) continue;
    values.add(m[1]);
  }
  if (values.size === 0) throw new Error("no webhook events extracted");
  return values;
}

function extractContextNames(text) {
  const values = new Set();
  for (const m of text.matchAll(/^## `([a-z]+)` context$/gm)) values.add(m[1]);
  if (values.size === 0) throw new Error("no context names extracted");
  return values;
}

function extractWorkflowTopKeys(text) {
  const values = new Set();
  for (const m of text.matchAll(/^## `([a-z][a-z-]*)`$/gm)) values.add(m[1]);
  if (values.size === 0) throw new Error("no workflow top-level keys extracted");
  return values;
}

function extractJobKeys(text) {
  const values = new Set();
  for (const m of text.matchAll(/^## `jobs\.<job_id>\.([a-z][a-z-]*)`$/gm)) values.add(m[1]);
  if (values.size === 0) throw new Error("no job-level keys extracted");
  return values;
}

function extractStepKeys(text) {
  const values = new Set();
  for (const m of text.matchAll(/^## `jobs\.<job_id>\.steps\[\*\]\.([a-z][a-z-]*)`$/gm)) {
    values.add(m[1]);
  }
  if (values.size === 0) throw new Error("no step-level keys extracted");
  return values;
}

function extractActionTopKeys(text) {
  const values = new Set();
  for (const m of text.matchAll(/^## `([a-z]+)`/gm)) values.add(m[1]);
  if (values.size === 0) throw new Error("no action.yml top-level keys extracted");
  return values;
}

// --- watcher registry --------------------------------------------------

const DOCS_RAW = "https://raw.githubusercontent.com/github/docs/main";
const RUNNER_IMAGES_README = "https://raw.githubusercontent.com/actions/runner-images/main/README.md";

const WATCHERS = [
  {
    key: "permission-scopes",
    label: "`permissions:` scopes (rule `permissions-syntax`, table `valid_perm_scopes`)",
    codeFn: "valid_perm_scopes",
    sources: [
      {
        url: `${DOCS_RAW}/data/reusables/actions/github-token-available-permissions.md`,
        extract: extractPermissionScopes,
      },
    ],
  },
  {
    key: "runner-labels",
    label: "`runs-on:` labels (rule `unknown-runner-label`, table `known_runner_labels`)",
    codeFn: "known_runner_labels",
    sources: [
      {
        url: `${DOCS_RAW}/data/reusables/actions/supported-github-runners.md`,
        extract: extractRunnerLabelsFromDocsTable,
      },
      {
        url: `${DOCS_RAW}/data/reusables/actions/larger-runners-table.md`,
        extract: extractRunnerLabelsFromLargerTable,
      },
      {
        // Secondary source per issue #111: new hosted-runner images often
        // land here (and in the actions/runner-images release notes) before
        // github/docs catches up — this is how `xcode-27` was found stale.
        url: RUNNER_IMAGES_README,
        extract: extractRunnerLabelsFromImagesReadme,
      },
    ],
  },
  {
    key: "webhook-events",
    label: "`on:` webhook events (rule `webhook-events`, table `known_events`)",
    codeFn: "known_events",
    sources: [
      {
        url: `${DOCS_RAW}/content/actions/reference/workflows-and-actions/events-that-trigger-workflows.md`,
        extract: extractWebhookEvents,
      },
    ],
  },
  {
    key: "context-names",
    label: "context names (rule `unknown-context-or-function`, table `known_contexts`)",
    codeFn: "known_contexts",
    sources: [
      {
        url: `${DOCS_RAW}/content/actions/reference/workflows-and-actions/contexts.md`,
        extract: extractContextNames,
      },
    ],
  },
  {
    key: "workflow-keys",
    label: "workflow top-level keys (rule `unexpected-keys`, table `workflow_top_keys`)",
    codeFn: "workflow_top_keys",
    sources: [
      {
        url: `${DOCS_RAW}/content/actions/reference/workflows-and-actions/workflow-syntax.md`,
        extract: extractWorkflowTopKeys,
      },
    ],
  },
  {
    key: "job-keys",
    label: "job-level keys (rule `unexpected-keys`, table `job_keys`)",
    codeFn: "job_keys",
    sources: [
      {
        url: `${DOCS_RAW}/content/actions/reference/workflows-and-actions/workflow-syntax.md`,
        extract: extractJobKeys,
      },
    ],
  },
  {
    key: "step-keys",
    label: "step-level keys (rule `unexpected-keys`, table `step_keys`)",
    codeFn: "step_keys",
    sources: [
      {
        url: `${DOCS_RAW}/content/actions/reference/workflows-and-actions/workflow-syntax.md`,
        extract: extractStepKeys,
      },
    ],
  },
  {
    key: "action-keys",
    label: "action.yml top-level keys (rule `unexpected-keys`, table `action_top_keys`)",
    codeFn: "action_top_keys",
    sources: [
      {
        url: `${DOCS_RAW}/content/actions/reference/workflows-and-actions/metadata-syntax.md`,
        extract: extractActionTopKeys,
      },
    ],
  },
];

// --- driver ----------------------------------------------------------------

async function checkWatcher(watcher, rulesSource) {
  const codeValues = extractMbtArray(rulesSource, watcher.codeFn);
  const docValues = new Set();
  const sourceUrls = [];
  for (const source of watcher.sources) {
    const text = await fetchTextCached(source.url);
    for (const v of source.extract(text)) docValues.add(v);
    sourceUrls.push(source.url);
  }
  const missingInCode = [...docValues].filter((v) => !codeValues.has(v)).sort();
  const codeOnly = [...codeValues].filter((v) => !docValues.has(v)).sort();
  return { ...watcher, sourceUrls, missingInCode, codeOnly };
}

function renderReport(results) {
  const lines = [];
  lines.push("# GitHub spec freshness check");
  lines.push("");
  lines.push(
    "Compares karinto's hardcoded strict-validation tables in `rules.mbt` against " +
      "the current github/docs and actions/runner-images sources. See issue #111.",
  );
  lines.push("");

  const drifted = results.filter((r) => r.status === "ok" && r.missingInCode.length > 0);
  const errored = results.filter((r) => r.status === "error");
  const clean = results.filter((r) => r.status === "ok" && r.missingInCode.length === 0);

  if (drifted.length > 0) {
    lines.push("## Drift found — sources list values the code doesn't have");
    lines.push("");
    for (const r of drifted) {
      lines.push(`### ${r.label}`);
      lines.push("");
      lines.push(`- table: \`${r.codeFn}()\` in \`rules.mbt\``);
      lines.push(`- source(s): ${r.sourceUrls.map((u) => `<${u}>`).join(", ")}`);
      lines.push(`- missing from code: ${r.missingInCode.map((v) => `\`${v}\``).join(", ")}`);
      if (r.codeOnly.length > 0) {
        lines.push(
          `- in code but not in these source(s) (often intentional — meta-labels, ` +
            `differently-documented scopes, etc.; not itself drift): ` +
            r.codeOnly.map((v) => `\`${v}\``).join(", "),
        );
      }
      lines.push("");
    }
  }

  if (errored.length > 0) {
    lines.push("## Could not check (config/fetch error, not drift)");
    lines.push("");
    for (const r of errored) {
      lines.push(`- **${r.label}**: ${r.error}`);
    }
    lines.push("");
  }

  if (clean.length > 0) {
    lines.push("## Up to date");
    lines.push("");
    for (const r of clean) {
      lines.push(`- ${r.label}`);
    }
    lines.push("");
  }

  return lines.join("\n");
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const rulesSource = readFileSync(args.rules, "utf8");

  const results = await Promise.all(
    WATCHERS.map(async (watcher) => {
      try {
        return await checkWatcher(watcher, rulesSource);
      } catch (err) {
        return { ...watcher, status: "error", error: err.message };
      }
    }),
  ).then((rs) => rs.map((r) => (r.status === "error" ? r : { ...r, status: "ok" })));

  const anyDrift = results.some((r) => r.status === "ok" && r.missingInCode.length > 0);
  const anyError = results.some((r) => r.status === "error");

  const report = renderReport(results);
  if (args.summaryPath) {
    try {
      appendFileSync(args.summaryPath, report + "\n");
    } catch {
      writeFileSync(args.summaryPath, report + "\n");
    }
  }
  // Also print to stdout so the action log shows the same info.
  process.stdout.write(report + "\n");

  if (anyDrift) {
    process.exitCode = 1;
  } else if (anyError) {
    process.exitCode = 2;
  } else {
    process.exitCode = 0;
  }
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 2;
});
