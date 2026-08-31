Refresh upstream linter pins (auto-generated).

| tool | from | to | release | compare |
| --- | --- | --- | --- | --- |
| zizmor | 1.29.0 | 1.30.0 | [v1.30.0](https://github.com/zizmorcore/zizmor/releases/tag/v1.30.0) | [`v1.29.0...v1.30.0`](https://github.com/zizmorcore/zizmor/compare/v1.29.0...v1.30.0) |

Fixtures under `fixtures/upstream/<tool>/` were re-vendored from the new tag. This PR is opened with `GITHUB_TOKEN`, so `upstream-parity` does **not** run automatically — add the `run-parity` label to trigger it. Its step summary then lists any divergences (`unmapped` / soft) that point at newly-added upstream checks.

## Upstream release notes

<details><summary><b>zizmor</b> v1.30.0</summary>

[Sponsorship is appreciated!](https://github.com/sponsors/woodruffw/)

## New Features 🌈[🔗](https://docs.zizmor.sh/release-notes/#new-features)

- New audit: [self-repository](https://docs.zizmor.sh/audits/#self-repository) detects usages of the old "workspace-relative" form for local reusable workflows and actions and recommends the new "self-repository" form instead ([#2271](https://github.com/zizmorcore/zizmor/issues/2271))
Enhancements 🌱[🔗](https://docs.zizmor.sh/release-notes/#enhancements)

- The [impostor-commit](https://docs.zizmor.sh/audits/#impostor-commit) audit now supports pre-commit config inputs ([#2256](https://github.com/zizmorcore/zizmor/issues/2256))

- The [forbidden-uses](https://docs.zizmor.sh/audits/#forbidden-uses) audit now supports pre-commit config inputs ([#2263](https://github.com/zizmorcore/zizmor/issues/2263))

- The [adhoc-packages](https://docs.zizmor.sh/audits/#adhoc-packages) audit now detects more ad-hoc package management patterns, including bundle add and yarn add

    Many thanks to [@connorshea](https://github.com/connorshea) for proposing and implementing this enhancement!

- The [archived-uses](https://docs.zizmor.sh/audits/#archived-uses) audit now supports pre-commit config inputs ([#2272](https://github.com/zizmorcore/zizmor/issues/2272))

- The [ref-confusion](https://docs.zizmor.sh/audits/#ref-confusion) audit now supports pre-commit config inputs ([#2274](https://github.com/zizmorcore/zizmor/issues/2274))

…(truncated — see release link)

</details>

## Incorporation checklist

If the parity step summary surfaces an `unmapped` / soft divergence (an upstream check karinto does not yet cover), follow the incorporation flow in [`DEVELOPMENT.md`](https://github.com/toiroakr/karinto/blob/main/DEVELOPMENT.md#incorporating-a-new-upstream-check):

- [ ] Reviewed the `compare` diff + release notes above for new / changed checks.
- [ ] Added the `run-parity` label and checked the `upstream-parity` step summary for `unmapped` rule IDs / Kinds.
- [ ] For each new check: registered it in `rules_catalog.mbt` (+ mirrored `rules_catalog.md`) with a status, or recorded the intentional divergence in `scripts/upstream-parity/allowlist.json`.
- [ ] `moon test` + local parity pass.
