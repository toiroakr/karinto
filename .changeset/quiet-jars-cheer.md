---
"karinto": patch
---

Fix `unknown-context-or-function` false positive on single-quoted string
literals containing dots. The scanner walked expression bodies char by char
without skipping string literals, so a dotted literal like
`hashFiles('replay-summary.md')` or a bare `'a.b'` was misread as
`<head>.<member>` context access and reported the head as an unknown context.
Single-quoted literals are now skipped during the scan, matching the GitHub
Actions expression language.
