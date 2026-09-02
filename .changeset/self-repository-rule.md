---
"karinto": minor
---

Fix the `upstream-parity` check's rule-catalog mapping (it silently matched zero entries — see below) and close out every real divergence it then revealed against zizmor 1.30.0 / actionlint 1.7.12.

**New rules** (zizmor parity):
- **`self-repository`**: flags a `uses:` value that starts with `./` — both a step-level local-action reference and a job-level reusable-workflow call — recommending GitHub's dedicated `$/...` self-repository syntax instead. `../`-prefixed paths are not covered, matching upstream zizmor.
- **`typosquat-uses`**: flags a `uses:` `owner/repo` whose repo name matches a bundled popular-action entry (`actions/*`, `docker/*`) exactly but whose owner is a one-character-omission/repetition/transposition/typo away from the real owner.
- **`unsound-ternary`**: flags a `${{ cond && true_value || fallback }}` pseudo-ternary whose `true_value` is itself falsy (`''`, `""`, `false`, `null`, `0`) — `cond && ''` is always `''`, so the `||` fallback wins even when `cond` is true.
- **`adhoc-packages`**: flags `gem install`/`npm install` (and their `gem i` / `npm i` / `npm add` / `yarn add` / `pnpm add` aliases) with a package-name argument, which bypass the project's lockfile. Fires on bash and pwsh `run:` steps alike.

**Bug fixes**:
- **`github-app`**: `owner` set without `repositories` is no longer flagged when every requested `permission-*` is an org-scoped permission with no repository-level meaning (mirrors zizmor's fix for GitHub issue #2219).
- **`artipacked`**: a step whose `with:` is itself a computed expression (`with: ${{ fromJson(...) }}`) is no longer flagged — confirmed against zizmor v1.30.0 that this case is no longer an audit finding upstream.
- **`unpinned-tools`**: now also covers `extractions/setup-just` (its `with.just-version`, including the `"*"` wildcard, not just `with.version`).
- **`unexpected-keys` / `invalid-mapping-values`**: now validate `on.image_version`'s nested schema (`names`/`versions` must each be a non-empty array of non-empty strings; no other keys allowed) — previously only the top-level workflow map was checked, never descending into a per-event config.
- **`insecure-url-scheme`**: catalogued as `NotPlanned` — this zizmor audit targets `.pre-commit-config.yaml`, a document schema karinto has no parser for.

**Upstream-parity harness fixes** (no user-facing rule change, but why the above surfaced now): `scripts/upstream-parity/lib/mapping.mjs`'s `rules_catalog.mbt` parser was reading `status` from the wrong positional argument (`applies_to_workflow` instead, ever since those two trailing booleans were added to `spec(...)`) — the catalog mapping was silently empty, so every upstream-fired rule read back as `unmapped`. `scripts/upstream-parity/compare.mjs` also treated `unmapped` as a soft, non-blocking divergence, so this stayed invisible; it's now hard, since the only correct resolution is to register the rule (`Implemented`/`Planned`/`NotPlanned`). Separately, `scripts/upstream-parity/lib/run-karinto.mjs` never awaited `shell-ts-adapter`'s `ensureInitNode()`, so every tree-sitter-bash-based rule (`github-env`, `use-trusted-publishing`, `unpinned-tools`'s pipe-to-shell detection, …) silently produced zero findings under the parity check the entire time.
