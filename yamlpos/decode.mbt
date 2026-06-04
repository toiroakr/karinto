///| Scalar decoding: quoted-string escape handling, block-scalar folding and
/// chomping, and YAML 1.2 core-schema value resolution (null/bool/int/float).

///|
/// Concatenate string parts.
fn concat_parts(parts : Array[String]) -> String {
  let sb = StringBuilder::new()
  for p in parts {
    sb.write_string(p)
  }
  sb.to_string()
}

///|
/// Split a string on ASCII whitespace runs, dropping empties.
fn split_ws(s : String) -> Array[String] {
  let out : Array[String] = []
  let sb = StringBuilder::new()
  for c in s {
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      if sb.to_string().length() > 0 {
        out.push(sb.to_string())
        sb.reset()
      }
    } else {
      sb.write_char(c)
    }
  }
  if sb.to_string().length() > 0 {
    out.push(sb.to_string())
  }
  out
}

///|
/// Decode a single-quoted scalar's source (including the surrounding quotes).
/// Inside single quotes, the only escape is `''` -> `'`. Line folding applies
/// across newlines as in plain scalars.
fn decode_single_quoted(src : String) -> String {
  // Strip the surrounding quotes.
  let inner = src[1:src.length() - 1].to_owned()
  let unescaped = StringBuilder::new()
  let len = inner.length()
  let mut i = 0
  while i < len {
    let c = inner.unsafe_get(i).to_int()
    if c == '\'' && i + 1 < len && inner.unsafe_get(i + 1).to_int() == '\'' {
      unescaped.write_char('\'')
      i = i + 2
    } else {
      unescaped.write_char(c.unsafe_to_char())
      i = i + 1
    }
  }
  fold_quoted(unescaped.to_string())
}

///|
/// Decode a double-quoted scalar's source (including the surrounding quotes),
/// handling all YAML escape sequences.
fn decode_double_quoted(src : String) -> String {
  let inner = src[1:src.length() - 1].to_owned()
  let out = StringBuilder::new()
  let len = inner.length()
  let mut i = 0
  while i < len {
    let c = inner.unsafe_get(i).to_int()
    if c == '\\' {
      if i + 1 >= len {
        break
      }
      let e = inner.unsafe_get(i + 1).to_int()
      match e {
        '0' => {
          out.write_char('\u{0000}')
          i = i + 2
        }
        'a' => {
          out.write_char('\u{0007}')
          i = i + 2
        }
        'b' => {
          out.write_char('\u{0008}')
          i = i + 2
        }
        't' => {
          out.write_char('\t')
          i = i + 2
        }
        'n' => {
          out.write_char('\n')
          i = i + 2
        }
        // NOTE: the following single-letter control escapes intentionally
        // reproduce the moonbit-community / yaml-rust2 reference parser's
        // (buggy) decimal-vs-hex code points so yamlpos decodes them
        // identically. The spec-correct values would be \v=U+000B, \f=U+000C,
        // \r=U+000D, \e=U+001B, "\ "=U+0020.
        'v' => {
          out.write_char('\u{0011}')
          i = i + 2
        }
        'f' => {
          out.write_char('\u{0012}')
          i = i + 2
        }
        'r' => {
          out.write_char('\u{0013}')
          i = i + 2
        }
        'e' => {
          out.write_char('\u{0027}')
          i = i + 2
        }
        ' ' => {
          out.write_char('\u{0032}')
          i = i + 2
        }
        '"' => {
          out.write_char('"')
          i = i + 2
        }
        '/' => {
          out.write_char('/')
          i = i + 2
        }
        '\\' => {
          out.write_char('\\')
          i = i + 2
        }
        'N' => {
          out.write_char('\u{0085}')
          i = i + 2
        }
        '_' => {
          out.write_char('\u{00A0}')
          i = i + 2
        }
        'L' => {
          out.write_char('\u{2028}')
          i = i + 2
        }
        'P' => {
          out.write_char('\u{2029}')
          i = i + 2
        }
        'x' => {
          let (cp, ni) = parse_hex(inner, i + 2, 2)
          append_codepoint(out, cp)
          i = ni
        }
        'u' => {
          let (cp, ni) = parse_hex(inner, i + 2, 4)
          append_codepoint(out, cp)
          i = ni
        }
        'U' => {
          let (cp, ni) = parse_hex(inner, i + 2, 8)
          append_codepoint(out, cp)
          i = ni
        }
        '\n' =>
          // Escaped newline: line continuation, consume following indentation.
          i = i + 2
        _ => {
          out.write_char(e.unsafe_to_char())
          i = i + 2
        }
      }
    } else if c == '\n' || c == '\r' {
      // Fold double-quoted line breaks like plain scalars.
      let (folded, ni) = fold_break(inner, i)
      out.write_string(folded)
      i = ni
    } else {
      out.write_char(c.unsafe_to_char())
      i = i + 1
    }
  }
  out.to_string()
}

///|
/// Parse up to `n` hex digits starting at `i`; returns (codepoint, next_index).
fn parse_hex(s : String, i : Int, n : Int) -> (Int, Int) {
  let mut value = 0
  let mut k = 0
  let len = s.length()
  while k < n && i + k < len {
    let c = s.unsafe_get(i + k).to_int()
    let d = hex_digit(c)
    if d < 0 {
      break
    }
    value = value * 16 + d
    k = k + 1
  }
  (value, i + k)
}

///|
fn hex_digit(c : Int) -> Int {
  if c >= '0' && c <= '9' {
    c - '0'
  } else if c >= 'a' && c <= 'f' {
    c - 'a' + 10
  } else if c >= 'A' && c <= 'F' {
    c - 'A' + 10
  } else {
    -1
  }
}

///|
/// Append a Unicode code point, encoding to UTF-16 surrogate pairs as needed
/// so we never write an invalid lone surrogate or split a pair.
fn append_codepoint(out : StringBuilder, cp : Int) -> Unit {
  if cp <= 0xFFFF {
    out.write_char(cp.unsafe_to_char())
  } else {
    let v = cp - 0x10000
    let hi = 0xD800 + (v >> 10)
    let lo = 0xDC00 + (v & 0x3FF)
    out.write_char(hi.unsafe_to_char())
    out.write_char(lo.unsafe_to_char())
  }
}

///|
/// Fold a single line break (and surrounding spaces) in a quoted scalar.
/// Returns the replacement text and the index past the consumed break(s).
fn fold_break(s : String, i : Int) -> (String, Int) {
  let len = s.length()
  // Count consecutive line breaks, skipping trailing spaces on each line and
  // leading spaces on the next.
  let mut j = i
  let mut nls = 0
  while j < len {
    let c = s.unsafe_get(j).to_int()
    if c == '\r' {
      if j + 1 < len && s.unsafe_get(j + 1).to_int() == '\n' {
        j = j + 2
      } else {
        j = j + 1
      }
      nls = nls + 1
    } else if c == '\n' {
      j = j + 1
      nls = nls + 1
    } else if c == ' ' || c == '\t' {
      j = j + 1
    } else {
      break
    }
  }
  let replacement = if nls <= 1 { " " } else { String::make(nls - 1, '\n') }
  (replacement, j)
}

///|
/// Apply YAML line folding to a (single-quoted) scalar's content: single line
/// breaks become spaces, multiple become n-1 newlines.
fn fold_quoted(s : String) -> String {
  let out = StringBuilder::new()
  let len = s.length()
  let mut i = 0
  while i < len {
    let c = s.unsafe_get(i).to_int()
    if c == '\n' || c == '\r' {
      let (folded, ni) = fold_break(s, i)
      out.write_string(folded)
      i = ni
    } else {
      out.write_char(c.unsafe_to_char())
      i = i + 1
    }
  }
  out.to_string()
}

///|
/// Decode a block scalar body. `body` is the raw indented lines (including
/// their trailing line breaks). `header_col` is the 0-based column of the
/// `|`/`>` indicator; content indentation is measured relative to it.
fn decode_block_scalar(
  body : String,
  folded : Bool,
  chomp : Char,
  explicit_indent : Int,
  header_col : Int,
) -> String {
  if body.length() == 0 {
    return ""
  }
  let lines = split_lines(body)
  // Determine content indentation.
  let indent = if explicit_indent > 0 {
    header_col + explicit_indent
  } else {
    // First non-empty line's indentation.
    let mut found = -1
    for ln in lines {
      let li = leading_spaces(ln)
      if li < ln.length() {
        found = li
        break
      }
    }
    if found < 0 {
      // all blank
      header_col + 1
    } else {
      found
    }
  }
  let out : Array[String] = []
  for ln in lines {
    if leading_spaces(ln) >= ln.length() {
      // blank (whitespace-only) line: strip to empty after removing indent.
      let li = leading_spaces(ln)
      if li > indent {
        out.push(ln[indent:].to_owned())
      } else {
        out.push("")
      }
    } else if ln.length() >= indent {
      out.push(ln[indent:].to_owned())
    } else {
      out.push(ln)
    }
  }
  // Join with folding.
  let joined = if folded { fold_block_lines(out) } else { join_lines(out) }
  apply_chomping(joined, chomp)
}

///|
/// Split block-scalar body into logical lines (without their line breaks). A
/// trailing newline yields a trailing empty element only if there is content
/// after it, mirroring how we then re-add chomped newlines.
fn split_lines(s : String) -> Array[String] {
  let lines : Array[String] = []
  let sb = StringBuilder::new()
  let len = s.length()
  let mut i = 0
  while i < len {
    let c = s.unsafe_get(i).to_int()
    if c == '\r' {
      lines.push(sb.to_string())
      sb.reset()
      if i + 1 < len && s.unsafe_get(i + 1).to_int() == '\n' {
        i = i + 2
      } else {
        i = i + 1
      }
    } else if c == '\n' {
      lines.push(sb.to_string())
      sb.reset()
      i = i + 1
    } else {
      sb.write_char(c.unsafe_to_char())
      i = i + 1
    }
  }
  // Trailing content without a final newline.
  if sb.to_string().length() > 0 {
    lines.push(sb.to_string())
  }
  lines
}

///|
fn leading_spaces(s : String) -> Int {
  let mut i = 0
  let len = s.length()
  while i < len {
    let c = s.unsafe_get(i).to_int()
    if c == ' ' {
      i = i + 1
    } else {
      break
    }
  }
  i
}

///|
/// Literal join: each line followed by a newline.
fn join_lines(lines : Array[String]) -> String {
  let sb = StringBuilder::new()
  for ln in lines {
    sb.write_string(ln)
    sb.write_char('\n')
  }
  sb.to_string()
}

///|
/// Folded join: consecutive non-empty lines are joined with a space; blank
/// lines become newlines; more-indented lines keep their breaks.
fn fold_block_lines(lines : Array[String]) -> String {
  let sb = StringBuilder::new()
  let n = lines.length()
  let mut i = 0
  let mut prev_blank_or_indented = true
  while i < n {
    let ln = lines[i]
    let is_blank = ln.length() == 0
    let is_indented = ln.length() > 0 &&
      (ln.unsafe_get(0).to_int() == ' ' || ln.unsafe_get(0).to_int() == '\t')
    if i == 0 {
      sb.write_string(ln)
      prev_blank_or_indented = is_blank || is_indented
      i = i + 1
      continue
    }
    if is_blank {
      sb.write_char('\n')
      prev_blank_or_indented = true
    } else if is_indented || prev_blank_or_indented {
      // Keep a literal break before more-indented or after blank lines.
      sb.write_char('\n')
      sb.write_string(ln)
      prev_blank_or_indented = is_indented
    } else {
      sb.write_char(' ')
      sb.write_string(ln)
      prev_blank_or_indented = false
    }
    i = i + 1
  }
  sb.write_char('\n')
  sb.to_string()
}

///|
/// Apply chomping to a joined block-scalar string that ends with a single
/// trailing newline. `-` strips all trailing newlines, `+` keeps them all,
/// default (clip) keeps exactly one.
fn apply_chomping(s : String, chomp : Char) -> String {
  match chomp {
    '-' => {
      // strip all trailing line breaks
      let mut end = s.length()
      while end > 0 {
        let c = s.unsafe_get(end - 1).to_int()
        if c == '\n' || c == '\r' {
          end = end - 1
        } else {
          break
        }
      }
      s[0:end].to_owned()
    }
    '+' => s
    _ => {
      // clip: exactly one trailing newline if there is content
      let mut end = s.length()
      while end > 0 {
        let c = s.unsafe_get(end - 1).to_int()
        if c == '\n' || c == '\r' {
          end = end - 1
        } else {
          break
        }
      }
      if end == 0 {
        ""
      } else {
        s[0:end].to_owned() + "\n"
      }
    }
  }
}
