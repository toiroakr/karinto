# curllint

`curl`-able GitHub Actions linter. The lint engine is written in
[MoonBit](https://www.moonbitlang.com/) and runs on Cloudflare Workers. Rules
are inspired by [actionlint](https://github.com/rhysd/actionlint),
[zizmor](https://github.com/zizmorcore/zizmor), and
[ghalint](https://github.com/suzuki-shunsuke/ghalint) — see
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).

## Status

MVP. A small set of rules is implemented; many more are scaffolded with
skipped tests that document the intended behaviour.

Implemented:

| ID | Severity | Summary |
| --- | --- | --- |
| `act-id-unique` | error | Job and step IDs must be unique (case-insensitive) |
| `ghl-001` | warning | Jobs must declare `permissions:` |
| `ghl-003` | error | `permissions: write-all` is forbidden |

The remaining ~40 medium-and-higher-priority rules are listed in
`curllint_test.mbt` as `#skip(...)`-attributed test cases. They describe the
expected behaviour so they can be filled in one-by-one.

## Layout

```
.                        # MoonBit library package — the lint engine
├── curllint.mbt         # public API: types, lint(), helpers
├── rules.mbt            # rule registry + currently-implemented rules
├── curllint_test.mbt    # blackbox tests + skipped specs for unimplemented rules
├── curllint_wbtest.mbt  # whitebox tests (internal helpers)
├── cmd/main             # demo CLI (`moon run cmd/main`)
├── worker               # MoonBit → JS export package for Cloudflare Workers
└── cf                   # Cloudflare Worker (`index.js` + `wrangler.jsonc`)
```

## Develop

```sh
# Tests (11 impl + 45 skipped)
moon test

# WASM-gc build (default backend, used by `moon run`)
moon build

# JS build for the Worker (release)
moon build --target js --release
```

The Worker imports `lint_string` from the compiled JS at
`_build/js/release/build/worker/worker.js`. The import is deferred to the
first request because MoonBit's compiled JS seeds a hashmap RNG via
`crypto.getRandomValues` at module load — CF Workers forbids that in global
scope, so we lazy-`import()` inside the `fetch` handler.

To run it locally:

```sh
cd cf
npm install        # installs wrangler + js-yaml
npm run dev        # `wrangler dev`
```

To deploy:

```sh
cd cf
npm run deploy     # `wrangler deploy`
```

## API

The Worker accepts `GET` and `POST`. Parameters can come from the query
string, the request body (raw `key=value&...`, JSON, or a plain YAML blob),
or both — body values win.

| Key | Type | Notes |
| --- | --- | --- |
| `type` | `workflow` \| `action` \| *(omit)* | Optional; auto-detected when blank |
| `content` | string | The YAML source |
| `disable` | string | Comma-separated glob patterns of rule IDs to skip |
| `repo` | `owner/name` | Public-repo mode; mutually exclusive with `content` |
| `targets` | string | Comma-separated path globs (used with `repo`). Default `.github/workflows/*.yml,.github/workflows/*.yaml` |

### Examples

`POST` with the workflow as the body:

```sh
curl -X POST --data-binary @.github/workflows/ci.yml \
     https://curllint.example.workers.dev
```

`POST` with form data:

```sh
curl https://curllint.example.workers.dev \
     --data-urlencode "content@.github/workflows/ci.yml" \
     --data "disable=ghl-*"
```

`GET` with query parameters (small payloads only):

```sh
curl -G https://curllint.example.workers.dev \
     --data-urlencode "content=$(cat workflow.yml)" \
     --data "type=workflow"
```

`GET`/`POST` over a public repo:

```sh
curl "https://curllint.example.workers.dev?repo=actions/checkout&targets=action.yml"
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
        "rule": "act-id-unique",
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

## Logging

The Worker logs a one-line JSON record per request via `console.log`,
captured by `wrangler tail`:

```json
{ "event": "request", "method": "POST", "type": "(auto)",
  "disable": "ghl-*", "repo": "", "targets": "",
  "content_lines": 42, "files": 1, "elapsed_ms": 4 }
```

## Private repositories

For private repos pass `content` directly. The Worker does not handle
`GITHUB_TOKEN`-authenticated calls in this MVP.
