---
"karinto": patch
---

Findings that blame one concrete job or step now carry that attribution instead of only mentioning it in their message. Previously several rules identified the exact offender and then discarded it, emitting a diagnostic with no `job`, `step`, or `pos` — so in a multi-job workflow you couldn't tell which one tripped, and an inline `# karinto: ignore[...]` on the offending line had no effect (it had nowhere to match against).

Fixed across: `cache-poisoning` (the cache-restoring step), `excessive-permissions` (the per-job "default permissions used" finding, which was the only arm of its own `match` still unattributed), `bot-conditions` (the job's or step's `if:`), `insecure-commands` (the job's or step's `env:`), `invalid-env-var-name` (down to the offending `env:` entry), `overprovisioned-secrets` (the job's or step's `env:`), `job-needs-graph` (the job's `needs:`), `context-availability` (the job's `env:`/`if:`), and `unsound-condition` (the job's or step's `if:`). Workflow-level findings that are genuinely about the document — or about something's *absence*, like `concurrency-limits` — correctly stay unpositioned and keep their file-wide inline-ignore fallback.

Rule ids, severities, and message text are unchanged; only the location metadata is newly populated.
