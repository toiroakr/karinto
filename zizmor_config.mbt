///|
/// zizmor config-file support.
///
/// zizmor opts out of an audit through `zizmor.yml` / `.github/zizmor.yml`
/// rather than (or in addition to) inline comments. The `rules:` section keys
/// each audit by its id; `disable: true` turns it off everywhere and `ignore:`
/// lists `filename[:line[:col]]` locations to skip. zizmor's audit ids are
/// Karinto's rule ids verbatim, so they map directly with no translation.

///|
/// One `ignore:` location. `line == None` means "any line in `filename`";
/// `col == None` means "any column on that line". A pinned column is honoured
/// (diagnostics are stamped with line/column before the config filter runs).
priv struct ZizmorIgnore {
  filename : String
  line : Int?
  col : Int?
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
/// Union two zizmor configs — used to combine an explicit `zizmor_config`
/// with the zizmor-shaped `rules:` entries read out of a `karinto_config`
/// (see `lint()`). `disabled` is deduped; `ignores` concatenates per-rule
/// entry lists rather than letting one source's key clobber the other's.
fn merge_zizmor_configs(a : ZizmorConfig, b : ZizmorConfig) -> ZizmorConfig {
  let disabled : Array[String] = []
  for d in a.disabled {
    disabled.push(d)
  }
  for d in b.disabled {
    if !disabled.contains(d) {
      disabled.push(d)
    }
  }
  let ignores : Map[String, Array[ZizmorIgnore]] = {}
  a.ignores.each(fn(rule_id, pats) { ignores[rule_id] = pats })
  b.ignores.each(fn(rule_id, pats) {
    match ignores.get(rule_id) {
      Some(existing) => {
        let merged : Array[ZizmorIgnore] = []
        for p in existing {
          merged.push(p)
        }
        for p in pats {
          merged.push(p)
        }
        ignores[rule_id] = merged
      }
      None => ignores[rule_id] = pats
    }
  })
  ZizmorConfig::{ disabled, ignores }
}

///|
/// Split a `filename[:line[:col]]` ignore entry. Lines and columns are 1-based,
/// so a non-positive (or non-numeric) value is treated as "any" rather than a
/// value that could never match a diagnostic.
fn parse_zizmor_ignore(s : String) -> ZizmorIgnore {
  fn pos_or_none(v : String) -> Int? {
    let n = parse_uint(v)
    if n > 0 {
      Some(n)
    } else {
      None
    }
  }

  match split_once(s, ":") {
    None => ZizmorIgnore::{ filename: s, line: None, col: None }
    Some((fname, rest)) => {
      let (line_str, col_str) = match split_once(rest, ":") {
        Some((l, c)) => (l, c)
        None => (rest, "")
      }
      ZizmorIgnore::{
        filename: fname,
        line: pos_or_none(line_str),
        col: pos_or_none(col_str),
      }
    }
  }
}

///|
/// Whether the file under lint matches a zizmor `ignore` filename: an exact
/// match, or a path-boundary suffix (so a bare-filename pattern like `ci.yml`
/// matches `.github/workflows/ci.yml`). An empty `file_path` matches nothing,
/// so a location-scoped ignore is conservatively not applied.
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
/// `disable`d, or an `ignore:` entry matches the file (and the line, then the
/// column, when the entry pins them).
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
      None => return true
      Some(ln) => {
        guard d.pos is Some(pos) && pos.line == ln else { continue }
        // Line matches; honour a pinned column when the entry has one.
        match p.col {
          None => return true
          Some(c) => if pos.col == c { return true }
        }
      }
    }
  }
  false
}
