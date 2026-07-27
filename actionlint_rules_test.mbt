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
        "pos": { "line": 3, "col": 3 },
        "job": "build",
      },
      {
        "rule": "unexpected-keys",
        "severity": "error",
        "message": "job `build`: unknown key `typo`",
        "pos": { "line": 3, "col": 3 },
        "job": "build",
      },
    ],
  })
}

///|
test "unexpected-keys: `parallel:` steps are not flagged as an unknown step key" {
  // Regression guard for the actionlint upstream gap (actionlint v1.7.12
  // rejects `parallel:` steps with "step must run script with \"run\"
  // section or run action with \"uses\" section [syntax-check]"). karinto's
  // `build_steps` flattens `parallel:` sub-steps (see `step-into-parallel-steps`
  // changeset), so the group itself never reaches `check_unexpected_keys_step`
  // and a genuine unknown key nested inside a sub-step is still caught.
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - parallel:
    #|          - run: echo one
    #|          - run: echo two
    #|            typo: oops
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
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "pos": { "line": 3, "col": 3 },
        "job": "build",
      },
      {
        "rule": "unexpected-keys",
        "severity": "error",
        "message": "step `step`: unknown key `typo`",
        "pos": { "line": 9, "col": 9 },
        "job": "build",
        "step": { "index": 0 },
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
        "pos": { "line": 2, "col": 3 },
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
        "pos": { "line": 3, "col": 3 },
        "job": "build",
      },
      {
        "rule": "invalid-mapping-values",
        "severity": "error",
        "message": "job `build`: `runs-on` must be a string or array",
        "pos": { "line": 3, "col": 3 },
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
        "pos": { "line": 3, "col": 3 },
        "job": "build",
      },
    ],
  })
}

///|
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
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "expression-type-mismatch",
        "severity": "error",
        "message": "expression type mismatch: cannot apply `+` to string and number",
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
        "pos": { "line": 3, "col": 3 },
        "job": "build",
      },
      {
        "rule": "obfuscation",
        "severity": "info",
        "message": "`if:` expression can be replaced by its static evaluation",
        "pos": { "line": 8, "col": 9 },
        "job": "build",
        "step": { "index": 0 },
      },
      {
        "rule": "job-timeout-minutes-required",
        "severity": "warning",
        "message": "job `build` does not declare `timeout-minutes:`",
        "pos": { "line": 3, "col": 3 },
        "job": "build",
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
        "pos": { "line": 3, "col": 3 },
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
        "pos": { "line": 5, "col": 3 },
        "job": "build",
      },
    ],
  })
}

///|
test "context-availability: `inputs` allowed at workflow level for workflow_call" {
  fn flags_inputs(yaml : String) -> Bool {
    @karinto.lint(yaml).diagnostics
    .filter(fn(d) {
      d.rule == "context-availability" && d.message.contains("`inputs`")
    })
    .length() >
    0
  }

  // A reusable workflow populates `inputs`, so it is available in workflow-level
  // `concurrency` (actionlint allows this) — no finding.
  let reusable =
    #|on:
    #|  workflow_call:
    #|    inputs:
    #|      v:
    #|        type: string
    #|concurrency:
    #|  group: g-${{ inputs.v }}
    #|jobs:
    #|  j:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo hi
  assert_false(flags_inputs(reusable))
  // Without an input trigger, `inputs` is not available there — flagged.
  let push_only =
    #|on: push
    #|concurrency:
    #|  group: g-${{ inputs.v }}
    #|jobs:
    #|  j:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo hi
  assert_true(flags_inputs(push_only))
}

///|
test "expression-syntax: literal `{{ }}` template is not a stray `}}`" {
  fn fires(script : String) -> Bool {
    let yaml = "on: push\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: \{script}"
    @karinto.lint(yaml).diagnostics
    .filter(fn(d) { d.rule == "expression-syntax" })
    .length() >
    0
  }

  // docker/metadata-action's `pattern={{version}}` carries a literal `}}` — not
  // a stray expression close. An extra `}}` after a real expression is fine too.
  assert_false(fires("echo \"pattern={{version}},value=${{ github.sha }}\""))
  assert_false(fires("echo \"${{ github.sha }} }}\""))
  // An unterminated `${{` is still an error.
  assert_true(fires("echo \"${{ github.sha\""))
  // A literal `{{ }}` must not mask an unterminated `${{` later in the string:
  // forward-scanning each `${{` catches it where token-counting would balance.
  assert_true(fires("echo \"pattern={{version}}-${{ inputs.version\""))
}

///|
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
        "pos": { "line": 3, "col": 3 },
        "job": "build",
      },
      {
        "rule": "expression-steps-type",
        "severity": "error",
        "message": "`steps.gen.outputs` is a mapping; index by output name",
        "pos": { "line": 10, "col": 9 },
        "job": "build",
        "step": { "index": 1 },
      },
      {
        "rule": "job-timeout-minutes-required",
        "severity": "warning",
        "message": "job `build` does not declare `timeout-minutes:`",
        "pos": { "line": 3, "col": 3 },
        "job": "build",
      },
    ],
  })
}

///|
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
        "pos": { "line": 3, "col": 3 },
        "job": "build",
      },
      {
        "rule": "template-injection",
        "severity": "info",
        "message": "code injection via template expansion in `run:` script",
        "pos": { "line": 11, "col": 14 },
        "job": "build",
        "step": { "index": 0 },
      },
      {
        "rule": "expression-matrix-type",
        "severity": "error",
        "message": "matrix.foo is not declared in the strategy",
        "pos": { "line": 11, "col": 9 },
        "job": "build",
        "step": { "index": 0 },
      },
      {
        "rule": "job-timeout-minutes-required",
        "severity": "warning",
        "message": "job `build` does not declare `timeout-minutes:`",
        "pos": { "line": 3, "col": 3 },
        "job": "build",
      },
    ],
  })
}

///|
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
        "message": "job `prep` has no `name:`",
        "pos": { "line": 3, "col": 3 },
        "job": "prep",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `use` has no `name:`",
        "pos": { "line": 12, "col": 3 },
        "job": "use",
      },
      {
        "rule": "template-injection",
        "severity": "info",
        "message": "code injection via template expansion in `run:` script",
        "pos": { "line": 18, "col": 14 },
        "job": "use",
        "step": { "index": 0 },
      },
      {
        "rule": "expression-needs-type",
        "severity": "error",
        "message": "needs.prep.outputs has no field `missing`",
        "pos": { "line": 18, "col": 9 },
        "job": "use",
        "step": { "index": 0 },
      },
      {
        "rule": "job-timeout-minutes-required",
        "severity": "warning",
        "message": "job `prep` does not declare `timeout-minutes:`",
        "pos": { "line": 3, "col": 3 },
        "job": "prep",
      },
      {
        "rule": "job-timeout-minutes-required",
        "severity": "warning",
        "message": "job `use` does not declare `timeout-minutes:`",
        "pos": { "line": 12, "col": 3 },
        "job": "use",
      },
    ],
  })
}

///|
test "expression-needs-type: reference to a job outside `needs`" {
  let yaml =
    #|name: ci
    #|on: push
    #|permissions:
    #|  contents: read
    #|concurrency:
    #|  group: ci-${{ github.ref }}
    #|  cancel-in-progress: true
    #|jobs:
    #|  prep:
    #|    name: prep
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    steps:
    #|      - run: echo ok
    #|  build:
    #|    name: build
    #|    needs: prep
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    steps:
    #|      - if: ${{ needs.deploy.result == 'success' }}
    #|        run: echo ok
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 2, "steps": 2, "lines": 22 },
    "diagnostics": [
      {
        "rule": "expression-needs-type",
        "severity": "error",
        "message": "needs.deploy is not defined; `deploy` is not in this job's `needs`",
        "pos": { "line": 21, "col": 9 },
        "job": "build",
        "step": { "index": 0 },
      },
    ],
  })
}

///|
test "expression-needs-type: reusable-workflow outputs are not second-guessed" {
  let yaml =
    #|name: ci
    #|on: push
    #|permissions:
    #|  contents: read
    #|concurrency:
    #|  group: ci-${{ github.ref }}
    #|  cancel-in-progress: true
    #|jobs:
    #|  prep:
    #|    name: prep
    #|    uses: octo/shared/.github/workflows/build.yml@0123456789012345678901234567890123456789
    #|  build:
    #|    name: build
    #|    needs: prep
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    steps:
    #|      - if: ${{ needs.prep.outputs.anything == 'x' }}
    #|        run: echo ok
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 2, "steps": 1, "lines": 19 },
    "diagnostics": [],
  })
}

///|
test "expression-steps-type: forward reference to a later step" {
  let yaml =
    #|name: ci
    #|on: push
    #|permissions:
    #|  contents: read
    #|concurrency:
    #|  group: ci-${{ github.ref }}
    #|  cancel-in-progress: true
    #|jobs:
    #|  build:
    #|    name: build
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    steps:
    #|      - if: ${{ steps.later.outcome == 'success' }}
    #|        run: echo first
    #|      - id: later
    #|        run: echo ok
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 2, "lines": 17 },
    "diagnostics": [
      {
        "rule": "expression-steps-type",
        "severity": "error",
        "message": "steps.later is not defined (no step with `id: later` is in scope)",
        "pos": { "line": 14, "col": 9 },
        "job": "build",
        "step": { "index": 0 },
      },
    ],
  })
}

///|
test "expression-steps-type: declared output access is clean" {
  let yaml =
    #|name: ci
    #|on: push
    #|permissions:
    #|  contents: read
    #|concurrency:
    #|  group: ci-${{ github.ref }}
    #|  cancel-in-progress: true
    #|jobs:
    #|  build:
    #|    name: build
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    outputs:
    #|      tag: ${{ steps.gen.outputs.tag }}
    #|    steps:
    #|      - id: gen
    #|        run: echo "tag=v1" >> "$GITHUB_OUTPUT"
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 17 },
    "diagnostics": [],
  })
}

///|
test "expression-matrix-type: include-introduced keys are declared" {
  let yaml =
    #|name: ci
    #|on: push
    #|permissions:
    #|  contents: read
    #|concurrency:
    #|  group: ci-${{ github.ref }}
    #|  cancel-in-progress: true
    #|jobs:
    #|  build:
    #|    name: build
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    strategy:
    #|      matrix:
    #|        os: [ubuntu-latest, macos-14]
    #|        include:
    #|          - os: ubuntu-latest
    #|            extra: true
    #|    steps:
    #|      - if: ${{ matrix.extra }}
    #|        run: echo ok
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 21 },
    "diagnostics": [],
  })
}

///|
test "expression-matrix-type: expression-built matrix is skipped" {
  let yaml =
    #|name: ci
    #|on: push
    #|permissions:
    #|  contents: read
    #|concurrency:
    #|  group: ci-${{ github.ref }}
    #|  cancel-in-progress: true
    #|jobs:
    #|  gen:
    #|    name: gen
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    outputs:
    #|      matrix: ${{ steps.m.outputs.matrix }}
    #|    steps:
    #|      - id: m
    #|        run: echo "matrix=..." >> "$GITHUB_OUTPUT"
    #|  build:
    #|    name: build
    #|    needs: gen
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    strategy:
    #|      matrix: ${{ fromJSON(needs.gen.outputs.matrix) }}
    #|    steps:
    #|      - if: ${{ matrix.os == 'ubuntu-latest' }}
    #|        run: echo ok
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 2, "steps": 2, "lines": 27 },
    "diagnostics": [],
  })
}

///|
test "expression-steps-type: bare outputs mapping evaluated in template" {
  let yaml =
    #|name: ci
    #|on: push
    #|permissions:
    #|  contents: read
    #|concurrency:
    #|  group: ci-${{ github.ref }}
    #|  cancel-in-progress: true
    #|jobs:
    #|  build:
    #|    name: build
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    steps:
    #|      - id: gen
    #|        run: echo "v=1" >> "$GITHUB_OUTPUT"
    #|      - name: show
    #|        if: ${{ steps.gen.outputs }}
    #|        run: echo done
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 2, "lines": 18 },
    "diagnostics": [
      {
        "rule": "expression-steps-type",
        "severity": "error",
        "message": "`steps.gen.outputs` is a mapping; index by output name",
        "pos": { "line": 16, "col": 9 },
        "job": "build",
        "step": { "index": 1 },
      },
    ],
  })
}

///|
test "expression-matrix-type: bracket indexing checks declared keys" {
  let yaml =
    #|name: ci
    #|on: push
    #|permissions:
    #|  contents: read
    #|concurrency:
    #|  group: ci-${{ github.ref }}
    #|  cancel-in-progress: true
    #|jobs:
    #|  build:
    #|    name: build
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    strategy:
    #|      matrix:
    #|        os: [ubuntu-latest, macos-14]
    #|    steps:
    #|      - if: ${{ matrix['os'] == matrix['arch'] }}
    #|        run: echo ok
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 18 },
    "diagnostics": [
      {
        "rule": "expression-matrix-type",
        "severity": "error",
        "message": "matrix.arch is not declared in the strategy",
        "pos": { "line": 17, "col": 9 },
        "job": "build",
        "step": { "index": 0 },
      },
    ],
  })
}

///|
test "expression-steps-type: member lookup is case-insensitive" {
  let yaml =
    #|name: ci
    #|on: push
    #|permissions:
    #|  contents: read
    #|concurrency:
    #|  group: ci-${{ github.ref }}
    #|  cancel-in-progress: true
    #|jobs:
    #|  build:
    #|    name: build
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    steps:
    #|      - id: gen
    #|        run: echo "v=1" >> "$GITHUB_OUTPUT"
    #|      - if: ${{ steps.GEN.Outputs.v == '1' }}
    #|        run: echo ok
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 2, "lines": 17 },
    "diagnostics": [],
  })
}

///|
test "expression-steps-type: unknown field on steps.<id>" {
  let yaml =
    #|name: ci
    #|on: push
    #|permissions:
    #|  contents: read
    #|concurrency:
    #|  group: ci-${{ github.ref }}
    #|  cancel-in-progress: true
    #|jobs:
    #|  build:
    #|    name: build
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    steps:
    #|      - id: gen
    #|        run: echo "v=1" >> "$GITHUB_OUTPUT"
    #|      - if: ${{ steps.gen.result == 'success' }}
    #|        run: echo ok
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 2, "lines": 17 },
    "diagnostics": [
      {
        "rule": "expression-steps-type",
        "severity": "error",
        "message": "steps.gen has no field `result`",
        "pos": { "line": 16, "col": 9 },
        "job": "build",
        "step": { "index": 1 },
      },
    ],
  })
}

///|
test "expression-matrix-type: expression-built include key disables the check" {
  let yaml =
    #|name: ci
    #|on: push
    #|permissions:
    #|  contents: read
    #|concurrency:
    #|  group: ci-${{ github.ref }}
    #|  cancel-in-progress: true
    #|jobs:
    #|  build:
    #|    name: build
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    strategy:
    #|      matrix:
    #|        os: [ubuntu-latest]
    #|        include:
    #|          - "${{ github.ref_name }}": dynamic
    #|    steps:
    #|      - if: ${{ matrix.undeclared }}
    #|        run: echo ok
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 20 },
    "diagnostics": [],
  })
}

///|
test "expression engine: hostile operator/property chains are skipped, not crashed" {
  // Left-associated chains parse iteratively but build a left-nested AST
  // whose height equals the chain length; the token cap keeps type
  // inference from recursing that deep. Both floods stay far above
  // EXPR_MAX_TOKENS and must be skipped without a stack overflow.
  // The yaml is assembled through a StringBuilder with the `$` split off
  // from `{{` — the JS backend compiles string concatenation into template
  // literals, where a literal `${` would be read as an interpolation.
  let sb = StringBuilder::new()
  sb.write_string(
    "on: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n",
  )
  sb.write_string("      - if: $")
  sb.write_string("{{ 1")
  for _i in 0..<5000 {
    sb.write_string(" && 1")
  }
  sb.write_string(" + 'x' }}\n        run: echo hi\n")
  sb.write_string("      - if: $")
  sb.write_string("{{ github")
  for _i in 0..<5000 {
    sb.write_string(".a")
  }
  sb.write_string(" }}\n        run: echo ho\n")
  let res = @karinto.lint(sb.to_string())
  assert_true(res.parse_error is None)
  // Over the token cap the expressions are skipped entirely — the trailing
  // `+ 'x'` mismatch is intentionally not reported.
  assert_true(
    res.diagnostics
    .filter(fn(d) { d.rule == "expression-type-mismatch" })
    .length() ==
    0,
  )
}

///|
test "expression-matrix-type: bare `if:` without braces is type-checked" {
  let yaml =
    #|name: ci
    #|on: push
    #|permissions:
    #|  contents: read
    #|concurrency:
    #|  group: ci-${{ github.ref }}
    #|  cancel-in-progress: true
    #|jobs:
    #|  build:
    #|    name: build
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    strategy:
    #|      matrix:
    #|        os: [ubuntu-latest]
    #|    steps:
    #|      - if: matrix.gradle == 1
    #|        run: echo ok
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 18 },
    "diagnostics": [
      {
        "rule": "expression-matrix-type",
        "severity": "error",
        "message": "matrix.gradle is not declared in the strategy",
        "pos": { "line": 17, "col": 9 },
        "job": "build",
        "step": { "index": 0 },
      },
    ],
  })
}

///|
test "expression-needs-type: toJSON-wrapped outputs mapping is clean" {
  let yaml =
    #|name: ci
    #|on: push
    #|permissions:
    #|  contents: read
    #|concurrency:
    #|  group: ci-${{ github.ref }}
    #|  cancel-in-progress: true
    #|jobs:
    #|  prep:
    #|    name: prep
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    outputs:
    #|      tag: ${{ steps.t.outputs.tag }}
    #|    steps:
    #|      - id: t
    #|        run: echo "tag=v1" >> "$GITHUB_OUTPUT"
    #|  build:
    #|    name: build
    #|    needs: prep
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    env:
    #|      ALL: ${{ toJSON(needs.prep.outputs) }}
    #|    steps:
    #|      - run: echo "$ALL"
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 2, "steps": 2, "lines": 26 },
    "diagnostics": [],
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
        "pos": { "line": 3, "col": 3 },
        "job": "build",
      },
      {
        "rule": "obfuscation",
        "severity": "info",
        "message": "`if:` expression can be replaced by its static evaluation",
        "pos": { "line": 9, "col": 9 },
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
        "pos": { "line": 4, "col": 12 },
        "job": "build",
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
        "pos": { "line": 3, "col": 3 },
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
        "pos": { "line": 5, "col": 3 },
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
        "pos": { "line": 7, "col": 3 },
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
        "pos": { "line": 6, "col": 3 },
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
        "pos": { "line": 5, "col": 3 },
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
        "pos": { "line": 3, "col": 3 },
        "job": "build",
      },
      {
        "rule": "unknown-runner-label",
        "severity": "warning",
        "message": "unknown runner label `ubunto-latest` (did you mean `ubuntu-latest`?)",
        "pos": { "line": 3, "col": 3 },
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
        "pos": { "line": 3, "col": 3 },
        "job": "build",
      },
      {
        "rule": "uses-syntax",
        "severity": "error",
        "message": "uses `actions/checkout`: expected `owner/repo@ref`",
        "pos": { "line": 9, "col": 9 },
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
        "pos": { "line": 3, "col": 3 },
        "job": "build",
      },
      {
        "rule": "shell-name-per-os",
        "severity": "error",
        "message": "shell `cmd` is only available on Windows runners",
        "pos": { "line": 9, "col": 9 },
        "job": "build",
        "step": { "index": 0 },
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
        "pos": { "line": 5, "col": 3 },
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
        "pos": { "line": 5, "col": 3 },
        "job": "build",
      },
      {
        "rule": "undocumented-permissions",
        "severity": "info",
        "message": "permissions block has 1 entry/entries without explanatory comments",
        "pos": { "line": 2, "col": 1 },
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
        "pos": { "line": 6, "col": 3 },
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
        "pos": { "line": 3, "col": 3 },
        "job": "build job",
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
        "pos": { "line": 3, "col": 3 },
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
        "pos": { "line": 3, "col": 3 },
        "job": "build",
      },
      {
        "rule": "deprecated-workflow-commands",
        "severity": "warning",
        "message": "deprecated workflow command `::set-output`; use `$GITHUB_OUTPUT` instead",
        "pos": { "line": 9, "col": 9 },
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
        "pos": { "line": 3, "col": 3 },
        "job": "build",
      },
      {
        "rule": "constant-if-condition",
        "severity": "warning",
        "message": "job `build` `if:` is constant `true` — remove or replace the condition",
        "pos": { "line": 3, "col": 3 },
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

// ---------------------------------------------------------------------------
// Attribution regression tests — see the matching block in
// zizmor_rules_test.mbt for the rationale.
// ---------------------------------------------------------------------------

///|
test "attribution: invalid-env-var-name names the step and the offending entry" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
    #|        env:
    #|          BAD-NAME: x
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "invalid-env-var-name" })
  inspect(hits.length(), content="1")
  assert_true(hits[0].job is Some("build"))
  assert_true(hits[0].step is Some({ index: 0, .. }))
  // Resolves to the offending entry itself, not the whole `env:` block.
  assert_true(hits[0].pos is Some({ line: 10, .. }))
}

///|
test "attribution: context-availability names the job whose `env:` is at fault" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    env:
    #|      OUT: ${{ steps.foo.outputs.bar }}
    #|    steps:
    #|      - run: echo hi
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "context-availability" })
  inspect(hits.length(), content="1")
  assert_true(hits[0].job is Some("build"))
  assert_true(hits[0].pos is Some({ line: 7, .. }))
}

///|
test "attribution: job-needs-graph names the job and its `needs:` value" {
  let yaml =
    #|on: push
    #|jobs:
    #|  first:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
    #|  second:
    #|    needs: nope
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "job-needs-graph" })
  inspect(hits.length(), content="1")
  assert_true(hits[0].job is Some("second"))
  assert_true(hits[0].pos is Some({ line: 10, .. }))
}
