# karinto Rules Catalog

Human-readable mirror of [`rules_catalog.mbt`](rules_catalog.mbt) — the
source of truth for rule **metadata** (status, severity, upstream origins),
enforced by `coverage_test.mbt`. The runtime rule registry that drives
lint execution lives in `rules.mbt` (`all_rules()`); editing the catalogue
does not by itself change engine behaviour. Keep both files in sync; see
[`AGENTS.md`](AGENTS.md) (CLAUDE.md is a symlink to it) for the update rule.

82 catalogued rules: **61 implemented**, **17 planned**, **4 not planned**,
plus **5 upstream checks consolidated** into existing karinto rules (see
below).

## Status legend

- **Implemented** — rule logic lives in [`rules.mbt`](rules.mbt); fixtures
  are active in the per-source `*_rules_test.mbt` and karinto matches the
  upstream's full firing scope (verified by `upstream-parity`).
- **Planned** — implementation pending or *preview-quality*. A `Planned`
  entry can mean either (a) only `#skip("not implemented yet")` fixtures
  exist, or (b) `rules.mbt` ships a narrower implementation that fires on a
  subset of the upstream's cases. `upstream-parity` gates `Planned` rules
  out of the hard-divergence count; promote back to `Implemented` once the
  gap to upstream is closed.
- **Not planned** — deliberately out of scope (runtime constraint, or
  already covered by another karinto rule). No fixture is kept.
- **Consolidated** — the upstream check is fully covered by another karinto
  rule (see [Consolidations](#consolidations)). Not a status of its own;
  these upstreams have no standalone catalogue entry.

## Upstream documentation roots

| Family | Docs |
| --- | --- |
| actionlint | <https://github.com/rhysd/actionlint/blob/main/docs/checks.md> |
| zizmor | <https://docs.zizmor.sh/audits/> |
| ghalint | <https://github.com/suzuki-shunsuke/ghalint/tree/main/docs/policies> |

Per-rule deep links below use these roots. Origin strings (e.g.
`actionlint:unexpected-keys`) are the verbatim tags stored in the catalog's
`origins` array.

## Consolidations

karinto merges five overlapping upstream checks into a single rule each.
The `origins` array on every consolidated entry preserves the lineage so
the diagnostic provenance is never lost.

| karinto rule | Absorbed upstream(s) | Rationale |
| --- | --- | --- |
| [`unpinned-uses`](#supply-chain--security-zizmor) | `zizmor:unpinned-uses` + [`ghalint:ghl-008`](https://github.com/suzuki-shunsuke/ghalint/blob/main/docs/policies/008.md) | Both demand `uses:` pinned to a full-length commit SHA; ghalint is a strict subset of the zizmor audit. |
| [`secrets-inherit`](#supply-chain--security-zizmor) | `zizmor:secrets-inherit` + [`ghalint:ghl-004`](https://github.com/suzuki-shunsuke/ghalint/blob/main/docs/policies/004.md) | Same check: forbid blanket `secrets: inherit` in callers. |
| [`unpinned-images`](#supply-chain--security-zizmor) | `zizmor:unpinned-images` + [`ghalint:ghl-007`](https://github.com/suzuki-shunsuke/ghalint/blob/main/docs/policies/007.md) | `ghl-007` ("forbid `:latest` container image") is one concrete case of zizmor's broader "not pinned by digest" audit. |
| [`hardcoded-container-credentials`](#supply-chain--security-zizmor) | `zizmor:hardcoded-container-credentials` + `actionlint:hardcoded-credentials` | Identical coverage — plaintext credentials on `container:` / `services:`. |
| [`template-injection`](#supply-chain--security-zizmor) | `zizmor:template-injection` + `actionlint:script-injection` | Same taint analysis: untrusted `${{ … }}` interpolated into `run:`. |

## actionlint family

| ID | Origin | Severity | Status | Notes |
| --- | --- | --- | --- | --- |
| `unexpected-keys` | [`actionlint:unexpected-keys`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Implemented | |
| `missing-required-keys` | [`actionlint:missing-required-keys`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Implemented | |
| `empty-mappings` | [`actionlint:empty-mappings`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | warning | Implemented | |
| `invalid-mapping-values` | [`actionlint:invalid-mapping-values`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Implemented | |
| `expression-syntax` | [`actionlint:expression-syntax`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Implemented | |
| `expression-type-mismatch` | [`actionlint:expression-type-mismatch`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Planned | Type inference is non-trivial — fixtures scaffolded but engine work pending. |
| `unknown-context-or-function` | [`actionlint:unknown-context-or-function`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Implemented | |
| `context-availability` | [`actionlint:context-availability`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Implemented | |
| `expression-steps-type` | [`actionlint:steps-id-type`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Planned | Requires per-step type tracking; fixtures in place. |
| `expression-matrix-type` | [`actionlint:matrix-type`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Planned | Requires matrix expansion model; fixtures in place. |
| `expression-needs-type` | [`actionlint:needs-type`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Planned | Requires job dependency graph typing; fixtures in place. |
| `meaningless-comparison` | [`actionlint:meaningless-comparison`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | warning | Implemented | |
| `shellcheck` | [`actionlint:shellcheck-on-run`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | warning | Not planned | Cloudflare Workers cannot ship native `shellcheck` binaries; no in-pure-JS substitute that matches actionlint coverage. |
| `pyflakes` | [`actionlint:pyflakes-on-python-run`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | warning | Not planned | Same Worker-runtime constraint as `shellcheck`. |
| `job-needs-graph` | [`actionlint:job-needs-graph`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Implemented | |
| `matrix-values` | [`actionlint:matrix-values`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Planned | Preview implementation: detects duplicate scalar entries in `strategy.matrix.<key>` arrays. `include`/`exclude` validation against the matrix configuration (the bulk of upstream coverage) is still pending. |
| `webhook-events` | [`actionlint:webhook-events`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Implemented | |
| `workflow-dispatch-inputs` | [`actionlint:workflow-dispatch-inputs`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Implemented | |
| `glob-patterns` | [`actionlint:glob-patterns`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Implemented | |
| `cron-and-timezone` | [`actionlint:cron-and-timezone`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Implemented | |
| `unknown-runner-label` | [`actionlint:runner-label`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | warning | Implemented | |
| `uses-syntax` | [`actionlint:uses-syntax`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Implemented | |
| `local-action-inputs` | [`actionlint:local-action-inputs`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Planned | Requires resolving local `action.yml` files; fixtures in place. |
| `popular-action-inputs` | [`actionlint:popular-action-inputs`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Planned | Requires bundling popular-action metadata; fixtures in place. |
| `outdated-action-version` | [`actionlint:outdated-popular-action-version`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | warning | Implemented | |
| `shell-name-per-os` | [`actionlint:shell-name`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Implemented | |
| `duplicate-job-step-ids` | [`actionlint:duplicate-job-step-ids`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Implemented | |
| `invalid-env-var-name` | [`actionlint:env-var-name`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | warning | Implemented | |
| `permissions-syntax` | [`actionlint:permissions-scope-and-value`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Implemented | |
| `reusable-workflow-definition` | [`actionlint:reusable-workflow`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Implemented | |
| `job-step-id-naming` | [`actionlint:job-step-id-naming`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | warning | Implemented | |
| `deprecated-workflow-commands` | [`actionlint:deprecated-workflow-commands`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | warning | Implemented | |
| `constant-if-condition` | [`actionlint:constant-if-condition`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | warning | Implemented | |
| `action-yml-metadata` | [`actionlint:action-yml-metadata`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | error | Implemented | Applies to `action.yml` only. |
| `deprecated-action-inputs` | [`actionlint:deprecated-popular-action-inputs`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | warning | Planned | Preview implementation: ~5 popular-action deprecations (setup-node `version`→`node-version`, setup-python `python_version`→`python-version`, setup-go/setup-java/setup-dotnet `version`→`<lang>-version`). actionlint bundles ~200 entries; promote to Implemented once the full popular-actions catalogue ships. |
| `yaml-anchor-issues` | [`actionlint:yaml-anchors`](https://github.com/rhysd/actionlint/blob/main/docs/checks.md) | warning | Implemented | Re-scans the raw source for `&name` declarations / `*name` aliases (the YAML parser resolves them away) and flags anchors that were declared but never referenced. |

## Supply-chain & security (zizmor)

Per-audit anchors below follow the pattern `https://docs.zizmor.sh/audits/#<id>`.

| ID | Origin | Severity | Status | Notes |
| --- | --- | --- | --- | --- |
| `anonymous-definition` | [`zizmor:anonymous-definition`](https://docs.zizmor.sh/audits/#anonymous-definition) | info | Implemented | |
| `archived-uses` | [`zizmor:archived-uses`](https://docs.zizmor.sh/audits/#archived-uses) | warning | Implemented | Mirrors zizmor's hardcoded offline baseline (`actions/setup-ruby`) so the rule fires without network access; Worker extends it via `archived_uses=` (CSV on the worker boundary as `?archived=…`) once GitHub reports `archived: true`. Comparison is case-insensitive and operates on the bare `owner/repo` (subpath stripped). |
| `artipacked` | [`zizmor:artipacked`](https://docs.zizmor.sh/audits/#artipacked) | warning | Implemented | Fires on every `actions/checkout` that lacks literal `persist-credentials: false` — covers workflows and composite actions, YAML anchors/aliases, templated `persist-credentials:` values (`${{ … }}`), and `with: ${{ fromJson(...) }}` (lower-confidence "may not set"). Auditor-only `persist-credentials: true` is suppressed under the Regular persona to match zizmor `--pedantic`. |
| `bot-conditions` | [`zizmor:bot-conditions`](https://docs.zizmor.sh/audits/#bot-conditions) | error | Implemented | |
| `cache-poisoning` | [`zizmor:cache-poisoning`](https://docs.zizmor.sh/audits/#cache-poisoning) | error | Implemented | Fires when a publishing job restores from cache. Publishing is detected via workflow triggers (`on: release`, `push.tags`, or `push.branches` containing `"release"`) or via a known publisher action (`pypa/gh-action-pypi-publish`, `softprops/action-gh-release`, `goreleaser/goreleaser-action`, `docker/build-push-action` when `push:` is not literally `false`, the AWS / Azure / Google Cloud / Cloudflare deploy actions, etc.). Cache-aware actions (`actions/cache`, `actions/setup-*`, `astral-sh/setup-uv`, `Swatinem/rust-cache`, `docker/setup-buildx-action`, `ramsey/composer-install`, …) are classified per upstream's `Always` / `DefaultBehaviour` / `OptIn` / `OptOut` model with `${{ … }}` expressions evaluated under the tag-push assumption so the tag-only conditional case stays accurate. |
| `concurrency-limits` | [`zizmor:concurrency-limits`](https://docs.zizmor.sh/audits/#concurrency-limits) | info | Implemented | |
| `dangerous-triggers` | [`zizmor:dangerous-triggers`](https://docs.zizmor.sh/audits/#dangerous-triggers) | error | Implemented | |
| `dependabot-cooldown` | [`zizmor:dependabot-cooldown`](https://docs.zizmor.sh/audits/#dependabot-cooldown) | info | Implemented | Applies to `dependabot.yml`. Each `updates:` entry is inspected for: missing `cooldown:` block, missing `default-days`, `default-days` below the upstream threshold of 7, and the pedantic-only "`multi-ecosystem-group` with an effective cooldown" pattern. |
| `dependabot-execution` | [`zizmor:dependabot-execution`](https://docs.zizmor.sh/audits/#dependabot-execution) | error | Implemented | Fires on `insecure-external-code-execution: allow` in any `dependabot.yml` update entry. |
| `excessive-permissions` | [`zizmor:excessive-permissions`](https://docs.zizmor.sh/audits/#excessive-permissions) | warning | Planned | Preview implementation lives in `rules.mbt` but the permissions inheritance / read-write semantics are narrower than upstream. |
| `forbidden-uses` | [`zizmor:forbidden-uses`](https://docs.zizmor.sh/audits/#forbidden-uses) | warning | Implemented | Denylist threaded via `forbidden_uses` (CSV on the worker boundary as `?forbidden=…`). Each entry is a glob matched against both the bare `owner/repo[/subpath]` and the full `…@ref`. Empty list keeps the rule dormant. |
| `github-app` | [`zizmor:github-app`](https://docs.zizmor.sh/audits/#github-app) | warning | Implemented | Fires on `actions/create-github-app-token` for `skip-token-revoke` (non-false), `owner` without `repositories`, and missing `permission-*` inputs. |
| `github-env` | [`zizmor:github-env`](https://docs.zizmor.sh/audits/#github-env) | error | Implemented | Fires on non-literal writes to `$GITHUB_ENV` / `$GITHUB_PATH` (bash `$VAR`/`${VAR}`, pwsh `$env:VAR`, cmd `%VAR%`) — static writes are silent. Workflow steps require a dangerous trigger (`pull_request_target` / `workflow_run`); composite-action steps are checked unconditionally. Upstream uses tree-sitter for shell parsing; karinto's heuristic is regex-class. |
| `hardcoded-container-credentials` | [`zizmor:hardcoded-container-credentials`](https://docs.zizmor.sh/audits/#hardcoded-container-credentials) + `actionlint:hardcoded-credentials` | error | Implemented | **Consolidated** — absorbs the matching actionlint check. |
| `impostor-commit` | [`zizmor:impostor-commit`](https://docs.zizmor.sh/audits/#impostor-commit) | error | Implemented | Offline-silent (mirrors zizmor `--no-online-audits`); the Worker resolves SHA membership via the GitHub API and passes the confirmed-impostor `owner/repo@sha` list as `impostor_uses=` CSV. |
| `insecure-commands` | [`zizmor:insecure-commands`](https://docs.zizmor.sh/audits/#insecure-commands) | warning | Implemented | Scans workflow / job / step / composite-action `env:` blocks for `ACTIONS_ALLOW_UNSECURE_COMMANDS=true`. |
| `known-vulnerable-actions` | [`zizmor:known-vulnerable-actions`](https://docs.zizmor.sh/audits/#known-vulnerable-actions) | error | Implemented | Optional OSV.dev lookup via `osv=1` query parameter. |
| `misfeature` | [`zizmor:misfeature`](https://docs.zizmor.sh/audits/#misfeature) | info | Implemented | Detects `defaults.run.shell: cmd` (workflow / job), `actions/setup-python` with `pip-install:` input, and job-level `continue-on-error: true`. |
| `obfuscation` | [`zizmor:obfuscation`](https://docs.zizmor.sh/audits/#obfuscation) | info | Implemented | Detects path-segment tricks in `uses:` (empty / `.` / `..` / percent-encoded refs), constant-reducible `${{ ... }}` expressions, computed index access (`foo[bar.baz]`), and expression-based `with:` mappings that prevent static analysis. |
| `overprovisioned-secrets` | [`zizmor:overprovisioned-secrets`](https://docs.zizmor.sh/audits/#overprovisioned-secrets) | warning | Implemented | Detects `toJSON(secrets)` / `toJson(secrets)` in job- or step-level `env:` blocks. |
| `ref-confusion` | [`zizmor:ref-confusion`](https://docs.zizmor.sh/audits/#ref-confusion) | warning | Not planned | The hazard (a `uses:` ref that could mean a tag or a branch) cannot arise in workflows that already comply with karinto's `unpinned-uses` SHA-pin requirement. |
| `ref-version-mismatch` | [`zizmor:ref-version-mismatch`](https://docs.zizmor.sh/audits/#ref-version-mismatch) | warning | Implemented | Offline-silent (mirrors zizmor `--no-online-audits`); the Worker resolves tag → SHA via the GitHub API and passes the confirmed-mismatch `owner/repo@sha` list as `ref_mismatches=` CSV. |
| `secrets-inherit` | [`zizmor:secrets-inherit`](https://docs.zizmor.sh/audits/#secrets-inherit) + [`ghalint:ghl-004`](https://github.com/suzuki-shunsuke/ghalint/blob/main/docs/policies/004.md) | error | Implemented | **Consolidated** — absorbs ghalint `deny_inherit_secrets`. |
| `secrets-outside-env` | [`zizmor:secrets-outside-env`](https://docs.zizmor.sh/audits/#secrets-outside-env) | warning | Implemented | |
| `self-hosted-runner` | [`zizmor:self-hosted-runner`](https://docs.zizmor.sh/audits/#self-hosted-runner) | warning | Implemented | Fires whenever `runs-on` includes `self-hosted` (string, list, or `{labels:…}` form). Upstream gates this audit on `--persona=auditor`; karinto has no persona system and reports always — two zizmor fixtures are allowlisted to document the intentional divergence. |
| `stale-action-refs` | [`zizmor:stale-action-refs`](https://docs.zizmor.sh/audits/#stale-action-refs) | info | Not planned | Would require a GitHub API call to enumerate tags reachable from a SHA. The signal is only informational (severity `info`); the API/latency/rate-limit cost is not worth it. |
| `superfluous-actions` | [`zizmor:superfluous-actions`](https://docs.zizmor.sh/audits/#superfluous-actions) | info | Implemented | Mirrors upstream's full `SUPERFLUOUS_ACTIONS` catalogue (release-action / create-or-update-comment / docker-run-action / rust-toolchain / git-auto-commit / etc.) for both workflow jobs and composite-action steps. |
| `template-injection` | [`zizmor:template-injection`](https://docs.zizmor.sh/audits/#template-injection) + `actionlint:script-injection` | error | Planned | **Consolidated** — absorbs the matching actionlint taint check. Preview implementation matches simple `${{ … }}` patterns; full upstream parity needs an expression parser + uses-sink catalogue. |
| `undocumented-permissions` | [`zizmor:undocumented-permissions`](https://docs.zizmor.sh/audits/#undocumented-permissions) | info | Implemented | Re-scans raw source to honour comments; skips `contents: read`-only blocks. |
| `unpinned-images` | [`zizmor:unpinned-images`](https://docs.zizmor.sh/audits/#unpinned-images) + [`ghalint:ghl-007`](https://github.com/suzuki-shunsuke/ghalint/blob/main/docs/policies/007.md) | warning | Implemented | **Consolidated** — absorbs ghalint `deny_job_container_latest_image`. Covers job-level `container.image` (including `${{ matrix.X }}` expansions through `matrix.include`) and docker-action `runs.image`. Upstream additionally handles top-level `services:`. |
| `unpinned-tools` | [`zizmor:unpinned-tools`](https://docs.zizmor.sh/audits/#unpinned-tools) | warning | Implemented | Detects `curl|wget | sh` patterns plus tool-installer actions (`aquasecurity/setup-trivy`, `1password/load-secrets-action`) whose `with.version` is implicit, `latest`, or expression-based. Upstream's tool-installer catalogue is broader. |
| `unpinned-uses` | [`zizmor:unpinned-uses`](https://docs.zizmor.sh/audits/#unpinned-uses) + [`ghalint:ghl-008`](https://github.com/suzuki-shunsuke/ghalint/blob/main/docs/policies/008.md) | warning | Implemented | **Consolidated** — absorbs ghalint `action_ref_should_be_full_length_commit_sha`. |
| `unredacted-secrets` | [`zizmor:unredacted-secrets`](https://docs.zizmor.sh/audits/#unredacted-secrets) | error | Implemented | Scans `run:` and `env:` for `base64`/`xxd`/`tr`/`cut`/`sed`/`awk` pipes and `fromJSON(secrets…)` expressions that bypass redaction. |
| `unsound-condition` | [`zizmor:unsound-condition`](https://docs.zizmor.sh/audits/#unsound-condition) | warning | Implemented | Detects `always()`/`success()`/`failure()`/`cancelled()` antipatterns and `if:` values that mix plaintext with `${{ ... }}` (incl. trailing newline from `|`/`>` block scalars). |
| `unsound-contains` | [`zizmor:unsound-contains`](https://docs.zizmor.sh/audits/#unsound-contains) | warning | Implemented | |
| `use-trusted-publishing` | [`zizmor:use-trusted-publishing`](https://docs.zizmor.sh/audits/#use-trusted-publishing) | info | Implemented | Action-based detection for `pypa/gh-action-pypi-publish` (password to a known PyPI index), `rubygems/release-gem` (`setup-trusted-publisher: false`), `rubygems/configure-rubygems-credentials` (api-token to a known rubygems server), and `actions/setup-node` (npmjs registry + `always-auth: true`). Run-based detection covers `cargo publish`, `twine upload`, `npm/pnpm/bun/yarn publish`, `gem push`, `nuget push` / `dotnet nuget push`, `poetry/hatch/pdm publish`, plus wrappers (`python -m twine`, `pipx run twine`, `uv/uvx`, `bundle exec gem push`, `bunx npm publish`), and is suppressed when the job carries `id-token: write`. |

## ghalint family

`ghl-004`, `ghl-007`, and `ghl-008` have no standalone rule spec in
`rules_catalog.mbt` — they are absorbed into the consolidated zizmor
entries above and surface here only as `_absorbed_` rows for lineage.

| ID | Origin | Severity | Status | Notes |
| --- | --- | --- | --- | --- |
| `job-permissions-required` | [`ghalint:ghl-001 (job_permissions)`](https://github.com/suzuki-shunsuke/ghalint/blob/main/docs/policies/001.md) | warning | Implemented | |
| `permissions-read-all-forbidden` | [`ghalint:ghl-002 (deny_read_all_permission)`](https://github.com/suzuki-shunsuke/ghalint/blob/main/docs/policies/002.md) | error | Implemented | |
| `permissions-write-all-forbidden` | [`ghalint:ghl-003 (deny_write_all_permission)`](https://github.com/suzuki-shunsuke/ghalint/blob/main/docs/policies/003.md) | error | Implemented | |
| _absorbed_ | [`ghalint:ghl-004 (deny_inherit_secrets)`](https://github.com/suzuki-shunsuke/ghalint/blob/main/docs/policies/004.md) | — | Consolidated | Covered by `secrets-inherit`. |
| `workflow-env-no-secrets` | [`ghalint:ghl-005 (workflow_secrets)`](https://github.com/suzuki-shunsuke/ghalint/blob/main/docs/policies/005.md) | error | Implemented | |
| `job-env-no-secrets` | [`ghalint:ghl-006 (job_secrets)`](https://github.com/suzuki-shunsuke/ghalint/blob/main/docs/policies/006.md) | error | Implemented | |
| _absorbed_ | [`ghalint:ghl-007 (deny_job_container_latest_image)`](https://github.com/suzuki-shunsuke/ghalint/blob/main/docs/policies/007.md) | — | Consolidated | Covered by `unpinned-images`. |
| _absorbed_ | [`ghalint:ghl-008 (action_ref_should_be_full_length_commit_sha)`](https://github.com/suzuki-shunsuke/ghalint/blob/main/docs/policies/008.md) | — | Consolidated | Covered by `unpinned-uses`. |
| `github-app-limit-repositories` | [`ghalint:ghl-009 (github_app_should_limit_repositories)`](https://github.com/suzuki-shunsuke/ghalint/blob/main/docs/policies/009.md) | warning | Implemented | |
| `github-app-limit-permissions` | [`ghalint:ghl-010 (github_app_should_limit_permissions)`](https://github.com/suzuki-shunsuke/ghalint/blob/main/docs/policies/010.md) | warning | Implemented | |
| `composite-step-shell-required` | [`ghalint:ghl-011 (action_shell_is_required)`](https://github.com/suzuki-shunsuke/ghalint/blob/main/docs/policies/011.md) | warning | Implemented | Applies to composite `action.yml` only. |
| `job-timeout-minutes-required` | [`ghalint:ghl-012 (job_timeout_minutes_is_required)`](https://github.com/suzuki-shunsuke/ghalint/blob/main/docs/policies/012.md) | warning | Implemented | |
| `checkout-persist-credentials-false` | [`ghalint:ghl-013 (checkout_persist_credentials_should_be_false)`](https://github.com/suzuki-shunsuke/ghalint/blob/main/docs/policies/013.md) | error | Implemented | |
