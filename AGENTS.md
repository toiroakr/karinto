# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

- In the toplevel directory, there is a `moon.mod.json` file listing module
  metadata.

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` to check tests pass. MoonBit supports snapshot testing; when
  changes affect outputs, run `moon test --update` to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. Use snapshot tests to record current
  behavior. For solid, well-defined results (e.g. scientific computations),
  prefer assertion tests. You can use `moon coverage analyze > uncovered.log` to
  see which parts of your code are not covered by tests.

## Rule catalog discipline

[`rules_catalog.mbt`](rules_catalog.mbt) is the source of truth for rule
**metadata** (status, severity, upstream origins) and is enforced by
`coverage_test.mbt`. The runtime rule registry that drives lint execution
lives in `rules.mbt` as `all_rules()`; the catalogue does not directly
control engine behaviour. [`rules_catalog.md`](rules_catalog.md) is a
human-readable mirror of the catalogue with upstream doc links and
per-rule status / merge rationale notes.

When you change `rules_catalog.mbt` (adding a rule, flipping `Planned` ↔
`Implemented`, adjusting severity, recording a new consolidation), update
`rules_catalog.md` in the same commit so the two stay in sync. Tests do not
enforce this — the responsibility is on the editor.

## License attribution discipline

The Worker build (`moon build --target js --release`) inlines every MoonBit
dependency into the distributed JS bundle, so each runtime dep must have its
license text reproduced in `THIRD_PARTY_LICENSES.md`. When adding a dependency,
the maintenance burden is to keep that file in sync:

- **New MoonBit dep in `moon.mod.json` `deps`** — copy
  `.mooncakes/<owner>/<name>/LICENSE` into a new `## <name>` section of
  `THIRD_PARTY_LICENSES.md`. If the LICENSE file embeds transitive
  attributions (e.g. the way `moonbit-community/yaml` ships the yaml-rust2
  notice), surface those as separate sections too so the chain stays visible.
  Add a row to the top-level project table.
- **New npm runtime dep in `cf/package.json` `dependencies`** (not
  `devDependencies` — wrangler / js-yaml today are devDeps and are not
  redistributed) — copy `cf/node_modules/<name>/LICENSE` into a section
  similarly and add a table row.
- **"Inspired by" projects** (rule taxonomy borrowed but no code ported) —
  table entry is courtesy, not a legal requirement. If actual code gets
  ported later, promote the entry to a full license-text section.

`.mooncakes/` and `cf/node_modules/` are gitignored, so they cannot satisfy
attribution by themselves — the texts must be in the tracked
`THIRD_PARTY_LICENSES.md`.
