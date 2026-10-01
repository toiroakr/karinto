---
"karinto": patch
---

Stop `shell-undefined-var` from flagging positional parameters (`$0`, `$1`,
`${2#x}`, `${10}`, …). tree-sitter-bash parses these as an ordinary
`variable_name` whose text is all digits, so a shell function reading its own
arguments (`f() { echo "$1"; }`) was reported as having "no declared `env:`
source" — a source no `env:` key could ever provide.
