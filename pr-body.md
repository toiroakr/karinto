Refresh upstream linter pins (auto-generated).

| tool | from | to | release | compare |
| --- | --- | --- | --- | --- |
| zizmor | 1.27.0 | 1.28.0 | [v1.28.0](https://github.com/zizmorcore/zizmor/releases/tag/v1.28.0) | [`v1.27.0...v1.28.0`](https://github.com/zizmorcore/zizmor/compare/v1.27.0...v1.28.0) |

Fixtures under `fixtures/upstream/<tool>/` were re-vendored from the new tag. This PR is opened with `GITHUB_TOKEN`, so `upstream-parity` does **not** run automatically — add the `run-parity` label to trigger it. Its step summary then lists any divergences (`unmapped` / soft) that point at newly-added upstream checks.

## Upstream release notes

<details><summary><b>zizmor</b> v1.28.0</summary>

## Security 🔒[🔗](https://docs.zizmor.sh/release-notes/#security)

- v1.27.0 contained a logging defect that would print any configured GitHub credentials as part of zizmor's cleartext logging. No versions other than v1.27.0 were affected. See [GHSA-f42p-wjw5-97qh](https://github.com/zizmorcore/zizmor/security/advisories/GHSA-f42p-wjw5-97qh) for full information.

    Many thanks to [@shaanmajid](https://github.com/shaanmajid) for finding and reporting this vulnerability.

## Enhancements 🌱[🔗](https://docs.zizmor.sh/release-notes/#enhancements)

- The JSON (v1) output format now includes metadata for each finding's fixes, if the finding has fixes ([#2186](https://github.com/zizmorcore/zizmor/issues/2186))

- The [dependabot-cooldown](https://docs.zizmor.sh/audits/#dependabot-cooldown) audit is now aware of GitHub's new three-day default cooldown ([#2193](https://github.com/zizmorcore/zizmor/issues/2193))

- sbt is now recognized as a package-ecosystem in dependabot.yml ([#2211](https://github.com/zizmorcore/zizmor/issues/2211))

## Bug Fixes 🐛[🔗](https://docs.zizmor.sh/release-notes/#bug-fixes)

- Fixed a bug where the [template-injection](https://docs.zizmor.sh/audits/#template-injection) audit would incorrectly flag `steps.*.outcome` and `steps.*.conclusion` as injection risks in the default persona ([#2199](https://github.com/zizmorcore/zizmor/issues/2199))

- Fixed a bug where the [github-env](https://docs.zizmor.sh/audits/#github-env) audit would i

…(truncated — see release link)

</details>

## Incorporation checklist

If the parity step summary surfaces an `unmapped` / soft divergence (an upstream check karinto does not yet cover), follow the incorporation flow in [`DEVELOPMENT.md`](https://github.com/toiroakr/karinto/blob/main/DEVELOPMENT.md#incorporating-a-new-upstream-check):

- [ ] Reviewed the `compare` diff + release notes above for new / changed checks.
- [ ] Added the `run-parity` label and checked the `upstream-parity` step summary for `unmapped` rule IDs / Kinds.
- [ ] For each new check: registered it in `rules_catalog.mbt` (+ mirrored `rules_catalog.md`) with a status, or recorded the intentional divergence in `scripts/upstream-parity/allowlist.json`.
- [ ] `moon test` + local parity pass.
