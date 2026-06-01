---
"karinto": minor
---

Action-side online audits, split by how cacheable the underlying fact is.

- `archived-uses`: the request path enqueues seen external `uses:` repos into
  a D1 worklist; a daily CI job (`refresh-archived.yml`) drains it, confirms
  each against the GitHub API `archived` flag, re-verifies the existing set on
  every run, and writes the baseline to both KV (live) and committed
  `cf/archived.json` (bundled into the Worker as a seed, updated via PR). Add
  `forbidden` and `archived` request parameters.
- New `online_audit_candidates` field on every response: the SHA-pinned refs
  (with any trailing `# vN` comment) that need a live GitHub API lookup.
- `impostor-commit` / `ref-version-mismatch` move out of karinto-core
  (`Not planned`) to the new `companion-action/`, which resolves them via the
  GitHub API and reports findings directly.
