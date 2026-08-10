///|
/// karinto-native config-file support (`karinto.yaml`, wired through the
/// CLI's `--config` and the Worker's `config` parameter).
///
/// Two top-level keys intentionally reuse actionlint.yaml's own key names and
/// shapes — `self-hosted-runner.labels` and `config-variables` — so an
/// existing `.github/actionlint.yaml` is already a valid (partial) karinto
/// config for those two settings; no separate actionlint-config parser is
/// needed. `rules` (per-rule severity override) and `ignore-paths` (per-path
/// rule ignores) are karinto-native, with no actionlint equivalent.
/// `ignore-paths` is deliberately not named `paths`, to avoid colliding with
/// actionlint's own `paths.*.ignore` (message-regex ignores against
/// actionlint's own messages — out of scope, see #50): reusing that name
/// would invite a `.github/actionlint.yaml`'s regex strings to be silently
/// (mis)matched against karinto rule IDs instead.
priv struct KarintoConfig {
  self_hosted_runner_labels : Array[String]
  // `None` = disabled (default — matches actionlint's own default), `Some([])`
  // = forbid every `vars.*` reference, `Some([...])` = allow only those names.
  config_variables : Array[String]?
  rule_severity : Map[String, Severity]
  ignore_paths : Array[(String, Array[String])]
}

///|
fn empty_karinto_config() -> KarintoConfig {
  KarintoConfig::{
    self_hosted_runner_labels: [],
    config_variables: None,
    rule_severity: {},
    ignore_paths: [],
  }
}

///|
/// Collect the string-valued entries of a YAML sequence, skipping any
/// non-string item rather than failing the whole config.
fn yaml_string_array(items : Array[@yaml.Yaml]) -> Array[String] {
  let out : Array[String] = []
  for it in items {
    match it {
      String(s) => out.push(s)
      _ => ()
    }
  }
  out
}

///|
fn parse_severity_string(s : String) -> Severity? {
  match s.trim(chars=" \t").to_owned() {
    "error" => Some(Error)
    "warning" => Some(Warning)
    "info" => Some(Info)
    _ => None
  }
}

///|
/// Parse a karinto config document (`karinto.yaml`, or a compatible
/// `.github/actionlint.yaml`) into a `KarintoConfig`. Best-effort: a
/// malformed config yields the all-default config rather than crashing the
/// lint, matching `parse_ghalint_excludes` / `parse_zizmor_config`.
fn parse_karinto_config(config : String) -> KarintoConfig {
  let empty = empty_karinto_config()
  let parsed = try? @yaml.Yaml::load_from_string(config)
  guard parsed is Ok(docs) else { return empty }
  guard docs.length() > 0 else { return empty }
  guard docs[0] is Map(top) else { return empty }
  let self_hosted_runner_labels = match top.get("self-hosted-runner") {
    Some(Map(sm)) =>
      match sm.get("labels") {
        Some(Array(items)) => yaml_string_array(items)
        _ => []
      }
    _ => []
  }
  let config_variables = match top.get("config-variables") {
    Some(Array(items)) => Some(yaml_string_array(items))
    _ => None
  }
  let rule_severity : Map[String, Severity] = {}
  match top.get("rules") {
    Some(Map(rm)) =>
      rm.each(fn(rule_id, v) {
        match v {
          String(s) =>
            match parse_severity_string(s) {
              Some(sev) => rule_severity[rule_id] = sev
              None => ()
            }
          _ => ()
        }
      })
    _ => ()
  }
  let ignore_paths : Array[(String, Array[String])] = []
  match top.get("ignore-paths") {
    Some(Map(pm)) =>
      pm.each(fn(glob, v) {
        match v {
          Array(items) => ignore_paths.push((glob, yaml_string_array(items)))
          _ => ()
        }
      })
    _ => ()
  }
  KarintoConfig::{
    self_hosted_runner_labels,
    config_variables,
    rule_severity,
    ignore_paths,
  }
}

///|
/// Whether diagnostic `d`'s rule is ignored under `ignore-paths` for the file
/// under lint. `"*"` in a glob's rule-id list ignores every rule matched by
/// that glob. An empty `file_path` matches nothing (mirrors ghalint's
/// path-scoped excludes), so this stays inert for callers that don't pass a
/// path (e.g. stdin).
fn karinto_config_path_ignored(
  rule : String,
  file_path : String,
  ignore_paths : Array[(String, Array[String])],
) -> Bool {
  if file_path == "" || ignore_paths.length() == 0 {
    return false
  }
  let f = strip_dot_slash(file_path)
  for entry in ignore_paths {
    let (glob, rules) = entry
    if !glob_match(strip_dot_slash(glob), f) {
      continue
    }
    for r in rules {
      if r == "*" || r == rule {
        return true
      }
    }
  }
  false
}
