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

68 of 83 catalogued rules are active. They cover syntax, expression typing
and context availability, permissions hygiene, pinned-`uses` requirements,
taint analysis for template injection, and a range of security policies
(excessive permissions, self-hosted runners, OIDC migration, dangerous
triggers, and more). The full catalogue with status, severity, and upstream
origins lives in [`rules_catalog.md`](rules_catalog.md) (human-readable
mirror of the in-code source of truth at
[`rules_catalog.mbt`](rules_catalog.mbt)).

## API

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
| `type` | `workflow` \| `action` \| *(omit)* | Optional; auto-detected when blank |
| `content` | string | The YAML source |
| `disable` | string | Comma-separated glob patterns of rule IDs to skip. At most 64 patterns, 128 characters per pattern, and one `*` per pattern. |
| `repo` | `owner/name` | Public-repo mode; mutually exclusive with `content` |
| `commit` | hex SHA, 7–64 chars | An **immutable pin**. Either this or `ref` is required whenever `repo` is set. Non-hex branch/tag names (e.g. `main`, `v1.2.3`) are rejected here — use `ref` for those. A short SHA can collide with an all-hex branch/tag (e.g. `deadbee`), so use the full 40-char SHA for guaranteed immutability. |
| `ref` | branch \| tag \| `HEAD` \| SHA | **Mutable** ref; fetches that ref's *latest* commit. Use it to lint the default branch (`ref=HEAD`) or any branch/tag by name. Takes precedence over `commit`. A domain-swapped GitHub URL (`…/blob/<ref>/<path>`) fills this from the path. Slashy branch names (`release/1.x`) work via `ref=` but not the path form, which treats only the first post-`blob` segment as the ref. |
| `targets` | string | Comma-separated literal file paths. Globs are not supported — list each file. At most 50 paths; requests over the cap are rejected with `400` rather than silently truncated. Omit it (with no path target either) to lint **all** `.github/workflows` files on the chosen ref — see *Whole-repo mode*. |
| `osv` | `1` / `true` | Query OSV.dev for known-vulnerable actions (adds 50–300 ms) |
| `forbidden` | string | Caller-supplied denylist for `forbidden-uses`. Comma-separated globs matched against `uses:` refs. |
| `archived` | string | Caller-supplied `owner/repo` for `archived-uses`, merged with the daily KV-cached baseline. |
| `no_capture` | `1` / `true` | Skip persisting this request to the dark-launch capture store (see *Privacy*) |

`forbidden` / `archived` accept at most 200 comma-separated entries of 256
characters each. The response also carries `online_audit_candidates` — the
external `uses:` refs that need a live GitHub API lookup (`impostor-commit`,
`ref-version-mismatch`). karinto does not resolve those; a companion action
([`companion-action/`](companion-action/)) checks them and reports directly.
See [*Action-side context*](docs/action-context.md) for the full flow.

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
