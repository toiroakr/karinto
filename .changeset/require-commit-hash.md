---
"karinto": minor
---

Allow specifying `org/repo/commit[/target/path/...]` directly in the request
URL path (e.g. `GET /actions/checkout/<sha>/action.yml`, or with nested
targets like `.github/workflows/ci.yml`), and require a commit SHA whenever
`repo` mode is used. The `commit` parameter accepts 7–64 hex characters,
so non-hex branch/tag names (e.g. `main`, `v1.2.3`) are rejected outright.
Hex-shaped refs are still accepted at face value, so an all-hex branch or
tag (e.g. `deadbee`) can collide with a short-SHA-shaped commit; callers
needing guaranteed immutability should pass the full 40-char SHA. Path
segments that don't match the repo-mode shape are ignored, so the Worker
can be served under arbitrary path prefixes (`/api/...`, `/favicon.ico`,
etc.) without bricking unrelated requests. Responses in `repo` mode now
include the resolved `commit` alongside `repo` and `targets`.

Path-based targets bypass the comma-delimited `targets=` parsing, so a
literal `,` in a path no longer splits one file into two. Each target path
is also validated to reject `..`, absolute, backslash, and percent-encoded
forms that could escape the pinned `<commit>` prefix once interpolated
into the `raw.githubusercontent.com` URL.
