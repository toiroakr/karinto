---
"karinto": patch
---

Catalog overhaul:

- Add `rules_catalog.md` as a human-readable mirror of `rules_catalog.mbt`,
  with upstream documentation links, status, severity, and per-rule notes
  on the five consolidations and on every planned/not-planned rule.
- Introduce a third `Status` variant, `NotPlanned`, for rules that are
  documented but deliberately out of scope. Demote `shellcheck` and
  `pyflakes` (Cloudflare Workers cannot ship the native binaries),
  `ref-confusion` (cannot occur once `unpinned-uses` mandates SHA pins),
  and `stale-action-refs` (GitHub API cost not worth the informational
  signal) to `NotPlanned` and drop their `#skip("not implemented yet")`
  fixtures. Coverage test now only requires fixtures for
  `Implemented`/`Planned` entries.
- `AGENTS.md` (and `CLAUDE.md`, now a symlink to it) gains a "Rule catalog
  discipline" section requiring `rules_catalog.mbt` and `rules_catalog.md`
  to be updated together.
