///| Block-structure parsing: block sequences, block mappings, and plain
/// scalars (which may turn out to be a block-map key).

///|
/// Decide whether a plain Scalar token begins a block mapping (key followed by
/// `:`) or is just a plain scalar value (possibly multi-line).
fn Parser::parse_plain_or_block_map(
  self : Parser,
  min_indent : Int,
  anchor : String?,
  tag : String?,
  start : Int,
  key_props : Bool,
  prop_start : Int,
) -> Node {
  let key_tok = self.peek().unwrap()
  let col = self.col_of(key_tok.offset)
  // Look ahead past the scalar (and inline trivia) for a map value indicator.
  let save = self.i
  self.i = self.i + 1
  self.skip_inline()
  let is_map = self.peek() is Some(t) && t.kind == MapValueInd
  self.i = save
  if is_map {
    if key_props {
      self.parse_block_map_keyed(self.col_of(prop_start), start, anchor, tag)
    } else {
      self.parse_block_map(col, anchor, tag, start)
    }
  } else {
    self.parse_plain_scalar(min_indent, anchor, tag, start)
  }
}

///|
/// Parse a (possibly multi-line) plain scalar in block context.
fn Parser::parse_plain_scalar(
  self : Parser,
  min_indent : Int,
  anchor : String?,
  tag : String?,
  start : Int,
) -> Node {
  let first = self.peek().unwrap()
  // Continuation lines fold when indented strictly more than the parent block
  // indent (`min_indent`); top-level scalars (min_indent = -1) accept any
  // indentation > -1.
  let base_col = min_indent
  let parts : Array[String] = []
  let mut value_end = first.offset + first.source.length()
  parts.push(first.source)
  self.i = self.i + 1
  // Continuation lines: plain scalars fold across lines that are indented more
  // than the scalar's starting column and are not new block constructs.
  let mut break_count = 0
  while true {
    let save = self.i
    // Consume inline trivia (spaces/comments) – a comment ends the scalar.
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
    if self.peek() is Some(t) && t.kind == Newline {
      // Count blank lines for folding.
      let mut nls = 0
      while self.peek() is Some(nt) && (nt.kind == Newline || nt.kind == Space) {
        if nt.kind == Newline {
          nls = nls + 1
        }
        self.i = self.i + 1
      }
      match self.peek() {
        Some(nt) =>
          if nt.kind == Scalar && self.col_of(nt.offset) > base_col {
            // Verify it's not a "key:" mapping start by lookahead.
            let s2 = self.i
            self.i = self.i + 1
            self.skip_inline()
            let is_kv = self.peek() is Some(x) && x.kind == MapValueInd
            self.i = s2
            if is_kv {
              self.i = save
              break
            }
            // fold
            if nls <= 1 {
              parts.push(" ")
            } else {
              let mut z = 1
              while z < nls {
                parts.push("\n")
                z = z + 1
              }
            }
            parts.push(nt.source)
            value_end = nt.offset + nt.source.length()
            self.i = self.i + 1
            break_count = nls
            let _ = break_count
            continue
          } else {
            self.i = save
            break
          }
        None => {
          self.i = save
          break
        }
      }
    } else {
      self.i = save
      break
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
/// Parse a block sequence whose `-` indicators sit at column `col`.
fn Parser::parse_block_seq(
  self : Parser,
  col : Int,
  anchor : String?,
  tag : String?,
  start : Int,
) -> Node {
  let items : Array[Node] = []
  let mut node_end = start
  while true {
    self.skip_trivia()
    match self.peek() {
      Some(t) =>
        if t.kind == SeqItemInd && self.col_of(t.offset) == col {
          let dash = t
          self.i = self.i + 1
          self.skip_inline()
          // The item value may be empty, inline, or on following lines.
          match self.peek() {
            Some(nt) =>
              if nt.kind == Newline {
                // Value (if any) is a nested block indented more than `col`.
                self.skip_trivia()
                match self.peek() {
                  Some(v) =>
                    if self.col_of(v.offset) > col &&
                      v.kind != DocStart &&
                      v.kind != DocEnd {
                      let n = self.parse_node(col)
                      node_end = n.range().node_end
                      items.push(n)
                    } else {
                      // empty item
                      let off = dash.offset + 1
                      items.push(self.empty_scalar(None, None, off))
                      node_end = off
                    }
                  None => {
                    let off = dash.offset + 1
                    items.push(self.empty_scalar(None, None, off))
                    node_end = off
                  }
                }
              } else {
                // Inline value on the same line. It could itself be a nested
                // block-map "key:" or a "- - x" nested sequence.
                let item_col = self.col_of(nt.offset)
                let n = self.parse_node(item_col - 1)
                node_end = n.range().node_end
                items.push(n)
              }
            None => {
              let off = dash.offset + 1
              items.push(self.empty_scalar(None, None, off))
              node_end = off
            }
          }
        } else {
          break
        }
      None => break
    }
  }
  Sequence(items, range=Range::new(start, node_end, node_end), tag~, anchor~)
}

///|
/// Parse a block mapping whose first key carries node properties (anchor/tag)
/// that appeared on the same line, e.g. `&a key: value`. The map's keys align
/// at the property column `col`, the first key node carries the properties,
/// and the mapping itself is unanchored/untagged.
fn Parser::parse_block_map_keyed(
  self : Parser,
  col : Int,
  start : Int,
  first_anchor : String?,
  first_tag : String?,
) -> Node {
  let entries : Array[(Node, Node)] = []
  let mut node_end = start
  // First key (with its properties already consumed by the caller).
  let key = self.parse_map_key_props(col, first_anchor, first_tag)
  match first_anchor {
    Some(name) => self.anchors[name] = key
    None => ()
  }
  self.skip_inline()
  if self.peek() is Some(ct) && ct.kind == MapValueInd {
    self.i = self.i + 1
    self.skip_inline()
    let value = self.parse_value_after_colon(col, ct)
    node_end = value.range().node_end
    add_entry(entries, key, value, self)
  } else {
    let value = self.empty_scalar(None, None, key.range().node_end)
    node_end = value.range().node_end
    add_entry(entries, key, value, self)
  }
  self.parse_block_map_loop(col, start, node_end, entries, None, None)
}

///|
/// Parse a block mapping whose keys sit at column `col`.
fn Parser::parse_block_map(
  self : Parser,
  col : Int,
  anchor : String?,
  tag : String?,
  start : Int,
) -> Node {
  self.parse_block_map_loop(col, start, start, [], anchor, tag)
}

///|
/// Shared block-mapping entry loop, seeded with any already-parsed entries.
fn Parser::parse_block_map_loop(
  self : Parser,
  col : Int,
  start : Int,
  node_end0 : Int,
  entries : Array[(Node, Node)],
  anchor : String?,
  tag : String?,
) -> Node {
  let mut node_end = node_end0
  while true {
    self.skip_trivia()
    match self.peek() {
      None => break
      Some(t) => {
        if t.kind == DocStart || t.kind == DocEnd {
          break
        }
        let kcol = self.col_of(t.offset)
        if kcol != col {
          break
        }
        // Explicit key: '? key' then ': value'.
        if t.kind == ExplicitKeyInd {
          self.i = self.i + 1
          self.skip_inline()
          let key = match self.peek() {
            Some(kt) =>
              if kt.kind == Newline {
                self.skip_trivia()
                self.parse_node(col)
              } else {
                self.parse_node(col)
              }
            None => self.empty_scalar(None, None, t.offset + 1)
          }
          self.skip_trivia()
          let value = if self.peek() is Some(vt) &&
            vt.kind == MapValueInd &&
            self.col_of(vt.offset) == col {
            self.i = self.i + 1
            self.skip_inline()
            self.parse_value_after_colon(col, vt)
          } else {
            self.empty_scalar(None, None, key.range().node_end)
          }
          node_end = value.range().node_end
          entries.push((key, value))
          continue
        }
        // Implicit key: parse a key node up to the ':' indicator.
        let key = self.parse_map_key()
        self.skip_inline()
        match self.peek() {
          Some(ct) =>
            if ct.kind == MapValueInd {
              self.i = self.i + 1
              self.skip_inline()
              let value = self.parse_value_after_colon(col, ct)
              node_end = value.range().node_end
              add_entry(entries, key, value, self)
            } else {
              // key with no value indicator (shouldn't normally happen)
              node_end = key.range().node_end
              add_entry(
                entries,
                key,
                self.empty_scalar(None, None, key.range().node_end),
                self,
              )
              break
            }
          None => {
            add_entry(
              entries,
              key,
              self.empty_scalar(None, None, key.range().node_end),
              self,
            )
            node_end = key.range().node_end
            break
          }
        }
      }
    }
  }
  Mapping(entries, range=Range::new(start, node_end, node_end), tag~, anchor~)
}

///|
/// Parse the value after a `:` map-value indicator at key column `col`.
fn Parser::parse_value_after_colon(
  self : Parser,
  col : Int,
  colon : Token,
) -> Node {
  match self.peek() {
    None => self.empty_scalar(None, None, colon.offset + 1)
    Some(vt) =>
      if vt.kind == Newline {
        self.skip_trivia()
        match self.peek() {
          None => self.empty_scalar(None, None, colon.offset + 1)
          Some(nv) => {
            let vcol = self.col_of(nv.offset)
            if nv.kind == DocStart || nv.kind == DocEnd {
              self.empty_scalar(None, None, colon.offset + 1)
            } else if nv.kind == SeqItemInd && vcol >= col {
              // Block sequence may be at the same column as the key in YAML.
              self.parse_node(col - 1)
            } else if vcol > col {
              self.parse_node(col)
            } else {
              self.empty_scalar(None, None, colon.offset + 1)
            }
          }
        }
      } else {
        // Inline value on same line as colon. Multiline plain scalars fold
        // against the *key* column, so pass `col` as the fold baseline.
        let _ = vt
        self.parse_node(col)
      }
  }
}

///|
/// Parse a mapping key: a plain/quoted/flow scalar or flow collection up to
/// the `:` indicator. Multi-line plain keys are not folded here.
fn Parser::parse_map_key(self : Parser) -> Node {
  let t = self.peek().unwrap()
  let start = t.offset
  match t.kind {
    Anchor | Tag => {
      // Collect the key's leading properties, then parse only the key scalar
      // (not a full node, which would over-consume the following `: value`).
      let mut anchor : String? = None
      let mut tag : String? = None
      while self.peek() is Some(p) && (p.kind == Anchor || p.kind == Tag) {
        match p.kind {
          Anchor => anchor = Some(p.source[1:].to_owned())
          Tag => tag = Some(self.resolve_tag(p.source))
          _ => ()
        }
        self.i = self.i + 1
        self.skip_inline()
      }
      let key = self.parse_map_key_props(start, anchor, tag)
      match anchor {
        Some(name) => self.anchors[name] = key
        None => ()
      }
      key
    }
    SingleQuoted | DoubleQuoted => self.parse_quoted_scalar(None, None, start)
    FlowMapStart | FlowSeqStart => self.parse_flow(None, None, start)
    Alias => {
      self.i = self.i + 1
      let name = t.source[1:].to_owned()
      Alias(
        name~,
        resolved=self.anchors.contains(name),
        range=Range::new(
          t.offset,
          t.offset + t.source.length(),
          t.offset + t.source.length(),
        ),
      )
    }
    Scalar => {
      let v = resolve_scalar_value(t.source, Plain, None)
      self.i = self.i + 1
      Scalar(
        v,
        style=Plain,
        range=Range::new(
          start,
          t.offset + t.source.length(),
          t.offset + t.source.length(),
        ),
        tag=None,
        anchor=None,
      )
    }
    _ =>
      // Fallback: empty key.
      self.empty_scalar(None, None, start)
  }
}

///|
/// Parse a mapping key (Scalar/quoted/flow) at the current position,
/// attaching the supplied anchor/tag (consumed earlier) and applying the tag
/// to scalar typing. `start` is the property start offset.
fn Parser::parse_map_key_props(
  self : Parser,
  start : Int,
  anchor : String?,
  tag : String?,
) -> Node {
  let t = self.peek().unwrap()
  match t.kind {
    SingleQuoted | DoubleQuoted => self.parse_quoted_scalar(anchor, tag, start)
    FlowMapStart | FlowSeqStart => self.parse_flow(anchor, tag, start)
    Scalar => {
      let v = resolve_scalar_value(t.source, Plain, tag)
      self.i = self.i + 1
      Scalar(
        v,
        style=Plain,
        range=Range::new(
          start,
          t.offset + t.source.length(),
          t.offset + t.source.length(),
        ),
        tag~,
        anchor~,
      )
    }
    _ => self.empty_scalar(anchor, tag, start)
  }
}

///|
/// Add a mapping entry, applying `<<` merge-key semantics.
fn add_entry(
  entries : Array[(Node, Node)],
  key : Node,
  value : Node,
  p : Parser,
) -> Unit {
  if is_merge_key(key) {
    p.apply_merge(entries, value)
  } else {
    if key_exists(entries, key) {
      p.errors.push(YamlError::{
        message: "duplicate mapping key",
        offset: key.range().start,
      })
    }
    entries.push((key, value))
  }
}

///|
fn is_merge_key(key : Node) -> Bool {
  match key {
    Scalar(Str(s), ..) => s == "<<"
    _ => false
  }
}

///|
/// Apply `<<` merge: the value is a mapping (or sequence of mappings/aliases)
/// whose entries are merged in, without overriding existing keys.
fn Parser::apply_merge(
  self : Parser,
  entries : Array[(Node, Node)],
  value : Node,
) -> Unit {
  let merge_one = fn(n : Node) {
    let resolved = self.deref(n)
    match resolved {
      Mapping(es, ..) =>
        for e in es {
          let (k, v) = e
          if !key_exists(entries, k) {
            entries.push((k, v))
          }
        }
      _ => ()
    }
  }
  match self.deref(value) {
    Sequence(items, ..) =>
      for it in items {
        merge_one(it)
      }
    _ => merge_one(value)
  }
}

///|
fn key_exists(entries : Array[(Node, Node)], k : Node) -> Bool {
  for e in entries {
    let (ek, _) = e
    if node_key_eq(ek, k) {
      return true
    }
  }
  false
}

///|
fn node_key_eq(a : Node, b : Node) -> Bool {
  match (a, b) {
    (Scalar(va, ..), Scalar(vb, ..)) => va == vb
    _ => false
  }
}

///|
/// Resolve an alias to its target node; non-aliases pass through.
fn Parser::deref(self : Parser, n : Node) -> Node {
  match n {
    Alias(name~, ..) =>
      match self.anchors.get(name) {
        Some(target) => target
        None => n
      }
    _ => n
  }
}
