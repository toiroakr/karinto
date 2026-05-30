# Action-side context

A handful of karinto rules can only reach a verdict with information that is
**not in the YAML being linted** — it lives in the live state of the actions a
workflow references (is the repo archived? does the pinned SHA actually belong
to that repo? does the SHA match the `# vN` comment next to it?). The Worker
deliberately does **not** fetch this itself: resolving it means authenticated,
rate-limited GitHub API calls that belong on the caller's side (a CI action
runner that already has a `GITHUB_TOKEN`). The caller resolves the facts and
passes them to karinto as request parameters.

This page documents what each rule needs and how to produce it.

## The contract

| Rule | Request parameter | Value format | Resolve from |
| --- | --- | --- | --- |
| [`known-vulnerable-actions`](../rules_catalog.md) | `osv=1` | flag — karinto queries OSV.dev for you | OSV.dev (done by the Worker) |
| [`forbidden-uses`](../rules_catalog.md) | `forbidden` | comma-separated globs (e.g. `evil/*,foo/bar@*`) | your own policy — no API needed |
| [`archived-uses`](../rules_catalog.md) | `archived` | comma-separated `owner/repo` | GitHub `GET /repos/{owner}/{repo}` → `archived: true` |
| [`impostor-commit`](../rules_catalog.md) | `impostor` | comma-separated `owner/repo@sha` | GitHub commit/branch/tag membership of the SHA |
| [`ref-version-mismatch`](../rules_catalog.md) | `ref_mismatches` | comma-separated `owner/repo@sha` | GitHub tag → SHA resolution vs. the `# vN` comment |

Rules of thumb:

- **Pass only the positives.** Each list contains the refs you have *confirmed*
  hit the condition (archived / impostor / mismatched). karinto fires on
  exactly those entries; it does not re-check them. An empty or omitted value
  leaves the rule on its offline baseline (`archived-uses` still fires on its
  hardcoded `actions/setup-ruby` entry; the others stay silent, matching
  zizmor's `--no-online-audits`).
- **Limits.** At most 200 entries of 256 characters per parameter; over-limit
  requests get `400`.
- **`uses:` shape.** `archived` matching is case-insensitive on the bare
  `owner/repo` (any `/subpath` and `@ref` are ignored). `impostor` /
  `ref_mismatches` match on `owner/repo@sha`.

## Producing each list

The high-level recipe on the action side:

1. Extract every external `uses:` ref from the target workflow / `action.yml`
   (skip `./local` and `docker://` forms).
2. For each ref, query the GitHub API for the fact the rule needs.
3. Collect the refs that hit the condition into a comma-separated string.
4. POST the YAML to karinto with those strings as the matching parameters.

### `archived`

For each unique `owner/repo`, call `GET /repos/{owner}/{repo}` and keep the
ones whose response has `"archived": true`.

```sh
gh api "repos/$owner/$repo" --jq '.archived'   # → true | false
```

### `impostor`

For a ref pinned as `owner/repo@<sha>`, confirm the SHA is reachable from a
branch or tag of `owner/repo`. If GitHub does **not** list the SHA as belonging
to the claimed repo (e.g. it only exists in a fork), it is an impostor — add
`owner/repo@<sha>` to the list. zizmor's impostor-commit audit describes the
exact membership check.

### `ref_mismatches`

For a ref pinned as `owner/repo@<sha> # vN`, resolve the tag `vN` of
`owner/repo` to its SHA. If it differs from the pinned `<sha>`, the comment lies
about the version — add `owner/repo@<sha>` to the list.

## Example request

Once the action runner has resolved the lists, the call is a normal POST:

```sh
curl -G https://karinto.toiroakr.workers.dev \
     --data-urlencode "content=$(cat .github/workflows/ci.yml)" \
     --data "type=workflow" \
     --data "osv=1" \
     --data "forbidden=evil/*" \
     --data "archived=actions/setup-ruby" \
     --data "impostor=foo/bar@deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
     --data "ref_mismatches=baz/qux@0123456789abcdef0123456789abcdef01234567"
```

Embedders calling the JS bundle directly pass the same values positionally to
[`lint_string`](../worker/worker.mbt) (`content, type, disable, vuln,
forbidden, archived, impostor, ref_mismatches`).
