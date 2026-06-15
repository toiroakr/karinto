// Whitebox tests for `osv_match` and the version comparator helpers.

///|
test "normalize_ver: strips v prefix and parses dotted numerics" {
  inspect(@worker.normalize_ver("v1.2.3"), content="Some([1, 2, 3])")
  inspect(@worker.normalize_ver("1.2.3"), content="Some([1, 2, 3])")
  inspect(@worker.normalize_ver("V4"), content="Some([4])")
  inspect(@worker.normalize_ver("0"), content="Some([0])")
}

///|
test "normalize_ver: returns None for non-numeric tags (SHAs, branches)" {
  inspect(@worker.normalize_ver("aabbccddeeff"), content="None")
  inspect(@worker.normalize_ver("main"), content="None")
  inspect(@worker.normalize_ver(""), content="None")
  inspect(@worker.normalize_ver("v"), content="None")
}

///|
test "cmp_ver: lexicographic with shorter operand zero-padded" {
  inspect(@worker.cmp_ver([1, 2, 3], [1, 2, 3]), content="0")
  inspect(@worker.cmp_ver([1, 2], [1, 2, 0]), content="0")
  inspect(@worker.cmp_ver([1, 2, 0], [1, 2]), content="0")
  inspect(@worker.cmp_ver([1, 2, 3], [1, 3, 0]), content="-1")
  inspect(@worker.cmp_ver([2], [1, 99, 99]), content="1")
}

///|
test "lint_string: persona param gates pedantic findings" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: self-hosted
    #|    timeout-minutes: 5
    #|    permissions:
    #|      contents: read
    #|    steps:
    #|      - run: echo hi
  // Default (no persona) is auditor — self-hosted-runner (a pedantic finding)
  // surfaces.
  let auditor = @worker.lint_string(yaml, "workflow", "", "")
  inspect(auditor.contains("self-hosted-runner"), content="true")
  // persona=regular drops it.
  let regular = @worker.lint_string(
    yaml,
    "workflow",
    "",
    "",
    persona_str="regular",
  )
  inspect(regular.contains("self-hosted-runner"), content="false")
  // persona=pedantic brings it back.
  let pedantic = @worker.lint_string(
    yaml,
    "workflow",
    "",
    "",
    persona_str="pedantic",
  )
  inspect(pedantic.contains("self-hosted-runner"), content="true")
}

///|
test "osv_match: introduced/fixed range" {
  let advisories =
    #|{"tj-actions/changed-files":[{"events":[{"introduced":"0"},{"fixed":"41"}]}]}
  inspect(
    @worker.osv_match("tj-actions/changed-files@v35", advisories),
    content="tj-actions/changed-files@v35",
  )
  inspect(
    @worker.osv_match("tj-actions/changed-files@v41", advisories),
    content="",
  )
  inspect(
    @worker.osv_match("tj-actions/changed-files@v100", advisories),
    content="",
  )
}

///|
test "osv_match: multi-range with semver fixed boundary" {
  let advisories =
    #|{"tj-actions/changed-files":[
    #|  {"events":[{"introduced":"0"},{"fixed":"41"}]},
    #|  {"events":[{"introduced":"0"},{"fixed":"46.0.1"}]}
    #|]}
  inspect(
    @worker.osv_match("tj-actions/changed-files@v45", advisories),
    content="tj-actions/changed-files@v45",
  )
  inspect(
    @worker.osv_match("tj-actions/changed-files@v46.0.1", advisories),
    content="",
  )
  inspect(
    @worker.osv_match("tj-actions/changed-files@v46.0.0", advisories),
    content="tj-actions/changed-files@v46.0.0",
  )
}

///|
test "osv_match: SHA-pinned ref matches conservatively" {
  let advisories =
    #|{"tj-actions/changed-files":[{"events":[{"introduced":"0"},{"fixed":"41"}]}]}
  inspect(
    @worker.osv_match(
      "tj-actions/changed-files@aabbccddeeff00112233445566778899aabbccdd", advisories,
    ),
    content="tj-actions/changed-files@aabbccddeeff00112233445566778899aabbccdd",
  )
}

///|
test "osv_match: subpath collapses to root action" {
  let advisories =
    #|{"actions/cache":[{"events":[{"introduced":"0"},{"fixed":"4"}]}]}
  inspect(
    @worker.osv_match("actions/cache/restore@v3", advisories),
    content="actions/cache/restore@v3",
  )
  inspect(@worker.osv_match("actions/cache/restore@v4", advisories), content="")
}

///|
test "osv_match: dedupes and emits CSV" {
  let advisories =
    #|{"tj-actions/changed-files":[{"events":[{"introduced":"0"},{"fixed":"41"}]}]}
  inspect(
    @worker.osv_match(
      "tj-actions/changed-files@v35,actions/checkout@v4,tj-actions/changed-files@v40,tj-actions/changed-files@v35",
      advisories,
    ),
    content="tj-actions/changed-files@v35,tj-actions/changed-files@v40",
  )
}

///|
test "osv_match: empty inputs / no match" {
  inspect(@worker.osv_match("", "{}"), content="")
  inspect(@worker.osv_match("actions/checkout@v4", ""), content="")
  inspect(@worker.osv_match("actions/checkout@v4", "{}"), content="")
  inspect(@worker.osv_match("no-at-symbol", "{}"), content="")
}

///|
test "osv_match: last_affected boundary (inclusive)" {
  let advisories =
    #|{"foo/bar":[{"events":[{"introduced":"1.0.0"},{"last_affected":"2.0.0"}]}]}
  inspect(@worker.osv_match("foo/bar@v0.9", advisories), content="")
  inspect(
    @worker.osv_match("foo/bar@v1.0.0", advisories),
    content="foo/bar@v1.0.0",
  )
  inspect(
    @worker.osv_match("foo/bar@v2.0.0", advisories),
    content="foo/bar@v2.0.0",
  )
  inspect(@worker.osv_match("foo/bar@v2.0.1", advisories), content="")
}

///|
test "lint_string_sarif: emits a SARIF document with the path label" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo hi
  let out = @worker.lint_string_sarif(
    yaml,
    "workflow",
    "",
    "",
    path=".github/workflows/ci.yml",
  )
  let doc = @json.parse(out)
  assert_true(out.contains("\"version\": \"2.1.0\""))
  assert_true(out.contains(".github/workflows/ci.yml"))
  assert_true(doc is Object(_))
}

///|
test "lint_string_sarif: empty path omits physicalLocation" {
  let yaml =
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo hi
  let out = @worker.lint_string_sarif(yaml, "workflow", "", "")
  assert_false(out.contains("physicalLocation"))
}

///|
test "lint_files_sarif: lints fetched files and surfaces fetch errors" {
  let files_json =
    #|[
    #|  {"path": ".github/workflows/ci.yml",
    #|   "content": "on: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n",
    #|   "kind": "workflow", "vuln": ""},
    #|  {"path": ".github/workflows/gone.yml", "error": "GET raw → 404"}
    #|]
  let out = @worker.lint_files_sarif(files_json, "")
  assert_true(out.contains("\"uri\": \".github/workflows/ci.yml\""))
  assert_true(out.contains("toolExecutionNotifications"))
  assert_true(out.contains("GET raw → 404"))
  assert_true(out.contains("\"executionSuccessful\": false"))
}

///|
test "lint_files_sarif: malformed files_json degrades to an empty report" {
  let out = @worker.lint_files_sarif("not json", "")
  assert_true(out.contains("\"results\": []"))
}
