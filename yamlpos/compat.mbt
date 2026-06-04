///|
/// `moonbit-community/yaml`-compatible value API.
///
/// karinto's rule engine was written against that package's position-free
/// `Yaml` value tree. To drop the external dependency without rewriting every
/// rule, this module exposes a structurally identical `Yaml` enum plus a
/// `load_from_string` that parses with this package's parser and converts the
/// position-carrying `Node` tree into the legacy value tree (scalars decoded,
/// anchors/aliases resolved, merge keys already applied by the parser).
///
/// Source positions are obtained separately via `parse_with_positions`, which
/// retains the `Node` tree.

///|
/// Structurally identical to the legacy `moonbit-community/yaml` `Yaml` enum.
pub(all) enum Yaml {
  Real(Double, repr~ : String)
  Integer(Int64)
  String(String)
  Boolean(Bool)
  Array(Array[Yaml])
  Map(Map[String, Yaml])
  Null
  BadValue
} derive(Eq, Debug)

///|
/// Render a `Yaml` value the way the reference `moonbit-community/yaml`
/// derives `Show` (string payloads are quoted, mirroring `Debug`). This keeps
/// the copied compatibility test's `inspect(..)` assertions (e.g.
/// `String("string")`) matching without relying on the deprecated
/// `derive(Show)` whose output diverged across MoonBit versions.
pub impl Show for Yaml with fn output(self, logger) {
  let s = match self {
    Null => "Null"
    BadValue => "BadValue"
    Boolean(b) => "Boolean(\{b})"
    Integer(n) => "Integer(\{n})"
    Real(f, repr~) => "Real(\{f}, repr=\{repr.escape()})"
    String(v) => "String(\{v.escape()})"
    Array(a) => {
      let parts = a.map(fn(y) { y.to_string() })
      "Array([\{parts.iter().intersperse(", ").fold(init="", fn(acc, p) { acc + p })}])"
    }
    Map(m) => {
      let parts = m
        .iter()
        .map(fn(kv) {
          let (k, v) = kv
          "(\{k.escape()}, \{v})"
        })
        .collect()
      "Map([\{parts.iter().intersperse(", ").fold(init="", fn(acc, p) { acc + p })}])"
    }
  }
  logger.write_string(s)
}

///|
/// JSON projection identical to `moonbit-community/yaml`'s, so callers (and
/// compatibility tests) can compare the two parsers' output directly.
pub impl ToJson for Yaml with fn to_json(self) {
  match self {
    Null => Json::null()
    Map(m) => Json::object(m.map(fn(_k, y) { y.to_json() }))
    Array(a) => Json::array(a.map(fn(y) { y.to_json() }))
    Boolean(b) => Json::boolean(b)
    String(s) => Json::string(s)
    Integer(i) => Json::number(i.to_double())
    Real(f, repr~) => Json::number(f, repr~)
    BadValue => Json::null()
  }
}

///|
/// Raised by `load_from_string` / `parse_for_lint` when the source fails to
/// parse.
pub suberror LoadError {
  LoadError(String)
} derive(Debug)

///|
/// The human-readable parse error message.
pub fn LoadError::message(self : LoadError) -> String {
  match self {
    LoadError(m) => m
  }
}

///|
/// Parse `source` into legacy `Yaml` documents. Mirrors the signature of
/// `moonbit-community/yaml`'s `Yaml::load_from_string`.
pub fn Yaml::load_from_string(
  source : StringView,
) -> Array[Yaml] raise LoadError {
  let s = source.to_owned()
  let toks = lex(s)
  let p = Parser::new(s, toks)
  let docs = p.parse_stream()
  let out : Array[Yaml] = []
  for d in docs {
    for e in d.errors {
      raise LoadError(e.message)
    }
    out.push(node_to_yaml(d.root, p.anchors))
  }
  out
}

///|
fn node_to_yaml(node : Node?, anchors : Map[String, Node]) -> Yaml {
  match node {
    None => Null
    Some(n) => convert(n, anchors)
  }
}

///|
fn convert(n : Node, anchors : Map[String, Node]) -> Yaml {
  match n {
    Scalar(v, ..) => scalar_to_yaml(v)
    Sequence(items, ..) => {
      let arr : Array[Yaml] = []
      for it in items {
        arr.push(convert(it, anchors))
      }
      Array(arr)
    }
    Mapping(entries, ..) => {
      let m : Map[String, Yaml] = {}
      for e in entries {
        let (k, val) = e
        let key = yaml_key_string(convert(k, anchors))
        // The reference parser uses an empty string as the "no key yet"
        // placeholder in its key stack, so a genuinely empty key collapses the
        // entry (the value is reinterpreted as the next key and ultimately
        // dropped). Mirror that by skipping empty-keyed entries.
        if key == "" {
          continue
        }
        m[key] = convert(val, anchors)
      }
      Map(m)
    }
    Alias(name~, resolved~, ..) =>
      if !resolved {
        BadValue
      } else {
        match anchors.get(name) {
          Some(target) => convert(target, anchors)
          None => BadValue
        }
      }
  }
}

///|
fn scalar_to_yaml(v : ScalarValue) -> Yaml {
  match v {
    Null => Null
    Bool(b) => Boolean(b)
    Int(n) => Integer(n)
    Float(f, repr~) => Real(f, repr~)
    Str(s) => String(s)
    Bad => BadValue
  }
}

///|
/// Collapse a converted key node to the string used in a `Map`. YAML mapping
/// keys in workflows are strings; non-string keys are stringified rather than
/// rejected.
fn yaml_key_string(y : Yaml) -> String {
  match y {
    String(s) => s
    Integer(n) => n.to_string()
    Boolean(b) => b.to_string()
    Real(_, repr~) => repr
    Null => "null"
    _ => ""
  }
}

///|
/// One-shot parse for the linter. A single lex+parse pass yields the legacy
/// value tree (for the rule engine), the position-carrying node tree, and the
/// line counter — so `lint` never parses the source twice.
pub struct LintParse {
  documents : Array[Yaml]
  position_root : Node?
  line_counter : LineCounter
}

///|
pub fn parse_for_lint(source : String) -> LintParse raise LoadError {
  let toks = lex(source)
  let lc = LineCounter::from_source(source)
  let p = Parser::new(source, toks)
  let docs = p.parse_stream()
  let values : Array[Yaml] = []
  for d in docs {
    for e in d.errors {
      raise LoadError(e.message)
    }
    values.push(node_to_yaml(d.root, p.anchors))
  }
  let position_root = if docs.length() > 0 { docs[0].root } else { None }
  { documents: values, position_root, line_counter: lc }
}
