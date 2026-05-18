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
