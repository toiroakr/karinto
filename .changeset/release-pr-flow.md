---
"karinto": patch
---

Switch the release workflow to a Release PR flow driven by `changesets/action`.
Pending changesets now accumulate into a "chore: release" PR that bumps
`package.json` + `moon.mod.json`, rewrites `CHANGELOG.md`, and — when merged —
runs `scripts/release-publish.sh` to deploy the production Worker and create
the GitHub Release. No more manual `workflow_dispatch`.
