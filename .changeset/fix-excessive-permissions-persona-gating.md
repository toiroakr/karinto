---
"karinto": patch
---

Fix `excessive-permissions`'s persona gating for the "default permissions used due to no permissions: block" finding to match zizmor's actual conditions instead of a blanket workflow-level-Pedantic / job-level-Regular split. It's now Pedantic only when the workflow has a single job, every job declares its own `permissions:`, or the workflow is reusable-only (`on:` lists only `workflow_call`); otherwise it's Regular. Reusable-workflow caller jobs (`uses:`) stay Regular regardless, since the caller is responsible for permissions. Previously, karinto missed real Regular-persona findings on multi-job workflows and over-reported on reusable-only workflows' normal jobs.
