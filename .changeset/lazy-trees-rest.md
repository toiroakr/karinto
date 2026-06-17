---
"karinto": patch
---

Refactor `check_unknown_context` to reuse the shared `extract_expr_bodies`
and `strip_expr_string_literals` helpers instead of its own inline `${{ }}`
extraction and string-literal skipping. The duplicated expression-scanning
logic is removed and the single-quoted-literal false-positive fix is
preserved. `extract_expr_bodies` now skips single-quoted literals while
locating the terminating `}}`, so a `}}` inside a literal (e.g.
`${{ hashFiles('a}}b') && github.ref }}`) no longer truncates the extracted
body — this preserves the previous `check_unknown_context` behaviour and also
hardens the shared `text_references_regular_context` scan against the same
edge case.
