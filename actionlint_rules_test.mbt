// Fixture + expected-JSON tests for the actionlint-derived rule family.
//
// `duplicate-job-step-ids` is already implemented in `karinto_test.mbt`; every
// other entry below is `#skip("not implemented yet")` until the matching
// check ships.

///|
test "unexpected-keys: unknown key under job" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    typo: oops
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 10 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "job": "build",
      },
      {
        "rule": "unexpected-keys",
        "severity": "error",
        "message": "job `build`: unknown key `typo`",
        "job": "build",
      },
    ],
  })
}

///|
test "missing-required-keys: workflow missing `on`" {
  let yaml =
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 8 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "missing-required-keys",
        "severity": "error",
        "message": "workflow is missing required key `on`",
      },
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "job": "build",
      },
    ],
  })
}

///|
test "empty-mappings: empty jobs block" {
  let yaml =
    #|on: push
    #|jobs: {}
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 0, "steps": 0, "lines": 2 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "empty-mappings",
        "severity": "warning",
        "message": "workflow: `jobs:` is an empty mapping",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
    ],
  })
}

///|
test "invalid-mapping-values: runs-on must be string or array" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: 123
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 9 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "job": "build",
      },
      {
        "rule": "invalid-mapping-values",
        "severity": "error",
        "message": "job `build`: `runs-on` must be a string or array",
        "job": "build",
      },
    ],
  })
}

///|
test "expression-syntax: malformed `${{` expression" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - if: ${{ github.event_name ==
    #|        run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 10 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "expression-syntax",
        "severity": "error",
        "message": "expression syntax error: unterminated `${{`",
      },
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "job": "build",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "expression-type-mismatch: arithmetic on string literal" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - if: ${{ 'foo' + 1 }}
    #|        run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 9 },
    "diagnostics": [
      {
        "rule": "expression-type-mismatch",
        "severity": "error",
        "message": "expression type mismatch: cannot apply `+` to string and number",
      },
    ],
  })
}

///|
test "unknown-context-or-function: unknown context name" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - if: ${{ githab.actor == 'me' }}
    #|        run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 10 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "unknown-context-or-function",
        "severity": "error",
        "message": "unknown context `githab` (did you mean `github`?)",
      },
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "job": "build",
      },
    ],
  })
}

///|
test "context-availability: `needs` referenced at workflow level" {
  let yaml =
    #|on: push
    #|env:
    #|  CHAIN: ${{ needs.prep.outputs.tag }}
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo "$CHAIN"
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 11 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
      {
        "rule": "context-availability",
        "severity": "error",
        "message": "context `needs` is not available in workflow-level `env`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "job": "build",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "expression-steps-type: steps.<id>.outputs typed wrongly" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - id: gen
    #|        run: echo "v=1" >> $GITHUB_OUTPUT
    #|      - if: ${{ steps.gen.outputs == 1 }}
    #|        run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 2, "lines": 11 },
    "diagnostics": [
      {
        "rule": "expression-steps-type",
        "severity": "error",
        "message": "`steps.gen.outputs` is a mapping; index by output name",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "expression-matrix-type: matrix.foo not declared in strategy" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    strategy:
    #|      matrix:
    #|        os: [ubuntu-latest]
    #|    steps:
    #|      - run: echo ${{ matrix.foo }}
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 11 },
    "diagnostics": [
      {
        "rule": "expression-matrix-type",
        "severity": "error",
        "message": "matrix.foo is not declared in the strategy",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "expression-needs-type: needs.<id>.outputs type mismatch" {
  let yaml =
    #|on: push
    #|jobs:
    #|  prep:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    outputs:
    #|      tag: ${{ steps.t.outputs.tag }}
    #|    steps:
    #|      - id: t
    #|        run: echo "tag=v1" >> $GITHUB_OUTPUT
    #|  use:
    #|    needs: prep
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo ${{ needs.prep.outputs.missing }}
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 2, "steps": 2, "lines": 18 },
    "diagnostics": [
      {
        "rule": "expression-needs-type",
        "severity": "error",
        "message": "needs.prep.outputs has no field `missing`",
      },
    ],
  })
}

///|
test "meaningless-comparison: meaningless comparison `1 == 1`" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - if: ${{ 1 == 1 }}
    #|        run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 10 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
      {
        "rule": "meaningless-comparison",
        "severity": "warning",
        "message": "comparison `1 == 1` is always true",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "job": "build",
      },
      {
        "rule": "obfuscation",
        "severity": "info",
        "message": "`if:` expression can be replaced by its static evaluation",
        "job": "build",
        "step": { "index": 0 },
      },
    ],
  })
}

// `shellcheck` and `pyflakes` are catalogued as NotPlanned — karinto runs
// in a Cloudflare Worker and cannot ship native shellcheck / pyflakes
// binaries. See rules_catalog.mbt.
//
// actionlint's `script-injection` is consolidated into `template-injection`
// (see rules_catalog.mbt). Its fixture lives in zizmor_rules_test.mbt.

///|
test "job-needs-graph: dependency on undefined job" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    needs: missing
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 10 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "job-needs-graph",
        "severity": "error",
        "message": "job `build` needs undefined job `missing`",
      },
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "job": "build",
      },
    ],
  })
}

///|
test "matrix-values: duplicate scalar in matrix array" {
  let yaml =
    #|on: push
    #|jobs:
    #|  test:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    strategy:
    #|      matrix:
    #|        node: [16, 16, 18]
    #|    steps:
    #|      - run: echo $NODE
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "matrix-values" })
  inspect(hits.length(), content="1")
  inspect(hits[0].message, content="duplicate matrix value `16` in `node`")
}

///|
test "matrix-values: silent on unique matrix entries" {
  let yaml =
    #|on: push
    #|jobs:
    #|  test:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    strategy:
    #|      matrix:
    #|        node: [16, 18, 20]
    #|    steps:
    #|      - run: echo $NODE
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "matrix-values" })
  inspect(hits.length(), content="0")
}

///|
test "webhook-events: unknown event filter" {
  let yaml =
    #|on:
    #|  pushh:
    #|    branches: [main]
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 11 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "webhook-events",
        "severity": "error",
        "message": "unknown webhook event `pushh` (did you mean `push`?)",
      },
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "job": "build",
      },
    ],
  })
}

///|
test "workflow-dispatch-inputs: input type must be one of the allowed set" {
  let yaml =
    #|on:
    #|  workflow_dispatch:
    #|    inputs:
    #|      level:
    #|        type: bogus
    #|jobs:
    #|  noop:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 13 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
      {
        "rule": "workflow-dispatch-inputs",
        "severity": "error",
        "message": "workflow_dispatch input `level.type` must be one of choice/boolean/string/environment/number",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `noop` has no `name:`",
        "job": "noop",
      },
    ],
  })
}

///|
test "glob-patterns: invalid glob pattern in paths filter" {
  let yaml =
    #|on:
    #|  push:
    #|    paths:
    #|      - "src/[unclosed"
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 12 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
      {
        "rule": "glob-patterns",
        "severity": "error",
        "message": "invalid glob `src/[unclosed`: unterminated character class",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "job": "build",
      },
    ],
  })
}

///|
test "cron-and-timezone: out-of-range minute value" {
  let yaml =
    #|on:
    #|  schedule:
    #|    - cron: "60 * * * *"
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 11 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "cron-and-timezone",
        "severity": "error",
        "message": "schedule.cron `60 * * * *`: minute: value `60` out of bounds [0-59]",
      },
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "job": "build",
      },
    ],
  })
}

///|
test "unknown-runner-label: unknown runner label" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubunto-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 9 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "job": "build",
      },
      {
        "rule": "unknown-runner-label",
        "severity": "warning",
        "message": "unknown runner label `ubunto-latest` (did you mean `ubuntu-latest`?)",
        "job": "build",
      },
    ],
  })
}

///|
test "uses-syntax: missing @ref in uses" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/checkout
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 9 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "job": "build",
      },
      {
        "rule": "uses-syntax",
        "severity": "error",
        "message": "uses `actions/checkout`: expected `owner/repo@ref`",
        "job": "build",
        "step": { "index": 0 },
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "local-action-inputs: unknown input on local action" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: ./.github/actions/local
    #|        with:
    #|          made_up: value
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 10 },
    "diagnostics": [
      {
        "rule": "local-action-inputs",
        "severity": "error",
        "message": "local action `./.github/actions/local` has no input `made_up`",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "popular-action-inputs: unknown input on actions/checkout" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/checkout@v4
    #|        with:
    #|          fetched-depth: 0
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 10 },
    "diagnostics": [
      {
        "rule": "popular-action-inputs",
        "severity": "error",
        "message": "actions/checkout has no input `fetched-depth` (did you mean `fetch-depth`?)",
      },
    ],
  })
}

///|
test "outdated-action-version: node12 runtime" {
  let yaml =
    #|name: legacy
    #|description: example
    #|runs:
    #|  using: node12
    #|  main: index.js
  json_inspect(lint_json(yaml, kind=Action), content={
    "kind": "action",
    "stats": { "jobs": 0, "steps": 0, "lines": 5 },
    "diagnostics": [
      {
        "rule": "outdated-action-version",
        "severity": "warning",
        "message": "runtime `node12` is deprecated; use `node20` or newer",
      },
    ],
  })
}

///|
test "shell-name-per-os: pwsh on linux runner" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - shell: cmd
    #|        run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 10 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "job": "build",
      },
      {
        "rule": "shell-name-per-os",
        "severity": "error",
        "message": "shell `cmd` is only available on Windows runners",
        "job": "build",
      },
    ],
  })
}

// actionlint's `hardcoded-credentials` is consolidated into
// `hardcoded-container-credentials` (see rules_catalog.mbt). Its fixture
// lives in zizmor_rules_test.mbt.

///|
test "invalid-env-var-name: env name starts with digit" {
  let yaml =
    #|on: push
    #|env:
    #|  1FOO: bar
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 11 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "invalid-env-var-name",
        "severity": "warning",
        "message": "env name `1FOO` does not match `[A-Za-z_][A-Za-z0-9_]*`",
      },
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "job": "build",
      },
    ],
  })
}

///|
test "permissions-syntax: unknown permission scope" {
  let yaml =
    #|on: push
    #|permissions:
    #|  conents: read
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 11 },
    "diagnostics": [
      {
        "rule": "permissions-syntax",
        "severity": "error",
        "message": "workflow: unknown permission scope `conents` — did you mean `contents`?",
      },
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "job": "build",
      },
      {
        "rule": "undocumented-permissions",
        "severity": "info",
        "message": "permissions block has 1 entry/entries without explanatory comments",
      },
    ],
  })
}

///|
test "reusable-workflow-definition: reusable workflow output not exposed" {
  let yaml =
    #|on:
    #|  workflow_call:
    #|    outputs:
    #|      version: {}
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 12 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "reusable-workflow-definition",
        "severity": "error",
        "message": "workflow_call output `version` is missing `value:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "job": "build",
      },
    ],
  })
}

///|
test "job-step-id-naming: job id has invalid characters" {
  let yaml =
    #|on: push
    #|jobs:
    #|  "build job":
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 9 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "job-step-id-naming",
        "severity": "warning",
        "message": "job ID `build job` must match `[A-Za-z_][A-Za-z0-9_-]*`",
      },
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build job` has no `name:`",
        "job": "build job",
      },
    ],
  })
}

///|
test "deprecated-workflow-commands: ::set-output workflow command" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo "::set-output name=v::1"
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 9 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "job": "build",
      },
      {
        "rule": "deprecated-workflow-commands",
        "severity": "warning",
        "message": "deprecated workflow command `::set-output`; use `$GITHUB_OUTPUT` instead",
        "job": "build",
        "step": { "index": 0 },
      },
    ],
  })
}

///|
test "constant-if-condition: `if: true` always-on" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    if: true
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 10 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "job": "build",
      },
      {
        "rule": "constant-if-condition",
        "severity": "warning",
        "message": "job `build` `if:` is constant `true` — remove or replace the condition",
        "job": "build",
      },
    ],
  })
}

///|
test "action-yml-metadata: action.yml missing `runs`" {
  let yaml =
    #|name: missing-runs
    #|description: example
    #|inputs:
    #|  who:
    #|    description: target
    #|    required: true
  json_inspect(lint_json(yaml, kind=Action), content={
    "kind": "action",
    "stats": { "jobs": 0, "steps": 0, "lines": 6 },
    "diagnostics": [
      {
        "rule": "action-yml-metadata",
        "severity": "error",
        "message": "action.yml is missing required key `runs`",
      },
    ],
  })
}

///|
test "deprecated-action-inputs: deprecated input on a popular action" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/setup-node@v4
    #|        with:
    #|          version: 20
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) {
    d.rule == "deprecated-action-inputs"
  })
  inspect(hits.length(), content="1")
  inspect(
    hits[0].message,
    content="actions/setup-node input `version` is deprecated; use `node-version`",
  )
}

///|
test "deprecated-action-inputs: silent when current input is used" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/setup-node@v4
    #|        with:
    #|          node-version: 20
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) {
    d.rule == "deprecated-action-inputs"
  })
  inspect(hits.length(), content="0")
}

///|
test "yaml-anchor-issues: anchor declared but never referenced" {
  let yaml =
    #|on: push
    #|jobs:
    #|  base: &base
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "yaml-anchor-issues" })
  inspect(hits.length(), content="1")
  inspect(
    hits[0].message,
    content="YAML anchor `&base` is declared but never referenced",
  )
}

///|
test "yaml-anchor-issues: silent when anchor is aliased" {
  let yaml =
    #|on: push
    #|defaults: &defaults
    #|  run:
    #|    shell: bash
    #|jobs:
    #|  build:
    #|    defaults: *defaults
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "yaml-anchor-issues" })
  inspect(hits.length(), content="0")
}
