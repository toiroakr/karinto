---
"karinto": minor
---

Add three `error` rules for `dependabot.yml`, derived from the required fields
of the official Dependabot v2 JSON schema:

- `dependabot-version` — top-level `version:` must be present and equal `2`.
- `dependabot-update-fields` — every `updates:` entry must declare
  `package-ecosystem`, a `schedule` with an `interval` (optional for entries in
  a `multi-ecosystem-group`), and exactly one of `directory` / `directories`.
- `dependabot-duplicate-directories` — a directory may appear only once across
  update entries that share the same `package-ecosystem` and `target-branch`.
