---
"karinto": patch
---

Add `rules_catalog.md` as a human-readable mirror of the in-code rule
catalog. The new file links every rule to its upstream documentation
(actionlint / zizmor / ghalint) and records status, severity, the
rationale behind the five upstream consolidations, and why each planned
rule is not yet implemented. `AGENTS.md` (and `CLAUDE.md`, now a symlink
to it) documents the rule that `rules_catalog.mbt` and `rules_catalog.md`
must be updated together.
