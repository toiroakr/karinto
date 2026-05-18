---
"karinto": patch
---

Harden DoS/ReDoS surface:

- Replace the recursive backtracking glob matcher behind the `disable=`
  parameter with a linear-time two-pointer algorithm, so adversarial
  patterns such as `*a*a*…*b` against long inputs can no longer cause
  exponential CPU usage.
- Cloudflare Worker now enforces a 1 MiB cap on request bodies and on
  files fetched in `repo` mode. Oversized payloads short-circuit with
  `413 Payload Too Large` before reaching the parser / rules.
- `disable=` patterns are limited to one `*` each (more than one returns
  `400`), and capped at 64 patterns × 128 characters per pattern.
- Add a two-tier rate limit via the Workers Rate Limiting binding:
  a 3000 req/min global ceiling for every request, plus a 60 req/min
  per-IP cap for non-GitHub-Actions traffic. The GitHub Actions
  allow-list is sourced from `api.github.com/meta` and refreshed daily
  by a Cron Trigger into a KV namespace; the request path reads from KV
  (memoized per isolate) with a one-shot direct-fetch fallback for the
  cold-deploy case. Over-limit requests get `429`.
- Deploy note: this introduces a `KV` namespace and a `triggers.crons`
  entry in `cf/wrangler.jsonc`. Run `npx wrangler kv namespace create
  karinto-meta` (and a staging counterpart) and paste the IDs before
  the next deploy.
- Regression test exercises the previously catastrophic pattern.
