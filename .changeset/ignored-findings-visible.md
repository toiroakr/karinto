---
"karinto": patch
---

Surface suppressed findings in `LintResult.ignored`

`LintResult` gains an `ignored` field (type `Array[Diagnostic]`) that collects every finding suppressed by any mechanism: inline `# karinto: ignore[…]` / `# zizmor: ignore[…]` comments, ghalint config excludes, zizmor config `disable`/`ignore`, and the persona gate. The field is omitted from JSON when empty, so existing callers are unaffected.
