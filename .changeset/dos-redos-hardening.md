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
- Regression test exercises the previously catastrophic pattern.
