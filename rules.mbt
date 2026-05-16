///|
/// Rule definitions and the rule registry.
///
/// Rule IDs are topic-only kebab-case (no source prefix). Each catalogue
/// entry records the upstream identifier(s) it derives from in its
/// `origins` field — see `rules_catalog.mbt`. Cross-linter consolidations
/// list every absorbed upstream there.
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
fn workflow_or_action(kind : FileKind) -> Bool {
  kind == FileKind::Workflow || kind == FileKind::Action
}

///|
fn unknown_only(kind : FileKind) -> Bool {
  kind == FileKind::Unknown
}

///|
/// Registry of currently-implemented rules.
pub fn all_rules() -> Array[Rule] {
  [
    Rule::{
      id: "duplicate-job-step-ids",
      title: "Job and step IDs must be unique",
      applies: workflow_only,
      check: check_id_unique,
    },
    Rule::{
      id: "permissions-write-all-forbidden",
      title: "Forbid `permissions: write-all`",
      applies: workflow_only,
      check: check_write_all_permission,
    },
    Rule::{
      id: "job-permissions-required",
      title: "Jobs must declare `permissions`",
      applies: workflow_only,
      check: check_job_permissions,
    },
    Rule::{
      id: "job-timeout-minutes-required",
      title: "Jobs must declare `timeout-minutes`",
      applies: workflow_only,
      check: check_job_timeout,
    },
    Rule::{
      id: "checkout-persist-credentials-false",
      title: "actions/checkout must set `persist-credentials: false`",
      applies: workflow_only,
      check: check_checkout_persist_credentials,
    },
    Rule::{
      id: "unpinned-uses",
      title: "uses must pin to a full-length SHA",
      applies: workflow_or_action,
      check: check_unpinned_uses,
    },
    Rule::{
      id: "artipacked",
      title: "Checkout-then-upload-artifact leaks credentials",
      applies: workflow_only,
      check: check_artipacked,
    },
    Rule::{
      id: "bot-conditions",
      title: "Spoofable `github.actor` bot check",
      applies: workflow_only,
      check: check_bot_conditions,
    },
    Rule::{
      id: "excessive-permissions",
      title: "Job grants many `write` permissions",
      applies: workflow_only,
      check: check_excessive_permissions,
    },
    Rule::{
      id: "use-trusted-publishing",
      title: "Prefer OIDC trusted publishing over long-lived tokens",
      applies: workflow_only,
      check: check_trusted_publishing,
    },
    Rule::{
      id: "dependabot-cooldown",
      title: "Dependabot updates should configure `cooldown`",
      applies: unknown_only,
      check: check_dependabot_cooldown,
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
// Rule: duplicate-job-step-ids (actionlint id-naming family)
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
                  "duplicate-job-step-ids",
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
                      "duplicate-job-step-ids",
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
// Rule: permissions-write-all-forbidden deny_write_all_permission
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
        "permissions-write-all-forbidden",
        Error,
        "\{location}: `permissions: write-all` is forbidden",
      )
    _ => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: job-permissions-required job_permissions_required
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
                    "job-permissions-required",
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

// ---------------------------------------------------------------------------
// Helpers shared by the new ghalint/zizmor rules.
// ---------------------------------------------------------------------------

///|
fn each_job(
  doc : @yaml.Yaml,
  f : (String, Map[String, @yaml.Yaml]) -> Unit,
) -> Unit {
  match doc {
    Map(m) =>
      match m.get("jobs") {
        Some(Map(jobs)) =>
          jobs.each(fn(name, body) {
            match body {
              Map(jm) => f(name, jm)
              _ => ()
            }
          })
        _ => ()
      }
    _ => ()
  }
}

///|
fn each_step(
  job : Map[String, @yaml.Yaml],
  f : (Map[String, @yaml.Yaml]) -> Unit,
) -> Unit {
  match job.get("steps") {
    Some(Array(steps)) =>
      for step in steps {
        match step {
          Map(sm) => f(sm)
          _ => ()
        }
      }
    _ => ()
  }
}

///|
/// Iterate over steps in either workflow (`jobs.<id>.steps`) or
/// composite/JS action (`runs.steps`) shape.
fn each_step_in_doc(
  doc : @yaml.Yaml,
  f : (Map[String, @yaml.Yaml]) -> Unit,
) -> Unit {
  match doc {
    Map(m) => {
      match m.get("jobs") {
        Some(Map(jobs)) =>
          jobs.each(fn(_name, body) {
            match body {
              Map(jm) => each_step(jm, f)
              _ => ()
            }
          })
        _ => ()
      }
      match m.get("runs") {
        Some(Map(runs)) =>
          match runs.get("steps") {
            Some(Array(steps)) =>
              for step in steps {
                match step {
                  Map(sm) => f(sm)
                  _ => ()
                }
              }
            _ => ()
          }
        _ => ()
      }
    }
    _ => ()
  }
}

///|
fn get_string_field(m : Map[String, @yaml.Yaml], key : String) -> String? {
  match m.get(key) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn get_bool_field(m : Map[String, @yaml.Yaml], key : String) -> Bool? {
  match m.get(key) {
    Some(Boolean(b)) => Some(b)
    Some(String("true")) => Some(true)
    Some(String("false")) => Some(false)
    _ => None
  }
}

///|
fn last_at_index(s : String) -> Int {
  let mut at = -1
  let mut i = 0
  let len = s.length()
  while i < len {
    match s.get_char(i) {
      Some('@') => at = i
      _ => ()
    }
    i = i + 1
  }
  at
}

///|
fn is_full_sha_after(s : String, at_idx : Int) -> Bool {
  let len = s.length()
  if len - at_idx - 1 != 40 {
    return false
  }
  let mut i = at_idx + 1
  while i < len {
    match s.get_char(i) {
      Some(c) =>
        if !((c >= '0' && c <= '9') ||
        (c >= 'a' && c <= 'f') ||
        (c >= 'A' && c <= 'F')) {
          return false
        }
      None => return false
    }
    i = i + 1
  }
  true
}

// ---------------------------------------------------------------------------
// Rule: job-timeout-minutes-required (ghalint ghl-012)
// ---------------------------------------------------------------------------

///|
fn check_job_timeout(doc : @yaml.Yaml, out : Array[Diagnostic]) -> Unit {
  each_job(doc, fn(name, jm) {
    // Reusable workflow calls (`uses:` at job level) don't take timeout-minutes.
    if jm.contains("uses") {
      return
    }
    if !jm.contains("timeout-minutes") {
      add_diag(
        out,
        "job-timeout-minutes-required",
        Warning,
        "job `\{name}` does not declare `timeout-minutes:`",
      )
    }
  })
}

// ---------------------------------------------------------------------------
// Rule: checkout-persist-credentials-false (ghalint ghl-013)
// ---------------------------------------------------------------------------

///|
fn check_checkout_persist_credentials(
  doc : @yaml.Yaml,
  out : Array[Diagnostic],
) -> Unit {
  each_job(doc, fn(_name, jm) {
    each_step(jm, fn(sm) {
      match get_string_field(sm, "uses") {
        Some(u) =>
          if u.has_prefix("actions/checkout@") {
            let persist = match sm.get("with") {
              Some(Map(w)) => get_bool_field(w, "persist-credentials")
              _ => None
            }
            match persist {
              Some(false) => () // explicit opt-out, satisfies the policy
              _ =>
                add_diag(
                  out,
                  "checkout-persist-credentials-false",
                  Error,
                  "actions/checkout requires `persist-credentials: false` to avoid token leakage",
                )
            }
          }
        None => ()
      }
    })
  })
}

// ---------------------------------------------------------------------------
// Rule: unpinned-uses (zizmor + ghalint ghl-008)
// ---------------------------------------------------------------------------

///|
fn check_unpinned_uses(doc : @yaml.Yaml, out : Array[Diagnostic]) -> Unit {
  each_step_in_doc(doc, fn(sm) {
    match get_string_field(sm, "uses") {
      Some(u) => {
        // Local actions and docker:// references aren't third-party action refs.
        if u.has_prefix("./") || u.has_prefix("docker://") {
          return
        }
        let at = last_at_index(u)
        if at < 0 {
          return
        }
        if !is_full_sha_after(u, at) {
          add_diag(
            out,
            "unpinned-uses",
            Warning,
            "uses `\{u}` is not pinned to a full-length SHA",
          )
        }
      }
      None => ()
    }
  })
}

// ---------------------------------------------------------------------------
// Rule: artipacked (zizmor)
// ---------------------------------------------------------------------------

///|
fn check_artipacked(doc : @yaml.Yaml, out : Array[Diagnostic]) -> Unit {
  each_job(doc, fn(_name, jm) {
    let mut checkout_unsafe = false
    let mut fired = false
    each_step(jm, fn(sm) {
      if fired {
        return
      }
      match get_string_field(sm, "uses") {
        Some(u) =>
          if u.has_prefix("actions/checkout@") {
            let persist = match sm.get("with") {
              Some(Map(w)) => get_bool_field(w, "persist-credentials")
              _ => None
            }
            match persist {
              Some(false) => ()
              _ => checkout_unsafe = true
            }
          } else if checkout_unsafe && u.has_prefix("actions/upload-artifact@") {
            add_diag(
              out,
              "artipacked",
              Error,
              "checkout persists credentials before upload-artifact; set `persist-credentials: false`",
            )
            fired = true
          }
        None => ()
      }
    })
  })
}

// ---------------------------------------------------------------------------
// Rule: bot-conditions (zizmor)
// ---------------------------------------------------------------------------

///|
fn looks_spoofable_bot(s : String) -> Bool {
  s.contains("github.actor") && s.contains("[bot]")
}

///|
fn check_bot_conditions(doc : @yaml.Yaml, out : Array[Diagnostic]) -> Unit {
  each_job(doc, fn(_name, jm) {
    let mut fired = false
    match get_string_field(jm, "if") {
      Some(s) =>
        if looks_spoofable_bot(s) {
          add_diag(
            out,
            "bot-conditions",
            Error,
            "`github.actor` is spoofable; use `github.event.pull_request.user.login` and verify",
          )
          fired = true
        }
      None => ()
    }
    if fired {
      return
    }
    each_step(jm, fn(sm) {
      if fired {
        return
      }
      match get_string_field(sm, "if") {
        Some(s) =>
          if looks_spoofable_bot(s) {
            add_diag(
              out,
              "bot-conditions",
              Error,
              "`github.actor` is spoofable; use `github.event.pull_request.user.login` and verify",
            )
            fired = true
          }
        None => ()
      }
    })
  })
}

// ---------------------------------------------------------------------------
// Rule: excessive-permissions (zizmor) — flags ≥ 3 `write` scopes per job
// ---------------------------------------------------------------------------

///|
fn check_excessive_permissions(
  doc : @yaml.Yaml,
  out : Array[Diagnostic],
) -> Unit {
  each_job(doc, fn(name, jm) {
    match jm.get("permissions") {
      Some(Map(perms)) => {
        let mut writes = 0
        perms.each(fn(_k, v) {
          match v {
            String("write") => writes = writes + 1
            _ => ()
          }
        })
        if writes >= 3 {
          add_diag(
            out,
            "excessive-permissions",
            Warning,
            "job `\{name}` grants \{writes} write permissions; consider narrowing the scope",
          )
        }
      }
      _ => ()
    }
  })
}

// ---------------------------------------------------------------------------
// Rule: use-trusted-publishing (zizmor) — heuristic
// ---------------------------------------------------------------------------

///|
fn check_trusted_publishing(
  doc : @yaml.Yaml,
  out : Array[Diagnostic],
) -> Unit {
  each_step_in_doc(doc, fn(sm) {
    match get_string_field(sm, "uses") {
      Some(u) =>
        if u.has_prefix("pypa/gh-action-pypi-publish@") {
          let has_password = match sm.get("with") {
            Some(Map(w)) => w.contains("password")
            _ => false
          }
          if has_password {
            add_diag(
              out,
              "use-trusted-publishing",
              Info,
              "PyPI publish uses an API token; prefer OIDC trusted publishing",
            )
          }
        }
      None => ()
    }
    match get_string_field(sm, "run") {
      Some(r) =>
        if r.contains("pkg-pr-new publish") ||
          r.contains("npm publish") ||
          r.contains("pnpm publish") {
          add_diag(
            out,
            "use-trusted-publishing",
            Info,
            "publish command uses a long-lived token; prefer OIDC trusted publishing",
          )
        }
      None => ()
    }
  })
}

// ---------------------------------------------------------------------------
// Rule: dependabot-cooldown (zizmor) — applies to dependabot.yaml
// ---------------------------------------------------------------------------

///|
fn check_dependabot_cooldown(
  doc : @yaml.Yaml,
  out : Array[Diagnostic],
) -> Unit {
  match doc {
    Map(m) =>
      match m.get("updates") {
        Some(Array(updates)) =>
          for u in updates {
            match u {
              Map(um) =>
                if !um.contains("cooldown") {
                  add_diag(
                    out,
                    "dependabot-cooldown",
                    Info,
                    "dependabot update has no `cooldown:` configured",
                  )
                }
              _ => ()
            }
          }
        _ => ()
      }
    _ => ()
  }
}
