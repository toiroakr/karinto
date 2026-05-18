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
