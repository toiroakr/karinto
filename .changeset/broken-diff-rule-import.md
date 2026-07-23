---
"karinto": patch
---

Fix `deploy-preview`'s `replay` job crashing with `ERR_MODULE_NOT_FOUND` because `scripts/diff-rules/2026-06-string-literal-with-promoted.mjs` imported a rule file that `prune-diff-rules.yml`'s automation had already pruned. The composite rule now inlines the logic it depended on instead of importing it.

Also hardens the automation against recurrence: `prune-diff-rules.yml` now skips removing a rule file that another surviving rule file still imports, and `scripts/replay.mjs` surfaces a clear error (naming the failing file) instead of an opaque crash if a diff-rule import ever breaks again.
