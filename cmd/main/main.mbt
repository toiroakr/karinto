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
///   moon run --target js cmd/main -- --format sarif ci.yml > karinto.sarif
///
/// Output is the same JSON envelope the Worker returns (`{ok, result}` for
/// stdin; `{ok, files: [...]}` for file arguments, where each entry is
/// `{path, ok, result}` — or `{path, ok: false, error}` with no `result`
/// when the file can't be read, like the Worker's repo mode. `ok` mirrors
/// the Worker's "parse succeeded" semantics).
///
/// `--format sarif` swaps the envelope for a SARIF 2.1.0 document
/// (`@karinto.sarif_report`) suitable for `codeql-action/upload-sarif`.
/// File arguments become artifact URIs; stdin has no path, so its results
/// carry logical (job/step) locations only. Unreadable files surface as
/// `invocations[].toolExecutionNotifications` instead of `{path, ok:
/// false, error}` entries. Exit codes are format-independent.
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
  let type_str = last_value(matches, "type")
  let kind = match parse_kind(type_str) {
    Some(k) => k
    None => {
      eprintln(
        "error: invalid value '\{type_str}' for '--type': expected 'workflow', 'action', or 'dependabot'",
      )
      return 2
    }
  }
  let format_str = last_value(matches, "format")
  let format = match parse_format(format_str) {
    Some(f) => f
    None => {
      eprintln(
        "error: invalid value '\{format_str}' for '--format': expected 'json' or 'sarif'",
      )
      return 2
    }
  }
  let persona_str = last_value(matches, "persona")
  let persona = match parse_persona(persona_str) {
    Some(p) => p
    None => {
      eprintln(
        "error: invalid value '\{persona_str}' for '--persona': expected 'regular', 'pedantic', or 'auditor'",
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
    // No files and an interactive terminal: reading stdin would just
    // block waiting for Ctrl-D, which looks like a hang. Bail out with
    // usage instead.
    if js_stdin_is_tty() {
      eprintln("error: no input: pipe YAML via stdin or pass file paths")
      eprintln("")
      eprintln(build_command().render_help())
      return 2
    }
    lint_stdin(kind, disabled, format, persona)
  } else {
    lint_files(files, kind, disabled, format, persona)
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
        about="File kind: 'workflow', 'action', or 'dependabot' (auto-detected when omitted)",
      ),
      @argparse.OptionArg::new(
        "disable",
        short='d',
        long="disable",
        action=Append,
        about="Comma-separated rule ID globs to disable (repeatable)",
      ),
      @argparse.OptionArg::new(
        "format",
        short='f',
        long="format",
        about="Output format: 'json' (default) or 'sarif'",
      ),
      @argparse.OptionArg::new(
        "persona",
        short='p',
        long="persona",
        about="Analysis profile: 'regular', 'pedantic', or 'auditor' (default; shows every finding)",
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
/// `""` (omitted) maps to `Auditor` — the engine's default, which shows every
/// finding (matching the Worker's `persona` parameter contract). Unlike the
/// Worker (which silently falls back), the CLI rejects an unrecognized value.
fn parse_persona(s : String) -> @karinto.Persona? {
  match s {
    "" | "auditor" => Some(@karinto.Persona::Auditor)
    "regular" => Some(@karinto.Persona::Regular)
    "pedantic" => Some(@karinto.Persona::Pedantic)
    _ => None
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
    "dependabot" => Some(@karinto.FileKind::Dependabot)
    _ => None
  }
}

///|
priv enum OutputFormat {
  Envelope
  Sarif
}

///|
/// `""` (omitted) and `"json"` both mean the JSON envelope — the Worker's
/// `format` parameter has the same contract.
fn parse_format(s : String) -> OutputFormat? {
  match s {
    "" | "json" => Some(Envelope)
    "sarif" => Some(Sarif)
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
/// Filename hint used when `--type` is omitted: `.github/workflows/`
/// paths are workflows (GitHub runs every YAML there as a workflow,
/// whatever its basename — even `action.yml`), `action.yml` /
/// `action.yaml` basenames are actions, `.github/dependabot.yml` /
/// `.yaml` is a Dependabot config; anything else falls back to the
/// engine's content-based auto-detection.
fn kind_from_path(path : String) -> @karinto.FileKind {
  // Windows callers pass `\`-separated paths — normalize so the hints
  // below only deal with `/`.
  let path = path.replace_all(old="\\", new="/")
  // Match `.github/workflows/` only as a path segment, so directories
  // like `foo.github/workflows/` don't false-positive.
  if path.has_prefix(".github/workflows/") ||
    path.contains("/.github/workflows/") {
    return @karinto.FileKind::Workflow
  }
  if path.has_prefix(".github/dependabot.") ||
    path.contains("/.github/dependabot.") {
    return @karinto.FileKind::Dependabot
  }
  let basename = match path.rev_find("/") {
    Some(i) => path[i + 1:].to_owned()
    None => path
  }
  if basename == "action.yml" || basename == "action.yaml" {
    return @karinto.FileKind::Action
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
fn lint_stdin(
  kind : @karinto.FileKind,
  disabled : Array[String],
  format : OutputFormat,
  persona : @karinto.Persona,
) -> Int {
  let content = match js_read_stdin() {
    Some(c) => c
    None => {
      eprintln("error: failed to read stdin")
      return 2
    }
  }
  let result = @karinto.lint(content, kind~, disabled~, persona~)
  match format {
    Envelope => {
      let body : Map[String, Json] = {
        "ok": (result.parse_error is None).to_json(),
        "result": result.to_json(),
      }
      println(body.to_json().stringify(indent=2))
    }
    Sarif =>
      // stdin has no path, so results keep logical locations only.
      println(
        @karinto.sarif_report([@karinto.SarifEntry::{ path: None, result }]).stringify(
          indent=2,
        ),
      )
  }
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
  format : OutputFormat,
  persona : @karinto.Persona,
) -> Int {
  let entries : Array[Json] = []
  let sarif_entries : Array[@karinto.SarifEntry] = []
  let io_errors : Array[@karinto.SarifIoError] = []
  let mut all_ok = true
  let mut code = 0
  for path in files {
    match js_read_file(path) {
      // Mirror the Worker's repo mode: an unreadable file becomes a
      // `{path, ok: false, error}` entry (a tool execution notification
      // in SARIF) and the rest of the batch still gets linted. IO errors
      // dominate the exit code.
      None => {
        eprintln("error: cannot read file '\{path}'")
        all_ok = false
        code = 2
        match format {
          Envelope => {
            let entry : Map[String, Json] = {
              "path": path.to_json(),
              "ok": false.to_json(),
              "error": "cannot read file".to_json(),
            }
            entries.push(entry.to_json())
          }
          Sarif =>
            io_errors.push(@karinto.SarifIoError::{
              path,
              message: "cannot read file",
            })
        }
      }
      Some(content) => {
        let file_kind = match kind {
          Unknown => kind_from_path(path)
          _ => kind
        }
        let result = @karinto.lint(content, kind=file_kind, disabled~, persona~)
        let ok = result.parse_error is None
        if !ok {
          all_ok = false
        }
        if has_blocking(result) && code == 0 {
          code = 1
        }
        match format {
          Envelope => {
            let entry : Map[String, Json] = {
              "path": path.to_json(),
              "ok": ok.to_json(),
              "result": result.to_json(),
            }
            entries.push(entry.to_json())
          }
          Sarif =>
            sarif_entries.push(@karinto.SarifEntry::{ path: Some(path), result })
        }
      }
    }
  }
  match format {
    Envelope => {
      let body : Map[String, Json] = {
        "ok": all_ok.to_json(),
        "files": entries.to_json(),
      }
      println(body.to_json().stringify(indent=2))
    }
    Sarif =>
      println(
        @karinto.sarif_report(sarif_entries, io_errors~).stringify(indent=2),
      )
  }
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
extern "js" fn js_stdin_is_tty() -> Bool =
  #| () => !!(typeof process !== "undefined" && process.stdin && process.stdin.isTTY)

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
