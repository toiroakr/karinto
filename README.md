# karinto

`curl`-able GitHub Actions linter. POST a workflow or `action.yml` and get
back JSON diagnostics. Rules are inspired by
[actionlint](https://github.com/rhysd/actionlint),
[zizmor](https://github.com/zizmorcore/zizmor), and
[ghalint](https://github.com/suzuki-shunsuke/ghalint) — see
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).

Public endpoint: `https://karinto.toiroakr.workers.dev`

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

`GET` or `POST`. Parameters can come from the query string, the request
body (raw `key=value&...`, JSON, or a plain YAML blob), or both — body
values win on conflict.

| Key | Type | Notes |
| --- | --- | --- |
| `type` | `workflow` \| `action` \| *(omit)* | Optional; auto-detected when blank |
| `content` | string | The YAML source |
| `disable` | string | Comma-separated glob patterns of rule IDs to skip. At most 64 patterns, 128 characters per pattern, and one `*` per pattern. |
| `repo` | `owner/name` | Public-repo mode; mutually exclusive with `content` |
| `targets` | string | Comma-separated literal file paths (required with `repo`). Globs are not supported — list each file. |
| `osv` | `1` / `true` | Query OSV.dev for known-vulnerable actions (adds 50–300 ms) |

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

`GET`/`POST` over a public repo:

```sh
curl "https://karinto.toiroakr.workers.dev?repo=actions/checkout&targets=action.yml"
```

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
        "message": "duplicate job ID `build` (conflicts with `Build` case-insensitively)"
      }
    ]
  }
}
```

In `repo` mode the result is wrapped:

```json
{
  "ok": true,
  "repo": "actions/checkout",
  "targets": ["action.yml"],
  "files": [ { "path": "action.yml", "ok": true, "result": { ... } } ]
}
```

## Private repositories

For private repos pass `content` directly. The Worker does not handle
`GITHUB_TOKEN`-authenticated `repo`-mode fetches.

## Development

Build, test, deploy, and rule-catalog notes live in
[`DEVELOPMENT.md`](DEVELOPMENT.md).
