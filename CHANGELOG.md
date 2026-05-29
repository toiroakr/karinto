# karinto

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
