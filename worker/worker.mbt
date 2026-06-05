///|
/// JS entry point for the Cloudflare Worker.
///
/// Takes the YAML content, file kind hint (`"workflow"` | `"action"` | `""`),
/// a comma-separated `disable` glob list, plus a few CSV inputs that feed
/// rules whose verdict depends on data the caller must resolve out-of-band
/// (typically via the GitHub / OSV.dev APIs). `vuln_uses_str` is a required
/// positional parameter (callers pass `""` when they have nothing to feed
/// `known-vulnerable-actions`); the remaining CSVs default to `""`.
/// When a CSV is empty the *caller-supplied augmentation* goes dormant —
/// rules with an offline baseline (e.g. `archived-uses` ships a hardcoded
/// `actions/setup-ruby` entry) still fire on their built-in entries.
///
///   * `vuln_uses_str`      — refs the caller has confirmed vulnerable
///                            (`known-vulnerable-actions`)
///   * `forbidden_uses_str` — denylist globs for `forbidden-uses`
///   * `archived_uses_str`  — refs whose repo is archived (`archived-uses`)
///
/// The Cloudflare Worker HTTP handler (`cf/index.js`) wires every input.
/// `vuln_uses_str` is populated from OSV.dev when the request sets `osv=1`;
/// `archived_uses_str` is merged from a KV-cached baseline plus the request's
/// `archived` parameter; `forbidden_uses_str` comes from the `forbidden`
/// parameter. The online `impostor-commit` / `ref-version-mismatch` audits
/// are NOT handled here — they are delegated to the companion action, which
/// resolves them via the GitHub API and reports findings directly.
///
/// Returns a JSON string with the lint diagnostics and metadata.

///|
pub fn lint_string(
  content : String,
  kind_str : String,
  disable_str : String,
  vuln_uses_str : String,
  forbidden_uses_str? : String = "",
  archived_uses_str? : String = "",
) -> String {
  let kind = match kind_str {
    "workflow" => @karinto.FileKind::Workflow
    "action" => @karinto.FileKind::Action
    _ => @karinto.FileKind::Unknown
  }
  let disabled = split_csv(disable_str)
  let vuln_uses = split_csv(vuln_uses_str)
  let forbidden_uses = split_csv(forbidden_uses_str)
  let archived_uses = split_csv(archived_uses_str)
  let result = @karinto.lint(
    content,
    kind~,
    disabled~,
    vuln_uses~,
    forbidden_uses~,
    archived_uses~,
  )
  let body : Map[String, Json] = {
    "ok": (result.parse_error is None).to_json(),
    "result": result.to_json(),
  }
  body.to_json().stringify()
}

///|
/// SARIF variant of `lint_string` (`format=sarif`, #33). Same lint inputs;
/// the output is a complete SARIF 2.1.0 document instead of the JSON
/// envelope. `path` is an optional artifact label for the linted content
/// (a relative path like `.github/workflows/ci.yml`): when non-empty every
/// result gets a `physicalLocation` pointing at it, which GitHub Code
/// Scanning needs to anchor findings; when `""` results carry logical
/// (job/step) locations only. `tool.driver.version` is stamped from
/// `ENGINE_VERSION`, which release automation keeps in lockstep with the
/// `package.json` version the HTTP layer reports.
pub fn lint_string_sarif(
  content : String,
  kind_str : String,
  disable_str : String,
  vuln_uses_str : String,
  forbidden_uses_str? : String = "",
  archived_uses_str? : String = "",
  path? : String = "",
) -> String {
  let kind = match kind_str {
    "workflow" => @karinto.FileKind::Workflow
    "action" => @karinto.FileKind::Action
    _ => @karinto.FileKind::Unknown
  }
  let result = @karinto.lint(
    content,
    kind~,
    disabled=split_csv(disable_str),
    vuln_uses=split_csv(vuln_uses_str),
    forbidden_uses=split_csv(forbidden_uses_str),
    archived_uses=split_csv(archived_uses_str),
  )
  let entry_path = if path == "" { None } else { Some(path) }
  @karinto.sarif_report([@karinto.SarifEntry::{ path: entry_path, result }]).stringify(
    indent=2,
  )
}

///|
/// Multi-file SARIF export for the Worker's repo mode (`format=sarif`).
///
/// `files_json` is a JSON array prepared by the HTTP layer, one object per
/// target: `{"path", "content", "kind", "vuln"}` for fetched files, or
/// `{"path", "error"}` for targets that could not be fetched (those become
/// `invocations[].toolExecutionNotifications`, mirroring envelope mode's
/// `{path, ok: false, error}` entries). `kind` / `vuln` are per-file because
/// repo mode guesses the kind from each path and resolves OSV advisories per
/// file. Malformed `files_json` (or malformed items) degrades to an empty
/// report rather than failing the request — the HTTP layer builds this JSON
/// itself, so a mismatch is a bug, not caller input.
pub fn lint_files_sarif(
  files_json : String,
  disable_str : String,
  forbidden_uses_str? : String = "",
  archived_uses_str? : String = "",
) -> String {
  let disabled = split_csv(disable_str)
  let forbidden_uses = split_csv(forbidden_uses_str)
  let archived_uses = split_csv(archived_uses_str)
  let entries : Array[@karinto.SarifEntry] = []
  let io_errors : Array[@karinto.SarifIoError] = []
  let parsed : Json = @json.parse(files_json) catch { _ => Json::null() }
  let items = match parsed {
    Array(a) => a
    _ => []
  }
  for item in items {
    let m = match item {
      Object(m) => m
      _ => continue
    }
    let path = match read_string_field(m, "path") {
      Some(p) => p
      None => continue
    }
    match read_string_field(m, "error") {
      Some(err) => {
        io_errors.push(@karinto.SarifIoError::{ path, message: err })
        continue
      }
      None => ()
    }
    let content = match read_string_field(m, "content") {
      Some(c) => c
      None => continue
    }
    let kind = match read_string_field(m, "kind") {
      Some("workflow") => @karinto.FileKind::Workflow
      Some("action") => @karinto.FileKind::Action
      _ => @karinto.FileKind::Unknown
    }
    let vuln_uses = match read_string_field(m, "vuln") {
      Some(v) => split_csv(v)
      None => []
    }
    let result = @karinto.lint(
      content,
      kind~,
      disabled~,
      vuln_uses~,
      forbidden_uses~,
      archived_uses~,
    )
    entries.push(@karinto.SarifEntry::{ path: Some(path), result })
  }
  @karinto.sarif_report(entries, io_errors~).stringify(indent=2)
}

///|
fn read_string_field(m : Map[String, Json], key : String) -> String? {
  match m.get(key) {
    Some(String(s)) => Some(s)
    _ => None
  }
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
