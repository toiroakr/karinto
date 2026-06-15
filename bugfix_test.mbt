// Regression tests for two false positives found while auditing
// tailor-platform/sdk workflows:
//   1. `concurrency:` as a plain string (valid GitHub Actions) was wrongly
//      flagged by `invalid-mapping-values`.
//   2. `needs.<hyphenated-job-id>.result` was wrongly flagged by
//      `unknown-context-or-function` (the scanner split the id on `-`).

///|
test "invalid-mapping-values: string `concurrency` is valid (not a mapping error)" {
  let yaml =
    #|on: push
    #|concurrency: ci-group
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
        "message": "workflow `concurrency:` is bare; missing `cancel-in-progress`",
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
        "pos": { "line": 4, "col": 3 },
        "job": "build",
      },
    ],
  })
}

///|
test "unknown-context-or-function: hyphenated `needs.<job-id>` is not an unknown context" {
  let yaml =
    #|on: push
    #|jobs:
    #|  my-cross-platform:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
    #|  summary:
    #|    needs: [my-cross-platform]
    #|    if: ${{ needs.my-cross-platform.result == 'success' }}
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
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
        "message": "job `my-cross-platform` has no `name:`",
        "pos": { "line": 3, "col": 3 },
        "job": "my-cross-platform",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `summary` has no `name:`",
        "pos": { "line": 10, "col": 3 },
        "job": "summary",
      },
    ],
  })
}

///|
test "github-app-limit-permissions: granular `permission-*` inputs satisfy the limit" {
  let yaml =
    #|name: T
    #|on: push
    #|jobs:
    #|  release:
    #|    name: Release
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 10
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
    #|        with:
    #|          app-id: "123"
    #|          private-key: "key"
    #|          permission-contents: write
    #|          permission-pull-requests: write
    #|          repositories: my-repo
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 17 },
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
    ],
  })
}

///|
test "unknown-runner-label: `ubuntu-slim` is an official GitHub-hosted runner" {
  let yaml =
    #|name: T
    #|on: push
    #|jobs:
    #|  build:
    #|    name: B
    #|    runs-on: ubuntu-slim
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
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
    ],
  })
}
