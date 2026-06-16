///|
test "glob_match exact" {
  inspect(glob_match("ghl-001", "ghl-001"), content="true")
  inspect(glob_match("ghl-001", "ghl-002"), content="false")
}

///|
test "glob_match wildcard prefix" {
  inspect(glob_match("ghl-*", "ghl-001"), content="true")
  inspect(glob_match("ghl-*", "act-id-unique"), content="false")
}

///|
test "glob_match wildcard middle" {
  inspect(glob_match("act-*-unique", "act-id-unique"), content="true")
  inspect(glob_match("act-*-unique", "act-id-format"), content="false")
}

///|
test "glob_match question mark" {
  inspect(glob_match("act-?d-unique", "act-id-unique"), content="true")
  inspect(glob_match("act-?d-unique", "act-xx-unique"), content="false")
}

///|
/// Regression: a pathological pattern that would trigger exponential
/// backtracking under the previous recursive matcher must terminate
/// quickly and report no match.
test "glob_match no exponential backtracking on adversarial pattern" {
  // 20 alternating `*a` segments followed by `b` against an `a`-only string
  // — the prior matcher took ~O(n^k) here; this should complete instantly.
  let pat = "*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*b"
  let s = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  inspect(glob_match(pat, s), content="false")
}

///|
test "glob_match trailing star matches remainder" {
  inspect(glob_match("ghl-*", ""), content="false")
  inspect(glob_match("*", ""), content="true")
  inspect(glob_match("**", "anything"), content="true")
  inspect(glob_match("a*", "a"), content="true")
}

///|
test "glob_match wildcard before literal `*` in input" {
  // Rule IDs never contain `*`, but the matcher must not crash or
  // misclassify if a caller passes one — record the wildcard before
  // trying a literal match.
  inspect(glob_match("*", "**x"), content="true")
  inspect(glob_match("*", "*"), content="true")
  inspect(glob_match("*x", "**x"), content="true")
}

///|
test "parse_inline_ignores requires a `#` comment marker" {
  // Inside a real `# <tool>: ignore[...]` comment → recorded for that line.
  let with_hash =
    #|      - uses: a/b@v1 # zizmor: ignore[unpinned-uses]
  let m1 = parse_inline_ignores(with_hash)
  assert_true(m1.get(1) is Some(["unpinned-uses"]))
  // The same text as a quoted YAML value (no `#`) must NOT be treated as a
  // directive — otherwise keys/values could silently suppress findings.
  let no_hash =
    #|      - run: echo "zizmor: ignore[unpinned-uses]"
  let m2 = parse_inline_ignores(no_hash)
  assert_true(m2.get(1) is None)
  // A `#` further left on the line (content before the comment) still works.
  let trailing =
    #|    env: { X: 1 } # karinto: ignore[a, b]
  let m3 = parse_inline_ignores(trailing)
  assert_true(m3.get(1) is Some(["a", "b"]))
}
