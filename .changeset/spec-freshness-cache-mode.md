---
"karinto": patch
---

Add `cache-mode` to the allowed workflow top-level and job-level keys for the
`unexpected-keys` rule. GitHub added this key for controlling Actions cache
access (read/write/write-only/none) and karinto's hardcoded key tables hadn't
caught up, so `cache-mode:` was flagged as an unknown key.

Also teach `invalid-mapping-values` to validate `cache-mode` (workflow and
job scope) against GitHub's `read`/`write`/`write-only`/`none` enum. Simply
allowing the key wasn't enough on its own: an out-of-enum value like
`cache-mode: typo` would have silently passed with no diagnostic at all.
