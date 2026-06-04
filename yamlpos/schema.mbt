///| YAML 1.2 core-schema scalar type resolution and explicit-tag application.

///|
/// Resolve a plain scalar's decoded text to a typed value following the core
/// schema, unless an explicit `tag` forces a representation.
fn resolve_scalar_value(
  raw : String,
  style : ScalarStyle,
  tag : String?,
) -> ScalarValue {
  match tag {
    Some(tg) => apply_tag_to_string(raw, tg)
    None =>
      match style {
        Plain => core_resolve(raw)
        _ => Str(raw)
      }
  }
}

///|
/// Apply an explicit tag to a string value, coercing per common YAML tags.
fn apply_tag_to_string(raw : String, tag : String) -> ScalarValue {
  match tag {
    "tag:yaml.org,2002:str" | "!!str" => Str(raw)
    "tag:yaml.org,2002:null" | "!!null" =>
      match raw {
        "" | "~" | "null" | "Null" | "NULL" => Null
        _ => Bad
      }
    "tag:yaml.org,2002:bool" | "!!bool" =>
      match parse_bool(raw) {
        Some(b) => Bool(b)
        None => Bad
      }
    "tag:yaml.org,2002:int" | "!!int" =>
      match parse_int(raw) {
        Some(n) => Int(n)
        None => Bad
      }
    "tag:yaml.org,2002:float" | "!!float" =>
      match parse_float(raw) {
        Some(f) => Float(f, repr=raw)
        None =>
          // An integer-looking value under an explicit `!!float` tag is a
          // valid float (e.g. `!!float 2`).
          match parse_int(raw) {
            Some(n) => Float(n.to_double(), repr=raw)
            None => Bad
          }
      }
    _ => Str(raw)
  }
}

///|
/// Core-schema resolution of a plain scalar.
fn core_resolve(raw : String) -> ScalarValue {
  if raw == "" {
    return Null
  }
  // null
  match raw {
    "~" | "null" | "Null" | "NULL" => return Null
    "true" | "True" | "TRUE" => return Bool(true)
    "false" | "False" | "FALSE" => return Bool(false)
    _ => ()
  }
  match parse_int(raw) {
    Some(n) => return Int(n)
    None => ()
  }
  match parse_float(raw) {
    Some(f) => return Float(f, repr=raw)
    None => ()
  }
  Str(raw)
}

///|
fn parse_bool(raw : String) -> Bool? {
  match raw {
    "true" | "True" | "TRUE" => Some(true)
    "false" | "False" | "FALSE" => Some(false)
    _ => None
  }
}

///|
/// Parse an integer per the core schema: decimal, `0x` hex, `0o` octal.
fn parse_int(raw : String) -> Int64? {
  if raw == "" {
    return None
  }
  let mut neg = false
  let mut start = 0
  let first = raw.unsafe_get(0).to_int()
  if first == '-' {
    neg = true
    start = 1
  } else if first == '+' {
    start = 1
  }
  if start >= raw.length() {
    return None
  }
  let rest = raw[start:].to_owned()
  let (base, digits) = if rest.has_prefix("0x") || rest.has_prefix("0X") {
    (16, rest[2:].to_owned())
  } else if rest.has_prefix("0o") {
    (8, rest[2:].to_owned())
  } else {
    (10, rest)
  }
  if digits == "" {
    return None
  }
  let mut value : Int64 = 0
  for c in digits {
    let d = digit_value(c)
    if d < 0 || d >= base {
      return None
    }
    value = value * base.to_int64() + d.to_int64()
  }
  Some(if neg { -value } else { value })
}

///|
fn digit_value(c : Char) -> Int {
  let n = c.to_int()
  if n >= '0' && n <= '9' {
    n - '0'
  } else if n >= 'a' && n <= 'f' {
    n - 'a' + 10
  } else if n >= 'A' && n <= 'F' {
    n - 'A' + 10
  } else {
    -1
  }
}

///|
/// Parse a float per the core schema, including `.inf`, `-.inf`, `.nan`, and
/// scientific notation.
fn parse_float(raw : String) -> Double? {
  match raw {
    ".inf" | ".Inf" | ".INF" | "+.inf" | "+.Inf" | "+.INF" =>
      return Some(@double.infinity)
    "-.inf" | "-.Inf" | "-.INF" => return Some(@double.neg_infinity)
    ".nan" | ".NaN" | ".NAN" => return Some(@double.not_a_number)
    _ => ()
  }
  // Must look numeric: contain a digit and only valid float chars, with at
  // least one of '.' or 'e' to distinguish from ints (ints handled earlier).
  if !looks_like_float(raw) {
    return None
  }
  Some(@string.parse_double(raw)) catch {
    _ => None
  }
}

///|
fn looks_like_float(raw : String) -> Bool {
  let len = raw.length()
  if len == 0 {
    return false
  }
  let mut has_digit = false
  let mut has_dot_or_e = false
  let mut i = 0
  while i < len {
    let c = raw.unsafe_get(i).to_int()
    if c >= '0' && c <= '9' {
      has_digit = true
    } else if c == '.' || c == 'e' || c == 'E' {
      has_dot_or_e = true
    } else if c == '+' || c == '-' {
      () // sign
    } else {
      return false
    }
    i = i + 1
  }
  has_digit && has_dot_or_e
}
