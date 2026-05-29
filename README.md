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

61 of 82 catalogued rules are active. They cover syntax, expression typing
and context availability, permissions hygiene, pinned-`uses` requirements,
taint analysis for template injection, and a range of security policies
(excessive permissions, self-hosted runners, OIDC migration, dangerous
triggers, and more). The full catalogue with status, severity, and upstream
origins lives in [`rules_catalog.md`](rules_catalog.md) (human-readable
mirror of the in-code source of truth at
[`rules_catalog.mbt`](rules_catalog.mbt)).

## API

`GET` or `POST`. Parameters can come from the URL path
(`/<owner>/<repo>/<commit>[/<target/path/...>]` — segments after the
commit are joined into a single nested target path), the query string,
the request body (raw `key=value&...`, JSON, or a plain YAML blob), or
any mix — body beats query, query beats path on conflict. Paths that
don't match the repo-mode shape are ignored so the Worker can be served
under arbitrary path prefixes.

| Key | Type | Notes |
| --- | --- | --- |
| `type` | `workflow` \| `action` \| *(omit)* | Optional; auto-detected when blank |
| `content` | string | The YAML source |
| `disable` | string | Comma-separated glob patterns of rule IDs to skip. At most 64 patterns, 128 characters per pattern, and one `*` per pattern. |
| `repo` | `owner/name` | Public-repo mode; mutually exclusive with `content` |
| `commit` | hex SHA, 7–64 chars | **Required** whenever `repo` is set. Non-hex branch/tag names (e.g. `main`, `v1.2.3`) are rejected. Hex-shaped refs are accepted at face value — a short SHA can collide with an all-hex branch/tag (e.g. `deadbee`), so use the full 40-char SHA for guaranteed immutability. |
| `targets` | string | Comma-separated literal file paths. Required with `repo` unless a single target is supplied via the URL path (`/<owner>/<repo>/<commit>/<target/...>`). Globs are not supported — list each file. At most 50 paths; requests over the cap are rejected with `400` rather than silently truncated. |
| `osv` | `1` / `true` | Query OSV.dev for known-vulnerable actions (adds 50–300 ms) |
| `no_capture` | `1` / `true` | Skip persisting this request to the dark-launch capture store (see *Privacy*) |

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

Or with explicit query parameters and multiple targets:

```sh
curl "https://karinto.toiroakr.workers.dev?repo=actions/checkout&commit=b4ffde65f46336ab88eb53be808477a3936bae11&targets=action.yml,.github/workflows/test.yml"
```

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

- `job` — the offending job's ID (the key under `jobs:`). Omitted for
  workflow-global findings and for action-file steps.
- `step` — the step the finding is about, as `{ "index": <0-based position in
  the steps list>, "id": "<step id, when declared>" }`. `index` is always
  present so a step is locatable even without an `id:`; `id` is omitted when
  the step declares none.

The YAML parser does not preserve source layout, so diagnostics do not carry
line/column positions; `job`/`step` are the location handles instead.

In `repo` mode the result is wrapped:

```json
{
  "ok": true,
  "repo": "actions/checkout",
  "commit": "b4ffde65f46336ab88eb53be808477a3936bae11",
  "targets": ["action.yml"],
  "files": [ { "path": "action.yml", "ok": true, "result": { ... } } ],
  "engine_version": "0.3.1"
}
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

For private repos pass `content` directly. The Worker does not handle
`GITHUB_TOKEN`-authenticated `repo`-mode fetches.

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
