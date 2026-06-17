///|
/// zizmor config-file support.
///
/// zizmor opts out of an audit through `zizmor.yml` / `.github/zizmor.yml`
/// rather than (or in addition to) inline comments. The `rules:` section keys
/// each audit by its id; `disable: true` turns it off everywhere and `ignore:`
/// lists `filename[:line[:col]]` locations to skip. zizmor's audit ids are
/// Karinto's rule ids verbatim, so they map directly with no translation.

///|
/// One `ignore:` location. `line == None` means "any line in `filename`"; the
/// column zizmor records is not tracked (line scope is enough).
priv struct ZizmorIgnore {
  filename : String
  line : Int?
}

///|
priv struct ZizmorConfig {
  disabled : Array[String]
  ignores : Map[String, Array[ZizmorIgnore]]
}

///|
/// Parse a zizmor config into its disabled-rule set and per-rule `ignore`
/// locations. Best-effort: a malformed config yields an empty result rather
/// than crashing the lint.
fn parse_zizmor_config(config : String) -> ZizmorConfig {
  let disabled : Array[String] = []
  let ignores : Map[String, Array[ZizmorIgnore]] = {}
  let parsed = try? @yaml.Yaml::load_from_string(config)
  guard parsed is Ok(docs) else { return ZizmorConfig::{ disabled, ignores } }
  for d in docs {
    guard d is Map(top) else { continue }
    guard top.get("rules") is Some(Map(rules)) else { continue }
    rules.each(fn(rule_id, spec) {
      guard spec is Map(sm) else { return }
      if sm.get("disable") is Some(Boolean(true)) {
        disabled.push(rule_id)
      }
      guard sm.get("ignore") is Some(Array(items)) else { return }
      let pats : Array[ZizmorIgnore] = []
      for it in items {
        if it is String(s) {
          pats.push(parse_zizmor_ignore(s))
        }
      }
      if pats.length() > 0 {
        ignores[rule_id] = pats
      }
    })
  }
  ZizmorConfig::{ disabled, ignores }
}

///|
/// Split a `filename[:line[:col]]` ignore entry. A non-numeric line is treated
/// as "any line".
fn parse_zizmor_ignore(s : String) -> ZizmorIgnore {
  match split_once(s, ":") {
    None => ZizmorIgnore::{ filename: s, line: None }
    Some((fname, rest)) => {
      let line_str = match split_once(rest, ":") {
        Some((l, _)) => l
        None => rest
      }
      let n = parse_uint(line_str)
      ZizmorIgnore::{
        filename: fname,
        line: if n >= 0 {
          Some(n)
        } else {
          None
        },
      }
    }
  }
}

///|
/// Whether the file under lint matches a zizmor `ignore` filename (exact, a
/// path-boundary suffix, or the bare basename). An empty `file_path` matches
/// nothing, so a location-scoped ignore is conservatively not applied.
fn zizmor_ignore_file_matches(file_path : String, pat : String) -> Bool {
  if file_path == "" {
    return false
  }
  let f = strip_dot_slash(file_path)
  let p = strip_dot_slash(pat)
  f == p || ends_with(f, "/" + p)
}

///|
/// Whether diagnostic `d` is suppressed by the zizmor config: its rule is
/// `disable`d, or an `ignore:` entry matches the file (and the line, when the
/// entry pins one).
fn zizmor_config_excluded(
  d : Diagnostic,
  cfg : ZizmorConfig,
  file_path : String,
) -> Bool {
  if cfg.disabled.contains(d.rule) {
    return true
  }
  guard cfg.ignores.get(d.rule) is Some(pats) else { return false }
  for p in pats {
    if !zizmor_ignore_file_matches(file_path, p.filename) {
      continue
    }
    match p.line {
      Some(ln) => if d.pos is Some(pos) && pos.line == ln { return true }
      None => return true
    }
  }
  false
}
