// Blackbox tests for the karinto library.
//
// This file holds tests for currently-implemented rules and the engine's
// general behaviour (parse errors, the `disable` glob, etc.). Per-rule
// fixtures for the actionlint/zizmor/ghalint families live in
// `actionlint_rules_test.mbt`, `zizmor_rules_test.mbt`, and
// `ghalint_rules_test.mbt`. The catalogue is `rules_catalog.mbt`, and
// `coverage_test.mbt` asserts the two stay in sync.

///|
fn lint_json(content : String, kind? : @karinto.FileKind = Unknown) -> Json {
  @karinto.lint(content, kind~).to_json()
}

// ---------------------------------------------------------------------------
// Implemented rules
// ---------------------------------------------------------------------------

///|
test "duplicate-job-step-ids: duplicate job ids (case-insensitive)" {
  let yaml =
    #|on: push
    #|jobs:
    #|  Build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 2, "steps": 2, "lines": 16 },
    "diagnostics": [
      {
        "rule": "duplicate-job-step-ids",
        "severity": "error",
        "message": "duplicate job ID `build` (conflicts with `Build` case-insensitively)",
        "job": "build",
      },
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
        "message": "job `Build` has no `name:`",
        "job": "Build",
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
test "duplicate-job-step-ids: duplicate step ids" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - id: A
    #|        run: echo a
    #|      - id: a
    #|        run: echo a2
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 2, "lines": 12 },
    "diagnostics": [
      {
        "rule": "duplicate-job-step-ids",
        "severity": "error",
        "message": "duplicate step ID `a` (conflicts with `A` case-insensitively)",
        "job": "build",
        "step": { "index": 1, "id": "a" },
      },
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
    ],
  })
}

///|
test "permissions-write-all-forbidden: write-all permission rejected at workflow scope" {
  let yaml =
    #|on: push
    #|permissions: write-all
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 8 },
    "diagnostics": [
      {
        "rule": "permissions-write-all-forbidden",
        "severity": "error",
        "message": "workflow: `permissions: write-all` is forbidden",
      },
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "uses write-all permissions",
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
test "job-permissions-required: missing job permissions" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 7 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "job `build`: default permissions used due to no permissions: block",
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
        "rule": "job-permissions-required",
        "severity": "warning",
        "message": "job `build` does not declare `permissions:`",
        "job": "build",
      },
    ],
  })
}

///|
test "job-permissions-required: satisfied when workflow-level permissions present" {
  let yaml =
    #|on: push
    #|permissions:
    #|  contents: read
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 9 },
    "diagnostics": [
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

// ---------------------------------------------------------------------------
// Engine-level behaviour
// ---------------------------------------------------------------------------

///|
test "disable: skip a rule with a glob pattern" {
  let yaml =
    #|on: push
    #|permissions: write-all
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    steps:
    #|      - run: echo hi
  let res = @karinto.lint(yaml, disabled=["permissions-*"])
  json_inspect(res.to_json(), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 8 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "uses write-all permissions",
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
test "parse error: malformed YAML is surfaced" {
  let yaml = "on: [push\njobs:\n  build:\n    steps: []"
  let res = @karinto.lint(yaml)
  json_inspect(res.parse_error is Some(_), content=true)
  json_inspect(res.diagnostics.length(), content=0)
}
