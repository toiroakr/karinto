Refresh upstream linter pins (auto-generated).

| tool | from | to | release | compare |
| --- | --- | --- | --- | --- |
| zizmor | 1.26.1 | 1.27.0 | [v1.27.0](https://github.com/zizmorcore/zizmor/releases/tag/v1.27.0) | [`v1.26.1...v1.27.0`](https://github.com/zizmorcore/zizmor/compare/v1.26.1...v1.27.0) |

Fixtures under `fixtures/upstream/<tool>/` were re-vendored from the new tag. This PR is opened with `GITHUB_TOKEN`, so `upstream-parity` does **not** run automatically — add the `run-parity` label to trigger it. Its step summary then lists any divergences (`unmapped` / soft) that point at newly-added upstream checks.

## Upstream release notes

<details><summary><b>zizmor</b> v1.27.0</summary>

## New Features 🌈[🔗](https://docs.zizmor.sh/release-notes/#new-feartures)

- zizmor now has experimental support for workflows that specify parallel steps. See [Usage - Parallel steps](https://docs.zizmor.sh/usage/#parallel-steps) for more information ([#2153](https://github.com/zizmorcore/zizmor/issues/2153))
Enhancements 🌱[🔗](https://docs.zizmor.sh/release-notes/#enhancements)

- zizmor's handling of paths is now more consistent, particularly when run on Windows ([#2163](https://github.com/zizmorcore/zizmor/issues/2163))

- zizmor now emits a helpful warning when being run in implicit offline mode ([#2180](https://github.com/zizmorcore/zizmor/issues/2180))

## Bug Fixes 🐛[🔗](https://docs.zizmor.sh/release-notes/#bug-fixes)

- Fixed a bug where the [secrets-outside-env](https://docs.zizmor.sh/audits/#secrets-outside-env) audit would not honor ignore comments within the same job scope ([#2157](https://github.com/zizmorcore/zizmor/issues/2157))

- Fixed a bug where the [ref-version-mismatch](https://docs.zizmor.sh/audits/#ref-version-mismatch) audit would not honor ignore comments within the same steps scope ([#2177](https://github.com/zizmorcore/zizmor/issues/2177))

- Fixed a bug where `--collect=[MODE]` was not correctly handled when auditing remote inputs ([#2185](https://github.com/zizmorcore/zizmor/issues/2185))

</details>

## Incorporation checklist

If the parity step summary surfaces an `unmapped` / soft divergence (an upstream check karinto does not yet cover), follow the incorporation flow in [`DEVELOPMENT.md`](https://github.com/toiroakr/karinto/blob/main/DEVELOPMENT.md#incorporating-a-new-upstream-check):

- [ ] Reviewed the `compare` diff + release notes above for new / changed checks.
- [ ] Added the `run-parity` label and checked the `upstream-parity` step summary for `unmapped` rule IDs / Kinds.
- [ ] For each new check: registered it in `rules_catalog.mbt` (+ mirrored `rules_catalog.md`) with a status, or recorded the intentional divergence in `scripts/upstream-parity/allowlist.json`.
- [ ] `moon test` + local parity pass.
