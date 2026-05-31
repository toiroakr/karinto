# Action-side context

A few karinto rules need information that is **not in the YAML being linted** —
it lives in the live state of the actions a workflow references. There are two
distinct ways karinto handles this, depending on how cacheable the fact is.

## 1. Facts karinto resolves for you (server-side)

| Rule | How | Notes |
| --- | --- | --- |
| [`known-vulnerable-actions`](../rules_catalog.md) | `osv=1` query param | The Worker queries OSV.dev and applies the advisory version ranges. |
| [`archived-uses`](../rules_catalog.md) | automatic | The Worker merges a KV-cached baseline of archived `owner/repo` (refreshed daily from `cf/archived-seed.json` via the GitHub API) with the engine's hardcoded baseline. No token needed by the caller. |

These are **per-repo / per-action** facts that change rarely, so karinto caches
them centrally — you get them without a `GITHUB_TOKEN`.

### Extending `archived-uses`

You can still add your own confirmed-archived repos per request:

```sh
curl -G https://karinto.toiroakr.workers.dev \
     --data-urlencode "content=$(cat wf.yml)" --data "type=workflow" \
     --data "archived=my-org/old-action"
```

`archived` is a comma-separated list of bare `owner/repo` (case-insensitive;
any `@ref` / subpath is ignored). It is merged with the KV baseline.

To grow the central baseline, add slugs to
[`cf/archived-seed.json`](../cf/archived-seed.json); the daily cron
re-verifies each against the GitHub API before publishing to KV, so a repo
that gets un-archived is dropped automatically.

### Caller policy: `forbidden-uses`

`forbidden` is a caller-supplied denylist (no API needed):

```sh
--data "forbidden=evil-org/*,*/deprecated-action@*"
```

Comma-separated globs (`*`, `?`) matched against both the bare
`owner/repo[/subpath]` and the full `…@ref`.

## 2. Facts the companion action resolves (`impostor-commit`, `ref-version-mismatch`)

`impostor-commit` and `ref-version-mismatch` hinge on a **specific `repo@sha`**,
which is not cacheable (SHAs are effectively unbounded) and needs an
authenticated GitHub API call. karinto-core does **not** resolve these. Instead
it returns the candidate refs and a companion action does the checks and
reports findings directly.

### What karinto returns

Every response carries `online_audit_candidates`: the external `uses:` refs
that need a live lookup.

```jsonc
"online_audit_candidates": [
  { "ref": "actions/checkout@<sha>", "name": "actions/checkout", "pin": "sha" },
  { "ref": "actions/cache@<sha>",    "name": "actions/cache",    "pin": "sha", "comment": "v4" },
  { "ref": "foo/bar@v1",             "name": "foo/bar",          "pin": "tag" }
]
```

- `pin: "sha"` → an impostor-commit candidate.
- `pin: "sha"` **with** `comment` → also a ref-version-mismatch candidate (the
  comment names the version the SHA is supposed to be).
- `pin: "tag"` → not pinned by SHA; no online audit applies.

### The companion action

A reference implementation lives in
[`companion-action/`](../companion-action/). It POSTs each file to karinto,
reads `online_audit_candidates`, resolves them via the GitHub API, and emits
GitHub annotations:

```yaml
jobs:
  audit:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@<sha>
      - uses: ./companion-action            # or your-org/karinto/companion-action@<sha>
        with:
          files: |
            .github/workflows/ci.yml
          fail-on: error                     # error | warning | none
```

What it checks:

- **impostor-commit** — `GET /repos/{owner}/{repo}/commits/{sha}`; a 404/422
  means the SHA is unknown to the claimed repo (fork-only or typo'd). This is a
  pragmatic heuristic — [zizmor's audit](https://docs.zizmor.sh/audits/#impostor-commit)
  is the rigorous reference for exact ref-membership.
- **ref-version-mismatch** — resolves the tag named in the trailing `# vN`
  comment to its SHA and compares with the pinned SHA.

Because the companion reports directly, there is no need to feed results back
into karinto, and karinto-core does not carry these as rules (they are
`NotPlanned` in [`rules_catalog.md`](../rules_catalog.md)).
