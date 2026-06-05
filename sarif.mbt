///|
/// SARIF 2.1.0 export — maps lint results onto the Static Analysis Results
/// Interchange Format so findings can be uploaded to GitHub Code Scanning
/// (`github/codeql-action/upload-sarif`) and other SARIF consumers (#33).
///
/// Mapping:
///   - `Diagnostic::rule`     → `result.ruleId`, plus a `tool.driver.rules[]`
///     entry carrying the catalogue's title, default severity, and upstream
///     origins (`rules_catalog.mbt`).
///   - `Diagnostic::severity` → `result.level` (`error` / `warning`; `Info`
///     becomes SARIF's `note`).
///   - `Diagnostic::message`  → `result.message.text`.
///   - `Diagnostic::pos`      → `physicalLocation.region` start line/column.
///   - `Diagnostic::job/step` → `locations[].logicalLocations[]`.
///   - YAML parse errors      → one result per failed file under a synthetic
///     `parse-error` rule (not a catalogue rule — it models the engine
///     refusing the input, mirroring actionlint's `syntax-check`).
///   - Unreadable inputs      → `invocations[].toolExecutionNotifications`
///     (SARIF results describe findings *in* artifacts; a missing artifact
///     is an execution-level notification instead).
///
/// `physicalLocation` requires an artifact URI, so it is only emitted for
/// entries that carry a `path`. Pathless inputs (stdin, the Worker's
/// `content` parameter without a `path` label) keep logical locations only.

///|
/// The OASIS-published errata01 schema URL — the canonical stable host.
/// (The raw.githubusercontent.com/oasis-tcs/sarif-spec URL many tools used
/// to ship 404s since the repo was restructured.)
const SARIF_SCHEMA = "https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/schemas/sarif-schema-2.1.0.json"

///|
const SARIF_INFORMATION_URI = "https://github.com/toiroakr/karinto"

///|
const SARIF_HELP_URI = "https://github.com/toiroakr/karinto/blob/main/rules_catalog.md"

///|
const PARSE_ERROR_RULE_ID = "parse-error"

///|
/// One linted input of a SARIF report: the artifact's path (a relative URI;
/// `None` for stdin / anonymous content) and its lint result.
pub(all) struct SarifEntry {
  path : String?
  result : LintResult
}

///|
/// An input that could not be read at all (CLI file IO error, Worker
/// repo-mode fetch failure). Surfaces as a tool execution notification.
pub(all) struct SarifIoError {
  path : String
  message : String
}

///|
/// Build a complete SARIF 2.1.0 document (single run) from lint results.
/// `tool.driver.rules[]` lists only the rules that actually fired, in
/// first-seen order, so `ruleIndex` on each result stays cheap to resolve.
pub fn sarif_report(
  entries : Array[SarifEntry],
  io_errors? : Array[SarifIoError] = [],
  version? : String = ENGINE_VERSION,
) -> Json {
  // Rules referenced by the results, in first-seen order.
  let rule_ids : Array[String] = []
  let rule_index : Map[String, Int] = {}
  for e in entries {
    if e.result.parse_error is Some(_) &&
      !rule_index.contains(PARSE_ERROR_RULE_ID) {
      rule_index[PARSE_ERROR_RULE_ID] = rule_ids.length()
      rule_ids.push(PARSE_ERROR_RULE_ID)
    }
    for d in e.result.diagnostics {
      if !rule_index.contains(d.rule) {
        rule_index[d.rule] = rule_ids.length()
        rule_ids.push(d.rule)
      }
    }
  }
  let rules : Array[Json] = []
  for id in rule_ids {
    rules.push(sarif_rule(id))
  }
  let results : Array[Json] = []
  for e in entries {
    match e.result.parse_error {
      Some(msg) =>
        results.push(sarif_parse_error_result(e.path, msg, rule_index))
      None => ()
    }
    for d in e.result.diagnostics {
      results.push(sarif_result(d, e.path, rule_index))
    }
  }
  let driver : Map[String, Json] = {
    "name": "karinto".to_json(),
    "version": version.to_json(),
    "informationUri": SARIF_INFORMATION_URI.to_json(),
    "rules": rules.to_json(),
  }
  let tool : Map[String, Json] = { "driver": driver.to_json() }
  let run : Map[String, Json] = {
    "tool": tool.to_json(),
    // Positions come from MoonBit strings, which index UTF-16 code units —
    // also SARIF's (and GitHub's) default interpretation. Stated explicitly.
    "columnKind": "utf16CodeUnits".to_json(),
  }
  if io_errors.length() > 0 {
    let notifications : Array[Json] = []
    for err in io_errors {
      notifications.push(sarif_io_notification(err))
    }
    let invocation : Map[String, Json] = {
      "executionSuccessful": false.to_json(),
      "toolExecutionNotifications": notifications.to_json(),
    }
    let invocations : Array[Json] = [invocation.to_json()]
    run["invocations"] = invocations.to_json()
  }
  run["results"] = results.to_json()
  let runs : Array[Json] = [run.to_json()]
  let doc : Map[String, Json] = {
    "$schema": SARIF_SCHEMA.to_json(),
    "version": "2.1.0".to_json(),
    "runs": runs.to_json(),
  }
  doc.to_json()
}

///|
/// `Severity` → SARIF `level`. Distinct from `Severity::to_json` (the JSON
/// envelope's strings): SARIF spells the lowest level `note`, not `info`.
fn sarif_level(s : Severity) -> String {
  match s {
    Error => "error"
    Warning => "warning"
    Info => "note"
  }
}

///|
fn sarif_category(c : Category) -> String {
  match c {
    Syntax => "syntax"
    Expression => "expression"
    Security => "security"
    SupplyChain => "supply-chain"
    Performance => "performance"
    BestPractice => "best-practice"
    Config => "config"
    External => "external"
  }
}

///|
/// Non-panicking catalogue lookup (`rule_spec` aborts on a miss, which would
/// turn an uncatalogued rule id into a runtime crash mid-serialization).
fn find_rule_spec(id : String) -> RuleSpec? {
  for s in all_rule_specs() {
    if s.id == id {
      return Some(s)
    }
  }
  None
}

///|
fn sarif_rule(id : String) -> Json {
  if id == PARSE_ERROR_RULE_ID {
    // Synthetic rule: parse failures aren't catalogued in rules_catalog.mbt.
    let short : Map[String, Json] = { "text": "YAML parse error".to_json() }
    let cfg : Map[String, Json] = { "level": "error".to_json() }
    let m : Map[String, Json] = {
      "id": id.to_json(),
      "shortDescription": short.to_json(),
      "defaultConfiguration": cfg.to_json(),
    }
    return m.to_json()
  }
  match find_rule_spec(id) {
    Some(spec) => {
      let short : Map[String, Json] = { "text": spec.title.to_json() }
      let cfg : Map[String, Json] = {
        "level": sarif_level(spec.default_severity).to_json(),
      }
      let origins : Array[Json] = []
      for o in spec.origins {
        origins.push(o.to_json())
      }
      let props : Map[String, Json] = {
        "category": sarif_category(spec.category).to_json(),
        "origins": origins.to_json(),
      }
      let m : Map[String, Json] = {
        "id": id.to_json(),
        "shortDescription": short.to_json(),
        "defaultConfiguration": cfg.to_json(),
        "helpUri": SARIF_HELP_URI.to_json(),
        "properties": props.to_json(),
      }
      m.to_json()
    }
    // Defensive: coverage_test.mbt guarantees every emitted rule id is
    // catalogued, but an uncatalogued id still yields a minimal valid entry.
    None => {
      let m : Map[String, Json] = { "id": id.to_json() }
      m.to_json()
    }
  }
}

///|
fn sarif_result(
  d : Diagnostic,
  path : String?,
  rule_index : Map[String, Int],
) -> Json {
  let msg : Map[String, Json] = { "text": d.message.to_json() }
  let m : Map[String, Json] = { "ruleId": d.rule.to_json() }
  match rule_index.get(d.rule) {
    Some(i) => m["ruleIndex"] = i.to_json()
    None => ()
  }
  m["level"] = sarif_level(d.severity).to_json()
  m["message"] = msg.to_json()
  match sarif_location(path, d.pos, d.job, d.step) {
    Some(loc) => {
      let locs : Array[Json] = [loc]
      m["locations"] = locs.to_json()
    }
    None => ()
  }
  m.to_json()
}

///|
/// A result's single location: `physicalLocation` when the artifact has a
/// path (region only when the diagnostic carries a position — an
/// artifact-only location means "the whole file"), `logicalLocations` for
/// the owning job / step. `None` when there is nothing to point at.
fn sarif_location(
  path : String?,
  pos : Position?,
  job : String?,
  step : StepRef?,
) -> Json? {
  let loc : Map[String, Json] = {}
  match path {
    Some(p) => {
      // Plain relative URI, no `uriBaseId`: a base-id reference is only
      // meaningful with a matching `originalUriBaseIds` entry, and GitHub
      // Code Scanning resolves relative URIs against the repository root.
      let artifact : Map[String, Json] = { "uri": p.to_json() }
      let phys : Map[String, Json] = { "artifactLocation": artifact.to_json() }
      match pos {
        Some(pp) => {
          let region : Map[String, Json] = {
            "startLine": pp.line.to_json(),
            "startColumn": pp.col.to_json(),
          }
          phys["region"] = region.to_json()
        }
        None => ()
      }
      loc["physicalLocation"] = phys.to_json()
    }
    None => ()
  }
  let logicals : Array[Json] = []
  match job {
    Some(j) => {
      let l : Map[String, Json] = {
        "name": j.to_json(),
        "kind": "job".to_json(),
      }
      logicals.push(l.to_json())
    }
    None => ()
  }
  match step {
    Some(s) => {
      let name = match s.id {
        Some(id) => id
        None => "steps[\{s.index}]"
      }
      let fq = match job {
        Some(j) => "\{j}/steps[\{s.index}]"
        None => "steps[\{s.index}]"
      }
      let l : Map[String, Json] = {
        "name": name.to_json(),
        "fullyQualifiedName": fq.to_json(),
        "kind": "step".to_json(),
      }
      logicals.push(l.to_json())
    }
    None => ()
  }
  if logicals.length() > 0 {
    loc["logicalLocations"] = logicals.to_json()
  }
  if loc.length() == 0 {
    return None
  }
  Some(loc.to_json())
}

///|
fn sarif_parse_error_result(
  path : String?,
  message : String,
  rule_index : Map[String, Int],
) -> Json {
  let msg : Map[String, Json] = { "text": message.to_json() }
  let m : Map[String, Json] = { "ruleId": PARSE_ERROR_RULE_ID.to_json() }
  match rule_index.get(PARSE_ERROR_RULE_ID) {
    Some(i) => m["ruleIndex"] = i.to_json()
    None => ()
  }
  m["level"] = "error".to_json()
  m["message"] = msg.to_json()
  match path {
    Some(p) => {
      let artifact : Map[String, Json] = { "uri": p.to_json() }
      let phys : Map[String, Json] = { "artifactLocation": artifact.to_json() }
      let loc : Map[String, Json] = { "physicalLocation": phys.to_json() }
      let locs : Array[Json] = [loc.to_json()]
      m["locations"] = locs.to_json()
    }
    None => ()
  }
  m.to_json()
}

///|
fn sarif_io_notification(err : SarifIoError) -> Json {
  let msg : Map[String, Json] = { "text": err.message.to_json() }
  let artifact : Map[String, Json] = { "uri": err.path.to_json() }
  let phys : Map[String, Json] = { "artifactLocation": artifact.to_json() }
  let loc : Map[String, Json] = { "physicalLocation": phys.to_json() }
  let locs : Array[Json] = [loc.to_json()]
  let m : Map[String, Json] = {
    "level": "error".to_json(),
    "message": msg.to_json(),
    "locations": locs.to_json(),
  }
  m.to_json()
}
