---
"karinto": patch
---

`dependabot-cooldown` now tracks zizmor 1.28.0, which taught the audit about GitHub's new implicit three-day default cooldown ([zizmorcore/zizmor#2193](https://github.com/zizmorcore/zizmor/issues/2193)).

Three behavioural changes:

- The pedantic-only "`multi-ecosystem-group` cooldowns do not batch updates correctly" finding is **gone**. An `updates:` entry that joins a `multi-ecosystem-group` while configuring a sufficient cooldown is now silent, matching upstream.
- An entry with no `cooldown:` block, or one without `default-days`, now reports `insufficient implicit default-days (less than 7)` instead of `missing cooldown configuration` / `no default-days configured` — the entry does get a cooldown, GitHub's implicit one, it's just shorter than the threshold.
- The rule's severity moves from `info` to `warning`, mirroring upstream: zizmor 1.28.0 promoted the too-short `default-days` case from `help` to `warning`, making every arm of the audit a `warning`. This also changes the SARIF `level` reported for the rule.

An explicit `default-days` below 7 keeps its existing `insufficient default-days configured (less than 7)` wording.
