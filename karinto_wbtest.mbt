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
  assert_true(
    m1.get(1) is Some({ patterns: ["unpinned-uses"], pure_comment: false }),
  )
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
  assert_true(m3.get(1) is Some({ patterns: ["a", "b"], pure_comment: false }))
  // A `#` *inside* a quoted scalar is data, not a comment marker — it must not
  // be treated as a directive even though the text reads like one.
  let hash_in_quotes =
    #|      - run: echo "# zizmor: ignore[unpinned-uses]"
  let m4 = parse_inline_ignores(hash_in_quotes)
  assert_true(m4.get(1) is None)
  // …but a real trailing comment after a quoted scalar is still honoured.
  let quote_then_comment =
    #|      - run: echo "hi" # zizmor: ignore[unpinned-uses]
  let m5 = parse_inline_ignores(quote_then_comment)
  assert_true(
    m5.get(1) is Some({ patterns: ["unpinned-uses"], pure_comment: false }),
  )
  // A line that is *only* the comment (nothing but whitespace before `#`) is
  // `pure_comment: true` — the signal that lets `is_inline_ignored` treat it
  // as referring to the line below.
  let standalone =
    #|      # zizmor: ignore[unpinned-uses]
  let m6 = parse_inline_ignores(standalone)
  assert_true(
    m6.get(1) is Some({ patterns: ["unpinned-uses"], pure_comment: true }),
  )
}

///|
test "extract_expr_bodies: `}}` inside a quoted literal does not truncate the body" {
  // The terminator scan skips single-quoted literals, so a `}}` inside one
  // (escaped or not) stays in the body and the real expression after it is
  // preserved. A naive first-`}}` scan would cut the body to `hashFiles('a`,
  // dropping the trailing `&& githab.ref` and hiding the typo from downstream
  // context checks.
  let bodies = extract_expr_bodies(
    "x ${{ hashFiles('a}}b') != '' && githab.ref }} y",
  )
  assert_eq(bodies.length(), 1)
  assert_eq(bodies[0], " hashFiles('a}}b') != '' && githab.ref ")
  // GitHub escapes a literal quote by doubling it; a doubled quote stays inside
  // the string, so the literal `'it''s }}'` is one unit and does not terminate.
  let escaped = extract_expr_bodies("${{ 'it''s }}' == github.ref }}")
  assert_eq(escaped.length(), 1)
  assert_eq(escaped[0], " 'it''s }}' == github.ref ")
  // Plain bodies (no literal) are unaffected.
  let plain = extract_expr_bodies("${{ github.ref }}")
  assert_eq(plain.length(), 1)
  assert_eq(plain[0], " github.ref ")
}

///|
test "is_jobs_key_line: bare header, spacing variants, and inline values" {
  assert_true(is_jobs_key_line("jobs:"))
  assert_true(is_jobs_key_line("jobs: # top-level jobs"))
  assert_true(is_jobs_key_line("jobs:    # extra spaces before comment"))
  assert_true(is_jobs_key_line("jobs:#no space before comment"))
  // An inline value means this isn't a block-mapping header, even though
  // the first character after the key is whitespace.
  assert_true(!is_jobs_key_line("jobs: {}"))
  assert_true(!is_jobs_key_line("jobs: read-all"))
  assert_true(!is_jobs_key_line("jobsfoo:"))
}

///|
test "build_line_job_map: an indented `jobs:`-looking line before the real header is not mistaken for it" {
  // `jobs:` is only ever valid at the workflow's top level (indent 0). A
  // decoy line that happens to start with `jobs:` at a deeper indent — e.g.
  // inside an earlier top-level field's block-scalar body — must not be
  // mistaken for the real header, or the state machine loses track of the
  // real `jobs:` section entirely (see below).
  let lines = [
    "name: |", "  jobs:", "  fake example text, not real YAML structure", "on: push",
    "jobs:", "  build:", "    runs-on: ubuntu-latest",
  ]
  let owners = build_line_job_map(lines)
  assert_true(owners[5] is Some("build"))
  assert_true(owners[6] is Some("build"))
}
