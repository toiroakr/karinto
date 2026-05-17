# karinto

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
| `duplicate-job-step-ids` | error | Job and step IDs must be unique (case-insensitive) |
| `permissions-write-all-forbidden` | error | `permissions: write-all` is forbidden |
| `job-permissions-required` | warning | Jobs must declare `permissions:` |
| `job-timeout-minutes-required` | warning | Jobs must declare `timeout-minutes:` |
| `checkout-persist-credentials-false` | error | `actions/checkout` must set `persist-credentials: false` |
| `unpinned-uses` | warning | `uses:` must pin to a full-length commit SHA |
| `artipacked` | error | Checkout-then-upload-artifact leaks persisted credentials |
| `bot-conditions` | error | `github.actor` bot check is spoofable |
| `excessive-permissions` | warning | Job grants ≥3 `write` permissions |
| `use-trusted-publishing` | info | Prefer OIDC trusted publishing over long-lived tokens |
| `dependabot-cooldown` | info | Dependabot updates should configure `cooldown` |

The catalogue in `rules_catalog.mbt` enumerates **82 rules** — every
distinct check actionlint, zizmor, and ghalint perform. **11 are
implemented**; the remaining 71 are scaffolded as `#skip`-attributed
fixtures. Five rules are deliberate consolidations of overlapping
upstream checks; each one records every upstream identifier it absorbs
in its `origins` field, so the lineage is preserved:

| Consolidated rule | Absorbed upstreams |
| --- | --- |
| `unpinned-uses` | `zizmor:unpinned-uses` + `ghalint:ghl-008 (action_ref_should_be_full_length_commit_sha)` |
| `secrets-inherit` | `zizmor:secrets-inherit` + `ghalint:ghl-004 (deny_inherit_secrets)` |
| `unpinned-images` | `zizmor:unpinned-images` + `ghalint:ghl-007 (deny_job_container_latest_image)` |
| `hardcoded-container-credentials` | `zizmor:hardcoded-container-credentials` + `actionlint:hardcoded-credentials` |
| `template-injection` | `zizmor:template-injection` + `actionlint:script-injection` |

The 71 unimplemented rules are scaffolded in the per-source
`*_rules_test.mbt` files as `#skip(...)`-attributed test cases with
fixture YAML + expected JSON, so each rule has a precise behavioural spec
ready to be filled in.

## Layout

```
.                             # MoonBit library package — the lint engine
├── karinto.mbt               # public API: types, lint(), helpers
├── rules.mbt                 # rule registry + implemented rules
├── rules_catalog.mbt         # full catalogue (82 rules, metadata + origins)
├── karinto_test.mbt          # blackbox tests for implemented rules + engine
├── actionlint_rules_test.mbt # 35 #skip fixtures for actionlint-derived rules
├── zizmor_rules_test.mbt     # 30 #skip + 6 active fixtures for zizmor audits
├── ghalint_rules_test.mbt    #  6 #skip + 2 active fixtures for ghalint policies
├── coverage_test.mbt         # asserts catalogue ↔ tests + origins stay in sync
├── karinto_wbtest.mbt        # whitebox tests (internal helpers)
├── cmd/main                  # demo CLI (`moon run cmd/main`)
├── worker                    # MoonBit → JS export package for the Worker
└── cf                        # Cloudflare Worker (`index.js` + `wrangler.jsonc`)
```

## Develop

```sh
# Tests (23 active + 71 skipped fixtures)
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
| `targets` | string | Comma-separated literal file paths (required with `repo`). Globs are not supported — list each file. |

### Examples

`POST` with the workflow as the body:

```sh
curl -X POST --data-binary @.github/workflows/ci.yml \
     https://karinto.example.workers.dev
```

`POST` with form data:

```sh
curl https://karinto.example.workers.dev \
     --data-urlencode "content@.github/workflows/ci.yml" \
     --data "disable=permissions-*"
```

`GET` with query parameters (small payloads only):

```sh
curl -G https://karinto.example.workers.dev \
     --data-urlencode "content=$(cat workflow.yml)" \
     --data "type=workflow"
```

`GET`/`POST` over a public repo:

```sh
curl "https://karinto.example.workers.dev?repo=actions/checkout&targets=action.yml"
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

## Logging

The Worker logs a one-line JSON record per request via `console.log`,
captured by `wrangler tail`:

```json
{ "event": "request", "method": "POST", "type": "(auto)",
  "disable": "permissions-*", "repo": "", "targets": "",
  "content_lines": 42, "files": 1, "elapsed_ms": 4 }
```

## Private repositories

For private repos pass `content` directly. The Worker does not handle
`GITHUB_TOKEN`-authenticated calls in this MVP.
