// More persona-gating regressions found validating karinto against real
// zizmor-using OSS (golangci-lint, LibCST, nautilus_trader). Empirical zizmor
// 1.25.2 gating (oracle):
//   - superfluous-actions  → pedantic only
//   - template-injection   → Regular for vars.* / env.* / inputs.* /
//     *.outputs.* / github.ref* / github.actor / github.workflow (not just the
//     high-cap event contexts); only truly-static contexts (run_id, sha,
//     matrix, repository, event_name, runner.os, token) are the pedantic
//     backstop.
//
// Reuses `fires(content, persona, rule)` from persona_gating_test.mbt.

///|
test "superfluous-actions is pedantic, not regular" {
  let yaml =
    #|name: t
    #|on: push
    #|jobs:
    #|  b:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: peter-evans/create-pull-request@5f6978faf089d4d20b00c7766989d076bb2fc7f1 # v8.1.1
  inspect(
    fires(yaml, @karinto.Persona::Regular, "superfluous-actions"),
    content="false",
  )
  inspect(
    fires(yaml, @karinto.Persona::Pedantic, "superfluous-actions"),
    content="true",
  )
}

///|
test "superfluous-actions: a regular-persona action fires at regular" {
  // zizmor flags release-action style superfluous actions at the default
  // persona (unlike create-pull-request, which is pedantic-only).
  let yaml =
    #|name: t
    #|on: push
    #|jobs:
    #|  b:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - uses: ncipollo/release-action@440c8c1cb0ed28b9f43e4d1d670870f059653174 # v1.16.0
  inspect(
    fires(yaml, @karinto.Persona::Regular, "superfluous-actions"),
    content="true",
  )
}

///|
test "template-injection: bare env.* stays the pedantic backstop" {
  // karinto cannot tell a statically-defined env var from a dynamic one, so
  // `env.*` is left on the pedantic backstop rather than over-firing at regular.
  let yaml =
    #|name: t
    #|on: push
    #|jobs:
    #|  b:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo "${{ env.PACKAGE_DIR }}"
  inspect(
    fires(yaml, @karinto.Persona::Regular, "template-injection"),
    content="false",
  )
  inspect(
    fires(yaml, @karinto.Persona::Pedantic, "template-injection"),
    content="true",
  )
}

///|
test "template-injection: vars.* in run is a regular finding" {
  let yaml =
    #|name: t
    #|on: push
    #|jobs:
    #|  b:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo "${{ vars.FOO }}"
  inspect(
    fires(yaml, @karinto.Persona::Regular, "template-injection"),
    content="true",
  )
}

///|
test "template-injection: a static context stays the pedantic backstop" {
  let yaml =
    #|name: t
    #|on: push
    #|jobs:
    #|  b:
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo "${{ github.run_id }}"
  inspect(
    fires(yaml, @karinto.Persona::Regular, "template-injection"),
    content="false",
  )
  inspect(
    fires(yaml, @karinto.Persona::Pedantic, "template-injection"),
    content="true",
  )
}
