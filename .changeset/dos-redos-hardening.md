---
"karinto": patch
---

Harden DoS/ReDoS surface:

- Replace the recursive backtracking glob matcher behind the `disable=`
  parameter with a linear-time two-pointer algorithm, so adversarial
  patterns such as `*a*a*…*b` against long inputs can no longer cause
  exponential CPU usage.
- Cloudflare Worker now enforces a 1 MiB cap on request bodies and on
  files fetched in `repo` mode. Oversized direct payloads short-circuit
  with `413 Payload Too Large` before reaching the parser / rules.
  In `repo` mode the request still returns `200` with the per-file
  error surfaced under `files[].error` so a single oversized file does
  not invalidate results for the rest of the batch.
- `disable=` patterns are limited to one `*` each (more than one returns
  `400`), and capped at 64 patterns × 128 characters per pattern.
- Add a 60 req/min per-IP rate limit via the Workers Rate Limiting
  binding. Traffic from GitHub-hosted Actions runners is exempt
  because runners share egress IPs across unrelated tenants; the
  allow-list is sourced from `api.github.com/meta` and refreshed daily
  by a Cron Trigger into a KV namespace, with the request path reading
  from KV (memoized per isolate) and a one-shot direct-fetch fallback
  for the cold-deploy case. Over-limit requests get `429`.
- Deploy note: this introduces a `KV` namespace and a `triggers.crons`
  entry in `cf/wrangler.jsonc`. Run `npx wrangler kv namespace create
  karinto-meta` (and a staging counterpart) and paste the IDs before
  the next deploy.
- Regression test exercises the previously catastrophic pattern.
