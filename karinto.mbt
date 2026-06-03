///|
/// karinto — GitHub Actions linter library.
///
/// Lints a YAML workflow or action file. Rules are inspired by actionlint,
/// zizmor, and ghalint (all MIT). See THIRD_PARTY_LICENSES.md for attribution.

///|
pub(all) enum FileKind {
  Workflow
  Action
  Unknown
} derive(Eq, Debug)

///|
pub(all) enum Severity {
  Error
  Warning
  Info
} derive(Eq, Debug)

///|
pub(all) struct Position {
  line : Int
  col : Int
} derive(Eq, Debug, ToJson)

///|
/// Identifies the step a finding belongs to, within its owning job (or, for
/// composite actions, within the action's `runs.steps`).
///
/// - `index`: 0-based position of the step in the steps list. Always present,
///   so a step is locatable even when it declares no `id:`.
/// - `id`: the step's `id:` value when declared.
pub(all) struct StepRef {
  index : Int
  id : String?
} derive(Eq, Debug)

///|
pub(all) struct Diagnostic {
  rule : String
  severity : Severity
  message : String
  pos : Position?
  // Owning job's ID (the key under `jobs:`). `None` for workflow-global
  // findings and for action-file steps (which have no job).
  job : String?
  // The step a finding is about, when the finding is step-scoped.
  step : StepRef?
} derive(Eq, Debug)

///|
pub impl ToJson for Severity with to_json(self) {
  match self {
    Error => "error"
    Warning => "warning"
    Info => "info"
  }
}

///|
pub impl ToJson for StepRef with to_json(self) {
  let m : Map[String, Json] = { "index": self.index.to_json() }
  match self.id {
    Some(id) => m["id"] = id.to_json()
    None => ()
  }
  m.to_json()
}

///|
pub impl ToJson for Diagnostic with to_json(self) {
  let m : Map[String, Json] = {
    "rule": self.rule.to_json(),
    "severity": self.severity.to_json(),
    "message": self.message.to_json(),
  }
  match self.pos {
    Some(p) => m["pos"] = p.to_json()
    None => ()
  }
  match self.job {
    Some(j) => m["job"] = j.to_json()
    None => ()
  }
  match self.step {
    Some(s) => m["step"] = s.to_json()
    None => ()
  }
  m.to_json()
}

///|
pub(all) struct Stats {
  jobs : Int
  steps : Int
  lines : Int
} derive(Eq, Debug, ToJson)

///|
pub(all) struct LintResult {
  kind : FileKind
  stats : Stats
  diagnostics : Array[Diagnostic]
  parse_error : String?
}

///|
pub impl ToJson for FileKind with to_json(self) {
  match self {
    Workflow => "workflow"
    Action => "action"
    Unknown => "unknown"
  }
}

///|
pub impl ToJson for LintResult with to_json(self) {
  let m : Map[String, Json] = {
    "kind": self.kind.to_json(),
    "stats": self.stats.to_json(),
    "diagnostics": self.diagnostics.to_json(),
  }
  match self.parse_error {
    Some(e) => m["parse_error"] = e.to_json()
    None => ()
  }
  m.to_json()
}

///|
/// Lint a YAML document.
///
/// - `content`: the YAML source.
/// - `kind`: explicit file kind. `Unknown` triggers heuristic detection.
/// - `disabled`: glob patterns of rule IDs to skip.
///
/// Inline comments of the form `# karinto: ignore[a, b]`,
/// `# zizmor: ignore[a]`, `# ghalint: ignore[a]`, or `# actionlint: ignore[a]`
/// found anywhere in `content` extend `disabled` for the file. Karinto
/// honours every upstream's syntax so vendored workflows lint cleanly when
/// the author already opted out of a specific finding with the tool that
/// originally fired it.
pub fn lint(
  content : String,
  kind? : FileKind = Unknown,
  disabled? : Array[String] = [],
  vuln_uses? : Array[String] = [],
  forbidden_uses? : Array[String] = [],
  archived_uses? : Array[String] = [],
) -> LintResult {
  let lines = count_lines(content)
  let merged_disabled = merge_inline_ignores(content, disabled)
  let docs = try? @yaml.Yaml::load_from_string(content)
  match docs {
    Err(e) =>
      LintResult::{
        kind,
        stats: Stats::{ jobs: 0, steps: 0, lines },
        diagnostics: [],
        parse_error: Some(e.to_string()),
      }
    Ok(arr) => {
      let doc = if arr.length() > 0 { arr[0] } else { @yaml.Yaml::Null }
      let resolved_kind = match kind {
        Unknown => detect_kind(doc)
        _ => kind
      }
      let stats = compute_stats(doc, lines)
      let diagnostics = run_rules(
        doc, resolved_kind, merged_disabled, vuln_uses, content, forbidden_uses,
        archived_uses,
      )
      LintResult::{ kind: resolved_kind, stats, diagnostics, parse_error: None }
    }
  }
}

///|
/// Scans `content` for `# <tool>: ignore[a, b]` directives and returns the
/// union of `disabled` with the collected rule IDs. Tool names accepted:
/// karinto, zizmor, ghalint, actionlint. Rule IDs are trimmed; empty
/// brackets and missing comments are no-ops.
fn merge_inline_ignores(
  content : String,
  disabled : Array[String],
) -> Array[String] {
  let extra : Array[String] = []
  let tools = ["karinto", "zizmor", "ghalint", "actionlint"]
  for line in content.split("\n") {
    let s = line.to_owned()
    for tool in tools {
      let needle = tool + ": ignore["
      match index_of(s, needle) {
        Some(i) => {
          let after = s[i + needle.length():].to_owned()
          match index_of(after, "]") {
            Some(j) => {
              let inner = after[0:j].to_owned()
              for part in inner.split(",") {
                let trimmed = trim_ws(part.to_owned())
                if trimmed.length() > 0 {
                  extra.push(trimmed)
                }
              }
            }
            None => ()
          }
        }
        None => ()
      }
    }
  }
  if extra.length() == 0 {
    return disabled
  }
  let merged : Array[String] = []
  for d in disabled {
    merged.push(d)
  }
  for d in extra {
    merged.push(d)
  }
  merged
}

///|
fn index_of(s : String, needle : String) -> Int? {
  let n = s.length()
  let m = needle.length()
  if m == 0 || m > n {
    return None
  }
  let mut i = 0
  while i + m <= n {
    if s[i:i + m].to_owned() == needle {
      return Some(i)
    }
    i = i + 1
  }
  None
}

///|
fn trim_ws(s : String) -> String {
  s.trim(chars=" \t\r").to_owned()
}

///|
fn count_lines(s : String) -> Int {
  let mut n = 1
  for ch in s {
    if ch == '\n' {
      n = n + 1
    }
  }
  n
}

///|
fn detect_kind(doc : @yaml.Yaml) -> FileKind {
  match doc {
    Map(m) =>
      if m.contains("jobs") || m.contains("on") {
        Workflow
      } else if m.contains("runs") {
        Action
      } else {
        Unknown
      }
    _ => Unknown
  }
}

///|
fn compute_stats(doc : @yaml.Yaml, lines : Int) -> Stats {
  let mut jobs = 0
  let mut steps = 0
  match doc {
    Map(m) =>
      match m.get("jobs") {
        Some(Map(js)) => {
          jobs = js.length()
          js.each(fn(_k, v) {
            match v {
              Map(jm) =>
                match jm.get("steps") {
                  Some(Array(s)) => steps = steps + s.length()
                  _ => ()
                }
              _ => ()
            }
          })
        }
        _ => ()
      }
    _ => ()
  }
  Stats::{ jobs, steps, lines }
}

///|
fn run_rules(
  doc : @yaml.Yaml,
  kind : FileKind,
  disabled : Array[String],
  vuln_uses : Array[String],
  source : String,
  forbidden_uses : Array[String],
  archived_uses : Array[String],
) -> Array[Diagnostic] {
  let ctx = prewalk(
    doc,
    vuln_uses~,
    kind~,
    source~,
    forbidden_uses~,
    archived_uses~,
  )
  let out : Array[Diagnostic] = []

  // Filter once. Each scope iterates pre-built callback arrays — no per-step
  // option-match overhead.
  let doc_cbs : Array[(WalkCtx, Array[Diagnostic]) -> Unit] = []
  let job_cbs : Array[(WalkCtx, JobInfo, Array[Diagnostic]) -> Unit] = []
  let step_cbs : Array[(WalkCtx, StepInfo, Array[Diagnostic]) -> Unit] = []
  for rule in all_rules() {
    if is_disabled(rule.id, disabled) {
      continue
    }
    if !(rule.applies)(kind) {
      continue
    }
    match rule.on_doc {
      Some(f) => doc_cbs.push(f)
      None => ()
    }
    match rule.on_job {
      Some(f) => job_cbs.push(f)
      None => ()
    }
    match rule.on_step {
      Some(f) => step_cbs.push(f)
      None => ()
    }
  }

  // Doc scope.
  for f in doc_cbs {
    f(ctx, out)
  }
  // Step scope (workflow + action steps). Run before job scope so step-level
  // findings precede the job-level conclusions they may inform (e.g. checkout
  // persist-credentials-false before artipacked).
  if step_cbs.length() > 0 {
    for s in ctx.workflow_steps {
      let start = out.length()
      for f in step_cbs {
        f(ctx, s, out)
      }
      stamp_step(out, start, s)
    }
    for s in ctx.action_steps {
      let start = out.length()
      for f in step_cbs {
        f(ctx, s, out)
      }
      stamp_step(out, start, s)
    }
  }
  // Job scope.
  if job_cbs.length() > 0 {
    for j in ctx.jobs {
      let start = out.length()
      for f in job_cbs {
        f(ctx, j, out)
      }
      stamp_job(out, start, j.name)
    }
  }
  out
}

///|
/// Attach step (and owning-job) context to every diagnostic a step-scoped
/// rule pushed during its callback. A step rule only ever reasons about the
/// single step it was handed, so any finding it produced is about that step.
/// Pre-existing context is preserved — a rule that already set `job`/`step`
/// explicitly wins.
fn stamp_step(out : Array[Diagnostic], start : Int, s : StepInfo) -> Unit {
  let sref = StepRef::{ index: s.step_index, id: s.id }
  let mut k = start
  while k < out.length() {
    let d = out[k]
    let job = match d.job {
      Some(_) => d.job
      None => s.job
    }
    let step = match d.step {
      Some(_) => d.step
      None => Some(sref)
    }
    out[k] = Diagnostic::{ ..d, job, step }
    k = k + 1
  }
}

///|
/// Attach the owning job's ID to every diagnostic a job-scoped rule pushed,
/// unless the rule already set one (e.g. a more specific step context).
fn stamp_job(out : Array[Diagnostic], start : Int, name : String) -> Unit {
  let mut k = start
  while k < out.length() {
    let d = out[k]
    match d.job {
      Some(_) => ()
      None => out[k] = Diagnostic::{ ..d, job: Some(name) }
    }
    k = k + 1
  }
}

///|
fn is_disabled(rule_id : String, disabled : Array[String]) -> Bool {
  for pat in disabled {
    if glob_match(pat, rule_id) {
      return true
    }
  }
  false
}

///|
/// Glob match with `*` (any run) and `?` (single char). Two-pointer with
/// last-star backtrack — eliminates exponential blowup (e.g. `*a*a*…*b`
/// vs `aaaa…`); worst case is O(m·n) when the post-`*` suffix has to be
/// rescanned at each text position (`*aaab` vs `aaaa…`). The Worker caps
/// `disable=` patterns at 128 chars / 64 entries so the bound is small
/// enough that DoS via this path is not feasible.
fn glob_match(pat : String, s : String) -> Bool {
  let p = pat.to_array()
  let t = s.to_array()
  let m = p.length()
  let n = t.length()
  let mut i = 0
  let mut j = 0
  let mut star = -1
  let mut restart = 0
  while j < n {
    // Wildcard must be checked before the literal/`?` branch — otherwise
    // a text char that happens to equal `*` would be consumed as a
    // literal instead of recording the wildcard position.
    if i < m && p[i] == '*' {
      star = i
      restart = j
      i = i + 1
    } else if i < m && (p[i] == '?' || p[i] == t[j]) {
      i = i + 1
      j = j + 1
    } else if star >= 0 {
      // Rewind to the last `*` and advance the text cursor by one.
      i = star + 1
      restart = restart + 1
      j = restart
    } else {
      return false
    }
  }
  while i < m && p[i] == '*' {
    i = i + 1
  }
  i == m
}
