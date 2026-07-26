---
"karinto": patch
---

Fix `use-trusted-publishing`'s run-based detection to no longer false-positive on `pkg-pr-new` invoked via `pnpm dlx`/`yarn dlx`/`npm exec` (e.g. `pnpm dlx pkg-pr-new@0.0.78 publish ...`). It publishes throwaway preview builds authenticated via the job's own `GITHUB_TOKEN`, not a long-lived npm registry token.
