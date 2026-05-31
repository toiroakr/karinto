# Action-side context

A few karinto rules need information that is **not in the YAML being linted** —
it lives in the live state of the actions a workflow references. There are two
distinct ways karinto handles this, depending on how cacheable the fact is.

## 1. Facts karinto resolves for you (server-side)

| Rule | How | Notes |
| --- | --- | --- |
| [`known-vulnerable-actions`](../rules_catalog.md) | `osv=1` query param | The Worker queries OSV.dev and applies the advisory version ranges. |
| [`archived-uses`](../rules_catalog.md) | automatic | The Worker merges a KV-published baseline of archived `owner/repo` (the request path enqueues seen `uses:` repos into a D1 worklist; a daily CI job confirms each via the GitHub API and writes KV) with the engine's hardcoded baseline. No token needed by the caller. |

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

The central baseline grows on its own: every lint request enqueues the
external `uses:` repos it references into a D1 worklist, and a daily CI job
(`refresh-archived.yml`) confirms each against the GitHub API and publishes the
archived ones to KV. It re-verifies the known set each run too, so a repo that
gets un-archived is dropped automatically. There is no committed seed list to
maintain.

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

- **impostor-commit** — whether the pinned SHA is **reachable from one of
  `owner/repo`'s own branches or tags** (a `GET /commits/{sha}` 200 is *not*
  sufficient: GitHub serves fork-network commits, so a fork-only impostor
  returns 200). It uses GitHub's `branch_commits` data (the web UI's
  "containing branches/tags") for public repos, falling back to walking every
  ref via the compare API for private repos. Reachable from none ⇒ impostor.
  Mirrors [zizmor's audit](https://docs.zizmor.sh/audits/#impostor-commit).
- **ref-version-mismatch** — resolves the tag named in the trailing `# vN`
  comment to its SHA and compares with the pinned SHA.

**Token / private actions.** The default `GITHUB_TOKEN` (passed automatically
as the `github-token` input) can only read the workflow's own repo, and the
`branch_commits` fast path is public-only. To audit a `uses:` that points at a
**private** action in another repo, pass a token with read access to that repo
via the `github-token` input (a PAT with `repo` / fine-grained Contents:read,
or a GitHub App token). Without it the action can't verify the private repo and
emits a non-failing "could not verify — no access" warning instead of a false
finding. Public actions need no extra token.

Because the companion reports directly, there is no need to feed results back
into karinto, and karinto-core does not carry these as rules (they are
`NotPlanned` in [`rules_catalog.md`](../rules_catalog.md)).
