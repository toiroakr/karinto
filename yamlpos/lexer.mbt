///| Lexer: turns YAML source into a flat token stream where every token carries
/// its source `offset` (UTF-16 code-unit index) and exact `source` slice.
///
/// This is a port of the structure of eemeli/yaml's `src/parse/lexer.ts`. The
/// upstream lexer emits bare strings plus control characters; here tokens are
/// represented by an explicit `TokenKind` tag plus the source slice, which is a
/// more natural fit for MoonBit and keeps offsets first-class.

///|
pub(all) enum TokenKind {
  ByteOrderMark
  DocStart // ---
  DocEnd // ...
  Space // run of spaces / tabs
  Comment // # ...
  Newline // line break
  Directive // %YAML / %TAG / ...
  Anchor // &name
  Tag // !tag
  SeqItemInd // -
  ExplicitKeyInd // ?
  MapValueInd // :
  FlowMapStart // {
  FlowMapEnd // }
  FlowSeqStart // [
  FlowSeqEnd // ]
  Comma // ,
  BlockScalarHeader // | or > with chomping/indent indicators
  BlockScalarBody // the raw body lines of a block scalar
  Alias // *name
  SingleQuoted // '...'
  DoubleQuoted // "..."
  Scalar // plain scalar
} derive(Eq, Debug)

///|
pub(all) struct Token {
  kind : TokenKind
  offset : Int
  source : String
} derive(Debug)

///|
fn Token::new(kind : TokenKind, offset : Int, source : String) -> Token {
  { kind, offset, source }
}

///|
priv struct Lexer {
  src : String
  len : Int
  mut pos : Int
  tokens : Array[Token]
  // Nesting depth of flow collections. `---` / `...` at column 0 are only
  // recognised as document markers outside any flow context (depth 0).
  mut in_flow : Int
}

///|
fn Lexer::new(src : String) -> Lexer {
  { src, len: src.length(), pos: 0, tokens: [], in_flow: 0 }
}

///|
fn Lexer::cc(self : Lexer, i : Int) -> Int {
  if i < self.len {
    self.src.unsafe_get(i).to_int()
  } else {
    -1
  }
}

///|
fn is_space(c : Int) -> Bool {
  c == ' ' || c == '\t'
}

///|
fn is_break(c : Int) -> Bool {
  c == '\n' || c == '\r'
}

///|
fn Lexer::push(self : Lexer, kind : TokenKind, start : Int, end : Int) -> Unit {
  self.tokens.push(Token::new(kind, start, self.src[start:end].to_owned()))
}

///|
/// Top-level tokenizer driver.
fn Lexer::run(self : Lexer) -> Array[Token] {
  // Byte order mark.
  if self.len > 0 && self.cc(0) == 0xFEFF {
    self.push(ByteOrderMark, 0, 1)
    self.pos = 1
  }
  while self.pos < self.len {
    self.step()
  }
  self.tokens
}

///|
fn Lexer::at_line_start(self : Lexer) -> Bool {
  if self.pos == 0 {
    return true
  }
  let p = self.pos - 1
  is_break(self.cc(p))
}

///|
fn Lexer::step(self : Lexer) -> Unit {
  let start = self.pos
  let c = self.cc(start)
  // Whitespace run.
  if is_space(c) {
    let mut i = start
    while i < self.len && is_space(self.cc(i)) {
      i = i + 1
    }
    self.push(Space, start, i)
    self.pos = i
    return
  }
  // Line break.
  if c == '\r' {
    if self.cc(start + 1) == '\n' {
      self.push(Newline, start, start + 2)
      self.pos = start + 2
    } else {
      self.push(Newline, start, start + 1)
      self.pos = start + 1
    }
    return
  }
  if c == '\n' {
    self.push(Newline, start, start + 1)
    self.pos = start + 1
    return
  }
  // Comment.
  if c == '#' {
    let mut i = start
    while i < self.len && !is_break(self.cc(i)) {
      i = i + 1
    }
    self.push(Comment, start, i)
    self.pos = i
    return
  }
  let line_start = self.at_line_start()
  // Directive line.
  if c == '%' && line_start && self.in_flow == 0 {
    let mut i = start
    while i < self.len && !is_break(self.cc(i)) {
      i = i + 1
    }
    self.push(Directive, start, i)
    self.pos = i
    return
  }
  // Document markers --- and ...
  if line_start && self.in_flow == 0 && (c == '-' || c == '.') {
    if self.cc(start + 1) == c && self.cc(start + 2) == c {
      let after = self.cc(start + 3)
      if after == -1 || is_space(after) || is_break(after) {
        if c == '-' {
          self.push(DocStart, start, start + 3)
        } else {
          self.push(DocEnd, start, start + 3)
        }
        self.pos = start + 3
        return
      }
    }
  }
  // Flow indicators.
  match c {
    '{' => {
      self.in_flow = self.in_flow + 1
      self.push(FlowMapStart, start, start + 1)
      self.pos = start + 1
      return
    }
    '}' => {
      if self.in_flow > 0 {
        self.in_flow = self.in_flow - 1
      }
      self.push(FlowMapEnd, start, start + 1)
      self.pos = start + 1
      return
    }
    '[' => {
      self.in_flow = self.in_flow + 1
      self.push(FlowSeqStart, start, start + 1)
      self.pos = start + 1
      return
    }
    ']' => {
      if self.in_flow > 0 {
        self.in_flow = self.in_flow - 1
      }
      self.push(FlowSeqEnd, start, start + 1)
      self.pos = start + 1
      return
    }
    ',' => {
      self.push(Comma, start, start + 1)
      self.pos = start + 1
      return
    }
    _ => ()
  }
  // Sequence item indicator: '-' followed by space/break/eof.
  if c == '-' {
    let after = self.cc(start + 1)
    if (after == -1 || is_space(after) || is_break(after)) && self.in_flow == 0 {
      self.push(SeqItemInd, start, start + 1)
      self.pos = start + 1
      return
    }
  }
  // Explicit key indicator '?' followed by space/break/eof (block only).
  if c == '?' && self.in_flow == 0 {
    let after = self.cc(start + 1)
    if after == -1 || is_space(after) || is_break(after) {
      self.push(ExplicitKeyInd, start, start + 1)
      self.pos = start + 1
      return
    }
  }
  // Map value indicator ':' followed by space/break/eof, or before flow end
  // when inside a flow collection.
  if c == ':' {
    let after = self.cc(start + 1)
    let ok = if self.in_flow > 0 {
      after == -1 ||
      is_space(after) ||
      is_break(after) ||
      after == ',' ||
      after == '}' ||
      after == ']' ||
      after == '{' ||
      after == '['
    } else {
      after == -1 || is_space(after) || is_break(after)
    }
    if ok {
      self.push(MapValueInd, start, start + 1)
      self.pos = start + 1
      return
    }
  }
  // Anchor.
  if c == '&' {
    let mut i = start + 1
    while i < self.len && is_anchor_char(self.cc(i)) {
      i = i + 1
    }
    self.push(Anchor, start, i)
    self.pos = i
    return
  }
  // Alias.
  if c == '*' {
    let mut i = start + 1
    while i < self.len && is_anchor_char(self.cc(i)) {
      i = i + 1
    }
    self.push(Alias, start, i)
    self.pos = i
    return
  }
  // Tag.
  if c == '!' {
    let i = self.scan_tag(start)
    self.push(Tag, start, i)
    self.pos = i
    return
  }
  // Block scalar header.
  if (c == '|' || c == '>') && self.in_flow == 0 {
    self.scan_block_scalar(start)
    return
  }
  // Quoted scalars.
  if c == '\'' {
    let i = self.scan_single_quoted(start)
    self.push(SingleQuoted, start, i)
    self.pos = i
    return
  }
  if c == '"' {
    let i = self.scan_double_quoted(start)
    self.push(DoubleQuoted, start, i)
    self.pos = i
    return
  }
  // Plain scalar.
  let i = self.scan_plain(start)
  if i > start {
    self.push(Scalar, start, i)
    self.pos = i
  } else {
    // Unknown single char; emit as a scalar to make progress.
    self.push(Scalar, start, start + 1)
    self.pos = start + 1
  }
}

///|
fn is_anchor_char(c : Int) -> Bool {
  !(is_space(c) ||
  is_break(c) ||
  c == ',' ||
  c == '[' ||
  c == ']' ||
  c == '{' ||
  c == '}' ||
  c == -1)
}

///|
/// Scans a tag token starting at a `!`. Handles `!`, `!!str`, `!foo`,
/// `!<verbatim>`, and `!h!suffix` named handles.
fn Lexer::scan_tag(self : Lexer, start : Int) -> Int {
  let mut i = start + 1
  if self.cc(i) == '<' {
    // Verbatim tag !<...>
    while i < self.len && self.cc(i) != '>' && !is_break(self.cc(i)) {
      i = i + 1
    }
    if self.cc(i) == '>' {
      i = i + 1
    }
    return i
  }
  // Optional handle: chars up to a second '!', then the suffix.
  while i < self.len && is_tag_char(self.cc(i)) {
    i = i + 1
  }
  if self.cc(i) == '!' {
    i = i + 1
    while i < self.len && is_tag_char(self.cc(i)) {
      i = i + 1
    }
  }
  i
}

///|
fn is_tag_char(c : Int) -> Bool {
  if c == -1 || is_space(c) || is_break(c) || c == '!' {
    return false
  }
  !(c == ',' || c == '[' || c == ']' || c == '{' || c == '}')
}

///|
/// Scans a single-quoted scalar including its closing quote. `''` is an escaped
/// quote and does not terminate the string.
fn Lexer::scan_single_quoted(self : Lexer, start : Int) -> Int {
  let mut i = start + 1
  while i < self.len {
    let c = self.cc(i)
    if c == '\'' {
      if self.cc(i + 1) == '\'' {
        i = i + 2
        continue
      }
      return i + 1
    }
    i = i + 1
  }
  i
}

///|
/// Scans a double-quoted scalar including its closing quote. `\"` is escaped.
fn Lexer::scan_double_quoted(self : Lexer, start : Int) -> Int {
  let mut i = start + 1
  while i < self.len {
    let c = self.cc(i)
    if c == '\\' {
      i = i + 2
      continue
    }
    if c == '"' {
      return i + 1
    }
    i = i + 1
  }
  i
}

///|
/// Scans a plain scalar. Plain scalars terminate at indicators that begin a new
/// structure, at `: ` (in block context) or before flow indicators (in flow
/// context), and at line breaks. Multi-line plain scalars are handled by the
/// parser folding successive Scalar tokens; here a Scalar token is a single
/// line's worth of plain content.
fn Lexer::scan_plain(self : Lexer, start : Int) -> Int {
  let mut i = start
  while i < self.len {
    let c = self.cc(i)
    if is_break(c) {
      break
    }
    if c == '#' && i > start && is_space(self.cc(i - 1)) {
      break
    }
    if self.in_flow > 0 {
      if c == ',' || c == '[' || c == ']' || c == '{' || c == '}' {
        break
      }
    }
    // ': ' ends the scalar (it is a map value indicator).
    if c == ':' {
      let after = self.cc(i + 1)
      let ends = if self.in_flow > 0 {
        after == -1 ||
        is_space(after) ||
        is_break(after) ||
        after == ',' ||
        after == '}' ||
        after == ']'
      } else {
        after == -1 || is_space(after) || is_break(after)
      }
      if ends {
        break
      }
    }
    i = i + 1
  }
  // Trim trailing spaces/tabs from the plain scalar token.
  while i > start && is_space(self.cc(i - 1)) {
    i = i - 1
  }
  i
}

///|
/// Scans a block scalar header (`|`/`>` with optional chomping `+`/`-` and an
/// explicit indentation indicator digit) plus the entire indented body, which
/// is emitted as a separate `BlockScalarBody` token.
fn Lexer::scan_block_scalar(self : Lexer, start : Int) -> Unit {
  let mut i = start + 1
  // Header indicators: chomping and indentation, in either order.
  let mut explicit_indent = 0
  while i < self.len &&
        (
          self.cc(i) == '+' ||
          self.cc(i) == '-' ||
          (self.cc(i) >= '1' && self.cc(i) <= '9')
        ) {
    if self.cc(i) >= '1' && self.cc(i) <= '9' {
      explicit_indent = self.cc(i) - '0'
    }
    i = i + 1
  }
  // Trailing spaces and an optional comment on the header line.
  while i < self.len && (is_space(self.cc(i)) || self.cc(i) == '#') {
    if self.cc(i) == '#' {
      while i < self.len && !is_break(self.cc(i)) {
        i = i + 1
      }
      break
    }
    i = i + 1
  }
  self.push(BlockScalarHeader, start, i)
  // The block body must be indented strictly more than the *parent* line's
  // indentation, i.e. the column of the first non-space character on the line
  // that carries the header (not the column of the `|`/`>` itself, which may
  // sit after a `key:` prefix).
  let line_start = self.line_start_offset(start)
  let mut parent_indent = 0
  while line_start + parent_indent < self.len &&
        is_space(self.cc(line_start + parent_indent)) {
    parent_indent = parent_indent + 1
  }
  let header_col = parent_indent

  // Consume the rest of the header line's break so the body starts on the
  // first following line.
  let j = self.skip_break(i)
  // The body consists of following lines that are either blank or indented
  // more than the parent. We greedily consume lines until a non-empty line
  // is indented at or below the header column.
  let body_start = j
  // The block's content indentation: either the explicit indicator (relative
  // to the parent indent) or, lazily, the indentation of the first non-blank
  // body line. A non-blank line indented below the content indent ends the
  // body; blank lines are always part of the body.
  let mut content_indent = if explicit_indent > 0 {
    header_col + explicit_indent
  } else {
    -1
  }
  let mut last_content_end = body_start
  // We must include the newline that ends the header line as part of body.
  for j = j {
    if j >= self.len {
      last_content_end = j
      break
    }
    // measure indentation of this line
    let ls = j
    let mut k = j
    while k < self.len && is_space(self.cc(k)) {
      k = k + 1
    }
    let indent = k - ls
    let cc = self.cc(k)
    if is_break(cc) || k >= self.len {
      // blank line: part of body; advance past the break and continue
      let nb = self.skip_break(k)
      last_content_end = nb
      continue nb
    }
    // Establish the content indent from the first non-blank line.
    if content_indent < 0 {
      if indent > header_col {
        content_indent = indent
      } else {
        // first non-blank line is not indented past the parent: empty body
        last_content_end = ls
        break
      }
    }
    if indent >= content_indent {
      // content line belongs to the block
      let mut m = k
      while m < self.len && !is_break(self.cc(m)) {
        m = m + 1
      }
      let nb = self.skip_break(m)
      last_content_end = nb
      continue nb
    } else {
      // line is dedented below the content indent; body ends before it
      last_content_end = ls
      break
    }
  }
  if last_content_end > body_start {
    self.push(BlockScalarBody, body_start, last_content_end)
  }
  self.pos = last_content_end
}

///|
fn Lexer::skip_break(self : Lexer, i : Int) -> Int {
  if i >= self.len {
    return i
  }
  let c = self.cc(i)
  if c == '\r' && self.cc(i + 1) == '\n' {
    return i + 2
  }
  if is_break(c) {
    return i + 1
  }
  i
}

///|
/// Offset of the start of the line containing `offset`.
fn Lexer::line_start_offset(self : Lexer, offset : Int) -> Int {
  let mut i = offset
  while i > 0 && !is_break(self.cc(i - 1)) {
    i = i - 1
  }
  i
}

///|
/// Public entry point used by tests and the parser.
pub fn lex(source : String) -> Array[Token] {
  Lexer::new(source).run()
}
