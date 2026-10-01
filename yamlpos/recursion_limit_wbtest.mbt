///|
fn nested_flow(depth : Int) -> String {
  let buf = StringBuilder::new()
  for _ in 0..<depth {
    buf.write_char('[')
  }
  for _ in 0..<depth {
    buf.write_char(']')
  }
  buf.to_string()
}

///|
/// `depth` levels of block mappings: `a:` / ` a:` / `  a:` ... ending in a
/// scalar, so every level is a node the parser descends into.
fn nested_block(depth : Int) -> String {
  let buf = StringBuilder::new()
  for i in 0..<(depth - 1) {
    for _ in 0..<i {
      buf.write_char(' ')
    }
    buf.write_string("a:\n")
  }
  for _ in 0..<(depth - 1) {
    buf.write_char(' ')
  }
  buf.write_string("x\n")
  buf.to_string()
}

///|
fn load_error_message(source : String) -> String? {
  try Yaml::load_from_string(source) catch {
    e => Some(e.message())
  } noraise {
    _ => None
  }
}

///|
test "flow nesting at MAX_DEPTH parses" {
  assert_eq(load_error_message(nested_flow(MAX_DEPTH)), None)
}

///|
test "flow nesting beyond MAX_DEPTH reports the recursion limit" {
  assert_eq(
    load_error_message(nested_flow(MAX_DEPTH + 1)),
    Some("recursion limit exceeded"),
  )
}

///|
test "block nesting at MAX_DEPTH parses" {
  assert_eq(load_error_message(nested_block(MAX_DEPTH)), None)
}

///|
test "block nesting beyond MAX_DEPTH reports the recursion limit" {
  assert_eq(
    load_error_message(nested_block(MAX_DEPTH + 1)),
    Some("recursion limit exceeded"),
  )
}
