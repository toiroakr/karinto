---
"karinto": patch
---

Fix false negative in `outdated-action-version` for workflow steps

The rule previously only checked an action file's own `runs.using` field, so
`actions/checkout@v3` (node16, deprecated) referenced from a workflow step was
silently ignored. The rule now also inspects `uses:` in workflow steps and fires
when a well-known action's major version is known to use a deprecated runtime.
