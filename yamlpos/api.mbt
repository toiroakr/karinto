///| Public convenience API tying nodes to source positions.

///|
/// Resolve a node's start offset to a 1-based `(line, col)` via a LineCounter.
pub fn Node::start_pos(self : Node, lc : LineCounter) -> (Int, Int) {
  lc.line_col(self.range().start)
}

///|
/// A parse result bundling the documents and a LineCounter built from the same
/// source, so callers can resolve any node's position.
pub struct ParseResult {
  documents : Array[Document]
  line_counter : LineCounter
}

///|
/// Parse source into documents plus a ready LineCounter.
pub fn parse_with_positions(source : String) -> ParseResult {
  {
    documents: parse_documents(source),
    line_counter: LineCounter::from_source(source),
  }
}

///|
/// The decoded string of a scalar node, or None for non-scalars.
pub fn Node::as_string(self : Node) -> String? {
  match self {
    Scalar(Str(s), ..) => Some(s)
    _ => None
  }
}

///|
/// Pretty, stable textual rendering of a node tree for snapshot tests
/// (positions included as offsets).
pub fn Node::dump(self : Node) -> String {
  let sb = StringBuilder::new()
  dump_node(self, sb, 0)
  sb.to_string()
}

///|
fn dump_node(n : Node, sb : StringBuilder, indent : Int) -> Unit {
  let pad = String::make(indent * 2, ' ')
  match n {
    Scalar(v, style~, range~, tag~, anchor~) => {
      sb.write_string(pad)
      sb.write_string("Scalar ")
      sb.write_string(scalar_value_str(v))
      sb.write_string(" style=")
      sb.write_string(
        match style {
          Plain => "Plain"
          SingleQuoted => "SingleQuoted"
          DoubleQuoted => "DoubleQuoted"
          Literal => "Literal"
          Folded => "Folded"
        },
      )
      sb.write_string(range_str(range))
      write_props(sb, tag, anchor)
      sb.write_char('\n')
    }
    Alias(name~, range~, ..) => {
      sb.write_string(pad)
      sb.write_string("Alias *")
      sb.write_string(name)
      sb.write_string(range_str(range))
      sb.write_char('\n')
    }
    Sequence(items, range~, tag~, anchor~) => {
      sb.write_string(pad)
      sb.write_string("Sequence")
      sb.write_string(range_str(range))
      write_props(sb, tag, anchor)
      sb.write_char('\n')
      for it in items {
        dump_node(it, sb, indent + 1)
      }
    }
    Mapping(entries, range~, tag~, anchor~) => {
      sb.write_string(pad)
      sb.write_string("Mapping")
      sb.write_string(range_str(range))
      write_props(sb, tag, anchor)
      sb.write_char('\n')
      for e in entries {
        let (k, v) = e
        sb.write_string(pad)
        sb.write_string("  key:\n")
        dump_node(k, sb, indent + 2)
        sb.write_string(pad)
        sb.write_string("  val:\n")
        dump_node(v, sb, indent + 2)
      }
    }
  }
}

///|
fn write_props(sb : StringBuilder, tag : String?, anchor : String?) -> Unit {
  match tag {
    Some(t) => {
      sb.write_string(" tag=")
      sb.write_string(t)
    }
    None => ()
  }
  match anchor {
    Some(a) => {
      sb.write_string(" &")
      sb.write_string(a)
    }
    None => ()
  }
}

///|
fn range_str(r : Range) -> String {
  " [" +
  r.start.to_string() +
  "," +
  r.value_end.to_string() +
  "," +
  r.node_end.to_string() +
  "]"
}

///|
fn scalar_value_str(v : ScalarValue) -> String {
  match v {
    Null => "null"
    Bool(b) => "bool:" + b.to_string()
    Int(n) => "int:" + n.to_string()
    Float(f, ..) => "float:" + f.to_string()
    Str(s) => "str:" + escape_for_dump(s)
    Bad => "bad"
  }
}

///|
fn escape_for_dump(s : String) -> String {
  let sb = StringBuilder::new()
  sb.write_char('"')
  for c in s {
    match c {
      '\n' => sb.write_string("\\n")
      '\t' => sb.write_string("\\t")
      '\r' => sb.write_string("\\r")
      _ => sb.write_char(c)
    }
  }
  sb.write_char('"')
  sb.to_string()
}
