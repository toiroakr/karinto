---
"karinto": patch
---

Align `superfluous-actions` and `template-injection` persona gating with real
zizmor, found by validating karinto against zizmor-using OSS workflows:

- `superfluous-actions` now uses a per-action persona map (zizmor gates a subset
  — e.g. `peter-evans/create-pull-request`, `dtolnay/rust-toolchain` — behind
  `--pedantic`; the rest fire at the default persona).
- `template-injection` now flags non-static influenceable contexts (`vars.*`,
  `inputs.*`, `*.outputs.*`, `github.ref*`, `github.actor`, `github.workflow`)
  at the regular persona instead of hiding them on the pedantic backstop.
  `env.*` stays on the backstop because karinto cannot tell a statically-defined
  env var from a dynamic one.
