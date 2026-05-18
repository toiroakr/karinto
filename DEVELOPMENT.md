# Development

## Layout

```
.                             # MoonBit library package — the lint engine
├── karinto.mbt               # public API: types, lint(), helpers
├── rules.mbt                 # rule registry + implemented rules
├── rules_catalog.mbt         # full catalogue (84 rules, metadata + origins)
├── karinto_test.mbt          # blackbox tests for implemented rules + engine
├── actionlint_rules_test.mbt # fixtures for actionlint-derived rules
├── zizmor_rules_test.mbt     # fixtures for zizmor audits
├── ghalint_rules_test.mbt    # fixtures for ghalint policies
├── coverage_test.mbt         # asserts catalogue ↔ tests + origins stay in sync
├── karinto_wbtest.mbt        # whitebox tests (internal helpers)
├── cmd/main                  # demo CLI (`moon run cmd/main`)
├── worker                    # MoonBit → JS export package for the Worker
└── cf                        # Cloudflare Worker (`index.js` + `wrangler.jsonc`)
```

## Build & test

```sh
# Tests (active + #skip fixtures)
moon test

# WASM-gc build (default backend, used by `moon run`)
moon build

# JS build for the Worker (release)
moon build --target js --release
```

## Worker

The Worker imports `lint_string` from the compiled JS at
`_build/js/release/build/worker/worker.js`. The import is deferred to the
first request because MoonBit's compiled JS seeds a hashmap RNG via
`crypto.getRandomValues` at module load — CF Workers forbids that in global
scope, so we lazy-`import()` inside the `fetch` handler.

Run locally:

```sh
cd cf
npm install        # installs wrangler
npm run dev        # `wrangler dev`
```

Deploy:

```sh
cd cf
npm run deploy     # `wrangler deploy`
```

Smoke-check the deployed Worker (3 curl-driven response paths):

```sh
cd cf
npm run smoke      # defaults to https://karinto.toiroakr.workers.dev
npm run smoke -- https://your-worker.example.workers.dev
```

## Logging

The Worker logs a one-line JSON record per request via `console.log`,
captured by `wrangler tail`:

```json
{ "event": "request", "method": "POST", "type": "(auto)",
  "disable": "permissions-*", "repo": "", "targets": "",
  "content_lines": 42, "files": 1, "elapsed_ms": 4 }
```

## Rule catalog

`rules_catalog.mbt` is the source of truth for what karinto checks. Each
entry carries an ID, human-readable title, source family (actionlint /
zizmor / ghalint), upstream origins, category, severity, priority,
implementation status, and which file kinds it applies to.

Of 84 catalogued rules, 62 are implemented; 22 are scaffolded as
`#skip(...)`-attributed test cases in the per-source `*_rules_test.mbt`
files. Each skipped entry ships fixture YAML and expected JSON so the
behavioural spec is in place, ready to be filled in.

Five consolidations merge overlapping upstream checks into one karinto
rule. The `origins` field on every catalog entry preserves the lineage:

| Consolidated rule | Absorbed upstreams |
| --- | --- |
| `unpinned-uses` | `zizmor:unpinned-uses` + `ghalint:ghl-008 (action_ref_should_be_full_length_commit_sha)` |
| `secrets-inherit` | `zizmor:secrets-inherit` + `ghalint:ghl-004 (deny_inherit_secrets)` |
| `unpinned-images` | `zizmor:unpinned-images` + `ghalint:ghl-007 (deny_job_container_latest_image)` |
| `hardcoded-container-credentials` | `zizmor:hardcoded-container-credentials` + `actionlint:hardcoded-credentials` |
| `template-injection` | `zizmor:template-injection` + `actionlint:script-injection` |

`coverage_test.mbt` asserts that the catalog, the rule implementations,
and the test fixtures stay in sync.

## Environments and release flow

Three Workers, one per environment:

| Environment | Worker name | URL | Trigger |
| --- | --- | --- | --- |
| Production | `karinto` | `https://karinto.toiroakr.workers.dev` | `release` workflow (manual dispatch) |
| Staging | `karinto-staging` | `https://karinto-staging.toiroakr.workers.dev` | `push: main` |
| Preview | `karinto-pr-<N>` | `https://karinto-pr-<N>.toiroakr.workers.dev` | `pull_request` (cleaned up on close) |

GitHub Actions wiring:

- `.github/workflows/test.yml` — runs `moon test` on every PR and on `main`,
  and enforces that pull requests include a `.changeset/*.md` entry.
- `.github/workflows/deploy-preview.yml` — builds and deploys the per-PR
  Worker, then posts a sticky comment with the preview URL.
- `.github/workflows/cleanup-preview.yml` — deletes the preview Worker when
  the PR closes.
- `.github/workflows/deploy-staging.yml` — deploys to staging on every push
  to `main`.
- `.github/workflows/release.yml` — `workflow_dispatch` job that consumes
  the accumulated changesets, bumps versions, writes the CHANGELOG section,
  tags `vX.Y.Z`, deploys to production, and publishes a GitHub Release.

### Per-PR changesets

Every PR with a user-visible change must include a changeset:

```sh
npx changeset       # prompts for bump type + summary, writes .changeset/<id>.md
```

CI fails without one. If a PR genuinely has no user-visible impact (CI
tweaks, internal scripts), apply the `skip-changeset` label on GitHub.

### Cutting a release

1. Open the **Actions** tab on GitHub and run the `release` workflow.
2. The workflow:
   - reads the queued `.changeset/*.md` entries
   - bumps `package.json` and `moon.mod.json` (via `scripts/sync-moon-version.mjs`)
   - rewrites `CHANGELOG.md` with the new section
   - commits, tags `vX.Y.Z`, pushes
   - builds, deploys to the production Worker, runs `cf/smoke.sh`
   - creates a GitHub Release whose body is the new CHANGELOG section

### Required GitHub secrets

| Secret | Where to get it |
| --- | --- |
| `CLOUDFLARE_API_TOKEN` | CF dashboard → My Profile → API Tokens → "Edit Cloudflare Workers" template |
| `CLOUDFLARE_ACCOUNT_ID` | Workers dashboard sidebar |
