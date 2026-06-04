///| Flow collections (`[...]`, `{...}`), quoted scalars and block scalars.

///|
/// Parse a flow collection beginning at `{` or `[`.
fn Parser::parse_flow(
  self : Parser,
  anchor : String?,
  tag : String?,
  start : Int,
) -> Node {
  let open = self.peek().unwrap()
  let is_map = open.kind == FlowMapStart
  self.i = self.i + 1
  if is_map {
    self.parse_flow_map(start, anchor, tag)
  } else {
    self.parse_flow_seq(start, anchor, tag)
  }
}

///|
fn Parser::parse_flow_seq(
  self : Parser,
  start : Int,
  anchor : String?,
  tag : String?,
) -> Node {
  let items : Array[Node] = []
  let mut node_end = start
  // Flow entries must be separated by commas and the collection must close
  // before EOF. Tracking this rejects block content swallowed by an unclosed
  // `[` (e.g. `on: [push` followed by indented block keys).
  let mut expect_comma = false
  while true {
    self.skip_trivia()
    match self.peek() {
      None => {
        if items.length() > 0 {
          self.errors.push(YamlError::{
            message: "unterminated flow sequence",
            offset: start,
          })
        }
        break
      }
      Some(t) =>
        if t.kind == FlowSeqEnd {
          node_end = t.offset + 1
          self.i = self.i + 1
          break
        } else if t.kind == Comma {
          self.i = self.i + 1
          expect_comma = false
          continue
        } else if expect_comma {
          self.errors.push(YamlError::{
            message: "flow sequence: expected ',' or ']'",
            offset: t.offset,
          })
          break
        } else {
          // A flow seq entry can be a "key: value" single-pair mapping.
          let n = self.parse_flow_node()
          self.skip_trivia()
          if self.peek() is Some(c) && c.kind == MapValueInd {
            self.i = self.i + 1
            self.skip_trivia()
            let v = self.parse_flow_node_or_empty()
            let r = Range::new(
              n.range().start,
              v.range().node_end,
              v.range().node_end,
            )
            items.push(Mapping([(n, v)], range=r, tag=None, anchor=None))
            node_end = v.range().node_end
          } else {
            node_end = n.range().node_end
            items.push(n)
          }
          expect_comma = true
        }
    }
  }
  Sequence(items, range=Range::new(start, node_end, node_end), tag~, anchor~)
}

///|
fn Parser::parse_flow_map(
  self : Parser,
  start : Int,
  anchor : String?,
  tag : String?,
) -> Node {
  let entries : Array[(Node, Node)] = []
  let merged : Array[Bool] = []
  let mut node_end = start
  let mut expect_comma = false
  while true {
    self.skip_trivia()
    match self.peek() {
      None => {
        if entries.length() > 0 {
          self.errors.push(YamlError::{
            message: "unterminated flow mapping",
            offset: start,
          })
        }
        break
      }
      Some(t) =>
        if t.kind == FlowMapEnd {
          node_end = t.offset + 1
          self.i = self.i + 1
          break
        } else if t.kind == Comma {
          self.i = self.i + 1
          expect_comma = false
          continue
        } else if expect_comma {
          self.errors.push(YamlError::{
            message: "flow mapping: expected ',' or '}'",
            offset: t.offset,
          })
          break
        } else if t.kind == ExplicitKeyInd {
          self.i = self.i + 1
          self.skip_trivia()
          let key = self.parse_flow_node_or_empty()
          self.skip_trivia()
          let value = if self.peek() is Some(c) && c.kind == MapValueInd {
            self.i = self.i + 1
            self.skip_trivia()
            self.parse_flow_node_or_empty()
          } else {
            self.empty_scalar(None, None, key.range().node_end)
          }
          node_end = value.range().node_end
          add_entry(entries, merged, key, value, self)
          expect_comma = true
        } else {
          let key = self.parse_flow_node()
          self.skip_trivia()
          let value = if self.peek() is Some(c) && c.kind == MapValueInd {
            self.i = self.i + 1
            self.skip_trivia()
            self.parse_flow_node_or_empty()
          } else {
            self.empty_scalar(None, None, key.range().node_end)
          }
          node_end = value.range().node_end
          add_entry(entries, merged, key, value, self)
          expect_comma = true
        }
    }
  }
  Mapping(entries, range=Range::new(start, node_end, node_end), tag~, anchor~)
}

///|
/// Parse a single node inside a flow context (scalar, nested flow, alias,
/// possibly with anchor/tag properties).
fn Parser::parse_flow_node(self : Parser) -> Node {
  self.depth = self.depth + 1
  if self.depth > MAX_DEPTH {
    self.depth = self.depth - 1
    self.errors.push(YamlError::{
      message: "recursion limit exceeded",
      offset: match self.peek() {
        Some(t) => t.offset
        None => self.src.length()
      },
    })
    return self.empty_scalar(None, None, -1)
  }
  let r = self.parse_flow_node_inner()
  self.depth = self.depth - 1
  r
}

///|
fn Parser::parse_flow_node_inner(self : Parser) -> Node {
  self.skip_trivia()
  let mut anchor : String? = None
  let mut tag : String? = None
  let mut prop_start = -1
  while self.peek() is Some(t) && (t.kind == Anchor || t.kind == Tag) {
    if prop_start < 0 {
      prop_start = t.offset
    }
    match t.kind {
      Anchor => anchor = Some(t.source[1:].to_owned())
      Tag => tag = Some(self.resolve_tag(t.source))
      _ => ()
    }
    self.i = self.i + 1
    self.skip_trivia()
  }
  match self.peek() {
    None => self.empty_scalar(anchor, tag, prop_start)
    Some(t) => {
      let start = if prop_start >= 0 { prop_start } else { t.offset }
      let node = match t.kind {
        FlowMapStart | FlowSeqStart => self.parse_flow(anchor, tag, start)
        SingleQuoted | DoubleQuoted =>
          self.parse_quoted_scalar(anchor, tag, start)
        Alias => {
          self.i = self.i + 1
          let name = t.source[1:].to_owned()
          Alias(
            name~,
            target=self.anchors.get(name),
            range=Range::new(
              t.offset,
              t.offset + t.source.length(),
              t.offset + t.source.length(),
            ),
          )
        }
        Scalar => self.parse_flow_plain(anchor, tag, start)
        _ => self.empty_scalar(anchor, tag, start)
      }
      match anchor {
        Some(name) => self.anchors[name] = node
        None => ()
      }
      node
    }
  }
}

///|
fn Parser::parse_flow_node_or_empty(self : Parser) -> Node {
  match self.peek() {
    Some(t) =>
      if t.kind == FlowSeqEnd ||
        t.kind == FlowMapEnd ||
        t.kind == Comma ||
        t.kind == MapValueInd {
        self.empty_scalar(None, None, t.offset)
      } else {
        self.parse_flow_node()
      }
    None => self.empty_scalar(None, None, self.src.length())
  }
}

///|
/// Plain scalar inside a flow collection. Flow plain scalars fold across
/// line breaks like block plain scalars: a single break becomes a space and
/// blank lines become newlines, until a flow indicator (`,`, `[`, `]`, `{`,
/// `}`), a `:` map indicator, or the end of the collection.
fn Parser::parse_flow_plain(
  self : Parser,
  anchor : String?,
  tag : String?,
  start : Int,
) -> Node {
  let first = self.peek().unwrap()
  let parts : Array[String] = [first.source]
  let mut value_end = first.offset + first.source.length()
  self.i = self.i + 1
  while true {
    let save = self.i
    // Skip inline spaces/comments; a comment terminates the scalar.
    let mut saw_comment = false
    while self.peek() is Some(t) && (t.kind == Space || t.kind == Comment) {
      if t.kind == Comment {
        saw_comment = true
      }
      self.i = self.i + 1
    }
    if saw_comment {
      self.i = save
      break
    }
    // Count line breaks for folding.
    let mut nls = 0
    while self.peek() is Some(t) && (t.kind == Newline || t.kind == Space) {
      if t.kind == Newline {
        nls = nls + 1
      }
      self.i = self.i + 1
    }
    match self.peek() {
      Some(nt) =>
        if nt.kind == Scalar {
          if nls == 0 {
            // Same line continuation (shouldn't normally happen as the lexer
            // emits one scalar per line, but handle defensively).
            parts.push(nt.source)
          } else if nls == 1 {
            parts.push(" ")
            parts.push(nt.source)
          } else {
            let mut z = 1
            while z < nls {
              parts.push("\n")
              z = z + 1
            }
            parts.push(nt.source)
          }
          value_end = nt.offset + nt.source.length()
          self.i = self.i + 1
        } else {
          self.i = save
          break
        }
      None => {
        self.i = save
        break
      }
    }
  }
  let raw = concat_parts(parts)
  let v = resolve_scalar_value(raw, Plain, tag)
  Scalar(
    v,
    style=Plain,
    range=Range::new(start, value_end, value_end),
    tag~,
    anchor~,
  )
}

///|
/// Parse a single- or double-quoted scalar.
fn Parser::parse_quoted_scalar(
  self : Parser,
  anchor : String?,
  tag : String?,
  start : Int,
) -> Node {
  let t = self.peek().unwrap()
  self.i = self.i + 1
  let end = t.offset + t.source.length()
  let (decoded, style) : (String, ScalarStyle) = if t.kind ==
    TokenKind::SingleQuoted {
    (decode_single_quoted(t.source), ScalarStyle::SingleQuoted)
  } else {
    (decode_double_quoted(t.source), ScalarStyle::DoubleQuoted)
  }
  // Quoted scalars are always strings unless an explicit tag overrides.
  let v = match tag {
    Some(tg) => apply_tag_to_string(decoded, tg)
    None => Str(decoded)
  }
  Scalar(v, style~, range=Range::new(start, end, end), tag~, anchor~)
}

///|
/// Parse a block scalar (`|` literal or `>` folded) with chomping and explicit
/// indentation indicators.
fn Parser::parse_block_scalar(
  self : Parser,
  anchor : String?,
  tag : String?,
  start : Int,
) -> Node {
  let header = self.peek().unwrap()
  self.i = self.i + 1
  let header_src = header.source
  let folded = header_src.unsafe_get(0).to_int() == '>'
  // Parse chomping and indent indicators from the header.
  let mut chomp = '\u{0000}' // ' ' clip(default), '-' strip, '+' keep
  let mut explicit_indent = 0
  let mut k = 1
  while k < header_src.length() {
    let c = header_src.unsafe_get(k).to_int()
    if c == '+' || c == '-' {
      chomp = c.unsafe_to_char()
    } else if c >= '1' && c <= '9' {
      explicit_indent = c - '0'
    } else {
      break
    }
    k = k + 1
  }
  // The explicit indentation indicator and body-indent baseline are measured
  // relative to the *parent* line's indentation (the column of the first
  // non-space character on the header's line), not the `|`/`>` column.
  let header_col = self.parent_indent(header.offset)
  // Skip the newline after the header (and inline trivia/comment already part
  // of header token).
  while self.peek() is Some(t) && (t.kind == Space || t.kind == Comment) {
    self.i = self.i + 1
  }
  if self.peek() is Some(t) && t.kind == Newline {
    self.i = self.i + 1
  }
  // Body token.
  let body = match self.peek() {
    Some(t) =>
      if t.kind == BlockScalarBody {
        self.i = self.i + 1
        t.source
      } else {
        ""
      }
    None => ""
  }
  let end = match self.toks.get(self.i - 1) {
    Some(t) => t.offset + t.source.length()
    None => start
  }
  let decoded = decode_block_scalar(
    body, folded, chomp, explicit_indent, header_col,
  )
  let style = if folded { Folded } else { Literal }
  let v = match tag {
    Some(tg) => apply_tag_to_string(decoded, tg)
    None => Str(decoded)
  }
  Scalar(v, style~, range=Range::new(start, end, end), tag~, anchor~)
}
