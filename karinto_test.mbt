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
        "pos": { "line": 3, "col": 3 },
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
  // `concurrency-limits` is about the *absence* of a `concurrency:` block, so
  // there is no line to anchor it to and `pos` stays `None`. A strictly
  // line-scoped match would never honour an opt-out for it, so position-less
  // findings fall back to a file-wide inline ignore — the comment can sit
  // anywhere in the file.
  let yaml =
    #|on:
    #|  push:
    #|    tags: ["v*"] # zizmor: ignore[concurrency-limits]
    #|jobs:
    #|  release:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      contents: write
    #|    steps:
    #|      - run: ./publish.sh
  let res = @karinto.lint(yaml)
  let cl = res.diagnostics.filter(fn(d) { d.rule == "concurrency-limits" })
  assert_eq(cl.length(), 0)
}

///|
test "cache-poisoning: attributed to the cache-restoring step, ignorable on its own line" {
  // The rule pinpoints the cache-restoring step, so the finding carries that
  // step's context and an inline ignore belongs on that step's `uses:` line —
  // which is where zizmor's own docs put it too.
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
    #|      - uses: actions/cache@13aacd865c20de90d75de3b17ebe84f7a17d57d2
    #|        with:
    #|          path: dist
    #|          key: build
    #|      - run: ./publish.sh
  let baseline = @karinto.lint(yaml)
  let hits = baseline.diagnostics.filter(fn(d) { d.rule == "cache-poisoning" })
  assert_eq(hits.length(), 1)
  assert_true(hits[0].job is Some("release"))
  assert_true(hits[0].step is Some({ index: 0, .. }))
  assert_true(hits[0].pos is Some({ line: 10, .. }))
  let ignored =
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
  let res = @karinto.lint(ignored)
  assert_eq(
    res.diagnostics.filter(fn(d) { d.rule == "cache-poisoning" }).length(),
    0,
  )
}

///|
test "inline ignore: comment on the line above a job-scoped finding is honoured" {
  // Findings with no owning step (e.g. `undocumented-permissions`, which is
  // about a `permissions:` block, not any one step) resolve `pos` to that
  // field's own line. A `# karinto: ignore[...]` placed on the line directly
  // above it — a "disable next line" style — should suppress the finding the
  // same way placing it on that line itself does.
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    # karinto: ignore[undocumented-permissions]
    #|    permissions:
    #|      contents: write
    #|    steps:
    #|      - run: echo hi
  let res = @karinto.lint(yaml)
  let hits = res.diagnostics.filter(fn(d) {
    d.rule == "undocumented-permissions"
  })
  assert_eq(hits.length(), 0)
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

// ---------------------------------------------------------------------------
// ignored: suppressed findings surface in LintResult.ignored
// ---------------------------------------------------------------------------

///|
test "ignored: inline ignore comment moves finding to ignored" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo "${{ github.event.issue.title }}" # zizmor: ignore[template-injection]
  let res = @karinto.lint(yaml)
  // The suppressed finding must not appear in diagnostics…
  assert_eq(
    res.diagnostics.filter(fn(d) { d.rule == "template-injection" }).length(),
    0,
  )
  // …but must be visible in ignored.
  assert_true(
    res.ignored.filter(fn(d) { d.rule == "template-injection" }).length() > 0,
  )
}

///|
test "ignored: ghalint config exclude moves finding to ignored" {
  let yaml =
    #|on: workflow_call
    #|jobs:
    #|  build:
    #|    uses: ./.github/workflows/reusable.yml
    #|    secrets: inherit
  let cfg =
    #|excludes:
    #|  - policy_name: deny_inherit_secrets
  let res = @karinto.lint(yaml, ghalint_config=cfg)
  assert_eq(
    res.diagnostics.filter(fn(d) { d.rule == "secrets-inherit" }).length(),
    0,
  )
  assert_true(
    res.ignored.filter(fn(d) { d.rule == "secrets-inherit" }).length() > 0,
  )
}

///|
test "ignored: zizmor config disable moves finding to ignored" {
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
  let res = @karinto.lint(yaml, zizmor_config=cfg)
  assert_eq(
    res.diagnostics
    .filter(fn(d) { d.rule == "undocumented-permissions" })
    .length(),
    0,
  )
  assert_true(
    res.ignored.filter(fn(d) { d.rule == "undocumented-permissions" }).length() >
    0,
  )
}

///|
test "ignored: persona gate moves below-threshold findings to ignored" {
  // At Regular persona, Auditor-only findings like `secrets-outside-env` are
  // hidden. They must appear in `ignored` rather than disappear silently.
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo "${{ secrets.TOKEN }}"
  let res = @karinto.lint(yaml, persona=@karinto.Persona::Regular)
  assert_eq(
    res.diagnostics.filter(fn(d) { d.rule == "secrets-outside-env" }).length(),
    0,
  )
  assert_true(
    res.ignored.filter(fn(d) { d.rule == "secrets-outside-env" }).length() > 0,
  )
}

///|
test "ignored: empty when nothing is suppressed" {
  // A completely clean workflow with no inline ignores or config excludes must
  // yield an empty ignored array (and consequently no `ignored` key in JSON).
  let yaml =
    #|on: push
    #|name: CI
    #|concurrency:
    #|  group: ci
    #|  cancel-in-progress: true
    #|jobs:
    #|  build:
    #|    name: Build
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
  let res = @karinto.lint(yaml)
  assert_eq(res.ignored.length(), 0)
  // The JSON output must not contain an `ignored` key.
  let j = res.to_json()
  assert_true(
    match j {
      Object(m) => !m.contains("ignored")
      _ => false
    },
  )
}

///|
test "karinto config: self-hosted-runner.labels validates the remaining labels instead of skipping" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: [self-hosted, gpu-a100]
    #|    steps:
    #|      - run: echo hi
  // Without config: legacy skip-all behaviour (bugfix_test.mbt covers this
  // baseline directly), so `gpu-a100` is not flagged.
  let cfg =
    #|self-hosted-runner:
    #|  labels:
    #|    - "gpu-*"
  let allowed = @karinto.lint(yaml, karinto_config=cfg)
  assert_eq(
    allowed.diagnostics
    .filter(fn(d) { d.rule == "unknown-runner-label" })
    .length(),
    0,
  )
  let cfg_no_match =
    #|self-hosted-runner:
    #|  labels:
    #|    - "cpu-*"
  let flagged = @karinto.lint(yaml, karinto_config=cfg_no_match)
  assert_eq(
    flagged.diagnostics
    .filter(fn(d) { d.rule == "unknown-runner-label" })
    .length(),
    1,
  )
}

///|
test "karinto config: config-variables is dormant without config" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo "${{ vars.ANYTHING }}"
  let res = @karinto.lint(yaml)
  assert_eq(
    res.diagnostics.filter(fn(d) { d.rule == "config-variables" }).length(),
    0,
  )
}

///|
test "karinto config: config-variables empty array forbids every vars.*" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo "${{ vars.ENVIRONMENT }}"
  let cfg =
    #|config-variables: []
  let res = @karinto.lint(yaml, karinto_config=cfg)
  assert_eq(
    res.diagnostics.filter(fn(d) { d.rule == "config-variables" }).length(),
    1,
  )
}

///|
test "karinto config: config-variables allowlist permits listed names only" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo "${{ vars.ENVIRONMENT }} ${{ vars.UNDECLARED }}"
  let cfg =
    #|config-variables:
    #|  - ENVIRONMENT
  let res = @karinto.lint(yaml, karinto_config=cfg)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "config-variables" })
  assert_eq(hits.length(), 1)
  assert_true(hits[0].message.contains("UNDECLARED"))
}

///|
test "karinto config: config-variables tolerates whitespace/newlines around the dot" {
  // `${{ vars\n  .  UNDECLARED }}` must still resolve to context `vars`,
  // member `UNDECLARED` — matching `check_unknown_context`'s tolerance for
  // whitespace (including newlines) around `.`.
  let yaml = "on: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: |\n          echo \"${{ vars\n            . UNDECLARED }}\"\n"
  let cfg =
    #|config-variables: []
  let res = @karinto.lint(yaml, karinto_config=cfg)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "config-variables" })
  assert_eq(hits.length(), 1)
  assert_true(hits[0].message.contains("UNDECLARED"))
}

///|
test "karinto config: config-variables catches bare `if:` (no `${{ }}` delimiters)" {
  // GitHub evaluates `if:` as an expression even without `${{ }}`, so a bare
  // `if: vars.UNDECLARED == 'x'` must still be checked — mirrors
  // `expr_collect_findings_in_if` in expr.mbt. One at job scope, one at step
  // scope.
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    if: vars.JOB_FLAG == 'on'
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - if: vars.STEP_FLAG == 'on'
    #|        run: echo hi
  let cfg =
    #|config-variables: []
  let res = @karinto.lint(yaml, karinto_config=cfg)
  let hits = res.diagnostics.filter(fn(d) { d.rule == "config-variables" })
  assert_eq(hits.length(), 2)
  let names = hits.map(fn(d) { d.message })
  assert_true(names.filter(fn(m) { m.contains("JOB_FLAG") }).length() == 1)
  assert_true(names.filter(fn(m) { m.contains("STEP_FLAG") }).length() == 1)
}

///|
test "karinto config: rules.<id> overrides severity" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      pull-requests: read
    #|    steps:
    #|      - run: echo hi
  let baseline = @karinto.lint(yaml)
  let base_hit = baseline.diagnostics.filter(fn(d) {
    d.rule == "undocumented-permissions"
  })
  assert_eq(base_hit.length(), 1)
  assert_true(base_hit[0].severity is Info)
  let cfg =
    #|rules:
    #|  undocumented-permissions: error
  let res = @karinto.lint(yaml, karinto_config=cfg)
  let hit = res.diagnostics.filter(fn(d) {
    d.rule == "undocumented-permissions"
  })
  assert_eq(hit.length(), 1)
  assert_true(hit[0].severity is Error)
}

///|
test "karinto config: rules.<id> severity as a YAML block scalar still parses" {
  // A literal block scalar (`|`) keeps its trailing newline under YAML's
  // default "clip" chomping — `parse_severity_string` must trim it, not
  // just spaces/tabs, or the override silently falls through.
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
    #|  undocumented-permissions: |
    #|    error
  let res = @karinto.lint(yaml, karinto_config=cfg)
  let hit = res.diagnostics.filter(fn(d) {
    d.rule == "undocumented-permissions"
  })
  assert_eq(hit.length(), 1)
  assert_true(hit[0].severity is Error)
}

///|
test "karinto config: ignore-paths suppresses a rule under a matching glob" {
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
    #|ignore-paths:
    #|  "fixtures/**":
    #|    - undocumented-permissions
  let other = @karinto.lint(
    yaml,
    karinto_config=cfg,
    file_path=".github/workflows/ci.yml",
  )
  assert_true(
    other.diagnostics
    .filter(fn(d) { d.rule == "undocumented-permissions" })
    .length() >
    0,
  )
  let hit = @karinto.lint(
    yaml,
    karinto_config=cfg,
    file_path="fixtures/legacy/ci.yml",
  )
  assert_eq(
    hit.diagnostics
    .filter(fn(d) { d.rule == "undocumented-permissions" })
    .length(),
    0,
  )
  assert_true(
    hit.ignored.filter(fn(d) { d.rule == "undocumented-permissions" }).length() >
    0,
  )
}

///|
test "karinto config: ignore-paths \"*\" suppresses every rule under a glob" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: [self-hosted, gpu-a100]
    #|    permissions:
    #|      pull-requests: read
    #|    steps:
    #|      - run: echo hi
  let cfg =
    #|ignore-paths:
    #|  "fixtures/**":
    #|    - "*"
  let res = @karinto.lint(
    yaml,
    karinto_config=cfg,
    file_path="fixtures/legacy/ci.yml",
  )
  assert_eq(
    res.diagnostics
    .filter(fn(d) { d.rule == "undocumented-permissions" })
    .length(),
    0,
  )
}

///|
test "karinto config: a compatible actionlint.yaml is honoured directly" {
  // `self-hosted-runner.labels` / `config-variables` share actionlint.yaml's
  // own key names and shapes, so an existing actionlint.yaml works without
  // translation. Its own `paths.*.ignore` (unrelated, message-regex, #50) is
  // simply not read.
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: [self-hosted, gpu-a100]
    #|    steps:
    #|      - run: echo "${{ vars.ENVIRONMENT }}"
  let actionlint_yaml =
    #|self-hosted-runner:
    #|  labels:
    #|    - "gpu-*"
    #|config-variables:
    #|  - ENVIRONMENT
    #|paths:
    #|  .github/workflows/**:
    #|    ignore:
    #|      - "unrelated actionlint-only regex"
  let res = @karinto.lint(yaml, karinto_config=actionlint_yaml)
  assert_eq(
    res.diagnostics.filter(fn(d) { d.rule == "unknown-runner-label" }).length(),
    0,
  )
  assert_eq(
    res.diagnostics.filter(fn(d) { d.rule == "config-variables" }).length(),
    0,
  )
}

///|
test "karinto config: excludes: (ghalint shape) is honoured from the same file" {
  // `excludes:` is ghalint's own top-level key/shape; karinto_config reads it
  // directly, so a ghalint.yaml's content can be pasted into karinto.yaml
  // instead of kept in a separate file passed via --ghalint-config.
  let yaml =
    #|on: workflow_call
    #|jobs:
    #|  build:
    #|    uses: ./.github/workflows/reusable.yml
    #|    secrets: inherit
  let cfg =
    #|excludes:
    #|  - policy_name: deny_inherit_secrets
  let res = @karinto.lint(yaml, karinto_config=cfg)
  assert_eq(
    res.diagnostics.filter(fn(d) { d.rule == "secrets-inherit" }).length(),
    0,
  )
}

///|
test "karinto config: rules.<id>.disable/.ignore (zizmor shape) is honoured from the same file" {
  // `rules.<id>` accepts zizmor's own `{disable, ignore}` object shape;
  // karinto_config parses it the same way `zizmor_config` does, so a
  // zizmor.yml's `rules:` section can be pasted into karinto.yaml's `rules:`
  // instead of kept in a separate file passed via --zizmor-config.
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
  let res = @karinto.lint(yaml, karinto_config=cfg)
  assert_eq(
    res.diagnostics
    .filter(fn(d) { d.rule == "undocumented-permissions" })
    .length(),
    0,
  )
}

///|
test "karinto config: rules.<id> combines zizmor's disable/ignore with karinto's severity" {
  // The same per-rule object carries zizmor's `ignore` alongside karinto's
  // `severity` — the two do not conflict, since they're read by separate
  // parsers (`parse_zizmor_config` / `parse_karinto_config`) over the same
  // text.
  let yaml =
    #|on: push
    #|permissions:
    #|  contents: read
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    permissions:
    #|      pull-requests: read
    #|    steps:
    #|      - run: echo hi
  let cfg =
    #|rules:
    #|  concurrency-limits:
    #|    ignore:
    #|      - ci.yml
    #|  undocumented-permissions:
    #|    severity: error
  let res = @karinto.lint(
    yaml,
    karinto_config=cfg,
    file_path=".github/workflows/ci.yml",
  )
  assert_eq(
    res.diagnostics.filter(fn(d) { d.rule == "concurrency-limits" }).length(),
    0,
  )
  let hit = res.diagnostics.filter(fn(d) {
    d.rule == "undocumented-permissions"
  })
  assert_eq(hit.length(), 1)
  assert_true(hit[0].severity is Error)
}

///|
test "karinto config: excludes: / rules: from karinto_config are additive with explicit ghalint_config/zizmor_config" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo hi
  let ghalint_cfg =
    #|excludes:
    #|  - policy_name: job_permissions
    #|    job_name: build
  let karinto_cfg =
    #|rules:
    #|  concurrency-limits:
    #|    disable: true
  let baseline = @karinto.lint(yaml)
  assert_true(
    baseline.diagnostics
    .filter(fn(d) { d.rule == "job-permissions-required" })
    .length() >
    0,
  )
  assert_true(
    baseline.diagnostics
    .filter(fn(d) { d.rule == "concurrency-limits" })
    .length() >
    0,
  )
  let res = @karinto.lint(
    yaml,
    ghalint_config=ghalint_cfg,
    karinto_config=karinto_cfg,
  )
  assert_eq(
    res.diagnostics
    .filter(fn(d) { d.rule == "job-permissions-required" })
    .length(),
    0,
  )
  assert_eq(
    res.diagnostics.filter(fn(d) { d.rule == "concurrency-limits" }).length(),
    0,
  )
}

///|
test "karinto config: malformed config yields the all-default config" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo hi
  let res = @karinto.lint(yaml, karinto_config="not: [valid")
  assert_true(res.parse_error is None)
}
