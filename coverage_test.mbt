// Sanity checks that bind the rule catalogue (`rules_catalog.mbt`) to the
// rest of the project. Two invariants are enforced:
//
//   1. every implemented rule in `all_rules()` is described in the catalogue,
//   2. every rule in the catalogue has a fixture test whose name embeds the
//      rule ID. The list below has to be edited in lockstep with the
//      per-source `_rules_test.mbt` files; the test fails loudly if a rule
//      is added to the catalogue without a corresponding fixture.

///|
fn tested_rule_ids() -> Array[String] {
  [
    // actionlint family — fixtures live in actionlint_rules_test.mbt
    "unexpected-keys",
    "missing-required-keys",
    "empty-mappings",
    "invalid-mapping-values",
    "expression-syntax",
    "expression-type-mismatch",
    "unknown-context-or-function",
    "context-availability",
    "expression-steps-type",
    "expression-matrix-type",
    "expression-needs-type",
    "meaningless-comparison",
    "shellcheck",
    "pyflakes",
    "job-needs-graph",
    "matrix-values",
    "webhook-events",
    "workflow-dispatch-inputs",
    "glob-patterns",
    "cron-and-timezone",
    "unknown-runner-label",
    "uses-syntax",
    "local-action-inputs",
    "popular-action-inputs",
    "outdated-action-version",
    "shell-name-per-os",
    "duplicate-job-step-ids",
    "invalid-env-var-name",
    "permissions-syntax",
    "reusable-workflow-definition",
    "job-step-id-naming",
    "deprecated-workflow-commands",
    "constant-if-condition",
    "action-yml-metadata",
    "deprecated-action-inputs",
    "yaml-anchor-issues",
    // zizmor family — fixtures live in zizmor_rules_test.mbt
    "anonymous-definition",
    "archived-uses",
    "artipacked",
    "bot-conditions",
    "cache-poisoning",
    "concurrency-limits",
    "dangerous-triggers",
    "dependabot-cooldown",
    "dependabot-execution",
    "excessive-permissions",
    "forbidden-uses",
    "github-app",
    "github-env",
    "hardcoded-container-credentials",
    "impostor-commit",
    "insecure-commands",
    "known-vulnerable-actions",
    "misfeature",
    "obfuscation",
    "overprovisioned-secrets",
    "ref-confusion",
    "ref-version-mismatch",
    "secrets-inherit",
    "secrets-outside-env",
    "self-hosted-runner",
    "stale-action-refs",
    "superfluous-actions",
    "template-injection",
    "undocumented-permissions",
    "unpinned-images",
    "unpinned-tools",
    "unpinned-uses",
    "unredacted-secrets",
    "unsound-condition",
    "unsound-contains",
    "use-trusted-publishing",
    // ghalint family — fixtures live in ghalint_rules_test.mbt
    "job-permissions-required",
    "permissions-read-all-forbidden",
    "permissions-write-all-forbidden",
    "workflow-env-no-secrets",
    "job-env-no-secrets",
    "github-app-limit-repositories",
    "github-app-limit-permissions",
    "composite-step-shell-required",
    "job-timeout-minutes-required",
    "checkout-persist-credentials-false",
  ]
}

///|
test "coverage: every catalogue entry has a fixture test" {
  let catalog : Array[String] = @curllint.all_rule_specs().map(fn(s) { s.id })
  let tested = tested_rule_ids()
  let missing : Array[String] = []
  for id in catalog {
    if !tested.contains(id) {
      missing.push(id)
    }
  }
  let extra : Array[String] = []
  for id in tested {
    let mut found = false
    for s in catalog {
      if s == id {
        found = true
        break
      }
    }
    if !found {
      extra.push(id)
    }
  }
  json_inspect(missing, content=[])
  json_inspect(extra, content=[])
}

///|
test "coverage: every implemented rule appears in the catalogue" {
  let catalog : Array[String] = @curllint.all_rule_specs().map(fn(s) { s.id })
  let missing : Array[String] = []
  for r in @curllint.all_rules() {
    if !catalog.contains(r.id) {
      missing.push(r.id)
    }
  }
  json_inspect(missing, content=[])
}

///|
test "coverage: every spec records at least one upstream origin" {
  let missing : Array[String] = []
  for s in @curllint.all_rule_specs() {
    if s.origins.length() == 0 {
      missing.push(s.id)
    }
  }
  json_inspect(missing, content=[])
}

///|
test "coverage: consolidated rules list every upstream they absorb" {
  // The five intentional consolidations — each one must keep both upstream
  // identifiers in `origins` so the lineage is never lost.
  json_inspect(@curllint.rule_spec("unpinned-uses").origins, content=[
    "zizmor:unpinned-uses",
    "ghalint:ghl-008 (action_ref_should_be_full_length_commit_sha)",
  ])
  json_inspect(@curllint.rule_spec("secrets-inherit").origins, content=[
    "zizmor:secrets-inherit",
    "ghalint:ghl-004 (deny_inherit_secrets)",
  ])
  json_inspect(@curllint.rule_spec("unpinned-images").origins, content=[
    "zizmor:unpinned-images",
    "ghalint:ghl-007 (deny_job_container_latest_image)",
  ])
  json_inspect(
    @curllint.rule_spec("hardcoded-container-credentials").origins,
    content=[
      "zizmor:hardcoded-container-credentials",
      "actionlint:hardcoded-credentials",
    ],
  )
  json_inspect(@curllint.rule_spec("template-injection").origins, content=[
    "zizmor:template-injection",
    "actionlint:script-injection",
  ])
}
