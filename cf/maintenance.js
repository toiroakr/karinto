// karinto-captures Worker — cron-only maintenance for the captures R2 bucket.
//
// R2 lifecycle rules (configured in the dashboard, see DEVELOPMENT.md) handle
// the "delete after N days" case. This Worker is a secondary safety net that
// prunes oldest-first when the bucket grows past a soft size limit.
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

export default {
  async scheduled(_event, env) {
    if (!env.CAPTURES) return;
    const sizeLimit = Number(env.CAPTURES_SIZE_LIMIT_MIB ?? DEFAULT_SIZE_LIMIT_MIB) * 1024 * 1024;
    const recoveryRatio = Number(env.CAPTURES_RECOVERY_RATIO ?? DEFAULT_RECOVERY_RATIO);
    const objects = await listAll(env.CAPTURES, "captures/");
    const total = objects.reduce((s, o) => s + o.size, 0);

    if (total < sizeLimit) {
      console.log(
        JSON.stringify({
          event: "maintenance",
          action: "skip",
          total,
          count: objects.length,
        }),
      );
      return;
    }

    objects.sort((a, b) => new Date(a.uploaded) - new Date(b.uploaded));
    let freed = 0;
    let deleted = 0;
    for (const obj of objects) {
      await env.CAPTURES.delete(obj.key);
      freed += obj.size;
      deleted++;
      if (total - freed < sizeLimit * recoveryRatio) break;
    }

    console.log(
      JSON.stringify({
        event: "maintenance",
        action: "prune",
        total,
        deleted,
        freed,
        remaining: total - freed,
      }),
    );
  },
};

async function listAll(bucket, prefix) {
  const out = [];
  let cursor;
  do {
    const page = await bucket.list({ prefix, cursor });
    out.push(...page.objects);
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return out;
}
