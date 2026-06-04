///|
/// Helper: parse a single-document source and dump its root.
fn dump1(src : String) -> String {
  let doc = @yamlpos.parse(src)
  match doc.root {
    Some(n) => n.dump()
    None => "<empty>"
  }
}

///|
test "plain scalar string" {
  inspect(
    dump1("hello world\n"),
    content=(
      #|Scalar str:"hello world" style=Plain [0,11,11]
      #|
    ),
  )
}

///|
test "core schema scalars" {
  inspect(
    dump1("[true, false, null, 42, 3.14, ~]\n"),
    content=(
      #|Sequence [0,32,32]
      #|  Scalar bool:true style=Plain [1,5,5]
      #|  Scalar bool:false style=Plain [7,12,12]
      #|  Scalar null style=Plain [14,18,18]
      #|  Scalar int:42 style=Plain [20,22,22]
      #|  Scalar float:3.14 style=Plain [24,28,28]
      #|  Scalar null style=Plain [30,31,31]
      #|
    ),
  )
}

///|
test "block mapping" {
  inspect(
    dump1("foo: bar\nbaz: 1\n"),
    content=(
      #|Mapping [0,15,15]
      #|  key:
      #|    Scalar str:"foo" style=Plain [0,3,3]
      #|  val:
      #|    Scalar str:"bar" style=Plain [5,8,8]
      #|  key:
      #|    Scalar str:"baz" style=Plain [9,12,12]
      #|  val:
      #|    Scalar int:1 style=Plain [14,15,15]
      #|
    ),
  )
}

///|
test "nested block mapping and sequence" {
  let src =
    #|root:
    #|  items:
    #|    - one
    #|    - two
    #|  name: test
    #|
  inspect(
    dump1(src),
    content=(
      #|Mapping [0,47,47]
      #|  key:
      #|    Scalar str:"root" style=Plain [0,4,4]
      #|  val:
      #|    Mapping [8,47,47]
      #|      key:
      #|        Scalar str:"items" style=Plain [8,13,13]
      #|      val:
      #|        Sequence [19,34,34]
      #|          Scalar str:"one" style=Plain [21,24,24]
      #|          Scalar str:"two" style=Plain [31,34,34]
      #|      key:
      #|        Scalar str:"name" style=Plain [37,41,41]
      #|      val:
      #|        Scalar str:"test" style=Plain [43,47,47]
      #|
    ),
  )
}

///|
test "flow collections" {
  inspect(
    dump1("{a: 1, b: [2, 3], c: {d: 4}}\n"),
    content=(
      #|Mapping [0,28,28]
      #|  key:
      #|    Scalar str:"a" style=Plain [1,2,2]
      #|  val:
      #|    Scalar int:1 style=Plain [4,5,5]
      #|  key:
      #|    Scalar str:"b" style=Plain [7,8,8]
      #|  val:
      #|    Sequence [10,16,16]
      #|      Scalar int:2 style=Plain [11,12,12]
      #|      Scalar int:3 style=Plain [14,15,15]
      #|  key:
      #|    Scalar str:"c" style=Plain [18,19,19]
      #|  val:
      #|    Mapping [21,27,27]
      #|      key:
      #|        Scalar str:"d" style=Plain [22,23,23]
      #|      val:
      #|        Scalar int:4 style=Plain [25,26,26]
      #|
    ),
  )
}

///|
test "double quoted escapes" {
  inspect(
    dump1(
      (
        #|"tab\there\nnewline é \x41"
        #|
      ),
    ),
    content=(
      #|Scalar str:"tab\there\nnewline é A" style=DoubleQuoted [0,27,27]
      #|
    ),
  )
}

///|
test "single quoted" {
  inspect(
    dump1("'it''s a test'\n"),
    content=(
      #|Scalar str:"it's a test" style=SingleQuoted [0,14,14]
      #|
    ),
  )
}

///|
test "literal block scalar" {
  let src =
    #|text: |
    #|  line one
    #|  line two
    #|
  inspect(
    dump1(src),
    content=(
      #|Mapping [0,30,30]
      #|  key:
      #|    Scalar str:"text" style=Plain [0,4,4]
      #|  val:
      #|    Scalar str:"line one\nline two\n" style=Literal [6,30,30]
      #|
    ),
  )
}

///|
test "folded block scalar" {
  let src =
    #|text: >
    #|  folded line
    #|  continues here
    #|
  inspect(
    dump1(src),
    content=(
      #|Mapping [0,39,39]
      #|  key:
      #|    Scalar str:"text" style=Plain [0,4,4]
      #|  val:
      #|    Scalar str:"folded line continues here\n" style=Folded [6,39,39]
      #|
    ),
  )
}

///|
test "block scalar strip chomping" {
  let src =
    #|text: |-
    #|  no trailing newline
    #|
  inspect(
    dump1(src),
    content=(
      #|Mapping [0,31,31]
      #|  key:
      #|    Scalar str:"text" style=Plain [0,4,4]
      #|  val:
      #|    Scalar str:"no trailing newline" style=Literal [6,31,31]
      #|
    ),
  )
}

///|
test "anchors and aliases" {
  let src =
    #|a: &x hello
    #|b: *x
    #|
  inspect(
    dump1(src),
    content=(
      #|Mapping [0,17,17]
      #|  key:
      #|    Scalar str:"a" style=Plain [0,1,1]
      #|  val:
      #|    Scalar str:"hello" style=Plain [3,11,11] &x
      #|  key:
      #|    Scalar str:"b" style=Plain [12,13,13]
      #|  val:
      #|    Alias *x [15,17,17]
      #|
    ),
  )
}

///|
test "merge keys" {
  let src =
    #|defaults: &d
    #|  timeout: 30
    #|  retries: 3
    #|server:
    #|  <<: *d
    #|  retries: 5
    #|
  inspect(
    dump1(src),
    content=(
      #|Mapping [0,69,69]
      #|  key:
      #|    Scalar str:"defaults" style=Plain [0,8,8]
      #|  val:
      #|    Mapping [10,39,39] &d
      #|      key:
      #|        Scalar str:"timeout" style=Plain [15,22,22]
      #|      val:
      #|        Scalar int:30 style=Plain [24,26,26]
      #|      key:
      #|        Scalar str:"retries" style=Plain [29,36,36]
      #|      val:
      #|        Scalar int:3 style=Plain [38,39,39]
      #|  key:
      #|    Scalar str:"server" style=Plain [40,46,46]
      #|  val:
      #|    Mapping [50,69,69]
      #|      key:
      #|        Scalar str:"timeout" style=Plain [15,22,22]
      #|      val:
      #|        Scalar int:30 style=Plain [24,26,26]
      #|      key:
      #|        Scalar str:"retries" style=Plain [59,66,66]
      #|      val:
      #|        Scalar int:5 style=Plain [68,69,69]
      #|
    ),
  )
}

///|
test "tags" {
  inspect(
    dump1("val: !!str 123\n"),
    content=(
      #|Mapping [0,14,14]
      #|  key:
      #|    Scalar str:"val" style=Plain [0,3,3]
      #|  val:
      #|    Scalar str:"123" style=Plain [5,14,14] tag=tag:yaml.org,2002:str
      #|
    ),
  )
}

///|
test "explicit key" {
  let src =
    #|? complex
    #|: value
    #|
  inspect(
    dump1(src),
    content=(
      #|Mapping [0,17,17]
      #|  key:
      #|    Scalar str:"complex" style=Plain [2,9,9]
      #|  val:
      #|    Scalar str:"value" style=Plain [12,17,17]
      #|
    ),
  )
}

///|
test "multi document" {
  let docs = @yamlpos.parse_documents("a: 1\n---\nb: 2\n...\n")
  inspect(docs.length(), content="2")
}

///|
test "directives and tag handle" {
  let src =
    #|%YAML 1.2
    #|---
    #|key: value
    #|
  inspect(
    dump1(src),
    content=(
      #|Mapping [14,24,24]
      #|  key:
      #|    Scalar str:"key" style=Plain [14,17,17]
      #|  val:
      #|    Scalar str:"value" style=Plain [19,24,24]
      #|
    ),
  )
}
