---
"karinto": patch
---

Harden DoS/ReDoS surface:

- Replace the recursive backtracking glob matcher behind the `disable=`
  parameter with a two-pointer "last-star backtrack" algorithm, so
  adversarial patterns such as `*a*a*…*b` against long inputs can no
  longer cause exponential CPU usage. (The matcher is not strictly
  linear — worst case is `O(m·n)` — but the `disable=` caps below keep
  the bound small enough that DoS via this path is not feasible.)
- Cloudflare Worker now enforces a 1 MiB cap on request bodies and on
  files fetched in `repo` mode. Oversized direct payloads short-circuit
  with `413 Payload Too Large` before reaching the parser / rules.
  In `repo` mode the request still returns `200` with the per-file
  error surfaced under `files[].error` so a single oversized file does
  not invalidate results for the rest of the batch.
- `disable=` patterns are limited to one `*` each (more than one returns
  `400`), and capped at 64 patterns × 128 characters per pattern.
- `targets=` (in `repo` mode) is capped at 50 paths. Requests over the
  cap are rejected with `400` rather than silently truncated, so clients
  don't get an `ok:true` response that quietly skipped files.
- Add a 60 req/min per-IP rate limit via the Workers Rate Limiting
  binding. Traffic from GitHub-hosted Actions runners is exempt
  because runners share egress IPs across unrelated tenants; the
  allow-list is sourced from `api.github.com/meta` and refreshed daily
  by a Cron Trigger into a KV namespace, with the request path reading
  from KV (memoized per isolate) and a one-shot direct-fetch fallback
  for the cold-deploy case. Over-limit requests get `429`.
- Deploy note: this introduces a `KV` namespace and a `triggers.crons`
  entry in `cf/wrangler.jsonc`. Run `npx wrangler kv namespace create
  karinto-meta` once and paste the returned id into both the top-level
  and `env.staging` `kv_namespaces` blocks — production and staging
  share the namespace because the `/meta` payload is GitHub-published
  and identical across envs.
- Regression test exercises the previously catastrophic pattern.
