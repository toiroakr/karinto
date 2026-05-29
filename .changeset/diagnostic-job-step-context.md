---
"karinto": minor
---

Diagnostics now carry location context. Each finding may include a `job` field
(the offending job's ID) and a `step` field (`{ index, id }`, where `index` is
the 0-based position in the steps list and `id` is the step's `id:` when
declared). Job-scoped and step-scoped rules attach this automatically. Rules
that walk jobs/steps themselves also populate it: `duplicate-job-step-ids`,
`anonymous-definition`, and `job-step-id-naming`. Step-specific findings raised
from job-scoped rules (`artipacked`, `superfluous-actions`, `shell-name-per-os`)
now carry the offending step too, not just the job. The YAML parser drops source
layout, so diagnostics still have no line/column positions — `job`/`step` are
the location handles instead.
