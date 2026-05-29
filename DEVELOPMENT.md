# Development

## Layout

```
.                             # MoonBit library package — the lint engine
├── karinto.mbt               # public API: types, lint(), helpers
├── rules.mbt                 # rule registry + implemented rules
├── rules_catalog.mbt         # full catalogue (82 rules, metadata + origins)
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

Three application Workers, one per environment, plus a maintenance Worker:

| Environment | Worker name | URL | Trigger |
| --- | --- | --- | --- |
| Production | `karinto` | `https://karinto.toiroakr.workers.dev` | merging the auto-generated "chore: release" PR |
| Staging | `karinto-staging` | `https://karinto-staging.toiroakr.workers.dev` | `push: main` |
| Preview | `karinto-pr-<N>` | `https://karinto-pr-<N>.toiroakr.workers.dev` | `pull_request` (cleaned up on close) |
| Captures (dark-launch) | `karinto-captures` | _(no public URL — `workers_dev: false`)_ | deployed with each release; cron-only Worker, runs every 6 hours. **Primary retention:** the R2 dashboard lifecycle rule (30 days). **Secondary safety net:** when the first 200k listed objects already total ≥ 7000 MiB (≈ 6.84 GiB), the Worker prunes oldest-first back to ≈ 4.79 GiB. Buckets with many small objects whose listed subset stays under that limit are left to the lifecycle rule. |

Both the production and staging Workers also carry a daily cron
(`0 2 * * *`) that refreshes the cached `api.github.com/meta` payload in
KV. The request path consults that cache to exempt GitHub-hosted Actions
runner IPs from the per-IP rate limit. Preview Workers inherit neither
the cron nor the R2 binding (the top-level `cf/wrangler.jsonc` omits both
on purpose), so they read from the shared KV but never refresh it and
can't write into the captures bucket.

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
  builds, deploys to the production Worker, runs `cf/smoke.sh`, deploys an
  immutable version-pinned snapshot Worker (`karinto-vX-Y-Z`, smoke-checked
  too), tags `vX.Y.Z`, and creates a GitHub Release whose body is the new
  CHANGELOG section.
- `.github/workflows/upstream-parity.yml` — runs karinto against the
  vendored upstream fixtures and the matching upstream linter binary, and
  compares the diagnostics they emit (per-rule for zizmor / ghalint, source-
  level aggregate for actionlint). Fails PRs on divergence; on `main` runs
  in soft mode (informational only).
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
   - `cd cf && npm ci && npx wrangler deploy`
   - `bash cf/smoke.sh` against `https://karinto.toiroakr.workers.dev`
   - `npx wrangler deploy --env="" --name karinto-vX-Y-Z` — an immutable
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
| `CLOUDFLARE_API_TOKEN` | CF dashboard → My Profile → API Tokens → "Edit Cloudflare Workers" template |
| `CLOUDFLARE_ACCOUNT_ID` | Workers dashboard sidebar |
| `R2_ACCESS_KEY_ID` (optional) | Created in CF Dashboard → R2 → Manage R2 API Tokens. Scoped to **read-only** on the `karinto-captures` bucket. Enables the PR dark-launch replay step. |
| `R2_SECRET_ACCESS_KEY` (optional) | The matching secret from the same R2 API token. |

### Optional GitHub variables

Tuning knobs for the dark-launch flow. All are repo-level **variables** (not
secrets — non-sensitive integers), set under Settings → Secrets and
variables → Actions → Variables. Unset values fall back to the defaults
hardcoded in the Worker / workflow.

| Variable | Default | Effect |
| --- | --- | --- |
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

# 5. Deploy the prod linter (with binding) + captures Worker. Normally this
#    happens via the release workflow, but the first time you can run:
npm ci
npx wrangler deploy --env production
npx wrangler deploy --config wrangler.maintenance.jsonc
```

`CLOUDFLARE_ACCOUNT_ID` is reused as `R2_ACCOUNT_ID` by the replay step
(both workflows pass it in via `env`).

### Adding an intentional-diff ignore rule

When a PR deliberately changes linter output (new rule, message rewording,
severity change, etc.), add a `scripts/diff-rules/*.mjs` file in the same PR.
See `scripts/diff-rules/README.md` for the rule contract and conventions.

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
