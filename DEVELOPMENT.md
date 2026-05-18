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

Of 82 catalogued rules, 61 are implemented; 17 are scaffolded as
`#skip(...)`-attributed test cases in the per-source `*_rules_test.mbt`
files (each ships fixture YAML and expected JSON so the behavioural spec
is in place, ready to be filled in); 4 are marked `NotPlanned` —
deliberately out of scope and carry no fixture. The full per-rule
rationale lives in [`rules_catalog.md`](rules_catalog.md).

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
| Production | `karinto` | `https://karinto.toiroakr.workers.dev` | merging the auto-generated "chore: release" PR |
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
- `.github/workflows/release.yml` — runs on every push to `main` via
  `changesets/action`. When pending changesets are present it opens (or
  updates) a "chore: release" PR that consumes them, bumps versions, and
  rewrites `CHANGELOG.md`. When that PR is merged (i.e. main has no pending
  changesets), the same workflow runs `scripts/release-publish.sh`:
  builds, deploys to the production Worker, runs `cf/smoke.sh`, tags
  `vX.Y.Z`, and creates a GitHub Release whose body is the new CHANGELOG
  section.

### Per-PR changesets

Every PR with a user-visible change must include a changeset:

```sh
npx changeset       # prompts for bump type + summary, writes .changeset/<id>.md
```

CI fails without one. If a PR genuinely has no user-visible impact (CI
tweaks, internal scripts), apply the `skip-changeset` label on GitHub.

### Cutting a release

Releases are driven by `changesets/action`. As PRs land on `main`, the
action keeps a "chore: release" PR open that previews the next version.

1. Review the open **chore: release** PR (created/updated by
   `changesets/action`). Its diff is purely the version bump,
   `CHANGELOG.md` update, and removal of the consumed `.changeset/*.md`
   files.
2. Merge it. On the resulting push to `main`, the `release` workflow runs
   `scripts/release-publish.sh`:
   - `moon update && moon test && moon build --target js --release`
   - `cd cf && npm ci && npx wrangler deploy`
   - `bash cf/smoke.sh` against `https://karinto.toiroakr.workers.dev`
   - `npx changeset tag` — creates `v<version>` and pushes it
   - `changesets/action` then publishes a GitHub Release for that tag
     using the new CHANGELOG section as the body.

### Required GitHub secrets

| Secret | Where to get it |
| --- | --- |
| `CLOUDFLARE_API_TOKEN` | CF dashboard → My Profile → API Tokens → "Edit Cloudflare Workers" template |
| `CLOUDFLARE_ACCOUNT_ID` | Workers dashboard sidebar |

### Required repository settings

| Setting | Where | Why |
| --- | --- | --- |
| Workflow permissions: **Read and write**, **Allow GitHub Actions to create and approve pull requests** | Settings → Actions → General | So `changesets/action` can push to `changeset-release/main` and open the "chore: release" PR. |

## Dependency updates

[Renovate](https://docs.renovatebot.com/) handles dependency PRs (config in
`renovate.json`). The bot runs **daily** (before 8am JST):

- GitHub Actions are grouped into a single PR.
- npm minor + patch updates are grouped; majors get a separate PR.
- `lockFileMaintenance` refreshes `package-lock.json` on the 1st of each month.
- All Renovate PRs are auto-labelled `dependencies` + `skip-changeset` (so
  they bypass the changeset CI gate — dependency bumps don't ship as a
  user-visible release).
- `minimumReleaseAge: 7 days` — Renovate waits a week after a version is
  published before opening a PR, to dodge insta-broken releases. Security
  advisories (`vulnerabilityAlerts`) bypass this delay.
- **Auto-merge** is enabled on every Renovate PR (squash). Once all checks
  pass (`moon-test`, `deploy`, `changeset-check` skipped), GitHub
  auto-merges the PR. The branch is auto-deleted after merge.

Enable Renovate by installing the [GitHub App](https://github.com/apps/renovate)
on the repo. The bot's first run will open a "Configure Renovate" PR — merge
it to activate the schedule.

> Repo settings already configured: `allow_auto_merge: true`,
> `delete_branch_on_merge: true`, and Actions are allowed to create + approve
> PRs (needed for `changesets/action`).
