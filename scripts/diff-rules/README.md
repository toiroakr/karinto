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

## Guidelines

- **Be specific.** A rule that returns `true` for everything makes the
  whole system useless. Match on `rule`, exact `message` prefixes, or
  severity — not just "anything new".
- **Date-prefix the filename** (`YYYY-MM-<slug>.mjs`) so older rules are
  obvious and easy to clean up.
- **Delete the rule when the change has shipped** and the captured prod
  responses reflect the new behaviour (i.e. after the next release plus
  ~30 days for the prod captures to roll over).
- **One rule per PR**. If a PR introduces two unrelated behavioural
  changes, write two rule files.
