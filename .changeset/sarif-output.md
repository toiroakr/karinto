---
"karinto": minor
---

Add SARIF 2.1.0 output (#33) alongside the JSON envelope, so findings can be
uploaded to GitHub Code Scanning via `github/codeql-action/upload-sarif`.

- **Engine** — new `sarif_report(entries, io_errors?, version?)` builds a
  complete SARIF document: `rule` → `result.ruleId` plus a
  `tool.driver.rules[]` entry (catalogue title, default severity, upstream
  origins), `severity` → `level` (`info` → `note`), `pos` →
  `physicalLocation.region`, `job`/`step` → `logicalLocations[]`, YAML parse
  errors → a synthetic `parse-error` rule, unreadable inputs →
  `invocations[].toolExecutionNotifications`. `tool.driver.version` is
  stamped from a new `ENGINE_VERSION` constant kept in lockstep with
  `package.json` / `moon.mod` by `scripts/sync-moon-version.mjs`.
- **Worker** — new `format=sarif` parameter (`content` and `repo` modes;
  response content type `application/sarif+json`). In `content` mode an
  optional `path=` labels the artifact so results get a `physicalLocation`;
  in `repo` mode targets already carry paths and the whole batch lands in
  one SARIF run. JSON stays the default — existing callers are unaffected.
- **CLI** — new `--format json|sarif` (`-f`). File arguments become artifact
  URIs; stdin yields pathless results. Exit codes are format-independent.
