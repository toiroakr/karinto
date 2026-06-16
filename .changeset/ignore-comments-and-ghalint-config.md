---
"karinto": patch
---

Honour author-written opt-outs from the upstream tools karinto consolidates:

- **Inline ignore comments** — `# karinto: ignore[rule-id]` and
  `# zizmor: ignore[rule-id]` suppress findings on the same line (line-scoped),
  supporting comma-separated rule lists and a trailing free-form note. Mirrors
  zizmor's inline-ignore syntax. actionlint and ghalint have no inline form, so
  only the `karinto` and `zizmor` prefixes are recognised.
- **ghalint config** — a `ghalint.yaml` `excludes:` list is honoured. Each
  entry's `policy_name` maps onto the karinto rule(s) that absorbed it (via the
  catalogue `origins`), with the `workflow_file_path` / `job_name` /
  `action_name` / `step_id` scope fields applied. Available through the CLI's
  `--ghalint-config` flag and the Worker's `ghalint` HTTP parameter (with
  `path` / per-file paths resolving the `workflow_file_path` scope).

actionlint config support is intentionally deferred (tracked in #50): it ignores
by regex against actionlint's own error messages, which do not map onto
karinto's findings.
