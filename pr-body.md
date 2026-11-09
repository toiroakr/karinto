Refresh upstream linter pins (auto-generated).

| tool | from | to | release | compare |
| --- | --- | --- | --- | --- |
| zizmor | 1.31.1 | 1.32.0 | [v1.32.0](https://github.com/zizmorcore/zizmor/releases/tag/v1.32.0) | [`v1.31.1...v1.32.0`](https://github.com/zizmorcore/zizmor/compare/v1.31.1...v1.32.0) |

Fixtures under `fixtures/upstream/<tool>/` were re-vendored from the new tag. This PR is opened with `GITHUB_TOKEN`, so `upstream-parity` does **not** run automatically — add the `run-parity` label to trigger it. Its step summary then lists any divergences (`unmapped` / soft) that point at newly-added upstream checks.

## Upstream release notes

<details><summary><b>zizmor</b> v1.32.0</summary>

[Sponsorship is appreciated!](https://github.com/sponsors/woodruffw/)

## New Features 🌈[🔗](https://docs.zizmor.sh/release-notes/#new-features)

- zizmor now has experimental support for GitHub Actions workflow lockfiles. Please see [the limitations documentation](https://docs.zizmor.sh/usage/#workflow-lockfiles) for more information about the current implementation and its limitations ([#2463](https://github.com/zizmorcore/zizmor/issues/2463))

## Enhancements 🌱[🔗](https://docs.zizmor.sh/release-notes/#enhancements)

- zizmor's input collection is now "root-aware" by default, meaning that invocations like zizmor . will no longer collect inputs unless they would actually be used by GitHub Actions, etc. This should eliminate spurious findings from (e.g.) workflow definitions in vendored directories. See the [input collection](https://docs.zizmor.sh/usage/#input-collection) documentation for more information. ([#2454](https://github.com/zizmorcore/zizmor/issues/2454))

- zizmor's LSP now honors the didChangeWorkspaceFolders event ([#2461](https://github.com/zizmorcore/zizmor/issues/2461))

- zizmor's LSP now audits pre-commit inputs ([#2485](https://github.com/zizmorcore/zizmor/issues/2485))

- zizmor now provides Windows ARM64 wheels on PyPI ([#2424](https://github.com/zizmorcore/zizmor/issues/2424))

    Many thanks to [@ndabas](https://github.com/ndabas) for proposing and implementing this improvement!

## Bug Fixes 🐛[🔗](https://docs.zizmor.sh/release

…(truncated — see release link)

</details>

## Incorporation checklist

If the parity step summary surfaces an `unmapped` / soft divergence (an upstream check karinto does not yet cover), follow the incorporation flow in [`DEVELOPMENT.md`](https://github.com/toiroakr/karinto/blob/main/DEVELOPMENT.md#incorporating-a-new-upstream-check):

- [ ] Reviewed the `compare` diff + release notes above for new / changed checks.
- [ ] Added the `run-parity` label and checked the `upstream-parity` step summary for `unmapped` rule IDs / Kinds.
- [ ] For each new check: registered it in `rules_catalog.mbt` (+ mirrored `rules_catalog.md`) with a status, or recorded the intentional divergence in `scripts/upstream-parity/allowlist.json`.
- [ ] `moon test` + local parity pass.
