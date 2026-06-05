///|
/// Minimal GitHub Actions expression parser and type model.
///
/// Backs the expression typing rule family (`expression-needs-type`,
/// `expression-steps-type`, `expression-matrix-type`,
/// `expression-type-mismatch`). The model is intentionally small compared to
/// actionlint's full inference engine: contexts whose shape can be read from
/// the workflow itself (`needs`, `steps`, `matrix`) are typed strictly, every
/// other context (`github`, `env`, `inputs`, ...) types as `any` so unknown
/// shapes never produce false positives. Any expression the parser cannot
/// handle is silently skipped — these rules never report syntax errors.
/// (The separate `expression-syntax` rule covers delimiter mismatches such
/// as an unterminated `${{`; expression grammar beyond that is unchecked.)

// ---------------------------------------------------------------------------
// AST + tokens
// ---------------------------------------------------------------------------

///|
priv enum ExprNode {
  ENull
  EBool
  ENum
  EStr(String)
  EIdent(String)
  EDot(ExprNode, String) // property access; "*" is the object filter
  EIndex(ExprNode, ExprNode)
  ECall(String, Array[ExprNode])
  ENot(ExprNode)
  EBin(String, ExprNode, ExprNode)
}

///|
priv enum ExprTok {
  TkIdent(String)
  TkNum
  TkStr(String)
  TkOp(String)
}

///|
priv suberror ExprError

///|
/// Characters allowed inside a number literal after the first one. GitHub
/// expressions accept integers, floats, hex (`0x...`) and exponents; we only
/// need the token kind, not the value, so the scan is permissive. `prev` is
/// the previously consumed character so an exponent sign (`1e-5`) can be
/// told apart from an operator.
fn is_expr_num_cont(c : Char, prev : Char) -> Bool {
  (c >= '0' && c <= '9') ||
  c == '.' ||
  c == 'x' ||
  c == 'X' ||
  (c >= 'a' && c <= 'f') ||
  (c >= 'A' && c <= 'F') ||
  ((c == '+' || c == '-') && (prev == 'e' || prev == 'E'))
}

///|
fn char_str(c : Char) -> String {
  let buf = StringBuilder::new()
  buf.write_char(c)
  buf.to_string()
}

///|
fn lex_ga_expr(s : String) -> Array[ExprTok] raise ExprError {
  let chars = s.to_array()
  let n = chars.length()
  let out : Array[ExprTok] = []
  let mut i = 0
  while i < n {
    let c = chars[i]
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      i = i + 1
    } else if is_ident_start(c) {
      // Identifiers follow GitHub's property-name grammar, which allows `-`
      // (step ids like `my-step`); subtraction does not exist in the
      // expression language so the hyphen is unambiguous.
      let start = i
      while i < n && is_id_cont(chars[i]) {
        i = i + 1
      }
      let buf = StringBuilder::new()
      for k in start..<i {
        buf.write_char(chars[k])
      }
      out.push(TkIdent(buf.to_string()))
    } else if (c >= '0' && c <= '9') ||
      (c == '-' && i + 1 < n && chars[i + 1] >= '0' && chars[i + 1] <= '9') {
      i = i + 1
      while i < n && is_expr_num_cont(chars[i], chars[i - 1]) {
        i = i + 1
      }
      out.push(TkNum)
    } else if c == '\'' {
      i = i + 1
      let buf = StringBuilder::new()
      let mut closed = false
      while i < n {
        if chars[i] == '\'' {
          // `''` is an escaped quote inside a single-quoted literal.
          if i + 1 < n && chars[i + 1] == '\'' {
            buf.write_char('\'')
            i = i + 2
          } else {
            closed = true
            i = i + 1
            break
          }
        } else {
          buf.write_char(chars[i])
          i = i + 1
        }
      }
      if !closed {
        raise ExprError
      }
      out.push(TkStr(buf.to_string()))
    } else {
      let nxt = if i + 1 < n { chars[i + 1] } else { ' ' }
      if c == '=' && nxt == '=' {
        out.push(TkOp("=="))
        i = i + 2
      } else if c == '!' && nxt == '=' {
        out.push(TkOp("!="))
        i = i + 2
      } else if c == '<' && nxt == '=' {
        out.push(TkOp("<="))
        i = i + 2
      } else if c == '>' && nxt == '=' {
        out.push(TkOp(">="))
        i = i + 2
      } else if c == '&' && nxt == '&' {
        out.push(TkOp("&&"))
        i = i + 2
      } else if c == '|' && nxt == '|' {
        out.push(TkOp("||"))
        i = i + 2
      } else if c == '!' ||
        c == '<' ||
        c == '>' ||
        c == '(' ||
        c == ')' ||
        c == '[' ||
        c == ']' ||
        c == '.' ||
        c == ',' ||
        c == '*' ||
        c == '+' ||
        c == '/' ||
        c == '%' {
        out.push(TkOp(char_str(c)))
        i = i + 1
      } else {
        raise ExprError
      }
    }
  }
  out
}

// ---------------------------------------------------------------------------
// Parser (recursive descent, GA precedence: || < && < ==/!= < </<=/>/>= <
// arithmetic < unary < postfix). GitHub's language has no arithmetic
// operators; `+`/`*`/`/`/`%` are parsed anyway so the type-mismatch rule can
// diagnose them instead of silently skipping the expression.
// ---------------------------------------------------------------------------

///|
priv struct ExprParser {
  toks : Array[ExprTok]
  mut pos : Int
}

///|
fn ExprParser::peek_op(self : ExprParser, op : String) -> Bool {
  if self.pos < self.toks.length() {
    match self.toks[self.pos] {
      TkOp(o) => o == op
      _ => false
    }
  } else {
    false
  }
}

///|
fn ExprParser::eat_op(self : ExprParser, op : String) -> Bool {
  if self.peek_op(op) {
    self.pos = self.pos + 1
    true
  } else {
    false
  }
}

///|
fn ExprParser::expect_op(
  self : ExprParser,
  op : String,
) -> Unit raise ExprError {
  if !self.eat_op(op) {
    raise ExprError
  }
}

///|
fn ExprParser::parse_expr(self : ExprParser) -> ExprNode raise ExprError {
  let mut l = self.parse_and()
  while self.eat_op("||") {
    l = EBin("||", l, self.parse_and())
  }
  l
}

///|
fn ExprParser::parse_and(self : ExprParser) -> ExprNode raise ExprError {
  let mut l = self.parse_eq()
  while self.eat_op("&&") {
    l = EBin("&&", l, self.parse_eq())
  }
  l
}

///|
fn ExprParser::parse_eq(self : ExprParser) -> ExprNode raise ExprError {
  let mut l = self.parse_cmp()
  while true {
    if self.eat_op("==") {
      l = EBin("==", l, self.parse_cmp())
    } else if self.eat_op("!=") {
      l = EBin("!=", l, self.parse_cmp())
    } else {
      break
    }
  }
  l
}

///|
fn ExprParser::parse_cmp(self : ExprParser) -> ExprNode raise ExprError {
  let mut l = self.parse_add()
  while true {
    if self.eat_op("<=") {
      l = EBin("<=", l, self.parse_add())
    } else if self.eat_op("<") {
      l = EBin("<", l, self.parse_add())
    } else if self.eat_op(">=") {
      l = EBin(">=", l, self.parse_add())
    } else if self.eat_op(">") {
      l = EBin(">", l, self.parse_add())
    } else {
      break
    }
  }
  l
}

///|
fn ExprParser::parse_add(self : ExprParser) -> ExprNode raise ExprError {
  let mut l = self.parse_mul()
  while self.eat_op("+") {
    l = EBin("+", l, self.parse_mul())
  }
  l
}

///|
fn ExprParser::parse_mul(self : ExprParser) -> ExprNode raise ExprError {
  let mut l = self.parse_unary()
  while true {
    if self.eat_op("*") {
      l = EBin("*", l, self.parse_unary())
    } else if self.eat_op("/") {
      l = EBin("/", l, self.parse_unary())
    } else if self.eat_op("%") {
      l = EBin("%", l, self.parse_unary())
    } else {
      break
    }
  }
  l
}

///|
fn ExprParser::parse_unary(self : ExprParser) -> ExprNode raise ExprError {
  if self.eat_op("!") {
    ENot(self.parse_unary())
  } else {
    self.parse_postfix()
  }
}

///|
fn ExprParser::parse_postfix(self : ExprParser) -> ExprNode raise ExprError {
  let mut e = self.parse_primary()
  while true {
    if self.eat_op(".") {
      if self.eat_op("*") {
        e = EDot(e, "*")
      } else if self.pos < self.toks.length() {
        match self.toks[self.pos] {
          TkIdent(name) => {
            self.pos = self.pos + 1
            e = EDot(e, name)
          }
          _ => raise ExprError
        }
      } else {
        raise ExprError
      }
    } else if self.eat_op("[") {
      if self.eat_op("*") {
        self.expect_op("]")
        e = EDot(e, "*")
      } else {
        let idx = self.parse_expr()
        self.expect_op("]")
        e = EIndex(e, idx)
      }
    } else {
      break
    }
  }
  e
}

///|
fn ExprParser::parse_primary(self : ExprParser) -> ExprNode raise ExprError {
  if self.pos >= self.toks.length() {
    raise ExprError
  }
  let t = self.toks[self.pos]
  self.pos = self.pos + 1
  match t {
    TkNum => ENum
    TkStr(s) => EStr(s)
    TkIdent(name) => {
      if name == "true" || name == "false" {
        return EBool
      }
      if name == "null" {
        return ENull
      }
      if self.eat_op("(") {
        let args : Array[ExprNode] = []
        if self.eat_op(")") {
          return ECall(name, args)
        }
        while true {
          args.push(self.parse_expr())
          if self.eat_op(",") {
            continue
          }
          self.expect_op(")")
          break
        }
        ECall(name, args)
      } else {
        EIdent(name)
      }
    }
    TkOp(o) =>
      if o == "(" {
        let e = self.parse_expr()
        self.expect_op(")")
        e
      } else {
        raise ExprError
      }
  }
}

///|
/// Parse a `${{ ... }}` body. `None` means "could not parse" — callers skip
/// the expression entirely so an unsupported construct never yields a
/// false positive.
fn parse_ga_expr(body : String) -> ExprNode? {
  let toks = lex_ga_expr(body) catch { _ => return None }
  if toks.length() == 0 {
    return None
  }
  let p = ExprParser::{ toks, pos: 0 }
  try p.parse_expr() catch {
    _ => None
  } noraise {
    node => if p.pos == toks.length() { Some(node) } else { None }
  }
}

// ---------------------------------------------------------------------------
// Type model
// ---------------------------------------------------------------------------

///|
/// Object types remember which rule owns strictness violations (`rule`) and
/// the display path (`path`, e.g. `needs.prep.outputs`) so findings can name
/// the exact reference. Property keys are stored lowercased — GitHub
/// expression member lookup is case-insensitive.
priv struct ExprObj {
  props : Map[String, ExprType]
  strict : Bool
  rule : String
  path : String
}

///|
priv enum ExprType {
  TAny
  TNull
  TBool
  TNum
  TStr
  TObj(ExprObj)
  TArr
}

///|
priv struct ExprFinding {
  rule : String
  message : String
}

///|
fn expr_type_display(t : ExprType) -> String {
  match t {
    TAny => "any"
    TNull => "null"
    TBool => "bool"
    TNum => "number"
    TStr => "string"
    TObj(_) => "object"
    TArr => "array"
  }
}

///|
fn expr_is_known_scalar(t : ExprType) -> Bool {
  match t {
    TNull | TBool | TNum | TStr => true
    _ => false
  }
}

///|
fn expr_missing_prop(
  o : ExprObj,
  name : String,
  out : Array[ExprFinding],
) -> Unit {
  if o.rule == "" {
    return
  }
  let msg = if o.rule == "expression-matrix-type" {
    "\{o.path}.\{name} is not declared in the strategy"
  } else if o.rule == "expression-needs-type" && o.path == "needs" {
    "needs.\{name} is not defined; `\{name}` is not in this job's `needs`"
  } else if o.rule == "expression-steps-type" && o.path == "steps" {
    "steps.\{name} is not defined (no step with `id: \{name}` is in scope)"
  } else {
    "\{o.path} has no field `\{name}`"
  }
  out.push(ExprFinding::{ rule: o.rule, message: msg })
}

///|
/// Flag a typed mapping used as a scalar operand of `==`/`!=` (e.g.
/// `steps.gen.outputs == 1`).
fn expr_mapping_compare_one(
  t : ExprType,
  other : ExprType,
  out : Array[ExprFinding],
) -> Unit {
  match t {
    TObj(o) =>
      if o.rule != "" && expr_is_known_scalar(other) {
        let msg = if o.path.has_suffix(".outputs") {
          "`\{o.path}` is a mapping; index by output name"
        } else {
          "`\{o.path}` is a mapping; compare one of its fields instead"
        }
        out.push(ExprFinding::{ rule: o.rule, message: msg })
      }
    _ => ()
  }
}

///|
fn expr_member_type(
  t : ExprType,
  name : String,
  out : Array[ExprFinding],
) -> ExprType {
  match t {
    TObj(o) =>
      match o.props.get(name.to_lower()) {
        Some(t2) => t2
        None => {
          if o.strict {
            expr_missing_prop(o, name, out)
          }
          TAny
        }
      }
    _ => TAny
  }
}

///|
fn expr_call_return_type(name : String) -> ExprType {
  let lo = name.to_lower()
  if lo == "contains" ||
    lo == "startswith" ||
    lo == "endswith" ||
    lo == "always" ||
    lo == "success" ||
    lo == "failure" ||
    lo == "cancelled" {
    TBool
  } else if lo == "format" ||
    lo == "join" ||
    lo == "tojson" ||
    lo == "hashfiles" {
    TStr
  } else {
    TAny
  }
}

///|
fn infer_expr_type(
  n : ExprNode,
  env : Map[String, ExprType],
  out : Array[ExprFinding],
) -> ExprType {
  match n {
    ENull => TNull
    EBool => TBool
    ENum => TNum
    EStr(_) => TStr
    EIdent(name) =>
      match env.get(name.to_lower()) {
        Some(t) => t
        None => TAny
      }
    EDot(obj, name) => {
      let t = infer_expr_type(obj, env, out)
      if name == "*" {
        return TArr
      }
      expr_member_type(t, name, out)
    }
    EIndex(obj, idx) => {
      let t = infer_expr_type(obj, env, out)
      match idx {
        EStr(key) => expr_member_type(t, key, out)
        _ => {
          ignore(infer_expr_type(idx, env, out))
          TAny
        }
      }
    }
    ECall(name, args) => {
      for a in args {
        ignore(infer_expr_type(a, env, out))
      }
      expr_call_return_type(name)
    }
    ENot(e) => {
      ignore(infer_expr_type(e, env, out))
      TBool
    }
    EBin(op, l, r) => {
      let lt = infer_expr_type(l, env, out)
      let rt = infer_expr_type(r, env, out)
      if op == "==" || op == "!=" {
        expr_mapping_compare_one(lt, rt, out)
        expr_mapping_compare_one(rt, lt, out)
        TBool
      } else if op == "+" || op == "*" || op == "/" || op == "%" {
        // GitHub's expression language has no arithmetic; when both operand
        // types are known and not numbers, surface the mismatch instead of
        // a silent skip. `any` operands stay quiet.
        match (lt, rt) {
          (TNum, TNum) => ()
          (TAny, _) | (_, TAny) => ()
          _ => {
            let ld = expr_type_display(lt)
            let rd = expr_type_display(rt)
            out.push(ExprFinding::{
              rule: "expression-type-mismatch",
              message: "expression type mismatch: cannot apply `\{op}` to \{ld} and \{rd}",
            })
          }
        }
        TNum
      } else if op == "&&" || op == "||" {
        // GA logical operators return one of their operands, not a bool.
        TAny
      } else {
        TBool
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Context typing (needs / steps / matrix)
// ---------------------------------------------------------------------------

///|
/// Type the `needs` context for `job`. Strict: only direct dependencies are
/// members, and each dependency's `outputs` is strict over its declared
/// output names. Returns `None` (untyped) when the `needs:` value is dynamic
/// or malformed — other rules own those reports.
fn needs_context_type(ctx : WalkCtx, job : JobInfo) -> ExprType? {
  let dep_names : Array[String] = []
  match job.raw.get("needs") {
    Some(String(n)) => dep_names.push(n)
    Some(Array(arr)) =>
      for v in arr {
        match v {
          String(n) => dep_names.push(n)
          _ => return None
        }
      }
    None => ()
    Some(_) => return None
  }
  let props : Map[String, ExprType] = {}
  for name in dep_names {
    if name.contains("${{") {
      return None
    }
    let mut dep : JobInfo? = None
    for j in ctx.jobs {
      if j.name == name {
        dep = Some(j)
        break
      }
    }
    let entry : ExprType = match dep {
      // Dependency on an undefined job: `job-needs-graph` reports it; type
      // the member loosely so no cascade errors pile on.
      None => TAny
      Some(d) => needs_job_entry_type(name, d)
    }
    props[name.to_lower()] = entry
  }
  Some(
    TObj(ExprObj::{
      props,
      strict: true,
      rule: "expression-needs-type",
      path: "needs",
    }),
  )
}

///|
fn needs_job_entry_type(name : String, dep : JobInfo) -> ExprType {
  let outputs_path = "needs.\{name}.outputs"
  let outputs : ExprType = if dep.uses is Some(_) {
    // Reusable-workflow job: its outputs come from the called workflow,
    // which we can't see — keep the mapping loose.
    TObj(ExprObj::{
      props: {},
      strict: false,
      rule: "expression-needs-type",
      path: outputs_path,
    })
  } else {
    let oprops : Map[String, ExprType] = {}
    let mut static_keys = true
    match dep.raw.get("outputs") {
      Some(Map(om)) =>
        om.each(fn(k, _v) {
          if k.contains("${{") {
            static_keys = false
          }
          oprops[k.to_lower()] = TStr
        })
      None => ()
      Some(_) => static_keys = false
    }
    TObj(ExprObj::{
      props: oprops,
      strict: static_keys,
      rule: "expression-needs-type",
      path: outputs_path,
    })
  }
  let props : Map[String, ExprType] = {}
  props["outputs"] = outputs
  props["result"] = TStr
  TObj(ExprObj::{
    props,
    strict: true,
    rule: "expression-needs-type",
    path: "needs.\{name}",
  })
}

///|
/// Type the `steps` context from the steps declared before `upto` (pass a
/// negative `upto` for job-level fields like `outputs:`, which see every
/// step). Strict over declared `id:`s; `None` when any in-scope id is
/// dynamic.
fn steps_context_type(steps : Array[StepInfo], upto : Int) -> ExprType? {
  let props : Map[String, ExprType] = {}
  for s in steps {
    if upto >= 0 && s.step_index >= upto {
      continue
    }
    match s.id {
      Some(id) => {
        if id.contains("${{") {
          return None
        }
        let sprops : Map[String, ExprType] = {}
        sprops["outputs"] = TObj(ExprObj::{
          // Step outputs are written at runtime (`$GITHUB_OUTPUT`), so the
          // member set is unknowable statically — loose, but still a typed
          // mapping so scalar misuse is caught.
          props: {},
          strict: false,
          rule: "expression-steps-type",
          path: "steps.\{id}.outputs",
        })
        sprops["outcome"] = TStr
        sprops["conclusion"] = TStr
        props[id.to_lower()] = TObj(ExprObj::{
          props: sprops,
          strict: true,
          rule: "expression-steps-type",
          path: "steps.\{id}",
        })
      }
      None => ()
    }
  }
  Some(
    TObj(ExprObj::{
      props,
      strict: true,
      rule: "expression-steps-type",
      path: "steps",
    }),
  )
}

///|
/// Type the `matrix` context from `strategy.matrix`. Strict over the declared
/// dimensions plus any keys introduced by `include:` entries; `None` when the
/// matrix (or its `include:`) is an expression, so dynamically-generated
/// matrices are never second-guessed.
fn matrix_context_type(job : JobInfo) -> ExprType? {
  let strategy = match job.raw.get("strategy") {
    Some(Map(m)) => m
    _ => return None
  }
  let matrix = match strategy.get("matrix") {
    Some(Map(m)) => m
    _ => return None
  }
  let props : Map[String, ExprType] = {}
  let mut static_keys = true
  matrix.each(fn(key, value) {
    if key == "exclude" {
      return
    }
    if key == "include" {
      match value {
        Array(arr) =>
          for entry in arr {
            match entry {
              Map(em) => em.each(fn(k, _v) { props[k.to_lower()] = TAny })
              _ => static_keys = false
            }
          }
        _ => static_keys = false
      }
      return
    }
    if key.contains("${{") {
      static_keys = false
    }
    props[key.to_lower()] = TAny
  })
  if !static_keys {
    return None
  }
  Some(
    TObj(ExprObj::{
      props,
      strict: true,
      rule: "expression-matrix-type",
      path: "matrix",
    }),
  )
}

///|
fn expr_env_add_job_contexts(
  env : Map[String, ExprType],
  ctx : WalkCtx,
  job : JobInfo,
  steps_upto : Int,
) -> Unit {
  match needs_context_type(ctx, job) {
    Some(t) => env["needs"] = t
    None => ()
  }
  match steps_context_type(job.steps, steps_upto) {
    Some(t) => env["steps"] = t
    None => ()
  }
  match matrix_context_type(job) {
    Some(t) => env["matrix"] = t
    None => ()
  }
}

///|
fn expr_env_for_job(ctx : WalkCtx, job : JobInfo) -> Map[String, ExprType] {
  let env : Map[String, ExprType] = {}
  expr_env_add_job_contexts(env, ctx, job, -1)
  env
}

///|
/// Environment for a step's own fields. The `steps` context only contains
/// steps that ran earlier, so the cutoff is this step's index; composite
/// action steps get the same treatment from `runs.steps`.
fn expr_env_for_step(ctx : WalkCtx, step : StepInfo) -> Map[String, ExprType] {
  let env : Map[String, ExprType] = {}
  match step.job {
    Some(jname) =>
      for j in ctx.jobs {
        if j.name == jname {
          expr_env_add_job_contexts(env, ctx, j, step.step_index)
          break
        }
      }
    None =>
      match steps_context_type(ctx.action_steps, step.step_index) {
        Some(t) => env["steps"] = t
        None => ()
      }
  }
  env
}

// ---------------------------------------------------------------------------
// Rule plumbing
// ---------------------------------------------------------------------------

///|
fn expr_collect_findings_in_string(
  s : String,
  env : Map[String, ExprType],
  out : Array[ExprFinding],
) -> Unit {
  if !s.contains("${{") {
    return
  }
  for body in extract_expr_bodies(s) {
    match parse_ga_expr(body) {
      Some(node) =>
        // An expression whose own result is an outputs mapping (e.g.
        // `${{ steps.foo.outputs }}`) renders an object into the template —
        // actionlint rejects evaluating object values in `${{ }}`. Wrapped
        // uses like `toJSON(steps.foo.outputs)` return a string and pass.
        match infer_expr_type(node, env, out) {
          TObj(o) =>
            if o.rule != "" && o.path.has_suffix(".outputs") {
              out.push(ExprFinding::{
                rule: o.rule,
                message: "`\{o.path}` is a mapping; index by output name",
              })
            }
          _ => ()
        }
      None => ()
    }
  }
}

///|
/// Emit only the findings belonging to `rule_id` (the shared walk produces
/// findings for the whole rule family), deduplicated by message.
fn expr_emit_rule(
  rule_id : String,
  findings : Array[ExprFinding],
  out : Array[Diagnostic],
) -> Unit {
  let seen : Map[String, Bool] = {}
  for f in findings {
    if f.rule == rule_id && !seen.contains(f.message) {
      seen[f.message] = true
      add_diag(out, rule_id, Error, f.message)
    }
  }
}

///|
/// Check every job-level field except `steps:` (steps run with their own
/// per-step environment via `run_expr_rule_step`).
fn run_expr_rule_job(
  rule_id : String,
  ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  let env = expr_env_for_job(ctx, job)
  let findings : Array[ExprFinding] = []
  job.raw.each(fn(k, v) {
    if k == "steps" {
      return
    }
    walk_strings(v, fn(s) { expr_collect_findings_in_string(s, env, findings) })
  })
  expr_emit_rule(rule_id, findings, out)
}

///|
fn run_expr_rule_step(
  rule_id : String,
  ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  let env = expr_env_for_step(ctx, step)
  let findings : Array[ExprFinding] = []
  step.raw.each(fn(_k, v) {
    walk_strings(v, fn(s) { expr_collect_findings_in_string(s, env, findings) })
  })
  expr_emit_rule(rule_id, findings, out)
}

// ---------------------------------------------------------------------------
// Rule entry points
// ---------------------------------------------------------------------------

///|
fn check_expression_needs_type_job(
  ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  run_expr_rule_job("expression-needs-type", ctx, job, out)
}

///|
fn check_expression_needs_type_step(
  ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  run_expr_rule_step("expression-needs-type", ctx, step, out)
}

///|
fn check_expression_steps_type_job(
  ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  run_expr_rule_job("expression-steps-type", ctx, job, out)
}

///|
fn check_expression_steps_type_step(
  ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  run_expr_rule_step("expression-steps-type", ctx, step, out)
}

///|
fn check_expression_matrix_type_job(
  ctx : WalkCtx,
  job : JobInfo,
  out : Array[Diagnostic],
) -> Unit {
  run_expr_rule_job("expression-matrix-type", ctx, job, out)
}

///|
fn check_expression_matrix_type_step(
  ctx : WalkCtx,
  step : StepInfo,
  out : Array[Diagnostic],
) -> Unit {
  run_expr_rule_step("expression-matrix-type", ctx, step, out)
}

///|
/// Literal-level type mismatches (e.g. `'foo' + 1`) need no context typing,
/// so this rule walks the whole document once with an empty environment —
/// context-dependent mismatches stay with the per-context rules above.
fn check_expression_type_mismatch(
  ctx : WalkCtx,
  out : Array[Diagnostic],
) -> Unit {
  let env : Map[String, ExprType] = {}
  let findings : Array[ExprFinding] = []
  walk_strings(ctx.doc, fn(s) {
    expr_collect_findings_in_string(s, env, findings)
  })
  expr_emit_rule("expression-type-mismatch", findings, out)
}
