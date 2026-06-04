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
  // Location context, populated during prewalk so findings can name their
  // step. `job` is the owning job's ID (`None` for action-file steps);
  // `step_index` is the 0-based position in the steps list (distinct from
  // `at_idx`, which is the `@` offset within a `uses` ref); `id` is the step
  // `id:` when declared.
  job : String?
  step_index : Int
  id : String?
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
  // Optional caller-supplied context: `uses:` refs known to be vulnerable
  // (typically populated from OSV.dev queries by the worker before linting).
  vuln_uses : Array[String]
  // Optional caller-supplied denylist of `uses:` patterns. Each entry is a
  // glob (`*`/`?`) matched against the step's `uses:` value — either the
  // bare `owner/repo[/subpath]` or `owner/repo[/subpath]@ref`. Empty list
  // keeps `forbidden-uses` dormant, matching zizmor's "no config → silent"
  // default.
  forbidden_uses : Array[String]
  // Optional caller-supplied `owner/repo` list of archived repositories (in
  // addition to a small hardcoded baseline). Worker resolves these from
  // GitHub before linting; comparison is case-insensitive and operates on
  // the bare `owner/repo` (subpath stripped).
  archived_uses : Array[String]
  // Resolved file kind, so rules can disambiguate workflow vs action when
  // structural cues alone aren't reliable (e.g. action.yml that's missing
  // its `runs:` key entirely).
  kind : FileKind
  // Raw source text. YAML parsing loses comments and line layout, but
  // rules like `undocumented-permissions` need both — they re-scan the
  // source. Empty string when no source is available.
  source : String
  // Position-carrying AST root and line counter from the `yamlpos` parser.
  // Used by the field-level position resolver so a finding about a specific
  // field (e.g. `uses:`/`run:`/`permissions:`) can point at that field's node
  // rather than the whole job/step. `None` when no positioned parse is
  // available (e.g. tests that build a `WalkCtx` directly).
  position_root : @yaml.Node?
  line_counter : @yaml.LineCounter?
}

///|
fn build_step_info(
  sm : Map[String, @yaml.Yaml],
  job : String?,
  step_index : Int,
) -> StepInfo {
  let uses = get_string_field(sm, "uses")
  let run = get_string_field(sm, "run")
  let if_cond = get_string_field(sm, "if")
  let id = get_string_field(sm, "id")
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
    job,
    step_index,
    id,
  }
}

///|
fn build_steps(arr : Array[@yaml.Yaml], job : String?) -> Array[StepInfo] {
  let out : Array[StepInfo] = []
  // Index reflects the position in the YAML steps list (counting every
  // element) so it matches what an author sees in the file.
  let mut step_index = 0
  for step in arr {
    match step {
      Map(sm) => out.push(build_step_info(sm, job, step_index))
      _ => ()
    }
    step_index = step_index + 1
  }
  out
}

///|
pub fn prewalk(
  doc : @yaml.Yaml,
  vuln_uses? : Array[String] = [],
  kind? : FileKind = Unknown,
  source? : String = "",
  forbidden_uses? : Array[String] = [],
  archived_uses? : Array[String] = [],
  position_root? : @yaml.Node? = None,
  line_counter? : @yaml.LineCounter? = None,
) -> WalkCtx {
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
                  Some(Array(arr)) => build_steps(arr, Some(name))
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
              for s in build_steps(arr, None) {
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
    vuln_uses,
    kind,
    source,
    forbidden_uses,
    archived_uses,
    position_root,
    line_counter,
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
      applies: workflow_or_action,
      on_doc: Some(check_unpinned_images_doc),
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
      applies: workflow_or_action,
      on_doc: Some(check_insecure_commands),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "misfeature",
      title: "GitHub Actions misfeatures (cmd shell, setup-python pip-install, continue-on-error)",
      applies: workflow_only,
      on_doc: Some(check_misfeature_doc),
      on_job: Some(check_misfeature),
      on_step: Some(check_misfeature_step),
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
      title: "Credential persistence through GitHub Actions artifacts",
      applies: workflow_or_action,
      on_doc: no_doc(),
      on_job: Some(check_artipacked),
      on_step: Some(check_artipacked_step),
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
      title: "Workflow or job grants overly broad `permissions:`",
      applies: workflow_only,
      on_doc: Some(check_excessive_permissions),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "use-trusted-publishing",
      title: "Prefer OIDC trusted publishing over long-lived tokens",
      applies: workflow_or_action,
      on_doc: no_doc(),
      on_job: Some(check_trusted_publishing_job),
      on_step: Some(check_trusted_publishing_step),
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
      id: "dependabot-execution",
      title: "Dependabot enables `insecure-external-code-execution`",
      applies: unknown_only,
      on_doc: Some(check_dependabot_execution),
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
      title: "Obfuscated usage of GitHub Actions features",
      applies: workflow_or_action,
      on_doc: no_doc(),
      on_job: Some(check_obfuscation_job),
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
      title: "Action functionality is already included by the runner",
      applies: workflow_or_action,
      on_doc: Some(check_superfluous_actions_doc),
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
    Rule::{
      id: "missing-required-keys",
      title: "Missing required keys",
      applies: workflow_or_action,
      on_doc: Some(check_missing_required_keys),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "webhook-events",
      title: "Unknown webhook event",
      applies: workflow_only,
      on_doc: Some(check_webhook_events),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "job-needs-graph",
      title: "Invalid job needs graph",
      applies: workflow_only,
      on_doc: Some(check_job_needs_graph),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "expression-syntax",
      title: "Expression syntax error",
      applies: workflow_or_action,
      on_doc: Some(check_expression_syntax),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "unknown-context-or-function",
      title: "Unknown context or function",
      applies: workflow_or_action,
      on_doc: Some(check_unknown_context),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "github-env",
      title: "Untrusted write to $GITHUB_ENV/$GITHUB_PATH",
      applies: workflow_or_action,
      on_doc: no_doc(),
      on_job: no_job(),
      on_step: Some(check_github_env),
    },
    Rule::{
      id: "unredacted-secrets",
      title: "Secret transformed before logging",
      applies: workflow_or_action,
      on_doc: no_doc(),
      on_job: no_job(),
      on_step: Some(check_unredacted_secrets),
    },
    Rule::{
      id: "shell-name-per-os",
      title: "Bad shell for runner OS",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: Some(check_shell_name_per_os),
      on_step: no_step(),
    },
    Rule::{
      id: "empty-mappings",
      title: "Empty mapping has no effect",
      applies: workflow_or_action,
      on_doc: Some(check_empty_mappings_doc),
      on_job: Some(check_empty_mappings_job),
      on_step: Some(check_empty_mappings_step),
    },
    Rule::{
      id: "constant-if-condition",
      title: "`if:` always evaluates to the same value",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: Some(check_constant_if_job),
      on_step: Some(check_constant_if_step),
    },
    Rule::{
      id: "permissions-syntax",
      title: "Invalid permissions scope or value",
      applies: workflow_only,
      on_doc: Some(check_permissions_syntax_doc),
      on_job: Some(check_permissions_syntax_job),
      on_step: no_step(),
    },
    Rule::{
      id: "unexpected-keys",
      title: "Unknown key at this level",
      applies: workflow_or_action,
      on_doc: Some(check_unexpected_keys_doc),
      on_job: Some(check_unexpected_keys_job),
      on_step: Some(check_unexpected_keys_step),
    },
    Rule::{
      id: "cron-and-timezone",
      title: "Invalid cron expression",
      applies: workflow_only,
      on_doc: Some(check_cron),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "invalid-mapping-values",
      title: "Mapping value has wrong type",
      applies: workflow_or_action,
      on_doc: Some(check_invalid_mapping_values_doc),
      on_job: Some(check_invalid_mapping_values_job),
      on_step: Some(check_invalid_mapping_values_step),
    },
    Rule::{
      id: "unknown-runner-label",
      title: "Unknown runner label",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: Some(check_unknown_runner_label),
      on_step: no_step(),
    },
    Rule::{
      id: "concurrency-limits",
      title: "Workflow has no concurrency control",
      applies: workflow_only,
      on_doc: Some(check_concurrency_limits),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "meaningless-comparison",
      title: "Comparison whose result is always constant",
      applies: workflow_or_action,
      on_doc: Some(check_meaningless_comparison),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "glob-patterns",
      title: "Bad glob pattern",
      applies: workflow_only,
      on_doc: Some(check_glob_patterns),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "workflow-dispatch-inputs",
      title: "Invalid workflow_dispatch input definition",
      applies: workflow_only,
      on_doc: Some(check_workflow_dispatch_inputs),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "context-availability",
      title: "Context used where it is not available",
      applies: workflow_or_action,
      on_doc: Some(check_context_availability),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "action-yml-metadata",
      title: "Invalid action.yml metadata",
      applies: action_only,
      on_doc: Some(check_action_yml_metadata),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "reusable-workflow-definition",
      title: "Invalid reusable workflow definition",
      applies: workflow_only,
      on_doc: Some(check_reusable_workflow_definition),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "unsound-condition",
      title: "Unsound boolean expression",
      applies: workflow_or_action,
      on_doc: Some(check_unsound_condition),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "unsound-contains",
      title: "`contains()` arguments look swapped",
      applies: workflow_or_action,
      on_doc: Some(check_unsound_contains),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "anonymous-definition",
      title: "Workflow/action or job has no `name:`",
      applies: workflow_or_action,
      on_doc: Some(check_anonymous_definition),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "undocumented-permissions",
      title: "Permissions block has no explanatory comments",
      applies: workflow_only,
      on_doc: Some(check_undocumented_permissions),
      on_job: no_job(),
      on_step: no_step(),
    },
    Rule::{
      id: "forbidden-uses",
      title: "`uses:` matches a caller-supplied denylist",
      applies: workflow_or_action,
      on_doc: no_doc(),
      on_job: no_job(),
      on_step: Some(check_forbidden_uses),
    },
    Rule::{
      id: "github-app",
      title: "Dangerous use of `actions/create-github-app-token`",
      applies: workflow_or_action,
      on_doc: no_doc(),
      on_job: no_job(),
      on_step: Some(check_github_app),
    },
    Rule::{
      id: "archived-uses",
      title: "Uses an action whose repository is archived",
      applies: workflow_or_action,
      on_doc: no_doc(),
      on_job: Some(check_archived_uses_job),
      on_step: Some(check_archived_uses_step),
    },
    Rule::{
      id: "matrix-values",
      title: "Duplicate scalar entries in `strategy.matrix.<key>`",
      applies: workflow_only,
      on_doc: no_doc(),
      on_job: Some(check_matrix_values_job),
      on_step: None,
    },
    Rule::{
      id: "yaml-anchor-issues",
      title: "YAML anchor declared but never referenced",
      applies: workflow_or_action,
      on_doc: Some(check_yaml_anchor_issues),
      on_job: None,
      on_step: None,
    },
    Rule::{
      id: "deprecated-action-inputs",
      title: "Deprecated input on a popular action",
      applies: workflow_or_action,
      on_doc: no_doc(),
      on_job: None,
      on_step: Some(check_deprecated_action_inputs),
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
  out.push(Diagnostic::{
    rule,
    severity,
    message,
    pos: None,
    job: None,
    step: None,
  })
}

///|
/// Emit a finding tagged with the job it concerns. For `on_job`/`on_step`
/// rules the engine stamps job context automatically; this helper is for
/// `on_doc` rules that iterate jobs themselves (e.g. `anonymous-definition`).
fn add_diag_job(
  out : Array[Diagnostic],
  rule : String,
  severity : Severity,
  message : String,
  job : String,
) -> Unit {
  out.push(Diagnostic::{
    rule,
    severity,
    message,
    pos: None,
    job: Some(job),
    step: None,
  })
}

///|
/// Emit a finding tagged with the step (and its owning job) it concerns. Used
/// by `on_doc` rules that walk steps directly. `index`/`id` come from the
/// step's `StepInfo`.
fn add_diag_step(
  out : Array[Diagnostic],
  rule : String,
  severity : Severity,
  message : String,
  step : StepInfo,
) -> Unit {
  out.push(Diagnostic::{
    rule,
    severity,
    message,
    pos: None,
    job: step.job,
    step: Some(StepRef::{ index: step.step_index, id: step.id }),
  })
}

///|
/// Resolve the fallback position for a step (its entry node), mirroring what
/// `fill_positions` would later stamp. Used by `add_diag_step_field` when the
/// requested field can't be located.
fn step_node_pos(ctx : WalkCtx, job : String?, step_index : Int) -> Position? {
  guard ctx.position_root is Some(root) else { return None }
  guard ctx.line_counter is Some(lc) else { return None }
  match step_node(root, job, step_index) {
    Some(n) => {
      let (line, col) = n.start_pos(lc)
      Some(Position::{ line, col })
    }
    None => None
  }
}

///|
/// Resolve the fallback position for a job (its key node), mirroring what
/// `fill_positions` would later stamp. Used by `add_diag_job_field`.
fn job_node_pos(ctx : WalkCtx, job : String) -> Position? {
  guard ctx.position_root is Some(root) else { return None }
  guard ctx.line_counter is Some(lc) else { return None }
  match job_key_node(root, job) {
    Some(n) => {
      let (line, col) = n.start_pos(lc)
      Some(Position::{ line, col })
    }
    None => None
  }
}

///|
/// Like `add_diag_step`, but additionally resolves `pos` to the step's `key`
/// field node (e.g. `uses`, `run`, or a `with.<input>` path). Falls back to
/// the step entry node when the field can't be located, so `pos` is never
/// lost. Job/step context is set exactly as `add_diag_step` would.
fn add_diag_step_field(
  out : Array[Diagnostic],
  ctx : WalkCtx,
  rule : String,
  severity : Severity,
  message : String,
  step : StepInfo,
  key : String,
) -> Unit {
  let pos = match step_field_pos(ctx, step.job, step.step_index, key) {
    Some(p) => Some(p)
    None => step_node_pos(ctx, step.job, step.step_index)
  }
  out.push(Diagnostic::{
    rule,
    severity,
    message,
    pos,
    job: step.job,
    step: Some(StepRef::{ index: step.step_index, id: step.id }),
  })
}

///|
/// Like `add_diag_job`, but additionally resolves `pos` to the job's `key`
/// field node (e.g. `permissions`). Falls back to the job key node when the
/// field can't be located. Job context is set exactly as `add_diag_job` would.
fn add_diag_job_field(
  out : Array[Diagnostic],
  ctx : WalkCtx,
  rule : String,
  severity : Severity,
  message : String,
  job : String,
  key : String,
) -> Unit {
  let pos = match job_field_pos(ctx, job, key) {
    Some(p) => Some(p)
    None => job_node_pos(ctx, job)
  }
  out.push(Diagnostic::{
    rule,
    severity,
    message,
    pos,
    job: Some(job),
    step: None,
  })
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
        add_diag_job(
          out,
          "duplicate-job-step-ids",
          Error,
          "duplicate job ID `\{name}` (conflicts with `\{prev}` case-insensitively)",
          name,
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
            add_diag_step(
              out,
              "duplicate-job-step-ids",
              Error,
              "duplicate step ID `\{id}` (conflicts with `\{prev}` case-insensitively)",
              s,
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
  ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  match job.raw.get("permissions") {
    Some(String("write-all")) =>
      add_diag_job_field(
        out,
        ctx,
        "permissions-write-all-forbidden",
        Error,
        "job `\{job.name}`: `permissions: write-all` is forbidden",
        job.name,
        "permissions",
      )
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
  ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  if step.is_actions_checkout && !step.has_persist_creds_false {
    add_diag_step_field(
      out,
      ctx,
      "checkout-persist-credentials-false",
      Error,
      "actions/checkout requires `persist-credentials: false` to avoid token leakage",
      step,
      "uses",
    )
  }
}

// ---------------------------------------------------------------------------
// Rule: unpinned-uses (zizmor + ghalint ghl-008)
// ---------------------------------------------------------------------------

///|
fn check_unpinned_uses(
  ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  match step.uses {
    Some(u) =>
      if !step.is_local_or_docker && step.at_idx >= 0 && !step.has_full_sha {
        add_diag_step_field(
          out,
          ctx,
          "unpinned-uses",
          Warning,
          "uses `\{u}` is not pinned to a full-length SHA",
          step,
          "uses",
        )
      }
    None => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: artipacked (zizmor)
// ---------------------------------------------------------------------------

///|
/// Inspect an `actions/checkout` step's `with:` block and emit an
/// `artipacked` diagnostic when the step leaves credentials persisted.
///
/// Behaviour mirrors upstream zizmor's Regular persona (pedantic):
/// - Literal `persist-credentials: false` (bool or stringy `"false"`) is
///   safe — emit nothing.
/// - Literal `persist-credentials: true` (bool or stringy `"true"`) is an
///   auditor-only finding and is suppressed under Regular.
/// - Missing `persist-credentials` (or `with:` itself absent) → Warning
///   with "does not set persist-credentials: false".
/// - Templated `persist-credentials: ${{ ... }}` → same Warning.
/// - `with:` itself is an expression (`with: ${{ fromJson(...) }}`) → Info
///   with "may not set persist-credentials: false" (lower confidence).
fn artipacked_emit_for_step(
  ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  if !step.is_actions_checkout {
    return
  }
  let unsafe_msg = "credential persistence through GitHub Actions artifacts: does not set persist-credentials: false"
  let maybe_msg = "credential persistence through GitHub Actions artifacts: may not set persist-credentials: false"
  let warn = fn() {
    add_diag_step_field(
      out,
      ctx,
      "artipacked",
      Warning,
      unsafe_msg,
      step,
      "uses",
    )
  }
  match step.raw.get("with") {
    Some(Map(w)) =>
      match w.get("persist-credentials") {
        None => warn()
        Some(Boolean(false)) => ()
        Some(Boolean(true)) => () // auditor-only — silent under Regular
        Some(String(s)) =>
          match s.to_lower() {
            "false" | "true" => ()
            _ => warn()
          }
        _ => warn()
      }
    Some(String(_)) =>
      add_diag_step_field(out, ctx, "artipacked", Info, maybe_msg, step, "uses")
    _ => warn()
  }
}

///|
fn check_artipacked(
  ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  for s in job.steps {
    artipacked_emit_for_step(ctx, s, out)
  }
}

///|
/// `on_step` for composite-action steps: composite actions reuse the
/// caller's `GITHUB_TOKEN`, so an unsafe `actions/checkout` inside one
/// is just as risky as in a workflow.
fn check_artipacked_step(
  ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  if ctx.kind != FileKind::Action {
    return
  }
  artipacked_emit_for_step(ctx, step, out)
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
// Rule: excessive-permissions (zizmor)
//
// Mirrors upstream's pedantic-mode behaviour: emit one finding per offending
// `permissions:` shape at the workflow level (`read-all`, `write-all`, each
// `write` entry of an Explicit map, or the *absence* of any `permissions:`
// block) and additionally at each job's level when the job either picks
// `read-all` / `write-all` or inherits the default token because no
// parent-level `permissions:` block exists. Jobs that supply their own
// Explicit map are not flagged — zizmor explicitly punts on per-key
// over-scoping analysis there.
// ---------------------------------------------------------------------------

///|
fn check_excessive_permissions(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  let m = match ctx.workflow_map {
    Some(m) => m
    None => return
  }
  let workflow_perms = m.get("permissions")
  let explicit_parent_permissions = match workflow_perms {
    None => false
    Some(_) => true
  }
  match workflow_perms {
    None =>
      add_diag(
        out,
        "excessive-permissions",
        Warning,
        "default permissions used due to no permissions: block",
      )
    Some(String("read-all")) =>
      add_diag(
        out,
        "excessive-permissions",
        Warning,
        "uses read-all permissions",
      )
    Some(String("write-all")) =>
      add_diag(
        out,
        "excessive-permissions",
        Warning,
        "uses write-all permissions",
      )
    Some(Map(perms)) =>
      perms.each(fn(name, value) {
        match value {
          String("write") =>
            add_diag(
              out,
              "excessive-permissions",
              Warning,
              "\{name}: write is overly broad at the workflow level",
            )
          _ => ()
        }
      })
    _ => ()
  }
  for job in ctx.jobs {
    match job.raw.get("permissions") {
      None =>
        if !explicit_parent_permissions {
          add_diag(
            out,
            "excessive-permissions",
            Warning,
            "job `\{job.name}`: default permissions used due to no permissions: block",
          )
        }
      Some(String("read-all")) =>
        add_diag_job_field(
          out,
          ctx,
          "excessive-permissions",
          Warning,
          "job `\{job.name}`: uses read-all permissions",
          job.name,
          "permissions",
        )
      Some(String("write-all")) =>
        add_diag_job_field(
          out,
          ctx,
          "excessive-permissions",
          Warning,
          "job `\{job.name}`: uses write-all permissions",
          job.name,
          "permissions",
        )
      _ => ()
    }
  }
}

// ---------------------------------------------------------------------------
// Rule: use-trusted-publishing (zizmor)
// ---------------------------------------------------------------------------

///|
/// True if `s` contains any of the URL substrings that mark a registry
/// known to support OIDC trusted publishing.
fn url_value_matches(value : @yaml.Yaml?, needle : String) -> Bool {
  match value {
    Some(String(s)) => s.to_lower().contains(needle)
    _ => false
  }
}

///|
/// Action-based detection: returns Some(message) when the step's `uses:`
/// pattern + `with:` inputs match an upstream-known credential-style
/// publishing setup that should switch to OIDC.
fn trusted_publishing_action_finding(step : StepInfo) -> String? {
  match step.uses {
    Some(u) => {
      // Strip ref before pattern matching.
      let bare = if step.at_idx >= 0 {
        u[:step.at_idx].to_owned()
      } else {
        u.to_string()
      }
      let lower = bare.to_lower()
      let with_ = match step.with_ {
        Some(w) => w
        None => Map::from_array([])
      }
      if lower == "pypa/gh-action-pypi-publish" {
        // Fires when `password:` input is present AND the target index
        // is one we know supports trusted publishing (default pypi.org
        // or one of the explicit pypi.org / test.pypi.org URLs).
        let has_password = with_.contains("password")
        if !has_password {
          return None
        }
        let repo_url = match with_.get("repository-url") {
          Some(v) => Some(v)
          None => with_.get("repository_url")
        }
        let known = match repo_url {
          Some(_) => url_value_matches(repo_url, "pypi.org")
          None => true
        }
        if known {
          return Some(
            "PyPI publish uses an API token; prefer OIDC trusted publishing",
          )
        }
        return None
      }
      if lower == "rubygems/release-gem" {
        // Fires unless `setup-trusted-publisher: true` is explicit.
        let setup = match with_.get("setup-trusted-publisher") {
          Some(@yaml.Yaml::Boolean(b)) => Some(b)
          Some(@yaml.Yaml::String(s)) =>
            if s.to_lower() == "true" {
              Some(true)
            } else if s.to_lower() == "false" {
              Some(false)
            } else {
              None
            }
          _ => None
        }
        if setup == Some(false) {
          return Some(
            "rubygems/release-gem with `setup-trusted-publisher: false`; prefer OIDC trusted publishing",
          )
        }
        return None
      }
      if lower == "rubygems/configure-rubygems-credentials" {
        if !with_.contains("api-token") {
          return None
        }
        let server = with_.get("gem-server")
        let known = match server {
          Some(_) => url_value_matches(server, "rubygems.org")
          None => true
        }
        if known {
          return Some(
            "rubygems/configure-rubygems-credentials uses an API token; prefer OIDC trusted publishing",
          )
        }
        return None
      }
      if lower == "actions/setup-node" {
        let reg = with_.get("registry-url")
        let always_auth = match with_.get("always-auth") {
          Some(@yaml.Yaml::Boolean(true)) => true
          Some(@yaml.Yaml::String(s)) => s.to_lower() == "true"
          _ => false
        }
        if always_auth && url_value_matches(reg, "registry.npmjs.org") {
          return Some(
            "actions/setup-node with `always-auth: true` to npmjs; prefer OIDC trusted publishing",
          )
        }
        return None
      }
      None
    }
    None => None
  }
}

///|
/// Replace bash (`\<EOL>`) and PowerShell (`` `<EOL> ``) line
/// continuations with a single space so multi-line publishing commands
/// flatten into one logical line.
fn collapse_continuations(s : String) -> String {
  let chars : Array[Char] = []
  for ch in s {
    chars.push(ch)
  }
  let n = chars.length()
  let buf = StringBuilder::new()
  let mut i = 0
  while i < n {
    let c = chars[i]
    if (c == '\\' || c == '`') && i + 1 < n {
      let c1 = chars[i + 1]
      if c1 == '\n' {
        buf.write_char(' ')
        i = i + 2
        continue
      }
      if c1 == '\r' && i + 2 < n && chars[i + 2] == '\n' {
        buf.write_char(' ')
        i = i + 3
        continue
      }
    }
    buf.write_char(c)
    i = i + 1
  }
  buf.to_string()
}

///|
fn tokens_contain(tokens : Array[String], needle : String) -> Bool {
  for t in tokens {
    if t == needle {
      return true
    }
  }
  false
}

///|
fn tokens_contain_prefix(tokens : Array[String], prefix : String) -> Bool {
  for t in tokens {
    if t.has_prefix(prefix) {
      return true
    }
  }
  false
}

///|
/// Tokenize a shell line on ASCII whitespace.
fn shell_tokens(line : String) -> Array[String] {
  let out : Array[String] = []
  let buf = StringBuilder::new()
  let mut has = false
  for ch in line {
    if ch == ' ' || ch == '\t' {
      if has {
        out.push(buf.to_string())
        buf.reset()
        has = false
      }
    } else {
      buf.write_char(ch)
      has = true
    }
  }
  if has {
    out.push(buf.to_string())
  }
  out
}

///|
/// Returns true if `tokens` (a single flattened shell command line)
/// invokes one of upstream zizmor's tracked publishing commands.
fn shell_line_is_publish(tokens : Array[String]) -> Bool {
  if tokens.length() == 0 {
    return false
  }
  let cmd = tokens[0]
  let rest : Array[String] = []
  for k in 1..<tokens.length() {
    rest.push(tokens[k])
  }
  if cmd == "cargo" {
    return tokens_contain(rest, "publish") &&
      !tokens_contain(rest, "--dry-run") &&
      !tokens_contain(rest, "-n")
  }
  if cmd == "twine" {
    return tokens_contain(rest, "upload")
  }
  if cmd == "npm" || cmd == "pnpm" {
    return tokens_contain(rest, "publish") && !tokens_contain(rest, "--dry-run")
  }
  if cmd == "bun" {
    return tokens_contain(rest, "publish") && !tokens_contain(rest, "--dry-run")
  }
  if cmd == "yarn" {
    return tokens_contain(rest, "publish") &&
      !tokens_contain(rest, "--dry-run") &&
      !tokens_contain(rest, "-n")
  }
  if cmd == "gem" {
    return tokens_contain(rest, "push")
  }
  if cmd == "nuget" || cmd == "nuget.exe" {
    return tokens_contain(rest, "push")
  }
  if cmd == "dotnet" {
    return tokens_contain(rest, "nuget") && tokens_contain(rest, "push")
  }
  if cmd == "poetry" {
    return tokens_contain(rest, "publish") && !tokens_contain(rest, "--dry-run")
  }
  if cmd == "hatch" || cmd == "pdm" {
    return tokens_contain(rest, "publish")
  }
  if cmd == "uv" {
    if tokens_contain(rest, "publish") {
      return true
    }
    if tokens_contain(rest, "twine") && tokens_contain(rest, "upload") {
      return true
    }
    return false
  }
  if cmd == "uvx" {
    if (
        tokens_contain(rest, "twine") ||
        tokens_contain_prefix(rest, "twine==") ||
        tokens_contain_prefix(rest, "twine@")
      ) &&
      tokens_contain(rest, "upload") {
      return true
    }
    return false
  }
  if cmd == "python" || cmd.has_prefix("python3") {
    return tokens_contain(rest, "-m") &&
      tokens_contain(rest, "twine") &&
      tokens_contain(rest, "upload")
  }
  if cmd == "pipx" {
    if rest.length() > 0 && rest[0] == "run" {
      let twine_like = tokens_contain(rest, "twine") ||
        tokens_contain_prefix(rest, "twine==") ||
        tokens_contain_prefix(rest, "twine@")
      return twine_like && tokens_contain(rest, "upload")
    }
    return false
  }
  if cmd == "bundle" {
    return tokens_contain(rest, "exec") &&
      tokens_contain(rest, "gem") &&
      tokens_contain(rest, "push")
  }
  if cmd == "bunx" {
    let npm_like = tokens_contain(rest, "npm") ||
      tokens_contain_prefix(rest, "npm@")
    return npm_like &&
      tokens_contain(rest, "publish") &&
      !tokens_contain(rest, "--dry-run")
  }
  false
}

///|
fn run_has_publish_cmd(run : String) -> Bool {
  let normalized = collapse_continuations(run)
  for line in normalized.split("\n") {
    let trimmed = line.trim(chars=" \t\r").to_owned()
    if trimmed.length() == 0 {
      continue
    }
    if shell_line_is_publish(shell_tokens(trimmed)) {
      return true
    }
  }
  false
}

///|
/// True if `permissions` map grants `id-token: write`.
fn perms_has_id_token_write(value : @yaml.Yaml?) -> Bool {
  match value {
    Some(@yaml.Yaml::Map(m)) =>
      match m.get("id-token") {
        Some(@yaml.Yaml::String(s)) => s == "write"
        _ => false
      }
    _ => false
  }
}

///|
/// `on_job` for `use-trusted-publishing`: action-based detection always
/// fires; run-based detection is suppressed when the job carries
/// `permissions.id-token: write` (workflow-level grant alone is enough
/// for zizmor too, but propagating that here keeps the check tractable).
fn check_trusted_publishing_job(
  ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  let job_id_token = perms_has_id_token_write(job.raw.get("permissions"))
  let workflow_id_token = match ctx.workflow_map {
    Some(m) => perms_has_id_token_write(m.get("permissions"))
    None => false
  }
  let suppress_run = job_id_token || workflow_id_token
  for step in job.steps {
    match trusted_publishing_action_finding(step) {
      Some(msg) => add_diag(out, "use-trusted-publishing", Info, msg)
      None => ()
    }
    if !suppress_run {
      match step.run {
        Some(r) =>
          if run_has_publish_cmd(r) {
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
  }
}

///|
/// `on_step` for composite-action steps: composite actions cannot
/// declare permissions, so the run-based detection always applies.
fn check_trusted_publishing_step(
  ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  // Workflow steps are handled by `check_trusted_publishing_job` so
  // they can see the enclosing job's permissions; skip them here.
  if ctx.kind != FileKind::Action {
    return
  }
  match trusted_publishing_action_finding(step) {
    Some(msg) => add_diag(out, "use-trusted-publishing", Info, msg)
    None => ()
  }
  match step.run {
    Some(r) =>
      if run_has_publish_cmd(r) {
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
/// Returns the matrix key referenced inside a `${{ matrix.X }}`-only
/// container image expression, or None if the image is not such a pure
/// reference.
fn matrix_key_of_image(image : String) -> String? {
  let s = image.trim(chars=" \t").to_owned()
  if !s.has_prefix("${{") || !s.has_suffix("}}") {
    return None
  }
  let inner = s[3:s.length() - 2].trim(chars=" \t").to_owned()
  let needle = "matrix."
  if !inner.has_prefix(needle) {
    return None
  }
  let rest = inner[needle.length():].to_owned()
  // Reject anything beyond a simple identifier (functions, dotted paths).
  let chars = rest.to_array()
  for ch in chars {
    let ok = (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '_' ||
      ch == '-'
    if !ok {
      return None
    }
  }
  Some(rest)
}

///|
/// Walks `matrix.include` and reports unpinned values of `field` (e.g. the
/// key the container image dereferences with `${{ matrix.<field> }}`).
fn unpinned_matrix_images(matrix : @yaml.Yaml, field : String) -> Array[String] {
  let out : Array[String] = []
  match matrix {
    Map(m) =>
      match m.get("include") {
        Some(Array(entries)) =>
          for e in entries {
            match e {
              Map(em) =>
                match em.get(field) {
                  Some(String(v)) => if !is_pinned_image(v) { out.push(v) }
                  _ => ()
                }
              _ => ()
            }
          }
        _ => ()
      }
    _ => ()
  }
  out
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
          // Resolve `${{ matrix.<key> }}` style images by walking the
          // matrix's `include:` list — anything literally unpinned there
          // still counts as unpinned.
          match matrix_key_of_image(img) {
            Some(key) =>
              match job.raw.get("strategy") {
                Some(Map(strat)) =>
                  match strat.get("matrix") {
                    Some(mx) =>
                      for v2 in unpinned_matrix_images(mx, key) {
                        add_diag(
                          out,
                          "unpinned-images",
                          Warning,
                          "matrix entry `\{key}: \{v2}` produces an unpinned container image",
                        )
                      }
                    None => ()
                  }
                _ => ()
              }
            None =>
              if !is_pinned_image(img) {
                add_diag(
                  out,
                  "unpinned-images",
                  Warning,
                  "container image `\{img}` is not pinned by digest",
                )
              }
          }
        None => ()
      }
    None => ()
  }
}

///|
fn check_unpinned_images_doc(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  // Docker actions declare their image at `runs.image` (or
  // `runs.using: docker` + `runs.image: docker://…`).
  let m = match ctx.workflow_map {
    Some(m) => m
    None => return
  }
  match m.get("runs") {
    Some(Map(r)) =>
      match r.get("image") {
        Some(String(img)) => {
          // Local Dockerfile references (e.g. `image: Dockerfile`) don't
          // pull a remote image, so they can't be unpinned.
          let is_local = !img.contains("docker://") && !img.contains("/")
          if !is_local && !is_pinned_image(img) {
            add_diag(
              out,
              "unpinned-images",
              Warning,
              "docker-action image `\{img}` is not pinned by digest",
            )
          }
        }
        _ => ()
      }
    _ => ()
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
      add_diag_step(
        out,
        "composite-step-shell-required",
        Warning,
        "composite action step is missing `shell:`",
        s,
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
  let fire = fn() {
    add_diag(
      out,
      "insecure-commands",
      Warning,
      "`ACTIONS_ALLOW_UNSECURE_COMMANDS=true` re-enables legacy workflow commands",
    )
  }
  match ctx.workflow_map {
    Some(m) =>
      match m.get("env") {
        Some(Map(env)) =>
          if env_has_unsafe_commands(env) {
            fire()
            return
          }
        _ => ()
      }
    None => ()
  }
  // Job- and step-level env blocks also count.
  for j in ctx.jobs {
    match j.raw.get("env") {
      Some(Map(env)) =>
        if env_has_unsafe_commands(env) {
          fire()
          return
        }
      _ => ()
    }
    for s in j.steps {
      match s.raw.get("env") {
        Some(Map(env)) =>
          if env_has_unsafe_commands(env) {
            fire()
            return
          }
        _ => ()
      }
    }
  }
  // Composite-action steps share the same hazard.
  for s in ctx.action_steps {
    match s.raw.get("env") {
      Some(Map(env)) =>
        if env_has_unsafe_commands(env) {
          fire()
          return
        }
      _ => ()
    }
  }
}

// ---------------------------------------------------------------------------
// Rule: misfeature (zizmor) — GHA misfeatures that bite users in practice:
//   - `defaults.run.shell: cmd` (workflow or job) — Windows `cmd` swallows
//     exit codes from inline `run:` blocks
//   - `actions/setup-python` with `pip-install:` — the input is undocumented
//     and silently no-ops on misuse
//   - job-level `continue-on-error: true` — hides real failures
// ---------------------------------------------------------------------------

///|
fn defaults_run_shell_is_cmd(raw : Map[String, @yaml.Yaml]) -> Bool {
  match raw.get("defaults") {
    Some(Map(d)) =>
      match d.get("run") {
        Some(Map(r)) =>
          match r.get("shell") {
            Some(String(s)) => s.to_lower() == "cmd"
            _ => false
          }
        _ => false
      }
    _ => false
  }
}

///|
fn check_misfeature_doc(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  match ctx.workflow_map {
    Some(m) =>
      if defaults_run_shell_is_cmd(m) {
        add_diag(
          out,
          "misfeature",
          Info,
          "workflow `defaults.run.shell: cmd` makes inline `run:` blocks swallow exit codes; prefer `pwsh`",
        )
      }
    None => ()
  }
}

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
  if defaults_run_shell_is_cmd(job.raw) {
    add_diag(
      out,
      "misfeature",
      Info,
      "job `\{job.name}` has `defaults.run.shell: cmd`, which swallows inline `run:` exit codes; prefer `pwsh`",
    )
  }
}

///|
fn check_misfeature_step(
  _ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  match step.uses {
    Some(u) => {
      let lo = u.to_lower()
      if lo.contains("actions/setup-python") {
        match step.raw.get("with") {
          Some(Map(w)) =>
            if w.contains("pip-install") {
              add_diag(
                out,
                "misfeature",
                Info,
                "`actions/setup-python` has no `pip-install:` input; this silently no-ops — run `pip install` in a separate step",
              )
            }
          _ => ()
        }
      }
    }
    None => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: dependabot-cooldown (zizmor) — applies to dependabot.yaml
// ---------------------------------------------------------------------------

///|
/// Mirrors zizmor's `dependabot-cooldown`: each `updates:` entry is
/// inspected independently and may produce up to four findings
/// (missing block / no default-days / insufficient default-days /
/// multi-ecosystem-group with effective cooldown). Threshold matches
/// upstream's default `days = 7`.
fn check_dependabot_cooldown(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  let threshold = 7
  for um in ctx.updates {
    let cooldown = um.get("cooldown")
    match cooldown {
      None =>
        add_diag(
          out,
          "dependabot-cooldown",
          Info,
          "missing cooldown configuration",
        )
      Some(@yaml.Yaml::Map(c)) => {
        let dd = c.get("default-days")
        let dd_int = match dd {
          Some(@yaml.Yaml::Integer(n)) => Some(n)
          Some(@yaml.Yaml::Real(d, repr=_)) => Some(d.to_int64())
          _ => None
        }
        match dd_int {
          None =>
            add_diag(
              out,
              "dependabot-cooldown",
              Info,
              "no default-days configured",
            )
          Some(n) =>
            if n < threshold.to_int64() {
              add_diag(
                out,
                "dependabot-cooldown",
                Info,
                "insufficient default-days configured (less than \{threshold})",
              )
            }
        }
        // multi-ecosystem-group with effective cooldown (pedantic).
        if um.contains("multi-ecosystem-group") && cooldown_is_effective(c) {
          add_diag(
            out,
            "dependabot-cooldown",
            Info,
            "multi-ecosystem-group cooldowns do not batch updates correctly",
          )
        }
      }
      _ =>
        add_diag(
          out,
          "dependabot-cooldown",
          Info,
          "missing cooldown configuration",
        )
    }
  }
}

///|
/// Returns true when the cooldown block has any positive day budget,
/// matching zizmor's `Cooldown::effective`.
fn cooldown_is_effective(c : Map[String, @yaml.Yaml]) -> Bool {
  let fields = [
    "default-days", "semver-major-days", "semver-minor-days", "semver-patch-days",
  ]
  for k in fields {
    match c.get(k) {
      Some(@yaml.Yaml::Integer(n)) => if n > 0L { return true }
      Some(@yaml.Yaml::Real(d, repr=_)) => if d > 0.0 { return true }
      _ => ()
    }
  }
  false
}

///|
/// Mirrors zizmor's `dependabot-execution`: a `dependabot.yml` update
/// entry that sets `insecure-external-code-execution: allow` lets the
/// dependency resolver run arbitrary scripts shipped by upstream
/// packages (the `cargo`, `bundler`, `pip`, etc. ecosystems support it).
fn check_dependabot_execution(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  for um in ctx.updates {
    match um.get("insecure-external-code-execution") {
      Some(v) =>
        if yaml_scalar_text(v) == "allow" {
          add_diag(
            out,
            "dependabot-execution",
            Error,
            "`insecure-external-code-execution: allow` lets dependency resolvers run arbitrary upstream code",
          )
        }
      None => ()
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
  if len == 0 {
    return false
  }
  let mut i = 0
  while i < len {
    match s.get_char(i) {
      Some(c) => {
        let ok = if i == 0 { is_ident_start(c) } else { ident_check(c) }
        if !ok {
          return false
        }
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
  if !is_github_app_token_step(step) {
    return
  }
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
  if !is_github_app_token_step(step) {
    return
  }
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
            let suffix = "`credentials.password` is a literal; reference `${{ secrets.* }}` instead"
            add_diag(
              out,
              "hardcoded-container-credentials",
              Error,
              "\{loc} \{suffix}",
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
  (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
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
/// Returns the "obfuscation kind" (empty / `.` / `..`) for the first
/// suspicious path segment in `head` (the part before `@`), or None.
fn uses_path_obfuscation(head : String) -> String? {
  // Skip the leading `owner/repo` segments — those are the first two
  // slash-delimited parts and shouldn't be checked. Upstream checks
  // *every* component including these for `.`/`..`/empty, but in
  // practice owner/repo can never literally be `.` / `..` / empty, so
  // walking from the start is safe.
  let mut idx = 0
  let parts = head.split("/")
  for raw in parts {
    let part = raw.to_owned()
    if idx >= 2 {
      // 3rd+ component is a subpath piece.
      if part.length() == 0 {
        return Some("empty component")
      }
      if part == "." {
        return Some("'.' component")
      }
      if part == ".." {
        return Some("'..' component")
      }
    }
    idx = idx + 1
  }
  None
}

///|
/// True if `inner` (the contents of a `${{ ... }}` interpolation) can be
/// reduced to a constant value statically. Mirrors zizmor's
/// `Expr::constant_reducible`: literals are reducible; any property
/// access (`foo.bar` / `foo[...]`) is presumed dynamic; functions are
/// reducible only when they are one of the deterministic builtins
/// (`contains`, `startswith`, `endswith`, `format`, `tojson`, `join`).
/// Single-quoted string literals may contain `.` and identifier-looking
/// text that should not be confused for context access.
fn expression_is_constant_only(inner : String) -> Bool {
  let lower = inner.to_lower()
  let chars : Array[Char] = []
  for ch in lower {
    chars.push(ch)
  }
  let n = chars.length()
  let mut i = 0
  while i < n {
    let c = chars[i]
    // Skip single-quoted string literals (GitHub Actions syntax uses
    // `''` as the escape for a single quote inside a string).
    if c == '\'' {
      i = i + 1
      while i < n {
        if chars[i] == '\'' {
          if i + 1 < n && chars[i + 1] == '\'' {
            i = i + 2
            continue
          }
          i = i + 1
          break
        }
        i = i + 1
      }
      continue
    }
    if is_ident_start(c) {
      let start = i
      while i < n && is_ident_cont(chars[i]) {
        i = i + 1
      }
      // `-` is a legal identifier continuation in GitHub Actions
      // expressions (see e.g. `runs-on`). zizmor's lexer also accepts it.
      while i < n && chars[i] == '-' && i + 1 < n && is_ident_cont(chars[i + 1]) {
        i = i + 1
        while i < n && is_ident_cont(chars[i]) {
          i = i + 1
        }
      }
      let buf = StringBuilder::new()
      for p in start..<i {
        buf.write_char(chars[p])
      }
      let name = buf.to_string()
      // Skip trailing whitespace before looking at the next token.
      let mut k = i
      while k < n && (chars[k] == ' ' || chars[k] == '\t') {
        k = k + 1
      }
      let next = if k < n { chars[k] } else { ' ' }
      // Property access — context or computed.
      if next == '.' || next == '[' {
        return false
      }
      // Function calls.
      if next == '(' {
        let safe = [
          "contains", "startswith", "endswith", "format", "tojson", "fromjson", "join",
        ]
        let mut is_safe = false
        for f in safe {
          if name == f {
            is_safe = true
            break
          }
        }
        if !is_safe {
          return false
        }
        // Bare identifier that isn't a keyword/literal — treat as a
        // context reference (e.g. `github` standalone or an unknown
        // ident). Only `true`/`false`/`null` are literal keywords.
      } else if name != "true" && name != "false" && name != "null" {
        return false
      }
      continue
    }
    i = i + 1
  }
  true
}

///|
/// Scans `text` for `${{ ... }}` interpolations. Returns true on the first
/// match whose inner content is constant-only (and therefore reducible).
fn text_has_reducible_expression(text : String) -> Bool {
  let mut i = 0
  let bytes = text
  while i + 2 < bytes.length() {
    let c0 = bytes[i]
    if c0 == '$' && bytes[i + 1] == '{' && bytes[i + 2] == '{' {
      // Find matching `}}`.
      let mut j = i + 3
      let mut found = false
      while j + 1 < bytes.length() {
        if bytes[j] == '}' && bytes[j + 1] == '}' {
          found = true
          break
        }
        j = j + 1
      }
      if found {
        let inner = bytes[i + 3:j].to_owned()
        let trimmed = inner.trim(chars=" \t\r\n").to_owned()
        if trimmed.length() > 0 && expression_is_constant_only(trimmed) {
          return true
        }
        i = j + 2
        continue
      }
    }
    i = i + 1
  }
  false
}

///|
/// True when the bracketed expression is a non-literal lookup — i.e. it
/// contains a `.` (property access) outside any quoted string. Literal
/// indices like `1` or `'a.b'` (single-quoted strings with embedded dots)
/// must stay static so we don't false-positive on the `obfuscation` audit.
fn index_expr_is_computed(idx_text : String) -> Bool {
  let chars = idx_text.to_array()
  let n = chars.length()
  let mut i = 0
  let mut in_single = false
  let mut in_double = false
  while i < n {
    let ch = chars[i]
    if !in_double && ch == '\'' {
      in_single = !in_single
    } else if !in_single && ch == '"' {
      in_double = !in_double
    } else if !in_single && !in_double && ch == '.' {
      return true
    }
    i = i + 1
  }
  false
}

///|
/// Detects `name[expr]` where `expr` itself is a non-literal lookup
/// (contains `.`). Matches upstream `computed_indices` pedantic finding.
fn text_has_computed_index(text : String) -> Bool {
  // Walk balanced `[...]` within `${{ ... }}` blocks.
  let mut i = 0
  while i + 2 < text.length() {
    if text[i] == '$' && text[i + 1] == '{' && text[i + 2] == '{' {
      let mut j = i + 3
      while j + 1 < text.length() {
        if text[j] == '}' && text[j + 1] == '}' {
          break
        }
        if text[j] == '[' {
          // Capture index expression up to matching `]`.
          let mut k = j + 1
          let mut nested = 1
          while k < text.length() && nested > 0 {
            if text[k] == '[' {
              nested = nested + 1
            } else if text[k] == ']' {
              nested = nested - 1
              if nested == 0 {
                break
              }
            }
            k = k + 1
          }
          if k < text.length() {
            let idx_text = text[j + 1:k].to_owned()
            if index_expr_is_computed(idx_text) {
              return true
            }
          }
          j = k
        }
        j = j + 1
      }
      i = j + 2
      continue
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
        let head = u[:step.at_idx].to_owned()
        let ref_str = u[step.at_idx + 1:].to_owned()
        if ref_has_percent_encoding(ref_str) {
          add_diag(
            out,
            "obfuscation",
            Info,
            "uses ref contains percent-encoded characters; possible obfuscation",
          )
        }
        match uses_path_obfuscation(head) {
          Some(kind) =>
            add_diag(out, "obfuscation", Info, "uses ref contains \{kind}")
          None => ()
        }
      }
    None => ()
  }
  // `with:` block that is an expression — prevents static analysis.
  match step.raw.get("with") {
    Some(String(s)) => {
      let t = s.trim(chars=" \t\r\n").to_owned()
      if t.has_prefix("${{") && t.has_suffix("}}") {
        add_diag(
          out,
          "obfuscation",
          Info,
          "use of an expression for `with:` prevents analysis",
        )
      }
    }
    _ => ()
  }
  // Expressions in `if:` / `run:` text.
  match step.if_cond {
    Some(c) =>
      if text_has_reducible_expression(c) {
        add_diag(
          out,
          "obfuscation",
          Info,
          "`if:` expression can be replaced by its static evaluation",
        )
      }
    None => ()
  }
  match step.run {
    Some(r) => {
      if text_has_reducible_expression(r) {
        add_diag(
          out,
          "obfuscation",
          Info,
          "expression can be replaced by its static evaluation",
        )
      }
      if text_has_computed_index(r) {
        add_diag(out, "obfuscation", Info, "index expression is computed")
      }
    }
    None => ()
  }
  // Computed indices can also appear in `if:`.
  match step.if_cond {
    Some(c) =>
      if text_has_computed_index(c) {
        add_diag(out, "obfuscation", Info, "index expression is computed")
      }
    None => ()
  }
}

///|
fn check_obfuscation_job(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  match job.if_cond {
    Some(c) => {
      if text_has_reducible_expression(c) {
        add_diag(
          out,
          "obfuscation",
          Info,
          "`if:` expression can be replaced by its static evaluation",
        )
      }
      if text_has_computed_index(c) {
        add_diag(out, "obfuscation", Info, "index expression is computed")
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
  ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  match step.uses {
    Some(u) => {
      // Static fallback list for offline / no-context runs.
      // tj-actions/* was retroactively compromised in March 2025.
      let static_hit = u.has_prefix("tj-actions/changed-files@") ||
        u.has_prefix("tj-actions/branch-names@") ||
        u.has_prefix("tj-actions/eslint-changed-files@") ||
        u.has_prefix("reviewdog/action-setup@v1.0.0") ||
        u.has_prefix("reviewdog/action-setup@v1.0.1") ||
        u.has_prefix("reviewdog/action-setup@v1.0.2") ||
        u.has_prefix("reviewdog/action-setup@v1.0.3") ||
        u.has_prefix("reviewdog/action-setup@v1.1.0")
      let osv_hit = array_contains_string(ctx.vuln_uses, u)
      if static_hit || osv_hit {
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
    Some(r) =>
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
    None => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: invalid-env-var-name (actionlint)
// ---------------------------------------------------------------------------

///|
fn check_invalid_env_var_name(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
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
    Some(u) => if s.at_idx > 0 { Some(u[:s.at_idx].to_owned()) } else { None }
    None => None
  }
}

///|
fn superfluous_action_replacement(name : String) -> String? {
  // Mirror upstream zizmor SUPERFLUOUS_ACTIONS catalogue (v1.25.2).
  if name == "ncipollo/release-action" ||
    name == "softprops/action-gh-release" ||
    name == "elgohr/Github-Release-Action" {
    Some("use `gh release` in a script step")
  } else if name == "peter-evans/create-pull-request" {
    Some("use `gh pr create` in a script step")
  } else if name == "peter-evans/create-or-update-comment" {
    Some("use `gh pr comment` or `gh issue comment` in a script step")
  } else if name == "dacbd/create-issue-action" {
    Some("use `gh issue create` in a script step")
  } else if name == "actions-ecosystem/action-add-labels" {
    Some(
      "use `gh issue edit --add-label` or `gh pr edit --add-label` in a script step",
    )
  } else if name == "actions-ecosystem/action-remove-labels" {
    Some(
      "use `gh issue edit --remove-label` or `gh pr edit --remove-label` in a script step",
    )
  } else if name == "svenstaro/upload-release-action" {
    Some("use `gh release create` and `gh release upload` in a script step")
  } else if name == "addnab/docker-run-action" {
    Some("use `docker run` in a script step, or use a container step")
  } else if name == "sergeysova/jq-action" {
    Some("use `jq` in a script step")
  } else if name == "dtolnay/rust-toolchain" {
    Some("use `rustup` and/or `cargo` in a script step")
  } else if name == "stefanzweifel/git-auto-commit-action" ||
    name == "EndBug/add-and-commit" {
    Some("use `git add`, `git commit`, and `git push` in a script step")
  } else {
    None
  }
}

///|
fn check_superfluous_actions(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  for s in job.steps {
    match step_repo_prefix(s) {
      Some(prefix) =>
        match superfluous_action_replacement(prefix) {
          Some(hint) =>
            add_diag_step(
              out,
              "superfluous-actions",
              Info,
              "step uses `\{prefix}` — \{hint}",
              s,
            )
          None => ()
        }
      None => ()
    }
  }
}

///|
fn check_superfluous_actions_doc(
  ctx : WalkCtx,
  out : Array[Diagnostic],
) -> Unit {
  // Composite action steps reuse the same SUPERFLUOUS_ACTIONS catalogue upstream.
  for s in ctx.action_steps {
    match step_repo_prefix(s) {
      Some(prefix) =>
        match superfluous_action_replacement(prefix) {
          Some(hint) =>
            add_diag_step(
              out,
              "superfluous-actions",
              Info,
              "step uses `\{prefix}` — \{hint}",
              s,
            )
          None => ()
        }
      None => ()
    }
  }
}

// ---------------------------------------------------------------------------
// Rule: template-injection (zizmor + actionlint script-injection)
//
// Upstream's pedantic-mode behaviour boils down to: for every `${{ … }}`
// expression that lands inside a `run:` script or a step `with:` input,
// emit at least one finding. High-cap contexts (e.g.
// `github.event.pull_request.title`) get the "untrusted … interpolated"
// Error; everything else falls through to the pedantic "backstop" Info
// ("any expression in a code context is a code smell"). karinto runs as
// the pedantic-equivalent, so we emit both tiers.
// ---------------------------------------------------------------------------

///|
/// Curated High-cap context patterns: substrings whose presence inside a
/// `${{ … }}` span indicates attacker-controllable input. The list mirrors
/// the Arbitrary-cap entries in zizmor's compiled FST that actually show
/// up across the upstream fixture corpus.
fn untrusted_context_patterns() -> Array[String] {
  [
    "github.event.pull_request.body", "github.event.pull_request.title", "github.event.pull_request.head.ref",
    "github.event.pull_request.head.label", "github.event.pull_request.head.repo.description",
    "github.event.pull_request.head.repo.homepage", "github.event.issue.title", "github.event.issue.body",
    "github.event.comment.body", "github.event.review.body", "github.event.review_comment.body",
    "github.event.discussion.title", "github.event.discussion.body", "github.event.workflow_run.head_branch",
    "github.event.workflow_run.display_title", "github.event.workflow_run.head_commit.message",
    "github.event.commits.", "github.event.head_commit.message", "github.event.pages.",
    "github.head_ref", "github.event.changes.",
  ]
}

///|
fn find_untrusted_in_text(t : String) -> String? {
  if !t.contains("${{") {
    return None
  }
  for p in untrusted_context_patterns() {
    if t.contains(p) {
      return Some(p)
    }
  }
  None
}

///|
/// True if `t` contains at least one `${{ … }}` template expression. Used
/// as the pedantic-backstop trigger.
fn text_has_template_expression(t : String) -> Bool {
  t.contains("${{")
}

///|
/// Emit the appropriate template-injection finding(s) for one piece of
/// script-bearing text. Returns once per call site:
///
/// * High-cap match → `Error`, with the specific context echoed.
/// * Otherwise, presence of any `${{ … }}` → `Info` (pedantic backstop).
fn template_injection_emit(
  ctx : WalkCtx,
  step : StepInfo,
  field : String,
  text : String,
  scope_label : String,
  out : Array[Diagnostic],
) -> Unit {
  match find_untrusted_in_text(text) {
    Some(p) =>
      add_diag_step_field(
        out,
        ctx,
        "template-injection",
        Error,
        "untrusted `\{p}` interpolated into \{scope_label}",
        step,
        field,
      )
    None =>
      if text_has_template_expression(text) {
        add_diag_step_field(
          out,
          ctx,
          "template-injection",
          Info,
          "code injection via template expansion in \{scope_label}",
          step,
          field,
        )
      }
  }
}

///|
/// Map of action sink prefixes → list of `with:` input names whose value
/// reaches a script interpreter. Mirrors zizmor's hardcoded extras + a
/// curated subset of the CodeQL injection-sinks model covering every
/// known sink that appears in the upstream fixture corpus.
fn template_injection_sinks() -> Array[(String, Array[String])] {
  [
    ("actions/github-script", ["script"]),
    ("amadevus/pwsh-script", ["script"]),
    ("jannekem/run-python-script-action", ["script"]),
    ("cardinalby/js-eval-action", ["expression"]),
    ("addnab/docker-run-action", ["options", "run"]),
    ("azure/cli", ["inlineScript"]),
    ("azure/powershell", ["inlineScript"]),
    ("mikefarah/yq", ["cmd"]),
    ("tibdex/backport", ["title_template", "body_template"]),
  ]
}

///|
/// True if the step's `uses:` matches any registered sink, returning the
/// list of input names that reach a script interpreter.
fn step_template_sink_inputs(step : StepInfo) -> Array[String] {
  match step.uses {
    Some(u) => {
      // `uses:` form is `owner/repo[/subpath][@ref]`. Strip ref and
      // subpath before comparing — sinks key on the bare repo prefix.
      let bare = match u.find("@") {
        Some(i) => u[0:i].to_owned()
        None => u
      }
      let canonical = (match bare.find("/") {
        Some(i) =>
          match bare[i + 1:].find("/") {
            Some(j) => bare[0:i + 1 + j].to_owned()
            None => bare
          }
        None => bare
      }).to_lower()
      for sink in template_injection_sinks() {
        let prefix = sink.0
        let inputs = sink.1
        if canonical == prefix {
          return inputs
        }
      }
      []
    }
    None => []
  }
}

///|
fn check_template_injection(
  ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  match step.run {
    Some(r) =>
      template_injection_emit(ctx, step, "run", r, "`run:` script", out)
    None => ()
  }
  let sink_inputs = step_template_sink_inputs(step)
  if sink_inputs.length() == 0 {
    return
  }
  match step.with_ {
    Some(w) =>
      for name in sink_inputs {
        match w.get(name) {
          Some(String(s)) =>
            template_injection_emit(
              ctx,
              step,
              "with.\{name}",
              s,
              "`with.\{name}`",
              out,
            )
          _ => ()
        }
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
      if found {
        return true
      }
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
  if job.raw.contains("environment") {
    return
  }
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
/// Trigger kinds collected from a workflow's `on:` block; mirrors upstream
/// `ReleaseTrigger`. `has_release_branch` distinguishes a `push:branches`
/// pattern whose name contains the substring `"release"` (case-insensitive),
/// which suppresses the tag-push conditional heuristic.
priv struct CacheTriggers {
  has_tag_push : Bool
  has_release_event : Bool
  has_release_branch : Bool
}

///|
fn cache_triggers_empty(t : CacheTriggers) -> Bool {
  !t.has_tag_push && !t.has_release_event && !t.has_release_branch
}

///|
fn cache_triggers_all_tag_or_release(t : CacheTriggers) -> Bool {
  !cache_triggers_empty(t) && !t.has_release_branch
}

///|
fn branch_pattern_is_release(s : String) -> Bool {
  s.to_lower().contains("release")
}

///|
fn collect_cache_triggers(ctx : WalkCtx) -> CacheTriggers {
  let mut tag = false
  let mut rel = false
  let mut branch = false
  let m = match ctx.workflow_map {
    Some(m) => m
    None =>
      return CacheTriggers::{
        has_tag_push: false,
        has_release_event: false,
        has_release_branch: false,
      }
  }
  match m.get("on") {
    Some(String(s)) => if s == "release" { rel = true }
    Some(Array(arr)) =>
      for item in arr {
        match item {
          String(s) => if s == "release" { rel = true }
          _ => ()
        }
      }
    Some(Map(om)) =>
      om.each(fn(name, v) {
        if name == "release" {
          rel = true
        }
        if name == "push" {
          match v {
            Map(pm) => {
              if pm.contains("tags") {
                tag = true
              }
              match pm.get("branches") {
                Some(String(s)) =>
                  if branch_pattern_is_release(s) {
                    branch = true
                  }
                Some(Array(b)) =>
                  for it in b {
                    match it {
                      String(s) =>
                        if branch_pattern_is_release(s) {
                          branch = true
                        }
                      _ => ()
                    }
                  }
                _ => ()
              }
            }
            _ => ()
          }
        }
      })
    _ => ()
  }
  CacheTriggers::{
    has_tag_push: tag,
    has_release_event: rel,
    has_release_branch: branch,
  }
}

///|
/// True if `uses` matches one of the curated publisher actions used by
/// upstream zizmor to mark a job as "publishing artifacts at runtime".
/// Comparison strips the `@ref` suffix and is case-insensitive.
fn cache_uses_is_publisher(u : String) -> Bool {
  let lo = u.to_lower()
  let prefixes = [
    "pypa/gh-action-pypi-publish", "rubygems/release-gem", "jreleaser/release-action",
    "goreleaser/goreleaser-action", "softprops/action-gh-release", "release-drafter/release-drafter",
    "googleapis/release-please-action", "redhat-actions/push-to-registry", "aws-actions/amazon-ecs-deploy-task-definition",
    "aws-actions/aws-cloudformation-github-deploy", "azure/aci-deploy", "azure/container-apps-deploy-action",
    "azure/functions-action", "azure/sql-action", "cloudflare/wrangler-action", "google-github-actions/deploy-appengine",
    "google-github-actions/deploy-cloudrun", "google-github-actions/deploy-cloud-functions",
  ]
  for p in prefixes {
    if lo.has_prefix(p + "@") || lo.has_prefix(p + "/") {
      return true
    }
  }
  false
}

///|
fn step_is_publisher_step(s : StepInfo) -> Bool {
  match s.uses {
    Some(u) => {
      if cache_uses_is_publisher(u) {
        return true
      }
      let lo = u.to_lower()
      if lo.has_prefix("docker/build-push-action@") ||
        lo.has_prefix("docker/build-push-action/") {
        // Upstream: ControlExpr::single(Toggle::OptIn, "push", Boolean, true) —
        // the 4th arg is `default_satisfied`, so when `push:` is absent the
        // step is still treated as publishing. Only an explicit `push: false`
        // (literal bool or stringy "false") clears it.
        match s.with_ {
          Some(w) =>
            match w.get("push") {
              Some(Boolean(false)) => false
              Some(String(s)) => s.to_lower() != "false"
              _ => true
            }
          _ => true
        }
      } else {
        false
      }
    }
    None => false
  }
}

///|
fn job_has_publisher_step(j : JobInfo) -> Bool {
  for s in j.steps {
    if step_is_publisher_step(s) {
      return true
    }
  }
  false
}

///|
/// Per-step classification: NotSatisfied means no cache is in use.
/// Satisfied means the step caches unconditionally (Always /
/// DefaultBehaviour / DirectOptIn). Conditional carries an optional
/// "would-enable-under-tag-push" result of evaluating the control
/// expression — `Some(true)` means tag-push would still cache,
/// `Some(false)` means it would not, `None` means uncertain.
priv enum CacheStep {
  CacheNotSatisfied
  CacheSatisfied
  CacheConditional(Bool?)
}

///|
fn expr_to_string(value : @yaml.Yaml) -> String {
  match value {
    String(s) => s
    Boolean(true) => "true"
    Boolean(false) => "false"
    Integer(n) => n.to_string()
    _ => ""
  }
}

///|
/// Evaluate `${{ ... }}` under the assumption that the workflow is
/// running under a tag-push (so `startsWith(github.ref, 'refs/tags/')`
/// is true). Returns Some(b) for definitive results, None for anything
/// the recogniser doesn't understand.
fn eval_tag_push_expr(raw : String) -> Bool? {
  let trimmed = raw.trim(chars=" \t\n\r").to_owned()
  if !trimmed.has_prefix("${{") || !trimmed.has_suffix("}}") {
    return None
  }
  let inner = trimmed[3:trimmed.length() - 2].trim(chars=" \t\n\r").to_owned()
  eval_tag_push_inner(inner)
}

///|
fn eval_tag_push_inner(s : String) -> Bool? {
  let t = s.trim(chars=" \t\n\r").to_owned()
  if t == "true" {
    return Some(true)
  }
  if t == "false" {
    return Some(false)
  }
  if t.has_prefix("!") {
    match eval_tag_push_inner(t[1:].to_owned()) {
      Some(b) => return Some(!b)
      None => return None
    }
  }
  // Match `startsWith(github.ref, 'refs/tags/')` permissively
  // (any whitespace, single or double quotes).
  let lo = t.to_lower()
  if lo.has_prefix("startswith(") &&
    lo.contains("github.ref") &&
    (lo.contains("'refs/tags/'") || lo.contains("\"refs/tags/\"")) {
    return Some(true)
  }
  None
}

///|
fn classify_boolean_optin(
  with_ : Map[String, @yaml.Yaml]?,
  field : String,
  satisfied_by_default : Bool,
) -> CacheStep {
  match with_ {
    None =>
      if satisfied_by_default {
        CacheSatisfied
      } else {
        CacheNotSatisfied
      }
    Some(w) =>
      match w.get(field) {
        None =>
          if satisfied_by_default {
            CacheSatisfied
          } else {
            CacheNotSatisfied
          }
        Some(Boolean(true)) => CacheSatisfied
        Some(Boolean(false)) => CacheNotSatisfied
        Some(String(s)) => {
          let lo = s.to_lower()
          if lo == "false" {
            CacheNotSatisfied
          } else if s.has_prefix("${{") {
            CacheConditional(eval_tag_push_expr(s))
          } else if lo == "" {
            if satisfied_by_default {
              CacheSatisfied
            } else {
              CacheNotSatisfied
            }
          } else {
            // boolish (any non-false, non-templated string)
            CacheSatisfied
          }
        }
        _ =>
          if satisfied_by_default {
            CacheSatisfied
          } else {
            CacheNotSatisfied
          }
      }
  }
}

///|
fn classify_boolean_optout(
  with_ : Map[String, @yaml.Yaml]?,
  field : String,
  satisfied_by_default : Bool,
) -> CacheStep {
  // OptOut Boolean: field=true → cache off, field=false → cache on.
  match with_ {
    None =>
      if satisfied_by_default {
        CacheSatisfied
      } else {
        CacheNotSatisfied
      }
    Some(w) =>
      match w.get(field) {
        None =>
          if satisfied_by_default {
            CacheSatisfied
          } else {
            CacheNotSatisfied
          }
        Some(Boolean(true)) => CacheNotSatisfied
        Some(Boolean(false)) => CacheSatisfied
        Some(String(s)) => {
          let lo = s.to_lower()
          if lo == "false" {
            CacheSatisfied
          } else if s.has_prefix("${{") {
            // For OptOut Boolean: cache-enabled iff expr-result is false.
            let r = eval_tag_push_expr(s)
            let would_enable = match r {
              Some(b) => Some(!b)
              None => None
            }
            CacheConditional(would_enable)
          } else if lo == "" {
            if satisfied_by_default {
              CacheSatisfied
            } else {
              CacheNotSatisfied
            }
          } else {
            // boolish non-false string → cache off
            CacheNotSatisfied
          }
        }
        _ =>
          if satisfied_by_default {
            CacheSatisfied
          } else {
            CacheNotSatisfied
          }
      }
  }
}

///|
fn classify_freestring_optin(
  with_ : Map[String, @yaml.Yaml]?,
  field : String,
  satisfied_by_default : Bool,
) -> CacheStep {
  match with_ {
    None =>
      if satisfied_by_default {
        CacheSatisfied
      } else {
        CacheNotSatisfied
      }
    Some(w) =>
      match w.get(field) {
        None =>
          if satisfied_by_default {
            CacheSatisfied
          } else {
            CacheNotSatisfied
          }
        Some(String(s)) =>
          if s == "" {
            if satisfied_by_default {
              CacheSatisfied
            } else {
              CacheNotSatisfied
            }
          } else if s.has_prefix("${{") {
            CacheConditional(None)
          } else {
            CacheSatisfied
          }
        Some(Null) =>
          if satisfied_by_default {
            CacheSatisfied
          } else {
            CacheNotSatisfied
          }
        Some(Boolean(_)) => CacheSatisfied
        Some(_) => CacheSatisfied
      }
  }
}

///|
fn classify_exact_optin(
  with_ : Map[String, @yaml.Yaml]?,
  field : String,
  allowed : Array[String],
) -> CacheStep {
  match with_ {
    None => CacheNotSatisfied
    Some(w) =>
      match w.get(field) {
        None => CacheNotSatisfied
        Some(String(s)) =>
          if s.has_prefix("${{") {
            CacheConditional(None)
          } else {
            let lo = s.to_lower()
            let mut matched = false
            for a in allowed {
              if a.to_lower() == lo {
                matched = true
              }
            }
            if matched {
              CacheSatisfied
            } else {
              CacheNotSatisfied
            }
          }
        _ => CacheNotSatisfied
      }
  }
}

///|
fn classify_exact_optout(
  with_ : Map[String, @yaml.Yaml]?,
  field : String,
  allowed : Array[String],
  satisfied_by_default : Bool,
) -> CacheStep {
  // OptOut Exact: value in allowed list → cache off, else cache on.
  match with_ {
    None =>
      if satisfied_by_default {
        CacheSatisfied
      } else {
        CacheNotSatisfied
      }
    Some(w) =>
      match w.get(field) {
        None =>
          if satisfied_by_default {
            CacheSatisfied
          } else {
            CacheNotSatisfied
          }
        Some(String(s)) =>
          if s.has_prefix("${{") {
            CacheConditional(None)
          } else {
            let lo = s.to_lower()
            let mut matched = false
            for a in allowed {
              if a.to_lower() == lo {
                matched = true
              }
            }
            if matched {
              CacheNotSatisfied
            } else {
              CacheSatisfied
            }
          }
        Some(v) => {
          let coerced = expr_to_string(v).to_lower()
          let mut matched = false
          for a in allowed {
            if a.to_lower() == coerced {
              matched = true
            }
          }
          if matched {
            CacheNotSatisfied
          } else {
            CacheSatisfied
          }
        }
      }
  }
}

///|
fn cache_step_and(a : CacheStep, b : CacheStep) -> CacheStep {
  match (a, b) {
    (CacheNotSatisfied, _) | (_, CacheNotSatisfied) => CacheNotSatisfied
    (CacheConditional(x), CacheConditional(y)) =>
      match (x, y) {
        (Some(false), _) | (_, Some(false)) => CacheConditional(Some(false))
        (Some(true), Some(true)) => CacheConditional(Some(true))
        _ => CacheConditional(None)
      }
    (CacheConditional(x), _) | (_, CacheConditional(x)) => CacheConditional(x)
    _ => CacheSatisfied
  }
}

///|
fn cache_step_or(a : CacheStep, b : CacheStep) -> CacheStep {
  match (a, b) {
    (CacheSatisfied, _) | (_, CacheSatisfied) => CacheSatisfied
    (CacheConditional(x), CacheConditional(y)) =>
      match (x, y) {
        (Some(true), _) | (_, Some(true)) => CacheConditional(Some(true))
        (Some(false), Some(false)) => CacheConditional(Some(false))
        _ => CacheConditional(None)
      }
    (CacheConditional(x), _) | (_, CacheConditional(x)) => CacheConditional(x)
    _ => CacheNotSatisfied
  }
}

///|
fn classify_cache_aware_step(s : StepInfo) -> CacheStep {
  let u = match s.uses {
    Some(u) => u
    None => return CacheNotSatisfied
  }
  // Strip ref before matching.
  let bare = if s.at_idx >= 0 { u[0:s.at_idx].to_lower() } else { u.to_lower() }
  if bare == "actions/cache" || bare == "actions/cache/restore" {
    return classify_boolean_optout(s.with_, "lookup-only", true)
  }
  if bare == "actions/setup-java" {
    return classify_freestring_optin(s.with_, "cache", false)
  }
  if bare == "actions/setup-go" {
    return classify_boolean_optin(s.with_, "cache", true)
  }
  if bare == "actions/setup-node" {
    let c1 = classify_exact_optin(s.with_, "cache", ["npm", "yarn", "pnpm"])
    let c2 = classify_boolean_optin(s.with_, "package-manager-cache", true)
    return cache_step_or(c1, c2)
  }
  if bare == "actions/setup-python" {
    return classify_freestring_optin(s.with_, "cache", false)
  }
  if bare == "actions/setup-dotnet" {
    return classify_boolean_optin(s.with_, "cache", false)
  }
  if bare == "astral-sh/setup-uv" {
    return classify_boolean_optin(s.with_, "enable-cache", true)
  }
  if bare == "swatinem/rust-cache" {
    return classify_boolean_optout(s.with_, "lookup-only", true)
  }
  if bare == "ruby/setup-ruby" {
    return classify_boolean_optin(s.with_, "bundler-cache", false)
  }
  if bare == "pyo3/maturin-action" {
    return classify_boolean_optin(s.with_, "sccache", false)
  }
  if bare == "mlugg/setup-zig" {
    return classify_boolean_optin(s.with_, "use-cache", true)
  }
  if bare == "oven-sh/setup-bun" {
    return classify_boolean_optout(s.with_, "no-cache", true)
  }
  if bare == "determinatesystems/magic-nix-cache-action" {
    return classify_boolean_optin(s.with_, "use-gha-cache", true)
  }
  if bare == "graalvm/setup-graalvm" {
    return classify_freestring_optin(s.with_, "cache", false)
  }
  if bare == "gradle/actions/setup-gradle" {
    return classify_boolean_optout(s.with_, "cache-disabled", true)
  }
  if bare == "docker/setup-buildx-action" {
    let c1 = classify_boolean_optin(s.with_, "cache-binary", true)
    let c2 = classify_freestring_optin(s.with_, "version", false)
    return cache_step_and(c1, c2)
  }
  if bare == "actions-rust-lang/setup-rust-toolchain" {
    return classify_boolean_optin(s.with_, "cache", true)
  }
  if bare == "mozilla-actions/sccache-action" {
    return CacheSatisfied
  }
  if bare == "nix-community/cache-nix-action" {
    return CacheSatisfied
  }
  if bare == "jdx/mise-action" {
    return classify_boolean_optin(s.with_, "cache", true)
  }
  if bare == "ramsey/composer-install" {
    return classify_exact_optout(
      s.with_,
      "ignore-cache",
      ["yes", "true", "1"],
      true,
    )
  }
  if bare == "awalsh128/cache-apt-pkgs-action" {
    return CacheSatisfied
  }
  CacheNotSatisfied
}

///|
/// Decide whether a step's `CacheStep` value should produce a finding,
/// given the workflow's collected triggers. Conditional findings can be
/// suppressed (or upgraded) when the trigger set is purely tag/release.
fn cache_step_should_emit(triggers : CacheTriggers, step : CacheStep) -> Bool {
  match step {
    CacheNotSatisfied => false
    CacheSatisfied => true
    CacheConditional(would_enable) =>
      if cache_triggers_all_tag_or_release(triggers) {
        match would_enable {
          Some(false) => false // tag-push would disable caching → silenced
          _ => true // Some(true) → upgraded to DirectOptIn; None → uncertain
        }
      } else {
        true // no heuristic when a release-branch trigger is present
      }
  }
}

///|
fn check_cache_poisoning(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  let triggers = collect_cache_triggers(ctx)
  let workflow_publishing = !cache_triggers_empty(triggers)
  for j in ctx.jobs {
    let job_publishing = workflow_publishing || job_has_publisher_step(j)
    if !job_publishing {
      continue
    }
    for s in j.steps {
      let usage = classify_cache_aware_step(s)
      if cache_step_should_emit(triggers, usage) {
        add_diag(
          out,
          "cache-poisoning",
          Error,
          "runtime artifacts potentially vulnerable to a cache poisoning attack",
        )
        return
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Rule: unpinned-tools (zizmor)
// ---------------------------------------------------------------------------

///|
fn run_has_pipe_to_shell(r : String) -> Bool {
  let has_fetch = r.contains("curl ") || r.contains("wget ")
  if !has_fetch {
    return false
  }
  r.contains("| bash") ||
  r.contains("|bash") ||
  r.contains("| sh") ||
  r.contains("|sh") ||
  r.contains("| zsh") ||
  r.contains("|zsh")
}

///|
/// Returns the canonical owner/name (lower-cased, no `@ref`, no path
/// segments) of a tool-installer action that downloads a versioned tool
/// at runtime. The list below matches zizmor's curated catalogue.
fn tool_installer_action(uses : String) -> String? {
  let lo = uses.to_lower()
  let bare = bare_repo_of(lo)
  let known = ["aquasecurity/setup-trivy", "1password/load-secrets-action"]
  for k in known {
    if bare == k {
      return Some(k)
    }
  }
  None
}

///|
fn check_unpinned_tools(
  ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  match step.run {
    Some(r) =>
      if run_has_pipe_to_shell(r) {
        add_diag_step_field(
          out,
          ctx,
          "unpinned-tools",
          Warning,
          "run step fetches and executes an external script without pinning",
          step,
          "run",
        )
        return
      }
    None => ()
  }
  // Known tool-installer actions: flag implicit-latest (`with:` missing or
  // omits `version:`), explicit `version: latest`, and expression-based
  // versions that resolve at workflow-trigger time.
  match step.uses {
    Some(u) =>
      match tool_installer_action(u) {
        Some(name) => {
          let kind = match step.raw.get("with") {
            Some(Map(w)) =>
              match w.get("version") {
                Some(String(v)) => {
                  let lo = v.to_lower()
                  if lo == "latest" {
                    "explicit-latest"
                  } else if v.contains("${{") {
                    "dynamic"
                  } else {
                    "pinned"
                  }
                }
                Some(_) => "pinned"
                None => "implicit-latest"
              }
            _ => "implicit-latest"
          }
          let msg = match kind {
            "implicit-latest" =>
              "`\{name}` defaults to the latest tool version; pin via `with.version`"
            "explicit-latest" =>
              "`\{name}` is invoked with `version: latest`; pin to a specific version"
            "dynamic" =>
              "`\{name}` resolves `version` from an expression; pin to a literal version"
            _ => ""
          }
          if msg.length() > 0 {
            add_diag_step_field(
              out,
              ctx,
              "unpinned-tools",
              Warning,
              msg,
              step,
              "uses",
            )
          }
        }
        None => ()
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
      add_diag_job(
        out,
        "job-step-id-naming",
        Warning,
        "job ID `\{j.name}` must match `[A-Za-z_][A-Za-z0-9_-]*`",
        j.name,
      )
    }
    for s in j.steps {
      match s.raw.get("id") {
        Some(String(id)) =>
          if !is_valid_id(id) {
            add_diag_step(
              out,
              "job-step-id-naming",
              Warning,
              "step ID `\{id}` must match `[A-Za-z_][A-Za-z0-9_-]*`",
              s,
            )
          }
        _ => ()
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers shared across the HIGH/MEDIUM rule batch
// ---------------------------------------------------------------------------

///|
/// Visit every String leaf in a YAML tree.
fn walk_strings(y : @yaml.Yaml, f : (String) -> Unit) -> Unit {
  match y {
    String(s) => f(s)
    Array(arr) =>
      for v in arr {
        walk_strings(v, f)
      }
    Map(m) => m.each(fn(_k, v) { walk_strings(v, f) })
    _ => ()
  }
}

///|
/// Count non-overlapping substring occurrences.
fn count_substr(s : String, sub : String) -> Int {
  let sa = s.to_array()
  let ba = sub.to_array()
  let sl = sa.length()
  let subl = ba.length()
  if subl == 0 || sl < subl {
    return 0
  }
  let mut count = 0
  let mut i = 0
  while i <= sl - subl {
    let mut j = 0
    let mut ok = true
    while j < subl {
      if sa[i + j] != ba[j] {
        ok = false
        break
      }
      j = j + 1
    }
    if ok {
      count = count + 1
      i = i + subl
    } else {
      i = i + 1
    }
  }
  count
}

///|
/// Levenshtein distance, capped early.
fn edit_distance(a : String, b : String) -> Int {
  let la = a.length()
  let lb = b.length()
  if la == 0 {
    return lb
  }
  if lb == 0 {
    return la
  }
  let aa = a.to_array()
  let bb = b.to_array()
  let prev : Array[Int] = []
  let mut idx = 0
  while idx <= lb {
    prev.push(idx)
    idx = idx + 1
  }
  let curr : Array[Int] = []
  idx = 0
  while idx <= lb {
    curr.push(0)
    idx = idx + 1
  }
  let mut i = 1
  while i <= la {
    curr[0] = i
    let mut row_min = i
    let mut j = 1
    while j <= lb {
      let cost = if aa[i - 1] == bb[j - 1] { 0 } else { 1 }
      let del = prev[j] + 1
      let ins = curr[j - 1] + 1
      let sub_cost = prev[j - 1] + cost
      let m1 = if del < ins { del } else { ins }
      let best = if m1 < sub_cost { m1 } else { sub_cost }
      curr[j] = best
      if best < row_min {
        row_min = best
      }
      j = j + 1
    }
    if row_min > 4 {
      return 5
    }
    let mut k = 0
    while k <= lb {
      prev[k] = curr[k]
      k = k + 1
    }
    i = i + 1
  }
  prev[lb]
}

///|
fn suggest(word : String, candidates : Array[String]) -> String? {
  let mut best : String? = None
  let mut best_d = 3
  for c in candidates {
    let d = edit_distance(word, c)
    if d < best_d {
      best_d = d
      best = Some(c)
    }
  }
  best
}

///|
fn array_contains_string(arr : Array[String], target : String) -> Bool {
  for s in arr {
    if s == target {
      return true
    }
  }
  false
}

// ---------------------------------------------------------------------------
// Rule: missing-required-keys (actionlint)
// ---------------------------------------------------------------------------

///|
fn check_missing_required_keys(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  match ctx.workflow_map {
    Some(m) => {
      // Trust the resolved file kind when caller supplied one; otherwise
      // fall back to the structural cue (presence of `runs:`).
      let is_action = match ctx.kind {
        Action => true
        Workflow => false
        _ => m.contains("runs")
      }
      if is_action {
        // `runs:` itself is covered by `action-yml-metadata`; here we only
        // check the nested `runs.using` requirement when `runs:` exists.
        match m.get("runs") {
          Some(Map(runs)) =>
            if !runs.contains("using") {
              add_diag(
                out,
                "missing-required-keys",
                Error,
                "action is missing required key `runs.using`",
              )
            }
          _ => ()
        }
      } else {
        if !m.contains("on") {
          add_diag(
            out,
            "missing-required-keys",
            Error,
            "workflow is missing required key `on`",
          )
        }
        if !m.contains("jobs") {
          add_diag(
            out,
            "missing-required-keys",
            Error,
            "workflow is missing required key `jobs`",
          )
        }
      }
    }
    None => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: webhook-events (actionlint)
// ---------------------------------------------------------------------------

///|
fn known_events() -> Array[String] {
  [
    "branch_protection_rule", "check_run", "check_suite", "create", "delete", "deployment",
    "deployment_status", "discussion", "discussion_comment", "fork", "gollum", "issue_comment",
    "issues", "label", "merge_group", "milestone", "page_build", "project", "project_card",
    "project_column", "public", "pull_request", "pull_request_review", "pull_request_review_comment",
    "pull_request_target", "push", "registry_package", "release", "repository_dispatch",
    "schedule", "status", "watch", "workflow_call", "workflow_dispatch", "workflow_run",
  ]
}

///|
fn emit_unknown_event(
  e : String,
  events : Array[String],
  out : Array[Diagnostic],
) -> Unit {
  let msg = match suggest(e, events) {
    Some(s) => "unknown webhook event `\{e}` (did you mean `\{s}`?)"
    None => "unknown webhook event `\{e}`"
  }
  add_diag(out, "webhook-events", Error, msg)
}

///|
fn check_webhook_events(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  let m = match ctx.workflow_map {
    Some(m) => m
    None => return
  }
  let events = known_events()
  match m.get("on") {
    Some(String(e)) =>
      if !array_contains_string(events, e) {
        emit_unknown_event(e, events, out)
      }
    Some(Array(arr)) =>
      for v in arr {
        match v {
          String(e) =>
            if !array_contains_string(events, e) {
              emit_unknown_event(e, events, out)
            }
          _ => ()
        }
      }
    Some(Map(om)) =>
      om.each(fn(k, _) {
        if !array_contains_string(events, k) {
          emit_unknown_event(k, events, out)
        }
      })
    _ => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: job-needs-graph (actionlint)
// ---------------------------------------------------------------------------

///|
fn check_job_needs_graph(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  let names : Map[String, Bool] = {}
  for j in ctx.jobs {
    names[j.name] = true
  }
  for j in ctx.jobs {
    match j.raw.get("needs") {
      Some(String(n)) =>
        if !names.contains(n) {
          add_diag(
            out,
            "job-needs-graph",
            Error,
            "job `\{j.name}` needs undefined job `\{n}`",
          )
        }
      Some(Array(arr)) =>
        for v in arr {
          match v {
            String(n) =>
              if !names.contains(n) {
                add_diag(
                  out,
                  "job-needs-graph",
                  Error,
                  "job `\{j.name}` needs undefined job `\{n}`",
                )
              }
            _ => ()
          }
        }
      _ => ()
    }
  }
}

// ---------------------------------------------------------------------------
// Rule: expression-syntax (actionlint)
// ---------------------------------------------------------------------------

///|
fn check_expression_syntax(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  let reported = { "unterminated": false, "stray": false }
  walk_strings(ctx.doc, fn(s) {
    if !s.contains("${{") && !s.contains("}}") {
      return
    }
    let opens = count_substr(s, "${{")
    let closes = count_substr(s, "}}")
    if opens > closes && !reported.get("unterminated").unwrap() {
      reported["unterminated"] = true
      add_diag(
        out,
        "expression-syntax",
        Error,
        "expression syntax error: unterminated `${{`",
      )
    } else if closes > opens && !reported.get("stray").unwrap() {
      reported["stray"] = true
      add_diag(
        out,
        "expression-syntax",
        Error,
        "expression syntax error: stray `}}`",
      )
    }
  })
}

// ---------------------------------------------------------------------------
// Rule: unknown-context-or-function (actionlint)
// ---------------------------------------------------------------------------

///|
fn known_contexts() -> Array[String] {
  [
    "github", "env", "vars", "secrets", "inputs", "needs", "steps", "job", "jobs",
    "runner", "matrix", "strategy",
  ]
}

///|
fn check_unknown_context(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  let contexts = known_contexts()
  let seen : Map[String, Bool] = {}
  walk_strings(ctx.doc, fn(s) {
    if !s.contains("${{") {
      return
    }
    let chars = s.to_array()
    let n = chars.length()
    let mut i = 0
    while i + 2 < n {
      if chars[i] == '$' && chars[i + 1] == '{' && chars[i + 2] == '{' {
        i = i + 3
        let mut prev_dot = false
        while i + 1 < n && !(chars[i] == '}' && chars[i + 1] == '}') {
          let c = chars[i]
          if c == '.' {
            prev_dot = true
            i = i + 1
          } else if c == ' ' || c == '\t' || c == '\n' {
            i = i + 1
          } else if is_ident_start(c) {
            let start = i
            while i < n && is_ident_cont(chars[i]) {
              i = i + 1
            }
            if !prev_dot {
              let buf = StringBuilder::new()
              let mut k = start
              while k < i {
                buf.write_char(chars[k])
                k = k + 1
              }
              let ident = buf.to_string()
              let mut j = i
              while j < n && chars[j] == ' ' {
                j = j + 1
              }
              if j < n && chars[j] == '.' {
                if !array_contains_string(contexts, ident) &&
                  !seen.contains(ident) {
                  seen[ident] = true
                  let msg = match suggest(ident, contexts) {
                    Some(c2) =>
                      "unknown context `\{ident}` (did you mean `\{c2}`?)"
                    None => "unknown context `\{ident}`"
                  }
                  add_diag(out, "unknown-context-or-function", Error, msg)
                }
              }
            }
            prev_dot = false
          } else {
            prev_dot = false
            i = i + 1
          }
        }
        if i + 1 < n {
          i = i + 2
        } else {
          i = n
        }
      } else {
        i = i + 1
      }
    }
  })
}

// ---------------------------------------------------------------------------
// Rule: github-env (zizmor)
// ---------------------------------------------------------------------------

///|
/// True when the workflow's `on:` block includes `pull_request_target` or
/// `workflow_run` — the privileged-trigger context under which writes to
/// `$GITHUB_ENV` / `$GITHUB_PATH` become an arbitrary-code-execution sink.
fn workflow_has_dangerous_trigger(ctx : WalkCtx) -> Bool {
  let m = match ctx.workflow_map {
    Some(m) => m
    None => return false
  }
  match m.get("on") {
    Some(String(s)) => is_dangerous_trigger(s)
    Some(Array(arr)) => {
      for item in arr {
        match item {
          String(s) => if is_dangerous_trigger(s) { return true }
          _ => ()
        }
      }
      false
    }
    Some(Map(om)) => {
      let mut hit = false
      om.each(fn(name, _) { if is_dangerous_trigger(name) { hit = true } })
      hit
    }
    _ => false
  }
}

///|
/// Heuristic "non-literal" check for the LHS of a `>>` redirect to
/// `GITHUB_ENV`/`GITHUB_PATH`. Matches any shell variable, `$(...)`,
/// command-substitution backticks, cmd-style `%var%`, or `${{ ... }}`
/// expression. Single-quoted regions stay literal in bash, so `$` and
/// backticks inside them are ignored — `echo '$HOME' >> $GITHUB_ENV`
/// is a static write. Static-only writes (e.g. `echo foo=bar >> $GITHUB_ENV`)
/// stay silent, matching upstream `bash_echo_arg_is_safe`.
fn lhs_has_dynamic_token(lhs : String) -> Bool {
  let chars = lhs.to_array()
  let n = chars.length()
  let mut i = 0
  let mut in_single = false
  let mut in_double = false
  while i < n {
    let ch = chars[i]
    if !in_double && ch == '\'' {
      in_single = !in_single
      i = i + 1
      continue
    }
    if !in_single && ch == '"' {
      in_double = !in_double
      i = i + 1
      continue
    }
    if !in_single {
      // Outside single-quotes: bash `$VAR` / `${VAR}` / `$(...)`,
      // pwsh `$env:...`, the template expression `${{ ... }}`, or a
      // command-substitution backtick — every one is dynamic.
      if ch == '$' || ch == '`' {
        return true
      }
    }
    i = i + 1
  }
  // cmd `%VAR%` is unaffected by shell quoting (cmd doesn't use single quotes
  // the same way); fall back to counting `%` occurrences.
  let mut pct_count = 0
  for part in lhs.split("%") {
    let _ = part
    pct_count = pct_count + 1
  }
  if pct_count >= 3 {
    return true
  }
  false
}

///|
/// Matches the three syntactic forms upstream recognises for a redirect to
/// `GITHUB_ENV` / `GITHUB_PATH`:
///   * bash       `>> $GITHUB_ENV` or `>> ${GITHUB_ENV}`
///   * powershell `>> $env:GITHUB_ENV` or `>> ${env:GITHUB_ENV}` (case-insensitive)
///   * cmd        `>> %GITHUB_ENV%`
/// Returns the (label, target) on first hit per line, else None.
fn detect_github_env_redirect(line : String) -> (String, String)? {
  let lo = line.to_lower()
  let pairs = [
    ("$github_env", "GITHUB_ENV"),
    ("${github_env}", "GITHUB_ENV"),
    ("$env:github_env", "GITHUB_ENV"),
    ("${env:github_env}", "GITHUB_ENV"),
    ("%github_env%", "GITHUB_ENV"),
    ("$github_path", "GITHUB_PATH"),
    ("${github_path}", "GITHUB_PATH"),
    ("$env:github_path", "GITHUB_PATH"),
    ("${env:github_path}", "GITHUB_PATH"),
    ("%github_path%", "GITHUB_PATH"),
  ]
  for entry in pairs {
    let (needle, target) = entry
    match lo.find(needle) {
      Some(_) => return Some((needle, target))
      None => ()
    }
  }
  None
}

///|
fn check_github_env(
  ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  let run = match step.run {
    Some(r) => r
    None => return
  }
  // Workflow steps require a dangerous trigger; composite-action steps
  // are checked unconditionally — they may be invoked from any caller
  // workflow, including one with `pull_request_target`.
  if !ctx.action_is_composite && !workflow_has_dangerous_trigger(ctx) {
    return
  }
  // Walk by line; for each redirect to GITHUB_ENV/GITHUB_PATH, fire when
  // the LHS contains any non-literal token (variable/cmd-sub/template).
  let lines = run.split("\n")
  for ln in lines {
    let line = ln.to_owned()
    // Only care about lines that include `>>`.
    if !line.contains(">>") {
      continue
    }
    let (_, target) = match detect_github_env_redirect(line) {
      Some(p) => p
      None => continue
    }
    match line.find(">>") {
      Some(idx) => {
        let lhs = line[:idx].to_owned()
        if lhs_has_dynamic_token(lhs) {
          add_diag(
            out,
            "github-env",
            Error,
            "write to `\{target}` may allow code execution",
          )
          return
        }
      }
      None => ()
    }
  }
}

// ---------------------------------------------------------------------------
// Rule: unredacted-secrets (zizmor)
// ---------------------------------------------------------------------------

///|
/// Checks whether `text` references a secret via a transform that bypasses
/// GitHub Actions' built-in redaction. Returns `Some(transform-name)` on
/// hit. Looks for shell pipes that mangle the secret (base64/xxd/tr/cut/sed
/// /awk) and for `fromJSON(secrets...)` / `fromJson(secrets...)` expressions
/// (case-insensitive) that destructure JSON-typed secrets — both classes
/// land an unredacted value in logs.
fn unredacted_secret_transform(text : String) -> String? {
  if !contains_secrets_ref(text) {
    return None
  }
  let lo = text.to_lower()
  let transforms = [
    ("base64", "base64"),
    ("xxd", "xxd"),
    ("| tr ", "tr"),
    ("| cut ", "cut"),
    ("| sed ", "sed"),
    ("| awk ", "awk"),
    ("fromjson(secrets", "fromJSON"),
  ]
  for entry in transforms {
    let (pat, name) = entry
    if lo.contains(pat) {
      return Some(name)
    }
  }
  None
}

///|
fn check_unredacted_secrets(
  _ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  match step.run {
    Some(r) =>
      match unredacted_secret_transform(r) {
        Some(name) => {
          add_diag(
            out,
            "unredacted-secrets",
            Error,
            "secret is transformed (\{name}) before logging; redaction will fail",
          )
          return
        }
        None => ()
      }
    None => ()
  }
  // zizmor also flags `env:` values that destructure JSON-typed secrets via
  // `fromJSON(secrets.X)` — the unredacted field lands in the runner
  // environment and gets echoed by any subsequent `run:` that references it.
  match step.raw.get("env") {
    Some(Map(env)) =>
      env.each(fn(_k, v) {
        match v {
          String(s) =>
            match unredacted_secret_transform(s) {
              Some(name) =>
                add_diag(
                  out,
                  "unredacted-secrets",
                  Error,
                  "secret is transformed (\{name}) in `env:` before logging; redaction will fail",
                )
              None => ()
            }
          _ => ()
        }
      })
    _ => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: shell-name-per-os (actionlint)
// ---------------------------------------------------------------------------

///|
fn runner_os_of(s : String) -> String {
  let lo = s.to_lower()
  if lo.contains("windows") {
    return "windows"
  }
  if lo.contains("macos") || lo.contains("mac-") || lo.contains("darwin") {
    return "macos"
  }
  "linux"
}

///|
fn shell_valid_for(shell : String, os : String) -> Bool {
  match os {
    "windows" =>
      shell == "bash" ||
      shell == "pwsh" ||
      shell == "python" ||
      shell == "cmd" ||
      shell == "powershell"
    _ =>
      shell == "bash" || shell == "pwsh" || shell == "python" || shell == "sh"
  }
}

///|
fn check_shell_name_per_os(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  let runs = match get_string_field(job.raw, "runs-on") {
    Some(s) => s
    None => return
  }
  let os = runner_os_of(runs)
  for s in job.steps {
    match get_string_field(s.raw, "shell") {
      Some(sh) =>
        if !shell_valid_for(sh, os) {
          let scope = if sh == "cmd" || sh == "powershell" {
            "Windows"
          } else if sh == "sh" {
            "Linux/macOS"
          } else {
            "this OS"
          }
          add_diag_step(
            out,
            "shell-name-per-os",
            Error,
            "shell `\{sh}` is only available on \{scope} runners",
            s,
          )
        }
      None => ()
    }
  }
}

// ---------------------------------------------------------------------------
// Rule: empty-mappings (actionlint)
// ---------------------------------------------------------------------------

///|
/// Flag a Map field that exists but has zero entries. Skips `permissions: {}`
/// (which intentionally means "deny all") because that is a recognized
/// lockdown idiom.
fn flag_empty_map(
  parent : Map[String, @yaml.Yaml],
  key : String,
  location : String,
  out : Array[Diagnostic],
) -> Unit {
  match parent.get(key) {
    Some(Map(m)) =>
      if m.length() == 0 && key != "permissions" {
        add_diag(
          out,
          "empty-mappings",
          Warning,
          "\{location}: `\{key}:` is an empty mapping",
        )
      }
    _ => ()
  }
}

///|
fn check_empty_mappings_doc(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  match ctx.workflow_map {
    Some(m) =>
      for k in ["jobs", "env", "defaults", "concurrency", "outputs"] {
        flag_empty_map(m, k, "workflow", out)
      }
    None => ()
  }
}

///|
fn check_empty_mappings_job(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  let loc = "job `\{job.name}`"
  for k in ["env", "defaults", "with", "outputs", "concurrency", "secrets"] {
    flag_empty_map(job.raw, k, loc, out)
  }
}

///|
fn check_empty_mappings_step(
  _ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  let id = match step.raw.get("id") {
    Some(String(s)) => s
    _ =>
      match step.raw.get("name") {
        Some(String(s)) => s
        _ => "step"
      }
  }
  let loc = "step `\{id}`"
  for k in ["env", "with", "defaults"] {
    flag_empty_map(step.raw, k, loc, out)
  }
}

// ---------------------------------------------------------------------------
// Rule: constant-if-condition (actionlint)
// ---------------------------------------------------------------------------

///|
/// Detect a literal-constant `if:` expression — `true`, `false`, or
/// `${{ true }}` / `${{ false }}` / `${{ 'x' }}` after trimming. These
/// always evaluate to the same value, so the condition is dead code.
fn is_constant_if(s : String) -> String? {
  let trimmed = s.trim(chars=" \t").to_owned()
  if trimmed == "true" || trimmed == "false" {
    return Some(trimmed)
  }
  if trimmed.has_prefix("${{") && trimmed.has_suffix("}}") {
    let inner = trimmed[3:trimmed.length() - 2].trim(chars=" \t").to_owned()
    if inner == "true" || inner == "false" {
      return Some(inner)
    }
    // Quoted literal `${{ 'x' }}` — also constant.
    if inner.length() >= 2 {
      let c0 = inner.get_char(0)
      let cn = inner.get_char(inner.length() - 1)
      if (c0 == Some('\'') && cn == Some('\'')) ||
        (c0 == Some('"') && cn == Some('"')) {
        return Some(inner)
      }
    }
  }
  None
}

///|
fn constant_if_value(m : Map[String, @yaml.Yaml]) -> String? {
  match m.get("if") {
    Some(String(s)) => is_constant_if(s)
    Some(Boolean(b)) => Some(if b { "true" } else { "false" })
    _ => None
  }
}

///|
fn check_constant_if_job(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  match constant_if_value(job.raw) {
    Some(v) =>
      add_diag(
        out,
        "constant-if-condition",
        Warning,
        "job `\{job.name}` `if:` is constant `\{v}` — remove or replace the condition",
      )
    None => ()
  }
}

///|
fn check_constant_if_step(
  _ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  match constant_if_value(step.raw) {
    Some(v) =>
      add_diag(
        out,
        "constant-if-condition",
        Warning,
        "step `if:` is constant `\{v}` — remove or replace the condition",
      )
    None => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: permissions-syntax (actionlint:permissions-scope-and-value)
// ---------------------------------------------------------------------------

///|
fn valid_perm_scopes() -> Array[String] {
  [
    "actions", "attestations", "checks", "contents", "deployments", "discussions",
    "id-token", "issues", "models", "packages", "pages", "pull-requests", "repository-projects",
    "security-events", "statuses",
  ]
}

///|
fn validate_permissions_map(
  m : Map[String, @yaml.Yaml],
  location : String,
  out : Array[Diagnostic],
) -> Unit {
  let scopes = valid_perm_scopes()
  m.each(fn(k, v) {
    if !array_contains_string(scopes, k) {
      let hint = match suggest(k, scopes) {
        Some(s) => " — did you mean `\{s}`?"
        None => ""
      }
      add_diag(
        out,
        "permissions-syntax",
        Error,
        "\{location}: unknown permission scope `\{k}`\{hint}",
      )
    }
    match v {
      String(s) => {
        let sv = s.trim(chars=" \t").to_owned()
        if sv != "read" && sv != "write" && sv != "none" {
          add_diag(
            out,
            "permissions-syntax",
            Error,
            "\{location}: permission `\{k}` has invalid value `\{sv}` (expected `read`, `write`, or `none`)",
          )
        }
      }
      _ =>
        add_diag(
          out,
          "permissions-syntax",
          Error,
          "\{location}: permission `\{k}` value must be a string",
        )
    }
  })
}

///|
fn check_permissions_syntax_doc(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  match ctx.workflow_map {
    Some(m) =>
      match m.get("permissions") {
        Some(Map(pm)) => validate_permissions_map(pm, "workflow", out)
        _ => ()
      }
    None => ()
  }
}

///|
fn check_permissions_syntax_job(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  match job.raw.get("permissions") {
    Some(Map(pm)) => validate_permissions_map(pm, "job `\{job.name}`", out)
    _ => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: unexpected-keys (actionlint)
// ---------------------------------------------------------------------------

///|
fn workflow_top_keys() -> Array[String] {
  [
    "name", "run-name", "on", "permissions", "env", "defaults", "concurrency", "jobs",
  ]
}

///|
fn action_top_keys() -> Array[String] {
  ["name", "description", "author", "inputs", "outputs", "runs", "branding"]
}

///|
fn job_keys() -> Array[String] {
  [
    "name", "needs", "if", "runs-on", "environment", "concurrency", "outputs", "env",
    "defaults", "steps", "strategy", "container", "services", "secrets", "uses",
    "with", "permissions", "continue-on-error", "timeout-minutes",
  ]
}

///|
fn step_keys() -> Array[String] {
  [
    "id", "name", "if", "run", "uses", "shell", "working-directory", "env", "with",
    "continue-on-error", "timeout-minutes",
  ]
}

///|
fn validate_keys(
  m : Map[String, @yaml.Yaml],
  allowed : Array[String],
  location : String,
  out : Array[Diagnostic],
) -> Unit {
  m.each(fn(k, _v) {
    if !array_contains_string(allowed, k) {
      let hint = match suggest(k, allowed) {
        Some(s) => " — did you mean `\{s}`?"
        None => ""
      }
      add_diag(
        out,
        "unexpected-keys",
        Error,
        "\{location}: unknown key `\{k}`\{hint}",
      )
    }
  })
}

///|
fn check_unexpected_keys_doc(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  match ctx.workflow_map {
    Some(m) => {
      // Trust the resolved file kind; fall back to a structural cue otherwise.
      let is_action = match ctx.kind {
        Action => true
        Workflow => false
        _ => m.contains("runs")
      }
      let allowed = if is_action {
        action_top_keys()
      } else {
        workflow_top_keys()
      }
      let location = if is_action { "action" } else { "workflow" }
      validate_keys(m, allowed, location, out)
    }
    None => ()
  }
}

///|
fn check_unexpected_keys_job(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  validate_keys(job.raw, job_keys(), "job `\{job.name}`", out)
}

///|
fn check_unexpected_keys_step(
  _ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  let id = match step.raw.get("id") {
    Some(String(s)) => s
    _ =>
      match step.raw.get("name") {
        Some(String(s)) => s
        _ => "step"
      }
  }
  validate_keys(step.raw, step_keys(), "step `\{id}`", out)
}

// ---------------------------------------------------------------------------
// Rule: cron-and-timezone (actionlint)
// ---------------------------------------------------------------------------

///|
/// Validate a single POSIX-style cron expression: 5 fields separated by
/// whitespace; each field is `*`, a number, range, list, or step within
/// the conventional bounds (m 0-59, h 0-23, dom 1-31, month 1-12, dow 0-7).
/// Returns `None` on success or `Some(reason)` on failure.
fn validate_cron(s : String) -> String? {
  let trimmed = s.trim(chars=" \t").to_owned()
  if trimmed == "" {
    return Some("empty cron expression")
  }
  let fields : Array[String] = []
  let buf = StringBuilder::new()
  for ch in trimmed {
    if ch == ' ' || ch == '\t' {
      let piece = buf.to_string()
      if piece != "" {
        fields.push(piece)
        buf.reset()
      }
    } else {
      buf.write_char(ch)
    }
  }
  let tail = buf.to_string()
  if tail != "" {
    fields.push(tail)
  }
  if fields.length() != 5 {
    return Some("expected 5 cron fields, got \{fields.length()}")
  }
  let bounds = [(0, 59), (0, 23), (1, 31), (1, 12), (0, 7)]
  let names = ["minute", "hour", "day-of-month", "month", "day-of-week"]
  let mut i = 0
  while i < 5 {
    let (lo, hi) = bounds[i]
    match validate_cron_field(fields[i], lo, hi) {
      Some(why) => return Some("\{names[i]}: \{why}")
      None => ()
    }
    i = i + 1
  }
  None
}

///|
fn validate_cron_field(field : String, lo : Int, hi : Int) -> String? {
  // Split on `,` then check each piece for `*` / `N` / `N-M` / `*/N` / `N-M/N`.
  let parts : Array[String] = []
  let buf = StringBuilder::new()
  for ch in field {
    if ch == ',' {
      parts.push(buf.to_string())
      buf.reset()
    } else {
      buf.write_char(ch)
    }
  }
  parts.push(buf.to_string())
  for p in parts {
    if p == "" {
      return Some("empty subfield in `\{field}`")
    }
    match validate_cron_piece(p, lo, hi) {
      Some(why) => return Some(why)
      None => ()
    }
  }
  None
}

///|
fn validate_cron_piece(piece : String, lo : Int, hi : Int) -> String? {
  // Split off `/step` suffix.
  let slash = index_of_char(piece, '/')
  let (range_part, step_part) = if slash >= 0 {
    (piece[0:slash].to_owned(), Some(piece[slash + 1:].to_owned()))
  } else {
    (piece, None)
  }
  // Validate step if present.
  match step_part {
    Some(sp) => {
      let n = parse_uint(sp.to_string())
      if n <= 0 {
        return Some("invalid step `\{sp}` in `\{piece}`")
      }
    }
    None => ()
  }
  let r = range_part.to_string()
  if r == "*" {
    return None
  }
  let dash = index_of_char(r, '-')
  if dash >= 0 {
    let a = parse_uint(r[0:dash].to_owned())
    let b = parse_uint(r[dash + 1:].to_owned())
    if a < 0 || b < 0 {
      return Some("invalid range `\{r}`")
    }
    if a < lo || b > hi || a > b {
      return Some("range `\{r}` out of bounds [\{lo}-\{hi}]")
    }
    return None
  }
  let n = parse_uint(r)
  if n < 0 {
    return Some("invalid value `\{r}`")
  }
  if n < lo || n > hi {
    return Some("value `\{r}` out of bounds [\{lo}-\{hi}]")
  }
  None
}

///|
fn index_of_char(s : String, c : Char) -> Int {
  let mut i = 0
  let n = s.length()
  while i < n {
    match s.get_char(i) {
      Some(ch) => if ch == c { return i }
      None => return -1
    }
    i = i + 1
  }
  -1
}

///|
fn parse_uint(s : String) -> Int {
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
fn check_cron(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  match ctx.workflow_map {
    Some(m) =>
      match m.get("on") {
        Some(Map(on)) =>
          match on.get("schedule") {
            Some(Array(arr)) =>
              for entry in arr {
                match entry {
                  Map(em) =>
                    match em.get("cron") {
                      Some(String(c)) =>
                        match validate_cron(c) {
                          Some(why) =>
                            add_diag(
                              out,
                              "cron-and-timezone",
                              Error,
                              "schedule.cron `\{c}`: \{why}",
                            )
                          None => ()
                        }
                      _ => ()
                    }
                  _ => ()
                }
              }
            _ => ()
          }
        _ => ()
      }
    None => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: invalid-mapping-values (actionlint)
// ---------------------------------------------------------------------------

///|
/// Per-scope type expectations for well-known YAML keys. We only flag the
/// fields whose runtime semantics are well-defined; obscure / optional fields
/// stay out of the allowlist to keep false-positive risk low.
fn type_name(y : @yaml.Yaml) -> String {
  match y {
    String(_) => "string"
    Boolean(_) => "boolean"
    Integer(_) => "number"
    Real(_, ..) => "number"
    Map(_) => "mapping"
    Array(_) => "array"
    Null => "null"
    BadValue => "invalid"
  }
}

///|
fn expect_string(
  m : Map[String, @yaml.Yaml],
  key : String,
  location : String,
  out : Array[Diagnostic],
) -> Unit {
  match m.get(key) {
    Some(String(_)) => ()
    Some(other) =>
      add_diag(
        out,
        "invalid-mapping-values",
        Error,
        "\{location}: `\{key}` must be a string (got \{type_name(other)})",
      )
    None => ()
  }
}

///|
fn expect_string_or_array(
  m : Map[String, @yaml.Yaml],
  key : String,
  location : String,
  out : Array[Diagnostic],
) -> Unit {
  match m.get(key) {
    Some(String(_)) => ()
    Some(Array(_)) => ()
    Some(_) =>
      add_diag(
        out,
        "invalid-mapping-values",
        Error,
        "\{location}: `\{key}` must be a string or array",
      )
    None => ()
  }
}

///|
fn expect_mapping(
  m : Map[String, @yaml.Yaml],
  key : String,
  location : String,
  out : Array[Diagnostic],
) -> Unit {
  match m.get(key) {
    Some(Map(_)) => ()
    Some(other) =>
      add_diag(
        out,
        "invalid-mapping-values",
        Error,
        "\{location}: `\{key}` must be a mapping (got \{type_name(other)})",
      )
    None => ()
  }
}

///|
fn expect_array(
  m : Map[String, @yaml.Yaml],
  key : String,
  location : String,
  out : Array[Diagnostic],
) -> Unit {
  match m.get(key) {
    Some(Array(_)) => ()
    Some(other) =>
      add_diag(
        out,
        "invalid-mapping-values",
        Error,
        "\{location}: `\{key}` must be an array (got \{type_name(other)})",
      )
    None => ()
  }
}

///|
fn expect_bool_or_string_bool(
  m : Map[String, @yaml.Yaml],
  key : String,
  location : String,
  out : Array[Diagnostic],
) -> Unit {
  match m.get(key) {
    Some(Boolean(_)) => ()
    Some(String("true")) => ()
    Some(String("false")) => ()
    Some(String(s)) =>
      if !s.has_prefix("${{") {
        add_diag(
          out,
          "invalid-mapping-values",
          Error,
          "\{location}: `\{key}` must be a boolean (got string `\{s}`)",
        )
      }
    Some(other) =>
      add_diag(
        out,
        "invalid-mapping-values",
        Error,
        "\{location}: `\{key}` must be a boolean (got \{type_name(other)})",
      )
    None => ()
  }
}

///|
/// GHA accepts `permissions:` as either a mapping or one of the string
/// shorthands `read-all` / `write-all`.
fn expect_permissions(
  m : Map[String, @yaml.Yaml],
  location : String,
  out : Array[Diagnostic],
) -> Unit {
  match m.get("permissions") {
    Some(Map(_)) => ()
    Some(String("read-all")) => ()
    Some(String("write-all")) => ()
    Some(String(s)) =>
      add_diag(
        out,
        "invalid-mapping-values",
        Error,
        "\{location}: `permissions` must be a mapping or `read-all`/`write-all` (got string `\{s}`)",
      )
    Some(other) =>
      add_diag(
        out,
        "invalid-mapping-values",
        Error,
        "\{location}: `permissions` must be a mapping or `read-all`/`write-all` (got \{type_name(other)})",
      )
    None => ()
  }
}

///|
/// `if:` is a GHA expression, which may be a string or coerced to a boolean
/// (`if: true` / `if: false` parses as boolean in YAML).
fn expect_if(
  m : Map[String, @yaml.Yaml],
  location : String,
  out : Array[Diagnostic],
) -> Unit {
  match m.get("if") {
    Some(String(_)) => ()
    Some(Boolean(_)) => ()
    Some(other) =>
      add_diag(
        out,
        "invalid-mapping-values",
        Error,
        "\{location}: `if` must be a string or boolean (got \{type_name(other)})",
      )
    None => ()
  }
}

///|
fn check_invalid_mapping_values_doc(
  ctx : WalkCtx,
  out : Array[Diagnostic],
) -> Unit {
  match ctx.workflow_map {
    Some(m) => {
      expect_mapping(m, "env", "workflow", out)
      expect_mapping(m, "defaults", "workflow", out)
      expect_mapping(m, "concurrency", "workflow", out)
      expect_permissions(m, "workflow", out)
      expect_mapping(m, "jobs", "workflow", out)
    }
    None => ()
  }
}

///|
fn check_invalid_mapping_values_job(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  let loc = "job `\{job.name}`"
  let m = job.raw
  // `runs-on` may be a string or an array.
  expect_string_or_array(m, "runs-on", loc, out)
  expect_array(m, "steps", loc, out)
  expect_mapping(m, "env", loc, out)
  expect_permissions(m, loc, out)
  expect_mapping(m, "with", loc, out)
  expect_mapping(m, "outputs", loc, out)
  expect_mapping(m, "strategy", loc, out)
  expect_bool_or_string_bool(m, "continue-on-error", loc, out)
  expect_string(m, "uses", loc, out)
  expect_if(m, loc, out)
}

///|
fn check_invalid_mapping_values_step(
  _ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  let id = match step.raw.get("id") {
    Some(String(s)) => s
    _ =>
      match step.raw.get("name") {
        Some(String(s)) => s
        _ => "step"
      }
  }
  let loc = "step `\{id}`"
  let m = step.raw
  expect_string(m, "uses", loc, out)
  expect_string(m, "run", loc, out)
  expect_string(m, "shell", loc, out)
  expect_string(m, "working-directory", loc, out)
  expect_mapping(m, "env", loc, out)
  expect_mapping(m, "with", loc, out)
  expect_bool_or_string_bool(m, "continue-on-error", loc, out)
  expect_if(m, loc, out)
}

// ---------------------------------------------------------------------------
// Rule: unknown-runner-label (actionlint)
// ---------------------------------------------------------------------------

///|
fn known_runner_labels() -> Array[String] {
  [
    // GitHub-hosted x64 Linux
    "ubuntu-latest", "ubuntu-24.04", "ubuntu-22.04", "ubuntu-20.04",
    // Arm Linux (preview)
     "ubuntu-22.04-arm", "ubuntu-24.04-arm",
    // macOS
     "macos-latest", "macos-15", "macos-14", "macos-13", "macos-12", "macos-latest-large",
    "macos-latest-xlarge", "macos-14-large", "macos-14-xlarge", "macos-15-large",
    "macos-15-xlarge",
    // Windows
     "windows-latest", "windows-2025", "windows-2022", "windows-2019", "windows-11-arm",
    // Common meta labels
     "self-hosted", "linux", "windows", "macos", "x64", "arm64", "arm",
  ]
}

///|
fn flag_runner_label(label : String, out : Array[Diagnostic]) -> Unit {
  // Skip GHA expression labels (`${{ ... }}`) and the empty string.
  if label == "" || label.contains("${{") {
    return
  }
  let labels = known_runner_labels()
  if array_contains_string(labels, label) {
    return
  }
  let hint = suggest(label, labels)
  // Group labels (e.g. `gpu`, `org/runner-pool`) are user-defined. Flag a
  // label only if it looks like a GitHub-hosted runner family OR there is a
  // close known-label suggestion (catches typos like `ubunto-latest`).
  let looks_hosted = label.has_prefix("ubuntu-") ||
    label.has_prefix("macos-") ||
    label.has_prefix("windows-")
  if !looks_hosted && hint is None {
    return
  }
  let msg = match hint {
    Some(c) => "unknown runner label `\{label}` (did you mean `\{c}`?)"
    None => "unknown runner label `\{label}`"
  }
  add_diag(out, "unknown-runner-label", Warning, msg)
}

///|
fn check_unknown_runner_label(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  match job.raw.get("runs-on") {
    Some(String(s)) => flag_runner_label(s, out)
    Some(Array(arr)) =>
      for item in arr {
        match item {
          String(s) => flag_runner_label(s, out)
          _ => ()
        }
      }
    _ => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: concurrency-limits (zizmor)
// ---------------------------------------------------------------------------

///|
/// Mirrors zizmor's `concurrency-limits` (audit/concurrency_limits.rs):
///
/// 1. Reusable-only workflows (`on:` lists only `workflow_call`) are
///    skipped — callers manage their concurrency. See zizmor#1511.
/// 2. Workflow-level `concurrency: <bare string>` fires (lacks
///    `cancel-in-progress`). A map form is treated as user-set intent
///    even if `cancel-in-progress` is absent or false — see zizmor#1302.
/// 3. With no workflow-level `concurrency:`, iterate normal jobs (skip
///    reusable `uses:` jobs); any normal job with bare-string concurrency
///    or no concurrency at all fires.
fn check_concurrency_limits(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  match ctx.workflow_map {
    Some(m) => {
      if is_reusable_only(m) {
        return
      }
      let wf_concurrency = m.get("concurrency")
      match wf_concurrency {
        Some(@yaml.Yaml::String(_)) => {
          add_diag(
            out,
            "concurrency-limits",
            Info,
            "workflow `concurrency:` is bare; missing `cancel-in-progress`",
          )
          return
        }
        Some(@yaml.Yaml::Map(_)) => return
        _ => ()
      }
      let mut missing = false
      for j in ctx.jobs {
        if j.uses is Some(_) {
          continue
        }
        match j.raw.get("concurrency") {
          None => {
            missing = true
            break
          }
          Some(@yaml.Yaml::String(_)) => {
            missing = true
            break
          }
          _ => ()
        }
      }
      if missing {
        add_diag(
          out,
          "concurrency-limits",
          Info,
          "workflow has no `concurrency:` block",
        )
      }
    }
    None => ()
  }
}

///|
/// True when the workflow's `on:` field lists only `workflow_call` — i.e.
/// it is a reusable workflow whose concurrency must be managed by callers.
fn is_reusable_only(m : Map[String, @yaml.Yaml]) -> Bool {
  match m.get("on") {
    Some(@yaml.Yaml::String(s)) => s == "workflow_call"
    Some(@yaml.Yaml::Array(arr)) => {
      if arr.length() == 0 {
        return false
      }
      for item in arr {
        match item {
          @yaml.Yaml::String(s) => if s != "workflow_call" { return false }
          _ => return false
        }
      }
      true
    }
    Some(@yaml.Yaml::Map(on_map)) =>
      on_map.length() == 1 && on_map.contains("workflow_call")
    _ => false
  }
}

// ---------------------------------------------------------------------------
// Rule: anonymous-definition (zizmor)
// ---------------------------------------------------------------------------

///|
/// Mirrors zizmor's `anonymous-definition` (audit/anonymous_definition.rs):
/// fires when a workflow/action has no top-level `name:` and, in workflows,
/// for each normal job that lacks its own `name:` (the job key is just an
/// ID). Reusable-workflow caller jobs (`uses:` instead of `runs-on:`) are
/// skipped — their identity is the called workflow, not a free-form label.
/// zizmor only surfaces this under `--persona=pedantic`; karinto's parity
/// run uses pedantic so we match the pedantic firings.
fn check_anonymous_definition(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  match ctx.workflow_map {
    Some(m) => {
      if !m.contains("name") {
        let what = match ctx.kind {
          Action => "action"
          _ => "workflow"
        }
        add_diag(out, "anonymous-definition", Info, "\{what} has no `name:`")
      }
      if ctx.kind != FileKind::Action {
        for j in ctx.jobs {
          if j.uses is Some(_) {
            continue
          }
          if !j.raw.contains("name") {
            add_diag_job(
              out,
              "anonymous-definition",
              Info,
              "job `\{j.name}` has no `name:`",
              j.name,
            )
          }
        }
      }
    }
    None => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: undocumented-permissions (zizmor)
// ---------------------------------------------------------------------------

///|
/// Mirrors zizmor's `undocumented-permissions` (pedantic persona): a
/// `permissions:` block whose entries lack explanatory comments is suspect.
/// We re-scan the raw source because the YAML parser drops comments.
///
/// Heuristics:
///   - `permissions: {}` (or any inline-flow value) — skip.
///   - A block whose only entry is `contents: read` — skip (self-explanatory).
///   - Otherwise, every key:value line in the block must have a non-empty
///     trailing comment. An empty `#` does not count; any text after `#`
///     (including a `zizmor: ignore[...]` directive) does.
fn check_undocumented_permissions(
  ctx : WalkCtx,
  out : Array[Diagnostic],
) -> Unit {
  if ctx.source == "" {
    return
  }
  let lines : Array[String] = []
  for v in ctx.source.split("\n") {
    lines.push(v.to_owned())
  }
  let n = lines.length()
  let mut i = 0
  while i < n {
    let line = lines[i]
    let indent = leading_spaces(line)
    let stripped = line[indent:].to_owned()
    // Header looks like `permissions:` (optionally followed by an inline
    // value or comment). Skip if there's a non-empty inline value.
    if has_permissions_header(stripped) {
      let after = stripped["permissions:".length():].to_owned()
      let after_trimmed = trim_ws(after)
      // Strip any trailing comment.
      let val = match index_of(after_trimmed, "#") {
        Some(k) => trim_ws(after_trimmed[0:k].to_owned())
        None => after_trimmed
      }
      if val != "" {
        // Inline value (e.g. `permissions: {}`, `permissions: read-all`).
        i = i + 1
        continue
      }
      // Collect block lines: subsequent lines indented strictly deeper than
      // the header. Stop at the first line with indent ≤ header indent.
      let entries : Array[(Int, String, String)] = []
      let mut j = i + 1
      while j < n {
        let body = lines[j]
        let body_trim = trim_ws(body)
        if body_trim == "" {
          j = j + 1
          continue
        }
        let body_indent = leading_spaces(body)
        if body_indent <= indent {
          break
        }
        // Pure-comment lines inside the block are skipped.
        if body_trim.has_prefix("#") {
          j = j + 1
          continue
        }
        let after_pound = match index_of(body, "#") {
          Some(k) => Some(body[k + 1:].to_owned())
          None => None
        }
        let before_pound = match index_of(body, "#") {
          Some(k) => body[0:k].to_owned()
          None => body
        }
        entries.push((j, before_pound, comment_text(after_pound)))
        j = j + 1
      }
      // An entry is "documented" if it has a non-empty trailing comment, or if
      // it is the self-explanatory `contents: read`. Fire when any entry is
      // undocumented. Empty block -> nothing to flag.
      if entries.length() > 0 {
        let mut uncommented = 0
        for e in entries {
          let (_, before, comment) = e
          let kv = trim_ws(before)
          if comment == "" && kv != "contents: read" {
            uncommented = uncommented + 1
          }
        }
        if uncommented > 0 {
          add_diag(
            out,
            "undocumented-permissions",
            Info,
            "permissions block has \{uncommented} entry/entries without explanatory comments",
          )
        }
      }
      i = j
      continue
    }
    i = i + 1
  }
}

///|
/// Count leading ASCII space characters on a line. Tabs are not GitHub
/// Actions YAML's indentation style, so this is sufficient.
fn leading_spaces(s : String) -> Int {
  let chars = s.to_array()
  let n = chars.length()
  let mut k = 0
  while k < n && chars[k] == ' ' {
    k = k + 1
  }
  k
}

///|
/// True iff `stripped` begins with `permissions:` as a top-level key. We
/// reject `permissionsfoo:` and other look-alikes.
fn has_permissions_header(stripped : String) -> Bool {
  let needle = "permissions:"
  if !stripped.has_prefix(needle) {
    return false
  }
  let rest = stripped[needle.length():].to_owned()
  if rest == "" {
    return true
  }
  let chars = rest.to_array()
  let c = chars[0]
  c == ' ' || c == '\t' || c == '#'
}

///|
/// Inline-comment payload after the `#`. Returns the comment body with
/// surrounding whitespace stripped. An empty body (just `#` or `# `) is
/// returned as the empty string.
fn comment_text(after_pound : String?) -> String {
  match after_pound {
    Some(s) => trim_ws(s)
    None => ""
  }
}

// ---------------------------------------------------------------------------
// Rule: forbidden-uses (zizmor)
// ---------------------------------------------------------------------------

///|
/// Mirrors zizmor's `forbidden-uses` (deny-list mode): flag any step whose
/// `uses:` matches a caller-supplied glob pattern. Patterns can target the
/// bare action (`owner/repo`) or a specific ref (`owner/repo@v1`); we test
/// both forms so callers do not have to know which one the workflow used.
/// Empty list keeps the rule dormant — zizmor's default config is also a
/// no-op, so parity holds without a config plumbed through.
fn check_forbidden_uses(
  ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  if ctx.forbidden_uses.length() == 0 {
    return
  }
  match step.uses {
    Some(u) => {
      let bare = if step.at_idx >= 0 { u[0:step.at_idx].to_owned() } else { u }
      for pat in ctx.forbidden_uses {
        if glob_match(pat, u) || glob_match(pat, bare) {
          add_diag_step_field(
            out,
            ctx,
            "forbidden-uses",
            Warning,
            "uses `\{u}` matches forbidden pattern `\{pat}`",
            step,
            "uses",
          )
          break
        }
      }
    }
    None => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: github-app (zizmor)
// ---------------------------------------------------------------------------

///|
/// Mirrors zizmor's `github-app` audit: a step using
/// `actions/create-github-app-token` is dangerous when it
///   1. sets `skip-token-revoke` to a truthy value or any expression,
///   2. specifies `owner:` without `repositories:` (token scoped to the
///      whole org), or
///   3. omits all `permission-*` inputs (token inherits blanket
///      installation permissions).
/// Each independent issue fires a separate diagnostic on the same step.
fn check_github_app(
  ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  let _ = ctx
  match step.uses {
    Some(u) => if !u.has_prefix("actions/create-github-app-token@") { return }
    None => return
  }
  match step.with_ {
    Some(w) => {
      // skip-token-revoke: anything non-default is suspicious.
      match w.get("skip-token-revoke") {
        Some(v) => {
          let raw = yaml_scalar_text(v)
          let trimmed = trim_ws(raw)
          if trimmed != "" && trimmed != "false" {
            add_diag(
              out,
              "github-app",
              Error,
              "`skip-token-revoke` disables the post-job token revocation; leave it false",
            )
          }
        }
        None => ()
      }
      // owner without repositories.
      let has_owner = match w.get("owner") {
        Some(v) => trim_ws(yaml_scalar_text(v)) != ""
        None => false
      }
      let has_repos = match w.get("repositories") {
        Some(v) => trim_ws(yaml_scalar_text(v)) != ""
        None => false
      }
      if has_owner && !has_repos {
        add_diag(
          out,
          "github-app",
          Error,
          "`owner` set without `repositories`: token spans the entire installation; scope it with `repositories:`",
        )
      }
      // No permission-* inputs at all.
      let mut has_permission = false
      w.each(fn(k, _v) {
        if k.has_prefix("permission-") {
          has_permission = true
        }
      })
      if !has_permission {
        add_diag(
          out,
          "github-app",
          Error,
          "no `permission-*` inputs: token inherits the App's blanket installation permissions",
        )
      }
    }
    None =>
      // No `with:` at all → token inherits everything.
      add_diag(
        out,
        "github-app",
        Error,
        "no `permission-*` inputs: token inherits the App's blanket installation permissions",
      )
  }
}

///|
/// Render a YAML scalar as text. Booleans and integers serialize to their
/// canonical form; expressions and quoted strings stay as the original
/// literal. Non-scalars return the empty string.
fn yaml_scalar_text(v : @yaml.Yaml) -> String {
  match v {
    String(s) => s
    Integer(i) => i.to_string()
    Real(_, repr~) => repr
    Boolean(true) => "true"
    Boolean(false) => "false"
    Null => ""
    _ => ""
  }
}

// ---------------------------------------------------------------------------
// Rule: archived-uses (zizmor)
// ---------------------------------------------------------------------------

///|
/// zizmor maintains a hardcoded baseline of archived `owner/repo` slugs so
/// the rule fires even in offline mode. Karinto mirrors that minimum so
/// upstream-parity holds on the zizmor archived-uses fixture without a
/// network round-trip. Worker callers extend the list at runtime via
/// `archived_uses=`. Comparison is case-insensitive (zizmor's snapshot
/// fires on both `actions/setup-ruby` and `ACTIONS/SETUP-RUBY`).
fn archived_baseline() -> Array[String] {
  ["actions/setup-ruby"]
}

///|
fn is_archived_repo(repo : String, extra : Array[String]) -> Bool {
  if repo == "" {
    return false
  }
  let lo = repo.to_lower()
  for r in archived_baseline() {
    if lo == r.to_lower() {
      return true
    }
  }
  for r in extra {
    if lo == r.to_lower() {
      return true
    }
  }
  false
}

///|
/// Extract `owner/repo` from a `uses:` value, stripping any subpath
/// (`actions/cache/restore` → `actions/cache`) and `@ref` suffix. Returns
/// `""` for local (`./...`) or docker (`docker://...`) refs that have no
/// `owner/repo` form.
fn bare_repo_of(uses : String) -> String {
  if uses == "" || uses.has_prefix("./") || uses.has_prefix("docker://") {
    return ""
  }
  let at = last_at_index(uses)
  let head = if at >= 0 { uses[0:at].to_owned() } else { uses }
  let mut slash = -1
  let mut count = 0
  let n = head.length()
  let mut i = 0
  while i < n {
    match head.get_char(i) {
      Some('/') => {
        count = count + 1
        if count == 2 {
          slash = i
          break
        }
      }
      _ => ()
    }
    i = i + 1
  }
  if slash >= 0 {
    head[0:slash].to_owned()
  } else {
    head
  }
}

///|
fn check_archived_uses_step(
  ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  match step.uses {
    Some(u) => {
      let repo = bare_repo_of(u)
      if is_archived_repo(repo, ctx.archived_uses) {
        add_diag(
          out,
          "archived-uses",
          Warning,
          "uses `\{repo}`: repository is archived",
        )
      }
    }
    None => ()
  }
}

///|
fn check_archived_uses_job(
  ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  match job.uses {
    Some(u) => {
      let repo = bare_repo_of(u)
      if is_archived_repo(repo, ctx.archived_uses) {
        add_diag(
          out,
          "archived-uses",
          Warning,
          "uses `\{repo}`: repository is archived",
        )
      }
    }
    None => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: matrix-values (actionlint)
// ---------------------------------------------------------------------------

///|
/// actionlint's `matrix-values` flags duplicate scalar entries in a job's
/// `strategy.matrix.<key>` array. We only handle scalars (string/int/
/// real/bool) — non-scalar matrix shapes (`include`/`exclude` maps,
/// nested arrays) are left to the engine work tracked under the broader
/// matrix-typing audits.
fn scalar_repr(y : @yaml.Yaml) -> String? {
  match y {
    @yaml.Yaml::String(s) => Some("s:" + s)
    @yaml.Yaml::Integer(i) => Some("i:" + i.to_string())
    @yaml.Yaml::Real(_, repr~) => Some("r:" + repr)
    @yaml.Yaml::Boolean(b) => Some("b:" + b.to_string())
    @yaml.Yaml::Null => Some("n:")
    _ => None
  }
}

///|
fn matrix_value_display(y : @yaml.Yaml) -> String {
  match y {
    @yaml.Yaml::String(s) => s
    @yaml.Yaml::Integer(i) => i.to_string()
    @yaml.Yaml::Real(_, repr~) => repr
    @yaml.Yaml::Boolean(b) => b.to_string()
    @yaml.Yaml::Null => "null"
    _ => "?"
  }
}

///|
fn check_matrix_values_job(
  _ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  let strategy = match job.raw.get("strategy") {
    Some(@yaml.Yaml::Map(m)) => m
    _ => return
  }
  let matrix = match strategy.get("matrix") {
    Some(@yaml.Yaml::Map(m)) => m
    _ => return
  }
  matrix.each(fn(key, value) {
    if key == "include" || key == "exclude" {
      return
    }
    match value {
      @yaml.Yaml::Array(arr) => {
        let seen : Map[String, Bool] = {}
        let reported : Map[String, Bool] = {}
        for entry in arr {
          match scalar_repr(entry) {
            Some(repr) =>
              if seen.contains(repr) && !reported.contains(repr) {
                reported[repr] = true
                add_diag(
                  out,
                  "matrix-values",
                  Error,
                  "duplicate matrix value `\{matrix_value_display(entry)}` in `\{key}`",
                )
              } else {
                seen[repr] = true
              }
            None => ()
          }
        }
      }
      _ => ()
    }
  })
}

// ---------------------------------------------------------------------------
// Rule: yaml-anchor-issues (actionlint)
// ---------------------------------------------------------------------------

///|
/// actionlint's `yaml-anchors` check fires when a YAML anchor (`&name`) is
/// declared but never referenced via an alias (`*name`). The YAML parser
/// resolves anchors away before we see the document, so we re-scan the
/// raw source for `&label` (declaration) and `*label` (alias) tokens.
fn is_anchor_name_char(ch : Char) -> Bool {
  (ch >= 'a' && ch <= 'z') ||
  (ch >= 'A' && ch <= 'Z') ||
  (ch >= '0' && ch <= '9') ||
  ch == '_' ||
  ch == '-'
}

///|
fn is_anchor_start(ch : Char) -> Bool {
  (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_'
}

///|
/// Collect `&name` / `*name` tokens from `line`, ignoring anything after
/// the first unquoted `#` (YAML comment). Skip single-quoted regions to
/// avoid false positives on tokens embedded in scalar strings.
fn scan_anchor_tokens(
  line : String,
  declared : Map[String, Bool],
  used : Map[String, Bool],
) -> Unit {
  let chars = line.to_array()
  let n = chars.length()
  let mut i = 0
  let mut in_single = false
  let mut in_double = false
  while i < n {
    let ch = chars[i]
    if !in_single && !in_double && ch == '#' {
      return
    }
    if !in_double && ch == '\'' {
      // YAML escapes a single-quote inside a single-quoted scalar as `''`;
      // skip the pair and stay in the quoted region.
      if in_single && i + 1 < n && chars[i + 1] == '\'' {
        i = i + 2
        continue
      }
      in_single = !in_single
      i = i + 1
      continue
    }
    if !in_single && ch == '"' {
      in_double = !in_double
      i = i + 1
      continue
    }
    if !in_single && !in_double && (ch == '&' || ch == '*') {
      let prev_ok = i == 0 ||
        chars[i - 1] == ' ' ||
        chars[i - 1] == '\t' ||
        chars[i - 1] == ':' ||
        chars[i - 1] == '[' ||
        chars[i - 1] == ',' ||
        chars[i - 1] == '-'
      if prev_ok && i + 1 < n && is_anchor_start(chars[i + 1]) {
        let mut j = i + 1
        while j < n && is_anchor_name_char(chars[j]) {
          j = j + 1
        }
        // `i` and `j` index `chars` (a codepoint array), so build the name
        // from those code points. Slicing `line` directly would use code-unit
        // offsets and could panic mid-surrogate when the line contains
        // non-BMP characters.
        let buf = StringBuilder::new()
        for k in (i + 1)..<j {
          buf.write_char(chars[k])
        }
        let name = buf.to_string()
        if ch == '&' {
          declared[name] = true
        } else {
          used[name] = true
        }
        i = j
        continue
      }
    }
    i = i + 1
  }
}

///|
fn check_yaml_anchor_issues(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  if ctx.source == "" {
    return
  }
  let declared : Map[String, Bool] = {}
  let used : Map[String, Bool] = {}
  // GitHub Actions' YAML loader does not implement merge keys, so actionlint
  // flags every `<<:` mapping key (syntax-check). Our parser *does* expand
  // merges before rules run, so detection re-scans the source for `<<` used
  // in key position (start of the line's content, optionally after a block
  // sequence dash).
  let mut lineno = 0
  for v in ctx.source.split("\n") {
    lineno = lineno + 1
    let line = v.to_owned()
    scan_anchor_tokens(line, declared, used)
    let indent = leading_spaces(line)
    let rest = trim_ws(line[indent:].to_owned())
    let (content, col0) = if rest.has_prefix("- ") {
      (trim_ws(rest[2:].to_owned()), indent + 2)
    } else {
      (rest, indent)
    }
    if content.has_prefix("<<:") {
      out.push(Diagnostic::{
        rule: "yaml-anchor-issues",
        severity: Error,
        message: "GitHub Actions does not support YAML merge key \"<<\"",
        pos: Some(Position::{ line: lineno, col: col0 + 1 }),
        job: None,
        step: None,
      })
    }
  }
  let names : Array[String] = []
  declared.each(fn(name, _) { names.push(name) })
  // Stable order — sort by name.
  names.sort()
  for name in names {
    if !used.contains(name) {
      add_diag(
        out,
        "yaml-anchor-issues",
        Warning,
        "YAML anchor `&\{name}` is declared but never referenced",
      )
    }
  }
}

// ---------------------------------------------------------------------------
// Rule: deprecated-action-inputs (actionlint)
// ---------------------------------------------------------------------------

///|
/// Hardcoded baseline of `<owner/repo>` → `[(old, new)]` deprecation
/// mappings for popular actions. actionlint pulls a much wider dataset
/// from its bundled `popular-actions.json` (~200 actions); shipping
/// that full table from the linter is tracked under
/// `popular-action-inputs`. This baseline covers the cases most workflow
/// authors actually hit. The Worker can extend coverage by supplying
/// its own deprecation map at a later stage (out of scope here).
fn deprecated_action_inputs_baseline() -> Array[
  (String, Array[(String, String)]),
] {
  [
    ("actions/setup-node", [("version", "node-version")]),
    ("actions/setup-python", [("python_version", "python-version")]),
    ("actions/setup-go", [("version", "go-version")]),
    ("actions/setup-java", [("version", "java-version")]),
    ("actions/setup-dotnet", [("version", "dotnet-version")]),
  ]
}

///|
fn check_deprecated_action_inputs(
  _ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  let uses = match step.uses {
    Some(u) => u
    None => return
  }
  let with_ = match step.with_ {
    Some(w) => w
    None => return
  }
  let repo = bare_repo_of(uses)
  if repo == "" {
    return
  }
  let lo = repo.to_lower()
  for entry in deprecated_action_inputs_baseline() {
    if lo != entry.0.to_lower() {
      continue
    }
    for pair in entry.1 {
      if with_.contains(pair.0) {
        add_diag(
          out,
          "deprecated-action-inputs",
          Warning,
          "\{entry.0} input `\{pair.0}` is deprecated; use `\{pair.1}`",
        )
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Rule: meaningless-comparison (actionlint)
// ---------------------------------------------------------------------------

///|
/// Walk every `${{ ... }}` interpolation and report obvious always-true /
/// always-false comparisons (literal == literal, identifier == itself).
fn check_meaningless_comparison(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  let seen : Map[String, Bool] = {}
  walk_strings(ctx.doc, fn(s) {
    if !s.contains("${{") {
      return
    }
    for expr in extract_expr_bodies(s) {
      match find_meaningless_compare(expr) {
        Some((text, verdict)) =>
          if !seen.contains(text) {
            seen[text] = true
            add_diag(
              out,
              "meaningless-comparison",
              Warning,
              "comparison `\{text}` is always \{verdict}",
            )
          }
        None => ()
      }
    }
  })
}

///|
/// Return the inside of every `${{ ... }}` chunk in `s` as a separate string.
fn extract_expr_bodies(s : String) -> Array[String] {
  let out : Array[String] = []
  let chars = s.to_array()
  let n = chars.length()
  let mut i = 0
  while i + 2 < n {
    if chars[i] == '$' && chars[i + 1] == '{' && chars[i + 2] == '{' {
      let start = i + 3
      let mut j = start
      while j + 1 < n && !(chars[j] == '}' && chars[j + 1] == '}') {
        j = j + 1
      }
      if j + 1 < n {
        let buf = StringBuilder::new()
        let mut k = start
        while k < j {
          buf.write_char(chars[k])
          k = k + 1
        }
        out.push(buf.to_string())
        i = j + 2
      } else {
        i = n
      }
    } else {
      i = i + 1
    }
  }
  out
}

///|
/// Detect `LHS == RHS` / `LHS != RHS` where LHS and RHS are textually
/// identical literals after trimming. Returns `(text, "true"|"false")`.
fn find_meaningless_compare(expr : String) -> (String, String)? {
  // Try `==` first, then `!=`.
  match split_once(expr, "==") {
    Some((lhs, rhs)) => {
      let l = lhs.trim(chars=" \t").to_owned()
      let r = rhs.trim(chars=" \t").to_owned()
      if l != "" && l == r {
        return Some(("\{l} == \{r}", "true"))
      }
    }
    None => ()
  }
  match split_once(expr, "!=") {
    Some((lhs, rhs)) => {
      let l = lhs.trim(chars=" \t").to_owned()
      let r = rhs.trim(chars=" \t").to_owned()
      if l != "" && l == r {
        return Some(("\{l} != \{r}", "false"))
      }
    }
    None => ()
  }
  None
}

///|
fn split_once(s : String, sep : String) -> (String, String)? {
  let n = s.length()
  let m = sep.length()
  if m == 0 || n < m {
    return None
  }
  let chars = s.to_array()
  let sep_chars = sep.to_array()
  let mut i = 0
  while i + m <= n {
    let mut matched = true
    let mut k = 0
    while k < m {
      if chars[i + k] != sep_chars[k] {
        matched = false
        break
      }
      k = k + 1
    }
    if matched {
      let lhs = StringBuilder::new()
      let mut p = 0
      while p < i {
        lhs.write_char(chars[p])
        p = p + 1
      }
      let rhs = StringBuilder::new()
      let mut q = i + m
      while q < n {
        rhs.write_char(chars[q])
        q = q + 1
      }
      return Some((lhs.to_string(), rhs.to_string()))
    }
    i = i + 1
  }
  None
}

// ---------------------------------------------------------------------------
// Rule: glob-patterns (actionlint)
// ---------------------------------------------------------------------------

///|
/// Validate every `branches:`/`paths:`/`tags:` (and `*-ignore` variants)
/// glob list under `on:`. We only catch obvious structural bugs:
///   - unterminated `[...]` character class,
///   - unterminated `{...}` brace group.
/// More elaborate glob semantics belong to a real glob compiler.
fn check_glob_patterns(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  match ctx.workflow_map {
    Some(m) =>
      match m.get("on") {
        Some(Map(on)) =>
          on.each(fn(_event, ev) {
            match ev {
              Map(filter) => check_glob_filter(filter, out)
              _ => ()
            }
          })
        _ => ()
      }
    None => ()
  }
}

///|
fn check_glob_filter(
  filter : Map[String, @yaml.Yaml],
  out : Array[Diagnostic],
) -> Unit {
  let keys = [
    "branches", "branches-ignore", "tags", "tags-ignore", "paths", "paths-ignore",
  ]
  for k in keys {
    match filter.get(k) {
      Some(Array(arr)) =>
        for item in arr {
          match item {
            String(p) =>
              match glob_pattern_error(p) {
                Some(why) =>
                  add_diag(
                    out,
                    "glob-patterns",
                    Error,
                    "invalid glob `\{p}`: \{why}",
                  )
                None => ()
              }
            _ => ()
          }
        }
      _ => ()
    }
  }
}

///|
fn glob_pattern_error(p : String) -> String? {
  let chars = p.to_array()
  let n = chars.length()
  let mut i = 0
  let mut in_class = false
  let mut in_brace = false
  while i < n {
    let c = chars[i]
    if c == '\\' {
      // Skip the escaped character (if any).
      i = i + 2
      continue
    }
    if in_class {
      if c == ']' {
        in_class = false
      }
    } else if in_brace {
      if c == '}' {
        in_brace = false
      }
    } else if c == '[' {
      in_class = true
    } else if c == '{' {
      in_brace = true
    }
    i = i + 1
  }
  if in_class {
    return Some("unterminated character class")
  }
  if in_brace {
    return Some("unterminated brace group")
  }
  None
}

// ---------------------------------------------------------------------------
// Rule: workflow-dispatch-inputs (actionlint)
// ---------------------------------------------------------------------------

///|
fn check_workflow_dispatch_inputs(
  ctx : WalkCtx,
  out : Array[Diagnostic],
) -> Unit {
  match ctx.workflow_map {
    Some(m) =>
      match m.get("on") {
        Some(Map(on)) =>
          match on.get("workflow_dispatch") {
            Some(Map(wd)) => check_dispatch_inputs_map(wd, out)
            _ => ()
          }
        _ => ()
      }
    None => ()
  }
}

///|
fn allowed_dispatch_input_types() -> Array[String] {
  ["choice", "boolean", "string", "environment", "number"]
}

///|
fn check_dispatch_inputs_map(
  wd : Map[String, @yaml.Yaml],
  out : Array[Diagnostic],
) -> Unit {
  match wd.get("inputs") {
    Some(Map(inputs)) =>
      inputs.each(fn(name, def) {
        match def {
          Map(d) => check_dispatch_input(name, d, out)
          _ =>
            add_diag(
              out,
              "workflow-dispatch-inputs",
              Error,
              "workflow_dispatch input `\{name}` must be a mapping",
            )
        }
      })
    _ => ()
  }
}

///|
fn check_dispatch_input(
  name : String,
  d : Map[String, @yaml.Yaml],
  out : Array[Diagnostic],
) -> Unit {
  let types = allowed_dispatch_input_types()
  match d.get("type") {
    Some(String(t)) =>
      if !array_contains_string(types, t) {
        add_diag(
          out,
          "workflow-dispatch-inputs",
          Error,
          "workflow_dispatch input `\{name}.type` must be one of choice/boolean/string/environment/number",
        )
      }
    Some(other) =>
      add_diag(
        out,
        "workflow-dispatch-inputs",
        Error,
        "workflow_dispatch input `\{name}.type` must be a string (got \{type_name(other)})",
      )
    None => ()
  }
  // `choice` inputs need an `options:` array.
  match d.get("type") {
    Some(String("choice")) =>
      match d.get("options") {
        Some(Array(_)) => ()
        _ =>
          add_diag(
            out,
            "workflow-dispatch-inputs",
            Error,
            "workflow_dispatch input `\{name}` is `type: choice` but is missing `options:`",
          )
      }
    _ => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: context-availability (actionlint)
// ---------------------------------------------------------------------------

///|
/// Pre-walk every `${{ ... }}` interpolation and emit a diagnostic when a
/// reserved context (currently `needs`, `steps`, `matrix`, `strategy`,
/// `runner`, `job`) is referenced at a location where GitHub forbids it.
///
/// Locations we check:
///   - workflow-level `env:` / `concurrency:` (no needs/steps/matrix/job)
///   - job-level `env:` (no steps)
///   - job-level `if:` (no steps; needs allowed iff the job declares needs)
///
/// Anything beyond this list is conservatively accepted to avoid noise.
fn check_context_availability(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  let seen : Map[String, Bool] = {}
  match ctx.workflow_map {
    Some(m) => {
      // Workflow scope: `env` / `concurrency` cannot read job-scoped context.
      let workflow_forbidden = [
        "needs", "steps", "matrix", "strategy", "runner", "job", "inputs",
      ]
      check_avail_in_node(
        m.get("env"),
        "workflow-level `env`",
        workflow_forbidden,
        seen,
        out,
      )
      check_avail_in_node(
        m.get("concurrency"),
        "workflow-level `concurrency`",
        workflow_forbidden,
        seen,
        out,
      )
    }
    None => ()
  }
  for j in ctx.jobs {
    // Job scope: env/`if:` cannot reference per-step context.
    check_avail_in_node(
      j.raw.get("env"),
      "job `\{j.name}` `env`",
      ["steps"],
      seen,
      out,
    )
    check_avail_in_node(
      j.raw.get("if"),
      "job `\{j.name}` `if`",
      ["steps"],
      seen,
      out,
    )
  }
}

///|
fn check_avail_in_node(
  node : @yaml.Yaml?,
  location : String,
  forbidden : Array[String],
  seen : Map[String, Bool],
  out : Array[Diagnostic],
) -> Unit {
  match node {
    Some(y) =>
      walk_strings(y, fn(s) {
        check_avail_in_string(s, location, forbidden, seen, out)
      })
    None => ()
  }
}

///|
fn check_avail_in_string(
  s : String,
  location : String,
  forbidden : Array[String],
  seen : Map[String, Bool],
  out : Array[Diagnostic],
) -> Unit {
  if !s.contains("${{") {
    return
  }
  for body in extract_expr_bodies(s) {
    for ctx_name in forbidden {
      if expr_uses_context(body, ctx_name) {
        let key = "\{location}|\{ctx_name}"
        if !seen.contains(key) {
          seen[key] = true
          add_diag(
            out,
            "context-availability",
            Error,
            "context `\{ctx_name}` is not available in \{location}",
          )
        }
      }
    }
  }
}

///|
fn expr_uses_context(expr : String, name : String) -> Bool {
  // Look for `<name>.` as a standalone identifier (after non-ident char).
  let chars = expr.to_array()
  let nm = name.to_array()
  let n = chars.length()
  let m = nm.length()
  let mut i = 0
  while i + m < n {
    let mut matched = true
    let mut k = 0
    while k < m {
      if chars[i + k] != nm[k] {
        matched = false
        break
      }
      k = k + 1
    }
    if matched && chars[i + m] == '.' {
      // Make sure the char before `name` isn't an identifier char.
      if i == 0 || !is_ident_cont(chars[i - 1]) {
        return true
      }
    }
    i = i + 1
  }
  false
}

// ---------------------------------------------------------------------------
// Rule: action-yml-metadata (actionlint)
// ---------------------------------------------------------------------------

///|
fn check_action_yml_metadata(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  match ctx.workflow_map {
    Some(m) => {
      // Every action.yml needs `name` and `runs`. Description is conventional
      // but only `runs` is strictly required by the runtime.
      if !m.contains("runs") {
        add_diag(
          out,
          "action-yml-metadata",
          Error,
          "action.yml is missing required key `runs`",
        )
      }
      match m.get("runs") {
        Some(Map(runs)) => check_action_runs(runs, out)
        Some(other) =>
          add_diag(
            out,
            "action-yml-metadata",
            Error,
            "action.yml `runs` must be a mapping (got \{type_name(other)})",
          )
        None => ()
      }
      match m.get("inputs") {
        Some(Map(inputs)) =>
          inputs.each(fn(name, def) {
            match def {
              Map(d) =>
                match d.get("description") {
                  Some(String(_)) => ()
                  _ =>
                    add_diag(
                      out,
                      "action-yml-metadata",
                      Warning,
                      "action.yml input `\{name}` is missing `description:`",
                    )
                }
              _ =>
                add_diag(
                  out,
                  "action-yml-metadata",
                  Error,
                  "action.yml input `\{name}` must be a mapping",
                )
            }
          })
        Some(other) =>
          add_diag(
            out,
            "action-yml-metadata",
            Error,
            "action.yml `inputs` must be a mapping (got \{type_name(other)})",
          )
        None => ()
      }
    }
    None => ()
  }
}

///|
fn check_action_runs(
  runs : Map[String, @yaml.Yaml],
  out : Array[Diagnostic],
) -> Unit {
  match runs.get("using") {
    Some(String(u)) => {
      let known = [
        "composite", "docker", "node12", "node16", "node20", "node22", "node24",
      ]
      if !array_contains_string(known, u) {
        let hint = match suggest(u, known) {
          Some(c) => " (did you mean `\{c}`?)"
          None => ""
        }
        add_diag(
          out,
          "action-yml-metadata",
          Error,
          "action.yml `runs.using` `\{u}` is not a recognized runtime\{hint}",
        )
      }
      // composite actions need `steps:`, JS actions need `main:`.
      if u == "composite" && !runs.contains("steps") {
        add_diag(
          out,
          "action-yml-metadata",
          Error,
          "composite action is missing `runs.steps`",
        )
      }
      if (u.has_prefix("node") || u == "node12") && !runs.contains("main") {
        add_diag(
          out,
          "action-yml-metadata",
          Error,
          "JavaScript action is missing `runs.main`",
        )
      }
    }
    Some(other) =>
      add_diag(
        out,
        "action-yml-metadata",
        Error,
        "action.yml `runs.using` must be a string (got \{type_name(other)})",
      )
    None =>
      add_diag(
        out,
        "action-yml-metadata",
        Error,
        "action.yml `runs` is missing required key `using`",
      )
  }
}

// ---------------------------------------------------------------------------
// Rule: reusable-workflow-definition (actionlint)
// ---------------------------------------------------------------------------

///|
fn check_reusable_workflow_definition(
  ctx : WalkCtx,
  out : Array[Diagnostic],
) -> Unit {
  match ctx.workflow_map {
    Some(m) =>
      match m.get("on") {
        Some(Map(on)) =>
          match on.get("workflow_call") {
            Some(Map(wc)) => check_workflow_call_def(wc, out)
            Some(other) =>
              add_diag(
                out,
                "reusable-workflow-definition",
                Error,
                "`on.workflow_call` must be a mapping (got \{type_name(other)})",
              )
            None => ()
          }
        _ => ()
      }
    None => ()
  }
}

///|
fn check_workflow_call_def(
  wc : Map[String, @yaml.Yaml],
  out : Array[Diagnostic],
) -> Unit {
  match wc.get("outputs") {
    Some(Map(outputs)) =>
      outputs.each(fn(name, def) {
        match def {
          Map(d) =>
            match d.get("value") {
              Some(_) => ()
              None =>
                add_diag(
                  out,
                  "reusable-workflow-definition",
                  Error,
                  "workflow_call output `\{name}` is missing `value:`",
                )
            }
          _ =>
            add_diag(
              out,
              "reusable-workflow-definition",
              Error,
              "workflow_call output `\{name}` must be a mapping",
            )
        }
      })
    Some(other) =>
      add_diag(
        out,
        "reusable-workflow-definition",
        Error,
        "`on.workflow_call.outputs` must be a mapping (got \{type_name(other)})",
      )
    None => ()
  }
  match wc.get("inputs") {
    Some(Map(inputs)) =>
      inputs.each(fn(name, def) {
        match def {
          Map(d) =>
            match d.get("type") {
              Some(String(t)) => {
                let allowed = ["boolean", "number", "string"]
                if !array_contains_string(allowed, t) {
                  add_diag(
                    out,
                    "reusable-workflow-definition",
                    Error,
                    "workflow_call input `\{name}.type` must be boolean/number/string (got `\{t}`)",
                  )
                }
              }
              Some(_) =>
                add_diag(
                  out,
                  "reusable-workflow-definition",
                  Error,
                  "workflow_call input `\{name}.type` must be a string",
                )
              None => ()
            }
          _ =>
            add_diag(
              out,
              "reusable-workflow-definition",
              Error,
              "workflow_call input `\{name}` must be a mapping",
            )
        }
      })
    Some(other) =>
      add_diag(
        out,
        "reusable-workflow-definition",
        Error,
        "`on.workflow_call.inputs` must be a mapping (got \{type_name(other)})",
      )
    None => ()
  }
}

// ---------------------------------------------------------------------------
// Rule: unsound-condition (zizmor)
// ---------------------------------------------------------------------------

///|
/// Catch trivially-unsound boolean expressions that almost always indicate a
/// misunderstanding of GHA's `always()` / `success()` / `failure()` /
/// `cancelled()` semantics, plus `if:` values whose YAML stringification
/// always renders truthy (block scalars with trailing newlines, mixed
/// plaintext + `${{ ... }}`).
fn check_unsound_condition(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  let seen : Map[String, Bool] = {}
  walk_strings(ctx.doc, fn(s) {
    if !s.contains("${{") {
      return
    }
    for body in extract_expr_bodies(s) {
      let norm = normalize_ws(body)
      let patterns = [
        (
          "always() && success()", "`always() && success()` is always equivalent to `always()`",
        ),
        (
          "success() && always()", "`success() && always()` is always equivalent to `always()`",
        ),
        (
          "always() && !cancelled()", "`always() && !cancelled()` simplifies to `!cancelled()`",
        ),
        (
          "!cancelled() && always()", "`!cancelled() && always()` simplifies to `!cancelled()`",
        ),
        (
          "success() || failure()", "`success() || failure()` ignores cancellation; prefer `!cancelled()`",
        ),
        (
          "failure() || success()", "`failure() || success()` ignores cancellation; prefer `!cancelled()`",
        ),
        ("always() || success()", "`always() || X` is always true"),
        ("success() || always()", "`X || always()` is always true"),
      ]
      for p in patterns {
        let (needle, msg) = p
        if norm.contains(needle) && !seen.contains(needle) {
          seen[needle] = true
          add_diag(out, "unsound-condition", Warning, msg)
        }
      }
    }
  })
  // Step- and job-level `if:` values that mix `${{ ... }}` with surrounding
  // plaintext (including the trailing `\n` left by `|` / `>` block scalars)
  // get stringified by GitHub Actions, then tested for non-emptiness — so
  // they evaluate truthy regardless of what the expression returns.
  for job in ctx.jobs {
    match job.if_cond {
      Some(s) =>
        if if_condition_is_unsound(s) {
          add_diag(
            out,
            "unsound-condition",
            Warning,
            "job `if:` mixes plaintext with `${{ ... }}` (or has a trailing newline from a `|`/`>` block scalar) — GitHub Actions stringifies the value and tests non-emptiness, so the condition is always truthy",
          )
        }
      None => ()
    }
    for step in job.steps {
      match step.if_cond {
        Some(s) =>
          if if_condition_is_unsound(s) {
            add_diag(
              out,
              "unsound-condition",
              Warning,
              "step `if:` mixes plaintext with `${{ ... }}` (or has a trailing newline from a `|`/`>` block scalar) — GitHub Actions stringifies the value and tests non-emptiness, so the condition is always truthy",
            )
          }
        None => ()
      }
    }
  }
}

///|
/// True when an `if:` value, after parsing out `${{ ... }}` expressions,
/// leaves any plaintext characters — including a stray space or a trailing
/// `\n` (the canonical signature of `|` / `>` block scalars).
fn if_condition_is_unsound(s : String) -> Bool {
  if !s.contains("${{") {
    return false
  }
  let chars = s.to_array()
  let n = chars.length()
  let mut i = 0
  let buf = StringBuilder::new()
  while i < n {
    if i + 2 < n &&
      chars[i] == '$' &&
      chars[i + 1] == '{' &&
      chars[i + 2] == '{' {
      let mut j = i + 3
      while j + 1 < n && !(chars[j] == '}' && chars[j + 1] == '}') {
        j = j + 1
      }
      if j + 1 < n {
        i = j + 2
      } else {
        i = n
      }
    } else {
      buf.write_char(chars[i])
      i = i + 1
    }
  }
  buf.to_string().length() > 0
}

///|
fn normalize_ws(s : String) -> String {
  // Collapse runs of whitespace to a single space; mainly to make pattern
  // matching robust to `always()  &&  success()` etc.
  let buf = StringBuilder::new()
  let mut last_space = false
  for ch in s {
    if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' {
      if !last_space {
        buf.write_char(' ')
        last_space = true
      }
    } else {
      buf.write_char(ch)
      last_space = false
    }
  }
  buf.to_string().trim(chars=" ").to_owned()
}

// ---------------------------------------------------------------------------
// Rule: unsound-contains (zizmor)
// ---------------------------------------------------------------------------

///|
/// `contains(search, item)` — searches `search` for `item`. A literal as
/// first arg with an expression second strongly suggests the caller meant
/// `contains(expr, literal)`.
fn check_unsound_contains(ctx : WalkCtx, out : Array[Diagnostic]) -> Unit {
  let seen : Map[String, Bool] = {}
  walk_strings(ctx.doc, fn(s) {
    if !s.contains("${{") || !s.contains("contains(") {
      return
    }
    for body in extract_expr_bodies(s) {
      for swap in find_unsound_contains_calls(body) {
        if !seen.contains(swap) {
          seen[swap] = true
          add_diag(
            out,
            "unsound-contains",
            Warning,
            "`\{swap}` arguments look swapped",
          )
        }
      }
    }
  })
}

///|
fn find_unsound_contains_calls(expr : String) -> Array[String] {
  let out : Array[String] = []
  let chars = expr.to_array()
  let n = chars.length()
  let mut i = 0
  while i + 9 < n {
    // Look for the literal substring `contains(` (case-sensitive).
    if chars[i] == 'c' &&
      chars[i + 1] == 'o' &&
      chars[i + 2] == 'n' &&
      chars[i + 3] == 't' &&
      chars[i + 4] == 'a' &&
      chars[i + 5] == 'i' &&
      chars[i + 6] == 'n' &&
      chars[i + 7] == 's' &&
      chars[i + 8] == '(' {
      let arg_start = i + 9
      // Find the matching `)` while honoring nested parens / quotes.
      let mut depth = 1
      let mut j = arg_start
      let mut in_single = false
      let mut in_double = false
      while j < n && depth > 0 {
        let c = chars[j]
        if in_single {
          if c == '\'' && (j + 1 >= n || chars[j + 1] != '\'') {
            in_single = false
          } else if c == '\'' && j + 1 < n && chars[j + 1] == '\'' {
            j = j + 1
          }
        } else if in_double {
          if c == '"' {
            in_double = false
          }
        } else if c == '\'' {
          in_single = true
        } else if c == '"' {
          in_double = true
        } else if c == '(' {
          depth = depth + 1
        } else if c == ')' {
          depth = depth - 1
          if depth == 0 {
            break
          }
        }
        j = j + 1
      }
      if depth == 0 && j > arg_start {
        let buf = StringBuilder::new()
        let mut k = arg_start
        while k < j {
          buf.write_char(chars[k])
          k = k + 1
        }
        let args = buf.to_string()
        match split_top_level_comma(args) {
          Some((lhs, rhs)) => {
            let l = lhs.trim(chars=" \t").to_owned()
            let r = rhs.trim(chars=" \t").to_owned()
            if looks_like_literal(l) && !looks_like_literal(r) && r != "" {
              let buf2 = StringBuilder::new()
              buf2.write_string("contains(")
              buf2.write_string(l)
              buf2.write_string(", ")
              buf2.write_string(r)
              buf2.write_string(")")
              out.push(buf2.to_string())
            }
          }
          None => ()
        }
        i = j + 1
        continue
      }
    }
    i = i + 1
  }
  out
}

///|
fn split_top_level_comma(s : String) -> (String, String)? {
  let chars = s.to_array()
  let n = chars.length()
  let mut depth = 0
  let mut in_single = false
  let mut in_double = false
  let mut i = 0
  while i < n {
    let c = chars[i]
    if in_single {
      if c == '\'' {
        in_single = false
      }
    } else if in_double {
      if c == '"' {
        in_double = false
      }
    } else if c == '\'' {
      in_single = true
    } else if c == '"' {
      in_double = true
    } else if c == '(' {
      depth = depth + 1
    } else if c == ')' {
      depth = depth - 1
    } else if c == ',' && depth == 0 {
      let lhs = StringBuilder::new()
      let mut p = 0
      while p < i {
        lhs.write_char(chars[p])
        p = p + 1
      }
      let rhs = StringBuilder::new()
      let mut q = i + 1
      while q < n {
        rhs.write_char(chars[q])
        q = q + 1
      }
      return Some((lhs.to_string(), rhs.to_string()))
    }
    i = i + 1
  }
  None
}

///|
fn looks_like_literal(s : String) -> Bool {
  if s == "" {
    return false
  }
  match s.get_char(0) {
    Some('\'') => true
    Some('"') => true
    Some(c) if c >= '0' && c <= '9' => true
    _ => false
  }
}
