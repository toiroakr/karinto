---
"karinto": minor
---

Allow specifying `org/repo/commit[/target]` directly in the request URL path
(e.g. `GET /actions/checkout/<sha>/action.yml`), and require a commit SHA
whenever `repo` mode is used. The new `commit` parameter accepts only the
full 40-character hex SHA — short SHAs are rejected because they are
ambiguous with branch/tag names of the same shape (e.g. `deadbee`), which
`raw.githubusercontent.com` would resolve as a mutable ref and defeat the
pinning. Branch names and tags are likewise rejected so lint results are
always tied to a verifiable revision. Responses in `repo` mode now include
the resolved `commit` alongside `repo` and `targets`.

Path-based targets bypass the comma-delimited `targets=` parsing, so a
literal `,` in a path no longer splits one file into two. Each target path
is also validated to reject `..` / absolute / backslash forms that could
escape the pinned `<commit>` prefix once interpolated into the
`raw.githubusercontent.com` URL.
