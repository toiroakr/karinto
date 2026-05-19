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

# `--env production` attaches the CAPTURES R2 binding; top-level deploys
# (used by PR previews) deliberately have no binding so they can't write.
npx wrangler deploy --env production "${PROD_VAR_FLAGS[@]}"
npx wrangler deploy --config wrangler.maintenance.jsonc "${MAINT_VAR_FLAGS[@]}"
bash smoke.sh
popd >/dev/null

# Emits "New tag: <pkg>@<version>" — parsed by changesets/action so it knows
# what GitHub Release to create.
npx changeset tag
