#!/usr/bin/env bash
# Runs as the `publish` step of changesets/action — fires only when main has
# no pending changesets (i.e. immediately after the "Version Packages" PR
# was merged). Builds, deploys to the production Worker, smoke-checks, then
# creates git tags so changesets/action can publish the GitHub Release.
set -euo pipefail

moon update
moon test
moon build --target js --release

pushd cf >/dev/null
npm ci
npx wrangler deploy
bash smoke.sh
popd >/dev/null

# Emits "New tag: <pkg>@<version>" — parsed by changesets/action so it knows
# what GitHub Release to create.
npx changeset tag
