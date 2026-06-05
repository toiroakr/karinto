///|
test "parse_kind maps the Worker's type parameter contract" {
  assert_true(parse_kind("") is Some(Unknown))
  assert_true(parse_kind("workflow") is Some(Workflow))
  assert_true(parse_kind("action") is Some(Action))
  assert_true(parse_kind("bogus") is None)
  assert_true(parse_kind("Workflow") is None)
}

///|
test "split_csv trims and drops empties" {
  assert_eq(split_csv("").join("|"), "")
  assert_eq(split_csv("a,b").join("|"), "a|b")
  assert_eq(split_csv(" a , b ,, ").join("|"), "a|b")
  assert_eq(split_csv("permissions-*").join("|"), "permissions-*")
}

///|
test "kind_from_path uses filename conventions" {
  assert_true(kind_from_path("action.yml") is Action)
  assert_true(kind_from_path("some/dir/action.yaml") is Action)
  assert_true(kind_from_path(".github/workflows/ci.yml") is Workflow)
  assert_true(kind_from_path("/repo/.github/workflows/ci.yaml") is Workflow)
  assert_true(kind_from_path("random.yml") is Unknown)
  // the workflows-directory hint beats the basename: GitHub runs every
  // YAML under .github/workflows/ as a workflow, even `action.yml`
  assert_true(kind_from_path(".github/workflows/action.yml") is Workflow)
  // Windows-style separators are normalized before matching
  assert_true(kind_from_path(".github\\workflows\\ci.yml") is Workflow)
  assert_true(kind_from_path("some\\dir\\action.yml") is Action)
  // `.github/workflows/` must be a path segment, not a substring
  assert_true(kind_from_path("foo.github/workflows/ci.yml") is Unknown)
}

///|
test "has_blocking flags error severity and parse errors" {
  let clean = @karinto.lint(
    (
      #|name: ci
      #|on: push
      #|concurrency:
      #|  group: g
      #|  cancel-in-progress: true
      #|jobs:
      #|  build:
      #|    name: build
      #|    runs-on: ubuntu-latest
      #|    timeout-minutes: 5
      #|    permissions: {}
      #|    steps:
      #|      - run: echo hi
    ),
  )
  assert_true(clean.parse_error is None)
  assert_false(has_blocking(clean))
  let with_error = @karinto.lint(
    (
      #|on: push
      #|permissions: write-all
      #|jobs:
      #|  build:
      #|    runs-on: ubuntu-latest
      #|    steps:
      #|      - run: echo hi
    ),
  )
  assert_true(has_blocking(with_error))
  let unparsable = @karinto.lint("foo: [unclosed")
  assert_true(unparsable.parse_error is Some(_))
  assert_true(has_blocking(unparsable))
}
