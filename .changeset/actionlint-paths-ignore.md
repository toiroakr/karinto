---
"karinto": patch
---

Honours `.github/actionlint.yaml`'s `paths.<glob>.ignore` (#50), wired through the CLI's `--actionlint-config` and the Worker's `actionlint` parameter (64 KiB cap, same as `ghalint`/`zizmor`/`config`).

actionlint suppresses findings by running each `ignore` regex against *its own* diagnostic message text — a mechanism karinto can't replay verbatim, since karinto's messages don't share actionlint's wording. Instead, each pattern is compiled and executed (via the new `moonbitlang/regexp` dependency) against a curated table of actionlint's own canonical message text, transcribed from its vendored test fixtures, to identify which actionlint check it targets; that check's karinto rule(s) — resolved via the catalogue's `origins`, the same way ghalint's `policy_name` already is — are suppressed under the matching `<glob>` (`path_glob_match`, the same `/`-segment-aware matcher `ignore-paths` uses).

This is rule-grained, not message-grained: unlike real actionlint, a pattern that in principle only ignores one specific dynamic value (e.g. one runner label) suppresses every finding of the matching rule under the glob instead. A pattern that fails to compile, or matches none of the curated checks, is a silent no-op — the same best-effort posture as `ghalint_config` / `zizmor_config`. For exact, guaranteed control, karinto's own `ignore-paths` (added alongside `karinto.yaml` in a previous release) remains the precise alternative.
