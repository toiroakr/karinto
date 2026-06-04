///| Broader YAML-test-suite-style conformance cases.

///|
fn d(src : String) -> String {
  match @yamlpos.parse(src).root {
    Some(n) => n.dump()
    None => "<empty>"
  }
}

///|
test "sequence of mappings" {
  let src =
    #|steps:
    #|  - name: checkout
    #|    uses: actions/checkout@v4
    #|  - name: build
    #|    run: make
    #|
  inspect(
    d(src),
    content=(
      #|Mapping [0,85,85]
      #|  key:
      #|    Scalar str:"steps" style=Plain [0,5,5]
      #|  val:
      #|    Sequence [9,85,85]
      #|      Mapping [11,55,55]
      #|        key:
      #|          Scalar str:"name" style=Plain [11,15,15]
      #|        val:
      #|          Scalar str:"checkout" style=Plain [17,25,25]
      #|        key:
      #|          Scalar str:"uses" style=Plain [30,34,34]
      #|        val:
      #|          Scalar str:"actions/checkout@v4" style=Plain [36,55,55]
      #|      Mapping [60,85,85]
      #|        key:
      #|          Scalar str:"name" style=Plain [60,64,64]
      #|        val:
      #|          Scalar str:"build" style=Plain [66,71,71]
      #|        key:
      #|          Scalar str:"run" style=Plain [76,79,79]
      #|        val:
      #|          Scalar str:"make" style=Plain [81,85,85]
      #|
    ),
  )
}

///|
test "multiline plain scalar" {
  let src =
    #|msg: this is
    #|  a folded
    #|  plain scalar
    #|
  inspect(
    d(src),
    content=(
      #|Mapping [0,38,38]
      #|  key:
      #|    Scalar str:"msg" style=Plain [0,3,3]
      #|  val:
      #|    Scalar str:"this is a folded plain scalar" style=Plain [5,38,38]
      #|
    ),
  )
}

///|
test "multiline flow" {
  let src =
    #|matrix: [
    #|  1,
    #|  2,
    #|  3
    #|]
    #|
  inspect(
    d(src),
    content=(
      #|Mapping [0,25,25]
      #|  key:
      #|    Scalar str:"matrix" style=Plain [0,6,6]
      #|  val:
      #|    Sequence [8,25,25]
      #|      Scalar int:1 style=Plain [12,13,13]
      #|      Scalar int:2 style=Plain [17,18,18]
      #|      Scalar int:3 style=Plain [22,23,23]
      #|
    ),
  )
}

///|
test "nested sequences" {
  let src =
    #|- - a
    #|  - b
    #|- - c
    #|
  inspect(
    d(src),
    content=(
      #|Sequence [0,17,17]
      #|  Sequence [2,11,11]
      #|    Scalar str:"a" style=Plain [4,5,5]
      #|    Scalar str:"b" style=Plain [10,11,11]
      #|  Sequence [14,17,17]
      #|    Scalar str:"c" style=Plain [16,17,17]
      #|
    ),
  )
}

///|
test "empty and null values" {
  let src =
    #|a:
    #|b: ~
    #|c: null
    #|d:
    #|  - 1
    #|
  inspect(
    d(src),
    content=(
      #|Mapping [0,24,24]
      #|  key:
      #|    Scalar str:"a" style=Plain [0,1,1]
      #|  val:
      #|    Scalar null style=Plain [2,2,2]
      #|  key:
      #|    Scalar str:"b" style=Plain [3,4,4]
      #|  val:
      #|    Scalar null style=Plain [6,7,7]
      #|  key:
      #|    Scalar str:"c" style=Plain [8,9,9]
      #|  val:
      #|    Scalar null style=Plain [11,15,15]
      #|  key:
      #|    Scalar str:"d" style=Plain [16,17,17]
      #|  val:
      #|    Sequence [21,24,24]
      #|      Scalar int:1 style=Plain [23,24,24]
      #|
    ),
  )
}

///|
test "number forms" {
  inspect(
    d("[-5, 0x1F, 0o17, 1.5e3, -.inf, .nan]\n"),
    content=(
      #|Sequence [0,36,36]
      #|  Scalar int:-5 style=Plain [1,3,3]
      #|  Scalar int:31 style=Plain [5,9,9]
      #|  Scalar int:15 style=Plain [11,15,15]
      #|  Scalar float:1500 style=Plain [17,22,22]
      #|  Scalar float:-Infinity style=Plain [24,29,29]
      #|  Scalar float:NaN style=Plain [31,35,35]
      #|
    ),
  )
}

///|
test "quoted keys" {
  let src =
    #|"quoted key": value
    #|'single': 1
    #|
  inspect(
    d(src),
    content=(
      #|Mapping [0,31,31]
      #|  key:
      #|    Scalar str:"quoted key" style=DoubleQuoted [0,12,12]
      #|  val:
      #|    Scalar str:"value" style=Plain [14,19,19]
      #|  key:
      #|    Scalar str:"single" style=SingleQuoted [20,28,28]
      #|  val:
      #|    Scalar int:1 style=Plain [30,31,31]
      #|
    ),
  )
}

///|
test "flow map as key" {
  inspect(
    d("{a: 1}: mapped\n"),
    content=(
      #|Mapping [0,14,14]
      #|  key:
      #|    Mapping [0,6,6]
      #|      key:
      #|        Scalar str:"a" style=Plain [1,2,2]
      #|      val:
      #|        Scalar int:1 style=Plain [4,5,5]
      #|  val:
      #|    Scalar str:"mapped" style=Plain [8,14,14]
      #|
    ),
  )
}

///|
test "multi-doc roots" {
  let docs = @yamlpos.parse_documents(
    (
      #|---
      #|first: 1
      #|---
      #|second: 2
      #|...
    ),
  )
  inspect(docs.length(), content="2")
}

///|
test "local and verbatim tags" {
  inspect(
    d("a: !foo bar\nb: !<tag:example.com,2024:t> baz\n"),
    content=(
      #|Mapping [0,44,44]
      #|  key:
      #|    Scalar str:"a" style=Plain [0,1,1]
      #|  val:
      #|    Scalar str:"bar" style=Plain [3,11,11] tag=!foo
      #|  key:
      #|    Scalar str:"b" style=Plain [12,13,13]
      #|  val:
      #|    Scalar str:"baz" style=Plain [15,44,44] tag=tag:example.com,2024:t
      #|
    ),
  )
}

///|
test "alias to collection" {
  let src =
    #|base: &b
    #|  x: 1
    #|  y: 2
    #|ref: *b
    #|
  inspect(
    d(src),
    content=(
      #|Mapping [0,30,30]
      #|  key:
      #|    Scalar str:"base" style=Plain [0,4,4]
      #|  val:
      #|    Mapping [6,22,22] &b
      #|      key:
      #|        Scalar str:"x" style=Plain [11,12,12]
      #|      val:
      #|        Scalar int:1 style=Plain [14,15,15]
      #|      key:
      #|        Scalar str:"y" style=Plain [18,19,19]
      #|      val:
      #|        Scalar int:2 style=Plain [21,22,22]
      #|  key:
      #|    Scalar str:"ref" style=Plain [23,26,26]
      #|  val:
      #|    Alias *b [28,30,30]
      #|
    ),
  )
}
