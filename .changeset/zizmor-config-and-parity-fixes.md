---
"karinto": minor
---

Honour `zizmor.yml` configs and fix five parity divergences found by diffing
karinto against zizmor / actionlint on real OSS workflows.

- **New: `zizmor.yml` config support.** A zizmor config's `rules.<id>.disable`
  and `rules.<id>.ignore` (`filename[:line[:col]]`) opt-outs are now honoured,
  alongside the existing inline-comment and ghalint-config opt-outs. Pass it via
  the CLI's `--zizmor-config` or the HTTP `zizmor` parameter.
- **`known-vulnerable-actions`** no longer carries a hardcoded action list. It
  could not track GHSA's per-advisory version ranges and false-flagged fixed
  releases (e.g. `tj-actions/changed-files@v47`). Vulnerability is now decided
  solely by the online advisory path (OSV.dev via `osv=1` / the companion
  action) — the mechanism zizmor uses. Without `osv=1` the rule no longer fires.
- **`context-availability`** no longer flags `inputs` in workflow-level `env` /
  `concurrency` for `workflow_call` / `workflow_dispatch` workflows, where the
  `inputs` context is in fact available (matching actionlint).
- **`expression-syntax`** no longer reports a stray `}}`: a literal `{{ … }}`
  template (e.g. docker/metadata-action's `pattern={{version}}`) is not an
  expression. Only an unterminated `${{` is an error, as in actionlint.
- **`bot-conditions`** now fires only on an `==` comparison of `github.actor` /
  `github.triggering_actor` against a `[bot]` login (and now also covers
  `triggering_actor`), matching zizmor; the `!=` / `endsWith(...)` exclude forms
  are no longer flagged.
- **`excessive-permissions`** persona gating: the workflow-level "no
  `permissions:` block" finding is now `pedantic` (the per-job "default
  permissions used" finding stays `regular`), matching zizmor's per-persona
  behaviour.
