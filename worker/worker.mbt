///|
/// JS entry point for the Cloudflare Worker.
///
/// Takes the YAML content, file kind hint (`"workflow"` | `"action"` | `""`),
/// a comma-separated `disable` glob list, and a CSV of `uses:` refs the
/// caller already knows are vulnerable (e.g. fetched from OSV.dev). Returns
/// a JSON string with the lint diagnostics and metadata.

///|
pub fn lint_string(
  content : String,
  kind_str : String,
  disable_str : String,
  vuln_uses_str : String,
) -> String {
  let kind = match kind_str {
    "workflow" => @curllint.FileKind::Workflow
    "action" => @curllint.FileKind::Action
    _ => @curllint.FileKind::Unknown
  }
  let disabled = split_csv(disable_str)
  let vuln_uses = split_csv(vuln_uses_str)
  let result = @curllint.lint(content, kind~, disabled~, vuln_uses~)
  let body : Map[String, Json] = {
    "ok": (result.parse_error is None).to_json(),
    "result": result.to_json(),
  }
  body.to_json().stringify()
}

///|
/// Match a list of `uses:` refs against an OSV-derived advisories map and
/// return the subset whose pinned version falls inside an advisory range.
///
/// `uses_csv`: comma-separated `owner/repo[/subpath]@ref` strings.
/// `advisories_json`: `{ "owner/repo": [{ "events": [{...}] }, ...] }` —
///   one entry per affected package; each entry's events list mirrors the
///   OSV ECOSYSTEM range events (`introduced` / `fixed` / `last_affected`).
///
/// Returns a CSV of original refs that hit; "" on parse failure or no hits.
pub fn osv_match(uses_csv : String, advisories_json : String) -> String {
  let refs = split_csv(uses_csv)
  if refs.length() == 0 || advisories_json == "" {
    return ""
  }
  let parsed = try? @json.parse(advisories_json)
  let advisories : Map[String, Array[VersionRange]] = match parsed {
    Ok(j) =>
      match j.as_object() {
        Some(m) => parse_advisories_map(m)
        None => Map::new()
      }
    Err(_) => Map::new()
  }
  let out = StringBuilder::new()
  let seen : Map[String, Bool] = Map::new()
  let mut first = true
  for r in refs {
    let at = last_at(r)
    if at < 0 {
      continue
    }
    let name_full = r.substring(start=0, end=at)
    let version = r.substring(start=at + 1)
    let name = action_root(name_full)
    match advisories.get(name) {
      Some(ranges) => {
        let mut hit = false
        for rg in ranges {
          if version_in_range(version, rg) {
            hit = true
            break
          }
        }
        if hit && !seen.contains(r) {
          seen[r] = true
          if !first {
            out.write_char(',')
          }
          out.write_string(r)
          first = false
        }
      }
      None => ()
    }
  }
  out.to_string()
}

///|
struct VersionRange {
  introduced : Array[Int]?
  fixed : Array[Int]?
  last_affected : Array[Int]?
}

///|
fn parse_advisories_map(
  m : Map[String, Json],
) -> Map[String, Array[VersionRange]] {
  let out : Map[String, Array[VersionRange]] = Map::new()
  m.each(fn(name, ranges_json) {
    match ranges_json.as_array() {
      Some(arr) => {
        let ranges : Array[VersionRange] = []
        for entry in arr {
          match entry.as_object() {
            Some(em) => {
              let events = match em.get("events") {
                Some(e) =>
                  match e.as_array() {
                    Some(a) => a
                    None => []
                  }
                None => []
              }
              let mut intro : Array[Int]? = None
              let mut fixed : Array[Int]? = None
              let mut last : Array[Int]? = None
              for ev in events {
                match ev.as_object() {
                  Some(evm) => {
                    match read_ver_field(evm, "introduced") {
                      Some(v) => intro = Some(v)
                      None => ()
                    }
                    match read_ver_field(evm, "fixed") {
                      Some(v) => fixed = Some(v)
                      None => ()
                    }
                    match read_ver_field(evm, "last_affected") {
                      Some(v) => last = Some(v)
                      None => ()
                    }
                  }
                  None => ()
                }
              }
              ranges.push(VersionRange::{
                introduced: intro,
                fixed,
                last_affected: last,
              })
            }
            None => ()
          }
        }
        out[name] = ranges
      }
      None => ()
    }
  })
  out
}

///|
fn read_ver_field(m : Map[String, Json], key : String) -> Array[Int]? {
  match m.get(key) {
    Some(j) =>
      match j.as_string() {
        Some(s) => normalize_ver(s)
        None => None
      }
    None => None
  }
}

///|
/// Strip a leading `v` and split on `.`. Returns `None` for non-numeric tags
/// (SHAs, branch names) — callers treat that as "match conservatively".
pub fn normalize_ver(s : String) -> Array[Int]? {
  if s == "" {
    return None
  }
  let body = if s.has_prefix("v") || s.has_prefix("V") {
    s.substring(start=1)
  } else {
    s
  }
  if body == "" {
    return None
  }
  let parts : Array[Int] = []
  let buf = StringBuilder::new()
  for ch in body {
    if ch == '.' {
      let n = parse_int_or_neg(buf.to_string())
      if n < 0 {
        return None
      }
      parts.push(n)
      buf.reset()
    } else if ch >= '0' && ch <= '9' {
      buf.write_char(ch)
    } else {
      return None
    }
  }
  let tail = parse_int_or_neg(buf.to_string())
  if tail < 0 {
    return None
  }
  parts.push(tail)
  Some(parts)
}

///|
fn parse_int_or_neg(s : String) -> Int {
  if s == "" {
    return -1
  }
  let mut n = 0
  for ch in s {
    if ch < '0' || ch > '9' {
      return -1
    }
    n = n * 10 + (ch.to_int() - '0'.to_int())
  }
  n
}

///|
pub fn cmp_ver(a : Array[Int], b : Array[Int]) -> Int {
  let la = a.length()
  let lb = b.length()
  let n = if la > lb { la } else { lb }
  let mut i = 0
  while i < n {
    let x = if i < la { a[i] } else { 0 }
    let y = if i < lb { b[i] } else { 0 }
    if x != y {
      return if x < y { -1 } else { 1 }
    }
    i = i + 1
  }
  0
}

///|
fn version_in_range(tag : String, rg : VersionRange) -> Bool {
  match normalize_ver(tag) {
    None => true // unknown form (SHA / branch) — flag conservatively
    Some(ver) => {
      match rg.introduced {
        Some(intro) => if cmp_ver(ver, intro) < 0 { return false }
        None => ()
      }
      match rg.fixed {
        Some(fx) => if cmp_ver(ver, fx) >= 0 { return false }
        None => ()
      }
      match rg.last_affected {
        Some(la) => if cmp_ver(ver, la) > 0 { return false }
        None => ()
      }
      true
    }
  }
}

///|
fn last_at(s : String) -> Int {
  let mut at = -1
  let mut i = 0
  let n = s.length()
  while i < n {
    match s.get_char(i) {
      Some('@') => at = i
      _ => ()
    }
    i = i + 1
  }
  at
}

///|
/// `actions/cache/restore` → `actions/cache` (OSV indexes by root action).
fn action_root(name : String) -> String {
  let chars = name.to_array()
  let n = chars.length()
  let mut slashes = 0
  let mut i = 0
  while i < n {
    if chars[i] == '/' {
      slashes = slashes + 1
      if slashes == 2 {
        return name.substring(start=0, end=i)
      }
    }
    i = i + 1
  }
  name
}

///|
fn split_csv(s : String) -> Array[String] {
  if s == "" {
    return []
  }
  let out : Array[String] = []
  let buf = StringBuilder::new()
  for ch in s {
    if ch == ',' {
      let piece = buf.to_string().trim(chars=" \t").to_owned()
      if piece != "" {
        out.push(piece)
      }
      buf.reset()
    } else {
      buf.write_char(ch)
    }
  }
  let last = buf.to_string().trim(chars=" \t").to_owned()
  if last != "" {
    out.push(last)
  }
  out
}
