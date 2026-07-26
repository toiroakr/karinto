---
"karinto": patch
---

Inline `# karinto: ignore[...]` / `# zizmor: ignore[...]` comments now also work when placed on the line directly above a job-scoped (no owning step) finding's own line — e.g. above a job's key line — in addition to that line itself. This covers job-level findings like `use-trusted-publishing`'s run-based detection, whose `pos` resolves to the job's key line rather than the step that triggered it, so the comment no longer has to sit on that exact line. Step-scoped findings are unaffected and remain strictly same-line. The README's "Ignoring findings" section now documents where the comment must go for findings with no owning step.
