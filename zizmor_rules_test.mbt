// Fixture + expected-JSON tests for the zizmor-derived rule family.
//
// Every test below is `#skip("not implemented yet")` until the matching
// audit ships. IDs match the upstream zizmor audit names exactly (no
// prefix); the catalogue's `origins` field preserves the zizmor lineage.

///|
test "anonymous-definition: workflow has no top-level `name`" {
  let yaml =
    #|on: push
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
      },
    ],
  })
}

///|
test "anonymous-definition: workflow with explicit name is silent when jobs have names" {
  let yaml =
    #|name: build
    #|on: push
    #|jobs:
    #|  build:
    #|    name: Build everything
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
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
    ],
  })
}

///|
/// karinto carries a small hardcoded baseline that mirrors zizmor's offline
/// detection (today: `actions/setup-ruby`). The Worker may extend it via
/// `archived_uses=` once GitHub responds with `archived: true`. The
/// comparison is case-insensitive (zizmor fires on `ACTIONS/SETUP-RUBY` too).
test "archived-uses: hardcoded baseline fires on actions/setup-ruby" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/setup-ruby@e932e7af67fc4a8fc77bd86b744acd4e42fe3543
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "archived-uses" })
  inspect(hits.length(), content="1")
}

///|
test "archived-uses: caller-supplied list extends the baseline" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: my-org/legacy-action@v1
  let res = @karinto.lint(yaml, archived_uses=["my-org/legacy-action"])
  let hits = res.diagnostics.filter(fn(d) { d.rule == "archived-uses" })
  inspect(hits.length(), content="1")
}

///|
test "archived-uses: dormant on non-listed repos" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/checkout@v4
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "archived-uses" })
  inspect(hits.length(), content="0")
}

///|
test "artipacked: actions/checkout leaves credentials persisted" {
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
    #|      - uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02
    #|        with:
    #|          path: .
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 2, "lines": 12 },
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

///|
test "bot-conditions: spoofable github.actor bot check" {
  let yaml =
    #|on: pull_request
    #|jobs:
    #|  auto:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    if: github.actor == 'dependabot[bot]'
    #|    steps:
    #|      - run: echo trust
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
        "message": "job `auto` has no `name:`",
      },
      {
        "rule": "bot-conditions",
        "severity": "error",
        "message": "`github.actor` is spoofable; use `github.event.pull_request.user.login` and verify",
      },
    ],
  })
}

///|
test "cache-poisoning: cache restore in publish flow" {
  let yaml =
    #|on:
    #|  push:
    #|    tags: ["v*"]
    #|jobs:
    #|  release:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: write
    #|    steps:
    #|      - uses: actions/cache@13aacd865c20de90d75de3b17ebe84f7a17d57d2
    #|        with:
    #|          path: dist
    #|          key: build
    #|      - run: ./publish.sh
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 2, "lines": 15 },
    "diagnostics": [
      {
        "rule": "excessive-permissions",
        "severity": "warning",
        "message": "default permissions used due to no permissions: block",
      },
      {
        "rule": "cache-poisoning",
        "severity": "error",
        "message": "runtime artifacts potentially vulnerable to a cache poisoning attack",
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
        "message": "job `release` has no `name:`",
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
test "concurrency-limits: no concurrency on deploy workflow" {
  let yaml =
    #|on:
    #|  push:
    #|    branches: [main]
    #|jobs:
    #|  deploy:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: ./deploy.sh
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
        "message": "job `deploy` has no `name:`",
      },
    ],
  })
}

///|
test "dangerous-triggers: workflow uses pull_request_target" {
  let yaml =
    #|on: pull_request_target
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
    "stats": { "jobs": 1, "steps": 1, "lines": 9 },
    "diagnostics": [
      {
        "rule": "dangerous-triggers",
        "severity": "error",
        "message": "trigger `pull_request_target` runs with write access to the base repo",
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
      },
    ],
  })
}

///|
test "dependabot-cooldown: dependabot.yml missing cooldown" {
  let yaml =
    #|version: 2
    #|updates:
    #|  - package-ecosystem: npm
    #|    directory: /
    #|    schedule:
    #|      interval: daily
  json_inspect(lint_json(yaml), content={
    "kind": "unknown",
    "stats": { "jobs": 0, "steps": 0, "lines": 6 },
    "diagnostics": [
      {
        "rule": "dependabot-cooldown",
        "severity": "info",
        "message": "missing cooldown configuration",
      },
    ],
  })
}

///|
test "dependabot-execution: insecure-external-code-execution allowed" {
  let yaml =
    #|version: 2
    #|updates:
    #|  - package-ecosystem: pip
    #|    directory: /
    #|    schedule:
    #|      interval: daily
    #|    insecure-external-code-execution: allow
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "dependabot-execution" })
  inspect(hits.length(), content="1")
}

///|
test "dependabot-execution: deny is safe" {
  let yaml =
    #|version: 2
    #|updates:
    #|  - package-ecosystem: pip
    #|    directory: /
    #|    schedule:
    #|      interval: daily
    #|    insecure-external-code-execution: deny
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "dependabot-execution" })
  inspect(hits.length(), content="0")
}

///|
test "excessive-permissions: workflow without `permissions:` block emits default-token finding" {
  // Upstream punts on per-key analysis for *job-level* Explicit maps
  // (`check_job_permissions` returns `None` for `Permissions::Explicit`).
  // The only excessive-permissions hit here is therefore the workflow-level
  // one for the missing parent `permissions:`.
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: write
    #|      actions: write
    #|      packages: write
    #|      id-token: write
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
        "rule": "undocumented-permissions",
        "severity": "info",
        "message": "permissions block has 4 entry/entries without explanatory comments",
      },
    ],
  })
}

///|
test "excessive-permissions: workflow-level explicit `write` keys each fire" {
  let yaml =
    #|on: push
    #|name: workflow-write-explicit
    #|permissions:
    #|  contents: write
    #|  id-token: write
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "excessive-permissions" })
  inspect(hits.length(), content="2")
}

///|
test "excessive-permissions: workflow `permissions: {}` silences all jobs" {
  let yaml =
    #|on: push
    #|name: workflow-empty-perms
    #|permissions: {}
    #|jobs:
    #|  job1:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo hi
    #|  job2:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo hi
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "excessive-permissions" })
  inspect(hits.length(), content="0")
}

///|
test "forbidden-uses: action matches caller-supplied denylist" {
  // karinto threads the denylist through the worker boundary as a CSV
  // (`?forbidden=…`). When the caller doesn't supply one, the rule is
  // dormant — matching zizmor's "no config → silent" default.
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: third-party/disallowed-action@v1
  let res = @karinto.lint(yaml, forbidden_uses=["third-party/*"], disabled=[
    "unpinned-uses",
  ])
  let hits = res.diagnostics.filter(fn(d) { d.rule == "forbidden-uses" })
  inspect(hits.length(), content="1")
}

///|
test "forbidden-uses: dormant when no denylist provided" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: third-party/disallowed-action@v1
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "forbidden-uses" })
  inspect(hits.length(), content="0")
}

///|
test "github-app: skip-token-revoke true, owner-without-repositories, missing permission-*" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/create-github-app-token@1b10c78c7865c340bc4f6099eb2f838309f1e8c3
    #|        with:
    #|          skip-token-revoke: true
    #|          owner: github
    #|          client-id: ${{ vars.APP_ID }}
    #|          private-key: ${{ secrets.APP_KEY }}
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "github-app" })
  inspect(hits.length(), content="3")
}

///|
test "github-app: scoped properly is silent" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/create-github-app-token@1b10c78c7865c340bc4f6099eb2f838309f1e8c3
    #|        with:
    #|          owner: github
    #|          repositories: github/docs
    #|          permission-issues: write
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "github-app" })
  inspect(hits.length(), content="0")
}

///|
test "github-env: write to $GITHUB_ENV from untrusted input" {
  let yaml =
    #|on: pull_request_target
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo "TITLE=${{ github.event.pull_request.title }}" >> $GITHUB_ENV
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 9 },
    "diagnostics": [
      {
        "rule": "dangerous-triggers",
        "severity": "error",
        "message": "trigger `pull_request_target` runs with write access to the base repo",
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
      },
      {
        "rule": "template-injection",
        "severity": "error",
        "message": "untrusted `github.event.pull_request.title` interpolated into `run:` script",
      },
      {
        "rule": "github-env",
        "severity": "error",
        "message": "write to `GITHUB_ENV` may allow code execution",
      },
    ],
  })
}

///|
test "hardcoded-container-credentials: plain password in container" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    container:
    #|      image: ghcr.io/org/private@sha256:abc
    #|      credentials:
    #|        username: bot
    #|        password: hunter2
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 14 },
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
      },
      {
        "rule": "hardcoded-container-credentials",
        "severity": "error",
        "message": "container `credentials.password` is a literal; reference `${{ secrets.* }}` instead",
      },
    ],
  })
}

///|
/// Confirming a SHA does NOT belong to the claimed repository requires a
/// GitHub API call, which the linter cannot do offline. Mirrors zizmor's
/// `--no-online-audits` behaviour: silent unless the Worker resolves the
/// ref externally and threads the confirmed-impostor list through
/// `impostor_uses=`.
test "impostor-commit: silent without caller-supplied impostor list" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/checkout@deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "impostor-commit" })
  inspect(hits.length(), content="0")
}

///|
test "impostor-commit: fires when caller marks ref as impostor" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/checkout@deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  let res = @karinto.lint(yaml, impostor_uses=[
    "actions/checkout@deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
  ])
  let hits = res.diagnostics.filter(fn(d) { d.rule == "impostor-commit" })
  inspect(hits.length(), content="1")
}

///|
test "insecure-commands: ACTIONS_ALLOW_UNSECURE_COMMANDS is set" {
  let yaml =
    #|on: push
    #|env:
    #|  ACTIONS_ALLOW_UNSECURE_COMMANDS: "true"
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo "::set-env name=X::1"
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 11 },
    "diagnostics": [
      {
        "rule": "insecure-commands",
        "severity": "warning",
        "message": "`ACTIONS_ALLOW_UNSECURE_COMMANDS=true` re-enables legacy workflow commands",
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
      },
      {
        "rule": "deprecated-workflow-commands",
        "severity": "warning",
        "message": "deprecated workflow command `::set-env`; use `$GITHUB_ENV` instead",
      },
    ],
  })
}

///|
test "known-vulnerable-actions: CVE-listed action version pinned" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: tj-actions/changed-files@v35
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
      },
      {
        "rule": "unpinned-uses",
        "severity": "warning",
        "message": "uses `tj-actions/changed-files@v35` is not pinned to a full-length SHA",
      },
      {
        "rule": "known-vulnerable-actions",
        "severity": "error",
        "message": "uses `tj-actions/changed-files@v35`: known compromised release",
      },
    ],
  })
}

///|
test "known-vulnerable-actions: OSV-supplied via context list" {
  // actions/checkout@v3 is not in the hardcoded list — only the caller
  // (worker → OSV.dev) decides whether it is vulnerable today.
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/checkout@v3
  let res = @karinto.lint(yaml, vuln_uses=["actions/checkout@v3"], disabled=[
    "unpinned-uses", "checkout-persist-credentials-false",
  ])
  let hits = res.diagnostics.filter(fn(d) {
    d.rule == "known-vulnerable-actions"
  })
  inspect(hits.length(), content="1")
}

///|
test "misfeature: continue-on-error masks real failures" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    continue-on-error: true
    #|    steps:
    #|      - run: ./tests.sh
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
      },
      {
        "rule": "misfeature",
        "severity": "info",
        "message": "job `build` has `continue-on-error: true`; failures will be hidden",
      },
    ],
  })
}

///|
test "obfuscation: hex-encoded uses ref" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/checkout@%76%34
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
      },
      {
        "rule": "checkout-persist-credentials-false",
        "severity": "error",
        "message": "actions/checkout requires `persist-credentials: false` to avoid token leakage",
      },
      {
        "rule": "unpinned-uses",
        "severity": "warning",
        "message": "uses `actions/checkout@%76%34` is not pinned to a full-length SHA",
      },
      {
        "rule": "obfuscation",
        "severity": "info",
        "message": "uses ref contains percent-encoded characters; possible obfuscation",
      },
      {
        "rule": "artipacked",
        "severity": "warning",
        "message": "credential persistence through GitHub Actions artifacts: does not set persist-credentials: false",
      },
    ],
  })
}

///|
test "overprovisioned-secrets: whole `secrets` context injected" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    env:
    #|      SECRETS: ${{ toJSON(secrets) }}
    #|    steps:
    #|      - run: echo "$SECRETS"
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
      },
      {
        "rule": "overprovisioned-secrets",
        "severity": "warning",
        "message": "`toJSON(secrets)` exposes every secret; reference specific keys",
      },
    ],
  })
}

// `ref-confusion` is catalogued as NotPlanned — karinto's `unpinned-uses`
// already mandates SHA pins, so confusable tag/branch refs cannot occur in
// compliant workflows. See rules_catalog.mbt.

///|
/// Resolving `tag → SHA` to confirm a mismatch with the trailing `# vN`
/// comment requires a GitHub API call. Mirrors zizmor's
/// `--no-online-audits` behaviour: silent unless the Worker threads the
/// confirmed-mismatch list through `ref_mismatches=`.
test "ref-version-mismatch: silent without caller-supplied mismatch list" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v5
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "ref-version-mismatch" })
  inspect(hits.length(), content="0")
}

///|
test "ref-version-mismatch: fires when caller marks ref as mismatched" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v5
  let res = @karinto.lint(yaml, ref_mismatches=[
    "actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  ])
  let hits = res.diagnostics.filter(fn(d) { d.rule == "ref-version-mismatch" })
  inspect(hits.length(), content="1")
}

///|
test "secrets-inherit: reusable workflow call uses `secrets: inherit`" {
  let yaml =
    #|on: push
    #|permissions:
    #|  contents: read
    #|jobs:
    #|  call:
    #|    uses: org/repo/.github/workflows/build.yml@v1
    #|    secrets: inherit
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 0, "lines": 7 },
    "diagnostics": [
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
      {
        "rule": "secrets-inherit",
        "severity": "error",
        "message": "job `call`: `secrets: inherit` forwards every secret",
      },
    ],
  })
}

///|
test "secrets-outside-env: secrets accessed without an environment" {
  let yaml =
    #|on: push
    #|jobs:
    #|  deploy:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: ./deploy.sh "${{ secrets.PROD_TOKEN }}"
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
        "message": "job `deploy` has no `name:`",
      },
      {
        "rule": "secrets-outside-env",
        "severity": "warning",
        "message": "job `deploy` uses `secrets.*` without protecting it with `environment:`",
      },
    ],
  })
}

///|
test "self-hosted-runner: job runs on self-hosted runner" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: [self-hosted, linux]
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
      },
      {
        "rule": "self-hosted-runner",
        "severity": "warning",
        "message": "job `build` runs on a self-hosted runner",
      },
    ],
  })
}

// `stale-action-refs` is catalogued as NotPlanned — would require a
// GitHub API call to enumerate tags reachable from a SHA, and the upstream
// signal is only informational. See rules_catalog.mbt.

///|
test "superfluous-actions: dtolnay/rust-toolchain flagged" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: dtolnay/rust-toolchain@086dfa4efe372cfb6b375460a56e26a62a873d2e
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
      },
      {
        "rule": "superfluous-actions",
        "severity": "info",
        "message": "step uses `dtolnay/rust-toolchain` — use `rustup` and/or `cargo` in a script step",
      },
    ],
  })
}

///|
test "template-injection: untrusted input in run script" {
  let yaml =
    #|on: pull_request
    #|jobs:
    #|  echo:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo "${{ github.event.pull_request.body }}"
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
        "message": "job `echo` has no `name:`",
      },
      {
        "rule": "template-injection",
        "severity": "error",
        "message": "untrusted `github.event.pull_request.body` interpolated into `run:` script",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "undocumented-permissions: permissions block has no comment" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: write
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 7 },
    "diagnostics": [
      {
        "rule": "undocumented-permissions",
        "severity": "info",
        "message": "`permissions: contents: write` has no justifying comment",
      },
    ],
  })
}

///|
test "unpinned-images: container image uses a floating tag" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    container: node:20
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
      },
      {
        "rule": "unpinned-images",
        "severity": "warning",
        "message": "container image `node:20` is not pinned by digest",
      },
    ],
  })
}

///|
test "unpinned-tools: pipe-to-shell installer in run" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: curl -fsSL https://example.com/install.sh | bash
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
      },
      {
        "rule": "unpinned-tools",
        "severity": "warning",
        "message": "run step fetches and executes an external script without pinning",
      },
    ],
  })
}

///|
test "unpinned-uses: tag/branch ref instead of full SHA" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/checkout@v4
    #|        with:
    #|          persist-credentials: false
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
      },
      {
        "rule": "unpinned-uses",
        "severity": "warning",
        "message": "uses `actions/checkout@v4` is not pinned to a full-length SHA",
      },
    ],
  })
}

///|
test "unredacted-secrets: secret length manipulated before logging" {
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
    #|      - run: |
    #|          echo "${{ secrets.TOKEN }}" | base64
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
      },
      {
        "rule": "unredacted-secrets",
        "severity": "error",
        "message": "secret is transformed (base64) before logging; redaction will fail",
      },
    ],
  })
}

///|
test "unsound-condition: `always() && success()` is always true" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - if: ${{ always() && success() }}
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
        "rule": "unsound-condition",
        "severity": "warning",
        "message": "`always() && success()` is always equivalent to `always()`",
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
test "unsound-contains: contains() with literal arg order swapped" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - if: ${{ contains('main', github.ref) }}
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
        "rule": "unsound-contains",
        "severity": "warning",
        "message": "`contains('main', github.ref)` arguments look swapped",
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
test "use-trusted-publishing: uses long-lived PyPI token" {
  let yaml =
    #|on:
    #|  release:
    #|    types: [published]
    #|jobs:
    #|  publish:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      id-token: write
    #|    environment: pypi
    #|    steps:
    #|      - uses: pypa/gh-action-pypi-publish@76f52bc884231f62b9a034ebfe128415bbaabdfc
    #|        with:
    #|          password: ${{ secrets.PYPI_TOKEN }}
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 14 },
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
        "message": "job `publish` has no `name:`",
      },
      {
        "rule": "undocumented-permissions",
        "severity": "info",
        "message": "permissions block has 1 entry/entries without explanatory comments",
      },
      {
        "rule": "use-trusted-publishing",
        "severity": "info",
        "message": "PyPI publish uses an API token; prefer OIDC trusted publishing",
      },
    ],
  })
}
