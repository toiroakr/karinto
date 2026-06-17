# karinto

`curl`-able GitHub Actions linter. POST a workflow or `action.yml` and get
back JSON diagnostics. Rules are inspired by
[actionlint](https://github.com/rhysd/actionlint),
[zizmor](https://github.com/zizmorcore/zizmor), and
[ghalint](https://github.com/suzuki-shunsuke/ghalint) — see
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).

Public endpoint: `https://karinto.toiroakr.workers.dev`

Try it in the browser: <https://toiroakr.github.io/karinto/>

## Coverage

72 of 83 catalogued rules are active. They cover syntax, expression typing
and context availability, permissions hygiene, pinned-`uses` requirements,
taint analysis for template injection, and a range of security policies
(excessive permissions, self-hosted runners, OIDC migration, dangerous
triggers, and more). The full catalogue with status, severity, and upstream
origins lives in [`rules_catalog.md`](rules_catalog.md) (human-readable
mirror of the in-code source of truth at
[`rules_catalog.mbt`](rules_catalog.mbt)).

## API

> **Recommended: send the YAML directly.** `POST` the workflow / `action.yml`
> as the request body (or pass it as the `content` parameter). It works on
> every deployment, makes no GitHub round-trip, and is **not** subject to any
> GitHub rate limit. This is the path to use in CI and other automated callers.

The **repo-mode** endpoints (below) fetch files from GitHub *for* you instead
of taking `content`. They are **opt-in** — disabled unless the deployment sets
the `REPO_MODE_ENABLED` variable, so they may be off on a given endpoint
(including the public `karinto.toiroakr.workers.dev`). When enabled they lean
on GitHub's raw hosting and API, so they are **far more likely to hit GitHub
rate limits**: whole-repo discovery in particular shares a single
unauthenticated **60 req/hour/IP** budget across *all* callers (the requests
egress from the Worker's shared Cloudflare IP). Reach for repo mode for
one-off, interactive checks — not high-volume automation; send `content` there.

`GET` or `POST`. Parameters can come from the URL path
(`/<owner>/<repo>` to lint **every workflow on the default branch**;
`/<owner>/<repo>/<commit>[/<target/path/...>]`; or a domain-swapped GitHub
file URL `/<owner>/<repo>/{blob,tree,raw}/<ref>/<target/path/...>` — segments
after the commit/ref are joined into a single nested target path), the query
string, the request body (raw `key=value&...`, JSON, or a plain YAML blob), or
any mix — body beats query, query beats path on conflict. Paths that
don't match the repo-mode shape are ignored so the Worker can be served
under arbitrary path prefixes.

When `repo` is set with **no** `targets` (and no path target), karinto
discovers and lints every `*.yml` / `*.yaml` file under `.github/workflows`
on the chosen ref — the default branch when no `commit`/`ref` is given. This
is the only mode that calls the GitHub API on the request path (directory
listing has no `raw.githubusercontent.com` equivalent), so it is subject to
GitHub's unauthenticated rate limit (60 req/hour/IP) — see *Whole-repo mode*
below.

| Key | Type | Notes |
| --- | --- | --- |
| `type` | `workflow` \| `action` \| `dependabot` \| *(omit)* | Optional; auto-detected when blank (`jobs`/`on` → workflow, `runs` → action, `updates` → dependabot) |
| `content` | string | The YAML source. **The recommended input** — always available, no GitHub round-trip, no rate limit. |
| `disable` | string | Comma-separated glob patterns of rule IDs to skip. At most 64 patterns, 128 characters per pattern, and one `*` per pattern. |
| `repo` | `owner/name` | Repo mode; mutually exclusive with `content`. **Opt-in** (`REPO_MODE_ENABLED`) and GitHub-rate-limit-prone — see the note above. Returns `403` when the deployment has repo mode disabled. |
| `commit` | hex SHA, 7–64 chars | An **immutable pin**. Either this or `ref` is required in **explicit-target mode** (`targets=` or a URL-path target); whole-repo discovery (no targets) defaults to the repo's default branch when neither is given. Non-hex branch/tag names (e.g. `main`, `v1.2.3`) are rejected here — use `ref` for those. A short SHA can collide with an all-hex branch/tag (e.g. `deadbee`), so use the full 40-char SHA for guaranteed immutability. |
| `ref` | branch \| tag \| `HEAD` \| SHA | **Mutable** ref; fetches that ref's *latest* commit. Use it to lint the default branch (`ref=HEAD`) or any branch/tag by name. Takes precedence over `commit`. A domain-swapped GitHub URL (`…/blob/<ref>/<path>`) fills this from the path. Slashy branch names (`release/1.x`) work via `ref=` but not the path form, which treats only the first post-`blob` segment as the ref. |
| `targets` | string | Comma-separated literal file paths. Globs are not supported — list each file. At most 50 paths; requests over the cap are rejected with `400` rather than silently truncated. Omit it (with no path target either) to lint **all** `.github/workflows` files on the chosen ref — see *Whole-repo mode*. |
| `osv` | `1` / `true` | Query OSV.dev for known-vulnerable actions (adds 50–300 ms) |
| `forbidden` | string | Caller-supplied denylist for `forbidden-uses`. Comma-separated globs matched against `uses:` refs. |
| `archived` | string | Caller-supplied `owner/repo` for `archived-uses`, merged with the daily KV-cached baseline. |
| `no_capture` | `1` / `true` | Skip persisting this request to the dark-launch capture store (see *Privacy*) |
| `format` | `json` \| `sarif` | Output format; defaults to the JSON envelope. `sarif` returns a [SARIF 2.1.0](https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html) document — see [*SARIF output*](#sarif-output). |
| `path` | string | Repo-relative path of the `content` (e.g. `.github/workflows/ci.yml`). In `format=sarif` it becomes the SARIF `artifactLocation.uri`; in either format it also resolves a `ghalint` exclude's `workflow_file_path` scope. Same shape rules as `targets` paths. Unnecessary in `repo` mode, where targets already carry paths. |
| `persona` | `regular` \| `pedantic` \| `auditor` | Analysis profile (see [*Personas*](#personas)). Defaults to `auditor` (every finding). An unrecognized value is a `400`. |
| `ghalint` | string | Verbatim ghalint config (`ghalint.yaml`) text; its `excludes:` list suppresses matching findings (see [*Ignoring findings*](#ignoring-findings)). At most 64 KiB. |
| `zizmor` | string | Verbatim zizmor config (`zizmor.yml`) text; its `rules.<id>.disable` / `rules.<id>.ignore` suppress matching findings (see [*Ignoring findings*](#ignoring-findings)). At most 64 KiB. |

`forbidden` / `archived` accept at most 200 comma-separated entries of 256
characters each. The response also carries `online_audit_candidates` — the
external `uses:` refs that need a live GitHub API lookup (`impostor-commit`,
`ref-version-mismatch`). karinto does not resolve those; a companion action
([`companion-action/`](companion-action/)) checks them and reports directly.
See [*Action-side context*](docs/action-context.md) for the full flow.

### Personas

`persona` mirrors [zizmor's persona model](https://docs.zizmor.sh/usage/#using-personas):
each finding declares the *minimum* persona at which it surfaces, and a request
shows every finding at or below the requested level (`regular ⊂ pedantic ⊂
auditor`).

| Persona | Shows |
| --- | --- |
| `regular` | High-confidence, real problems only — the equivalent of a default `zizmor` run. |
| `pedantic` | The above **plus** code smells / likely-safe-but-noisy findings. |
| `auditor` (**default**) | Everything, including low-confidence / defense-in-depth findings. |

The default is `auditor` so the bare endpoint and CLI keep reporting every
finding. Pass `persona=regular` to match what a stock `zizmor` invocation
(no `--pedantic` / `--persona`) would flag.

Findings that are **not** `regular` (hidden unless you opt up):

- **Pedantic** — `anonymous-definition`, `self-hosted-runner`,
  `undocumented-permissions`, `concurrency-limits`, the `template-injection`
  *Info backstop* (the per-`${{ … }}` finding; see the split below), the
  `excessive-permissions` *per-key* finding (`<x>: write is overly broad`), and
  the pedantic-only subset of `superfluous-actions`.
- **Auditor** — `secrets-outside-env`, and `misfeature`'s
  `defaults.run.shell: cmd` finding.

Everything else fires under `regular`. Several rules are **persona-split** per
finding, pinned against `zizmor`'s actual per-persona behaviour (see
`persona_gating_test.mbt` / `persona_regular_parity_test.mbt`):

- `excessive-permissions` — blanket `write-all`/`read-all` and the **per-job**
  "default permissions used" finding are `regular`; the **workflow-level** "no
  `permissions:` block" finding and the per-key over-scope finding are
  `pedantic` (matching `zizmor`, which only surfaces the workflow-level default
  under `--pedantic`).
- `template-injection` — the high-cap event contexts are `regular` (`Error`);
  non-static influenceable contexts (`vars.*`, `inputs.*`, `*.outputs.*`,
  `github.ref*`, `github.actor`, `github.workflow`) are `regular` (`Info`);
  truly-static contexts (`github.run_id`, `github.sha`, `matrix.*`, …) and
  `env.*` (karinto can't tell static from dynamic) are the `pedantic` backstop.
- `superfluous-actions` — `regular` for most of the catalogue; `pedantic` for
  the subset `zizmor` gates there (e.g. `peter-evans/create-pull-request`,
  `dtolnay/rust-toolchain`).

### Ignoring findings

Beyond the `disable` glob list (which skips a rule everywhere), karinto honours
the opt-outs authors already wrote for the upstream tools:

- **Inline comments** — `# karinto: ignore[rule-id]` or
  `# zizmor: ignore[rule-id]` on a line suppresses findings **on that same
  line** (line-scoped, not file-global). List several rules with commas
  (`# zizmor: ignore[a, b]`) and add a free-form note after the bracket
  (`# zizmor: ignore[a] handled upstream`). This matches
  [zizmor's inline-ignore syntax](https://docs.zizmor.sh/usage/#inline-ignores);
  it reads straight from `content`, so it works on every entry point.
  actionlint and ghalint have no inline-comment form, so karinto recognises
  only the `karinto` and `zizmor` prefixes.
- **ghalint config** — a `ghalint.yaml` `excludes:` list is honoured. Each
  entry's `policy_name` is mapped onto the karinto rule(s) that absorbed it
  (via the catalogue's `origins`), and the `workflow_file_path` / `job_name` /
  `action_name` / `step_id` scope fields are applied. Pass it through the
  [local CLI](#local-cli)'s `--ghalint-config`, or over HTTP via the `ghalint`
  parameter (the config's verbatim text); the `workflow_file_path` scope then
  resolves against `path` in content mode or each file's repo-relative path in
  repo mode. actionlint configs are **not** honoured — they ignore by regex
  against actionlint's own error messages, which do not map onto karinto's
  findings.
- **zizmor config** — a `zizmor.yml` `rules:` section is honoured. Each rule's
  `disable: true` skips that rule everywhere (rule ids match zizmor's audit
  names verbatim), and an `ignore:` list of `filename[:line[:col]]` entries
  drops findings of that rule in the matching file (a pinned `line` / `col`
  must match the finding's position; an entry without a line matches any line,
  and without a column any column on that line). Pass it through the
  [local CLI](#local-cli)'s `--zizmor-config`, or over HTTP via the `zizmor`
  parameter; the `ignore` filename resolves against `path` in content mode or
  each file's repo-relative path in repo mode.

### Examples

`POST` with the workflow as the body:

```sh
curl -X POST --data-binary @.github/workflows/ci.yml \
     https://karinto.toiroakr.workers.dev
```

`POST` with form data:

```sh
curl https://karinto.toiroakr.workers.dev \
     --data-urlencode "content@.github/workflows/ci.yml" \
     --data "disable=permissions-*"
```

`GET` with query parameters (small payloads only):

```sh
curl -G https://karinto.toiroakr.workers.dev \
     --data-urlencode "content=$(cat workflow.yml)" \
     --data "type=workflow"
```

The remaining examples use **repo mode**, which must be enabled on the
deployment (`REPO_MODE_ENABLED`) — otherwise they return `403`. They are handy
for one-off checks but draw on GitHub rate limits; prefer sending `content` for
anything automated.

`GET`/`POST` over a public repo (single target via path):

```sh
curl "https://karinto.toiroakr.workers.dev/actions/checkout/b4ffde65f46336ab88eb53be808477a3936bae11/action.yml"
```

Lint the latest commit on a branch by **swapping the domain** of a GitHub file
URL (`github.com` → `karinto.toiroakr.workers.dev`):

```sh
# https://github.com/actions/checkout/blob/main/action.yml
curl "https://karinto.toiroakr.workers.dev/actions/checkout/blob/main/action.yml"
```

Lint **every workflow on the default branch** with just `owner/repo` (swap the
domain of a repo's GitHub URL):

```sh
# https://github.com/actions/checkout
curl "https://karinto.toiroakr.workers.dev/actions/checkout"
```

Or pin nothing and lint the default branch's latest commit via `ref`:

```sh
curl "https://karinto.toiroakr.workers.dev?repo=actions/checkout&ref=HEAD&targets=action.yml"
```

Or with explicit query parameters and multiple targets:

```sh
curl "https://karinto.toiroakr.workers.dev?repo=actions/checkout&commit=b4ffde65f46336ab88eb53be808477a3936bae11&targets=action.yml,.github/workflows/test.yml"
```

### Whole-repo mode

`repo` with **no** `targets` (and no path target) lints every `*.yml` /
`*.yaml` file under `.github/workflows`. The ref defaults to the repository's
**default branch**; pass `ref=`/`commit=` to scan a specific branch, tag, or
commit instead.

Listing a directory has no `raw.githubusercontent.com` equivalent, so this is
the one mode that calls the **GitHub contents API** on the request path:

- It is subject to GitHub's **unauthenticated rate limit (60 req/hour/IP)**.
  When that is hit the request fails with `429` and a message pointing you at
  the escape hatches (retry later, pass explicit `targets=`, or self-host with
  a token).
- Set a `GITHUB_PUBLIC_READ_TOKEN` repo secret and the release / staging /
  preview deploys mirror it into the Worker (as an encrypted secret), raising
  the ceiling to 5000 req/hour and reaching private repos the token can see.
  Unset → the deployment runs token-less and this mode stays anonymous.
- At most 50 workflows are linted per request (the `targets` cap). When a repo
  has more, the response sets `"truncated": true` and `"discovered": <count>`
  so you know the result is partial; pass explicit `targets=` to pick the rest.
- `404` means there is no `.github/workflows` directory on that ref.

### Limits

- **Request body**: 1 MiB. Direct payloads over the cap short-circuit with
  `413 Payload Too Large` before reaching the parser. In `repo` mode the
  request still returns `200` and the oversized file is surfaced as
  `files[].error` so the rest of the batch is unaffected.
- **Per-IP rate limit**: 60 requests / minute. Over-limit traffic gets `429`.
  Requests originating from GitHub-hosted Actions runners are exempted (their
  egress IPs are shared across unrelated tenants), so noisy CI tenants can't
  collateral-429 other CI traffic.

### Response

```json
{
  "ok": true,
  "result": {
    "kind": "workflow",
    "stats": { "jobs": 2, "steps": 2, "lines": 11 },
    "diagnostics": [
      {
        "rule": "duplicate-job-step-ids",
        "severity": "error",
        "message": "duplicate job ID `build` (conflicts with `Build` case-insensitively)",
        "job": "build"
      }
    ]
  },
  "engine_version": "0.3.1"
}
```

`engine_version` is present on every response (success and error). It is the
version of the karinto engine that produced the diagnostics — see
[*Versioning & pinning*](#versioning--pinning).

Each diagnostic carries `rule`, `severity`, and `message`. When a finding can
be tied to a location, it also includes:

- `pos` — the source position, as `{ "line": <1-based>, "col": <1-based> }`.
  A finding about a specific field points at that field — the `uses:` ref, the
  `run:` script, a multi-line `permissions:` key. Other job/step-scoped
  findings point at the job key or the step entry. Omitted for workflow-global
  findings.
- `job` — the offending job's ID (the key under `jobs:`). Omitted for
  workflow-global findings and for action-file steps.
- `step` — the step the finding is about, as `{ "index": <0-based position in
  the steps list>, "id": "<step id, when declared>" }`. `index` is always
  present so a step is locatable even without an `id:`; `id` is omitted when
  the step declares none.

`pos` comes from karinto's own YAML parser, which records each node's source
range and resolves line/column on demand; `job`/`step` remain the fallback
handles for workflow-global findings that have no single source location.

In `repo` mode the result is wrapped:

```json
{
  "ok": true,
  "repo": "actions/checkout",
  "ref": "b4ffde65f46336ab88eb53be808477a3936bae11",
  "commit": "b4ffde65f46336ab88eb53be808477a3936bae11",
  "targets": ["action.yml"],
  "files": [ { "path": "action.yml", "ok": true, "result": { ... } } ],
  "engine_version": "0.3.1"
}
```

`ref` echoes the branch / tag / `HEAD` / SHA that was fetched (`"HEAD"` for the
default-branch discovery case). `commit` is present **only** when `ref` is an
immutable SHA pin (a branch/tag ref has no resolved SHA in the response — the
Worker does not resolve content SHAs on the request path). A `ref=main` request
therefore returns `"ref": "main"` and no `commit`. In whole-repo mode, `targets`
lists the discovered files; if discovery found more than the 50-file cap, the
response also carries `"truncated": true` and `"discovered": <count>`.

### SARIF output

`format=sarif` swaps the envelope for a [SARIF 2.1.0](https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html)
document (content type `application/sarif+json`) that uploads directly to
GitHub Code Scanning via
[`github/codeql-action/upload-sarif`](https://github.com/github/codeql-action/tree/main/upload-sarif).
It works in both `content` and `repo` mode:

```sh
# content mode (always available) — pass `path=` so findings anchor to a file
curl -X POST --data-binary @.github/workflows/ci.yml \
     "https://karinto.toiroakr.workers.dev?format=sarif&path=.github/workflows/ci.yml"

# repo mode (requires REPO_MODE_ENABLED on the deployment)
curl "https://karinto.toiroakr.workers.dev/actions/checkout/b4ffde65f46336ab88eb53be808477a3936bae11/action.yml?format=sarif"
```

Mapping:

| Envelope | SARIF |
| --- | --- |
| `rule` | `result.ruleId`, plus a `tool.driver.rules[]` entry carrying the catalogue title, default severity, and upstream `origins` |
| `severity` | `result.level` (`error` / `warning`; `info` becomes `note`) |
| `message` | `result.message.text` |
| `pos` | `physicalLocation.region` (`startLine` / `startColumn`) |
| `job` / `step` | `locations[].logicalLocations[]` (`kind: "job"` / `"step"`) |
| `parse_error` | one `error`-level result under a synthetic `parse-error` rule |
| `files[].error` (repo mode) | `invocations[].toolExecutionNotifications[]`, with `executionSuccessful: false` |
| `engine_version` | `tool.driver.version` |

`physicalLocation` needs an artifact URI, so it is emitted when the input
has a path: always in `repo` mode, and in `content` mode only when the
request also passes `path=`. Pathless results keep their logical (job/step)
locations, but GitHub Code Scanning cannot anchor those to a file — pass
`path=` (or use `repo` mode) when uploading. `online_audit_candidates` and
the dark-launch capture are envelope-mode-only.

A complete workflow that surfaces findings in the repository **Security**
tab (public repos — `repo` mode fetches the files from
raw.githubusercontent.com). Note this uses **repo mode**, so it only works
against an endpoint with `REPO_MODE_ENABLED` set; otherwise POST each file as
`content` with `format=sarif&path=…`, or run the [Local CLI](#local-cli):

```yaml
name: karinto
on:
  push:
    branches: [main]
permissions:
  contents: read
  security-events: write
jobs:
  karinto:
    runs-on: ubuntu-latest
    steps:
      - name: Lint workflows to SARIF
        run: |
          curl -sf "https://karinto.toiroakr.workers.dev/${{ github.repository }}/${{ github.sha }}?format=sarif&targets=.github/workflows/ci.yml,.github/workflows/release.yml" \
            -o karinto.sarif
      - uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: karinto.sarif
```

For private repos, run the [Local CLI](#local-cli) on a checkout instead
(`--format sarif` with file arguments) — and note the CLI exits `1` when
error-severity findings exist, so give the lint step `continue-on-error:
true` (or append `|| true`) so the upload step still runs.

## Local CLI

Lint local files without deploying anything or making a network
round-trip — same engine, same JSON envelope as the Worker. Requires
Node.js (the CLI targets MoonBit's js backend).

```sh
# stdin
cat .github/workflows/ci.yml | moon run --target js cmd/main

# file arguments (kind auto-detected from filename / content)
moon run --target js cmd/main -- .github/workflows/ci.yml action.yml

# the same knobs as the Worker's `type` / `disable` parameters
moon run --target js cmd/main -- --type action --disable 'permissions-*' action.yml

# pick an analysis profile (see *Personas*); default is auditor (every finding)
moon run --target js cmd/main -- --persona regular .github/workflows/ci.yml

# honour a ghalint config's `excludes` (see *Ignoring findings*); the file
# path is matched against each exclude's `workflow_file_path`
moon run --target js cmd/main -- --ghalint-config ghalint.yaml .github/workflows/ci.yml

# honour a zizmor config's `rules.<id>.disable` / `ignore` (see *Ignoring findings*)
moon run --target js cmd/main -- --zizmor-config zizmor.yml .github/workflows/ci.yml

# SARIF 2.1.0 for GitHub Code Scanning (same as the Worker's `format=sarif`);
# file arguments become artifact URIs, stdin yields pathless results
moon run --target js cmd/main -- --format sarif .github/workflows/ci.yml > karinto.sarif
```

Exit codes are CI-friendly: `0` clean, `1` error-severity diagnostics or
YAML parse errors, `2` usage / IO errors. `moon run` does not propagate
the program's exit status, so in CI (or pre-commit hooks) run the built
bundle directly:

```sh
moon build --target js --release
node _build/js/release/build/cmd/main/main.js .github/workflows/ci.yml
```

## Versioning & pinning

`https://karinto.toiroakr.workers.dev` always serves the **latest** release.
For reproducible CI, three options:

- **Exact pin** — `https://karinto-vX-Y-Z.toiroakr.workers.dev` (immutable
  snapshot per release; dots → dashes).
- **Major alias** — `https://karinto-vX.toiroakr.workers.dev` (auto-rolls
  within a major; shielded from a future `1.0.0`).
- **Self-host** on your own Cloudflare account.

```sh
curl -X POST --data-binary @workflow.yml \
     https://karinto-v0-3-1.toiroakr.workers.dev
```

Every response carries an `engine_version` field on both success and error
paths, so even against the bare endpoint you can `jq -e '.engine_version
== "0.3.1"'` to fail loudly the moment the engine drifts.

Full guide — including the auto-prune retention rule and the 404 risk for
long-untouched exact pins, self-hosting steps, and a Renovate preset for
auto-bumping URL pins — in [`docs/pinning.md`](docs/pinning.md). Released
versions are listed under [GitHub Releases](https://github.com/toiroakr/karinto/releases).

## Private repositories

For private repos pass `content` directly — a deployment without a token
fetches `repo`-mode files anonymously and cannot read private repos. A
deployment with a `GITHUB_PUBLIC_READ_TOKEN` secret (see
[`DEVELOPMENT.md`](DEVELOPMENT.md#required-github-secrets)) can reach private
repos the token can see in whole-repo discovery mode.

## Privacy

The production deployment persists successful requests (the `content`
plus a few non-secret query parameters) and the corresponding response
into a private bucket for up to 30 days. These captures are used to
replay traffic against PR previews and detect regressions before they
reach prod. To opt out per-request, send either:

- query / form parameter `no_capture=1`, **or**
- HTTP header `X-Karinto-No-Capture: 1`

Requests using `osv=1` or `repo=` are never captured; nor are requests
whose `content` exceeds the per-deployment cap (default 100 KiB, tunable
via the `CAPTURE_CONTENT_LIMIT_KIB` Worker variable — see
[`DEVELOPMENT.md`](DEVELOPMENT.md#optional-github-variables)).

## Development

Build, test, deploy, and rule-catalog notes live in
[`DEVELOPMENT.md`](DEVELOPMENT.md).
