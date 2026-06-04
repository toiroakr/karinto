///| Robustness: comments, blank lines, BOM, colon-in-value, surrogate pairs,
/// block scalar indent indicators and chomping.

///|
fn dr(src : String) -> String {
  match @yamlpos.parse(src).root {
    Some(n) => n.dump()
    None => "<empty>"
  }
}

///|
test "comments and blank lines tolerated" {
  let src =
    #|# leading comment
    #|
    #|foo: bar  # trailing comment
    #|
    #|# another
    #|baz: 2
    #|
  inspect(
    dr(src),
    content=(
      #|Mapping [19,65,65]
      #|  key:
      #|    Scalar str:"foo" style=Plain [19,22,22]
      #|  val:
      #|    Scalar str:"bar" style=Plain [24,27,27]
      #|  key:
      #|    Scalar str:"baz" style=Plain [59,62,62]
      #|  val:
      #|    Scalar int:2 style=Plain [64,65,65]
      #|
    ),
  )
}

///|
test "byte order mark" {
  let src = "\u{FEFF}a: 1\n"
  inspect(
    dr(src),
    content=(
      #|Mapping [1,5,5]
      #|  key:
      #|    Scalar str:"a" style=Plain [1,2,2]
      #|  val:
      #|    Scalar int:1 style=Plain [4,5,5]
      #|
    ),
  )
}

///|
test "double-quoted unicode escape and surrogate" {
  let n = @yamlpos.parse(
    (
      #|"smile \U0001F600 end"
    ),
  ).root.unwrap()
  let s = n.as_string().unwrap()
  // "smile " (6) + emoji (2 UTF-16 units) + " end" (4) = 12.
  inspect(s.length(), content="12")
}

///|
test "empty document" {
  inspect(dr(""), content="<empty>")
  inspect(dr("# only a comment\n"), content="<empty>")
}

///|
test "scalar with colon in value not a map" {
  inspect(
    dr("url: http://example.com\n"),
    content=(
      #|Mapping [0,23,23]
      #|  key:
      #|    Scalar str:"url" style=Plain [0,3,3]
      #|  val:
      #|    Scalar str:"http://example.com" style=Plain [5,23,23]
      #|
    ),
  )
}

///|
test "block scalar explicit indent indicator" {
  let src =
    #|t: |2
    #|    indented
    #|  body
    #|
  inspect(
    dr(src),
    content=(
      #|Mapping [0,26,26]
      #|  key:
      #|    Scalar str:"t" style=Plain [0,1,1]
      #|  val:
      #|    Scalar str:"  indented\nbody\n" style=Literal [3,26,26]
      #|
    ),
  )
}

///|
test "block scalar keep chomping" {
  let src =
    #|t: |+
    #|  x
    #|
    #|
  inspect(
    dr(src),
    content=(
      #|Mapping [0,11,11]
      #|  key:
      #|    Scalar str:"t" style=Plain [0,1,1]
      #|  val:
      #|    Scalar str:"x\n\n" style=Literal [3,11,11]
      #|
    ),
  )
}
