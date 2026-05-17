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
  has_shell : Bool
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
  action_is_composite : Bool
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
  let has_shell = sm.contains("shell")
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
    has_shell,
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
  let action_is_composite = match workflow_map {
    Some(m) =>
      match m.get("runs") {
        Some(Map(runs)) => get_string_field(runs, "using") == Some("composite")
        _ => false
      }
    None => false
  }
  WalkCtx::{
    doc,
    workflow_map,
    workflow_has_permissions,
    jobs,
    workflow_steps,
    action_steps,
    action_is_composite,
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
fn action_only(kind : FileKind) -> Bool {
  kind == FileKind::Action
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
      id: "permissions-read-all-forbidden",
      title: "Forbid `permissions: read-all`",
      applies: workflow_only,
      on_doc: Some(check_read_all_workflow),
      on_job: Some(check_read_all_job),
      on_step: no_step(),
    },
    Rule::{
      id: "dangerous-triggers",
      title: "`pull_request_target` / `workflow_run` are privileged events",
      applies: workflow_only,
      on_doc: Some(check_dangerous_triggers),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "unpinned-images",
      title: "Container image is not pinned by digest",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: Some(check_unpinned_images),
      on_step: no_step(),
    },
    Rule::{
      id: "secrets-inherit",
      title: "Reusable workflow uses `secrets: inherit`",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: Some(check_secrets_inherit),
      on_step: no_step(),
    },
    Rule::{
      id: "composite-step-shell-required",
      title: "Composite action `run:` step needs `shell:`",
      applies: action_only,
      on_doc: Some(check_composite_step_shell),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "self-hosted-runner",
      title: "Job runs on a self-hosted runner",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: Some(check_self_hosted_runner),
      on_step: no_step(),
    },
    Rule::{
      id: "insecure-commands",
      title: "`ACTIONS_ALLOW_UNSECURE_COMMANDS` re-enables legacy commands",
      applies: workflow_only,
      on_doc: Some(check_insecure_commands),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "misfeature",
      title: "`continue-on-error: true` masks real failures",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: Some(check_misfeature),
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
    Rule::{
      id: "workflow-env-no-secrets",
      title: "Workflow env must not reference `secrets`",
      applies: workflow_only,
      on_doc: Some(check_workflow_env_no_secrets),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "job-env-no-secrets",
      title: "Job env must not reference `secrets`",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: Some(check_job_env_no_secrets),
      on_step: no_step(),
    },
    Rule::{
      id: "github-app-limit-repositories",
      title: "GitHub App tokens must limit `repositories:`",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: no_job(),
      on_step: Some(check_github_app_limit_repos),
    },
    Rule::{
      id: "github-app-limit-permissions",
      title: "GitHub App tokens must limit `permissions:`",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: no_job(),
      on_step: Some(check_github_app_limit_perms),
    },
    Rule::{
      id: "hardcoded-container-credentials",
      title: "Hardcoded container or service credentials",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: Some(check_hardcoded_container_creds),
      on_step: no_step(),
    },
    Rule::{
      id: "obfuscation",
      title: "Obfuscated uses ref (percent-encoded)",
      applies: workflow_or_action,
      on_doc: no_doc(),
      on_job: no_job(),
      on_step: Some(check_obfuscation),
    },
    Rule::{
      id: "known-vulnerable-actions",
      title: "Action is on the known-compromised list",
      applies: workflow_or_action,
      on_doc: no_doc(),
      on_job: no_job(),
      on_step: Some(check_known_vulnerable_actions),
    },
    Rule::{
      id: "deprecated-workflow-commands",
      title: "Deprecated workflow command in `run:`",
      applies: workflow_or_action,
      on_doc: no_doc(),
      on_job: no_job(),
      on_step: Some(check_deprecated_workflow_commands),
    },
    Rule::{
      id: "invalid-env-var-name",
      title: "Invalid env var name",
      applies: workflow_only,
      on_doc: Some(check_invalid_env_var_name),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "superfluous-actions",
      title: "Duplicate setup-* action in a job",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: Some(check_superfluous_actions),
      on_step: no_step(),
    },
    Rule::{
      id: "template-injection",
      title: "Untrusted expression in `run:` script",
      applies: workflow_or_action,
      on_doc: no_doc(),
      on_job: no_job(),
      on_step: Some(check_template_injection),
    },
    Rule::{
      id: "secrets-outside-env",
      title: "Secrets accessed without an `environment:` gate",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: Some(check_secrets_outside_env),
      on_step: no_step(),
    },
    Rule::{
      id: "overprovisioned-secrets",
      title: "Whole `secrets` context injected via `toJSON()`",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: Some(check_overprovisioned_secrets),
      on_step: no_step(),
    },
    Rule::{
      id: "cache-poisoning",
      title: "Cache restore in release-publishing flow",
      applies: workflow_only,
      on_doc: Some(check_cache_poisoning),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "unpinned-tools",
      title: "External installer piped to a shell in `run:`",
      applies: workflow_or_action,
      on_doc: no_doc(),
      on_job: no_job(),
      on_step: Some(check_unpinned_tools),
    },
    Rule::{
      id: "outdated-action-version",
      title: "Outdated action runtime",
      applies: action_only,
      on_doc: Some(check_outdated_action_version),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "uses-syntax",
      title: "Bad `uses:` format",
      applies: workflow_or_action,
      on_doc: no_doc(),
      on_job: no_job(),
      on_step: Some(check_uses_syntax),
    },
    Rule::{
      id: "job-step-id-naming",
      title: "Bad job/step ID naming",
      applies: workflow_only,
      on_doc: Some(check_job_step_id_naming),
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
// Rule: permissions-read-all-forbidden (ghalint ghl-002)
// ---------------------------------------------------------------------------

///|
fn check_read_all_workflow(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  match ctx.workflow_map {
    Some(m) => check_read_all(m.get("permissions"), "workflow", out)
    None => ()
  }
}

///|
fn check_read_all_job(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  check_read_all(job.raw.get("permissions"), "job `\{job.name}`", out)
}

///|
fn check_read_all(
  value : @yaml.Yaml?,
  location : String,
  out : Array[Diagnostic],
) -> Unit {
  match value {
    Some(String("read-all")) =>
      add_diag(
        out,
        "permissions-read-all-forbidden",
        Error,
        "\{location}: `permissions: read-all` is forbidden",
      )
    _ => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: dangerous-triggers (zizmor) — `pull_request_target`, `workflow_run`
// ---------------------------------------------------------------------------

///|
fn is_dangerous_trigger(name : String) -> Bool {
  name == "pull_request_target" || name == "workflow_run"
}

///|
fn emit_dangerous_trigger(name : String, out : Array[Diagnostic]) -> Unit {
  add_diag(
    out,
    "dangerous-triggers",
    Error,
    "trigger `\{name}` runs with write access to the base repo",
  )
}

///|
fn check_dangerous_triggers(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  let m = match ctx.workflow_map {
    Some(m) => m
    None => return
  }
  match m.get("on") {
    Some(String(s)) =>
      if is_dangerous_trigger(s) {
        emit_dangerous_trigger(s, out)
      }
    Some(Array(arr)) =>
      for item in arr {
        match item {
          String(s) =>
            if is_dangerous_trigger(s) {
              emit_dangerous_trigger(s, out)
            }
          _ => ()
        }
      }
    Some(Map(om)) =>
      om.each(fn(name, _) {
        if is_dangerous_trigger(name) {
          emit_dangerous_trigger(name, out)
        }
      })
    _ => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: unpinned-images (zizmor + ghalint ghl-007)
// ---------------------------------------------------------------------------

///|
fn extract_image(v : @yaml.Yaml) -> String? {
  match v {
    String(s) => Some(s)
    Map(im) => get_string_field(im, "image")
    _ => None
  }
}

///|
fn is_pinned_image(image : String) -> Bool {
  image.contains("${{") || image.contains("@sha256:")
}

///|
fn check_unpinned_images(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  match job.raw.get("container") {
    Some(v) =>
      match extract_image(v) {
        Some(img) =>
          if !is_pinned_image(img) {
            add_diag(
              out,
              "unpinned-images",
              Warning,
              "container image `\{img}` is not pinned by digest",
            )
          }
        None => ()
      }
    None => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: secrets-inherit (zizmor + ghalint ghl-004)
// ---------------------------------------------------------------------------

///|
fn check_secrets_inherit(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  // Only reusable workflow calls accept a `secrets:` block.
  match job.uses {
    None => return
    Some(_) => ()
  }
  match job.raw.get("secrets") {
    Some(String("inherit")) =>
      add_diag(
        out,
        "secrets-inherit",
        Error,
        "job `\{job.name}`: `secrets: inherit` forwards every secret",
      )
    _ => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: composite-step-shell-required (ghalint ghl-011)
// ---------------------------------------------------------------------------

///|
fn check_composite_step_shell(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  if !ctx.action_is_composite {
    return
  }
  for s in ctx.action_steps {
    if s.run is Some(_) && !s.has_shell {
      add_diag(
        out,
        "composite-step-shell-required",
        Warning,
        "composite action step is missing `shell:`",
      )
    }
  }
}

// ---------------------------------------------------------------------------
// Rule: self-hosted-runner (zizmor) — flags self-hosted runner labels
// ---------------------------------------------------------------------------

///|
fn runs_on_has_self_hosted(v : @yaml.Yaml) -> Bool {
  match v {
    String(s) => s == "self-hosted"
    Array(arr) => {
      for item in arr {
        match item {
          String(s) => if s == "self-hosted" { return true }
          _ => ()
        }
      }
      false
    }
    Map(m) =>
      match m.get("labels") {
        Some(inner) => runs_on_has_self_hosted(inner)
        None => false
      }
    _ => false
  }
}

///|
fn check_self_hosted_runner(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  match job.raw.get("runs-on") {
    Some(v) =>
      if runs_on_has_self_hosted(v) {
        add_diag(
          out,
          "self-hosted-runner",
          Warning,
          "job `\{job.name}` runs on a self-hosted runner",
        )
      }
    None => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: insecure-commands (zizmor) — `ACTIONS_ALLOW_UNSECURE_COMMANDS=true`
// ---------------------------------------------------------------------------

///|
fn env_has_unsafe_commands(env : Map[String, @yaml.Yaml]) -> Bool {
  match env.get("ACTIONS_ALLOW_UNSECURE_COMMANDS") {
    Some(String("true")) => true
    Some(Boolean(true)) => true
    _ => false
  }
}

///|
fn check_insecure_commands(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  let m = match ctx.workflow_map {
    Some(m) => m
    None => return
  }
  let flagged = match m.get("env") {
    Some(Map(env)) => env_has_unsafe_commands(env)
    _ => false
  }
  if flagged {
    add_diag(
      out,
      "insecure-commands",
      Warning,
      "`ACTIONS_ALLOW_UNSECURE_COMMANDS=true` re-enables legacy workflow commands",
    )
    return
  }
  // Job- and step-level env blocks also count.
  for j in ctx.jobs {
    match j.raw.get("env") {
      Some(Map(env)) =>
        if env_has_unsafe_commands(env) {
          add_diag(
            out,
            "insecure-commands",
            Warning,
            "`ACTIONS_ALLOW_UNSECURE_COMMANDS=true` re-enables legacy workflow commands",
          )
          return
        }
      _ => ()
    }
    for s in j.steps {
      match s.raw.get("env") {
        Some(Map(env)) =>
          if env_has_unsafe_commands(env) {
            add_diag(
              out,
              "insecure-commands",
              Warning,
              "`ACTIONS_ALLOW_UNSECURE_COMMANDS=true` re-enables legacy workflow commands",
            )
            return
          }
        _ => ()
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Rule: misfeature (zizmor) — `continue-on-error: true` at job level
// ---------------------------------------------------------------------------

///|
fn check_misfeature(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  match get_bool_field(job.raw, "continue-on-error") {
    Some(true) =>
      add_diag(
        out,
        "misfeature",
        Info,
        "job `\{job.name}` has `continue-on-error: true`; failures will be hidden",
      )
    _ => ()
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

// ---------------------------------------------------------------------------
// Helpers for the new rule batch
// ---------------------------------------------------------------------------

///|
fn contains_secrets_ref(s : String) -> Bool {
  s.contains("${{") && s.contains("secrets.")
}

///|
fn map_value_has_secrets(env : Map[String, @yaml.Yaml]) -> Bool {
  let mut found = false
  env.each(fn(_k, v) {
    match v {
      String(s) => if contains_secrets_ref(s) { found = true }
      _ => ()
    }
  })
  found
}

///|
fn is_ident_start(c : Char) -> Bool {
  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_'
}

///|
fn is_ident_cont(c : Char) -> Bool {
  is_ident_start(c) || (c >= '0' && c <= '9')
}

///|
fn is_id_cont(c : Char) -> Bool {
  is_ident_cont(c) || c == '-'
}

///|
fn matches_pattern(s : String, ident_check : (Char) -> Bool) -> Bool {
  let len = s.length()
  if len == 0 { return false }
  let mut i = 0
  while i < len {
    match s.get_char(i) {
      Some(c) => {
        let ok = if i == 0 { is_ident_start(c) } else { ident_check(c) }
        if !ok { return false }
      }
      None => return false
    }
    i = i + 1
  }
  true
}

///|
fn is_valid_env_name(s : String) -> Bool {
  matches_pattern(s, is_ident_cont)
}

///|
fn is_valid_id(s : String) -> Bool {
  matches_pattern(s, is_id_cont)
}

// ---------------------------------------------------------------------------
// Rule: workflow-env-no-secrets (ghalint ghl-005)
// ---------------------------------------------------------------------------

///|
fn check_workflow_env_no_secrets(
  ctx : WalkCtx,
  out : Array[Diagnostic],
) -> Unit {
  let m = match ctx.workflow_map {
    Some(m) => m
    None => return
  }
  match m.get("env") {
    Some(Map(env)) =>
      env.each(fn(k, v) {
        match v {
          String(s) =>
            if contains_secrets_ref(s) {
              add_diag(
                out,
                "workflow-env-no-secrets",
                Error,
                "workflow env `\{k}` references `secrets.*`; move it to a job/step env",
              )
            }
          _ => ()
        }
      })
    _ => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: job-env-no-secrets (ghalint ghl-006)
// ---------------------------------------------------------------------------

///|
fn check_job_env_no_secrets(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  match job.raw.get("env") {
    Some(Map(env)) =>
      env.each(fn(k, v) {
        match v {
          String(s) =>
            if contains_secrets_ref(s) {
              add_diag(
                out,
                "job-env-no-secrets",
                Error,
                "job `\{job.name}` env `\{k}` references `secrets.*`; scope it to the step instead",
              )
            }
          _ => ()
        }
      })
    _ => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: github-app-limit-repositories / github-app-limit-permissions
// (ghalint ghl-009 / ghl-010)
// ---------------------------------------------------------------------------

///|
fn is_github_app_token_step(step : StepInfo) -> Bool {
  match step.uses {
    Some(u) =>
      u.has_prefix("tibdex/github-app-token@") ||
      u.has_prefix("actions/create-github-app-token@")
    None => false
  }
}

///|
fn check_github_app_limit_repos(
  _ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  if !is_github_app_token_step(step) { return }
  let has = match step.with_ {
    Some(w) => w.contains("repositories")
    None => false
  }
  if !has {
    add_diag(
      out,
      "github-app-limit-repositories",
      Warning,
      "GitHub App token request is missing `repositories:` scope",
    )
  }
}

///|
fn check_github_app_limit_perms(
  _ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  if !is_github_app_token_step(step) { return }
  let has = match step.with_ {
    Some(w) => w.contains("permissions")
    None => false
  }
  if !has {
    add_diag(
      out,
      "github-app-limit-permissions",
      Warning,
      "GitHub App token request is missing `permissions:` scope",
    )
  }
}

// ---------------------------------------------------------------------------
// Rule: hardcoded-container-credentials (zizmor + actionlint)
// ---------------------------------------------------------------------------

///|
fn flag_creds_password(
  m : Map[String, @yaml.Yaml],
  loc : String,
  out : Array[Diagnostic],
) -> Unit {
  match m.get("credentials") {
    Some(Map(creds)) =>
      match creds.get("password") {
        Some(String(s)) =>
          if !s.contains("${{") {
            add_diag(
              out,
              "hardcoded-container-credentials",
              Error,
              "\{loc} `credentials.password` is a literal; reference `${{ secrets.* }}` instead",
            )
          }
        _ => ()
      }
    _ => ()
  }
}

///|
fn check_hardcoded_container_creds(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  match job.raw.get("container") {
    Some(Map(c)) => flag_creds_password(c, "container", out)
    _ => ()
  }
  match job.raw.get("services") {
    Some(Map(svcs)) =>
      svcs.each(fn(svc, v) {
        match v {
          Map(sm) => flag_creds_password(sm, "services.\{svc}", out)
          _ => ()
        }
      })
    _ => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: obfuscation (zizmor) — percent-encoded uses ref
// ---------------------------------------------------------------------------

///|
fn is_hex_char(c : Char) -> Bool {
  (c >= '0' && c <= '9') ||
  (c >= 'a' && c <= 'f') ||
  (c >= 'A' && c <= 'F')
}

///|
fn ref_has_percent_encoding(s : String) -> Bool {
  let len = s.length()
  let mut i = 0
  while i + 2 < len {
    match s.get_char(i) {
      Some('%') => {
        let h1 = match s.get_char(i + 1) {
          Some(c) => c
          None => return false
        }
        let h2 = match s.get_char(i + 2) {
          Some(c) => c
          None => return false
        }
        if is_hex_char(h1) && is_hex_char(h2) {
          return true
        }
      }
      _ => ()
    }
    i = i + 1
  }
  false
}

///|
fn check_obfuscation(
  _ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  match step.uses {
    Some(u) =>
      if step.at_idx >= 0 {
        let ref_str = u[step.at_idx + 1:].to_owned()
        if ref_has_percent_encoding(ref_str) {
          add_diag(
            out,
            "obfuscation",
            Warning,
            "uses ref contains percent-encoded characters; possible obfuscation",
          )
        }
      }
    None => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: known-vulnerable-actions (zizmor)
// ---------------------------------------------------------------------------

///|
fn check_known_vulnerable_actions(
  _ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  match step.uses {
    Some(u) => {
      // tj-actions/* was retroactively compromised in March 2025.
      if u.has_prefix("tj-actions/changed-files@") ||
         u.has_prefix("tj-actions/branch-names@") ||
         u.has_prefix("tj-actions/eslint-changed-files@") ||
         u.has_prefix("reviewdog/action-setup@v1.0.0") ||
         u.has_prefix("reviewdog/action-setup@v1.0.1") ||
         u.has_prefix("reviewdog/action-setup@v1.0.2") ||
         u.has_prefix("reviewdog/action-setup@v1.0.3") ||
         u.has_prefix("reviewdog/action-setup@v1.1.0") {
        add_diag(
          out,
          "known-vulnerable-actions",
          Error,
          "uses `\{u}`: known compromised release",
        )
      }
    }
    None => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: deprecated-workflow-commands (actionlint)
// ---------------------------------------------------------------------------

///|
fn check_deprecated_workflow_commands(
  _ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  match step.run {
    Some(r) => {
      if r.contains("::set-output") {
        add_diag(
          out,
          "deprecated-workflow-commands",
          Warning,
          "deprecated workflow command `::set-output`; use `$GITHUB_OUTPUT` instead",
        )
      } else if r.contains("::set-env") {
        add_diag(
          out,
          "deprecated-workflow-commands",
          Warning,
          "deprecated workflow command `::set-env`; use `$GITHUB_ENV` instead",
        )
      } else if r.contains("::save-state") {
        add_diag(
          out,
          "deprecated-workflow-commands",
          Warning,
          "deprecated workflow command `::save-state`; use `$GITHUB_STATE` instead",
        )
      }
    }
    None => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: invalid-env-var-name (actionlint)
// ---------------------------------------------------------------------------

///|
fn check_invalid_env_var_name(
  ctx : WalkCtx,
  out : Array[Diagnostic],
) -> Unit {
  let check_env = fn(env : Map[String, @yaml.Yaml]) -> Unit {
    env.each(fn(k, _v) {
      if !is_valid_env_name(k) {
        add_diag(
          out,
          "invalid-env-var-name",
          Warning,
          "env name `\{k}` does not match `[A-Za-z_][A-Za-z0-9_]*`",
        )
      }
    })
  }
  match ctx.workflow_map {
    Some(m) =>
      match m.get("env") {
        Some(Map(e)) => check_env(e)
        _ => ()
      }
    None => ()
  }
  for j in ctx.jobs {
    match j.raw.get("env") {
      Some(Map(e)) => check_env(e)
      _ => ()
    }
    for s in j.steps {
      match s.raw.get("env") {
        Some(Map(e)) => check_env(e)
        _ => ()
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Rule: superfluous-actions (zizmor)
// ---------------------------------------------------------------------------

///|
fn step_repo_prefix(s : StepInfo) -> String? {
  match s.uses {
    Some(u) =>
      if s.at_idx > 0 {
        Some(u[:s.at_idx].to_owned())
      } else {
        None
      }
    None => None
  }
}

///|
fn is_setup_action(name : String) -> Bool {
  name == "actions/setup-node" ||
  name == "actions/setup-python" ||
  name == "actions/setup-go" ||
  name == "actions/setup-java" ||
  name == "actions/setup-dotnet" ||
  name == "actions/setup-ruby"
}

///|
fn check_superfluous_actions(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  let counts : Map[String, Int] = {}
  for s in job.steps {
    match step_repo_prefix(s) {
      Some(prefix) =>
        if is_setup_action(prefix) {
          let curr = match counts.get(prefix) {
            Some(n) => n
            None => 0
          }
          counts[prefix] = curr + 1
        }
      None => ()
    }
  }
  counts.each(fn(prefix, n) {
    if n >= 2 {
      let times = if n == 2 { "twice" } else { "\{n} times" }
      add_diag(
        out,
        "superfluous-actions",
        Info,
        "job `\{job.name}` uses `\{prefix}` \{times}",
      )
    }
  })
}

// ---------------------------------------------------------------------------
// Rule: template-injection (zizmor + actionlint script-injection)
// ---------------------------------------------------------------------------

///|
fn find_untrusted_in_text(t : String) -> String? {
  if !t.contains("${{") { return None }
  let patterns = [
    "github.event.pull_request.body",
    "github.event.pull_request.title",
    "github.event.pull_request.head.ref",
    "github.event.pull_request.head.label",
    "github.event.issue.title",
    "github.event.issue.body",
    "github.event.comment.body",
    "github.event.review.body",
    "github.event.review_comment.body",
    "github.event.workflow_run.head_branch",
    "github.head_ref",
  ]
  for p in patterns {
    if t.contains(p) {
      return Some(p)
    }
  }
  None
}

///|
fn check_template_injection(
  _ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  match step.run {
    Some(r) =>
      match find_untrusted_in_text(r) {
        Some(p) =>
          add_diag(
            out,
            "template-injection",
            Error,
            "untrusted `\{p}` interpolated into `run:` script",
          )
        None => ()
      }
    None => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: secrets-outside-env (zizmor)
// ---------------------------------------------------------------------------

///|
fn step_uses_secrets(s : StepInfo) -> Bool {
  match s.run {
    Some(r) => if contains_secrets_ref(r) { return true }
    None => ()
  }
  match s.with_ {
    Some(w) => {
      let mut found = false
      w.each(fn(_, v) {
        match v {
          String(sv) => if contains_secrets_ref(sv) { found = true }
          _ => ()
        }
      })
      if found { return true }
    }
    None => ()
  }
  false
}

///|
fn check_secrets_outside_env(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  if job.raw.contains("environment") { return }
  for s in job.steps {
    if step_uses_secrets(s) {
      add_diag(
        out,
        "secrets-outside-env",
        Warning,
        "job `\{job.name}` uses `secrets.*` without protecting it with `environment:`",
      )
      return
    }
  }
}

// ---------------------------------------------------------------------------
// Rule: overprovisioned-secrets (zizmor)
// ---------------------------------------------------------------------------

///|
fn env_has_tojson_secrets(env : Map[String, @yaml.Yaml]) -> Bool {
  let mut found = false
  env.each(fn(_k, v) {
    match v {
      String(s) =>
        if s.contains("toJSON(secrets)") || s.contains("toJson(secrets)") {
          found = true
        }
      _ => ()
    }
  })
  found
}

///|
fn check_overprovisioned_secrets(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  match job.raw.get("env") {
    Some(Map(e)) =>
      if env_has_tojson_secrets(e) {
        add_diag(
          out,
          "overprovisioned-secrets",
          Warning,
          "`toJSON(secrets)` exposes every secret; reference specific keys",
        )
        return
      }
    _ => ()
  }
  for s in job.steps {
    match s.raw.get("env") {
      Some(Map(e)) =>
        if env_has_tojson_secrets(e) {
          add_diag(
            out,
            "overprovisioned-secrets",
            Warning,
            "`toJSON(secrets)` exposes every secret; reference specific keys",
          )
          return
        }
      _ => ()
    }
  }
  let _ = map_value_has_secrets // silence unused warning if any
}

// ---------------------------------------------------------------------------
// Rule: cache-poisoning (zizmor)
// ---------------------------------------------------------------------------

///|
fn workflow_runs_on_release(ctx : WalkCtx) -> Bool {
  let m = match ctx.workflow_map {
    Some(m) => m
    None => return false
  }
  match m.get("on") {
    Some(String(s)) => s == "release"
    Some(Array(arr)) => {
      for item in arr {
        match item {
          String(s) => if s == "release" { return true }
          _ => ()
        }
      }
      false
    }
    Some(Map(om)) => {
      let mut found = false
      om.each(fn(name, v) {
        if name == "release" { found = true }
        if name == "push" {
          match v {
            Map(pm) => if pm.contains("tags") { found = true }
            _ => ()
          }
        }
      })
      found
    }
    _ => false
  }
}

///|
fn step_is_cache_restore(s : StepInfo) -> Bool {
  match s.uses {
    Some(u) =>
      u.has_prefix("actions/cache@") || u.has_prefix("actions/cache/restore@")
    None => false
  }
}

///|
fn check_cache_poisoning(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  if !workflow_runs_on_release(ctx) { return }
  for j in ctx.jobs {
    let mut hit = false
    for s in j.steps {
      if step_is_cache_restore(s) {
        hit = true
        break
      }
    }
    if hit {
      add_diag(
        out,
        "cache-poisoning",
        Error,
        "release-publishing job restores from cache; risk of cache poisoning",
      )
      return
    }
  }
}

// ---------------------------------------------------------------------------
// Rule: unpinned-tools (zizmor)
// ---------------------------------------------------------------------------

///|
fn run_has_pipe_to_shell(r : String) -> Bool {
  let has_fetch = r.contains("curl ") || r.contains("wget ")
  if !has_fetch { return false }
  r.contains("| bash") ||
  r.contains("|bash") ||
  r.contains("| sh") ||
  r.contains("|sh") ||
  r.contains("| zsh") ||
  r.contains("|zsh")
}

///|
fn check_unpinned_tools(
  _ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  match step.run {
    Some(r) =>
      if run_has_pipe_to_shell(r) {
        add_diag(
          out,
          "unpinned-tools",
          Warning,
          "run step fetches and executes an external script without pinning",
        )
      }
    None => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: outdated-action-version (actionlint)
// ---------------------------------------------------------------------------

///|
fn check_outdated_action_version(
  ctx : WalkCtx,
  out : Array[Diagnostic],
) -> Unit {
  let m = match ctx.workflow_map {
    Some(m) => m
    None => return
  }
  match m.get("runs") {
    Some(Map(r)) =>
      match r.get("using") {
        Some(String(u)) =>
          if u == "node12" || u == "node16" {
            add_diag(
              out,
              "outdated-action-version",
              Warning,
              "runtime `\{u}` is deprecated; use `node20` or newer",
            )
          }
        _ => ()
      }
    _ => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: uses-syntax (actionlint)
// ---------------------------------------------------------------------------

///|
fn check_uses_syntax(
  _ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  match step.uses {
    Some(u) =>
      if !step.is_local_or_docker && step.at_idx < 0 {
        add_diag(
          out,
          "uses-syntax",
          Error,
          "uses `\{u}`: expected `owner/repo@ref`",
        )
      }
    None => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: job-step-id-naming (actionlint)
// ---------------------------------------------------------------------------

///|
fn check_job_step_id_naming(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  for j in ctx.jobs {
    if !is_valid_id(j.name) {
      add_diag(
        out,
        "job-step-id-naming",
        Warning,
        "job ID `\{j.name}` must match `[A-Za-z_][A-Za-z0-9_-]*`",
      )
    }
    for s in j.steps {
      match s.raw.get("id") {
        Some(String(id)) =>
          if !is_valid_id(id) {
            add_diag(
              out,
              "job-step-id-naming",
              Warning,
              "step ID `\{id}` must match `[A-Za-z_][A-Za-z0-9_-]*`",
            )
          }
        _ => ()
      }
    }
  }
}
