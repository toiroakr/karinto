---
"karinto": patch
---

Fix `github-app-limit-repositories` to no longer flag a GitHub App token request that omits both `owner:` and `repositories:`. Per ghalint's own `ghl-009` doc, omitting both scopes the token to the current repository, which is compliant — the finding now only fires when `owner:` is set without `repositories:` (token spans the whole installation).
