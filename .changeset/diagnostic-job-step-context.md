---
"karinto": minor
---

Diagnostics now carry location context. Each finding may include a `job` field
(the offending job's ID) and a `step` field (`{ index, id }`, where `index` is
the 0-based position in the steps list and `id` is the step's `id:` when
declared). Job-scoped and step-scoped rules attach this automatically; the
`duplicate-job-step-ids` and `anonymous-definition` rules also populate it. The
YAML parser drops source layout, so diagnostics still have no line/column
positions — `job`/`step` are the location handles instead.
