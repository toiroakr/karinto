///|
/// karinto-native config-file support (`karinto.yaml`, wired through the
/// CLI's `--config` and the Worker's `config` parameter).
///
/// Two top-level keys intentionally reuse actionlint.yaml's own key names and
/// shapes — `self-hosted-runner.labels` and `config-variables` — so an
/// existing `.github/actionlint.yaml` is already a valid (partial) karinto
/// config for those two settings; no separate parser is needed for *them*.
/// `rules` (per-rule severity override) and `ignore-paths` (per-path rule
/// ignores) are karinto-native, with no actionlint equivalent.
/// `ignore-paths` is deliberately not named `paths`, to avoid colliding with
/// actionlint's own `paths.*.ignore` (message-regex ignores against
/// actionlint's own messages): reusing that name here would invite a
/// `.github/actionlint.yaml`'s regex strings to be silently (mis)matched
/// against karinto rule IDs, instead of going through the dedicated,
/// best-effort `actionlint_config` parameter that actually handles them (see
/// `actionlint_config.mbt`, #50) — `karinto_config` itself still does not
/// read `paths:`.

///|
priv struct KarintoConfig {
  // `None` = not configured (default — `check_unknown_runner_label` keeps
  // its historical skip-when-self-hosted behaviour), `Some([])` = configured
  // with no extra labels (validate strictly: only the known built-in labels
  // pass), `Some([...])` = validate against the known set plus these globs.
  // Distinguishing `Some([])` from `None` matters: an author who writes
  // `labels: []` is opting into strict checking, not opting out of it.
  self_hosted_runner_labels : Array[String]?
  // `None` = disabled (default — matches actionlint's own default), `Some([])`
  // = forbid every `vars.*` reference, `Some([...])` = allow only those names.
  config_variables : Array[String]?
  rule_severity : Map[String, Severity]
  ignore_paths : Array[(String, Array[String])]
}

///|
fn empty_karinto_config() -> KarintoConfig {
  KarintoConfig::{
    self_hosted_runner_labels: None,
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
/// Trims ` \t\r\n` rather than just ` \t`, so a value written as a YAML
/// block scalar (`severity: |\n  error\n`, which keeps its trailing
/// newline) still matches instead of silently falling through to `None`.
fn parse_severity_string(s : String) -> Severity? {
  match s.trim(chars=" \t\r\n").to_owned().to_lower() {
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
/// lint, matching `parse_ghalint_excludes` / `parse_zizmor_config`. Only the
/// first YAML document is read (unlike `parse_zizmor_config`, which scans
/// every document for its zizmor-shaped `rules:`): a multi-document
/// `karinto.yaml` is not a realistic authoring pattern for this format, so
/// later documents are ignored rather than merged.
fn parse_karinto_config(config : String) -> KarintoConfig {
  let empty = empty_karinto_config()
  let parsed = try? @yaml.Yaml::load_from_string(config)
  guard parsed is Ok(docs) else { return empty }
  guard docs.length() > 0 else { return empty }
  guard docs[0] is Map(top) else { return empty }
  let self_hosted_runner_labels = match top.get("self-hosted-runner") {
    Some(Map(sm)) =>
      match sm.get("labels") {
        Some(Array(items)) => Some(yaml_string_array(items))
        _ => None
      }
    _ => None
  }
  let config_variables = match top.get("config-variables") {
    Some(Array(items)) => Some(yaml_string_array(items))
    _ => None
  }
  // `rules.<id>` accepts either a bare severity string (`error`/`warning`/
  // `info`), or a map with a `severity` key — the latter shape is identical
  // to zizmor's own `rules.<id>: {disable, ignore}` object, so a zizmor.yml
  // pasted into this same `rules:` section keeps working (its `disable` /
  // `ignore` keys are read separately, by `parse_zizmor_config` against this
  // same text — see `lint()`) and can also carry a `severity` override.
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
          Map(rm2) =>
            match rm2.get("severity") {
              Some(String(s)) =>
                match parse_severity_string(s) {
                  Some(sev) => rule_severity[rule_id] = sev
                  None => ()
                }
              _ => ()
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
/// Splits `s` on `/`, dropping empty segments — so a leading/trailing/
/// doubled slash doesn't introduce phantom empty path components.
fn split_path_segments(s : String) -> Array[String] {
  let out : Array[String] = []
  for seg in s.split("/") {
    let seg = seg.to_owned()
    if seg != "" {
      out.push(seg)
    }
  }
  out
}

///|
/// Path-glob match, gitignore-style: `*` matches within a single path
/// segment (never crosses `/`), `**` matches zero or more whole segments,
/// `?` matches one character. Deliberately distinct from `glob_match`
/// (shared with rule-ID / runner-label matching, where there is no `/` to
/// reason about and a bare `*` is expected to match anything): a
/// segment-blind `*` would let `.github/*` match a nested
/// `.github/workflows/ci.yml`, and a literal-slash `**/*.yml` would fail to
/// match a root-level `ci.yml`.
///
/// `ignore-paths` globs come from the untrusted `karinto_config` text (the
/// Worker's `config` parameter), so — same reasoning as `glob_match`'s own
/// non-backtracking two-pointer design, noted on its doc comment — matching
/// must stay polynomial however many `**` segments a pattern repeats. A
/// `**` state is resolved by the standard two-way wildcard-matching
/// recurrence (`go(pi + 1, si) || go(pi, si + 1)`: either stop here and
/// match zero segments, or consume one more segment and stay on `**`)
/// rather than trying every split point — trying every split point is
/// still memo-safe (no combinatorial blowup) but costs `O(path_segments)`
/// per `**` state, degrading the overall bound to
/// `O(pattern_segments * path_segments²)` for patterns with many `**`
/// segments. The two-way recurrence keeps every state O(1) after
/// memoization, bounding the whole match to
/// `O(pattern_segments * path_segments)`.
///
/// That bound is still a function of the (untrusted) pattern's own segment
/// count, and this runs once per `(diagnostic, ignore-paths entry)` pair —
/// so a pattern packed with thousands of tiny segments (e.g. `a/` repeated
/// to fill the 64 KiB `config` cap) would still allocate a memo table sized
/// to match, repeatedly. `max_path_glob_segments` caps both the pattern and
/// the path at a generous depth no real repository path approaches, and
/// fails closed (no match, no allocation) past it — a pattern this deep is
/// never going to usefully identify a real file anyway.
fn max_path_glob_segments() -> Int {
  64
}

///|
fn path_glob_match(pattern : String, path : String) -> Bool {
  let pat = split_path_segments(pattern)
  let seg = split_path_segments(path)
  let pn = pat.length()
  let sn = seg.length()
  let cap = max_path_glob_segments()
  if pn > cap || sn > cap {
    return false
  }
  // -1 = not yet computed, 0 = false, 1 = true.
  let memo : Array[Int] = Array::make((pn + 1) * (sn + 1), -1)
  fn go(pi : Int, si : Int) -> Bool {
    let idx = pi * (sn + 1) + si
    if memo[idx] != -1 {
      return memo[idx] == 1
    }
    let result = if pi == pn {
      si == sn
    } else if pat[pi] == "**" {
      // Zero segments (drop `**`, move to the next pattern segment here),
      // or one more segment consumed by this same `**`.
      go(pi + 1, si) || (si < sn && go(pi, si + 1))
    } else if si == sn {
      false
    } else if !glob_match(pat[pi], seg[si]) {
      false
    } else {
      go(pi + 1, si + 1)
    }
    memo[idx] = if result { 1 } else { 0 }
    result
  }

  go(0, 0)
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
    if !path_glob_match(strip_dot_slash(glob), f) {
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
