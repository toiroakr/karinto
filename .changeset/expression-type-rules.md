---
"karinto": minor
---

Implement the expression type-inference rule family (#36).

A new in-tree `${{ … }}` expression parser (lexer + recursive-descent parser
+ small type model in `expr.mbt`) backs four rules that were catalogued as
`Planned`:

- **`expression-needs-type`** — types the `needs` context from the job
  dependency graph. Only direct dependencies are members (referencing a
  transitive dependency is an error, matching actionlint), and
  `needs.<job>.outputs` is strict over the dependency's declared `outputs:`
  keys. Reusable-workflow dependencies keep loose outputs.
- **`expression-steps-type`** — tracks declared step `id`s per job (and per
  composite action) honouring step order: references to unknown or
  not-yet-run steps are errors, as is using `steps.<id>.outputs` as a scalar
  (`steps.gen.outputs == 1`).
- **`expression-matrix-type`** — flags `matrix.<key>` references not declared
  as a `strategy.matrix` dimension or introduced by an `include:` entry.
  Expression-built matrices disable the check.
- **`expression-type-mismatch`** — flags arithmetic operators applied to
  known non-number operands (e.g. `'foo' + 1`; the expression language has
  no arithmetic at all).

The model is deliberately conservative: contexts whose shape can't be read
from the file (`github`, `env`, dynamic ids/matrices, reusable-workflow
outputs) type as `any` and never fire, and unparseable expressions are
skipped (`expression-syntax` owns syntax reporting). All four rules hold
zero hard divergences against actionlint's vendored fixtures in the
upstream-parity check.
