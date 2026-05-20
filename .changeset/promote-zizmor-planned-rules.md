---
"karinto": patch
---

Promote every `Planned` zizmor rule in the catalogue to `Implemented` and drive
per-rule upstream parity against `zizmor --pedantic --no-online-audits` to
missing=0 / extra=0 on the vendored fixtures (engine-wide divergences are
recorded in the parity allowlist instead of being silently absorbed).

Promoted (zizmor): `anonymous-definition`, `undocumented-permissions`,
`forbidden-uses`, `github-app`, `dependabot-execution`, `archived-uses`,
`impostor-commit`, `ref-version-mismatch`, `overprovisioned-secrets`,
`insecure-commands`, `unsound-condition`, `unredacted-secrets`, `misfeature`,
`unpinned-tools`, `unpinned-images`, `self-hosted-runner`,
`superfluous-actions`, `github-env`, `obfuscation`, `use-trusted-publishing`,
`dependabot-cooldown`, `artipacked`, `cache-poisoning`, `excessive-permissions`,
`template-injection`.

Promoted (actionlint): `yaml-anchor-issues` ships a full implementation
(re-scans the raw source for `&name` / `*name` tokens since the YAML parser
resolves them away).

Preview implementations were added for the actionlint-side `matrix-values`
and `deprecated-action-inputs` rules (still `Planned` in the catalogue
pending broader coverage work).

Known engine-wide divergences absorbed via the parity allowlist:
- `# zizmor: ignore[…]` is parsed file-wide instead of per-node, so
  fixtures that mute a single step also drop neighbouring findings.
- Local `zizmor.yml` config discovery is not implemented, so
  `config-scenarios/*/hackme.yml` reports the unconfigured baseline.
- `self-hosted-runner` is gated to `--persona=auditor` upstream but fires
  unconditionally in karinto.
