///|
/// Rule definitions and the rule registry.
///
/// Each rule has a stable ID prefixed with the original linter family:
///   - `act-*`  → inspired by actionlint
///   - `ziz-*`  → inspired by zizmor
///   - `ghl-*`  → inspired by ghalint
///   - `cl-*`   → curllint-only
///
/// Only a handful of high-priority rules are implemented for the MVP; the rest
/// are listed for testing purposes with skipped fixtures.

///|
pub(all) struct Rule {
  id : String
  title : String
  applies : (FileKind) -> Bool
  check : (@yaml.Yaml, Array[Diagnostic]) -> Unit
}

///|
fn workflow_only(kind : FileKind) -> Bool {
  kind == FileKind::Workflow
}

///|
/// Registry of currently-implemented rules.
pub fn all_rules() -> Array[Rule] {
  [
    Rule::{
      id: "act-id-unique",
      title: "Job and step IDs must be unique",
      applies: workflow_only,
      check: check_id_unique,
    },
    Rule::{
      id: "ghl-003",
      title: "Forbid `permissions: write-all`",
      applies: workflow_only,
      check: check_write_all_permission,
    },
    Rule::{
      id: "ghl-001",
      title: "Jobs must declare `permissions`",
      applies: workflow_only,
      check: check_job_permissions,
    },
  ]
}

///|
fn add_diag(
  out : Array[Diagnostic],
  rule : String,
  severity : Severity,
  message : String,
) -> Unit {
  out.push(Diagnostic::{ rule, severity, message, pos: None })
}

// ---------------------------------------------------------------------------
// Rule: act-id-unique
// ---------------------------------------------------------------------------

///|
fn check_id_unique(doc : @yaml.Yaml, out : Array[Diagnostic]) -> Unit {
  match doc {
    Map(m) =>
      match m.get("jobs") {
        Some(Map(jobs)) => {
          let lowered : Map[String, String] = {}
          jobs.each(fn(name, body) {
            let lower = name.to_lower()
            match lowered.get(lower) {
              Some(prev) =>
                add_diag(
                  out,
                  "act-id-unique",
                  Error,
                  "duplicate job ID `\{name}` (conflicts with `\{prev}` case-insensitively)",
                )
              None => lowered[lower] = name
            }
            match body {
              Map(jm) => check_steps_id_unique(jm, out)
              _ => ()
            }
          })
        }
        _ => ()
      }
    _ => ()
  }
}

///|
fn check_steps_id_unique(
  job : Map[String, @yaml.Yaml],
  out : Array[Diagnostic],
) -> Unit {
  match job.get("steps") {
    Some(Array(steps)) => {
      let seen : Map[String, String] = {}
      for step in steps {
        match step {
          Map(sm) =>
            match sm.get("id") {
              Some(String(id)) => {
                let lower = id.to_lower()
                match seen.get(lower) {
                  Some(prev) =>
                    add_diag(
                      out,
                      "act-id-unique",
                      Error,
                      "duplicate step ID `\{id}` (conflicts with `\{prev}` case-insensitively)",
                    )
                  None => seen[lower] = id
                }
              }
              _ => ()
            }
          _ => ()
        }
      }
    }
    _ => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: ghl-003 deny_write_all_permission
// ---------------------------------------------------------------------------

///|
fn check_write_all_permission(
  doc : @yaml.Yaml,
  out : Array[Diagnostic],
) -> Unit {
  match doc {
    Map(m) => {
      check_perm_string(m.get("permissions"), "workflow", out)
      match m.get("jobs") {
        Some(Map(jobs)) =>
          jobs.each(fn(name, body) {
            match body {
              Map(jm) =>
                check_perm_string(jm.get("permissions"), "job `\{name}`", out)
              _ => ()
            }
          })
        _ => ()
      }
    }
    _ => ()
  }
}

///|
fn check_perm_string(
  value : @yaml.Yaml?,
  location : String,
  out : Array[Diagnostic],
) -> Unit {
  match value {
    Some(String("write-all")) =>
      add_diag(
        out,
        "ghl-003",
        Error,
        "\{location}: `permissions: write-all` is forbidden",
      )
    _ => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: ghl-001 job_permissions_required
// ---------------------------------------------------------------------------

///|
fn check_job_permissions(doc : @yaml.Yaml, out : Array[Diagnostic]) -> Unit {
  match doc {
    Map(m) => {
      let workflow_has_perm = m.contains("permissions")
      match m.get("jobs") {
        Some(Map(jobs)) =>
          jobs.each(fn(name, body) {
            match body {
              Map(jm) =>
                if !jm.contains("permissions") && !workflow_has_perm {
                  add_diag(
                    out,
                    "ghl-001",
                    Warning,
                    "job `\{name}` does not declare `permissions:`",
                  )
                }
              _ => ()
            }
          })
        _ => ()
      }
    }
    _ => ()
  }
}
