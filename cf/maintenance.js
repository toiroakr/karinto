// karinto-captures Worker — cron-only maintenance for the captures R2 bucket.
//
// R2 lifecycle rules (configured in the dashboard, see DEVELOPMENT.md) handle
// the "delete after N days" case. This Worker is a secondary safety net that
// prunes oldest-first across the listed subset when the bucket grows past a
// soft size limit. R2 returns objects in lexicographic key order (sha256
// hashes, which are not time-correlated), so if listing hits the page cap
// (`truncated=true`) the loop deletes the oldest captures *within that
// subset*, not the bucket's globally-oldest. The 30-day lifecycle rule
// remains the only guarantee on the unlisted tail.
//
// There is intentionally no `fetch` handler: captures are read directly from
// the R2 S3 endpoint by `scripts/replay.mjs`, so this Worker exposes no
// public HTTP surface. `workers_dev: false` in wrangler.maintenance.jsonc
// disables the workers.dev URL as well.
//
// Bindings:
//   - CAPTURES   R2 bucket (same bucket the prod linter writes into)

// Defaults: prune trigger at ~7 GiB (leaves ~3 GiB headroom under the 10 GiB
// free tier for write bursts between 6-hour cron firings), shrink back to
// ~70% (≈ 4.9 GiB). Overridable via the `CAPTURES_SIZE_LIMIT_MIB` and
// `CAPTURES_RECOVERY_RATIO` Worker vars (set in release-publish.sh from
// GitHub repository variables).
const DEFAULT_SIZE_LIMIT_MIB = 7000;
const DEFAULT_RECOVERY_RATIO = 0.7;
// Safety cap on list pages (1000 objects/page) to bound Worker memory and
// CPU even if the bucket somehow holds millions of entries. The R2 lifecycle
// rule (30 days, configured in the dashboard) is the primary retention
// mechanism; this Worker is just a soft cap on top.
const MAX_LIST_PAGES = 200;
// R2's binding takes up to 1000 keys per `delete()` call. Batching shrinks
// tens of thousands of sequential round-trips down to a handful of bulk
// requests so the scheduled invocation finishes well within CPU/wall-time
// limits even on a worst-case shrink from ~7 GiB down to ~4.9 GiB.
const DELETE_BATCH_SIZE = 1000;
// Hard cap on deletes per run so a pathological state can't consume the
// whole CPU budget. The cron fires every 6 hours and pruning is idempotent;
// subsequent firings continue from the new state.
const MAX_DELETES_PER_RUN = 50000;

function positiveNumber(raw, fallback) {
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

function ratio(raw, fallback) {
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 && n < 1 ? n : fallback;
}

export default {
  async scheduled(_event, env) {
    if (!env.CAPTURES) return;
    const sizeLimit =
      positiveNumber(env.CAPTURES_SIZE_LIMIT_MIB, DEFAULT_SIZE_LIMIT_MIB) * 1024 * 1024;
    const recoveryRatio = ratio(env.CAPTURES_RECOVERY_RATIO, DEFAULT_RECOVERY_RATIO);
    const { objects, truncated } = await listCapped(env.CAPTURES, "captures/", MAX_LIST_PAGES);
    const total = objects.reduce((s, o) => s + o.size, 0);

    // Prune only when we have a definite over-limit signal (`total >= sizeLimit`).
    // When the listing is truncated, `total` is only a lower bound on the bucket,
    // so the true size might still be over `sizeLimit` — but pruning on truncation
    // alone could delete captures from a bucket that's actually under the limit
    // (e.g. 200k small objects). The R2 dashboard lifecycle rule (30 days) is the
    // backstop for the unlisted tail; we just log a warning and wait it out.
    if (total < sizeLimit) {
      console.log(
        JSON.stringify({
          event: "maintenance",
          action: truncated ? "skip-truncated" : "skip",
          total,
          count: objects.length,
          listTruncated: truncated,
        }),
      );
      return;
    }

    // total >= sizeLimit: prune. When the listing was truncated, shrink the
    // listed subset by `(1 - recoveryRatio)` so the cron makes guaranteed
    // progress against the listed slice; the lifecycle rule handles the tail.
    const target = truncated ? total * recoveryRatio : sizeLimit * recoveryRatio;

    objects.sort((a, b) => new Date(a.uploaded) - new Date(b.uploaded));
    // First collect the keys we want to delete, then issue them in batches.
    // We stop collecting once `total - freed < target` OR the per-run cap is
    // hit, whichever comes first.
    const toDelete = [];
    let freed = 0;
    let capped = false;
    for (const obj of objects) {
      if (toDelete.length >= MAX_DELETES_PER_RUN) {
        capped = true;
        break;
      }
      toDelete.push(obj.key);
      freed += obj.size;
      if (total - freed < target) break;
    }
    for (let i = 0; i < toDelete.length; i += DELETE_BATCH_SIZE) {
      await env.CAPTURES.delete(toDelete.slice(i, i + DELETE_BATCH_SIZE));
    }

    console.log(
      JSON.stringify({
        event: "maintenance",
        action: "prune",
        total,
        deleted: toDelete.length,
        freed,
        remaining: total - freed,
        listTruncated: truncated,
        deleteCapped: capped,
      }),
    );
  },
};

async function listCapped(bucket, prefix, maxPages) {
  const out = [];
  let cursor;
  for (let page = 0; page < maxPages; page++) {
    const res = await bucket.list({ prefix, cursor });
    out.push(...res.objects);
    if (!res.truncated) return { objects: out, truncated: false };
    cursor = res.cursor;
  }
  // Hit the page cap. R2 returns objects in lexicographic key order (sha256
  // hashes), which is unrelated to upload time, so subsequent cron firings
  // will see the SAME first `maxPages * 1000` objects rather than naturally
  // "continuing" toward older keys. Caller compensates by pruning the listed
  // subset by `(1 - recoveryRatio)` per run; the dashboard R2 lifecycle rule
  // (30 days) remains the primary retention for the unlisted tail.
  return { objects: out, truncated: true };
}
