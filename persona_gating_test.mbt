// Persona-gating regressions found by validating karinto against real
// zizmor-using OSS workflows (django, trivy, …): karinto at `persona=regular`
// fired two zizmor audits that real `zizmor` only emits under `--pedantic`.
//
// Empirical zizmor 1.25.2 gating (oracle):
//   - concurrency-limits          → pedantic only
//   - excessive-permissions       → MIXED: blanket write-all/read-all and the
//     "default permissions used" finding are Regular; the per-key
//     "<x>: write is overly broad" finding is pedantic only.

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
