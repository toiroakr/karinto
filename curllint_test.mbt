// Blackbox tests for the curllint library.
//
// Each test loads a YAML fixture and snapshots the diagnostic JSON output.
// Tests for rules that are not implemented yet are kept skipped (`#skip`)
// so the desired behaviour is documented up-front.

///|
fn lint_json(content : String, kind? : @curllint.FileKind = Unknown) -> Json {
  @curllint.lint(content, kind~).to_json()
}

// ---------------------------------------------------------------------------
// Implemented rules
// ---------------------------------------------------------------------------

///|
test "act-id-unique: duplicate job ids (case-insensitive)" {
  let yaml =
    #|on: push
    #|jobs:
    #|  Build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 2, "steps": 2, "lines": 14 },
    "diagnostics": [
      {
        "rule": "act-id-unique",
        "severity": "error",
        "message": "duplicate job ID `build` (conflicts with `Build` case-insensitively)",
      },
    ],
  })
}

///|
test "act-id-unique: duplicate step ids" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - id: A
    #|        run: echo a
    #|      - id: a
    #|        run: echo a2
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 2, "lines": 11 },
    "diagnostics": [
      {
        "rule": "act-id-unique",
        "severity": "error",
        "message": "duplicate step ID `a` (conflicts with `A` case-insensitively)",
      },
    ],
  })
}

///|
test "ghl-003: write-all permission rejected at workflow scope" {
  let yaml =
    #|on: push
    #|permissions: write-all
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 7 },
    "diagnostics": [
      {
        "rule": "ghl-003",
        "severity": "error",
        "message": "workflow: `permissions: write-all` is forbidden",
      },
    ],
  })
}

///|
test "ghl-001: missing job permissions" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 6 },
    "diagnostics": [
      {
        "rule": "ghl-001",
        "severity": "warning",
        "message": "job `build` does not declare `permissions:`",
      },
    ],
  })
}

///|
test "ghl-001: satisfied when workflow-level permissions present" {
  let yaml =
    #|on: push
    #|permissions:
    #|  contents: read
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo hi
  json_inspect(lint_json(yaml), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 8 },
    "diagnostics": [],
  })
}

///|
test "disable: skip a rule with a glob pattern" {
  let yaml =
    #|on: push
    #|permissions: write-all
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo hi
  let res = @curllint.lint(yaml, disabled=["ghl-*"])
  json_inspect(res.to_json(), content={
    "kind": "workflow",
    "stats": { "jobs": 1, "steps": 1, "lines": 7 },
    "diagnostics": [],
  })
}

///|
test "parse error: malformed YAML is surfaced" {
  let yaml = "on: [push\njobs:\n  build:\n    steps: []"
  let res = @curllint.lint(yaml)
  json_inspect(res.parse_error is Some(_), content=true)
  json_inspect(res.diagnostics.length(), content=0)
}

// ---------------------------------------------------------------------------
// Not-yet-implemented rules — fixtures kept skipped on purpose.
// Each test below states the *expected* future behaviour.
// ---------------------------------------------------------------------------

///|
#skip("not implemented yet")
test "skip: ziz-unpinned-uses — `uses:` without full SHA pin" {
  // Plan: error when uses references a tag/branch instead of a 40-char SHA.
  fail("not implemented yet (ziz-unpinned-uses)")
}

///|
#skip("not implemented yet")
test "skip: act-script-injection — github.event.* used in run scripts" {
  fail("not implemented yet (act-script-injection / ziz-template-injection)")
}

///|
#skip("not implemented yet")
test "skip: ziz-excessive-permissions — overly broad permissions" {
  fail("not implemented yet (ziz-excessive-permissions)")
}

///|
#skip("not implemented yet")
test "skip: ghl-004 — `secrets: inherit` in reusable workflow call" {
  fail("not implemented yet (ghl-004 / ziz-secrets-inherit)")
}

///|
#skip("not implemented yet")
test "skip: act-action-format — owner/repo@ref syntax" {
  fail("not implemented yet (act-action-format)")
}

///|
#skip("not implemented yet")
test "skip: act-cron — invalid cron expression" {
  fail("not implemented yet (act-cron)")
}

///|
#skip("not implemented yet")
test "skip: ghl-007 — container image uses `:latest`" {
  fail("not implemented yet (ghl-007)")
}

///|
#skip("not implemented yet")
test "skip: ghl-008 — uses must be pinned to full SHA" {
  fail("not implemented yet (ghl-008)")
}

///|
#skip("not implemented yet")
test "skip: ghl-011 — timeout-minutes required" {
  fail("not implemented yet (ghl-011)")
}

///|
#skip("not implemented yet")
test "skip: ghl-012 — checkout persist-credentials must be false" {
  fail("not implemented yet (ghl-012)")
}

///|
#skip("not implemented yet")
test "skip: ziz-dangerous-triggers — pull_request_target" {
  fail("not implemented yet (ziz-dangerous-triggers)")
}

///|
#skip("not implemented yet")
test "skip: ziz-secrets-outside-env — secrets used without environment" {
  fail("not implemented yet (ziz-secrets-outside-env)")
}

///|
#skip("not implemented yet")
test "skip: ziz-github-env — writes to $GITHUB_ENV" {
  fail("not implemented yet (ziz-github-env)")
}

///|
#skip("not implemented yet")
test "skip: ziz-artipacked — persist-credentials defaults" {
  fail("not implemented yet (ziz-artipacked)")
}

///|
#skip("not implemented yet")
test "skip: act-permissions — invalid permission scope/value" {
  fail("not implemented yet (act-permissions)")
}

///|
#skip("not implemented yet")
test "skip: act-runner-label — unknown runner label" {
  fail("not implemented yet (act-runner-label)")
}

///|
#skip("not implemented yet")
test "skip: act-expr-syntax — malformed ${{ }} expression" {
  fail("not implemented yet (act-expr-syntax)")
}

///|
#skip("not implemented yet")
test "skip: act-expr-contexts — unknown context name" {
  fail("not implemented yet (act-expr-contexts)")
}

///|
#skip("not implemented yet")
test "skip: act-job-needs — undefined dependency in needs" {
  fail("not implemented yet (act-job-needs)")
}

///|
#skip("not implemented yet")
test "skip: act-job-needs — cycle in needs graph" {
  fail("not implemented yet (act-job-needs)")
}

///|
#skip("not implemented yet")
test "skip: act-matrix — duplicate matrix values" {
  fail("not implemented yet (act-matrix)")
}

///|
#skip("not implemented yet")
test "skip: act-webhook-events — unknown event filter" {
  fail("not implemented yet (act-webhook-events)")
}

///|
#skip("not implemented yet")
test "skip: act-workflow-dispatch — bad input type" {
  fail("not implemented yet (act-workflow-dispatch)")
}

///|
#skip("not implemented yet")
test "skip: act-credentials — hardcoded container credentials" {
  fail(
    "not implemented yet (act-credentials / ziz-hardcoded-container-credentials)",
  )
}

///|
#skip("not implemented yet")
test "skip: act-env-var-name — invalid env var name" {
  fail("not implemented yet (act-env-var-name)")
}

///|
#skip("not implemented yet")
test "skip: act-shell-name — invalid shell for OS" {
  fail("not implemented yet (act-shell-name)")
}

///|
#skip("not implemented yet")
test "skip: act-deprecated-cmds — uses ::set-output" {
  fail("not implemented yet (act-deprecated-cmds)")
}

///|
#skip("not implemented yet")
test "skip: act-action-outdated — node16 runtime" {
  fail("not implemented yet (act-action-outdated)")
}

///|
#skip("not implemented yet")
test "skip: act-glob — invalid glob in paths filter" {
  fail("not implemented yet (act-glob)")
}

///|
#skip("not implemented yet")
test "skip: act-required-keys — missing top-level `on`" {
  fail("not implemented yet (act-required-keys)")
}

///|
#skip("not implemented yet")
test "skip: act-empty-mappings — empty jobs block" {
  fail("not implemented yet (act-empty-mappings)")
}

///|
#skip("not implemented yet")
test "skip: act-reusable-workflow — bad inputs/outputs" {
  fail("not implemented yet (act-reusable-workflow)")
}

///|
#skip("not implemented yet")
test "skip: act-action-metadata — invalid action.yml" {
  fail("not implemented yet (act-action-metadata)")
}

///|
#skip("not implemented yet")
test "skip: ghl-002 — `read-all` permission forbidden" {
  fail("not implemented yet (ghl-002)")
}

///|
#skip("not implemented yet")
test "skip: ghl-005 — secrets in workflow-level env" {
  fail("not implemented yet (ghl-005)")
}

///|
#skip("not implemented yet")
test "skip: ghl-006 — secrets in job-level env" {
  fail("not implemented yet (ghl-006)")
}

///|
#skip("not implemented yet")
test "skip: ziz-cache-poisoning — cache key in release flow" {
  fail("not implemented yet (ziz-cache-poisoning)")
}

///|
#skip("not implemented yet")
test "skip: ziz-bot-conditions — spoofable github.actor bot check" {
  fail("not implemented yet (ziz-bot-conditions)")
}

///|
#skip("not implemented yet")
test "skip: ziz-impostor-commit — SHA not in claimed repo (requires network)" {
  fail("not implemented yet (ziz-impostor-commit; offline mode)")
}

///|
#skip("not implemented yet")
test "skip: ziz-known-vulnerable-actions — CVE-listed actions" {
  fail("not implemented yet (ziz-known-vulnerable-actions)")
}

///|
#skip("not implemented yet")
test "skip: ziz-unpinned-images — container image not pinned by SHA" {
  fail("not implemented yet (ziz-unpinned-images)")
}

///|
#skip("not implemented yet")
test "skip: ziz-self-hosted-runner — warns on self-hosted" {
  fail("not implemented yet (ziz-self-hosted-runner)")
}

///|
#skip("not implemented yet")
test "skip: ziz-overprovisioned-secrets — secrets context exposed wholesale" {
  fail("not implemented yet (ziz-overprovisioned-secrets)")
}

///|
#skip("not implemented yet")
test "skip: ziz-anonymous-definition — workflow/action missing name" {
  fail("not implemented yet (ziz-anonymous-definition)")
}

///|
#skip("not implemented yet")
test "skip: ziz-concurrency-limits — missing concurrency block" {
  fail("not implemented yet (ziz-concurrency-limits)")
}
