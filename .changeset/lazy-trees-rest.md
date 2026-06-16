---
"karinto": patch
---

Refactor `check_unknown_context` to reuse the shared `extract_expr_bodies`
and `strip_expr_string_literals` helpers instead of its own inline `${{ }}`
extraction and string-literal skipping. No behavioural change; the
single-quoted-literal false-positive fix is preserved and the duplicated
expression-scanning logic is removed.
