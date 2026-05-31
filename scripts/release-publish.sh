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

# Dark-launch tuning knobs. CI plumbs these from repo-level GitHub variables
# (`vars.*`); unset → empty → the Workers fall back to their hardcoded
# defaults (100 KiB / 7000 MiB / 0.7). The `--var` flag overlays these onto
# the wrangler.jsonc `vars` section at deploy time.
PROD_VAR_FLAGS=()
if [ -n "${CAPTURE_CONTENT_LIMIT_KIB:-}" ]; then
  PROD_VAR_FLAGS+=(--var "CAPTURE_CONTENT_LIMIT_KIB:${CAPTURE_CONTENT_LIMIT_KIB}")
fi

MAINT_VAR_FLAGS=()
if [ -n "${CAPTURES_SIZE_LIMIT_MIB:-}" ]; then
  MAINT_VAR_FLAGS+=(--var "CAPTURES_SIZE_LIMIT_MIB:${CAPTURES_SIZE_LIMIT_MIB}")
fi
if [ -n "${CAPTURES_RECOVERY_RATIO:-}" ]; then
  MAINT_VAR_FLAGS+=(--var "CAPTURES_RECOVERY_RATIO:${CAPTURES_RECOVERY_RATIO}")
fi

# Render the deploy-time config with the D1 database_id injected from the
# `D1_DATABASE_ID` repo variable (the tracked wrangler.jsonc keeps the
# placeholder so no account id is committed). Both the prod and the pinned
# snapshot deploy below use it; the maintenance Worker has no D1 binding so it
# keeps using wrangler.maintenance.jsonc. If D1_DATABASE_ID is unset (e.g. a
# fork that hasn't provisioned D1) the script drops the binding and the Worker
# no-ops its archived sweep.
node ../scripts/prepare-wrangler-d1.mjs

# `--env production` attaches the CAPTURES R2 binding; top-level deploys
# (used by PR previews) deliberately have no binding so they can't write.
npx wrangler deploy --config wrangler.deploy.jsonc --env production "${PROD_VAR_FLAGS[@]}"
npx wrangler deploy --config wrangler.maintenance.jsonc "${MAINT_VAR_FLAGS[@]}"
bash smoke.sh

# Version-pinned snapshot Worker. CI users who can't tolerate the
# always-latest endpoint shifting under them (a new rule landing without
# any change on their side) curl `karinto-vX-Y-Z.toiroakr.workers.dev`
# instead, which is frozen to this release's bundle. Deployed against the
# top-level config (like PR previews) so it has no CAPTURES binding and no
# cron — it reads the shared KV but never writes captures or refreshes the
# meta cache. workers.dev names can't contain dots, so `.` → `-`.
VERSION=$(node -p "require('../package.json').version")
PINNED_NAME="karinto-v${VERSION//./-}"
PINNED_URL="https://${PINNED_NAME}.toiroakr.workers.dev"
npx wrangler deploy --config wrangler.deploy.jsonc --env="" --name "$PINNED_NAME"
bash smoke.sh "$PINNED_URL"

# Refresh the `karinto-vMAJOR` alias to this release if it's the new top in
# its major, then prune stale `karinto-vX-Y-Z` snapshots per the retention
# policy (see scripts/manage-pinned-workers.mjs and the README "Versioning
# & pinning" section). Alias failures fail the release; prune failures
# only warn (stale snapshots retry next release).
RELEASE_VERSION="$VERSION" \
PINNED_KEEP_RECENT="${PINNED_KEEP_RECENT:-}" \
  node ../scripts/manage-pinned-workers.mjs
popd >/dev/null

# Emits "New tag: <pkg>@<version>" — parsed by changesets/action so it knows
# what GitHub Release to create.
npx changeset tag

# Push a dashed tag (`v0-3-2` pointing at the same commit as `v0.3.2`) so
# Renovate users extending `github>toiroakr/karinto:pin` can match the
# dashed URL pin (`karinto-v0-3-2.toiroakr.workers.dev`) against
# `github-tags`. The dotted tag stays canonical (gets the GitHub Release);
# the dashed one is a lightweight pointer used only by tooling.
DASHED_TAG="v${VERSION//./-}"
git tag "$DASHED_TAG" "v$VERSION"
git push origin "$DASHED_TAG"
