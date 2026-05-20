// Fixture + expected-JSON tests for the ghalint-derived rule family.
//
// Every test below is `#skip("not implemented yet")` until the matching
// check ships. The YAML fixtures and expected diagnostics document the
// behaviour we want once each rule is wired up; the rule of thumb is
//   * fixture: smallest workflow that should trip exactly this rule,
//   * expected: single diagnostic, error/warning per the catalogue.

///|
test "permissions-read-all-forbidden: workflow `permissions: read-all` is forbidden" {
  let yaml =
    #|on: push
    #|permissions: read-all
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
        "rule": "permissions-read-all-forbidden",
        "severity": "error",
        "message": "workflow: `permissions: read-all` is forbidden",
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
      },
    ],
  })
}

// `ghl-004` (deny_inherit_secrets) is consolidated into `secrets-inherit`
// (see rules_catalog.mbt). Its fixture lives in zizmor_rules_test.mbt.

///|
test "workflow-env-no-secrets: secrets referenced in workflow-level env" {
  let yaml =
    #|on: push
    #|env:
    #|  TOKEN: ${{ secrets.GITHUB_TOKEN }}
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo $TOKEN
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 11 },
    "diagnostics": [
      {
        "rule": "workflow-env-no-secrets",
        "severity": "error",
        "message": "workflow env `TOKEN` references `secrets.*`; move it to a job/step env",
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
      },
    ],
  })
}

///|
test "job-env-no-secrets: secrets referenced in job-level env" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    env:
    #|      TOKEN: ${{ secrets.GITHUB_TOKEN }}
    #|    steps:
    #|      - run: echo $TOKEN
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 11 },
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
      },
      {
        "rule": "job-env-no-secrets",
        "severity": "error",
        "message": "job `build` env `TOKEN` references `secrets.*`; scope it to the step instead",
      },
    ],
  })
}

// `ghl-007` (deny_job_container_latest_image) is consolidated into
// `unpinned-images`; `ghl-008` (action_ref_should_be_full_length_commit_sha)
// is consolidated into `unpinned-uses`. See rules_catalog.mbt for the
// merged origins; fixtures live in zizmor_rules_test.mbt.

///|
test "github-app-limit-repositories: GitHub App token scoped to whole org" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    environment: prod
    #|    steps:
    #|      - uses: tibdex/github-app-token@aaaabbbbccccddddeeeeffff0000111122223333
    #|        with:
    #|          app_id: 1
    #|          private_key: ${{ secrets.APP_PK }}
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 13 },
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
      },
      {
        "rule": "github-app-limit-repositories",
        "severity": "warning",
        "message": "GitHub App token request is missing `repositories:` scope",
      },
      {
        "rule": "github-app-limit-permissions",
        "severity": "warning",
        "message": "GitHub App token request is missing `permissions:` scope",
      },
    ],
  })
}

///|
test "github-app-limit-permissions: GitHub App token requests no permissions" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    environment: prod
    #|    steps:
    #|      - uses: tibdex/github-app-token@aaaabbbbccccddddeeeeffff0000111122223333
    #|        with:
    #|          app_id: 1
    #|          private_key: ${{ secrets.APP_PK }}
    #|          repositories: my-repo
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 14 },
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
      },
      {
        "rule": "github-app-limit-permissions",
        "severity": "warning",
        "message": "GitHub App token request is missing `permissions:` scope",
      },
    ],
  })
}

///|
test "composite-step-shell-required: composite action step is missing `shell`" {
  let yaml =
    #|name: composite
    #|description: example
    #|runs:
    #|  using: composite
    #|  steps:
    #|    - run: echo hello
  json_inspect(lint_json(yaml, kind=Action), content={
    "kind": "action",
    "stats": { "jobs": 0, "steps": 0, "lines": 6 },
    "diagnostics": [
      {
        "rule": "composite-step-shell-required",
        "severity": "warning",
        "message": "composite action step is missing `shell:`",
      },
    ],
  })
}

///|
test "job-timeout-minutes-required: job is missing `timeout-minutes`" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 8 },
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
      },
      {
        "rule": "job-timeout-minutes-required",
        "severity": "warning",
        "message": "job `build` does not declare `timeout-minutes:`",
      },
    ],
  })
}

///|
test "checkout-persist-credentials-false: actions/checkout `persist-credentials` must be false" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
    #|        with:
    #|          ref: main
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 11 },
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
      },
      {
        "rule": "checkout-persist-credentials-false",
        "severity": "error",
        "message": "actions/checkout requires `persist-credentials: false` to avoid token leakage",
      },
      {
        "rule": "artipacked",
        "severity": "warning",
        "message": "credential persistence through GitHub Actions artifacts: does not set persist-credentials: false",
      },
    ],
  })
}
