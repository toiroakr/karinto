///|
/// Pure, target-agnostic analysis over a parsed `ShellNode` tree (#113).
/// Each function here is exercised directly by fixture tests using captured
/// JSON-AST snapshots (see `shell_rules_test.mbt`), so they run under the
/// default `moon test` (wasm-gc) — no tree-sitter needed at test time. The
/// thin js-only seam that actually produces a `ShellNode` from a live parse
/// lives in `shell_ts_ffi.mbt` / `shell_ts_ffi_stub.mbt`; the wiring that
/// calls that seam and turns findings into `Diagnostic`s lives in `rules.mbt`
/// (`check_github_env`, `check_unpinned_tools`, etc. — same function names
/// the old regex-based rules used, so `all_rules()` didn't need to change).

///|
/// Replaces each `${{ … }}` span with an equal-length run of `_`, mirroring
/// actionlint's `sanitizeExpressionsInScript` trick: offsets into the
/// sanitized text still line up with the original source (needed to map a
/// finding back to a line), and a raw `${{ }}` can't confuse the bash
/// grammar (it isn't valid shell syntax on its own).
pub fn sanitize_expr_placeholders(source : String) -> String {
  let chars = source.to_array()
  let n = chars.length()
  let out = StringBuilder::new()
  let mut i = 0
  while i < n {
    if chars[i] == '$' &&
      i + 1 < n &&
      chars[i + 1] == '{' &&
      i + 2 < n &&
      chars[i + 2] == '{' {
      let start = i
      let mut j = i + 3
      let mut closed = false
      while j + 1 < n {
        if chars[j] == '}' && chars[j + 1] == '}' {
          j = j + 2
          closed = true
          break
        }
        j = j + 1
      }
      if !closed {
        j = n
      }
      let mut k = start
      while k < j {
        out.write_char('_')
        k = k + 1
      }
      i = j
    } else {
      out.write_char(chars[i])
      i = i + 1
    }
  }
  out.to_string()
}

///|
fn shell_node_find_child(node : ShellNode, t : String) -> ShellNode? {
  for c in node.c {
    if c.t == t {
      return Some(c)
    }
  }
  None
}

///|
fn shell_node_has_expansion(node : ShellNode) -> Bool {
  let mut found = false
  shell_node_walk(node, fn(n) {
    if n.t == "simple_expansion" ||
      n.t == "expansion" ||
      n.t == "command_substitution" {
      found = true
    }
  })
  found
}

// ---------------------------------------------------------------------------
// github-env: writing dynamic content into $GITHUB_ENV / $GITHUB_PATH
// ---------------------------------------------------------------------------

///|
/// `Some(target)` (`"GITHUB_ENV"` / `"GITHUB_PATH"`) for the first append
/// redirect whose written content is dynamic — an injection an attacker who
/// controls that value could use to smuggle extra `NAME=VALUE` lines (or,
/// for `GITHUB_PATH`, an extra directory) into the runner environment.
/// `original_source` is the run script *before* `${{ }}` → `_` sanitization
/// (same length, same offsets): a `${{ github.event.pull_request.title }}`
/// expression is itself the classic attacker-controlled source here, but
/// after sanitization it's just underscores — no `simple_expansion` node
/// for the AST half of this check to find — so this also checks whether
/// the node's own source span, read back from `original_source`, still
/// contains a raw `${{`.
pub fn analyze_github_env(
  root : ShellNode,
  original_source : String,
) -> String? {
  for stmt in shell_node_find_all(root, "redirected_statement") {
    let cmd = shell_node_find_child(stmt, "command")
    for redirect in stmt.c {
      if redirect.t == "file_redirect" &&
        shell_node_is_append_redirect(redirect) {
        match github_env_target(redirect) {
          Some(target) =>
            match cmd {
              Some(c) =>
                if content_is_dynamic(c, original_source) {
                  return Some(target)
                }
              None => ()
            }
          None => ()
        }
      } else if redirect.t == "heredoc_redirect" {
        let fr = shell_node_find_child(redirect, "file_redirect")
        let body = shell_node_find_child(redirect, "heredoc_body")
        match (fr, body) {
          (Some(fr), Some(body)) =>
            // Heredoc redirects need the same append-only guard as the
            // direct case above — without it, `cat <<EOF > "$GITHUB_ENV"`
            // (overwrite, single `>`) would be treated as a hit even
            // though the rule only means to flag `>>`.
            if shell_node_is_append_redirect(fr) {
              match github_env_target(fr) {
                Some(target) =>
                  if content_is_dynamic(body, original_source) {
                    return Some(target)
                  }
                None => ()
              }
            }
          _ => ()
        }
      }
    }
  }
  None
}

///|
/// True if `node` contains a real shell expansion, or its own source span
/// (read back from `original_source`, pre-sanitization) still contains a
/// raw `${{` — see `analyze_github_env`.
fn content_is_dynamic(node : ShellNode, original_source : String) -> Bool {
  if shell_node_has_expansion(node) {
    return true
  }
  source_slice(original_source, node.s, node.e).contains("${{")
}

///|
fn source_slice(source : String, s : Int, e : Int) -> String {
  let n = source.length()
  if s < 0 || e > n || s > e {
    return ""
  }
  source[s:e].to_owned()
}

///|
/// Exact-match, not substring — `redirect.x` used to be checked with a
/// plain `contains`, which would false-positive on an unrelated variable
/// that merely contains "GITHUB_ENV" as a substring (e.g. `$GITHUB_ENV_FILE`).
/// bash `$VAR`/`${VAR}` surfaces a `variable_name` node to compare exactly;
/// cmd's `%VAR%` has no such substructure (a bare `word`), but its own `%`
/// delimiters already act as a boundary, so a literal `%GITHUB_ENV%`
/// substring check on the redirect's text is still exact-enough there.
fn github_env_target(redirect : ShellNode) -> String? {
  for vn in shell_node_find_all(redirect, "variable_name") {
    let up = vn.x.to_upper()
    if up == "GITHUB_ENV" {
      return Some("GITHUB_ENV")
    }
    if up == "GITHUB_PATH" {
      return Some("GITHUB_PATH")
    }
  }
  let up = redirect.x.to_upper()
  if up.contains("%GITHUB_ENV%") {
    Some("GITHUB_ENV")
  } else if up.contains("%GITHUB_PATH%") {
    Some("GITHUB_PATH")
  } else {
    None
  }
}

// ---------------------------------------------------------------------------
// unpinned-tools: `curl|wget ... | sh|bash|zsh|dash`
// ---------------------------------------------------------------------------

///|
fn pipeline_command_names(pipeline : ShellNode) -> Array[String] {
  let out : Array[String] = []
  for c in pipeline.c {
    if c.t == "command" {
      match shell_node_find_child(c, "command_name") {
        Some(name) => out.push(name.x.to_lower())
        None => ()
      }
    }
  }
  out
}

///|
/// True if a `pipeline` runs a fetch tool (`curl`/`wget`) and ends in a
/// shell interpreter — position-aware, unlike the old
/// `contains("curl ") && contains("| sh")` heuristic, which fires on script
/// text that merely mentions both substrings anywhere, in any order.
pub fn analyze_unpinned_tools(root : ShellNode) -> Bool {
  let shells = ["sh", "bash", "zsh", "dash"]
  let fetchers = ["curl", "wget"]
  for pipeline in shell_node_find_all(root, "pipeline") {
    let names = pipeline_command_names(pipeline)
    if names.length() < 2 {
      continue
    }
    let has_fetch = names[:names.length() - 1]
      .iter()
      .any(fn(n) { fetchers.contains(n) })
    let last = names[names.length() - 1]
    if has_fetch && shells.contains(last) {
      return true
    }
  }
  false
}

// ---------------------------------------------------------------------------
// unredacted-secrets: a secret piped through a transform that defeats
// GitHub's log redaction (base64/xxd/tr/cut/sed/awk)
// ---------------------------------------------------------------------------

///|
/// `Some(transform-name)` when some pipeline pipes into one of the known
/// redaction-defeating tools. Scoped to *pipeline structure* — the caller
/// (`check_unredacted_secrets` in rules.mbt) is responsible for the
/// `secrets.`-reference gate, since that substring lives in the un-sanitized
/// source (`${{ secrets.X }}` is replaced with underscores before parsing).
pub fn analyze_unredacted_secrets(root : ShellNode) -> String? {
  let transforms = ["base64", "xxd", "tr", "cut", "sed", "awk"]
  for pipeline in shell_node_find_all(root, "pipeline") {
    let names = pipeline_command_names(pipeline)
    for name in names[1:] {
      if transforms.contains(name) {
        return Some(name)
      }
    }
  }
  None
}

// ---------------------------------------------------------------------------
// use-trusted-publishing: long-lived-token publish commands
// ---------------------------------------------------------------------------

///|
/// Mirrors the previous hand-rolled shell tokenizer's publish-command
/// table, now matched against real `command`/`command_name`/`word` nodes
/// instead of a manual `&&`/`||`/`;`-splitting scanner — the AST already
/// gives each statement's own command/argument boundaries for free, so a
/// value like `"--dry-run"` can't be mistaken for a separate token the way
/// naive whitespace splitting could inside quotes.
pub fn analyze_trusted_publishing(root : ShellNode) -> Bool {
  for cmd in shell_node_find_all(root, "command") {
    if command_is_publish(cmd) {
      return true
    }
  }
  false
}

///|
fn command_words(cmd : ShellNode) -> Array[String] {
  let out : Array[String] = []
  for c in cmd.c {
    if c.t == "command_name" || c.t == "word" {
      out.push(c.x)
    } else if c.t == "string" {
      out.push(string_literal_text(c))
    }
  }
  out
}

///|
/// A double-quoted string's literal value (surrounding quotes stripped),
/// so a quoted flag like `"--dry-run"` still matches the bare token
/// `--dry-run` in `command_is_publish`'s comparisons — `c.x` on the
/// `string` node itself includes the quote characters. Only safe when the
/// string has no expansion inside it (every child is `string_content`);
/// falls back to the raw source span otherwise, which won't match any of
/// this file's literal-token comparisons anyway.
fn string_literal_text(s : ShellNode) -> String {
  for c in s.c {
    if c.t != "string_content" {
      return s.x
    }
  }
  let buf = StringBuilder::new()
  for c in s.c {
    buf.write_string(c.x)
  }
  buf.to_string()
}

///|
fn words_contain(words : ArrayView[String], needle : String) -> Bool {
  for w in words {
    if w.to_lower() == needle {
      return true
    }
  }
  false
}

///|
fn words_contain_prefix(words : ArrayView[String], prefix : String) -> Bool {
  for w in words {
    if w.to_lower().has_prefix(prefix) {
      return true
    }
  }
  false
}

///|
/// The first `rest` word that isn't a `-`-prefixed flag — used to tell
/// `npm publish` (own subcommand) apart from `npm exec pkg -- publish` /
/// `pnpm dlx pkg publish` (a *different* package's own `publish` argument,
/// which happens to appear as a `word` later in the same command but isn't
/// npm/pnpm's subcommand at all).
fn first_non_flag_word(words : ArrayView[String]) -> String? {
  for w in words {
    if !w.has_prefix("-") {
      return Some(w.to_lower())
    }
  }
  None
}

///|
fn command_is_publish(cmd : ShellNode) -> Bool {
  let words = command_words(cmd)
  if words.length() == 0 {
    return false
  }
  let head = words[0].to_lower()
  let rest = words[1:]
  match head {
    "twine" => words_contain(rest, "upload")
    "npm" | "pnpm" | "yarn" =>
      first_non_flag_word(rest) == Some("publish") &&
      !words_contain(rest, "--dry-run")
    "python" =>
      words_contain(rest, "-m") &&
      words_contain(rest, "twine") &&
      words_contain(rest, "upload")
    "python3" =>
      words_contain(rest, "-m") &&
      words_contain(rest, "twine") &&
      words_contain(rest, "upload")
    "pipx" =>
      rest.length() > 0 &&
      rest[0].to_lower() == "run" &&
      (
        words_contain(rest, "twine") ||
        words_contain_prefix(rest, "twine==") ||
        words_contain_prefix(rest, "twine@")
      ) &&
      words_contain(rest, "upload")
    "bundle" =>
      words_contain(rest, "exec") &&
      words_contain(rest, "gem") &&
      words_contain(rest, "push")
    "bunx" =>
      (words_contain(rest, "npm") || words_contain_prefix(rest, "npm@")) &&
      words_contain(rest, "publish") &&
      !words_contain(rest, "--dry-run")
    _ => false
  }
}

// ---------------------------------------------------------------------------
// shell-quote-safety (karinto-original, #113): unquoted expansion of an
// env var whose value derives from `${{ … }}` — the injection-amplification
// neighbour of `template-injection`. A workflow author who writes
// `env: TITLE: ${{ github.event.pull_request.title }}` already accepted
// that `$TITLE` carries attacker-controlled text; using it unquoted
// (`run: echo $TITLE`) additionally exposes it to word-splitting and glob
// expansion — an attacker-controlled `TITLE` containing spaces/`*` can
// inject extra arguments into whatever command reads it. Deliberately
// narrower than stock SC2086 (every unquoted expansion): only variables
// this specific workflow made expression-derived are in scope, which is
// meant to keep noise far below stock shellcheck.
// ---------------------------------------------------------------------------

///|
/// Every variable name from `dynamic_env_names` that's referenced via an
/// unquoted `$VAR` / `${VAR}` expansion somewhere in `root`. Dedup'd, but
/// otherwise in AST-visit (source) order.
pub fn analyze_quote_safety(
  root : ShellNode,
  dynamic_env_names : Array[String],
) -> Array[String] {
  let refs : Array[String] = []
  collect_var_refs(root, false, refs)
  let out : Array[String] = []
  for name in refs {
    if dynamic_env_names.contains(name) && !out.contains(name) {
      out.push(name)
    }
  }
  out
}

///|
/// Walks `node`, appending every *unquoted* `simple_expansion`/`expansion`
/// variable name to `out`. `in_string` tracks whether an ancestor was a
/// `string` node — bash doesn't word-split/glob-expand inside double
/// quotes, so those don't count (single-quoted regions never contain a live
/// expansion in the first place — tree-sitter-bash doesn't parse `$` inside
/// `'...'` as an expansion at all).
fn collect_var_refs(
  node : ShellNode,
  in_string : Bool,
  out : Array[String],
) -> Unit {
  if (node.t == "simple_expansion" || node.t == "expansion") && !in_string {
    match shell_node_find_child(node, "variable_name") {
      Some(vn) => out.push(vn.x)
      None => ()
    }
  }
  let child_in_string = in_string || node.t == "string"
  for c in node.c {
    collect_var_refs(c, child_in_string, out)
  }
}

// ---------------------------------------------------------------------------
// shell-undefined-var (karinto-original, #113): a shell variable reference
// with no visible source — not declared in `env:` at any level, not
// assigned earlier in the same script, and not a well-known runner/shell
// built-in. SC2154-like, but scoped to what the syntax tree makes
// reliable: no attempt to model conditionals, functions, or `source`d
// files, so this stays an `Info`-severity nudge, not an error.
// ---------------------------------------------------------------------------

///|
let well_known_shell_vars : Array[String] = [
  "PATH", "HOME", "USER", "PWD", "OLDPWD", "SHELL", "LANG", "LC_ALL", "TERM", "CI",
  "IFS", "HOSTNAME", "TMPDIR", "TZ", "GITHUB_ENV", "GITHUB_PATH",
]

///|
fn is_well_known_prefix(name : String) -> Bool {
  let up = name.to_upper()
  up.has_prefix("GITHUB_") ||
  up.has_prefix("RUNNER_") ||
  up.has_prefix("ACTIONS_") ||
  up.has_prefix("INPUT_")
}

///|
/// Every referenced variable name with no visible declaration — neither in
/// `declared` (the caller's merged workflow/job/step `env:` keys, visible
/// for the whole script) nor assigned *earlier* in `root` itself (`FOO=bar`
/// — a `variable_assignment` node whose own span ends before the
/// reference starts) nor a well-known built-in. Position-aware by design:
/// an assignment later in the script doesn't retroactively excuse an
/// earlier use-before-def, which is exactly the class of bug this rule
/// exists to catch. Dedup'd, AST-visit order.
pub fn analyze_undefined_vars(
  root : ShellNode,
  declared : Array[String],
) -> Array[String] {
  let assignments : Array[(String, Int)] = []
  for a in shell_node_find_all(root, "variable_assignment") {
    match shell_node_find_child(a, "variable_name") {
      Some(vn) => assignments.push((vn.x, a.e))
      None => ()
    }
  }
  let refs : Array[(String, Int)] = []
  shell_node_walk(root, fn(n) {
    if n.t == "simple_expansion" || n.t == "expansion" {
      match shell_node_find_child(n, "variable_name") {
        Some(vn) => refs.push((vn.x, n.s))
        None => ()
      }
    }
  })
  let out : Array[String] = []
  for r in refs {
    let (name, pos) = r
    if declared.contains(name) ||
      well_known_shell_vars.contains(name) ||
      is_well_known_prefix(name) {
      continue
    }
    let assigned_before = assignments
      .iter()
      .any(fn(a) { a.0 == name && a.1 <= pos })
    if assigned_before {
      continue
    }
    if !out.contains(name) {
      out.push(name)
    }
  }
  out
}
