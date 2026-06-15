---
"karinto": patch
---

Fix four false positives in workflow linting:

- `invalid-mapping-values`: accept the string form of `concurrency` (valid
  GitHub Actions), not only the mapping form.
- `unknown-context-or-function`: scan identifiers with hyphen support so a
  `needs.<hyphenated-job-id>` reference is no longer split (the trailing
  segment was misread as an unknown context).
- `github-app-limit-permissions`: recognize the granular `permission-*` inputs
  of `create-github-app-token`, matching the zizmor `github-app` rule.
- `unknown-runner-label`: add `ubuntu-slim` to the known GitHub-hosted runner
  labels.
