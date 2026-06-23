---
"karinto": patch
---

Fix false negatives and false positives in `outdated-action-version` and `unknown-runner-label`

**outdated-action-version**

The rule previously only checked an action file's own `runs.using` field, so
`actions/checkout@v3` (node16, deprecated) referenced from a workflow step was
silently ignored. The rule now also inspects `uses:` in workflow steps and fires
when a well-known action's major version is known to use a deprecated runtime.
Subpath refs (`actions/cache/restore@v3`), pre-release suffixes (`v3-beta`), and
mixed-case refs (`Actions/Checkout@v3`) are all normalized correctly. Runtime-upgrade
backport tags such as `@v3-node20` (which explicitly targets node20) are correctly
excluded. The diagnostic message now echoes the original ref string from the workflow
(e.g. `@v3-beta`) rather than reconstructing it as `@v<major>`.

**unknown-runner-label**

Two fixes:
- Removed the `looks_hosted` guard that only flagged labels with an
  `ubuntu-`/`macos-`/`windows-` prefix. Any label absent from the known set is
  now flagged, matching actionlint behavior (fixes false negatives for
  `depot-ubuntu-*`, `codspeed-macro`, etc.).
- When `self-hosted` is present in a `runs-on` array, the remaining labels are
  routing hints for self-hosted infrastructure. Unknown-label checks are now
  skipped in that case, matching actionlint behavior (fixes false positives for
  `runs-on: [self-hosted, custom-pool]`).
