---
"karinto": patch
---

Deeply nested YAML now fails with a `recursion limit exceeded` parse error
instead of crashing the parser with `RangeError: Maximum call stack size
exceeded`. The nesting limit drops from 1000 to 128 levels: the old limit was
never reached because the stack ran out first (block mappings nested about 800
levels deep already overflowed the shipped JS build).
