---
"karinto": minor
---

Allow specifying `org/repo/commit[/target]` directly in the request URL path
(e.g. `GET /actions/checkout/<sha>/action.yml`), and require a commit SHA
whenever `repo` mode is used. The new `commit` parameter accepts 7–64 hex
characters; branch names and tags are rejected so lint results are always
tied to a verifiable revision. Responses in `repo` mode now include the
resolved `commit` alongside `repo` and `targets`.
