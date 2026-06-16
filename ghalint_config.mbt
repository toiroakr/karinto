///|
/// ghalint config-file support.
///
/// ghalint opts out of a policy via its config file (`ghalint.yaml` /
/// `.ghalint.yaml`) rather than inline comments. The relevant section is
/// `excludes`, a list of entries keyed by `policy_name` and optionally scoped
/// to a `workflow_file_path`, `job_name`, `action_name`, or `step_id`.
///
/// Karinto honours such a config so a repo already carrying a ghalint
/// `excludes` list lints cleanly. ghalint's policy names are mapped onto
/// karinto rule IDs through the `origins` metadata in `rules_catalog.mbt`
/// (e.g. `ghalint:ghl-004 (deny_inherit_secrets)` ties the policy
/// `deny_inherit_secrets` to whichever karinto rule absorbed it). actionlint
/// is deliberately not handled here: its config ignores by regex against the
/// (tool-specific) error message, which does not map onto karinto's findings.

///|
/// One `excludes:` entry. `policy` is required; the rest narrow *where* the
/// exclusion applies — an absent field means "any".
priv struct GhalintExclude {
  policy : String
  workflow_file_path : String?
  job_name : String?
  action_name : String?
  step_id : String?
}

///|
/// Read a string-valued field from a YAML mapping, if present and a scalar
/// string.
fn ghalint_yaml_str(m : Map[String, @yaml.Yaml], key : String) -> String? {
  match m.get(key) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// Parse a ghalint config document into its `excludes` entries. A malformed
/// or position-less config yields no entries (best-effort: a bad config never
/// crashes a lint). Entries without a `policy_name` are skipped.
fn parse_ghalint_excludes(config : String) -> Array[GhalintExclude] {
  let out : Array[GhalintExclude] = []
  let parsed = try? @yaml.Yaml::load_from_string(config)
  guard parsed is Ok(docs) else { return out }
  for d in docs {
    guard d is Map(top) else { continue }
    guard top.get("excludes") is Some(Array(items)) else { continue }
    for it in items {
      guard it is Map(em) else { continue }
      guard ghalint_yaml_str(em, "policy_name") is Some(policy) else {
        continue
      }
      out.push(GhalintExclude::{
        policy,
        workflow_file_path: ghalint_yaml_str(em, "workflow_file_path"),
        job_name: ghalint_yaml_str(em, "job_name"),
        action_name: ghalint_yaml_str(em, "action_name"),
        step_id: ghalint_yaml_str(em, "step_id"),
      })
    }
  }
  out
}

///|
/// Map each ghalint policy name to the karinto rule IDs that cover it, derived
/// from the `origins` strings in the rule catalogue. An origin such as
/// `ghalint:ghl-004 (deny_inherit_secrets)` registers `deny_inherit_secrets ->
/// <rule id>`. One policy can map to several rules (consolidations).
fn ghalint_policy_map() -> Map[String, Array[String]] {
  let m : Map[String, Array[String]] = {}
  for spec in all_rule_specs() {
    for origin in spec.origins {
      // Only ghalint origins carry a `(policy_name)`; skip everything else.
      guard index_of(origin, "ghalint") is Some(_) else { continue }
      guard index_of(origin, "(") is Some(a) else { continue }
      guard index_of(origin, ")") is Some(b) else { continue }
      if b <= a + 1 {
        continue
      }
      let name = origin[a + 1:b].to_owned()
      let ids = match m.get(name) {
        Some(existing) => existing
        None => {
          let fresh : Array[String] = []
          m[name] = fresh
          fresh
        }
      }
      ids.push(spec.id)
    }
  }
  m
}

///|
/// Drop a leading `./` so relative-path comparisons line up.
fn strip_dot_slash(p : String) -> String {
  if index_of(p, "./") is Some(0) {
    p[2:].to_owned()
  } else {
    p
  }
}

///|
/// Whether `s` ends with `suffix`.
fn ends_with(s : String, suffix : String) -> Bool {
  let sl = s.length()
  let fl = suffix.length()
  if fl > sl {
    return false
  }
  s[sl - fl:].to_owned() == suffix
}

///|
/// Whether the file under lint matches a ghalint `workflow_file_path`. ghalint
/// records the path relative to the repo root; we accept an exact match or a
/// path-boundary suffix match so callers can pass either a relative or a
/// longer absolute path. An empty `file_path` (caller gave none) matches
/// nothing, so a path-scoped exclude is conservatively *not* applied.
fn ghalint_path_matches(file_path : String, wfp : String) -> Bool {
  if file_path == "" {
    return false
  }
  let f = strip_dot_slash(file_path)
  let w = strip_dot_slash(wfp)
  f == w || ends_with(f, "/" + w)
}

///|
/// Whether a step's `uses:` value refers to ghalint's `action_name`. ghalint
/// names the action without its `@ref`; a `uses:` of `owner/repo/path@ref`
/// matches `owner/repo` or `owner/repo/path`.
fn ghalint_uses_matches(uses : String, action_name : String) -> Bool {
  let base = match index_of(uses, "@") {
    Some(i) => uses[0:i].to_owned()
    None => uses
  }
  base == action_name || index_of(base, action_name + "/") is Some(0)
}

///|
/// The `uses:` value of the step at `index` within its job (or composite
/// action when `job` is `None`), read from the value tree.
fn ghalint_step_uses(doc : @yaml.Yaml, job : String?, index : Int) -> String? {
  let steps = match job {
    Some(name) => {
      guard doc is Map(top) else { return None }
      guard top.get("jobs") is Some(Map(js)) else { return None }
      guard js.get(name) is Some(Map(jm)) else { return None }
      jm.get("steps")
    }
    None => {
      guard doc is Map(top) else { return None }
      guard top.get("runs") is Some(Map(rm)) else { return None }
      rm.get("steps")
    }
  }
  guard steps is Some(Array(items)) else { return None }
  if index < 0 || index >= items.length() {
    return None
  }
  guard items[index] is Map(sm) else { return None }
  match sm.get("uses") {
    Some(String(u)) => Some(u)
    _ => None
  }
}

///|
/// Whether diagnostic `d` is excluded by any ghalint `excludes` entry. Every
/// scope field present on the entry must match the finding's context.
fn ghalint_excluded(
  d : Diagnostic,
  excludes : Array[GhalintExclude],
  policy_map : Map[String, Array[String]],
  file_path : String,
  doc : @yaml.Yaml,
) -> Bool {
  for e in excludes {
    guard policy_map.get(e.policy) is Some(ids) else { continue }
    if !ids.contains(d.rule) {
      continue
    }
    match e.workflow_file_path {
      Some(wfp) => if !ghalint_path_matches(file_path, wfp) { continue }
      None => ()
    }
    match e.job_name {
      Some(jn) => if !(d.job is Some(j) && j == jn) { continue }
      None => ()
    }
    match e.step_id {
      Some(sid) =>
        if !(d.step is Some(s) && s.id is Some(id) && id == sid) {
          continue
        }
      None => ()
    }
    match e.action_name {
      Some(an) =>
        match d.step {
          Some(s) =>
            match ghalint_step_uses(doc, d.job, s.index) {
              Some(u) => if !ghalint_uses_matches(u, an) { continue }
              None => continue
            }
          None => continue
        }
      None => ()
    }
    return true
  }
  false
}
