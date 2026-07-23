// Persona-gating regressions found by validating karinto against real
// zizmor-using OSS workflows (django, trivy, …): karinto at `persona=regular`
// fired two zizmor audits that real `zizmor` only emits under `--pedantic`.
//
// Empirical zizmor 1.25.2 gating (oracle):
//   - concurrency-limits          → pedantic only
//   - excessive-permissions       → MIXED: blanket write-all/read-all are
//     always Regular; the per-key "<x>: write is overly broad" finding is
//     pedantic only; the "default permissions used" finding (workflow- and
//     job-level) is conditionally pedantic — see the "default permissions
//     used" gating tests below and the derivation in
//     `check_excessive_permissions`'s doc comment in rules.mbt.

///|
fn fires(content : String, persona : @karinto.Persona, rule : String) -> Bool {
  @karinto.lint(content, persona~).diagnostics
  .iter()
  .any(fn(d) { d.rule == rule })
}

///|
test "concurrency-limits is pedantic, not regular" {
  let yaml =
    #|name: t
    #|on: push
    #|jobs:
    #|  build:
    #|    name: b
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  // No `concurrency:` anywhere → "workflow has no concurrency block".
  inspect(
    fires(yaml, @karinto.Persona::Regular, "concurrency-limits"),
    content="false",
  )
  inspect(
    fires(yaml, @karinto.Persona::Pedantic, "concurrency-limits"),
    content="true",
  )
}

///|
test "excessive-permissions per-key `write` is pedantic, not regular" {
  let yaml =
    #|name: t
    #|on: push
    #|concurrency:
    #|  group: g
    #|  cancel-in-progress: true
    #|permissions:
    #|  pull-requests: write
    #|jobs:
    #|  build:
    #|    name: b
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  // Workflow grants a single per-key `write` (overly broad). zizmor flags this
  // only under --pedantic.
  inspect(
    fires(yaml, @karinto.Persona::Regular, "excessive-permissions"),
    content="false",
  )
  inspect(
    fires(yaml, @karinto.Persona::Pedantic, "excessive-permissions"),
    content="true",
  )
}

///|
test "excessive-permissions write-all stays regular" {
  let yaml =
    #|name: t
    #|on: push
    #|concurrency:
    #|  group: g
    #|  cancel-in-progress: true
    #|permissions: write-all
    #|jobs:
    #|  build:
    #|    name: b
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  // Blanket write-all is a real problem zizmor flags at the default persona.
  inspect(
    fires(yaml, @karinto.Persona::Regular, "excessive-permissions"),
    content="true",
  )
}

///|
test "excessive-permissions default-perms: multi-job non-reusable workflow is regular" {
  // Two jobs, neither the workflow nor either job declares `permissions:`,
  // and the workflow isn't reusable-only (`on: push`). zizmor's gate
  // (`jobs.len() == 1 || all_jobs_have_permissions || reusable_only`) is
  // false on every count, so both the workflow-level and each normal job's
  // finding are Regular — matching
  // `excessive-permissions/reusable-workflow-other-triggers.yml` in the
  // vendored zizmor fixtures (its `push`-triggerable case).
  let yaml =
    #|name: t
    #|on: push
    #|jobs:
    #|  job1:
    #|    name: job1
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo hi
    #|  job2:
    #|    name: job2
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo hi
  let regular_hits = @karinto.lint(yaml, persona=@karinto.Persona::Regular).diagnostics.filter(fn(
      d,
    ) {
      d.rule == "excessive-permissions"
    },
  )
  inspect(regular_hits.length(), content="3")
  inspect(
    regular_hits
    .iter()
    .any(fn(d) {
      d.message == "default permissions used due to no permissions: block"
    }),
    content="true",
  )
  inspect(
    regular_hits
    .iter()
    .any(fn(d) {
      d.message ==
      "job `job1`: default permissions used due to no permissions: block"
    }),
    content="true",
  )
  inspect(
    regular_hits
    .iter()
    .any(fn(d) {
      d.message ==
      "job `job2`: default permissions used due to no permissions: block"
    }),
    content="true",
  )
}

///|
test "excessive-permissions default-perms: reusable-only workflow gates normal jobs pedantic, caller jobs stay regular" {
  // `on: workflow_call` only → reusable-only. The normal job's "default
  // permissions used" finding is pedantic-only; the caller job's (`uses:`)
  // is always Regular, since the caller is responsible for permissions
  // regardless of how the callee is triggered. Matches
  // `excessive-permissions/issue-472-repro.yml` upstream.
  let yaml =
    #|name: t
    #|on:
    #|  workflow_call:
    #|jobs:
    #|  job1:
    #|    name: job1
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo hi
    #|  job2:
    #|    name: job2
    #|    uses: ./.github/workflows/fake.yml
  let regular_hits = @karinto.lint(yaml, persona=@karinto.Persona::Regular).diagnostics.filter(fn(
      d,
    ) {
      d.rule == "excessive-permissions"
    },
  )
  inspect(regular_hits.length(), content="1")
  inspect(
    regular_hits[0].message,
    content="job `job2`: default permissions used due to no permissions: block",
  )
  inspect(
    fires(yaml, @karinto.Persona::Pedantic, "excessive-permissions"),
    content="true",
  )
}

///|
test "excessive-permissions default-perms: single-job workflow is pedantic even when non-reusable" {
  // One job, `on: push` (not reusable-only) — the single-job gate alone is
  // enough to demote both findings to pedantic. Matches
  // `excessive-permissions/workflow-default-perms.yml` upstream.
  let yaml =
    #|name: t
    #|on: push
    #|jobs:
    #|  single:
    #|    name: single
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo hi
  inspect(
    fires(yaml, @karinto.Persona::Regular, "excessive-permissions"),
    content="false",
  )
  inspect(
    fires(yaml, @karinto.Persona::Pedantic, "excessive-permissions"),
    content="true",
  )
}
