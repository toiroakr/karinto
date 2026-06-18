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
        "pos": { "line": 10, "col": 3 },
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
        "pos": { "line": 3, "col": 3 },
        "job": "Build",
      },
      {
        "rule": "anonymous-definition",
        "severity": "info",
        "message": "job `build` has no `name:`",
        "pos": { "line": 10, "col": 3 },
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
        "pos": { "line": 11, "col": 9 },
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
        "pos": { "line": 3, "col": 3 },
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
        "pos": { "line": 4, "col": 3 },
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
        "pos": { "line": 3, "col": 3 },
        "job": "build",
      },
      {
        "rule": "job-permissions-required",
        "severity": "warning",
        "message": "job `build` does not declare `permissions:`",
        "pos": { "line": 3, "col": 3 },
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
        "pos": { "line": 5, "col": 3 },
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
        "pos": { "line": 4, "col": 3 },
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

///|
// Regression: content containing non-BMP characters (emoji are surrogate
// pairs in UTF-16) used to panic. The inline-ignore scanner (`index_of`) and
// the YAML anchor scanner sliced strings at arbitrary code-unit offsets, which
// aborts when a boundary splits a surrogate pair. Linting must complete
// without throwing.
test "non-BMP characters do not crash the scanners" {
  let yaml =
    #|on:
    #|  push:
    #|    branches: &default
    #|      - main
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - name: Dog fooding 🐶 # karinto: ignore[empty-mappings]
    #|        run: echo "🙊"
  let res = @karinto.lint(yaml)
  json_inspect(res.parse_error is None, content=true)
}

///|
test "positions: job key and step line/column" {
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
  let result = @karinto.lint(yaml)
  // Pull out the two findings we can pin to a concrete source location.
  let dup = result.diagnostics.filter(fn(d) {
      d.rule == "duplicate-job-step-ids"
    })[0]
  let job_anon = result.diagnostics.filter(fn(d) {
      d.rule == "anonymous-definition" && d.job is Some(_)
    })[0]
  // Step index 1 is the `- id: a` item; its position is the step content (the
  // `id:` key) on line 11, column 9.
  assert_true(dup.pos is Some({ line: 11, col: 9 }))
  // Job-only finding resolves to the `build:` key on line 3, column 3.
  assert_true(job_anon.pos is Some({ line: 3, col: 3 }))
}

///|
test "positions: block scalars do not desync step indices" {
  // The `run: |` body contains lines that look like list items and keys. The
  // scanner must treat them as scalar content, so the second step still
  // resolves to its real source line.
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: |
    #|          echo hi
    #|          - not a step
    #|          fake: not a key
    #|      - uses: actions/checkout@v4
  let result = @karinto.lint(yaml)
  // The checkout step is index 1 on line 10; positions must not be thrown off
  // by the structure-looking text inside the preceding block scalar. The
  // `uses:`-oriented findings on this step now resolve to the `uses:` value
  // node (col 15 on line 10); either way the line must stay 10.
  let pin = result.diagnostics.filter(fn(d) { d.step is Some({ index: 1, .. }) })
  assert_true(pin.length() > 0)
  for d in pin {
    assert_true(d.pos is Some({ line: 10, .. }))
  }
}

///|
test "positions: multi-line field values point at the key" {
  // `run: |` puts the script on following lines; the annotation should land
  // on the `run` key itself rather than the first body line.
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: |
    #|          echo "${{ github.event.issue.title }}"
  let res = @karinto.lint(yaml)
  let ti = res.diagnostics.filter(fn(d) { d.rule == "template-injection" })
  assert_true(ti.length() > 0)
  assert_true(ti[0].pos is Some({ line: 6, col: 9 }))
}

///|
test "inline ignore: line-scoped, not file-global" {
  // Two steps trip `template-injection`; only the first carries an inline
  // ignore. A line-scoped ignore must suppress that one finding while the
  // second (uncommented) step still reports — a file-global ignore would
  // wrongly silence both.
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo "${{ github.event.issue.title }}" # zizmor: ignore[template-injection]
    #|      - run: echo "${{ github.event.issue.body }}"
  let res = @karinto.lint(yaml)
  let ti = res.diagnostics.filter(fn(d) { d.rule == "template-injection" })
  // Exactly the second step survives, on line 7.
  assert_eq(ti.length(), 1)
  assert_true(ti[0].pos is Some({ line: 7, .. }))
}

///|
test "ghalint config: policy excluded by name maps to karinto rule" {
  // `deny_inherit_secrets` maps (via the catalogue's origins) to the karinto
  // rule that absorbed it; a matching exclude drops that finding.
  let yaml =
    #|on: workflow_call
    #|jobs:
    #|  build:
    #|    uses: ./.github/workflows/reusable.yml
    #|    secrets: inherit
  let cfg =
    #|excludes:
    #|  - policy_name: deny_inherit_secrets
  let baseline = @karinto.lint(yaml)
  assert_true(
    baseline.diagnostics.filter(fn(d) { d.rule == "secrets-inherit" }).length() >
    0,
  )
  let res = @karinto.lint(yaml, ghalint_config=cfg)
  assert_eq(
    res.diagnostics.filter(fn(d) { d.rule == "secrets-inherit" }).length(),
    0,
  )
}

///|
test "ghalint config: workflow_file_path scopes the exclude" {
  let yaml =
    #|on: workflow_call
    #|jobs:
    #|  build:
    #|    uses: ./.github/workflows/reusable.yml
    #|    secrets: inherit
  let cfg =
    #|excludes:
    #|  - policy_name: deny_inherit_secrets
    #|    workflow_file_path: .github/workflows/release.yml
  // The path does not match the file under lint, so the finding survives.
  let other = @karinto.lint(
    yaml,
    ghalint_config=cfg,
    file_path=".github/workflows/ci.yml",
  )
  assert_true(
    other.diagnostics.filter(fn(d) { d.rule == "secrets-inherit" }).length() > 0,
  )
  // The matching path drops it.
  let hit = @karinto.lint(
    yaml,
    ghalint_config=cfg,
    file_path=".github/workflows/release.yml",
  )
  assert_eq(
    hit.diagnostics.filter(fn(d) { d.rule == "secrets-inherit" }).length(),
    0,
  )
}

///|
test "zizmor config: rules.<id>.disable drops the rule everywhere" {
  // Mirrors a real `zizmor.yml` that turns off `undocumented-permissions`.
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      pull-requests: read
    #|    steps:
    #|      - run: echo hi
  let cfg =
    #|rules:
    #|  undocumented-permissions:
    #|    disable: true
  let baseline = @karinto.lint(yaml)
  assert_true(
    baseline.diagnostics
    .filter(fn(d) { d.rule == "undocumented-permissions" })
    .length() >
    0,
  )
  let res = @karinto.lint(yaml, zizmor_config=cfg)
  assert_eq(
    res.diagnostics
    .filter(fn(d) { d.rule == "undocumented-permissions" })
    .length(),
    0,
  )
}

///|
test "zizmor config: rules.<id>.ignore scopes by file and line" {
  let yaml =
    #|on: push
    #|permissions:
    #|  contents: read
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo hi
  // `concurrency-limits` is a workflow-global finding without a line, so a
  // bare-filename ignore (line == any) is what suppresses it.
  let cfg =
    #|rules:
    #|  concurrency-limits:
    #|    ignore:
    #|      - ci.yml
  // A non-matching filename leaves the finding in place.
  let other = @karinto.lint(
    yaml,
    zizmor_config=cfg,
    file_path=".github/workflows/release.yml",
  )
  assert_true(
    other.diagnostics.filter(fn(d) { d.rule == "concurrency-limits" }).length() >
    0,
  )
  // The matching filename (path-boundary suffix) drops it.
  let hit = @karinto.lint(
    yaml,
    zizmor_config=cfg,
    file_path=".github/workflows/ci.yml",
  )
  assert_eq(
    hit.diagnostics.filter(fn(d) { d.rule == "concurrency-limits" }).length(),
    0,
  )
}

///|
test "zizmor config: rules.<id>.ignore honours a pinned column" {
  // The job-level `anonymous-definition` finding is stamped at line 3, col 3.
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  let path = ".github/workflows/ci.yml"
  // Count the positioned (job-level) anonymous-definition finding at line 3.
  fn job_anon(cfg : String) -> Int {
    @karinto.lint(yaml, file_path=path, zizmor_config=cfg).diagnostics
    .filter(fn(d) {
      d.rule == "anonymous-definition" && d.pos is Some({ line: 3, .. })
    })
    .length()
  }

  assert_eq(job_anon(""), 1)
  // Exact column suppresses it.
  let exact =
    #|rules:
    #|  anonymous-definition:
    #|    ignore:
    #|      - ci.yml:3:3
  assert_eq(job_anon(exact), 0)
  // A non-matching column does not.
  let wrong_col =
    #|rules:
    #|  anonymous-definition:
    #|    ignore:
    #|      - ci.yml:3:99
  assert_eq(job_anon(wrong_col), 1)
  // Line-only (no column) suppresses any column on that line.
  let line_only =
    #|rules:
    #|  anonymous-definition:
    #|    ignore:
    #|      - ci.yml:3
  assert_eq(job_anon(line_only), 0)
}

///|
test "inline ignore: karinto alias and trailing explanation" {
  // The `karinto` alias and a free-form note after the bracket are both
  // honoured; comma-separated ids opt out of several rules at once.
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo "${{ github.event.issue.title }}" # karinto: ignore[template-injection] safe, sanitised upstream
  let res = @karinto.lint(yaml)
  let ti = res.diagnostics.filter(fn(d) { d.rule == "template-injection" })
  assert_eq(ti.length(), 0)
}

///|
test "inline ignore: position-less workflow finding honoured file-wide" {
  // `cache-poisoning` is a workflow-scoped finding emitted without a source
  // position. zizmor attributes it to the cache-restoring step, so authors
  // place the opt-out there. Because the finding has no resolvable line, a
  // strictly line-scoped match would never honour it; position-less findings
  // fall back to a file-wide inline ignore.
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
    #|      - uses: actions/cache@13aacd865c20de90d75de3b17ebe84f7a17d57d2 # zizmor: ignore[cache-poisoning]
    #|        with:
    #|          path: dist
    #|          key: build
    #|      - run: ./publish.sh
  let res = @karinto.lint(yaml)
  let cp = res.diagnostics.filter(fn(d) { d.rule == "cache-poisoning" })
  assert_eq(cp.length(), 0)
}

///|
test "positions: merge key column tolerates extra spaces after dash" {
  let yaml =
    #|defaults: &d
    #|  run: echo hi
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      -   <<: *d
  let res = @karinto.lint(yaml)
  let mk = res.diagnostics.filter(fn(d) { d.message.contains("merge key") })
  assert_true(mk.length() == 1)
  assert_true(mk[0].pos is Some({ line: 7, col: 11 }))
}
