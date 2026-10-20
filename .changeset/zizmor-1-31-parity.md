---
"karinto": minor
---

Track zizmor 1.31:

- `dangerous-triggers` also flags `issue_comment`.
- `cache-poisoning` flags an explicit `cache-mode: write` / `write-only` (workflow or job level; the job's value wins) combined with a dangerous trigger, and skips jobs whose effective `cache-mode` is `none`.
- `unpinned-images` flags a container image taken from an indirect matrix (`matrix: ${{ fromJSON(...) }}`, or an expression-valued `include` / `exclude`) and floating tags in the matrix key's own list.
- New `pre-commit` file kind (auto-detected from a top-level `repos:`, or `--type pre-commit` / the `.pre-commit-config.yaml` filename). `typosquat-uses` checks its GitHub `repo:` URLs against `pre-commit/pre-commit-hooks`, `astral-sh/ruff-pre-commit`, `asottile/pyupgrade` and `psf/black`.
