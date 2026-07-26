---
"karinto": patch
---

`undocumented-permissions` findings now carry `pos` (pointing at the `permissions:` key) and, when the block is nested under a job, that job's `job` id — so a workflow with several per-job `permissions:` blocks can trace each finding back to its specific block instead of requiring a manual audit of the whole file.
