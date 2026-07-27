# Dark-launch ignore rules

Each `*.mjs` file in this directory is an **ignore rule**: a small JS module
that inspects a diff between a captured prod response and a PR's replayed
response, and decides whether the diff is intentional. If any rule's
`matches()` returns `true`, the diff is suppressed; otherwise it fails the
`replay` job in `deploy-preview.yml`.

Add a rule when a PR deliberately changes linter output (new rule, message
wording change, severity bump, etc.). The rule is reviewed in the same PR
as the change it describes — that's the audit trail.

## Module shape

```js
// scripts/diff-rules/2026-05-add-new-foo-rule.mjs
export const id = "add-new-foo-rule";
// Required. See "Prunability" below.
export const prunable = true;
export const reason = "PR #42 adds the `foo` rule, which fires on any workflow that uses X.";

/**
 * @param capture   { hash, request, response, first_seen, uploaded }
 *                  — the prod-side snapshot the PR is being compared against
 * @param replayed  raw JSON the PR worker returned for the same request
 * @param diff      array of diff entries; see below
 * @returns true if the diff is intentional (suppress it)
 */
export function matches(capture, replayed, diff) {
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;
    // PR adds new diagnostics only; nothing should disappear.
    if (d.onlyInCaptured.length > 0) return false;
    if (!d.onlyInReplayed.every((x) => x.rule === "foo")) return false;
  }
  return true;
}
```

## Diff entry shapes

```ts
// Response shape mismatch (rare — usually means a 5xx in the PR worker)
{ kind: "ok-mismatch", captured: boolean, replayed: boolean }

// Diagnostic set difference
{
  kind: "diagnostics",
  onlyInCaptured: Array<{ file?: string, rule: string, severity: string, message: string }>,
  onlyInReplayed: Array<{ file?: string, rule: string, severity: string, message: string }>,
}

// Response-metadata difference. Catches everything the response exposes
// outside `diagnostics` (`result.kind`, `result.stats`, per-file ok/error,
// parse-error details, etc.) — emitted when the JSON-stringified, diagnostics-
// stripped response differs.
{ kind: "metadata", captured: object, replayed: object }
```

`file` is set only for `repo`-mode captures (currently skipped at capture
time, so you won't see it in practice).

## Prunability

Every rule must export a boolean `prunable`. It tells
`.github/workflows/prune-diff-rules.yml` whether the rule is allowed to be
deleted automatically, and there is no safe default — the two kinds of rule
look identical from the replay report alone.

| `prunable` | Kind of rule | Pruner behaviour |
| --- | --- | --- |
| `true` | **Transient "shipped fix".** The diff exists only because prod already serves the new behaviour while the frozen captures still carry the old one. Every rule written alongside a linter change is this kind. | Once the rule matches a replay **against prod**, the pruner opens a PR deleting it. |
| `false` | **Permanent.** The diff is caused by state no release can ship — e.g. `2026-05-archived-uses-baseline.mjs`, where the `archived:list` KV set simply differs between capture time and replay time. | Never deleted. The job logs a warning noting it matched and was intentionally kept. |
| omitted | Authoring omission. | Treated as `false`, plus a warning telling you to add the field. |

Marking a permanent rule `prunable = true` (or letting the pruner infer
prunability from "it matched against prod") is unrecoverable in practice: a
rebaseline clears only the drift present at that moment, and the next
out-of-band refresh reopens it with no rule left to suppress it. When in
doubt, ask whether a release could ever make the diff go away for good — if
not, the rule is permanent.

## Guidelines

- **Be specific.** A rule that returns `true` for everything makes the
  whole system useless. Match on `rule`, exact `message` prefixes, or
  severity — not just "anything new".
- **Date-prefix the filename** (`YYYY-MM-<slug>.mjs`) so older rules are
  obvious and easy to clean up.
- **Declare `prunable`** — see "Prunability" above. Omitting it opts the rule
  out of automatic cleanup and produces a CI warning.
- **Deletion is usually automatic.** For a `prunable = true` rule,
  `prune-diff-rules.yml` opens the removal PR itself once the fix is live on
  prod; merging it triggers `rebaseline-captures.yml`, which refreshes the
  captures so no manual ~30-day wait is needed. Deleting by hand is still
  fine — the same merge-time rebaseline picks it up.
- **One rule per PR**. If a PR introduces two unrelated behavioural
  changes, write two rule files.
