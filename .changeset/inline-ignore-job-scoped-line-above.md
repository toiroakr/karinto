---
"karinto": patch
---

Inline `# karinto: ignore[...]` / `# zizmor: ignore[...]` comments now also work when placed on the line directly above a finding's own line, in addition to that line itself, for findings with no owning step (workflow- or job-level ones, e.g. `undocumented-permissions`, whose `pos` resolves to the `permissions:` field's own line rather than any step). Step-scoped findings are unaffected and remain strictly same-line. The README's "Ignoring findings" section now documents where the comment must go for findings with no owning step.
