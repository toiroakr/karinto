Refresh upstream linter pins (auto-generated).

| tool | from | to | release | compare |
| --- | --- | --- | --- | --- |
| zizmor | 1.30.0 | 1.30.1 | [v1.30.1](https://github.com/zizmorcore/zizmor/releases/tag/v1.30.1) | [`v1.30.0...v1.30.1`](https://github.com/zizmorcore/zizmor/compare/v1.30.0...v1.30.1) |

Fixtures under `fixtures/upstream/<tool>/` were re-vendored from the new tag. This PR is opened with `GITHUB_TOKEN`, so `upstream-parity` does **not** run automatically — add the `run-parity` label to trigger it. Its step summary then lists any divergences (`unmapped` / soft) that point at newly-added upstream checks.

## Upstream release notes

<details><summary><b>zizmor</b> v1.30.1</summary>

[Sponsorship is appreciated!](https://github.com/sponsors/woodruffw/)

## Bug Fixes 🐛[🔗](https://docs.zizmor.sh/release-notes/#bug-fixes)

- Fixed a bug where zizmor would crash on pre-commit inputs that reference a GitHub URL with an explicit .git suffix ([#2363](https://github.com/zizmorcore/zizmor/issues/2363))

- Fixed a bug where [self-repository](https://docs.zizmor.sh/audits/#self-repository) auto-fixes were incorrectly marked as "safe" instead of "unsafe" ([#2373](https://github.com/zizmorcore/zizmor/issues/2373))

</details>

## Incorporation checklist

If the parity step summary surfaces an `unmapped` / soft divergence (an upstream check karinto does not yet cover), follow the incorporation flow in [`DEVELOPMENT.md`](https://github.com/toiroakr/karinto/blob/main/DEVELOPMENT.md#incorporating-a-new-upstream-check):

- [ ] Reviewed the `compare` diff + release notes above for new / changed checks.
- [ ] Added the `run-parity` label and checked the `upstream-parity` step summary for `unmapped` rule IDs / Kinds.
- [ ] For each new check: registered it in `rules_catalog.mbt` (+ mirrored `rules_catalog.md`) with a status, or recorded the intentional divergence in `scripts/upstream-parity/allowlist.json`.
- [ ] `moon test` + local parity pass.
