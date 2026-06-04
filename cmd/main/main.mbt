///|
/// karinto CLI — lints GitHub Actions workflow / action YAML locally.
///
/// Reads YAML from stdin when no file arguments are given, or from each
/// file path argument. Reuses the same `@karinto.lint` engine as the
/// Cloudflare Worker so the two stay behaviorally identical.
///
///   cat .github/workflows/ci.yml | moon run --target js cmd/main
///   moon run --target js cmd/main -- .github/workflows/ci.yml action.yml
///   moon run --target js cmd/main -- --type action action.yml
///   moon run --target js cmd/main -- --disable 'permissions-*' ci.yml
///
/// Output is the same JSON envelope the Worker returns (`{ok, result}` for
/// stdin; `{ok, files: [{path, ok, result}, ...]}` for file arguments,
/// where `ok` mirrors the Worker's "parse succeeded" semantics).
///
/// Exit codes: 0 — clean; 1 — error-severity diagnostics or YAML parse
/// errors (CI-friendly); 2 — usage / IO errors.
///
/// The package is js-only (`supported_targets = "js"` in moon.pkg):
/// stdin / file IO and the exit code go through Node.js FFI, which is the
/// simplest local UX given the Worker build already targets js.

///|
fn main {
  js_set_exit_code(run())
}

///|
fn run() -> Int {
  let matches = build_command().parse(argv=cli_argv()[:]) catch {
    err => {
      eprintln(err.to_string())
      return 2
    }
  }
  let kind = match parse_kind(last_value(matches, "type")) {
    Some(k) => k
    None => {
      eprintln(
        "error: invalid value for '--type': expected 'workflow' or 'action'",
      )
      return 2
    }
  }
  let disabled = collect_disabled(matches)
  let files = match matches.values.get("files") {
    Some(fs) => fs
    None => []
  }
  if files.length() == 0 {
    lint_stdin(kind, disabled)
  } else {
    lint_files(files, kind, disabled)
  }
}

///|
fn build_command() -> @argparse.Command {
  @argparse.Command::new(
    "karinto",
    about="Lint GitHub Actions workflow / action YAML. Reads stdin when no FILES are given.",
    options=[
      @argparse.OptionArg::new(
        "type",
        short='t',
        long="type",
        about="File kind: 'workflow' or 'action' (auto-detected when omitted)",
      ),
      @argparse.OptionArg::new(
        "disable",
        short='d',
        long="disable",
        action=Append,
        about="Comma-separated rule ID globs to disable (repeatable)",
      ),
    ],
    positionals=[
      @argparse.PositionArg::new(
        "files",
        num_args=@argparse.ValueRange::new(lower=0),
        about="YAML files to lint; omit to read from stdin",
      ),
    ],
  )
}

///|
/// `@env.args()` on js is the raw `process.argv` — drop the leading
/// `node` + script-path entries.
fn cli_argv() -> Array[String] {
  let args = @env.args()
  if args.length() > 2 {
    args[2:].to_owned()
  } else {
    []
  }
}

///|
fn last_value(matches : @argparse.Matches, name : String) -> String {
  match matches.values.get(name) {
    Some(vs) if vs.length() > 0 => vs[vs.length() - 1]
    _ => ""
  }
}

///|
/// `""` (omitted) maps to `Unknown`, which the engine auto-detects —
/// the same contract as the Worker's `type` parameter.
fn parse_kind(s : String) -> @karinto.FileKind? {
  match s {
    "" => Some(@karinto.FileKind::Unknown)
    "workflow" => Some(@karinto.FileKind::Workflow)
    "action" => Some(@karinto.FileKind::Action)
    _ => None
  }
}

///|
/// Each `--disable` occurrence is itself a CSV, matching the Worker's
/// `disable` parameter.
fn collect_disabled(matches : @argparse.Matches) -> Array[String] {
  let out : Array[String] = []
  match matches.values.get("disable") {
    Some(vs) =>
      for v in vs {
        for piece in split_csv(v) {
          out.push(piece)
        }
      }
    None => ()
  }
  out
}

///|
fn split_csv(s : String) -> Array[String] {
  let out : Array[String] = []
  for piece in s.split(",") {
    let trimmed = piece.trim(chars=" \t").to_owned()
    if trimmed != "" {
      out.push(trimmed)
    }
  }
  out
}

///|
/// Filename hint used when `--type` is omitted: `action.yml` /
/// `action.yaml` basenames are actions, `.github/workflows/` paths are
/// workflows; anything else falls back to the engine's content-based
/// auto-detection.
fn kind_from_path(path : String) -> @karinto.FileKind {
  let basename = match path.rev_find("/") {
    Some(i) => path[i + 1:].to_owned()
    None => path
  }
  if basename == "action.yml" || basename == "action.yaml" {
    return @karinto.FileKind::Action
  }
  if path.contains(".github/workflows/") {
    return @karinto.FileKind::Workflow
  }
  @karinto.FileKind::Unknown
}

///|
/// Error-severity diagnostics and parse errors are CI-blocking.
fn has_blocking(result : @karinto.LintResult) -> Bool {
  if result.parse_error is Some(_) {
    return true
  }
  for d in result.diagnostics {
    if d.severity is Error {
      return true
    }
  }
  false
}

///|
fn lint_stdin(kind : @karinto.FileKind, disabled : Array[String]) -> Int {
  let content = match js_read_stdin() {
    Some(c) => c
    None => {
      eprintln("error: failed to read stdin")
      return 2
    }
  }
  let result = @karinto.lint(content, kind~, disabled~)
  let body : Map[String, Json] = {
    "ok": (result.parse_error is None).to_json(),
    "result": result.to_json(),
  }
  println(body.to_json().stringify(indent=2))
  if has_blocking(result) {
    1
  } else {
    0
  }
}

///|
fn lint_files(
  files : Array[String],
  kind : @karinto.FileKind,
  disabled : Array[String],
) -> Int {
  let entries : Array[Json] = []
  let mut all_ok = true
  let mut code = 0
  for path in files {
    match js_read_file(path) {
      None => {
        eprintln("error: cannot read file '\{path}'")
        return 2
      }
      Some(content) => {
        let file_kind = match kind {
          Unknown => kind_from_path(path)
          _ => kind
        }
        let result = @karinto.lint(content, kind=file_kind, disabled~)
        let ok = result.parse_error is None
        if !ok {
          all_ok = false
        }
        if has_blocking(result) {
          code = 1
        }
        let entry : Map[String, Json] = {
          "path": path.to_json(),
          "ok": ok.to_json(),
          "result": result.to_json(),
        }
        entries.push(entry.to_json())
      }
    }
  }
  let body : Map[String, Json] = {
    "ok": all_ok.to_json(),
    "files": entries.to_json(),
  }
  println(body.to_json().stringify(indent=2))
  code
}

///|
/// `String?`'s `None` is represented as `undefined` on the js backend, so
/// the catch arms return `undefined` (not `null`).
extern "js" fn js_read_stdin() -> String? =
  #| () => {
  #|   try { return require("node:fs").readFileSync(0, "utf8"); }
  #|   catch (e) { return undefined; }
  #| }

///|
extern "js" fn js_read_file(path : String) -> String? =
  #| (path) => {
  #|   try { return require("node:fs").readFileSync(path, "utf8"); }
  #|   catch (e) { return undefined; }
  #| }

///|
/// `process.exitCode` (not `process.exit()`) so Node still flushes piped
/// stdout before exiting.
extern "js" fn js_set_exit_code(code : Int) -> Unit =
  #| (code) => { if (typeof process !== "undefined") process.exitCode = code; }

///|
extern "js" fn eprintln(msg : String) -> Unit =
  #| (msg) => {
  #|   if (typeof process !== "undefined" && process.stderr) process.stderr.write(msg + "\n");
  #|   else console.error(msg);
  #| }
