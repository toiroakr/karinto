Refresh upstream linter pins (auto-generated).

| tool | from | to | release | compare |
| --- | --- | --- | --- | --- |
| zizmor | 1.28.0 | 1.29.0 | [v1.29.0](https://github.com/zizmorcore/zizmor/releases/tag/v1.29.0) | [`v1.28.0...v1.29.0`](https://github.com/zizmorcore/zizmor/compare/v1.28.0...v1.29.0) |

Fixtures under `fixtures/upstream/<tool>/` were re-vendored from the new tag. This PR is opened with `GITHUB_TOKEN`, so `upstream-parity` does **not** run automatically — add the `run-parity` label to trigger it. Its step summary then lists any divergences (`unmapped` / soft) that point at newly-added upstream checks.

## Upstream release notes

<details><summary><b>zizmor</b> v1.29.0</summary>

## New Features 🌈[🔗](https://docs.zizmor.sh/release-notes/#new-features)

- zizmor now has **experimental** support for auditing pre-commit inputs, meaning both pre-commit configuration and hook definitions ([#2209](https://github.com/zizmorcore/zizmor/issues/2209))

- New audit: [insecure-url-scheme](https://docs.zizmor.sh/audits/#insecure-url-scheme) detects usages of insecure (i.e. plaintext) protocols when making network requests. The initial version of this audit is limited to pre-commit inputs only ([#2228](https://github.com/zizmorcore/zizmor/issues/2228))

- zizmor now supports GitHub's "self-repository" reference syntax for local actions, e.g. `uses: $/foo/bar` instead of a manual checkout and `uses: ./foo/bar` ([#2248](https://github.com/zizmorcore/zizmor/issues/2248))

## Changes ⚠️[🔗](https://docs.zizmor.sh/release-notes/#changes)

- The [unpinned-uses](https://docs.zizmor.sh/audits/#unpinned-uses) and [unpinned-images](https://docs.zizmor.sh/audits/#unpinned-images) audits have been separated more cleanly: [unpinned-uses](https://docs.zizmor.sh/audits/#unpinned-uses) is now principally responsible for Git-style `uses:` clauses, whereas [unpinned-images](https://docs.zizmor.sh/audits/#unpinned-images) is now responsible for `docker://`-style `uses:` clauses (in addition to already checking other image references) ([#2222](https://github.com/zizmorcore/zizmor/issues/2222))

## Removals 🌅[🔗](https://docs.zizmor.sh/release-notes/#removals)

- `--co

…(truncated — see release link)

</details>

## Incorporation checklist

If the parity step summary surfaces an `unmapped` / soft divergence (an upstream check karinto does not yet cover), follow the incorporation flow in [`DEVELOPMENT.md`](https://github.com/toiroakr/karinto/blob/main/DEVELOPMENT.md#incorporating-a-new-upstream-check):

- [ ] Reviewed the `compare` diff + release notes above for new / changed checks.
- [ ] Added the `run-parity` label and checked the `upstream-parity` step summary for `unmapped` rule IDs / Kinds.
- [ ] For each new check: registered it in `rules_catalog.mbt` (+ mirrored `rules_catalog.md`) with a status, or recorded the intentional divergence in `scripts/upstream-parity/allowlist.json`.
- [ ] `moon test` + local parity pass.
