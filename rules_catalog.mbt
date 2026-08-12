///|
/// Catalogue of every rule karinto is aware of, with one of three statuses:
/// `Implemented`, `Planned`, or `NotPlanned` (deliberately out of scope).
///
/// This is the single source of truth for rule **metadata**. The runtime
/// rule registry that actually drives lint execution lives in `rules.mbt`
/// as `all_rules()`; editing this catalogue does not by itself add or
/// remove engine behaviour. Tests (`coverage_test.mbt`) assert that:
///   - every `Implemented` or `Planned` entry has a fixture test,
///   - every entry in `all_rules()` is catalogued as `Implemented`,
///   - JSON returned by `lint(...)` only emits rule IDs that appear here.
///
/// `origins` records the upstream provenance verbatim. When two upstreams
/// cover the same ground (e.g. zizmor's `unpinned-uses` and ghalint's
/// `ghl-008`), karinto merges them into a single rule and lists every
/// origin in this array, so the lineage is never lost.

///|
pub(all) enum Source {
  Actionlint
  Zizmor
  Ghalint
  Curllint
  /// karinto-original: no upstream defines this check. First used by the
  /// tree-sitter-bash shell rules (#113) — see `origins` on each entry for
  /// which specific gap it fills.
  Karinto
} derive(Eq, Debug)

///|
pub(all) enum Category {
  Syntax
  Expression
  Security
  SupplyChain
  Performance
  BestPractice
  Config
  External
} derive(Eq, Debug)

///|
pub(all) enum Status {
  Implemented
  Planned
  NotPlanned
} derive(Eq, Debug)

///|
pub(all) struct RuleSpec {
  id : String
  title : String
  source : Source
  origins : Array[String]
  category : Category
  default_severity : Severity
  status : Status
  applies_to_workflow : Bool
  applies_to_action : Bool
} derive(Eq, Debug)

///|
/// The full catalogue: 84 rules spanning actionlint (38), zizmor (36) and
/// ghalint (10). 4 deliberate consolidations are recorded in `origins`
/// (zizmor entries that also absorb the matching actionlint or ghalint
/// check), and 7 rules are marked `NotPlanned` (out of scope, see status
/// comments below — including impostor-commit and ref-version-mismatch, whose
/// online resolution is delegated to the companion action).
pub fn all_rule_specs() -> Array[RuleSpec] {
  [
    // -----------------------------------------------------------------------
    // actionlint family — syntax, expression typing, generic checks.
    // -----------------------------------------------------------------------
    spec(
      "unexpected-keys",
      "Unexpected keys",
      Actionlint,
      ["actionlint:unexpected-keys"],
      Syntax,
      Error,
      Implemented,
      true,
      true,
    ),
    spec(
      "missing-required-keys",
      "Missing required keys",
      Actionlint,
      ["actionlint:missing-required-keys"],
      Syntax,
      Error,
      Implemented,
      true,
      true,
    ),
    spec(
      "empty-mappings",
      "Empty mappings",
      Actionlint,
      ["actionlint:empty-mappings"],
      Syntax,
      Warning,
      Implemented,
      true,
      true,
    ),
    spec(
      "invalid-mapping-values",
      "Invalid mapping value types",
      Actionlint,
      ["actionlint:invalid-mapping-values"],
      Syntax,
      Error,
      Implemented,
      true,
      true,
    ),
    spec(
      "expression-syntax",
      "Expression syntax error",
      Actionlint,
      ["actionlint:expression-syntax"],
      Expression,
      Error,
      Implemented,
      true,
      true,
    ),
    spec(
      "expression-type-mismatch",
      "Expression type mismatch",
      Actionlint,
      ["actionlint:expression-type-mismatch"],
      Expression,
      Error,
      Implemented,
      true,
      true,
    ),
    spec(
      "unknown-context-or-function",
      "Unknown context/function name or bad arity",
      Actionlint,
      ["actionlint:unknown-context-or-function"],
      Expression,
      Error,
      Implemented,
      true,
      true,
    ),
    spec(
      "config-variables",
      "`vars.*` reference not declared in `config-variables`",
      Actionlint,
      ["actionlint:config-variables"],
      Config,
      Error,
      Implemented,
      true,
      true,
    ),
    spec(
      "context-availability",
      "Context/function used where it is not available",
      Actionlint,
      ["actionlint:context-availability"],
      Expression,
      Error,
      Implemented,
      true,
      true,
    ),
    spec(
      "expression-steps-type",
      "Bad type for steps.<id>",
      Actionlint,
      ["actionlint:steps-id-type"],
      Expression,
      Error,
      Implemented,
      true,
      true,
    ),
    spec(
      "expression-matrix-type",
      "Bad type for matrix",
      Actionlint,
      ["actionlint:matrix-type"],
      Expression,
      Error,
      Implemented,
      true,
      false,
    ),
    spec(
      "expression-needs-type",
      "Bad type for needs",
      Actionlint,
      ["actionlint:needs-type"],
      Expression,
      Error,
      Implemented,
      true,
      false,
    ),
    spec(
      "meaningless-comparison",
      "Meaningless comparison",
      Actionlint,
      ["actionlint:meaningless-comparison"],
      Expression,
      Warning,
      Implemented,
      true,
      true,
    ),
    // shellcheck: out of scope. A 2026-08-10 investigation found WASM
    // (wasilibs/go-shellcheck) partially invalidates the "can't ship a
    // native binary" rationale, but it was evaluated and rejected anyway —
    // GPL-3.0 (license-hygiene overhead for this Apache-2.0 repo), an
    // unproven WASI shim under workerd, and a GHC-runtime CPU cost that
    // doesn't fit the free plan's 10ms budget. #113 adds targeted
    // tree-sitter-bash rules instead (see the `Karinto`-sourced entries
    // below and the upgraded `github-env` / `unpinned-tools` /
    // `unredacted-secrets` / `use-trusted-publishing` entries) — not a
    // shellcheck substitute or a claim of equivalent coverage.
    spec(
      "shellcheck",
      "shellcheck findings in run",
      Actionlint,
      ["actionlint:shellcheck-on-run"],
      External,
      Warning,
      NotPlanned,
      true,
      true,
    ),
    // pyflakes / Python script analysis: out of scope entirely, unrelated
    // to the shellcheck WASM question above. GitHub-hosted runners don't
    // preinstall pyflakes either, so actionlint's own pyflakes rule is a
    // silent no-op in most CI anyway.
    spec(
      "pyflakes",
      "pyflakes findings in python run",
      Actionlint,
      ["actionlint:pyflakes-on-python-run"],
      External,
      Warning,
      NotPlanned,
      true,
      true,
    ),
    // NotPlanned: same vulnerability surface as zizmor:template-injection, which
    // karinto ships as the `template-injection` rule. zizmor's audit covers
    // every taint sink actionlint flags (verified against actionlint's
    // examples/untrusted_input.yaml, err/nested_untrusted_input.yaml,
    // err/github_script_untrusted_input.yaml) and additionally backstops with
    // Info-level findings on every `${{ … }}` expression. Finding granularity
    // differs (actionlint emits one per untrusted subexpression; zizmor
    // emits one per template expression), but no vulnerable site is missed.
    spec(
      "script-injection",
      "Script injection via untrusted input in run:",
      Actionlint,
      ["actionlint:script-injection"],
      Security,
      Error,
      NotPlanned,
      true,
      true,
    ),
    spec(
      "job-needs-graph",
      "Invalid job needs graph",
      Actionlint,
      ["actionlint:job-needs-graph"],
      Syntax,
      Error,
      Implemented,
      true,
      false,
    ),
    spec(
      "matrix-values",
      "Bad matrix values",
      Actionlint,
      ["actionlint:matrix-values"],
      Syntax,
      Error,
      Planned,
      true,
      false,
    ),
    spec(
      "webhook-events",
      "Unknown webhook event/activity",
      Actionlint,
      ["actionlint:webhook-events"],
      Syntax,
      Error,
      Implemented,
      true,
      false,
    ),
    spec(
      "workflow-dispatch-inputs",
      "Bad workflow_dispatch inputs",
      Actionlint,
      ["actionlint:workflow-dispatch-inputs"],
      Syntax,
      Error,
      Implemented,
      true,
      false,
    ),
    spec(
      "glob-patterns",
      "Bad glob pattern",
      Actionlint,
      ["actionlint:glob-patterns"],
      Syntax,
      Error,
      Implemented,
      true,
      false,
    ),
    spec(
      "cron-and-timezone",
      "Bad cron expression or IANA timezone",
      Actionlint,
      ["actionlint:cron-and-timezone"],
      Syntax,
      Error,
      Implemented,
      true,
      false,
    ),
    spec(
      "unknown-runner-label",
      "Unknown runner label",
      Actionlint,
      ["actionlint:runner-label"],
      Syntax,
      Warning,
      Implemented,
      true,
      false,
    ),
    spec(
      "uses-syntax",
      "Bad uses: format",
      Actionlint,
      ["actionlint:uses-syntax"],
      Syntax,
      Error,
      Implemented,
      true,
      true,
    ),
    spec(
      "local-action-inputs",
      "Local action inputs invalid",
      Actionlint,
      ["actionlint:local-action-inputs"],
      Syntax,
      Error,
      Planned,
      true,
      true,
    ),
    spec(
      "popular-action-inputs",
      "Popular action inputs invalid",
      Actionlint,
      ["actionlint:popular-action-inputs"],
      Syntax,
      Error,
      Planned,
      true,
      true,
    ),
    spec(
      "outdated-action-version",
      "Outdated popular action version (EOL runtime)",
      Actionlint,
      ["actionlint:outdated-popular-action-version"],
      BestPractice,
      Warning,
      Implemented,
      true,
      true,
    ),
    spec(
      "shell-name-per-os",
      "Bad shell for OS",
      Actionlint,
      ["actionlint:shell-name"],
      Syntax,
      Error,
      Implemented,
      true,
      true,
    ),
    spec(
      "duplicate-job-step-ids",
      "Duplicate job/step IDs",
      Actionlint,
      ["actionlint:duplicate-job-step-ids"],
      Syntax,
      Error,
      Implemented,
      true,
      false,
    ),
    spec(
      "invalid-env-var-name",
      "Bad environment variable name",
      Actionlint,
      ["actionlint:env-var-name"],
      Syntax,
      Warning,
      Implemented,
      true,
      true,
    ),
    spec(
      "permissions-syntax",
      "Bad permissions scope/value (syntax)",
      Actionlint,
      ["actionlint:permissions-scope-and-value"],
      Syntax,
      Error,
      Implemented,
      true,
      false,
    ),
    spec(
      "reusable-workflow-definition",
      "Bad reusable workflow inputs/outputs/secrets",
      Actionlint,
      ["actionlint:reusable-workflow"],
      Syntax,
      Error,
      Implemented,
      true,
      false,
    ),
    spec(
      "job-step-id-naming",
      "Bad job/step ID naming",
      Actionlint,
      ["actionlint:job-step-id-naming"],
      BestPractice,
      Warning,
      Implemented,
      true,
      true,
    ),
    spec(
      "deprecated-workflow-commands",
      "Deprecated workflow command",
      Actionlint,
      ["actionlint:deprecated-workflow-commands"],
      BestPractice,
      Warning,
      Implemented,
      true,
      true,
    ),
    spec(
      "constant-if-condition",
      "Constant if condition",
      Actionlint,
      ["actionlint:constant-if-condition"],
      BestPractice,
      Warning,
      Implemented,
      true,
      true,
    ),
    spec(
      "action-yml-metadata",
      "Invalid action.yml metadata",
      Actionlint,
      ["actionlint:action-yml-metadata"],
      Syntax,
      Error,
      Implemented,
      false,
      true,
    ),
    // `deprecated-action-inputs` status stays Planned: a hardcoded baseline
    // of ~5 popular actions ships in `rules.mbt`, but actionlint pulls from
    // ~200 entries. Promote to Implemented once the full popular-actions
    // catalogue is bundled (tracked under `popular-action-inputs` below).
    spec(
      "deprecated-action-inputs",
      "Deprecated action inputs",
      Actionlint,
      ["actionlint:deprecated-popular-action-inputs"],
      BestPractice,
      Warning,
      Planned,
      true,
      true,
    ),
    spec(
      "yaml-anchor-issues",
      "YAML anchor/alias issues",
      Actionlint,
      ["actionlint:yaml-anchors"],
      Syntax,
      Warning,
      Implemented,
      true,
      true,
    ),
    // -----------------------------------------------------------------------
    // zizmor family — security and supply-chain audits.
    // Some entries here absorb a matching actionlint or ghalint rule;
    // when that happens, every upstream is listed in `origins`.
    // -----------------------------------------------------------------------
    spec(
      "anonymous-definition",
      "Missing name on workflow/action",
      Zizmor,
      ["zizmor:anonymous-definition"],
      BestPractice,
      Info,
      Implemented,
      true,
      true,
    ),
    spec(
      "archived-uses",
      "References archived repo",
      Zizmor,
      ["zizmor:archived-uses"],
      SupplyChain,
      Warning,
      Implemented,
      true,
      true,
    ),
    spec(
      "artipacked",
      "Credential persistence through GitHub Actions artifacts",
      Zizmor,
      ["zizmor:artipacked"],
      Security,
      Warning,
      Implemented,
      true,
      true,
    ),
    spec(
      "bot-conditions",
      "Spoofable github.actor bot check",
      Zizmor,
      ["zizmor:bot-conditions"],
      Security,
      Error,
      Implemented,
      true,
      false,
    ),
    spec(
      "cache-poisoning",
      "Runtime artifacts vulnerable to cache poisoning",
      Zizmor,
      ["zizmor:cache-poisoning"],
      Security,
      Error,
      Implemented,
      true,
      true,
    ),
    spec(
      "concurrency-limits",
      "Missing concurrency control",
      Zizmor,
      ["zizmor:concurrency-limits"],
      Performance,
      Info,
      Implemented,
      true,
      false,
    ),
    spec(
      "dangerous-triggers",
      "pull_request_target etc.",
      Zizmor,
      ["zizmor:dangerous-triggers"],
      Security,
      Error,
      Implemented,
      true,
      false,
    ),
    spec(
      "dependabot-cooldown",
      "Insufficient cooldown for dependabot updates",
      Zizmor,
      ["zizmor:dependabot-cooldown"],
      SupplyChain,
      Warning,
      Implemented,
      false,
      false,
    ),
    spec(
      "dependabot-execution",
      "External exec in dependabot config",
      Zizmor,
      ["zizmor:dependabot-execution"],
      Security,
      Error,
      Implemented,
      true,
      false,
    ),
    spec(
      "excessive-permissions",
      "Overly broad permissions",
      Zizmor,
      ["zizmor:excessive-permissions"],
      Security,
      Warning,
      Implemented,
      true,
      true,
    ),
    spec(
      "forbidden-uses",
      "Disallowed action by allowlist",
      Zizmor,
      ["zizmor:forbidden-uses"],
      Config,
      Warning,
      Implemented,
      true,
      true,
    ),
    spec(
      "github-app",
      "GitHub App install token misuse",
      Zizmor,
      ["zizmor:github-app"],
      Security,
      Warning,
      Implemented,
      true,
      false,
    ),
    // First karinto-original rules (#113), built on the tree-sitter-bash
    // integration added for the upgraded shell rules above/below. Narrower
    // in scope than stock shellcheck by design — see DEVELOPMENT.md /
    // the issue for the rationale.
    spec(
      "shell-quote-safety",
      "Unquoted expansion of an expression-derived env var in `run:`",
      Karinto,
      ["karinto:shell-quote-safety"],
      Security,
      Warning,
      Implemented,
      true,
      true,
    ),
    spec(
      "shell-undefined-var",
      "Reference to a shell variable with no declared source",
      Karinto,
      ["karinto:shell-undefined-var"],
      BestPractice,
      Info,
      Implemented,
      true,
      true,
    ),
    spec(
      "github-env",
      "Dangerous $GITHUB_ENV writes",
      Zizmor,
      ["zizmor:github-env"],
      Security,
      Error,
      Implemented,
      true,
      true,
    ),
    // Consolidates actionlint's "hardcoded credentials" check (containers + services).
    spec(
      "hardcoded-container-credentials",
      "Plain container/service credentials",
      Zizmor,
      [
        "zizmor:hardcoded-container-credentials", "actionlint:hardcoded-credentials",
      ],
      Security,
      Error,
      Implemented,
      true,
      false,
    ),
    // impostor-commit: NotPlanned in karinto-core. Confirming a pinned SHA's
    // repo membership needs live GitHub API calls per `repo@sha`, which the
    // edge linter does not do. Detection is delegated to the companion action
    // (see docs/action-context.md), which reports findings directly.
    spec(
      "impostor-commit",
      "SHA not in claimed repo (network)",
      Zizmor,
      ["zizmor:impostor-commit"],
      SupplyChain,
      Error,
      NotPlanned,
      true,
      false,
    ),
    spec(
      "insecure-commands",
      "ACTIONS_ALLOW_UNSECURE_COMMANDS",
      Zizmor,
      ["zizmor:insecure-commands"],
      Security,
      Warning,
      Implemented,
      true,
      true,
    ),
    spec(
      "known-vulnerable-actions",
      "CVE-listed actions",
      Zizmor,
      ["zizmor:known-vulnerable-actions"],
      SupplyChain,
      Error,
      Implemented,
      true,
      true,
    ),
    spec(
      "misfeature",
      "Problematic feature pattern",
      Zizmor,
      ["zizmor:misfeature"],
      BestPractice,
      Info,
      Implemented,
      true,
      true,
    ),
    spec(
      "obfuscation",
      "Obfuscated expressions or uses refs",
      Zizmor,
      ["zizmor:obfuscation"],
      Security,
      Info,
      Implemented,
      true,
      true,
    ),
    spec(
      "overprovisioned-secrets",
      "Whole secrets context exposed",
      Zizmor,
      ["zizmor:overprovisioned-secrets"],
      Security,
      Warning,
      Implemented,
      true,
      false,
    ),
    // ref-confusion: out of scope — karinto already mandates SHA pins via
    // `unpinned-uses`, so confusable tag/branch refs cannot occur in
    // compliant workflows.
    spec(
      "ref-confusion",
      "Confusable symbolic refs",
      Zizmor,
      ["zizmor:ref-confusion"],
      SupplyChain,
      Warning,
      NotPlanned,
      true,
      true,
    ),
    // ref-version-mismatch: NotPlanned in karinto-core. Resolving a tag to its
    // SHA to compare against the trailing `# vN` comment needs live GitHub API
    // calls, which the edge linter does not do. Detection is delegated to the
    // companion action (see docs/action-context.md), which reports directly.
    spec(
      "ref-version-mismatch",
      "Pinned-SHA comment vs actual tag",
      Zizmor,
      ["zizmor:ref-version-mismatch"],
      BestPractice,
      Warning,
      NotPlanned,
      true,
      false,
    ),
    // Consolidates ghalint ghl-004 (deny_inherit_secrets).
    spec(
      "secrets-inherit",
      "Blanket `secrets: inherit`",
      Zizmor,
      ["zizmor:secrets-inherit", "ghalint:ghl-004 (deny_inherit_secrets)"],
      Security,
      Error,
      Implemented,
      true,
      false,
    ),
    spec(
      "secrets-outside-env",
      "Secrets used outside protected environment",
      Zizmor,
      ["zizmor:secrets-outside-env"],
      Security,
      Warning,
      Implemented,
      true,
      false,
    ),
    spec(
      "self-hosted-runner",
      "Self-hosted runner used",
      Zizmor,
      ["zizmor:self-hosted-runner"],
      Security,
      Warning,
      Implemented,
      true,
      false,
    ),
    // stale-action-refs: out of scope — would require GitHub API to
    // enumerate tags reachable from a SHA, and the upstream signal is only
    // informational; the cost (API call, latency, rate-limit) is not worth it.
    spec(
      "stale-action-refs",
      "SHA without any tag",
      Zizmor,
      ["zizmor:stale-action-refs"],
      SupplyChain,
      Info,
      NotPlanned,
      true,
      true,
    ),
    spec(
      "superfluous-actions",
      "Action functionality is already included by the runner",
      Zizmor,
      ["zizmor:superfluous-actions"],
      BestPractice,
      Info,
      Implemented,
      true,
      false,
    ),
    spec(
      "template-injection",
      "Template injection via untrusted input",
      Zizmor,
      ["zizmor:template-injection"],
      Security,
      Error,
      Implemented,
      true,
      true,
    ),
    spec(
      "undocumented-permissions",
      "Permission block without comment",
      Zizmor,
      ["zizmor:undocumented-permissions"],
      BestPractice,
      Info,
      Implemented,
      true,
      false,
    ),
    // Consolidates ghalint ghl-007 (deny_job_container_latest_image) — :latest is one specific case of "not pinned by digest".
    spec(
      "unpinned-images",
      "Container image not pinned by digest",
      Zizmor,
      [
        "zizmor:unpinned-images", "ghalint:ghl-007 (deny_job_container_latest_image)",
      ],
      SupplyChain,
      Warning,
      Implemented,
      true,
      false,
    ),
    spec(
      "unpinned-tools",
      "Runtime-fetched external tools",
      Zizmor,
      ["zizmor:unpinned-tools"],
      SupplyChain,
      Warning,
      Implemented,
      true,
      false,
    ),
    // Consolidates ghalint ghl-008 (action_ref_should_be_full_length_commit_sha).
    spec(
      "unpinned-uses",
      "uses: not pinned to full SHA",
      Zizmor,
      [
        "zizmor:unpinned-uses", "ghalint:ghl-008 (action_ref_should_be_full_length_commit_sha)",
      ],
      SupplyChain,
      Warning,
      Implemented,
      true,
      true,
    ),
    spec(
      "unredacted-secrets",
      "Secret-leak via redaction failure",
      Zizmor,
      ["zizmor:unredacted-secrets"],
      Security,
      Error,
      Implemented,
      true,
      false,
    ),
    spec(
      "unsound-condition",
      "Logically broken if:",
      Zizmor,
      ["zizmor:unsound-condition"],
      BestPractice,
      Warning,
      Implemented,
      true,
      true,
    ),
    spec(
      "unsound-contains",
      "Misuse of contains()",
      Zizmor,
      ["zizmor:unsound-contains"],
      Security,
      Warning,
      Implemented,
      true,
      true,
    ),
    spec(
      "use-trusted-publishing",
      "Prefer OIDC trusted publishing",
      Zizmor,
      ["zizmor:use-trusted-publishing"],
      BestPractice,
      Info,
      Implemented,
      true,
      true,
    ),
    // -----------------------------------------------------------------------
    // ghalint family — policy/security checks. The numbering matches the
    // upstream `docs/policies/NNN.md` files. ghl-004/007/008 are absorbed
    // into the zizmor entries above and intentionally absent here.
    // -----------------------------------------------------------------------
    spec(
      "job-permissions-required",
      "Job permissions required",
      Ghalint,
      ["ghalint:ghl-001 (job_permissions)"],
      Security,
      Warning,
      Implemented,
      true,
      false,
    ),
    spec(
      "permissions-read-all-forbidden",
      "Forbid `permissions: read-all`",
      Ghalint,
      ["ghalint:ghl-002 (deny_read_all_permission)"],
      Security,
      Error,
      Implemented,
      true,
      false,
    ),
    spec(
      "permissions-write-all-forbidden",
      "Forbid `permissions: write-all`",
      Ghalint,
      ["ghalint:ghl-003 (deny_write_all_permission)"],
      Security,
      Error,
      Implemented,
      true,
      false,
    ),
    spec(
      "workflow-env-no-secrets",
      "No secrets in workflow env",
      Ghalint,
      ["ghalint:ghl-005 (workflow_secrets)"],
      Security,
      Error,
      Implemented,
      true,
      false,
    ),
    spec(
      "job-env-no-secrets",
      "No secrets in job env",
      Ghalint,
      ["ghalint:ghl-006 (job_secrets)"],
      Security,
      Error,
      Implemented,
      true,
      false,
    ),
    spec(
      "github-app-limit-repositories",
      "Limit GitHub App repository scope",
      Ghalint,
      ["ghalint:ghl-009 (github_app_should_limit_repositories)"],
      Security,
      Warning,
      Implemented,
      true,
      false,
    ),
    spec(
      "github-app-limit-permissions",
      "Limit GitHub App permissions",
      Ghalint,
      ["ghalint:ghl-010 (github_app_should_limit_permissions)"],
      Security,
      Warning,
      Implemented,
      true,
      false,
    ),
    spec(
      "composite-step-shell-required",
      "Composite action step needs shell",
      Ghalint,
      ["ghalint:ghl-011 (action_shell_is_required)"],
      BestPractice,
      Warning,
      Implemented,
      false,
      true,
    ),
    spec(
      "job-timeout-minutes-required",
      "Job timeout-minutes required",
      Ghalint,
      ["ghalint:ghl-012 (job_timeout_minutes_is_required)"],
      BestPractice,
      Warning,
      Implemented,
      true,
      false,
    ),
    spec(
      "checkout-persist-credentials-false",
      "checkout persist-credentials must be false",
      Ghalint,
      ["ghalint:ghl-013 (checkout_persist_credentials_should_be_false)"],
      Security,
      Error,
      Implemented,
      true,
      false,
    ),
  ]
}

///|
fn spec(
  id : String,
  title : String,
  source : Source,
  origins : Array[String],
  category : Category,
  default_severity : Severity,
  status : Status,
  applies_to_workflow : Bool,
  applies_to_action : Bool,
) -> RuleSpec {
  RuleSpec::{
    id,
    title,
    source,
    origins,
    category,
    default_severity,
    status,
    applies_to_workflow,
    applies_to_action,
  }
}

///|
/// Returns the rule spec for `id`, panicking if none exists.
pub fn rule_spec(id : String) -> RuleSpec {
  for s in all_rule_specs() {
    if s.id == id {
      return s
    }
  }
  abort("no such rule in catalog: \{id}")
}
