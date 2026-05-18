# Changesets

Karinto uses [changesets](https://github.com/changesets/changesets) to manage
releases. Each pull request that ships a user-visible change must include a
changeset; CI fails otherwise.

## Add a changeset

```sh
npx changeset
```

The CLI prompts for the bump type and a summary. It writes a Markdown file
into this directory. Commit it with your other changes.

Bump types follow semver:

- `patch` — bug fixes, internal refactors, doc-only changes that still ship
- `minor` — new lint rules, new API parameters, new endpoints
- `major` — breaking API changes (response shape, removed parameters, etc.)

## Skip when there's nothing to release

If a PR truly has no user-visible impact (CI infra, internal scripts), add
the `skip-changeset` label on the GitHub UI. The CI check honours the
label and lets the PR through without a changeset entry.

## Releasing (maintainers)

1. Merge PRs into `main`. Each merge automatically deploys to the staging
   Worker at `https://karinto-staging.toiroakr.workers.dev`.
2. When ready to cut a release, run the `release` workflow from the GitHub
   Actions tab (workflow_dispatch). It:
   - consumes the accumulated changesets
   - bumps `package.json` and `moon.mod.json` versions
   - writes the new CHANGELOG section
   - commits, tags `vX.Y.Z`, pushes
   - deploys to the production Worker (`https://karinto.toiroakr.workers.dev`)
   - publishes a GitHub Release with the new CHANGELOG entry as its body
