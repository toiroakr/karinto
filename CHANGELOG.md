# karinto

## 0.9.5

### Patch Changes

- [#93](https://github.com/toiroakr/karinto/pull/93) [`65d6953`](https://github.com/toiroakr/karinto/commit/65d6953c005d6ae50a51467fe84ef1fddfea8a87) Thanks [@github-actions](https://github.com/apps/github-actions)! - `dependabot-cooldown` now tracks zizmor 1.28.0, which taught the audit about GitHub's new implicit three-day default cooldown ([zizmorcore/zizmor#2193](https://github.com/zizmorcore/zizmor/issues/2193)).

  Three behavioural changes:

  - The pedantic-only "`multi-ecosystem-group` cooldowns do not batch updates correctly" finding is **gone**. An `updates:` entry that joins a `multi-ecosystem-group` while configuring a sufficient cooldown is now silent, matching upstream.
  - An entry with no `cooldown:` block, or one without `default-days`, now reports `insufficient implicit default-days (less than 7)` instead of `missing cooldown configuration` / `no default-days configured` — the entry does get a cooldown, GitHub's implicit one, it's just shorter than the threshold.
  - The rule's severity moves from `info` to `warning`, mirroring upstream: zizmor 1.28.0 promoted the too-short `default-days` case from `help` to `warning`, making every arm of the audit a `warning`. This also changes the SARIF `level` reported for the rule.

  An explicit `default-days` below 7 keeps its existing `insufficient default-days configured (less than 7)` wording.

- [#92](https://github.com/toiroakr/karinto/pull/92) [`e57bc46`](https://github.com/toiroakr/karinto/commit/e57bc46926878dea94f5b5defa57717647c65c90) Thanks [@toiroakr](https://github.com/toiroakr)! - Findings that blame one concrete job or step now carry that attribution instead of only mentioning it in their message. Previously several rules identified the exact offender and then discarded it, emitting a diagnostic with no `job`, `step`, or `pos` — so in a multi-job workflow you couldn't tell which one tripped, and an inline `# karinto: ignore[...]` on the offending line had no effect (it had nowhere to match against).

  Fixed across: `cache-poisoning` (the cache-restoring step), `excessive-permissions` (the per-job "default permissions used" finding, which was the only arm of its own `match` still unattributed), `bot-conditions` (the job's or step's `if:`), `insecure-commands` (the job's or step's `env:`), `invalid-env-var-name` (down to the offending `env:` entry), `overprovisioned-secrets` (the job's or step's `env:`), `job-needs-graph` (the job's `needs:`), `context-availability` (the job's `env:`/`if:`), and `unsound-condition` (the job's or step's `if:`). Workflow-level findings that are genuinely about the document — or about something's _absence_, like `concurrency-limits` — correctly stay unpositioned and keep their file-wide inline-ignore fallback.

  Rule ids, severities, and message text are unchanged; only the location metadata is newly populated.

- [#92](https://github.com/toiroakr/karinto/pull/92) [`c72bb66`](https://github.com/toiroakr/karinto/commit/c72bb6627d57586525a7891e6fa2ee67e7b3705c) Thanks [@toiroakr](https://github.com/toiroakr)! - Fix `github-app-limit-repositories` to no longer flag a GitHub App token request that omits both `owner:` and `repositories:`. Per ghalint's own `ghl-009` doc, omitting both scopes the token to the current repository, which is compliant — the finding now only fires when `owner:` is set without `repositories:` (token spans the whole installation).

- [#92](https://github.com/toiroakr/karinto/pull/92) [`c72bb66`](https://github.com/toiroakr/karinto/commit/c72bb6627d57586525a7891e6fa2ee67e7b3705c) Thanks [@toiroakr](https://github.com/toiroakr)! - Fix `use-trusted-publishing`'s run-based detection to no longer false-positive on `pkg-pr-new` invoked via `pnpm dlx`/`yarn dlx`/`npm exec` (e.g. `pnpm dlx pkg-pr-new@0.0.78 publish ...`). It publishes throwaway preview builds authenticated via the job's own `GITHUB_TOKEN`, not a long-lived npm registry token.

- [#92](https://github.com/toiroakr/karinto/pull/92) [`e9ba6fc`](https://github.com/toiroakr/karinto/commit/e9ba6fc4248641d0cf88ba6fdac31894cdbf54a7) Thanks [@toiroakr](https://github.com/toiroakr)! - Inline `# karinto: ignore[...]` / `# zizmor: ignore[...]` comments now also work as a "disable next line" directive: a comment on its own line (nothing else before the `#`) suppresses a finding on the line directly below it, in addition to same-line placement. A trailing comment on a code line (`run: foo # karinto: ignore[rule]`) still applies only to that line — it never carries over to the next one, so two adjacent findings for the same rule can't collide with each other's ignores. This is most useful for a finding with no owning step (e.g. `undocumented-permissions`, whose `pos` resolves to the `permissions:` field's own line rather than any step), but also works for step-scoped findings when the comment sits on its own line just above the step's `uses:`/`run:` line. For a step-scoped finding, a standalone comment directly above the step's own list-item (`-`) line works too, not just above the specific field `pos` resolves to — useful when a step spans several lines and you'd rather annotate the whole step. The README's "Ignoring findings" section documents both forms.

- [#92](https://github.com/toiroakr/karinto/pull/92) [`c72bb66`](https://github.com/toiroakr/karinto/commit/c72bb6627d57586525a7891e6fa2ee67e7b3705c) Thanks [@toiroakr](https://github.com/toiroakr)! - `undocumented-permissions` findings now carry `pos` (pointing at the `permissions:` key) and, when the block is nested under a job, that job's `job` id — so a workflow with several per-job `permissions:` blocks can trace each finding back to its specific block instead of requiring a manual audit of the whole file.

- [#92](https://github.com/toiroakr/karinto/pull/92) [`6409093`](https://github.com/toiroakr/karinto/commit/640909318caf2f10f117fa2cd5aed61f39c40549) Thanks [@toiroakr](https://github.com/toiroakr)! - `use-trusted-publishing` findings in workflow files are now attributed to the specific step that triggered them (`job` + `step`, with `pos` pointing at that step's `uses:`/`run:` line) instead of only the owning job. This lets an inline `# karinto: ignore[...]` / `# zizmor: ignore[...]` comment placed on the offending step itself suppress the finding, which previously had no effect — the comment had to go on the job's own key line instead.

## 0.9.4

### Patch Changes

- [#84](https://github.com/toiroakr/karinto/pull/84) [`673c594`](https://github.com/toiroakr/karinto/commit/673c594d64ee46e93c2a73467910ce820fd6e3ff) Thanks [@toiroakr](https://github.com/toiroakr)! - Fix `excessive-permissions`'s persona gating for the "default permissions used due to no permissions: block" finding to match zizmor's actual conditions instead of a blanket workflow-level-Pedantic / job-level-Regular split. It's now Pedantic only when the workflow has a single job, every job declares its own `permissions:`, or the workflow is reusable-only (`on:` lists only `workflow_call`); otherwise it's Regular. Reusable-workflow caller jobs (`uses:`) stay Regular regardless, since the caller is responsible for permissions. Previously, karinto missed real Regular-persona findings on multi-job workflows and over-reported on reusable-only workflows' normal jobs.

## 0.9.3

### Patch Changes

- [#81](https://github.com/toiroakr/karinto/pull/81) [`66d1139`](https://github.com/toiroakr/karinto/commit/66d1139de1e5e558f382571d5975a910a23b765e) Thanks [@toiroakr](https://github.com/toiroakr)! - Fix `deploy-preview`'s `replay` job crashing with `ERR_MODULE_NOT_FOUND` because `scripts/diff-rules/2026-06-string-literal-with-promoted.mjs` imported a rule file that `prune-diff-rules.yml`'s automation had already pruned. The composite rule now inlines the logic it depended on instead of importing it.

  Also hardens the automation against recurrence: `prune-diff-rules.yml` now skips removing a rule file that another surviving rule file still imports, and `scripts/replay.mjs` surfaces a clear error (naming the failing file) instead of an opaque crash if a diff-rule import ever breaks again.

## 0.9.2

### Patch Changes

- [#76](https://github.com/toiroakr/karinto/pull/76) [`88e676c`](https://github.com/toiroakr/karinto/commit/88e676cc7ff8711e39c5371bb731a43923af5393) Thanks [@github-actions](https://github.com/apps/github-actions)! - Fix `template-injection` (and other per-step rules) missing findings inside zizmor 1.27's experimental `parallel:` steps. `build_steps` now flattens `parallel:` sub-steps into the step list so `on_step` rules see their `run:`/`uses:` bodies; diagnostics for a nested sub-step report the position of the parent `parallel:` entry.

## 0.9.1

### Patch Changes

- [#64](https://github.com/toiroakr/karinto/pull/64) [`60aee17`](https://github.com/toiroakr/karinto/commit/60aee17dbf23374069c410ee9b79668e7697f99e) Thanks [@toiroakr](https://github.com/toiroakr)! - Fix false negatives and false positives in `outdated-action-version` and `unknown-runner-label`

  **outdated-action-version**

  The rule previously only checked an action file's own `runs.using` field, so
  `actions/checkout@v3` (node16, deprecated) referenced from a workflow step was
  silently ignored. The rule now also inspects `uses:` in workflow steps and fires
  when a well-known action's major version is known to use a deprecated runtime.
  Subpath refs (`actions/cache/restore@v3`), pre-release suffixes (`v3-beta`), and
  mixed-case refs (`Actions/Checkout@v3`) are all normalized correctly. Runtime-upgrade
  backport tags such as `@v3-node20` (which explicitly targets node20) are correctly
  excluded. The diagnostic message now echoes the original ref string from the workflow
  (e.g. `@v3-beta`) rather than reconstructing it as `@v<major>`.

  **unknown-runner-label**

  Two fixes:

  - Removed the `looks_hosted` guard that only flagged labels with an
    `ubuntu-`/`macos-`/`windows-` prefix. Any label absent from the known set is
    now flagged, matching actionlint behavior (fixes false negatives for
    `depot-ubuntu-*`, `codspeed-macro`, etc.).
  - When `self-hosted` is present in a `runs-on` array, the remaining labels are
    routing hints for self-hosted infrastructure. Unknown-label checks are now
    skipped in that case, matching actionlint behavior (fixes false positives for
    `runs-on: [self-hosted, custom-pool]`).

- [#67](https://github.com/toiroakr/karinto/pull/67) [`2b684fd`](https://github.com/toiroakr/karinto/commit/2b684fd6f007a376a7bf8bd79d070c7074e78a79) Thanks [@toiroakr](https://github.com/toiroakr)! - Surface suppressed findings in `LintResult.ignored`

  `LintResult` gains an `ignored` field (type `Array[Diagnostic]`) that collects every finding suppressed by any mechanism: inline `# karinto: ignore[…]` / `# zizmor: ignore[…]` comments, ghalint config excludes, zizmor config `disable`/`ignore`, and the persona gate. The field is omitted from JSON when empty, so existing callers are unaffected.

## 0.9.0

### Minor Changes

- [#62](https://github.com/toiroakr/karinto/pull/62) [`c50ee67`](https://github.com/toiroakr/karinto/commit/c50ee67a408f9d1facad3a7139fb51e3ee63bfc8) Thanks [@toiroakr](https://github.com/toiroakr)! - Honour `zizmor.yml` configs and fix five parity divergences found by diffing
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

### Patch Changes

- [#56](https://github.com/toiroakr/karinto/pull/56) [`19e61a5`](https://github.com/toiroakr/karinto/commit/19e61a588926e1695c1fe27ccb90014fe64f3e12) Thanks [@toiroakr](https://github.com/toiroakr)! - Refactor `check_unknown_context` to reuse the shared `extract_expr_bodies`
  and `strip_expr_string_literals` helpers instead of its own inline `${{ }}`
  extraction and string-literal skipping. The duplicated expression-scanning
  logic is removed and the single-quoted-literal false-positive fix is
  preserved. `extract_expr_bodies` now skips single-quoted literals while
  locating the terminating `}}`, so a `}}` inside a literal (e.g.
  `${{ hashFiles('a}}b') && github.ref }}`) no longer truncates the extracted
  body — this preserves the previous `check_unknown_context` behaviour and also
  hardens the shared `text_references_regular_context` scan against the same
  edge case. The context-access lookahead in `check_unknown_context` now skips
  tabs and newlines (not just spaces) before the `.`, matching the `expr.mbt`
  lexer, so a typo like `${{ githab<TAB>.ref }}` is still flagged.

## 0.8.5

### Patch Changes

- [#58](https://github.com/toiroakr/karinto/pull/58) [`ae00986`](https://github.com/toiroakr/karinto/commit/ae009866c281215a3c97cc2ab39d6729cf59bcbe) Thanks [@toiroakr](https://github.com/toiroakr)! - Honour inline `# zizmor: ignore[...]` / `# karinto: ignore[...]` comments for
  workflow-scoped findings that carry no source position (e.g.
  `cache-poisoning`). When inline ignores became line-scoped, such findings —
  emitted once per workflow without a step/job anchor, so `fill_positions`
  leaves them position-less — could no longer be suppressed by an inline
  comment, because the line-scoped match guarded on a resolved position. The
  opt-out was silently dropped even when the author placed the comment exactly
  where the upstream tool (zizmor) attributes the finding. Position-less
  findings now fall back to a file-wide match: any inline ignore in the file
  that names the rule suppresses it. Positioned findings remain strictly
  line-scoped.

## 0.8.4

### Patch Changes

- [#51](https://github.com/toiroakr/karinto/pull/51) [`733a800`](https://github.com/toiroakr/karinto/commit/733a80021aa1d28b8a6d0f05b9354cc1098018ea) Thanks [@toiroakr](https://github.com/toiroakr)! - Honour author-written opt-outs from the upstream tools karinto consolidates:

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

- [#55](https://github.com/toiroakr/karinto/pull/55) [`82ad616`](https://github.com/toiroakr/karinto/commit/82ad6162d2c5cd4f72ab55fafbb3d619de79366c) Thanks [@toiroakr](https://github.com/toiroakr)! - Fix `unknown-context-or-function` false positive on single-quoted string
  literals containing dots. The scanner walked expression bodies char by char
  without skipping string literals, so a dotted literal like
  `hashFiles('replay-summary.md')` or a bare `'a.b'` was misread as
  `<head>.<member>` context access and reported the head as an unknown context.
  Single-quoted literals are now skipped during the scan, matching the GitHub
  Actions expression language.

## 0.8.3

### Patch Changes

- [#52](https://github.com/toiroakr/karinto/pull/52) [`1a0709d`](https://github.com/toiroakr/karinto/commit/1a0709dd49df59eca38f7ec10d60d2f539f62fac) Thanks [@toiroakr](https://github.com/toiroakr)! - Align `superfluous-actions` and `template-injection` persona gating with real
  zizmor, found by validating karinto against zizmor-using OSS workflows:

  - `superfluous-actions` now uses a per-action persona map (zizmor gates a subset
    — e.g. `peter-evans/create-pull-request`, `dtolnay/rust-toolchain` — behind
    `--pedantic`; the rest fire at the default persona).
  - `template-injection` now flags non-static influenceable contexts (`vars.*`,
    `inputs.*`, `*.outputs.*`, `github.ref*`, `github.actor`, `github.workflow`)
    at the regular persona instead of hiding them on the pedantic backstop.
    `env.*` stays on the backstop because karinto cannot tell a statically-defined
    env var from a dynamic one.

## 0.8.2

### Patch Changes

- [#48](https://github.com/toiroakr/karinto/pull/48) [`09edee2`](https://github.com/toiroakr/karinto/commit/09edee21e71088cababb3ab1adf5863655a0dc4b) Thanks [@toiroakr](https://github.com/toiroakr)! - Fix persona gating for `concurrency-limits` and `excessive-permissions` so
  `persona=regular` matches a default `zizmor` run. Validating against real
  zizmor-using OSS workflows showed karinto emitting two findings at `regular`
  that zizmor only emits under `--pedantic`:

  - `concurrency-limits` is now `pedantic` (it was `regular`).
  - `excessive-permissions` is split: the per-key `<x>: write is overly broad`
    finding is `pedantic`; the blanket `write-all`/`read-all` and "default
    permissions used" findings stay `regular`.

## 0.8.1

### Patch Changes

- [#46](https://github.com/toiroakr/karinto/pull/46) [`31260d6`](https://github.com/toiroakr/karinto/commit/31260d604955878aef97635b393010c90f0109c7) Thanks [@toiroakr](https://github.com/toiroakr)! - Fix four false positives in workflow linting:

  - `invalid-mapping-values`: accept the string form of `concurrency` (valid
    GitHub Actions), not only the mapping form.
  - `unknown-context-or-function`: scan identifiers with hyphen support so a
    `needs.<hyphenated-job-id>` reference is no longer split (the trailing
    segment was misread as an unknown context).
  - `github-app-limit-permissions`: recognize the granular `permission-*` inputs
    of `create-github-app-token`, matching the zizmor `github-app` rule.
  - `unknown-runner-label`: add `ubuntu-slim` to the known GitHub-hosted runner
    labels.

- [#45](https://github.com/toiroakr/karinto/pull/45) [`0c423c7`](https://github.com/toiroakr/karinto/commit/0c423c78d05e59aee299acb78babbab4b73c1699) Thanks [@toiroakr](https://github.com/toiroakr)! - Add `persona` analysis profiles (`regular` / `pedantic` / `auditor`), mirroring
  zizmor's persona model. Each finding declares the minimum persona at which it
  surfaces and the linter filters to the requested level (`regular ⊂ pedantic ⊂
auditor`). The default is `auditor`, so the bare endpoint and CLI keep reporting
  every finding; pass `persona=regular` to match a stock zizmor run.

  Pedantic findings: `anonymous-definition`, `self-hosted-runner`,
  `undocumented-permissions`, and the `template-injection` Info backstop. Auditor
  findings: `secrets-outside-env` and `misfeature`'s `defaults.run.shell: cmd`.
  Available as the `persona` HTTP parameter (invalid values return `400`) and the
  CLI `--persona` flag. The response schema is unchanged.

## 0.8.0

### Minor Changes

- [#43](https://github.com/toiroakr/karinto/pull/43) [`eb8df2f`](https://github.com/toiroakr/karinto/commit/eb8df2fedec30a0b981c3c0f3b2b58e47ae1fe45) Thanks [@toiroakr](https://github.com/toiroakr)! - Promote Dependabot config to a first-class file kind.

  `.github/dependabot.yml` is neither a workflow nor an action, so it was
  previously lumped into the `Unknown` kind and the Dependabot rules
  (`dependabot-cooldown`, `dependabot-execution`) rode along on an
  `unknown_only` predicate. It is now a proper `FileKind::Dependabot`:

  - **Detection** — content-based auto-detect classifies a top-level `updates:`
    key as Dependabot (it is unique to dependabot config; workflows/actions never
    carry it), and the path-based hints (Worker repo mode, CLI, playground) map
    `.github/dependabot.yml` / `.yaml` to it — mirroring how
    `.github/workflows/*` and `action.yml` are recognised.
  - **Explicit override** — `type=dependabot` (API) / `--type dependabot` (CLI)
    force it.
  - The Dependabot rules now run only when the kind is `Dependabot`, and a lint
    of a dependabot config reports `"kind": "dependabot"`.

  This also clears the way for a future "could not determine kind" hint on the
  genuinely-`Unknown` case without false-positiving on dependabot config.

- [#42](https://github.com/toiroakr/karinto/pull/42) [`a6cefd7`](https://github.com/toiroakr/karinto/commit/a6cefd721aaec9eadd3a99c782adc0667e141e20) Thanks [@toiroakr](https://github.com/toiroakr)! - Implement the expression type-inference rule family (#36).

  A new in-tree `${{ … }}` expression parser (lexer + recursive-descent parser

  - small type model in `expr.mbt`) backs four rules that were catalogued as
    `Planned`:

  * **`expression-needs-type`** — types the `needs` context from the job
    dependency graph. Only direct dependencies are members (referencing a
    transitive dependency is an error, matching actionlint), and
    `needs.<job>.outputs` is strict over the dependency's declared `outputs:`
    keys. Reusable-workflow dependencies keep loose outputs.
  * **`expression-steps-type`** — tracks declared step `id`s per job (and per
    composite action) honouring step order: references to unknown or
    not-yet-run steps are errors, as is using `steps.<id>.outputs` as a scalar
    (`steps.gen.outputs == 1`).
  * **`expression-matrix-type`** — flags `matrix.<key>` references not declared
    as a `strategy.matrix` dimension or introduced by an `include:` entry.
    Expression-built matrices disable the check.
  * **`expression-type-mismatch`** — flags arithmetic operators applied to
    known non-number operands (e.g. `'foo' + 1`; the expression language has
    no arithmetic at all).

  Bare `if:` conditions (which GitHub evaluates as expressions even without
  `${{ }}` delimiters) are type-checked the same way. Validated against
  actionlint's real-world dataset (1503 workflows): every file karinto flags
  is also flagged by actionlint's expression checker — zero false positives.

  The model is deliberately conservative: contexts whose shape can't be read
  from the file (`github`, `env`, dynamic ids/matrices, reusable-workflow
  outputs) type as `any` and never fire, and unparseable expressions are
  silently skipped rather than reported (the `expression-syntax` rule
  separately covers `${{` / `}}` delimiter mismatches, not full expression
  grammar). All four rules hold
  zero hard divergences against actionlint's vendored fixtures in the
  upstream-parity check.

- [#39](https://github.com/toiroakr/karinto/pull/39) [`fa0573c`](https://github.com/toiroakr/karinto/commit/fa0573ce82d0e0d4755e298ce907e7f3e5f6d391) Thanks [@toiroakr](https://github.com/toiroakr)! - Turn `cmd/main` into a usable local CLI (#34).

  `cmd/main` was a build sanity-check that linted a hard-coded workflow. It is
  now a real CLI that runs locally with MoonBit's js backend (Node.js):

  - Reads YAML from **stdin** (`cat workflow.yml | moon run --target js cmd/main`)
    or from **file path arguments**
    (`moon run --target js cmd/main -- .github/workflows/ci.yml action.yml`).
  - Reuses the same `@karinto.lint` engine as the Worker, with the same knobs:
    `--type workflow|action` (auto-detected when omitted — file paths also get a
    filename hint: `action.yml` basenames and `.github/workflows/` paths) and
    `--disable` comma-separated rule-ID globs (repeatable).
  - Prints the same JSON envelope as the Worker (`{ok, result}` for stdin;
    `{ok, files: [...]}` for file arguments — each entry is `{path, ok, result}`,
    or `{path, ok: false, error}` without `result` when the file can't be read,
    matching the Worker's repo mode).
  - CI-friendly exit codes: `0` clean, `1` error-severity diagnostics or YAML
    parse errors, `2` usage / IO errors. `moon run` swallows exit codes, so for
    CI run the built bundle directly:
    `moon build --target js --release && node _build/js/release/build/cmd/main/main.js <files>`.

- Repo mode: accept GitHub URL shapes / branch refs, add whole-repo discovery, and gate it behind `REPO_MODE_ENABLED`.

  The `repo`-mode endpoints now go beyond `/owner/repo/<sha>/<path>`:

  - **Domain-swap a GitHub file URL.** `/owner/repo/{blob,tree,raw}/<ref>/<path>`
    is accepted, so swapping `github.com` for the Worker host on a file URL lints
    it. The `ref` can be a branch / tag / `HEAD` / SHA (new `ref=` parameter,
    resolved to that ref's latest commit); `commit=` stays a SHA-only immutable
    pin. The response echoes `ref`, and `commit` only for SHA pins.
  - **Whole-repo discovery.** Bare `/owner/repo` (or `repo=` with no `targets`)
    lints every `.github/workflows/*.{yml,yaml}` file on the default branch via
    the GitHub contents API. This is the only request-path GitHub API call; it
    returns `429` with an actionable message when rate-limited.
  - **Opt-in.** Repo mode (all of the above plus the existing forms) is now
    **disabled by default** and enabled per deployment via the `REPO_MODE_ENABLED`
    variable — it fetches arbitrary public content and draws on GitHub's rate
    limits. Posting the YAML as `content` is always available and is the
    recommended input. Disabled deployments return `403` for repo-mode requests.
  - **Optional auth.** A `GITHUB_PUBLIC_READ_TOKEN` secret, when set, is mirrored
    into each Worker at deploy time and raises the contents-API ceiling from the
    unauthenticated 60 req/hour/IP to 5000/hour (and reaches private repos).

  The GitHub Pages playground now fetches files in the browser and POSTs their
  content to the linter, so its Repo / GitHub URL tabs no longer depend on the
  Worker's repo mode; the **Paste YAML** tab is the default.

  Path-based kind detection (repo mode + playground) now matches the CLI and
  ghalint's conventions: a file under `.github/workflows/` is always a workflow
  (any basename), and only an exact `action.yml` / `action.yaml` basename is an
  action — fixing a false positive where a workflow like `release-action.yml` was
  hinted as an action.

- [#41](https://github.com/toiroakr/karinto/pull/41) [`c64dc83`](https://github.com/toiroakr/karinto/commit/c64dc83b41d2bf40aa80bda8bfde50941a4cbb19) Thanks [@toiroakr](https://github.com/toiroakr)! - Add SARIF 2.1.0 output (#33) alongside the JSON envelope, so findings can be
  uploaded to GitHub Code Scanning via `github/codeql-action/upload-sarif`.

  - **Engine** — new `sarif_report(entries, io_errors?, version?)` builds a
    complete SARIF document: `rule` → `result.ruleId` plus a
    `tool.driver.rules[]` entry (catalogue title, default severity, upstream
    origins), `severity` → `level` (`info` → `note`), `pos` →
    `physicalLocation.region`, `job`/`step` → `logicalLocations[]`, YAML parse
    errors → a synthetic `parse-error` rule, unreadable inputs →
    `invocations[].toolExecutionNotifications`. `tool.driver.version` is
    stamped from a new `ENGINE_VERSION` constant kept in lockstep with
    `package.json` / `moon.mod` by `scripts/sync-moon-version.mjs`.
  - **Worker** — new `format=sarif` parameter (`content` and `repo` modes;
    response content type `application/sarif+json`). In `content` mode an
    optional `path=` labels the artifact so results get a `physicalLocation`;
    in `repo` mode targets already carry paths and the whole batch lands in
    one SARIF run. JSON stays the default — existing callers are unaffected.
  - **CLI** — new `--format json|sarif` (`-f`). File arguments become artifact
    URIs; stdin yields pathless results. Exit codes are format-independent.

## 0.7.0

### Minor Changes

- [#38](https://github.com/toiroakr/karinto/pull/38) [`e806129`](https://github.com/toiroakr/karinto/commit/e80612997287f6f908e49d9160616c965d6f3e4f) Thanks [@toiroakr](https://github.com/toiroakr)! - Carry source line/column positions on diagnostics (#35), and replace the YAML
  parser to make it possible.

  Each diagnostic tied to a concrete job or step now includes a `pos` field —
  `{ "line": <1-based>, "col": <1-based> }`. Where a finding concerns a specific
  field it points at that field's node (the `uses:` value, the `run:` script, the
  `permissions:` key); otherwise it falls back to the job key or step entry. The
  field is optional and omitted for workflow-global findings, so existing
  consumers are unaffected; `job` / `step` remain fallback handles.

  To obtain positions, karinto **drops the `moonbit-community/yaml` dependency** in
  favour of a new in-tree parser, `yamlpos`: a MoonBit port of the
  [eemeli/yaml](https://github.com/eemeli/yaml) design — a layered lexer →
  offset-range CST → composed AST with first-class source ranges, plus a
  `LineCounter` that resolves line/column lazily. It parses full YAML 1.2 (block +
  flow, anchors/aliases, tags, all block-scalar styles, merge keys, multi-doc) and
  decodes scalar values, so it is a drop-in replacement for the rule engine's
  value tree (rule behaviour is unchanged) while additionally exposing positions.

  We prototyped and benchmarked both forking the existing parser and porting
  eemeli/yaml from scratch; the port won on size, position design (offset-first
  ranges + lazy line/col), and not carrying a fork.

  This unblocks richer integrations — SARIF `physicalLocation` and GitHub Actions
  inline annotations.

### Patch Changes

- [#31](https://github.com/toiroakr/karinto/pull/31) [`c27d3ef`](https://github.com/toiroakr/karinto/commit/c27d3efa9e3053da4b49b461b879a90dd505ea0a) Thanks [@toiroakr](https://github.com/toiroakr)! - Replace deprecated MoonBit standard-library APIs with their current
  equivalents to keep the codebase warning-free on recent toolchains:

  - `StringView::to_string()` → `to_owned()`
  - `String::substring(...)` → slice syntax `s[a:b]` (plus `to_owned()` where an
    owned `String` is required)
  - `not(expr)` → `!expr`
  - `Map::new()` → `{}`
  - `.size()` → `.length()`

  Also migrate the module manifest from the deprecated `moon.mod.json` to the
  current `moon.mod` format (required by recent toolchains) and update the
  release version-sync script and docs accordingly.

  This is an internal refactor only; there are no changes to the public
  interface (`.mbti` is unchanged) or runtime behaviour.

## 0.6.0

### Minor Changes

- [#26](https://github.com/toiroakr/karinto/pull/26) [`ce5b640`](https://github.com/toiroakr/karinto/commit/ce5b64034f42d4f692bf4880f100b5aad572a897) Thanks [@toiroakr](https://github.com/toiroakr)! - Action-side online audits, split by how cacheable the underlying fact is.

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

## 0.5.0

### Minor Changes

- [#24](https://github.com/toiroakr/karinto/pull/24) [`a13d4a3`](https://github.com/toiroakr/karinto/commit/a13d4a3241b60d2388178bacf14dcd154ada52d1) Thanks [@toiroakr](https://github.com/toiroakr)! - Diagnostics now carry location context. Each finding may include a `job` field
  (the offending job's ID) and a `step` field (`{ index, id }`, where `index` is
  the 0-based position in the steps list and `id` is the step's `id:` when
  declared). Job-scoped and step-scoped rules attach this automatically. Rules
  that walk jobs/steps themselves also populate it: `duplicate-job-step-ids`,
  `anonymous-definition`, and `job-step-id-naming`. Step-specific findings raised
  from job-scoped rules (`artipacked`, `superfluous-actions`, `shell-name-per-os`)
  now carry the offending step too, not just the job. The YAML parser drops source
  layout, so diagnostics still have no line/column positions — `job`/`step` are
  the location handles instead.

## 0.4.0

### Minor Changes

- [#21](https://github.com/toiroakr/karinto/pull/21) [`bf23c93`](https://github.com/toiroakr/karinto/commit/bf23c930bd563f77a97d7e165ebe3cdfbb537edc) Thanks [@toiroakr](https://github.com/toiroakr)! - Make the engine pinnable for reproducible CI. Every response now carries an
  `engine_version` field (on both success and error paths) so callers can assert
  the deployed engine hasn't drifted.

  Each release additionally deploys two extra Workers alongside the always-latest
  one:

  - `karinto-vX-Y-Z.toiroakr.workers.dev` — an immutable snapshot frozen to
    that release's bundle (dots → dashes). The maximally-strict pin for CI.
  - `karinto-vX.toiroakr.workers.dev` — a major alias that tracks the latest
    patch within major `X`. Rolls forward across patches and minors, shielded
    from breaking-change bumps.

  Exact-version snapshots are auto-pruned on each release down to _(the latest
  patch within every major)_ ∪ _(the top `PINNED_KEEP_RECENT` versions by
  SemVer, default 50)_ ∪ _(the just-released version)_, so the latest patch
  of every released major remains available as an exact pin indefinitely.
  Major aliases are never auto-deleted.

  Each release also pushes a dashed lightweight git tag (`v0-3-2` pointing at
  the same commit as `v0.3.2`) used by the new shareable Renovate preset
  (`github>toiroakr/karinto:pin`), which auto-PRs version bumps for
  `karinto-vX-Y-Z.toiroakr.workers.dev` URL pins and `engine_version`
  assertions in downstream repos.

  Full pinning guide — including the 404 risk for long-untouched exact pins,
  self-hosting on your own Cloudflare account, and the Renovate preset — in
  [`docs/pinning.md`](docs/pinning.md).

## 0.3.1

### Patch Changes

- [#18](https://github.com/toiroakr/karinto/pull/18) [`567f6c7`](https://github.com/toiroakr/karinto/commit/567f6c7ea362e7f857ab6cd0baf30947d8f00f50) Thanks [@toiroakr](https://github.com/toiroakr)! - Add a `preview-pages` workflow that uploads `docs/` as an unzipped artifact
  (`actions/upload-artifact@v7` with `archive: false`, Feb 2026 feature) on
  every PR touching the docs. The sticky PR comment links straight to the
  artifact so reviewers can open `index.html` in the browser without a
  GitHub Pages deploy.

## 0.3.0

### Minor Changes

- [#16](https://github.com/toiroakr/karinto/pull/16) [`3b37ddf`](https://github.com/toiroakr/karinto/commit/3b37ddfd12998d9da91071aedc1eb0f9c2a3eb07) Thanks [@toiroakr](https://github.com/toiroakr)! - Add a GitHub Pages playground (`docs/index.html`) where users can enter
  `owner/repo` and a workflow/action file path; the page resolves the latest
  commit on the default branch via the GitHub API and calls the karinto
  Worker, showing the JSON response inline. Deployment is automated through
  `.github/workflows/deploy-pages.yml`.

  The Worker (`cf/index.js`) now emits `Access-Control-Allow-Origin: *` on
  every JSON response so browser-based clients (including the new
  playground) can read the body. The API was already public and
  credential-less, so this is purely additive.

## 0.2.1

### Patch Changes

- [#14](https://github.com/toiroakr/karinto/pull/14) [`0b4fa3a`](https://github.com/toiroakr/karinto/commit/0b4fa3ab33b791afaac44969c34212adc4adc989) Thanks [@toiroakr](https://github.com/toiroakr)! - Promote every `Planned` zizmor rule in the catalogue to `Implemented` and drive
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

## 0.2.0

### Minor Changes

- [#5](https://github.com/toiroakr/karinto/pull/5) [`db305e6`](https://github.com/toiroakr/karinto/commit/db305e6427355ae48f07bc894f7cdc89cb4326dd) Thanks [@toiroakr](https://github.com/toiroakr)! - Catalog overhaul:

  - Add `rules_catalog.md` as a human-readable mirror of `rules_catalog.mbt`,
    with upstream documentation links, status, severity, and per-rule notes
    on the five consolidations and on every planned/not-planned rule.
  - Introduce a third `Status` variant, `NotPlanned`, for rules that are
    documented but deliberately out of scope. Demote `shellcheck` and
    `pyflakes` (Cloudflare Workers cannot ship the native binaries),
    `ref-confusion` (cannot occur once `unpinned-uses` mandates SHA pins),
    and `stale-action-refs` (GitHub API cost not worth the informational
    signal) to `NotPlanned` and drop their `#skip("not implemented yet")`
    fixtures. Coverage test now only requires fixtures for
    `Implemented`/`Planned` entries.
  - `AGENTS.md` (and `CLAUDE.md`, now a symlink to it) gains a "Rule catalog
    discipline" section requiring `rules_catalog.mbt` and `rules_catalog.md`
    to be updated together.

- [#8](https://github.com/toiroakr/karinto/pull/8) [`bfa0c9c`](https://github.com/toiroakr/karinto/commit/bfa0c9c146abc1dd7249caff7a87cac2fd364e2d) Thanks [@toiroakr](https://github.com/toiroakr)! - Allow specifying `org/repo/commit[/target/path/...]` directly in the request
  URL path (e.g. `GET /actions/checkout/<sha>/action.yml`, or with nested
  targets like `.github/workflows/ci.yml`), and require a commit SHA whenever
  `repo` mode is used. The `commit` parameter accepts 7–64 hex characters,
  so non-hex branch/tag names (e.g. `main`, `v1.2.3`) are rejected outright.
  Hex-shaped refs are still accepted at face value, so an all-hex branch or
  tag (e.g. `deadbee`) can collide with a short-SHA-shaped commit; callers
  needing guaranteed immutability should pass the full 40-char SHA. Path
  segments that don't match the repo-mode shape are ignored, so the Worker
  can be served under arbitrary path prefixes (`/api/...`, `/favicon.ico`,
  etc.) without bricking unrelated requests. Responses in `repo` mode now
  include the resolved `commit` alongside `repo` and `targets`.

  Path-based targets bypass the comma-delimited `targets=` parsing, so a
  literal `,` in a path no longer splits one file into two. Each target path
  is also validated to reject `..`, absolute, backslash, and percent-encoded
  forms that could escape the pinned `<commit>` prefix once interpolated
  into the `raw.githubusercontent.com` URL.

### Patch Changes

- [#9](https://github.com/toiroakr/karinto/pull/9) [`800c4f6`](https://github.com/toiroakr/karinto/commit/800c4f6a26cca2e5b82197a296ad5ef1c3ec6053) Thanks [@toiroakr](https://github.com/toiroakr)! - Harden DoS/ReDoS surface:

  - Replace the recursive backtracking glob matcher behind the `disable=`
    parameter with a two-pointer "last-star backtrack" algorithm, so
    adversarial patterns such as `*a*a*…*b` against long inputs can no
    longer cause exponential CPU usage. (The matcher is not strictly
    linear — worst case is `O(m·n)` — but the `disable=` caps below keep
    the bound small enough that DoS via this path is not feasible.)
  - Cloudflare Worker now enforces a 1 MiB cap on request bodies and on
    files fetched in `repo` mode. Oversized direct payloads short-circuit
    with `413 Payload Too Large` before reaching the parser / rules.
    In `repo` mode the request still returns `200` with the per-file
    error surfaced under `files[].error` so a single oversized file does
    not invalidate results for the rest of the batch.
  - `disable=` patterns are limited to one `*` each (more than one returns
    `400`), and capped at 64 patterns × 128 characters per pattern.
  - `targets=` (in `repo` mode) is capped at 50 paths. Requests over the
    cap are rejected with `400` rather than silently truncated, so clients
    don't get an `ok:true` response that quietly skipped files.
  - Add a 60 req/min per-IP rate limit via the Workers Rate Limiting
    binding. Traffic from GitHub-hosted Actions runners is exempt
    because runners share egress IPs across unrelated tenants; the
    allow-list is sourced from `api.github.com/meta` and refreshed daily
    by a Cron Trigger into a KV namespace, with the request path reading
    from KV (memoized per isolate) and a one-shot direct-fetch fallback
    for the cold-deploy case. Over-limit requests get `429`.
  - Deploy note: this introduces a `KV` namespace and a `triggers.crons`
    entry in `cf/wrangler.jsonc`. Run `npx wrangler kv namespace create
karinto-meta` once and paste the returned id into both the top-level
    and `env.staging` `kv_namespaces` blocks — production and staging
    share the namespace because the `/meta` payload is GitHub-published
    and identical across envs.
  - Regression test exercises the previously catastrophic pattern.

## 0.1.0

### Minor Changes

- [#1](https://github.com/toiroakr/karinto/pull/1) [`4f4267c`](https://github.com/toiroakr/karinto/commit/4f4267c5a31c7ca25f7f0d9dc79dfbbc482f8636) Thanks [@toiroakr](https://github.com/toiroakr)! - Initial release.

  - MoonBit lint engine (`karinto.mbt` + `rules.mbt`) with 62 implemented rules
    derived from actionlint, zizmor, and ghalint. 22 additional rules are
    scaffolded as `#skip` specs.
  - Cloudflare Worker (`cf/index.js`) accepting `GET`/`POST` with workflow YAML,
    form-encoded params, JSON body, or repo-mode dispatch.
  - OSV.dev integration for `known-vulnerable-actions` (opt-in via `osv=1`).
  - Curl-driven smoke check at `cf/smoke.sh` runnable as `npm run smoke`.
  - Changesets-managed Release PR flow that cuts the production deploy and
    GitHub Release on merge.
  - Per-PR preview Workers (`karinto-pr-<N>.toiroakr.workers.dev`) auto-deployed
    and cleaned up.
  - Staging Worker (`karinto-staging.toiroakr.workers.dev`) auto-deployed on
    every push to `main`.
