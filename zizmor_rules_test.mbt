// Fixture + expected-JSON tests for the zizmor-derived rule family.
//
// Every test below is `#skip("not implemented yet")` until the matching
// audit ships. IDs match the upstream zizmor audit names exactly (no
// prefix); the catalogue's `origins` field preserves the zizmor lineage.

///|
#skip("not implemented yet")
test "anonymous-definition: workflow has no top-level `name`" {
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
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "workflow has no `name:`",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "archived-uses: action repo is archived" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: deprecated-org/abandoned-action@v1
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 8 },
    "diagnostics": [
      {
        "rule": "archived-uses",
        "severity": "warning",
        "message": "uses `deprecated-org/abandoned-action`: repository is archived",
      },
    ],
  })
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
        "rule": "checkout-persist-credentials-false",
        "severity": "error",
        "message": "actions/checkout requires `persist-credentials: false` to avoid token leakage",
      },
      {
        "rule": "artipacked",
        "severity": "error",
        "message": "checkout persists credentials before upload-artifact; set `persist-credentials: false`",
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
        "rule": "bot-conditions",
        "severity": "error",
        "message": "`github.actor` is spoofable; use `github.event.pull_request.user.login` and verify",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "cache-poisoning: cache restore in publish flow" {
  let yaml =
    #|on:
    #|  push:
    #|    tags: ["v*"]
    #|jobs:
    #|  release:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: write
    #|    steps:
    #|      - uses: actions/cache@v4
    #|        with:
    #|          path: dist
    #|          key: build
    #|      - run: ./publish.sh
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 2, "lines": 14 },
    "diagnostics": [
      {
        "rule": "cache-poisoning",
        "severity": "error",
        "message": "release-publishing job restores from cache; risk of cache poisoning",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "concurrency-limits: no concurrency on deploy workflow" {
  let yaml =
    #|on:
    #|  push:
    #|    branches: [main]
    #|jobs:
    #|  deploy:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: ./deploy.sh
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 10 },
    "diagnostics": [
      {
        "rule": "concurrency-limits",
        "severity": "info",
        "message": "workflow has no `concurrency:` block",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "dangerous-triggers: workflow uses pull_request_target" {
  let yaml =
    #|on: pull_request_target
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 7 },
    "diagnostics": [
      {
        "rule": "dangerous-triggers",
        "severity": "error",
        "message": "trigger `pull_request_target` runs with write access to the base repo",
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
        "message": "dependabot update has no `cooldown:` configured",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "dependabot-execution: dependabot trigger runs external code" {
  let yaml =
    #|on:
    #|  pull_request:
    #|    branches: [main]
    #|jobs:
    #|  test:
    #|    if: github.actor == 'dependabot[bot]'
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/checkout@v4
    #|        with:
    #|          ref: ${{ github.event.pull_request.head.sha }}
    #|      - run: npm install && npm test
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 2, "lines": 14 },
    "diagnostics": [
      {
        "rule": "dependabot-execution",
        "severity": "error",
        "message": "dependabot PR head SHA is checked out and code is executed without review",
      },
    ],
  })
}

///|
test "excessive-permissions: job grants more than it needs" {
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
        "message": "job `build` grants 4 write permissions; consider narrowing the scope",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "forbidden-uses: action not in allowlist" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: third-party/disallowed-action@v1
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 8 },
    "diagnostics": [
      {
        "rule": "forbidden-uses",
        "severity": "warning",
        "message": "uses `third-party/disallowed-action`: not in the allowlist",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "github-app: GitHub App token exchanged at workflow scope" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - id: token
    #|        uses: tibdex/github-app-token@v2
    #|      - run: echo "${{ steps.token.outputs.token }}"
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 2, "lines": 10 },
    "diagnostics": [
      {
        "rule": "github-app",
        "severity": "warning",
        "message": "GitHub App token is interpolated into a shell command",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "github-env: write to $GITHUB_ENV from untrusted input" {
  let yaml =
    #|on: pull_request_target
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo "TITLE=${{ github.event.pull_request.title }}" >> $GITHUB_ENV
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 7 },
    "diagnostics": [
      {
        "rule": "github-env",
        "severity": "error",
        "message": "untrusted `github.event.pull_request.title` written to `$GITHUB_ENV`",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "hardcoded-container-credentials: plain password in container" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    container:
    #|      image: ghcr.io/org/private:1
    #|      credentials:
    #|        username: bot
    #|        password: hunter2
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 12 },
    "diagnostics": [
      {
        "rule": "hardcoded-container-credentials",
        "severity": "error",
        "message": "container `credentials.password` is a literal; reference `${{ secrets.* }}` instead",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "impostor-commit: SHA pin not present in claimed repo" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/checkout@deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 7 },
    "diagnostics": [
      {
        "rule": "impostor-commit",
        "severity": "error",
        "message": "uses `actions/checkout@deadbeef…`: SHA does not exist in `actions/checkout`",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "insecure-commands: ACTIONS_ALLOW_UNSECURE_COMMANDS is set" {
  let yaml =
    #|on: push
    #|env:
    #|  ACTIONS_ALLOW_UNSECURE_COMMANDS: "true"
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo "::set-env name=X::1"
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 10 },
    "diagnostics": [
      {
        "rule": "insecure-commands",
        "severity": "warning",
        "message": "`ACTIONS_ALLOW_UNSECURE_COMMANDS=true` re-enables legacy workflow commands",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "known-vulnerable-actions: CVE-listed action version pinned" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: tj-actions/changed-files@v35
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 8 },
    "diagnostics": [
      {
        "rule": "known-vulnerable-actions",
        "severity": "error",
        "message": "uses `tj-actions/changed-files@v35`: known compromised release",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "misfeature: continue-on-error masks real failures" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    continue-on-error: true
    #|    steps:
    #|      - run: ./tests.sh
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 8 },
    "diagnostics": [
      {
        "rule": "misfeature",
        "severity": "info",
        "message": "job `build` has `continue-on-error: true`; failures will be hidden",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "obfuscation: hex-encoded uses ref" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/checkout@%76%34
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 7 },
    "diagnostics": [
      {
        "rule": "obfuscation",
        "severity": "warning",
        "message": "uses ref contains percent-encoded characters; possible obfuscation",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "overprovisioned-secrets: whole `secrets` context injected" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    env:
    #|      SECRETS: ${{ toJSON(secrets) }}
    #|    steps:
    #|      - run: echo "$SECRETS"
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 10 },
    "diagnostics": [
      {
        "rule": "overprovisioned-secrets",
        "severity": "warning",
        "message": "`toJSON(secrets)` exposes every secret; reference specific keys",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "ref-confusion: tag and branch share a name" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: org/repo@main
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 7 },
    "diagnostics": [
      {
        "rule": "ref-confusion",
        "severity": "warning",
        "message": "ref `main` is both a branch and a tag in `org/repo`",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "ref-version-mismatch: comment claims v5 but SHA is from v4" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v5
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 7 },
    "diagnostics": [
      {
        "rule": "ref-version-mismatch",
        "severity": "warning",
        "message": "pinned SHA does not match the tag in the trailing comment (`v5`)",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "secrets-inherit: reusable workflow call uses `secrets: inherit`" {
  let yaml =
    #|on: push
    #|jobs:
    #|  call:
    #|    uses: org/repo/.github/workflows/build.yml@v1
    #|    secrets: inherit
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 0, "lines": 5 },
    "diagnostics": [
      {
        "rule": "secrets-inherit",
        "severity": "error",
        "message": "job `call`: `secrets: inherit` forwards every secret",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "secrets-outside-env: secrets accessed without an environment" {
  let yaml =
    #|on: push
    #|jobs:
    #|  deploy:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: ./deploy.sh "${{ secrets.PROD_TOKEN }}"
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 8 },
    "diagnostics": [
      {
        "rule": "secrets-outside-env",
        "severity": "warning",
        "message": "job `deploy` uses `secrets.*` without protecting it with `environment:`",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "self-hosted-runner: job runs on self-hosted runner" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: [self-hosted, linux]
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 8 },
    "diagnostics": [
      {
        "rule": "self-hosted-runner",
        "severity": "warning",
        "message": "job `build` runs on a self-hosted runner",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "stale-action-refs: SHA pin has no matching tag" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/checkout@1234567890abcdef1234567890abcdef12345678
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 7 },
    "diagnostics": [
      {
        "rule": "stale-action-refs",
        "severity": "info",
        "message": "pinned SHA `1234567…` has no matching tag in `actions/checkout`",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "superfluous-actions: setup-node duplicated across steps" {
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
    #|      - uses: actions/setup-node@v4
    #|        with:
    #|          node-version: 22
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 2, "lines": 12 },
    "diagnostics": [
      {
        "rule": "superfluous-actions",
        "severity": "info",
        "message": "job `build` uses `actions/setup-node` twice",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "template-injection: untrusted input in run script" {
  let yaml =
    #|on: pull_request_target
    #|jobs:
    #|  echo:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo "${{ github.event.pull_request.body }}"
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 7 },
    "diagnostics": [
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
#skip("not implemented yet")
test "unpinned-images: container image uses a floating tag" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    container: node:20
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 8 },
    "diagnostics": [
      {
        "rule": "unpinned-images",
        "severity": "warning",
        "message": "container image `node:20` is not pinned by digest",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "unpinned-tools: pipe-to-shell installer in run" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: curl -fsSL https://example.com/install.sh | bash
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 7 },
    "diagnostics": [
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
        "rule": "unpinned-uses",
        "severity": "warning",
        "message": "uses `actions/checkout@v4` is not pinned to a full-length SHA",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "unredacted-secrets: secret length manipulated before logging" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: |
    #|          echo "${{ secrets.TOKEN }}" | base64
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 9 },
    "diagnostics": [
      {
        "rule": "unredacted-secrets",
        "severity": "error",
        "message": "secret is transformed (base64) before logging; redaction will fail",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "unsound-condition: `always() && success()` is always true" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - if: ${{ always() && success() }}
    #|        run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 9 },
    "diagnostics": [
      {
        "rule": "unsound-condition",
        "severity": "warning",
        "message": "`always() && success()` is always equivalent to `always()`",
      },
    ],
  })
}

///|
#skip("not implemented yet")
test "unsound-contains: contains() with literal arg order swapped" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - if: ${{ contains('main', github.ref) }}
    #|        run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 9 },
    "diagnostics": [
      {
        "rule": "unsound-contains",
        "severity": "warning",
        "message": "`contains('main', github.ref)` arguments look swapped",
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
    #|    steps:
    #|      - uses: pypa/gh-action-pypi-publish@76f52bc884231f62b9a034ebfe128415bbaabdfc
    #|        with:
    #|          password: ${{ secrets.PYPI_TOKEN }}
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 13 },
    "diagnostics": [
      {
        "rule": "use-trusted-publishing",
        "severity": "info",
        "message": "PyPI publish uses an API token; prefer OIDC trusted publishing",
      },
    ],
  })
}
