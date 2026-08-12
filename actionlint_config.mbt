///|
/// actionlint config-file support (`.github/actionlint.yaml`'s
/// `paths.<glob>.ignore`, #50).
///
/// actionlint suppresses findings by running a list of regexes (scoped to a
/// file-path glob) against *its own* diagnostic message text. Two things
/// make that mechanism not directly portable to karinto: there is no stable
/// rule-ID key to translate (unlike ghalint's `policy_name`, which the
/// catalogue's `origins` already map onto karinto rule IDs — see
/// `ghalint_config.mbt`), and the regexes are written against actionlint's
/// own wording, which karinto's diagnostics do not share.
///
/// The approach taken here: a curated table (`actionlint_canonical_messages`)
/// holds one or more real sample messages per actionlint check, transcribed
/// verbatim from the `.out` fixtures vendored under
/// `fixtures/upstream/actionlint/testdata/` (never invented). Each `ignore`
/// pattern is compiled with `moonbitlang/regexp` and *actually executed*
/// against those samples; a match identifies which actionlint check the
/// pattern targets, and the catalogue's `origins` (`"actionlint:<check>"`)
/// resolve that check to karinto rule ID(s). A pattern that fails to
/// compile, or matches none of the curated samples, is a silent no-op —
/// best-effort, the same posture as `parse_ghalint_excludes` /
/// `parse_zizmor_config`.
///
/// This is necessarily coarser than actionlint's own mechanism: suppression
/// happens at rule granularity, not message granularity — a pattern that (in
/// real actionlint) would only ignore one specific dynamic value (e.g. one
/// runner label) suppresses every finding of the matching rule under the
/// path glob instead. A handful of checks legitimately share one message
/// template (e.g. `property "X" is not defined in object type {...}` covers
/// `expression-steps-type` / `expression-matrix-type` / `expression-needs-
/// type` / `expression-type-mismatch` alike, since actionlint's own type
/// checker produces that exact text regardless of which context triggered
/// it) — a pattern broad enough to match the shared template suppresses all
/// of them, which mirrors what actionlint itself would do with the same
/// pattern, not a false positive introduced here.

///|
/// One `paths.<glob>:` entry: the glob and its raw `ignore` regex pattern
/// strings, not yet resolved to karinto rule IDs.
priv struct ActionlintPathIgnore {
  glob : String
  patterns : Array[String]
}

///|
/// Parse the `paths:` map of an actionlint config into per-glob `ignore`
/// pattern lists. Best-effort: a malformed config yields no entries, matching
/// `parse_ghalint_excludes` / `parse_zizmor_config`.
fn parse_actionlint_paths(config : String) -> Array[ActionlintPathIgnore] {
  let out : Array[ActionlintPathIgnore] = []
  let docs = @yaml.Yaml::load_from_string(config) catch { _ => return out }
  for d in docs {
    guard d is Map(top) else { continue }
    match top.get("paths") {
      Some(Map(paths)) =>
        paths.each(fn(glob, v) {
          match v {
            Map(pm) =>
              match pm.get("ignore") {
                Some(Array(items)) => {
                  let patterns = yaml_string_array(items)
                  if patterns.length() > 0 {
                    out.push(ActionlintPathIgnore::{ glob, patterns })
                  }
                }
                _ => ()
              }
            _ => ()
          }
        })
      _ => ()
    }
  }
  out
}

///|
/// Curated canonical sample messages for each actionlint check karinto
/// implements, keyed by the check name as it appears in the catalogue's
/// `"actionlint:<check>"` origins. Every sample is transcribed verbatim from
/// a `.out` fixture under `fixtures/upstream/actionlint/testdata/` — except
/// the four marked below, where the upstream fixture itself only records a
/// regex test assertion (a variable file path or label list) rather than a
/// literal transcript; those are reconstructed by filling the pattern's own
/// literal fragments with a representative concrete value, never invented
/// wording.
fn actionlint_canonical_messages() -> Array[(String, Array[String])] {
  [
    (
      "unexpected-keys",
      [
        "unexpected key \"invalid_key\" for \"inputs\" section. expected one of \"default\", \"description\", \"required\"",
        "unexpected key \"invalid_key\" for step to run shell command. expected one of \"continue-on-error\", \"env\", \"id\", \"if\", \"name\", \"run\", \"shell\", \"timeout-minutes\", \"working-directory\"",
        "expected \"inputs\" key for \"workflow_dispatch\" section but got \"invalid_key\"",
      ],
    ),
    (
      "missing-required-keys",
      [
        "\"type\" is missing at \"foo\" input of workflow_call event", "\"runs-on\" section is missing in job \"test\"",
        "group name is missing in \"concurrency\" section",
      ],
    ),
    (
      "empty-mappings",
      [
        "\"schedule\" section should not be empty", "\"defaults\" section should not be empty. please remove this section if it's unnecessary",
        "workflow is empty",
      ],
    ),
    (
      "invalid-mapping-values",
      [
        "expected scalar node for integer value but found scalar node with \"!!float\" tag",
        "expected mapping node for secrets or \"inherit\" string node but found \"foo\" node",
        "expected scalar node for string value but found sequence node with \"!!seq\" tag",
      ],
    ),
    (
      "expression-syntax",
      [
        "unexpected end of input while parsing arguments of function call. expecting \",\", \")\"",
        "unexpected end of input while parsing object property dereference like 'a.b' or array element dereference like 'a.*'. expecting \"IDENT\", \"*\"",
        "got unexpected character '+' while lexing expression, expecting 'a'..'z', 'A'..'Z', '_', '0'..'9', ''', '}', '(', ')', '[', ']', '.', '!', '<', '>', '=', '&', '|', '*', ',', ' '",
      ],
    ),
    (
      "expression-type-mismatch",
      [
        "property access of object must be type of string but got \"number\"", "receiver of object dereference \"owner\" must be type of object but got \"string\"",
        "object, array, and null values should not be evaluated in template with ${{ }} but evaluating the value of type object",
      ],
    ),
    (
      "unknown-context-or-function",
      [
        "undefined variable \"unknown_context\". available variables are \"env\", \"github\", \"inputs\", \"job\", \"matrix\", \"needs\", \"runner\", \"secrets\", \"steps\", \"strategy\", \"vars\"",
        "undefined function \"startWith\". available functions are \"always\", \"cancelled\", \"case\", \"contains\", \"endswith\", \"failure\", \"format\", \"fromjson\", \"hashfiles\", \"join\", \"startswith\", \"success\", \"tojson\"",
        "number of arguments is wrong. function \"startsWith(string, string) -> bool\" takes 2 parameters but 1 arguments are given",
      ],
    ),
    (
      "config-variables",
      [
        "undefined configuration variable \"piyo\". defined configuration variables in actionlint.yaml are \"FOO\", \"WOO\"",
      ],
    ),
    (
      "context-availability",
      [
        "context \"env\" is not allowed here. available contexts are \"github\", \"inputs\", \"secrets\", \"vars\". see https://docs.github.com/en/actions/learn-github-actions/contexts#context-availability for more details",
        "context \"runner\" is not allowed here. available contexts are \"github\", \"inputs\", \"needs\", \"vars\". see https://docs.github.com/en/actions/learn-github-actions/contexts#context-availability for more details",
        "calling function \"success\" is not allowed here. \"success\" is only available in \"jobs.<job_id>.if\", \"jobs.<job_id>.steps.if\". see https://docs.github.com/en/actions/learn-github-actions/contexts#context-availability for more details",
      ],
    ),
    (
      "steps-id-type",
      ["property \"get_value\" is not defined in object type {}"],
    ),
    ("matrix-type", ["property \"os\" is not defined in object type {}"]),
    (
      "needs-type",
      [
        "property \"some_job\" is not defined in object type {install: {outputs: {installed: string}; result: string}; prepare: {outputs: {prepared: string}; result: string}}",
        "property \"prepare\" is not defined in object type {}",
      ],
    ),
    (
      "meaningless-comparison",
      [
        "\"string\" value cannot be compared to \"{}\" value with \"==\" operator",
        "\"number\" value cannot be compared to \"null\" value with \">\" operator",
        "\"bool\" value cannot be compared to \"number\" value with \">\" operator",
      ],
    ),
    (
      "job-needs-graph",
      [
        "cyclic dependencies in \"needs\" job configurations are detected. detected cycle is \"from\" -> \"to\" -> \"from\"",
        "job ID \"BAR\" duplicates in \"needs\" section. note that job ID is case insensitive",
        "job \"bar\" needs job \"unknown\" which does not exist in this workflow",
      ],
    ),
    (
      "webhook-events",
      [
        "both \"paths\" and \"paths-ignore\" filters cannot be used for the same event \"push\". note: use '!' to negate patterns",
        "invalid activity type \"created\" for \"issues\" Webhook event. available types are \"assigned\", \"closed\", \"deleted\", \"demilestoned\", \"edited\", \"labeled\", \"locked\", \"milestoned\", \"opened\", \"pinned\", \"reopened\", \"transferred\", \"typed\", \"unassigned\", \"unlabeled\", \"unlocked\", \"unpinned\", \"untyped\"",
        "unknown Webhook event \"pullreq\". see https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#webhook-events for list of all Webhook event names",
      ],
    ),
    (
      "workflow-dispatch-inputs",
      [
        "input type of \"choice_input_no_options\" is \"choice\" but \"options\" is not set",
        "type of \"boolean_invalid_default\" input is \"boolean\". its default value \"foo\" must be \"true\" or \"false\"",
        "option \"foo\" is duplicated in options of \"choice_duplicate_options\" input",
      ],
    ),
    (
      "glob-patterns",
      [
        "character '^' is invalid for branch and tag names. ref name cannot contain spaces, ~, ^, :, [, ?, *. see `man git-check-ref-format` for more details. note that regular expression is unavailable. note: filter pattern syntax is explained at https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions#filter-pattern-cheat-sheet",
        "invalid glob pattern. unexpected character ']' while checking character match []. character match with single character is useless. simply use x instead of [x]. note: filter pattern syntax is explained at https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions#filter-pattern-cheat-sheet",
        "leading and trailing spaces are not allowed in glob path. note: filter pattern syntax is explained at https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions#filter-pattern-cheat-sheet",
      ],
    ),
    (
      "cron-and-timezone",
      [
        "invalid CRON format \"0 */3 * *\" in schedule event: expected exactly 5 fields, found 4: [0 */3 * *]",
        "scheduled job runs too frequently. it runs once per 60 seconds. the shortest interval is once every 5 minutes",
        "invalid timezone \"Asia/Somewhere\" in schedule event. it must be a valid IANA timezone name",
      ],
    ),
    (
      "runner-label",
      [
        "label \"windows-latest\" conflicts with label \"ubuntu-latest\" defined at line:8,col:15. note: to run your job on each workers, use matrix",
        // Reconstructed: `testdata/err/invalid_runner_labels.out` records this
        // shape only as a regex assertion (`label "ubuntu-oldest" is
        // unknown\. available labels are .+\. if it is a custom label for
        // self-hosted runner, set list of labels in actionlint.yaml config
        // file`) because the available-labels list is dynamic. This is the
        // exact shape of a real `.github/actionlint.yaml` ignore entry (see
        // `fixtures/upstream/actionlint/testdata/projects/paths_config/`),
        // so it is filled in here with a representative label list.
         "label \"ubuntu-oldest\" is unknown. available labels are \"ubuntu-latest\", \"ubuntu-22.04\", \"ubuntu-24.04\", \"windows-latest\", \"windows-2022\", \"macos-latest\". if it is a custom label for self-hosted runner, set list of labels in actionlint.yaml config file",
      ],
    ),
    (
      "uses-syntax",
      [
        "specifying action \"actions/checkout\" in invalid format because ref is missing. available formats are \"{owner}/{repo}@{ref}\" or \"{owner}/{repo}/{path}@{ref}\"",
        "specifying action \"checkout@v2\" in invalid format because owner is missing. available formats are \"{owner}/{repo}@{ref}\" or \"{owner}/{repo}/{path}@{ref}\"",
        "tag of Docker action should not be empty: \"docker://image\"",
      ],
    ),
    (
      "outdated-popular-action-version",
      [
        "the runner of \"actions/checkout@v2\" action is too old to run on GitHub Actions. update the action's version to fix this issue",
        "the runner of \"actions/stale@v4\" action is too old to run on GitHub Actions. update the action's version to fix this issue",
      ],
    ),
    (
      "shell-name",
      [
        "shell name \"dash\" is invalid. available names are \"bash\", \"pwsh\", \"python\", \"sh\"",
        "shell name \"powershell\" is invalid on macOS or Linux. available names are \"bash\", \"pwsh\", \"python\", \"sh\"",
        "shell name \"sh\" is invalid on Windows. available names are \"bash\", \"cmd\", \"powershell\", \"pwsh\", \"python\"",
      ],
    ),
    (
      "duplicate-job-step-ids",
      [
        "step ID \"STEP_ID\" duplicates. previously defined at line:7,col:13. step ID must be unique within a job. note that step ID is case insensitive",
        "key \"TEST\" is duplicated in \"jobs\" section. previously defined at line:3,col:3. note that this key is case insensitive",
      ],
    ),
    (
      "env-var-name",
      [
        "environment variable name \"FOO=BAR\" is invalid. '&', '=' and spaces should not be contained",
        "environment variable name \"FOO BAR\" is invalid. '&', '=' and spaces should not be contained",
      ],
    ),
    (
      "permissions-scope-and-value",
      [
        "\"write\" is invalid for permission for all the scopes. available values are \"read-all\", \"write-all\" or {}",
        "unknown permission scope \"check\". all available permission scopes are \"actions\", \"artifact-metadata\", \"attestations\", \"checks\", \"contents\", \"deployments\", \"discussions\", \"id-token\", \"issues\", \"models\", \"packages\", \"pages\", \"pull-requests\", \"repository-projects\", \"security-events\", \"statuses\"",
        "\"readable\" is invalid as permission of scope \"issues\". available values are \"read\", \"write\", \"none\"",
      ],
    ),
    (
      "reusable-workflow",
      [
        "when a reusable workflow is called with \"uses\", \"steps\" is not available. only following keys are allowed: \"name\", \"uses\", \"with\", \"secrets\", \"needs\", \"if\", and \"permissions\" in job \"call1\"",
        "reusable workflow call \"./foo/bar/workflow.yml@main\" at \"uses\" is not following the format \"owner/repo/path/to/workflow.yml@ref\" nor \"./path/to/workflow.yml\". see https://docs.github.com/en/actions/learn-github-actions/reusing-workflows for more details",
        "error while parsing reusable workflow \"./reusable/no_hook.yaml\": \"workflow_call\" event trigger is not found in \"on:\" at line:1, column:5",
      ],
    ),
    (
      "job-step-id-naming",
      [
        "invalid job ID \"-foo\". job ID must start with a letter or _ and contain only alphanumeric characters, -, or _",
        "invalid step ID \"-foo\". step ID must start with a letter or _ and contain only alphanumeric characters, -, or _",
        "invalid job ID \"1-2-3\". job ID must start with a letter or _ and contain only alphanumeric characters, -, or _",
      ],
    ),
    (
      "deprecated-workflow-commands",
      [
        "workflow command \"set-output\" was deprecated. use `echo \"{name}={value}\" >> $GITHUB_OUTPUT` instead: https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions",
        "workflow command \"set-env\" was deprecated. use `echo \"{name}={value}\" >> $GITHUB_ENV` instead: https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions",
        "workflow command \"add-path\" was deprecated. use `echo \"{path}\" >> $GITHUB_PATH` instead: https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions",
      ],
    ),
    (
      "constant-if-condition",
      [
        "constant expression \"true\" in condition. remove the if: section", "constant expression \"true && 42 || !null\" in condition. remove the if: section",
        "constant expression \"contains(format('{0} {1} {2}', 'foo', 'bar', 'piyo'), 'o b')\" in condition. remove the if: section",
      ],
    ),
    (
      "action-yml-metadata",
      [
        // Reconstructed: `testdata/examples/action_metadata_syntax_validation.out`
        // and `testdata/projects/local_action_invalid.out` record these only
        // as regex assertions (the action's file path is dynamic per test
        // run). Filled in with the literal path segments visible in the
        // pattern itself.
        "description is required in metadata of \"My action\" action at \"testdata/projects/local_action_invalid/no_desc/action.yaml\"",
        "could not parse action metadata in \"testdata/projects/local_action_invalid/unknown_key\": line 6: unexpected key \"foo\" for definition of input \"input1\"",
        "could not parse action metadata in \"testdata/projects/broken_local_action/duplicate_input\": line 5: input \"FOO\" is duplicated",
      ],
    ),
    (
      "yaml-anchors",
      [
        "anchor \"credentials\" is defined but not used", "recursive alias \"recursive\" is found. anchor was declared at line:19, column:9",
        "GitHub Actions does not support YAML merge key \"<<\"",
      ],
    ),
    (
      "hardcoded-credentials",
      [
        "\"password\" section in \"container\" section should be specified via secrets. do not put password value directly",
        "\"password\" section in \"redis\" service should be specified via secrets. do not put password value directly",
        "both \"username\" and \"password\" must be specified in \"credentials\" section",
      ],
    ),
  ]
}

///|
/// Map each actionlint check name (the part after `actionlint:` in the
/// catalogue's `origins`) to the karinto rule IDs that cover it. Mirrors
/// `ghalint_policy_map`, but actionlint origins carry no `(policy_name)`
/// parenthetical — the check name is the whole string after the prefix.
fn actionlint_check_map() -> Map[String, Array[String]] {
  let m : Map[String, Array[String]] = {}
  for spec in all_rule_specs() {
    for origin in spec.origins {
      guard index_of(origin, "actionlint:") is Some(0) else { continue }
      let name = origin[11:].to_owned()
      let ids = match m.get(name) {
        Some(existing) => existing
        None => {
          let fresh : Array[String] = []
          m[name] = fresh
          fresh
        }
      }
      ids.push(spec.id)
    }
  }
  m
}

///|
/// A resolved `paths.<glob>:` entry: the glob and the karinto rule IDs its
/// `ignore` patterns were fingerprinted to (via `actionlint_canonical_messages`
/// + `actionlint_check_map`), computed once per `lint()` call rather than
/// per diagnostic.
priv struct ActionlintExclude {
  glob : String
  rule_ids : Array[String]
}

///|
/// Resolve each `paths.<glob>:`'s raw `ignore` patterns to the karinto rule
/// IDs they target. A pattern that fails to compile, or matches none of the
/// curated canonical samples, contributes nothing (best-effort). A pattern
/// matching several checks' samples (a broad pattern, or one of the shared-
/// template checks — see the file doc comment) contributes every one of
/// their rule IDs.
fn resolve_actionlint_excludes(
  path_ignores : Array[ActionlintPathIgnore],
  check_map : Map[String, Array[String]],
) -> Array[ActionlintExclude] {
  let canonical = actionlint_canonical_messages()
  let out : Array[ActionlintExclude] = []
  for pi in path_ignores {
    let rule_ids : Array[String] = []
    for pattern in pi.patterns {
      let compiled = try? @regexp.compile(pattern)
      guard compiled is Ok(re) else { continue }
      for entry in canonical {
        let (check, samples) = entry
        let mut hit = false
        for s in samples {
          if re.execute(s).matched() {
            hit = true
            break
          }
        }
        if hit {
          match check_map.get(check) {
            Some(ids) =>
              for id in ids {
                if !rule_ids.contains(id) {
                  rule_ids.push(id)
                }
              }
            None => ()
          }
        }
      }
    }
    if rule_ids.length() > 0 {
      out.push(ActionlintExclude::{ glob: pi.glob, rule_ids })
    }
  }
  out
}

///|
/// Whether diagnostic `d` is excluded by any resolved actionlint `paths.
/// <glob>` entry: its rule must be among the entry's resolved rule IDs, and
/// the file under lint must match the glob (`path_glob_match`, the same
/// gitignore-style, `/`-segment-aware matcher `karinto_config`'s
/// `ignore-paths` uses — not the segment-blind `glob_match` used for rule-ID
/// wildcards, which would let a bare `*` cross a `/` and over-suppress). An
/// empty `file_path` matches nothing, mirroring every other path-scoped
/// exclude in this engine.
fn actionlint_excluded(
  d : Diagnostic,
  excludes : Array[ActionlintExclude],
  file_path : String,
) -> Bool {
  if file_path == "" {
    return false
  }
  let f = strip_dot_slash(file_path)
  for e in excludes {
    if !e.rule_ids.contains(d.rule) {
      continue
    }
    if path_glob_match(strip_dot_slash(e.glob), f) {
      return true
    }
  }
  false
}
