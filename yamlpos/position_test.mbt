///| Position-correctness tests: exact 1-based (line, col) via LineCounter.

///|
test "line_counter basic" {
  let lc = @yamlpos.LineCounter::from_source("abc\ndef\nghi\n")
  assert_true(lc.line_col(0) == (1, 1))
  assert_true(lc.line_col(2) == (1, 3))
  assert_true(lc.line_col(4) == (2, 1))
  assert_true(lc.line_col(8) == (3, 1))
  assert_true(lc.line_col(10) == (3, 3))
}

///|
test "line_counter crlf" {
  let lc = @yamlpos.LineCounter::from_source("ab\r\ncd\r\n")
  assert_true(lc.line_col(0) == (1, 1))
  assert_true(lc.line_col(4) == (2, 1))
}

///|
/// Position of a mapping key, a nested sequence item, and a scalar inside a
/// flow collection.
test "node positions" {
  let src =
    #|root:
    #|  list:
    #|    - alpha
    #|    - beta
    #|  flow: [x, y, z]
    #|
  let result = @yamlpos.parse_with_positions(src)
  let lc = result.line_counter
  let doc = result.documents[0]
  let root = doc.root.unwrap()
  // root mapping
  let entries = match root {
    Mapping(es, ..) => es
    _ => abort("expected mapping")
  }
  // key "root" at line 1 col 1
  let (rk, _) = entries[0]
  assert_true(rk.start_pos(lc) == (1, 1))
  // value is a mapping with keys list, flow
  let inner = match entries[0].1 {
    Mapping(es, ..) => es
    _ => abort("expected inner mapping")
  }
  // "list" key at line 2 col 3
  assert_true(inner[0].0.start_pos(lc) == (2, 3))
  // list value is a sequence; second item "beta" at line 4 col 7
  let seq = match inner[0].1 {
    Sequence(items, ..) => items
    _ => abort("expected sequence")
  }
  assert_true(seq[1].start_pos(lc) == (4, 7))
  // "flow" key at line 5 col 3
  assert_true(inner[1].0.start_pos(lc) == (5, 3))
  // flow seq value; third element "z" — flow seq is [x, y, z] starting col 9
  let flow = match inner[1].1 {
    Sequence(items, ..) => items
    _ => abort("expected flow sequence")
  }
  assert_true(flow[2].start_pos(lc) == (5, 16))
}

///|
/// The key test: a node *after* a block scalar whose body contains decoy
/// `- x` and `k:` lines must get the correct position (the decoys must not be
/// parsed as structure).
test "position after block scalar with decoy lines" {
  let src =
    #|script: |
    #|  - not a seq item
    #|  key: not a mapping
    #|  echo done
    #|after: here
    #|
  let result = @yamlpos.parse_with_positions(src)
  let lc = result.line_counter
  let root = result.documents[0].root.unwrap()
  let entries = match root {
    Mapping(es, ..) => es
    _ => abort("expected mapping")
  }
  // Two entries only: "script" and "after". The decoys are inside the scalar.
  assert_true(entries.length() == 2)
  // The block scalar value preserves the decoy lines literally.
  let script_val = entries[0].1
  assert_true(
    script_val.as_string() ==
    Some("- not a seq item\nkey: not a mapping\necho done\n"),
  )
  // "after" key is on line 5 col 1.
  assert_true(entries[1].0.start_pos(lc) == (5, 1))
  // its value "here" on line 5 col 8.
  assert_true(entries[1].1.start_pos(lc) == (5, 8))
}

///|
test "scalar inside flow inside block" {
  let src =
    #|matrix:
    #|  include:
    #|    - { os: linux, node: 18 }
    #|
  let result = @yamlpos.parse_with_positions(src)
  let lc = result.line_counter
  let root = result.documents[0].root.unwrap()
  let m = match root {
    Mapping(es, ..) => es
    _ => abort("map")
  }
  let inc = match m[0].1 {
    Mapping(es, ..) => es
    _ => abort("map")
  }
  let seq = match inc[0].1 {
    Sequence(items, ..) => items
    _ => abort("seq")
  }
  let flow = match seq[0] {
    Mapping(es, ..) => es
    _ => abort("flowmap")
  }
  // "node" key: line 3 col 20
  assert_true(flow[1].0.start_pos(lc) == (3, 20))
  // value 18: line 3 col 26
  assert_true(flow[1].1.start_pos(lc) == (3, 26))
}
