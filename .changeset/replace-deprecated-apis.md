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

Also migrate the module manifest from the deprecated `moon.mod.json` to the
current `moon.mod` format (required by recent toolchains) and update the
release version-sync script and docs accordingly.

This is an internal refactor only; there are no changes to the public
interface (`.mbti` is unchanged) or runtime behaviour.
