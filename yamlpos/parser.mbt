///| Parser + Composer: consumes the lexer token stream and produces composed
/// `Document`s. This fuses eemeli/yaml's CST-build and compose stages while
/// keeping first-class source ranges on every node, decoding scalar values per
/// the YAML 1.2 core schema, and resolving anchors/aliases and merge keys.
///
/// Block structure is recovered from token offsets/indentation (computed from
/// the source) rather than from a separate indentation token, which keeps the
/// implementation compact while remaining faithful to YAML semantics.

///|
priv struct Parser {
  src : String
  toks : Array[Token]
  mut i : Int
  anchors : Map[String, Node]
  errors : Array[YamlError]
  // %TAG handle -> prefix, plus the implicit ! and !! handles.
  tag_handles : Map[String, String]
  // Current nesting depth of the recursive node parser; guards against stack
  // overflow on adversarial deeply-nested / self-referential input.
  mut depth : Int
}

///|
/// Maximum nesting depth for the recursive parser. Mirrors a recursion-limit
/// guard so that untrusted input cannot overflow the stack (DoS safety).
const MAX_DEPTH : Int = 1000

///|
fn Parser::new(src : String, toks : Array[Token]) -> Parser {
  {
    src,
    toks,
    i: 0,
    anchors: {},
    errors: [],
    tag_handles: { "!": "!", "!!": "tag:yaml.org,2002:" },
    depth: 0,
  }
}

///|
fn Parser::peek(self : Parser) -> Token? {
  if self.i < self.toks.length() {
    Some(self.toks[self.i])
  } else {
    None
  }
}

///|
/// Column (0-based) of a token's start offset within its source line.
fn Parser::col_of(self : Parser, offset : Int) -> Int {
  let mut i = offset
  while i > 0 {
    let c = self.src.unsafe_get(i - 1).to_int()
    if c == '\n' || c == '\r' {
      break
    }
    i = i - 1
  }
  offset - i
}

///|
/// Indentation (0-based column of the first non-space char) of the line that
/// contains `offset`.
fn Parser::parent_indent(self : Parser, offset : Int) -> Int {
  let mut ls = offset
  while ls > 0 {
    let c = self.src.unsafe_get(ls - 1).to_int()
    if c == '\n' || c == '\r' {
      break
    }
    ls = ls - 1
  }
  let mut k = ls
  while k < self.src.length() &&
        (
          self.src.unsafe_get(k).to_int() == ' ' ||
          self.src.unsafe_get(k).to_int() == '\t'
        ) {
    k = k + 1
  }
  k - ls
}

///|
/// Skips spaces, comments and newlines (structurally insignificant trivia at
/// the current scanning position).
fn Parser::skip_trivia(self : Parser) -> Unit {
  while true {
    match self.peek() {
      Some(t) =>
        match t.kind {
          Space | Comment | Newline | ByteOrderMark => self.i = self.i + 1
          _ => break
        }
      None => break
    }
  }
}

///|
/// Skips only spaces and comments on the current line (not newlines).
fn Parser::skip_inline(self : Parser) -> Unit {
  while true {
    match self.peek() {
      Some(t) =>
        match t.kind {
          Space | Comment => self.i = self.i + 1
          _ => break
        }
      None => break
    }
  }
}

///|
/// Top-level: parse all documents in the stream.
pub fn parse_documents(source : String) -> Array[Document] {
  let toks = lex(source)
  let p = Parser::new(source, toks)
  p.parse_stream()
}

///|
/// Parse the first document only.
pub fn parse(source : String) -> Document {
  let docs = parse_documents(source)
  if docs.length() > 0 {
    docs[0]
  } else {
    { root: None, range: Range::new(0, 0, 0), errors: [] }
  }
}

///|
fn Parser::parse_stream(self : Parser) -> Array[Document] {
  let docs : Array[Document] = []
  while self.peek() is Some(_) {
    let loop_start = self.i
    // YAML scopes anchors and %TAG handles to a single document. Reset both
    // before each document's directives — including empty documents, which the
    // previous reset (inside the non-empty-root branch) skipped, leaking state
    // across `--- ---`.
    self.anchors.clear()
    self.tag_handles.clear()
    self.tag_handles["!"] = "!"
    self.tag_handles["!!"] = "tag:yaml.org,2002:"
    self.skip_trivia()
    // Directives.
    let mut had_directive = false
    while self.peek() is Some(t) && t.kind == Directive {
      self.handle_directive(t)
      self.i = self.i + 1
      had_directive = true
      self.skip_trivia()
    }
    match self.peek() {
      None =>
        if had_directive {
          docs.push({
            root: None,
            range: Range::new(
              self.src.length(),
              self.src.length(),
              self.src.length(),
            ),
            errors: [],
          })
        }
      Some(t) => {
        let doc_start = t.offset
        let mut has_marker = false
        if t.kind == DocStart {
          has_marker = true
          self.i = self.i + 1
          self.skip_inline()
        }
        // Empty document (immediately ---, ..., or EOF).
        self.skip_trivia()
        let root = match self.peek() {
          Some(nt) =>
            if nt.kind == DocEnd || nt.kind == DocStart {
              None
            } else {
              Some(self.parse_node(-1))
            }
          None => None
        }
        // Consume an explicit document end `...`.
        self.skip_trivia()
        let mut end = match root {
          Some(n) => n.range().node_end
          None => doc_start
        }
        if self.peek() is Some(et) && et.kind == DocEnd {
          end = et.offset + et.source.length()
          self.i = self.i + 1
        } else if root is Some(_) &&
          self.peek() is Some(lt) &&
          lt.kind != DocStart &&
          lt.kind != DocEnd {
          // Unexpected content trailing a complete root node within the same
          // document (e.g. `"foo" l"`): the source is malformed.
          self.errors.push(YamlError::{
            message: "unexpected content after document node",
            offset: lt.offset,
          })
        }
        let _ = has_marker
        docs.push({
          root,
          range: Range::new(doc_start, end, end),
          errors: self.errors.copy(),
        })
        self.errors.clear()
      }
    }
    // Safety: guarantee forward progress so a malformed stream can never spin
    // forever.
    if self.i <= loop_start {
      self.i = loop_start + 1
    }
  }
  docs
}

///|
fn Parser::handle_directive(self : Parser, t : Token) -> Unit {
  // %TAG !handle! prefix    OR    %YAML 1.2
  let body = t.source
  if body.has_prefix("%TAG") {
    let parts = split_ws(body[4:].to_owned())
    if parts.length() >= 2 {
      self.tag_handles[parts[0]] = parts[1]
    }
  }
  // %YAML directive is recorded but not otherwise acted upon.
}

///|
/// Parse a node whose content must be indented strictly more than
/// `min_indent` (use -1 at document top level). Handles node properties
/// (anchor and tag in either order), then dispatches on the leading token.
fn Parser::parse_node(self : Parser, min_indent : Int) -> Node {
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
  let r = self.parse_node_inner(min_indent)
  self.depth = self.depth - 1
  r
}

///|
fn Parser::parse_node_inner(self : Parser, min_indent : Int) -> Node {
  self.skip_inline()
  // Collect leading properties (anchor / tag), possibly spanning newlines in
  // block context only when they sit on the same line as the value start.
  let mut anchor : String? = None
  let mut tag : String? = None
  let mut prop_start = -1
  let mut prop_newline = false
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
    self.skip_inline()
    // A node's properties may be followed by a newline before a block value.
    if self.peek() is Some(nt) && nt.kind == Newline {
      prop_newline = true
      // Look ahead: a block value on the following lines must be indented
      // strictly deeper than `min_indent`. Otherwise the properties stand
      // alone (an anchored empty scalar) and the next line belongs to an
      // outer construct — e.g. `env: &e` followed by a sibling `- item`
      // must not swallow the sibling as the anchor's value.
      let save = self.i
      self.skip_trivia()
      match self.peek() {
        Some(t2) => {
          let c2 = self.col_of(t2.offset)
          // Zero-indented sequences are YAML's one exception: a block
          // sequence may sit at the parent key's own column.
          let too_shallow = if t2.kind == SeqItemInd {
            c2 < min_indent
          } else {
            c2 <= min_indent
          }
          if too_shallow {
            self.i = save
            break
          }
        }
        None => {
          self.i = save
          break
        }
      }
    }
  }
  let node = self.parse_node_content(
    min_indent, anchor, tag, prop_start, prop_newline,
  )
  // When same-line properties were attached to a block-mapping's first key
  // (`&a key: v`), the anchor already points at that key; do not overwrite it
  // with the whole mapping (which would create a spurious self-reference).
  let consumed_as_key_prop = prop_start >= 0 &&
    !prop_newline &&
    node is Mapping(_)
  match anchor {
    Some(name) => if !consumed_as_key_prop { self.anchors[name] = node }
    None => ()
  }
  node
}

///|
fn Parser::parse_node_content(
  self : Parser,
  min_indent : Int,
  anchor : String?,
  tag : String?,
  prop_start : Int,
  prop_newline : Bool,
) -> Node {
  match self.peek() {
    None => self.empty_scalar(anchor, tag, prop_start)
    Some(t) => {
      let start = if prop_start >= 0 { prop_start } else { t.offset }
      // When properties sit on the same line as a block-mapping key
      // (`&a key: v`), they belong to the first key, and the mapping aligns
      // its keys at the property column rather than the key column.
      let key_props = prop_start >= 0 && !prop_newline
      match t.kind {
        Alias =>
          // An alias may be a block-mapping key (`*a : v`).
          if self.alias_is_block_key() {
            let col = if key_props {
              self.col_of(prop_start)
            } else {
              self.col_of(t.offset)
            }
            self.parse_block_map(col, anchor, tag, start)
          } else {
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
        FlowMapStart | FlowSeqStart =>
          if self.flow_is_block_key() {
            if key_props {
              self.parse_block_map_keyed(
                self.col_of(prop_start),
                start,
                anchor,
                tag,
              )
            } else {
              self.parse_block_map(self.col_of(t.offset), anchor, tag, start)
            }
          } else {
            self.parse_flow(anchor, tag, start)
          }
        FlowSeqEnd | FlowMapEnd | Comma =>
          // unexpected; empty scalar
          self.empty_scalar(anchor, tag, start)
        BlockScalarHeader => self.parse_block_scalar(anchor, tag, start)
        SingleQuoted | DoubleQuoted =>
          if self.quoted_is_block_key() {
            if key_props {
              self.parse_block_map_keyed(
                self.col_of(prop_start),
                start,
                anchor,
                tag,
              )
            } else {
              self.parse_block_map(self.col_of(t.offset), anchor, tag, start)
            }
          } else {
            self.parse_quoted_scalar(anchor, tag, start)
          }
        SeqItemInd => {
          let col = self.col_of(t.offset)
          self.parse_block_seq(col, anchor, tag, start)
        }
        ExplicitKeyInd => {
          let col = self.col_of(t.offset)
          self.parse_block_map(col, anchor, tag, start)
        }
        Scalar =>
          // Could be a plain scalar or the key of a block mapping.
          self.parse_plain_or_block_map(
            min_indent, anchor, tag, start, key_props, prop_start,
          )
        _ => self.empty_scalar(anchor, tag, start)
      }
    }
  }
}

///|
/// Lookahead: is the current alias actually a block-mapping key (followed by
/// `:`)?
fn Parser::alias_is_block_key(self : Parser) -> Bool {
  let save = self.i
  self.i = self.i + 1
  self.skip_inline()
  let r = self.peek() is Some(t) && t.kind == MapValueInd
  self.i = save
  r
}

///|
/// Lookahead: is the current quoted scalar actually a block-mapping key
/// (followed by `:`)?
fn Parser::quoted_is_block_key(self : Parser) -> Bool {
  let save = self.i
  self.i = self.i + 1
  self.skip_inline()
  let r = self.peek() is Some(t) && t.kind == MapValueInd
  self.i = save
  r
}

///|
/// Lookahead: is the current flow collection actually a block-mapping key
/// (followed by `:` after the matching close bracket)?
fn Parser::flow_is_block_key(self : Parser) -> Bool {
  let save = self.i
  let mut depth = 0
  let mut ok = false
  while self.peek() is Some(t) {
    match t.kind {
      FlowMapStart | FlowSeqStart => depth = depth + 1
      FlowMapEnd | FlowSeqEnd => {
        depth = depth - 1
        if depth == 0 {
          self.i = self.i + 1
          self.skip_inline()
          ok = self.peek() is Some(n) && n.kind == MapValueInd
          break
        }
      }
      Newline => if depth == 0 { break }
      _ => ()
    }
    self.i = self.i + 1
  }
  self.i = save
  ok
}

///|
fn Parser::empty_scalar(
  self : Parser,
  anchor : String?,
  tag : String?,
  start : Int,
) -> Node {
  let off = if start >= 0 {
    start
  } else {
    match self.peek() {
      Some(t) => t.offset
      None => self.src.length()
    }
  }
  let v = resolve_scalar_value("", Plain, tag)
  Scalar(v, style=Plain, range=Range::new(off, off, off), tag~, anchor~)
}

///|
/// Resolve a tag token's source (e.g. `!!str`, `!foo`, `!<verbatim>`) to a
/// canonical tag string.
fn Parser::resolve_tag(self : Parser, src : String) -> String {
  if src == "!" {
    return "!"
  }
  if src.has_prefix("!<") && src.has_suffix(">") {
    return src[2:src.length() - 1].to_owned()
  }
  // Named handle: !h!suffix
  // Find a second '!'.
  let mut second = -1
  let mut k = 1
  while k < src.length() {
    if src.unsafe_get(k).to_int() == '!' {
      second = k
      break
    }
    k = k + 1
  }
  if second > 0 {
    let handle = src[0:second + 1].to_owned()
    let suffix = src[second + 1:].to_owned()
    match self.tag_handles.get(handle) {
      Some(prefix) => prefix + suffix
      None => src
    }
  } else {
    // Primary handle '!' with suffix: !foo
    let suffix = src[1:].to_owned()
    match self.tag_handles.get("!") {
      Some(prefix) => prefix + suffix
      None => src
    }
  }
}
