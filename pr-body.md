Refresh upstream linter pins (auto-generated).

| tool | from | to | release | compare |
| --- | --- | --- | --- | --- |
| ghalint | 1.5.7 | 1.6.0 | [v1.6.0](https://github.com/suzuki-shunsuke/ghalint/releases/tag/v1.6.0) | [`v1.5.7...v1.6.0`](https://github.com/suzuki-shunsuke/ghalint/compare/v1.5.7...v1.6.0) |

Fixtures under `fixtures/upstream/<tool>/` were re-vendored from the new tag. This PR is opened with `GITHUB_TOKEN`, so `upstream-parity` does **not** run automatically — add the `run-parity` label to trigger it. Its step summary then lists any divergences (`unmapped` / soft) that point at newly-added upstream checks.

## Upstream release notes

<details><summary><b>ghalint</b> v1.6.0</summary>

https://github.com/suzuki-shunsuke/ghalint/compare/v1.5.7...v1.6.0

## Features

#1529 #1535 Support GitHub Actions workflow lockfiles

[GitHub Actions workflow lockfiles are generally available](https://github.blog/changelog/2026-10-28-github-actions-workflow-lockfiles-are-generally-available/).

The policy [action_ref_should_be_full_length_commit_sha](https://github.com/suzuki-shunsuke/ghalint/blob/main/docs/policies/008.md) ignores actions in workflows locked by [the workflow dependency lockfile](https://docs.github.com/en/enterprise-cloud@latest/actions/concepts/security/workflow-dependency-lockfiles) `.github/workflows/actions.lock`, because the lockfile locks them to commits.
An action is regarded as locked if its `uses` is listed in both `workflows.<workflow file path>` and `dependencies` of the lockfile.

If the lockfile doesn't exist, the behavior doesn't change.

The following still need to be pinned by full length commit SHA even if the lockfile exists:

- Reusable workflows (`jobs.<job_id>.uses`)
- Docker images (`docker://`)
- Actions in workflows that the lockfile doesn't lock
- Actions in action files (`action.yaml`), because callers of the action don't necessarily use the lockfile

> [!WARNING]
> If ghalint fails to read the lockfile, for instance because the lockfile is invalid or its schema version is newer than ghalint supports, ghalint can't validate versions of actions properly.
> Then ghalint outputs an error and skips action_ref_sh

…(truncated — see release link)

</details>

## Incorporation checklist

If the parity step summary surfaces an `unmapped` / soft divergence (an upstream check karinto does not yet cover), follow the incorporation flow in [`DEVELOPMENT.md`](https://github.com/toiroakr/karinto/blob/main/DEVELOPMENT.md#incorporating-a-new-upstream-check):

- [ ] Reviewed the `compare` diff + release notes above for new / changed checks.
- [ ] Added the `run-parity` label and checked the `upstream-parity` step summary for `unmapped` rule IDs / Kinds.
- [ ] For each new check: registered it in `rules_catalog.mbt` (+ mirrored `rules_catalog.md`) with a status, or recorded the intentional divergence in `scripts/upstream-parity/allowlist.json`.
- [ ] `moon test` + local parity pass.
