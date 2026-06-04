// Regression tests for the two actionlint parity fixtures the parser used to
// choke on (the CI `parity` job): YAML merge keys overridden by explicit keys,
// and anchor redefinition. Fixture bodies are embedded verbatim from
// fixtures/upstream/actionlint/testdata/err/.

///|
/// merge_key_unsupported.yaml: a `<<` merge followed by an explicit key (which
/// overrides the merged entry per YAML merge semantics) used to trip the
/// duplicate-mapping-key error and fail the whole lint.
test "parity regression: merge keys with explicit override lint cleanly" {
  let src =
    #|on:
    #|  workflow_dispatch:
    #|    inputs: &inputs
    #|      foo:
    #|        type: string
    #|  workflow_call:
    #|    inputs:
    #|      <<: *inputs
    #|      bar:
    #|        type: string
    #|
    #|jobs:
    #|  test:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: env
    #|        env: &default_env
    #|          FOO: BAR
    #|      - run: env
    #|        env:
    #|          <<: *default_env
    #|          TEST: test
    #|      - &default_step
    #|        run: echo hello
    #|        working-directory: /foo/bar
    #|        shell: bash
    #|      - <<: *default_step
    #|        run: echo bye
  let res = lint(src)
  assert_true(res.parse_error is None)
  assert_true(res.stats.jobs == 1)
  assert_true(res.stats.steps == 4)
}

///|
/// unused_anchors.yaml: anchors are redefined repeatedly; an alias must resolve
/// to the definition in scope where it appears. Resolving against the final
/// anchor table made `RUNS_ON: *anchor` point at its own ancestor job node and
/// recurse forever (stack overflow on the JS target).
test "parity regression: anchor redefinition does not cycle" {
  let src =
    #|# ERROR: Unused
    #|on: &anchor push
    #|
    #|jobs:
    #|  # ERROR: Unused
    #|  test: &anchor
    #|    # OK: Used
    #|    runs-on: &anchor ubuntu-latest
    #|    env:
    #|      RUNS_ON: *anchor
    #|    # ERROR: Unused
    #|    steps: &anchor
    #|      # OK: Used
    #|      - &step
    #|        run: env
    #|        # OK: Used
    #|        env: &default_env
    #|          FOO1: BAR1
    #|          FOO2: BAR2
    #|      - run: env
    #|        env: *default_env
    #|      - run: env
    #|        # ERROR: Unused
    #|        env: &default_env
    #|      - *step
    #|      # ERROR: Unused
    #|      - &step
    #|        run: echo hello
  let res = lint(src)
  assert_true(res.parse_error is None)
  assert_true(res.stats.jobs == 1)
  assert_true(res.stats.steps == 5)
}
