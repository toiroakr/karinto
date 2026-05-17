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
/// Per-step view with hot fields pre-extracted so rules don't repeat
/// `m.get("uses")` / `String.has_prefix(...)` for each rule.
pub(all) struct StepInfo {
  raw : Map[String, @yaml.Yaml]
  uses : String?
  run : String?
  if_cond : String?
  with_ : Map[String, @yaml.Yaml]?
  // semantic flags pre-computed during prewalk
  is_actions_checkout : Bool
  is_upload_artifact : Bool
  is_pypi_publish : Bool
  is_local_or_docker : Bool
  has_persist_creds_false : Bool
  at_idx : Int // -1 if no `@`
  has_full_sha : Bool
}

///|
pub(all) struct JobInfo {
  name : String
  raw : Map[String, @yaml.Yaml]
  if_cond : String?
  uses : String?
  has_permissions : Bool
  has_timeout : Bool
  steps : Array[StepInfo]
}

///|
/// Pre-extracted view of a YAML doc — built once in `prewalk` and
/// passed to every rule.
pub(all) struct WalkCtx {
  doc : @yaml.Yaml
  workflow_map : Map[String, @yaml.Yaml]?
  workflow_has_permissions : Bool
  jobs : Array[JobInfo]
  workflow_steps : Array[StepInfo]
  action_steps : Array[StepInfo]
  updates : Array[Map[String, @yaml.Yaml]]
}

///|
fn build_step_info(sm : Map[String, @yaml.Yaml]) -> StepInfo {
  let uses = get_string_field(sm, "uses")
  let run = get_string_field(sm, "run")
  let if_cond = get_string_field(sm, "if")
  let with_ : Map[String, @yaml.Yaml]? = match sm.get("with") {
    Some(Map(w)) => Some(w)
    _ => None
  }
  let mut is_actions_checkout = false
  let mut is_upload_artifact = false
  let mut is_pypi_publish = false
  let mut is_local_or_docker = false
  let mut at_idx = -1
  let mut has_full_sha = false
  match uses {
    Some(u) => {
      if u.has_prefix("./") || u.has_prefix("docker://") {
        is_local_or_docker = true
      } else if u.has_prefix("actions/checkout@") {
        is_actions_checkout = true
      } else if u.has_prefix("actions/upload-artifact@") {
        is_upload_artifact = true
      } else if u.has_prefix("pypa/gh-action-pypi-publish@") {
        is_pypi_publish = true
      }
      at_idx = last_at_index(u)
      if at_idx >= 0 {
        has_full_sha = is_full_sha_after(u, at_idx)
      }
    }
    None => ()
  }
  let has_persist_creds_false = match with_ {
    Some(w) =>
      match get_bool_field(w, "persist-credentials") {
        Some(false) => true
        _ => false
      }
    None => false
  }
  StepInfo::{
    raw: sm,
    uses,
    run,
    if_cond,
    with_,
    is_actions_checkout,
    is_upload_artifact,
    is_pypi_publish,
    is_local_or_docker,
    has_persist_creds_false,
    at_idx,
    has_full_sha,
  }
}

///|
fn build_steps(arr : Array[@yaml.Yaml]) -> Array[StepInfo] {
  let out : Array[StepInfo] = []
  for step in arr {
    match step {
      Map(sm) => out.push(build_step_info(sm))
      _ => ()
    }
  }
  out
}

///|
pub fn prewalk(doc : @yaml.Yaml) -> WalkCtx {
  let jobs : Array[JobInfo] = []
  let workflow_steps : Array[StepInfo] = []
  let action_steps : Array[StepInfo] = []
  let updates : Array[Map[String, @yaml.Yaml]] = []
  let workflow_map : Map[String, @yaml.Yaml]? = match doc {
    Map(m) => Some(m)
    _ => None
  }
  match workflow_map {
    Some(m) => {
      match m.get("jobs") {
        Some(Map(jm)) =>
          jm.each(fn(name, body) {
            match body {
              Map(jb) => {
                let steps : Array[StepInfo] = match jb.get("steps") {
                  Some(Array(arr)) => build_steps(arr)
                  _ => []
                }
                for s in steps {
                  workflow_steps.push(s)
                }
                let job = JobInfo::{
                  name,
                  raw: jb,
                  if_cond: get_string_field(jb, "if"),
                  uses: get_string_field(jb, "uses"),
                  has_permissions: jb.contains("permissions"),
                  has_timeout: jb.contains("timeout-minutes"),
                  steps,
                }
                jobs.push(job)
              }
              _ => ()
            }
          })
        _ => ()
      }
      match m.get("runs") {
        Some(Map(runs)) =>
          match runs.get("steps") {
            Some(Array(arr)) =>
              for s in build_steps(arr) {
                action_steps.push(s)
              }
            _ => ()
          }
        _ => ()
      }
      match m.get("updates") {
        Some(Array(arr)) =>
          for u in arr {
            match u {
              Map(um) => updates.push(um)
              _ => ()
            }
          }
        _ => ()
      }
    }
    None => ()
  }
  let workflow_has_permissions = match workflow_map {
    Some(m) => m.contains("permissions")
    None => false
  }
  WalkCtx::{
    doc,
    workflow_map,
    workflow_has_permissions,
    jobs,
    workflow_steps,
    action_steps,
    updates,
  }
}

///|
/// A rule may register zero or more scoped callbacks. `run_rules` walks the
/// pre-parsed doc once and dispatches every active rule at each scope.
pub(all) struct Rule {
  id : String
  title : String
  applies : (FileKind) -> Bool
  on_doc : ((WalkCtx, Array[Diagnostic]) -> Unit)?
  on_job : ((WalkCtx, JobInfo, Array[Diagnostic]) -> Unit)?
  on_step : ((WalkCtx, StepInfo, Array[Diagnostic]) -> Unit)?
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
fn no_doc() -> ((WalkCtx, Array[Diagnostic]) -> Unit)? {
  None
}

///|
fn no_job() -> ((WalkCtx, JobInfo, Array[Diagnostic]) -> Unit)? {
  None
}

///|
fn no_step() -> ((WalkCtx, StepInfo, Array[Diagnostic]) -> Unit)? {
  None
}

///|
/// Registry of currently-implemented rules.
pub fn all_rules() -> Array[Rule] {
  [
    Rule::{
      id: "duplicate-job-step-ids",
      title: "Job and step IDs must be unique",
      applies: workflow_only,
      on_doc: Some(check_id_unique),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "permissions-write-all-forbidden",
      title: "Forbid `permissions: write-all`",
      applies: workflow_only,
      on_doc: Some(check_write_all_workflow),
      on_job: Some(check_write_all_job),
      on_step: no_step(),
    },
    Rule::{
      id: "job-permissions-required",
      title: "Jobs must declare `permissions`",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: Some(check_job_permissions),
      on_step: no_step(),
    },
    Rule::{
      id: "job-timeout-minutes-required",
      title: "Jobs must declare `timeout-minutes`",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: Some(check_job_timeout),
      on_step: no_step(),
    },
    Rule::{
      id: "checkout-persist-credentials-false",
      title: "actions/checkout must set `persist-credentials: false`",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: no_job(),
      on_step: Some(check_checkout_persist_credentials),
    },
    Rule::{
      id: "unpinned-uses",
      title: "uses must pin to a full-length SHA",
      applies: workflow_or_action,
      on_doc: no_doc(),
      on_job: no_job(),
      on_step: Some(check_unpinned_uses),
    },
    Rule::{
      id: "artipacked",
      title: "Checkout-then-upload-artifact leaks credentials",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: Some(check_artipacked),
      on_step: no_step(),
    },
    Rule::{
      id: "bot-conditions",
      title: "Spoofable `github.actor` bot check",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: Some(check_bot_conditions),
      on_step: no_step(),
    },
    Rule::{
      id: "excessive-permissions",
      title: "Job grants many `write` permissions",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: Some(check_excessive_permissions),
      on_step: no_step(),
    },
    Rule::{
      id: "use-trusted-publishing",
      title: "Prefer OIDC trusted publishing over long-lived tokens",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: no_job(),
      on_step: Some(check_trusted_publishing),
    },
    Rule::{
      id: "dependabot-cooldown",
      title: "Dependabot updates should configure `cooldown`",
      applies: unknown_only,
      on_doc: Some(check_dependabot_cooldown),
      on_job: no_job(),
      on_step: no_step(),
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
fn check_id_unique(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  let lowered : Map[String, String] = {}
  for j in ctx.jobs {
    let name = j.name
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
    check_steps_id_unique_pre(j.steps, out)
  }
}

///|
fn check_steps_id_unique_pre(
  steps : Array[StepInfo],
  out : Array[Diagnostic],
) -> Unit {
  let seen : Map[String, String] = {}
  for s in steps {
    match s.raw.get("id") {
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
  }
}



// ---------------------------------------------------------------------------
// Rule: permissions-write-all-forbidden deny_write_all_permission
// ---------------------------------------------------------------------------

///|
fn check_write_all_workflow(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  match ctx.workflow_map {
    Some(m) => check_perm_string(m.get("permissions"), "workflow", out)
    None => ()
  }
}

///|
fn check_write_all_job(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  check_perm_string(job.raw.get("permissions"), "job `\{job.name}`", out)
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
fn check_job_permissions(
  ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  if !job.has_permissions && !ctx.workflow_has_permissions {
    add_diag(
      out,
      "job-permissions-required",
      Warning,
      "job `\{job.name}` does not declare `permissions:`",
    )
  }
}

// ---------------------------------------------------------------------------
// Helpers shared by the new ghalint/zizmor rules.
// ---------------------------------------------------------------------------

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
fn check_job_timeout(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  // Reusable workflow calls (`uses:` at job level) don't take timeout-minutes.
  match job.uses {
    Some(_) => return
    None => ()
  }
  if !job.has_timeout {
    add_diag(
      out,
      "job-timeout-minutes-required",
      Warning,
      "job `\{job.name}` does not declare `timeout-minutes:`",
    )
  }
}

// ---------------------------------------------------------------------------
// Rule: checkout-persist-credentials-false (ghalint ghl-013)
// ---------------------------------------------------------------------------

///|
fn check_checkout_persist_credentials(
  _ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  if step.is_actions_checkout && !step.has_persist_creds_false {
    add_diag(
      out,
      "checkout-persist-credentials-false",
      Error,
      "actions/checkout requires `persist-credentials: false` to avoid token leakage",
    )
  }
}

// ---------------------------------------------------------------------------
// Rule: unpinned-uses (zizmor + ghalint ghl-008)
// ---------------------------------------------------------------------------

///|
fn check_unpinned_uses(
  _ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  match step.uses {
    Some(u) =>
      if !step.is_local_or_docker && step.at_idx >= 0 && !step.has_full_sha {
        add_diag(
          out,
          "unpinned-uses",
          Warning,
          "uses `\{u}` is not pinned to a full-length SHA",
        )
      }
    None => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: artipacked (zizmor)
// ---------------------------------------------------------------------------

///|
fn check_artipacked(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  let mut checkout_unsafe = false
  for s in job.steps {
    if s.is_actions_checkout {
      if !s.has_persist_creds_false {
        checkout_unsafe = true
      }
    } else if checkout_unsafe && s.is_upload_artifact {
      add_diag(
        out,
        "artipacked",
        Error,
        "checkout persists credentials before upload-artifact; set `persist-credentials: false`",
      )
      return
    }
  }
}

// ---------------------------------------------------------------------------
// Rule: bot-conditions (zizmor)
// ---------------------------------------------------------------------------

///|
fn looks_spoofable_bot(s : String) -> Bool {
  s.contains("github.actor") && s.contains("[bot]")
}

///|
fn check_bot_conditions(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  match job.if_cond {
    Some(s) =>
      if looks_spoofable_bot(s) {
        add_diag(
          out,
          "bot-conditions",
          Error,
          "`github.actor` is spoofable; use `github.event.pull_request.user.login` and verify",
        )
        return
      }
    None => ()
  }
  for s in job.steps {
    match s.if_cond {
      Some(c) =>
        if looks_spoofable_bot(c) {
          add_diag(
            out,
            "bot-conditions",
            Error,
            "`github.actor` is spoofable; use `github.event.pull_request.user.login` and verify",
          )
          return
        }
      None => ()
    }
  }
}

// ---------------------------------------------------------------------------
// Rule: excessive-permissions (zizmor) — flags ≥ 3 `write` scopes per job
// ---------------------------------------------------------------------------

///|
fn check_excessive_permissions(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  match job.raw.get("permissions") {
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
          "job `\{job.name}` grants \{writes} write permissions; consider narrowing the scope",
        )
      }
    }
    _ => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: use-trusted-publishing (zizmor) — heuristic
// ---------------------------------------------------------------------------

///|
fn check_trusted_publishing(
  _ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  if step.is_pypi_publish {
    let has_password = match step.with_ {
      Some(w) => w.contains("password")
      None => false
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
  match step.run {
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
}

// ---------------------------------------------------------------------------
// Rule: dependabot-cooldown (zizmor) — applies to dependabot.yaml
// ---------------------------------------------------------------------------

///|
fn check_dependabot_cooldown(
  ctx : WalkCtx,
  out : Array[Diagnostic],
) -> Unit {
  for um in ctx.updates {
    if !um.contains("cooldown") {
      add_diag(
        out,
        "dependabot-cooldown",
        Info,
        "dependabot update has no `cooldown:` configured",
      )
    }
  }
}
