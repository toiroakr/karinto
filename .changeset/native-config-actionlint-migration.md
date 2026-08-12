---
"karinto": patch
---

Adds a native `karinto.yaml` config file, wired through the CLI's `--config` and the Worker's `config` parameter (64 KiB cap, same as `ghalint`/`zizmor`), covering four settings that had no home before:

- `self-hosted-runner.labels` — glob patterns of your self-hosted runners' extra labels. Without it, `runs-on:` containing `self-hosted` still skips label validation entirely (unchanged default behaviour); with it, `unknown-runner-label` validates the remaining labels against the known set plus your globs instead of skipping, so a typo (`gpu-a1oo` vs `gpu-a100`) is caught.
- `config-variables` — an allowlist of `vars.*` names, backing a new `config-variables` rule. Omitted (the default) leaves the check off; `[]` forbids every `vars.*` reference; a non-empty list flags any `vars.<name>` outside it.
- `rules` — per-rule severity override (`rule-id: error|warning|info`).
- `ignore-paths` — per-path rule suppression, keyed by a glob against the linted file's path (`"*"` suppresses every rule under that glob).

`self-hosted-runner.labels` and `config-variables` reuse `.github/actionlint.yaml`'s own key names and shapes, so an existing actionlint.yaml is already a valid (partial) karinto config for those two settings — pass it straight through. actionlint's own `paths.*.ignore` (a message-regex mechanism against actionlint's own error text) has no karinto equivalent and is not read; use `ignore-paths` instead.

`karinto.yaml` also doubles as a ghalint config and a zizmor config: its top-level `excludes:` (ghalint's own shape) and `rules.<id>.disable`/`.ignore` (zizmor's own shape, nested alongside karinto's `severity`) are read directly, so a `ghalint.yaml` or `zizmor.yml` can be pasted straight into one shared `karinto.yaml` instead of kept in separate files. Every source is additive with any `--ghalint-config`/`--zizmor-config` also passed.

Adds `docs/actionlint-migration.md`, mapping actionlint's check categories and `-ignore` habits onto karinto rule IDs, `disable` globs, inline ignores, and `ignore-paths`.
