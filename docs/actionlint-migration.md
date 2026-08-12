# Migrating from actionlint

karinto reimplements the checks it covers from actionlint (plus selected
zizmor and ghalint rules) on a different engine — but it does **not** cover
everything actionlint does; see the gaps below (`shellcheck` / `pyflakes`)
before dropping actionlint from your CI. This page maps what you already
have — actionlint's check categories (`Kind`) and its `-ignore` /
`actionlint.yaml` opt-outs — onto their karinto equivalents, for whatever
karinto does implement.

## Check categories → karinto rule IDs

actionlint reports findings under a coarse `Kind` field (`syntax-check`,
`expression`, `runner-label`, …), not a per-check ID. Each Kind below maps to
every karinto rule ID that can produce the same class of finding — consult
[`rules_catalog.md`](../rules_catalog.md) for what each rule actually checks,
and `karinto --disable` / `karinto.yaml`'s `rules:` if you want to tune one
individually (see [*Ignoring findings*](../README.md#ignoring-findings)).

| actionlint `Kind` | karinto rule IDs |
| --- | --- |
| `syntax-check` | `unexpected-keys`, `missing-required-keys`, `empty-mappings`, `invalid-mapping-values`, `meaningless-comparison`, `permissions-syntax`, `uses-syntax`, `yaml-anchor-issues`, `action-yml-metadata`, `duplicate-job-step-ids`, `invalid-env-var-name`, `reusable-workflow-definition` |
| `expression` | `expression-syntax`, `expression-type-mismatch`, `unknown-context-or-function`, `context-availability`, `expression-steps-type`, `expression-matrix-type`, `expression-needs-type` |
| `events` | `webhook-events`, `workflow-dispatch-inputs`, `cron-and-timezone` |
| `workflow-call` | `reusable-workflow-definition`, `local-action-inputs` |
| `runner-label` | `unknown-runner-label` |
| `glob` | `glob-patterns` |
| `if-cond` | `constant-if-condition` |
| `permissions` | `permissions-syntax` |
| `matrix` | `matrix-values` |
| `action` | `popular-action-inputs`, `outdated-action-version`, `action-yml-metadata`, `uses-syntax`, `deprecated-action-inputs` |
| `id` | `job-step-id-naming`, `duplicate-job-step-ids` |
| `credentials` | `hardcoded-container-credentials` |
| `job-needs` | `job-needs-graph` |
| `deprecated-commands` | `deprecated-workflow-commands` |
| `shell-name` | `shell-name-per-os` |
| `env-var` | `invalid-env-var-name` |
| `shellcheck` | *(none — see below)* |
| `pyflakes` | *(none — see below)* |

`shellcheck` and `pyflakes` have no karinto equivalent and are not planned:
shipping native `shellcheck`/`pyflakes` binaries isn't possible inside a
Cloudflare Worker, and most GitHub-hosted runners don't preinstall
`pyflakes` either, so actionlint's `pyflakes` check silently no-ops in most
CI already. See
[#113](https://github.com/toiroakr/karinto/issues/113) for the narrower,
targeted shell-script rules karinto is building instead of a shellcheck port.

Beyond actionlint's own checks, karinto also folds in most
[zizmor](https://docs.zizmor.sh) and [ghalint](https://github.com/suzuki-shunsuke/ghalint)
rules — see [`rules_catalog.md`](../rules_catalog.md) for the exact status of
each (`Implemented` / `Planned` / `Not planned`) and the
[Coverage](../README.md#coverage) table for the running total.

## `-ignore` → `disable` / inline ignores

actionlint's `-ignore <regex>` flag (and the config file's message-regex
`paths.*.ignore`, see below) suppresses findings by matching a regex against
actionlint's own error message text. karinto has no message-based ignore of
its own — messages are free text and not a stable interface — so most of
this section is still a manual rewrite. The one exception is
`paths.<glob>.ignore` itself, which karinto now honours directly,
best-effort (#50) — see the last bullet.

- **Silencing a rule everywhere**: use `disable` (CLI `--disable`, or the
  Worker's `disable` parameter) with a comma-separated list of rule-ID globs.
  Where actionlint's regex targeted one specific *kind* of finding
  (`-ignore 'label ".+" is unknown'`), find the matching karinto rule ID in
  the table above (`unknown-runner-label`) and disable that instead —
  precise by rule, not by wording.
- **Silencing one finding, in place**: use an inline
  `# karinto: ignore[rule-id]` (or `# zizmor: ignore[rule-id]`) comment on
  the offending line, instead of a workflow-wide regex. See
  [*Ignoring findings*](../README.md#ignoring-findings) for the exact
  placement rules (same-line, "disable next line" on a standalone comment,
  or above a step's own `-` line).
- **Silencing a rule under a path**: pass your `.github/actionlint.yaml`
  straight through as karinto's `--actionlint-config` / the Worker's
  `actionlint` parameter, and its `paths.<glob>.ignore` is honoured
  automatically — each pattern is matched against a curated table of
  actionlint's own canonical messages to identify which check (and karinto
  rule) it targets, then suppressed under the matching `<glob>`:

  ```yaml
  # actionlint.yaml — pass this file directly, no rewrite needed
  paths:
    fixtures/**:
      ignore:
        - 'label ".+" is unknown'
  ```

  This is **best-effort and rule-grained, not message-grained**: it can tell
  "this pattern targets `unknown-runner-label`" but not "only for the label
  `foo`" — every finding of that rule under the glob is suppressed, not just
  the one dynamic value the original regex happened to describe. A pattern
  that doesn't match any curated check is silently ignored (no error, no
  effect). For exact, guaranteed control — or if a pattern doesn't get
  picked up — use `ignore-paths` in a native `karinto.yaml` instead, keyed by
  rule ID rather than message text:

  ```yaml
  # karinto.yaml
  ignore-paths:
    "fixtures/**":
      - unknown-runner-label
  ```

  See [*Ignoring findings*](../README.md#ignoring-findings) for the full
  detail on both mechanisms, including where the automatic one is known to
  fall short (a handful of actionlint checks share one message template, so
  a broad pattern can suppress more than one rule at once — see the doc
  comment on `actionlint_config.mbt`). Everything else in this document
  (the check-category table, and any wording not covered by an inline
  ignore, `disable`, or `paths.<glob>.ignore`) is still a manual rewrite.

## Settings that carry over automatically

Two `.github/actionlint.yaml` settings *are* read directly, because they are
meaning-level config with a clean equivalent and karinto deliberately reuses
actionlint's own key names and shapes for them — pass the same file straight
through as karinto's `--config` / `config`:

- `self-hosted-runner.labels` — your self-hosted runners' extra labels.
- `config-variables` — the `vars.*` allowlist.

See [*Ignoring findings*](../README.md#ignoring-findings) for the full
`karinto.yaml` shape, including the two settings above that have no
actionlint equivalent (`rules` severity overrides, `ignore-paths`).
