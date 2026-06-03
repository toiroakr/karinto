---
"karinto": patch
---

Replace deprecated MoonBit standard-library APIs with their current
equivalents to keep the codebase warning-free on recent toolchains:

- `StringView::to_string()` → `to_owned()`
- `String::substring(...)` → slice syntax `s[a:b]` (plus `to_owned()` where an
  owned `String` is required)
- `not(expr)` → `!expr`
- `Map::new()` → `{}`
- `.size()` → `.length()`

This is an internal refactor only; there are no changes to the public
interface (`.mbti` is unchanged) or runtime behaviour.
