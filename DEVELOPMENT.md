# Development

## Layout

```
.                             # MoonBit library package — the lint engine
├── karinto.mbt               # public API: types, lint(), helpers
├── rules.mbt                 # rule registry + implemented rules
├── rules_catalog.mbt         # full catalogue (83 rules, metadata + origins)
├── karinto_test.mbt          # blackbox tests for implemented rules + engine
├── actionlint_rules_test.mbt # fixtures for actionlint-derived rules
├── zizmor_rules_test.mbt     # fixtures for zizmor audits
├── ghalint_rules_test.mbt    # fixtures for ghalint policies
├── coverage_test.mbt         # asserts catalogue ↔ tests + origins stay in sync
├── karinto_wbtest.mbt        # whitebox tests (internal helpers)
├── cmd/main                  # local CLI (js-only; see README "Local CLI")
├── worker                    # MoonBit → JS export package for the Worker
└── cf                        # Cloudflare Worker (`index.js` + `wrangler.jsonc`)
```

## Build & test

```sh
# Tests (active + #skip fixtures)
moon test

# js-only packages (worker, cmd/main) are skipped by the default target —
# CI runs both
moon test --target js

# WASM-gc build (default backend, used by `moon run`)
moon build

# JS build for the Worker (release)
moon build --target js --release

# Local CLI (js-only package; usage in README "Local CLI")
cat .github/workflows/test.yml | moon run --target js cmd/main
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
npm run dev        # render-config + `wrangler dev --config wrangler.deploy.jsonc`
```

Deploy:

```sh
cd cf
npm run deploy     # render-config + `wrangler deploy --config wrangler.deploy.jsonc`
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
zizmor / ghalint), upstream origins, category, severity,
implementation status, and which file kinds it applies to.

Of 83 catalogued rules, 68 are implemented; 8 are `Planned` — scaffolded as
`#skip(...)`-attributed test cases in the per-source `*_rules_test.mbt`
files (each ships fixture YAML and expected JSON so the behavioural spec
is in place, ready to be filled in); 7 are marked `NotPlanned` —
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

Three application Workers, one per environment, plus a maintenance Worker:

| Environment | Worker name | URL | Trigger |
| --- | --- | --- | --- |
| Production | `karinto` | `https://karinto.toiroakr.workers.dev` | merging the auto-generated "chore: release" PR |
| Staging | `karinto-staging` | `https://karinto-staging.toiroakr.workers.dev` | `push: main` |
| Preview | `karinto-pr-<N>` | `https://karinto-pr-<N>.toiroakr.workers.dev` | `pull_request` (cleaned up on close) |
| Captures (dark-launch) | `karinto-captures` | _(no public URL — `workers_dev: false`)_ | deployed with each release; cron-only Worker, runs every 6 hours. **Primary retention:** the R2 dashboard lifecycle rule (30 days). **Secondary safety net:** when the first 200k listed objects already total ≥ 7000 MiB (≈ 6.84 GiB), the Worker prunes oldest-first back to ≈ 4.79 GiB. Buckets with many small objects whose listed subset stays under that limit are left to the lifecycle rule. |

The production and staging Workers carry a single daily cron (`0 2 * * *`) that
refreshes the `api.github.com/meta` payload (key `meta`), consulted on the
request path to exempt GitHub-hosted Actions runner IPs from the per-IP rate
limit.

The archived `owner/repo` baseline for `archived-uses` is **not** verified by
the Worker — doing GitHub API lookups from the Worker would fight the Workers
**Free** plan's ~50-subrequest-per-invocation limit and the unauthenticated
60-req/hour quota (shared across Cloudflare's egress IPs). Instead it is kept in
two synced places and the work is split:

- The baseline lives in committed **`cf/archived.json`** (source of truth,
  reviewable in git, **bundled into the Worker** as a seed) and mirrored to KV
  **`archived:list`** (read live on the request path for immediacy).
- **Worker (request path)** discovers candidates and reads the baseline: it
  enqueues each external `uses:` repo it serves into the D1 `pending` worklist
  (`INSERT OR IGNORE`, off the hot path via `ctx.waitUntil`), and feeds the rule
  the union of the bundled `cf/archived.json` seed, the live KV value (memoized
  per-isolate, fail-open), the engine's hardcoded baseline, and the caller's
  `archived` parameter.
- **CI (`.github/workflows/refresh-archived.yml`, daily)** does the verifying:
  `scripts/refresh-archived.mjs` reads the current baseline from
  `cf/archived.json` + drains `pending`, confirms each repo's `archived` flag
  against the GitHub API (re-checking the existing baseline too, so un-archives
  are caught), and when it changed writes the result to **both** KV (immediately,
  so prod reflects it now) and `cf/archived.json` (the workflow opens a PR with
  it via `create-pull-request`; merging updates the bundled seed on the next
  deploy). It then `DELETE`s the repos it resolved from `pending`; anything it
  couldn't reach (rate-limit tail, transient error) stays queued and is
  re-enqueued by traffic.

  GitHub Actions has a full 5000-req/hour budget (with a token) and no
  subrequest ceiling, so a single daily run comfortably re-verifies the whole
  set. The job runs with the workflow's `github.token` (1000 req/hour, enough to
  read public repos' `archived` flag); set the optional `ARCHIVED_REFRESH_TOKEN`
  repo secret to a public-read PAT to get the full 5000/hour. The job is skipped
  on deployments without D1 (`if: vars.D1_DATABASE_ID != ''`).

  > Because the baseline lives in KV out-of-band, `archived-uses` findings are
  > excluded from the dark-launch replay diff (see
  > `scripts/diff-rules/2026-05-archived-uses-baseline.mjs`): the KV set can
  > differ between capture and replay independently of any code change. That
  > makes it a **permanent** ignore rule (`prunable = false`) — unlike the
  > per-change rules, no release ever makes it unnecessary, so
  > `prune-diff-rules.yml` must never delete it.

The D1 database backing `pending` (binding `DB`, `karinto-archived`) must be
provisioned once. Its `database_id` is **not** committed: `cf/wrangler.jsonc`
keeps the placeholder `REPLACE_WITH_D1_DATABASE_ID`, and the real id lives in
the `D1_DATABASE_ID` repo variable (same self-host stance as
`CLOUDFLARE_ACCOUNT_ID` and the R2 bucket name). At deploy time
`scripts/prepare-wrangler-d1.mjs` renders a throwaway `cf/wrangler.deploy.jsonc`
with the id substituted in; deploys pass `--config wrangler.deploy.jsonc`. If
`D1_DATABASE_ID` is unset (e.g. a fork that hasn't provisioned D1) the script
drops the binding and the Worker no-ops its archived sweep (`cf/index.js`
guards every `env.DB` use).

```sh
cd cf
wrangler d1 create karinto-archived          # note the printed database id
gh variable set D1_DATABASE_ID --body "<database id>"   # NOT into wrangler.jsonc
# Apply the migration. wrangler reads the id from config, so render it first:
D1_DATABASE_ID="<database id>" node ../scripts/prepare-wrangler-d1.mjs
wrangler d1 migrations apply karinto-archived --config wrangler.deploy.jsonc --remote
```

A fork wires up its own D1 the same way: create the database on its own
Cloudflare account and set that account's id in its `D1_DATABASE_ID` repo
variable. Nothing in the tracked config changes.

Preview Workers inherit neither the cron nor the R2 binding (the top-level
`cf/wrangler.jsonc` omits both on purpose), so they read from the shared KV
but never refresh it and can't write into the captures bucket.

GitHub Actions wiring:

- `.github/workflows/test.yml` — runs `moon test` on every PR and on `main`,
  and enforces that pull requests include a `.changeset/*.md` entry.
- `.github/workflows/deploy-preview.yml` — builds and deploys the per-PR
  Worker, then posts a sticky comment with the preview URL.
- `.github/workflows/cleanup-preview.yml` — deletes the preview Worker when
  the PR closes.
- `.github/workflows/deploy-staging.yml` — deploys to staging on every push
  to `main`.
- `.github/workflows/refresh-archived.yml` — daily cron that runs
  `scripts/refresh-archived.mjs` to maintain the `archived-uses` baseline
  (drains the D1 worklist, verifies repos against the GitHub API, writes the
  live KV key and opens a PR updating committed `cf/archived.json`). Skipped
  when `vars.D1_DATABASE_ID` is unset.
- `.github/workflows/release.yml` — runs on every push to `main` via
  `changesets/action`. When pending changesets are present it opens (or
  updates) a "chore: release" PR that consumes them, bumps versions, and
  rewrites `CHANGELOG.md`. When that PR is merged (i.e. main has no pending
  changesets), the same workflow runs `scripts/release-publish.sh`:
  builds, deploys to the production Worker, runs `cf/smoke.sh`, deploys an
  immutable version-pinned snapshot Worker (`karinto-vX-Y-Z`, smoke-checked
  too), tags `vX.Y.Z`, and creates a GitHub Release whose body is the new
  CHANGELOG section.
- `.github/workflows/upstream-parity.yml` — runs karinto against the
  vendored upstream fixtures and the matching upstream linter binary, and
  compares the diagnostics they emit (per-rule for zizmor / ghalint, source-
  level aggregate for actionlint). Fails PRs on divergence; on `main` runs
  in soft mode (informational only). Also triggers when someone adds the
  `run-parity` label (gated on the label name; label application already
  requires write access), the manual hook for token-created refresh PRs that
  don't auto-run `pull_request` workflows.
- `.github/workflows/upstream-refresh.yml` — weekly cron (Monday 00:00 UTC)
  that checks GitHub for newer actionlint / zizmor / ghalint releases. When
  found, bumps `mise.toml` and re-vendors `fixtures/upstream/<tool>/` from
  the matching tag, then opens a PR labelled `dependencies` + `skip-changeset`.

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
   - `cd cf && npm ci`, then `node ../scripts/prepare-wrangler-d1.mjs` to inject
     the `D1_DATABASE_ID` and `npx wrangler deploy --config wrangler.deploy.jsonc
     --env production`
   - `bash cf/smoke.sh` against `https://karinto.toiroakr.workers.dev`
   - `npx wrangler deploy --config wrangler.deploy.jsonc --env="" --name karinto-vX-Y-Z` — an immutable
     snapshot Worker for the released version (`.` → `-` in the name),
     smoke-checked at `https://karinto-vX-Y-Z.toiroakr.workers.dev`. Uses the
     top-level config (like PR previews) so it has no CAPTURES binding and no
     cron; it reads the shared KV but never writes. CI users pin to this URL
     to avoid the always-latest endpoint shifting under them — see
     [*Versioning & pinning*](docs/pinning.md).
   - `node ../scripts/manage-pinned-workers.mjs` — refreshes the
     `karinto-vMAJOR` alias if this release is the new top within its major
     (smoke-checked at `karinto-vMAJOR.toiroakr.workers.dev`) and deletes
     exact-version Workers outside the retention set *(latest patch per
     major)* ∪ *(top `PINNED_KEEP_RECENT` by SemVer)* ∪ *(just-released)*.
     Aliases are never auto-deleted. Alias failures fail the release; prune
     failures only warn — stale snapshots are an inventory concern, retried
     next release.
   - `npx changeset tag` — creates `v<version>` and pushes it
   - `changesets/action` then publishes a GitHub Release for that tag
     using the new CHANGELOG section as the body.

### Required GitHub secrets

| Secret | Where to get it |
| --- | --- |
| `CLOUDFLARE_API_TOKEN` | CF dashboard → My Profile → API Tokens → "Edit Cloudflare Workers" template, **plus the `Account → D1 → Edit` permission added on top** — the template alone has no D1 scope, so `refresh-archived.yml`'s `wrangler d1 execute --remote` fails with Cloudflare error 7403 ("not authorized to access this service"). |
| `CLOUDFLARE_ACCOUNT_ID` | Workers dashboard sidebar |
| `R2_ACCESS_KEY_ID` (optional) | Created in CF Dashboard → R2 → Manage R2 API Tokens. Scoped to **read-only** on the `karinto-captures` bucket. Enables the PR dark-launch replay step. |
| `R2_SECRET_ACCESS_KEY` (optional) | The matching secret from the same R2 API token. |
| `ARCHIVED_REFRESH_TOKEN` (optional) | A GitHub PAT with public read access (classic `public_repo`, or a fine-grained token with no extra scopes). Lets `refresh-archived.yml` use the 5000-req/hour quota instead of the job token's 1000/hour. Only needed if the worklist outgrows 1000 checks/day. |
| `GITHUB_PUBLIC_READ_TOKEN` (optional) | A GitHub PAT (public read; add Contents:read for private repos). Whole-repo mode (`/owner/repo` with no targets) lists `.github/workflows` through the GitHub contents API. When this repo secret is set, the release, staging, and preview deploys mirror it into each Worker as an encrypted secret (`wrangler secret put GITHUB_PUBLIC_READ_TOKEN` — see `scripts/release-publish.sh`, `scripts/manage-pinned-workers.mjs`, and the deploy workflows), raising the request-path ceiling from the unauthenticated 60 req/hour/IP to 5000/hour. Unset → deploys are a no-op for it and the path stays anonymous (`429` on over-limit listing). |

### Optional GitHub variables

Repo-level **variables** (not secrets — non-sensitive values), set under
Settings → Secrets and variables → Actions → Variables. The dark-launch knobs
are integers that fall back to the defaults hardcoded in the Worker / workflow
when unset; `D1_DATABASE_ID` is the one deployment identifier (unset → the D1
binding is dropped, see below).

| Variable | Default | Effect |
| --- | --- | --- |
| `REPO_MODE_ENABLED` | `false` (off) | Truthy (`1`/`true`/`yes`/`on`) enables repo mode — the GitHub-fetching `/owner/repo[/...]` endpoints (`repo`/`commit`/`ref` params, the `blob`/`tree` path forms, and whole-repo discovery). Off by default because it makes the Worker fetch arbitrary public content and draw on GitHub's API rate limit; `content` linting is always available. Overlaid onto every request-serving Worker via `--var` at deploy time (`scripts/release-publish.sh`, `scripts/manage-pinned-workers.mjs`, and the deploy workflows). |
| `D1_DATABASE_ID` | _(none)_ | D1 database id for the archived-uses worklist, injected into the deploy config by `scripts/prepare-wrangler-d1.mjs`. Unset → the `DB` binding is dropped from every deploy and the archived sweep stays dormant (`cf/index.js` no-ops when `env.DB` is absent). |
| `REPLAY_LIMIT` | 200 | Captures replayed per CI run (both auto-on-open and label-triggered). |
| `CAPTURE_CONTENT_LIMIT_KIB` | 100 | Skip capturing requests whose `content` exceeds this size. Applied by `cf/index.js` at write time. |
| `CAPTURES_SIZE_LIMIT_MIB` | 7000 (≈ 6.84 GiB) | Bucket size that triggers prune in the `karinto-captures` cron Worker. |
| `CAPTURES_RECOVERY_RATIO` | 0.7 | When pruning fires, shrink to this fraction of the size limit (default → ≈ 4.79 GiB target). |
| `PINNED_KEEP_RECENT` | 50 | Top-N retention for exact-version pinned Workers (`karinto-vX-Y-Z`). The "latest patch per major" set is kept on top of this regardless. The free-plan Workers cap is 100, so 50 leaves comfortable headroom for prod/staging/maintenance + per-PR preview + major-alias Workers. |

`CAPTURE_CONTENT_LIMIT_KIB` / `CAPTURES_SIZE_LIMIT_MIB` /
`CAPTURES_RECOVERY_RATIO` take effect on the next release deploy via
`wrangler deploy --var` in `scripts/release-publish.sh`. `PINNED_KEEP_RECENT`
is consumed by `scripts/manage-pinned-workers.mjs` at release time as a
prune knob (not a Worker runtime var, so it isn't surfaced through
`--var`). `REPLAY_LIMIT` is read by the workflows directly, so it applies
immediately.

### Required repository settings

| Setting | Where | Why |
| --- | --- | --- |
| Workflow permissions: **Read and write**, **Allow GitHub Actions to create and approve pull requests** | Settings → Actions → General | So `changesets/action` can push to `changeset-release/main` and open the "chore: release" PR. |

### Required repository labels

The workflows match on these label names verbatim, so they must exist
before the corresponding flow fires. Create them once via `gh label
create` (or the GitHub UI):

| Label | Used by | Purpose |
| --- | --- | --- |
| `skip-changeset` | `.github/workflows/test.yml` | Bypasses the changeset CI gate for PRs with no user-visible impact (CI tweaks, internal scripts, doc-only changes). |
| `regression-test` | `.github/workflows/replay-on-label.yml` | Triggers a dark-launch replay against this PR's preview Worker on demand. Auto-removed by the workflow when it finishes. |

Renovate's own labels (`dependencies`, `security`) are created
automatically on first use, so no pre-provisioning is needed for them.

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

## Dark-launch (capture & replay)

Production captures the requests it serves into an R2 bucket. On demand
(by labelling a PR `regression-test`), recent captures are replayed
against that PR's preview Worker and diffed against the recorded prod
responses. Unexpected diffs fail the run and the result is posted as a
sticky PR comment.

### How it works

```
        prod request                          PR opened / `regression-test` label added
            │                                                 │
            ▼                                                 │
     ┌───────────┐    ctx.waitUntil    ┌────────────────┐     │
     │  karinto  │ ───────────────────▶│ R2: captures/  │     │
     │  (prod)   │  PUT If-None-Match  │  <hash>.json   │     │
     └───────────┘                     └───────┬────────┘     │
                                               │              │
                                               │ R2 S3 API    │
                                               │ (sigv4)      │
                                               ▼              ▼
                                      scripts/replay.mjs ─▶ POST same request
                                          (CI runner)        (karinto-pr-<N>)
                                               │
                                               ▼
                                      diff + apply
                                      scripts/diff-rules/*.mjs
                                               │
                                               ▼
                                      sticky PR comment +
                                      fail check on unmatched diff

The `karinto-captures` Worker is cron-only (`workers_dev: false`); it has
no public HTTP surface. CI reads the bucket directly via R2's S3-compatible
endpoint, authenticated with bucket-scoped read-only access keys.
```

- **Capture key** = `sha256(canonical(normalized_request))`. `If-None-Match: *`
  prevents repeat writes for the same request — true content dedup.
- **Skipped at capture time**: `osv=1` (external state), `repo` mode (external
  state), content larger than 100 KiB, and opt-out (caller passes
  `no_capture=1` or sends `X-Karinto-No-Capture: 1`).
- **Retention**: configure an R2 lifecycle rule on the `karinto-captures`
  bucket to delete objects older than 30 days. The `karinto-captures`
  Worker's `scheduled` handler runs every 6 hours as a secondary guard that
  prunes oldest-first when the bucket grows past ≈ 6.84 GiB (7000 MiB),
  cutting it back down to ≈ 4.79 GiB.

### Bootstrapping a fresh deployment

> One-time, owner-only. Run these steps once when first setting this up on
> a Cloudflare account (or when forking the repo into a different account).
> Regular contributors don't need any of this — secrets and the bucket
> already exist on the upstream deployment.

```sh
# 1. Build the MoonBit → JS bundle that the Worker imports. The release
#    workflow does this automatically, but a manual first-time deploy
#    needs it explicitly:
moon update
moon build --target js --release

cd cf
# 2. Create the bucket
npx wrangler r2 bucket create karinto-captures

# 3. In the Cloudflare dashboard: R2 → karinto-captures → Lifecycle rules
#    Add: "Delete objects older than 30 days", prefix `captures/`.

# 4. Create an R2 API token (Dashboard → R2 → Manage R2 API Tokens →
#    "Create API Token"). Scope it to **Object Read only** on the
#    `karinto-captures` bucket. Save the Access Key ID + Secret Access Key
#    as GitHub repo secrets:
gh secret set R2_ACCESS_KEY_ID     -b "<access key id>"
gh secret set R2_SECRET_ACCESS_KEY -b "<secret access key>"

# 5. Provision the D1 worklist and stash its id in the D1_DATABASE_ID repo
#    variable (NOT in wrangler.jsonc — see "Environments and release flow"):
npx wrangler d1 create karinto-archived          # note the printed database id
gh variable set D1_DATABASE_ID --body "<database id>"
D1_DATABASE_ID="<database id>" node ../scripts/prepare-wrangler-d1.mjs
npx wrangler d1 migrations apply karinto-archived --config wrangler.deploy.jsonc --remote

# 6. Deploy the prod linter (with binding) + captures Worker. Normally this
#    happens via the release workflow, but the first time you can run:
npm ci
export D1_DATABASE_ID="<database id>"            # injected into the deploy config
node ../scripts/prepare-wrangler-d1.mjs
npx wrangler deploy --config wrangler.deploy.jsonc --env production
npx wrangler deploy --config wrangler.maintenance.jsonc
```

`CLOUDFLARE_ACCOUNT_ID` is reused as `R2_ACCOUNT_ID` by the replay step
(both workflows pass it in via `env`).

### Adding an intentional-diff ignore rule

When a PR deliberately changes linter output (new rule, message rewording,
severity change, etc.), add a `scripts/diff-rules/*.mjs` file in the same PR.
See `scripts/diff-rules/README.md` for the rule contract and conventions.

Every rule must export `prunable` (see the README's "Prunability" section):
`true` for the usual transient rule that only masks stale captures, `false` for
a rule masking drift no release can fix (`archived-uses-baseline`). The field is
what stops the automatic pruner from deleting a permanent rule.

### Lifecycle of an ignore rule

```
PR adds the rule       ──▶  merged, unreleased  ──▶  release ships the fix to prod
(reviewed alongside          (rule masks the         (captures now carry the OLD
 the behaviour change)        preview-vs-capture      response — the rule now masks
                              diff)                   a prod-vs-capture diff)
                                                                │
                                          prune-diff-rules.yml  │  (dispatched by
                                          replays captures ◀────┘   release.yml)
                                          against prod
                                                │
                    all four gates pass? (see the workflow header)
                      unexpected == 0, matchCount > 0,
                      threwCount == 0, prunable == true
                        │                          │
                       yes                         no ──▶ nothing removed; warns,
                        │                                 or fails on unexplained drift
                        ▼
              `replay.mjs --check-rules` proves the rest still import
                        │
              opens `chore/prune-diff-rules` PR deleting the rule
                        │
                     a human merges it  ──▶  rebaseline-captures.yml fires on the
                     ("bake this in")        `main` push, rewrites the captures
                                             from current prod, diffs gone
```

The pruner **refuses to act** while the detection replay reports unexplained
diffs. `rebaseline-captures.mjs` does not consult the diff-rules — it overwrites
every capture whose prod response differs — so merging a pruning PR during
unexplained drift would bake a prod regression into the baseline. Resolve the
drift (add a rule, or fix the regression) before pruning; `dry_run: true` lets
you inspect meanwhile.

The `replay` check on the pruning PR itself is expected to be red — the rule is
gone but the captures are still stale. It clears for later PRs as soon as the
post-merge rebaseline finishes. A rule can also just be deleted by hand; the
same push trigger picks it up.

### Triggering a replay on a PR

- **Automatic** on the first deploy of a PR: when the PR is opened or
  reopened, `deploy-preview.yml` runs replay against the freshly-deployed
  preview Worker once the build finishes.
- **On-demand** on subsequent commits: add the **`regression-test`** label.
  `replay-on-label.yml` waits for the preview to be reachable, replays,
  posts the sticky comment, and removes the label. Re-add the label to run
  again.

Both paths use the same `scripts/replay.mjs` and post under the
`dark-launch-replay` sticky-comment header, so the comment updates in
place rather than stacking.

### Running replay locally

```sh
export R2_ACCESS_KEY_ID=<access key>
export R2_SECRET_ACCESS_KEY=<secret>
export R2_ACCOUNT_ID=<cloudflare account id>
node scripts/replay.mjs --target https://karinto-staging.toiroakr.workers.dev --limit 30
```

The script fetches captures directly from R2 via its S3-compatible API
(sigv4-signed) and runs the diff entirely in this process — no Worker-side
replay endpoint is involved. `REPLAY_SUMMARY_PATH=/tmp/out.md` will
additionally write a markdown summary to that path (used by the PR
sticky-comment step).

## Upstream parity check

`upstream-parity.yml` runs karinto and the three upstream linters
(actionlint / zizmor / ghalint) over a shared, vendored set of test
fixtures and compares the rule IDs each side emits. The point is to
detect when karinto drifts from the upstream behaviour it claims to
implement.

```
fixtures/upstream/
├── actionlint/    # vendored from rhysd/actionlint @ matching release tag
├── zizmor/        # vendored from zizmorcore/zizmor @ matching release tag
└── ghalint/       # vendored from suzuki-shunsuke/ghalint @ matching release tag
```

Pins (binary version + fixture tag) live in `mise.toml`. The CI installs
the binaries via [mise](https://mise.jdx.dev/) (`aqua:` backend for
actionlint + ghalint, `ubi:` backend for zizmor since it isn't in the aqua
standard registry). Locally:

```sh
mise install
moon build --target js --release
node scripts/upstream-parity/compare.mjs \
  --actionlint "$(mise which actionlint)" \
  --zizmor     "$(mise which zizmor)" \
  --ghalint    "$(mise which ghalint)"
```

Always resolve the binaries through `mise which` (as above) — don't invoke a
bare `zizmor` from `PATH`. If `zizmor` is also installed via an aqua proxy
shim, that shim can hang on analysis runs in sandboxed / non-interactive
shells (version/help still work, so it looks installed). `mise which zizmor`
points at the real `ubi:`-installed binary. Also note the analysis flag is
`--no-online-audits` (what `run-zizmor.mjs` passes), not `--offline`.

### How diffs are classified

For each fixture file, the script runs both karinto and the matching
upstream linter and compares.

- **zizmor / ghalint** — per-rule. Their rule IDs map 1:1 to entries in
  `rules_catalog.mbt` `origins`. The comparison expects:
  - upstream fires `T:foo` → karinto fires the rule with `T:foo` origin
    (if its status is `Implemented`);
  - karinto fires a rule with `T:foo` origin → upstream fires `T:foo`.
- **actionlint** — source-level aggregate. actionlint's JSON `Kind` field
  is a coarse category (e.g. `syntax-check`) that doesn't disambiguate
  individual karinto rules, so the comparison is: "did either side fire on
  this file at all?". Per-rule precision is left as future work — message-
  regex tables would need to be added per actionlint Kind.

Status-driven exemptions:

- `Implemented` rules participate in the diff. A miss is a hard failure.
- `Planned` / `NotPlanned` rules don't participate; upstream firings that
  map to them are reported in the soft-divergence section as informational.
- Upstream firings that don't map to any karinto rule (e.g.
  `actionlint:shellcheck-on-run` — explicitly `NotPlanned`) are reported as
  `unmapped` and don't fail the check.

### When parity legitimately diverges

When upstream and karinto are intentionally different on a specific
fixture (e.g. the fixture exercises a rule we deliberately don't ship),
add an entry to `scripts/upstream-parity/allowlist.json`. Schema lives in
the file's leading `_comment` block. Be specific — match by rule ID, not
by file alone, so the allowlist degrades gracefully as fixtures change.

### Weekly refresh

`upstream-refresh.yml` runs every Monday at 00:00 UTC (and on
`workflow_dispatch`). It:

1. Reads the current pins from `mise.toml`.
2. Queries `gh api repos/<owner>/<repo>/releases/latest` for each tool.
3. For tools with a newer release: bumps `mise.toml`, shallow-clones the
   new tag, and replaces `fixtures/upstream/<tool>/` with the vendored
   testdata subdirs (see `TOOLS[].vendor` in `refresh.mjs`).
4. Opens a PR via `peter-evans/create-pull-request` labelled
   `dependencies` + `skip-changeset`. Auto-merge is intentionally not
   enabled — a refresh is exactly when `upstream-parity.yml` is most
   likely to surface real regressions, so a human should look.

The PR body carries, per bump: a `compare/v<from>...<to>` link, a
release-notes excerpt, and an incorporation checklist (added by
`refresh.mjs` → the workflow's PR-body step).

Because the PR is opened with `GITHUB_TOKEN`, GitHub does not start the
`pull_request`-triggered `upstream-parity.yml` for it. Add the `run-parity`
label to run the behavioural diff; the label is removed after the run so
re-adding it re-triggers. The label must already exist in the repo for it to
be applied — create it once with
`gh label create run-parity --description 'Run upstream-parity on this PR'`.
Gating is by label name only (applying labels already requires write access).

### Incorporating a new upstream check

The refresh PR + parity step summary tell you *that* an upstream check
changed; turning it into a karinto rule is manual:

1. Run parity locally (see [above](#upstream-parity-check)) and read the
   `unmapped` IDs / Kinds and soft divergences — these name the upstream
   checks karinto doesn't yet cover. Cross-check against the `compare`
   link + release-notes excerpt in the refresh PR for intended semantics.
2. Decide a status: `Implemented` (ship parity now), `Planned` (in scope,
   not yet built), or `NotPlanned` (deliberately out of scope). If it's the
   same ground as an existing rule, consolidate by adding the origin to that
   rule's `origins` array rather than minting a new ID.
3. Register it in `rules_catalog.mbt` and mirror the entry into
   `rules_catalog.md` **in the same commit** (see AGENTS.md "Rule catalog
   discipline").
4. If `Implemented`, wire the rule into `all_rules()` in `rules.mbt` and add
   a fixture/expected-JSON test in the matching `<tool>_rules_test.mbt`.
5. If we're intentionally *not* matching it, record the divergence in
   `scripts/upstream-parity/allowlist.json` (keyed by rule ID + file).
6. Verify with `moon test` and a green local parity run.
