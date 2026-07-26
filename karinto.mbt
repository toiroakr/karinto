///|
/// karinto — GitHub Actions linter library.
///
/// Lints a YAML workflow or action file. Rules are inspired by actionlint,
/// zizmor, and ghalint (all MIT). See THIRD_PARTY_LICENSES.md for attribution.

///|
pub(all) enum FileKind {
  Workflow
  Action
  Dependabot
  Unknown
} derive(Eq, Debug)

///|
pub(all) enum Severity {
  Error
  Warning
  Info
} derive(Eq, Debug)

///|
/// Analysis profile, mirroring zizmor's persona model. A finding declares the
/// *minimum* persona at which it surfaces; a request shows every finding whose
/// minimum is at or below the requested persona (`Regular ⊂ Pedantic ⊂
/// Auditor`).
///
/// - `Regular`: high-confidence, real problems (zizmor's default).
/// - `Pedantic`: also code smells and likely-safe-but-noisy findings (e.g. the
///   template-injection backstop on every `${{ … }}`).
/// - `Auditor`: also low-confidence / defense-in-depth findings (e.g.
///   `secrets-outside-env`).
///
/// Findings default to `Regular`; only rules that mirror zizmor's
/// pedantic/auditor-gated behaviour tag themselves higher.
pub(all) enum Persona {
  Regular
  Pedantic
  Auditor
} derive(Eq, Debug)

///|
/// Inclusion order: a request at `want` shows a finding tagged `have` iff
/// `persona_rank(have) <= persona_rank(want)`.
fn persona_rank(p : Persona) -> Int {
  match p {
    Regular => 0
    Pedantic => 1
    Auditor => 2
  }
}

///|
/// Parse a persona string (`"regular"` / `"pedantic"` / `"auditor"`). Anything
/// else — including `""` — resolves to `Auditor`, the default that preserves
/// karinto's historical "report everything" behaviour.
pub fn persona_from_string(s : String) -> Persona {
  match s {
    "regular" => Regular
    "pedantic" => Pedantic
    _ => Auditor
  }
}

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
  // Minimum persona at which this finding surfaces. Internal gating attribute;
  // intentionally absent from `to_json` so the response schema is unchanged.
  persona : Persona
} derive(Eq, Debug)

///|
pub impl ToJson for Severity with fn to_json(self) {
  match self {
    Error => "error"
    Warning => "warning"
    Info => "info"
  }
}

///|
pub impl ToJson for StepRef with fn to_json(self) {
  let m : Map[String, Json] = { "index": self.index.to_json() }
  match self.id {
    Some(id) => m["id"] = id.to_json()
    None => ()
  }
  m.to_json()
}

///|
pub impl ToJson for Diagnostic with fn to_json(self) {
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
  // Findings that were generated but suppressed by an inline ignore comment,
  // a ghalint/zizmor config exclude, or the persona gate. Omitted from JSON
  // when empty so the response schema is unchanged for existing callers.
  ignored : Array[Diagnostic]
}

///|
pub impl ToJson for FileKind with fn to_json(self) {
  match self {
    Workflow => "workflow"
    Action => "action"
    Dependabot => "dependabot"
    Unknown => "unknown"
  }
}

///|
pub impl ToJson for LintResult with fn to_json(self) {
  let m : Map[String, Json] = {
    "kind": self.kind.to_json(),
    "stats": self.stats.to_json(),
    "diagnostics": self.diagnostics.to_json(),
  }
  match self.parse_error {
    Some(e) => m["parse_error"] = e.to_json()
    None => ()
  }
  if self.ignored.length() > 0 {
    m["ignored"] = self.ignored.to_json()
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
/// Inline comments of the form `# karinto: ignore[a, b]` or
/// `# zizmor: ignore[a]` suppress findings *on the same line* as the comment,
/// line-scoped rather than file-global — except workflow-scoped findings that
/// carry no source position (e.g. `cache-poisoning`), which fall back to a
/// file-wide match against any inline ignore in the file that names the rule.
/// A trailing explanation is allowed
/// (`# zizmor: ignore[a] reason here`) and several rules may be listed with
/// commas. Of the upstreams Karinto consolidates, only zizmor ships an inline
/// ignore syntax — actionlint and ghalint opt out via config files, so they
/// have no comment form to honour. Karinto matches zizmor's so vendored
/// workflows lint cleanly when the author already opted out of a finding
/// where it fires.
///
/// - `file_path`: the path of the file under lint, relative to the repo root.
///   Used only to scope `ghalint_config` excludes by `workflow_file_path`;
///   leave empty to apply path-less excludes only.
/// - `ghalint_config`: the raw text of a ghalint config (`ghalint.yaml`). Its
///   `excludes` are mapped onto karinto rules via the catalogue's `origins`
///   and applied with their `workflow_file_path` / `job_name` / `action_name`
///   / `step_id` scoping. actionlint configs are not honoured: they ignore by
///   regex against tool-specific messages, which do not map onto karinto.
pub fn lint(
  content : String,
  kind? : FileKind = Unknown,
  disabled? : Array[String] = [],
  vuln_uses? : Array[String] = [],
  forbidden_uses? : Array[String] = [],
  archived_uses? : Array[String] = [],
  persona? : Persona = Auditor,
  file_path? : String = "",
  ghalint_config? : String = "",
  zizmor_config? : String = "",
) -> LintResult {
  let lines = count_lines(content)
  // Inline ignores: parsed up front, applied as a post-pass (below) rather than
  // folded into the file-global `disabled` set. Positioned findings match
  // line-scoped; position-less findings fall back to a file-wide match.
  let inline_ignores = parse_inline_ignores(content)
  // ghalint config excludes (if any): parsed up front, applied as a post-pass
  // (below) scoped by file path / job / step / action.
  let ghalint_excludes = if ghalint_config == "" {
    []
  } else {
    parse_ghalint_excludes(ghalint_config)
  }
  let ghalint_policies = if ghalint_excludes.length() > 0 {
    ghalint_policy_map()
  } else {
    {}
  }
  // zizmor config (if any): `rules.<id>.disable` / `.ignore`, applied as a
  // post-pass below alongside the inline-ignore and ghalint-exclude passes.
  let zizmor_cfg = if zizmor_config == "" {
    ZizmorConfig::{ disabled: [], ignores: {} }
  } else {
    parse_zizmor_config(zizmor_config)
  }
  // Single parse pass: the value tree (for rules), the position node tree, and
  // the line counter all come from one lex+parse of `content`.
  try @yaml.parse_for_lint(content) catch {
    e =>
      LintResult::{
        kind,
        stats: Stats::{ jobs: 0, steps: 0, lines },
        diagnostics: [],
        parse_error: Some(e.message()),
        ignored: [],
      }
  } noraise {
    lp => {
      let doc = if lp.documents.length() > 0 {
        lp.documents[0]
      } else {
        @yaml.Yaml::Null
      }
      let resolved_kind = match kind {
        Unknown => detect_kind(doc)
        _ => kind
      }
      let stats = compute_stats(doc, lines)
      let diagnostics = run_rules(
        doc,
        resolved_kind,
        disabled,
        vuln_uses,
        content,
        forbidden_uses,
        archived_uses,
        lp.position_root,
        Some(lp.line_counter),
      )
      // Stamp line/column positions onto job- and step-scoped findings from the
      // position node tree. Best-effort: absent positions leave `pos = None`.
      fill_positions(diagnostics, lp.position_root, lp.line_counter)
      // Inline ignores: drop a positioned finding when its line carries a
      // `# <tool>: ignore[...]` directive matching the rule. Findings without a
      // resolved line fall back to a file-wide match — any inline ignore in the
      // file that names the rule suppresses them. ghalint excludes drop findings
      // by policy/file/job/step/action scope (line-independent).
      // Suppressed findings are collected into `ignored` rather than discarded
      // so callers can inspect what was silenced.
      let ignored : Array[Diagnostic] = []
      let kept : Array[Diagnostic] = []
      for d in diagnostics {
        if is_inline_ignored(d, inline_ignores) {
          ignored.push(d)
        } else if ghalint_excludes.length() > 0 &&
          ghalint_excluded(
            d, ghalint_excludes, ghalint_policies, file_path, doc,
          ) {
          ignored.push(d)
        } else if zizmor_config != "" &&
          zizmor_config_excluded(d, zizmor_cfg, file_path) {
          ignored.push(d)
        } else {
          kept.push(d)
        }
      }
      // Persona gate: keep findings whose minimum persona is at or below the
      // requested one. `Auditor` (the default) keeps everything.
      let want = persona_rank(persona)
      let visible : Array[Diagnostic] = []
      for d in kept {
        if persona_rank(d.persona) <= want {
          visible.push(d)
        } else {
          ignored.push(d)
        }
      }
      LintResult::{
        kind: resolved_kind,
        stats,
        diagnostics: visible,
        parse_error: None,
        ignored,
      }
    }
  }
}

///|
/// Maps a 1-based source line number to the rule-id patterns an inline
/// `# <tool>: ignore[...]` comment opts out on that line.
fn parse_inline_ignores(content : String) -> Map[Int, Array[String]] {
  let by_line : Map[Int, Array[String]] = {}
  // Only zizmor ships an inline ignore syntax among the upstreams Karinto
  // consolidates; `karinto` is our own alias. actionlint and ghalint opt out
  // via config files, so they have no comment form to scan for.
  let tools = ["karinto", "zizmor"]
  let mut lineno = 1
  for line in content.split("\n") {
    let s = line.to_owned()
    // The directive is only honoured inside a real YAML line comment. A `#`
    // that sits in a quoted scalar (e.g. `run: echo "# zizmor: ignore[x]"`)
    // is data, not a comment, so we scan only the comment body — not the whole
    // line — to keep such scalars from suppressing findings.
    guard comment_start(s) is Some(cs) else {
      lineno = lineno + 1
      continue
    }
    let comment = s[cs:].to_owned()
    for tool in tools {
      let needle = tool + ": ignore["
      match index_of(comment, needle) {
        Some(i) => {
          let after = comment[i + needle.length():].to_owned()
          // Stop at the closing bracket; anything after `]` (e.g. a trailing
          // `# zizmor: ignore[rule] explanation`) is a free-form note.
          match index_of(after, "]") {
            Some(j) => {
              let inner = after[0:j].to_owned()
              let pats = match by_line.get(lineno) {
                Some(existing) => existing
                None => {
                  let fresh : Array[String] = []
                  by_line[lineno] = fresh
                  fresh
                }
              }
              for part in inner.split(",") {
                let trimmed = trim_ws(part.to_owned())
                if trimmed.length() > 0 {
                  pats.push(trimmed)
                }
              }
            }
            None => ()
          }
        }
        None => ()
      }
    }
    lineno = lineno + 1
  }
  by_line
}

///|
/// Returns the code-unit index just past the `#` that opens a YAML line
/// comment on `s`, or `None` when the line has no comment. A `#` starts a
/// comment only when it is at the start of the line or preceded by whitespace
/// AND it sits outside any quoted scalar; a `#` inside a quoted string is
/// data. Scanning is done in UTF-16 code units — `#`, the quote characters,
/// and ASCII whitespace are all single code units, and surrogate halves never
/// collide with them, so the returned index always lands on a char boundary.
fn comment_start(s : String) -> Int? {
  let len = s.length()
  let mut i = 0
  // Start-of-line counts as "preceded by whitespace" for the leading `#`.
  let mut prev_ws = true
  while i < len {
    let c = s.unsafe_get(i).to_int()
    if c == '\'' {
      // Single-quoted scalar: `''` is a literal quote, a lone `'` closes it.
      i = i + 1
      while i < len {
        if s.unsafe_get(i).to_int() == '\'' {
          if i + 1 < len && s.unsafe_get(i + 1).to_int() == '\'' {
            i = i + 2
          } else {
            i = i + 1
            break
          }
        } else {
          i = i + 1
        }
      }
      prev_ws = false
    } else if c == '"' {
      // Double-quoted scalar: `\` escapes the next code unit.
      i = i + 1
      while i < len {
        let d = s.unsafe_get(i).to_int()
        if d == '\\' {
          i = i + 2
        } else if d == '"' {
          i = i + 1
          break
        } else {
          i = i + 1
        }
      }
      prev_ws = false
    } else if c == '#' && prev_ws {
      return Some(i + 1)
    } else {
      prev_ws = c == ' ' || c == '\t'
      i = i + 1
    }
  }
  None
}

///|
/// Whether `d` is suppressed by an inline ignore comment. Positioned findings
/// are line-scoped: only an ignore on the finding's own line counts. A finding
/// with no resolved position cannot be line-scoped, so it falls back to a
/// file-wide match — any inline ignore in the file that names the rule
/// suppresses it. This keeps workflow-scoped findings (e.g. `cache-poisoning`,
/// emitted once per workflow without a step/job anchor) honourable, instead of
/// silently dropping the opt-out because the finding carries no line.
fn is_inline_ignored(
  d : Diagnostic,
  inline_ignores : Map[Int, Array[String]],
) -> Bool {
  guard d.pos is Some(p) else {
    for _, pats in inline_ignores {
      for pat in pats {
        if glob_match(pat, d.rule) {
          return true
        }
      }
    }
    return false
  }
  // Findings with no owning step (e.g. `undocumented-permissions`, which is
  // about a `permissions:` block rather than any one step) resolve `pos` to
  // that field's own line, or the job's key line (`  build:`) absent a more
  // specific field. Besides that line itself, also honour a "disable next
  // line" comment placed on the line directly above it — that reads more
  // naturally than a trailing comment there and mirrors how many linters'
  // next-line pragmas work. Step-scoped findings stay strictly same-line: a
  // step's own line is always the intuitive, unambiguous place, and
  // consecutive steps commonly trip the same rule, so a look-behind there
  // would risk suppressing the wrong step.
  let candidates = if d.step is None { [p.line, p.line - 1] } else { [p.line] }
  for candidate in candidates {
    match inline_ignores.get(candidate) {
      Some(pats) =>
        for pat in pats {
          if glob_match(pat, d.rule) {
            return true
          }
        }
      None => ()
    }
  }
  false
}

///|
fn index_of(s : String, needle : String) -> Int? {
  // Delegate to the stdlib substring search. The previous hand-rolled scan
  // sliced `s[i:i + m]` at every code-unit position, which panics when a
  // boundary splits a surrogate pair (e.g. content containing emoji); `find`
  // returns a code-unit offset on a char boundary, matching how callers slice
  // the result. Empty needle keeps the old "no match" contract.
  if needle.length() == 0 {
    return None
  }
  s.find(needle)
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
      } else if m.contains("updates") {
        // Dependabot config (`.github/dependabot.yml`): `updates:` is unique to
        // it — workflows/actions never carry a top-level `updates` key.
        Dependabot
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
  position_root : @yaml.Node?,
  line_counter : @yaml.LineCounter?,
) -> Array[Diagnostic] {
  let ctx = prewalk(
    doc,
    vuln_uses~,
    kind~,
    source~,
    forbidden_uses~,
    archived_uses~,
    position_root~,
    line_counter~,
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
