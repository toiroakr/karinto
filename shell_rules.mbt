///|
/// Pure, target-agnostic analysis over a parsed `ShellNode` tree (#113).
/// Each function here is exercised directly by fixture tests using captured
/// JSON-AST snapshots (see `shell_rules_wbtest.mbt`), so they run under the
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
fn sanitize_expr_placeholders(source : String) -> String {
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
fn analyze_github_env(root : ShellNode, original_source : String) -> String? {
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
/// bash `$VAR`/`${VAR}` surfaces a `variable_name` node to compare exactly.
/// The `%VAR%` fallback below is realistically dead in practice: the only
/// caller (`check_github_env` in rules.mbt) already gates on the step's
/// resolved shell being bash/sh before this ever runs, so a real cmd step
/// never reaches here. Left in (cheap, and correct if reached — cmd's
/// `%VAR%` has no `variable_name` substructure, a bare `word` instead, but
/// its own `%` delimiters already bound the substring check) rather than
/// removed, in case a bash script ever legitimately contains a literal
/// `%GITHUB_ENV%` string.
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
fn last_pipeline_command(pipeline : ShellNode) -> ShellNode? {
  let mut last : ShellNode? = None
  for c in pipeline.c {
    if c.t == "command" {
      last = Some(c)
    }
  }
  last
}

///|
/// The shell interpreter a pipeline's last command actually runs, seeing
/// through a thin wrapper (`sudo`/`env`/`exec`/`nohup`) to its first
/// non-flag argument — `curl x | sudo bash` and `curl x | env bash` both
/// end in `bash`, not `sudo`/`env`.
fn command_shell_name(cmd : ShellNode) -> String? {
  let words = command_words(cmd)
  if words.length() == 0 {
    return None
  }
  let head = words[0].to_lower()
  let wrappers = ["sudo", "env", "exec", "nohup"]
  if wrappers.contains(head) {
    first_word_after_wrapper_flags(words[1:], head)
  } else {
    Some(head)
  }
}

///|
/// True if `flag` (as it appears on `wrapper`'s own command line, e.g. the
/// `-u` in `sudo -u root bash` or `env -u PATH bash`) consumes the *next*
/// word as its argument rather than standing alone — so that argument isn't
/// mistaken for the wrapped command's name. Not exhaustive, just the flags
/// plausible before a shell invocation in a `curl | wrapper ... bash`-style
/// install script.
fn wrapper_flag_takes_value(wrapper : String, flag : String) -> Bool {
  match wrapper {
    "sudo" =>
      flag == "-u" ||
      flag == "-g" ||
      flag == "-h" ||
      flag == "-p" ||
      flag == "-r" ||
      flag == "-t" ||
      flag == "-C" ||
      flag == "-D" ||
      flag == "-U"
    "env" => flag == "-u" || flag == "--unset"
    "exec" => flag == "-a"
    _ => false
  }
}

///|
/// The first `words` token that's neither a `-`-prefixed flag (skipping
/// that flag's own argument too, per `wrapper_flag_takes_value` — `sudo -u
/// root bash` must resolve to `bash`, not `root`) nor, for `env`
/// specifically, a `NAME=VALUE` assignment (`env FOO=bar bash` → `bash`,
/// not `FOO=bar`).
fn first_word_after_wrapper_flags(
  words : ArrayView[String],
  wrapper : String,
) -> String? {
  let mut i = 0
  let n = words.length()
  while i < n {
    let w = words[i]
    if wrapper == "env" && is_env_style_assignment(w) {
      i = i + 1
      continue
    }
    if w.has_prefix("-") {
      i = if wrapper_flag_takes_value(wrapper, w) { i + 2 } else { i + 1 }
      continue
    }
    return Some(w.to_lower())
  }
  None
}

///|
/// True if `word` looks like a POSIX `NAME=VALUE` assignment (`env`'s own
/// argument syntax, e.g. `FOO=bar` in `env FOO=bar bash`) — a leading
/// `[A-Za-z_][A-Za-z0-9_]*` followed by `=`.
fn is_env_style_assignment(word : String) -> Bool {
  let eq = index_of_char(word, '=')
  if eq <= 0 {
    return false
  }
  for i in 0..<eq {
    let ch = word.get_char(i).unwrap()
    let is_head = i == 0
    let alpha = (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      ch == '_'
    let digit = ch >= '0' && ch <= '9'
    if is_head {
      if !alpha {
        return false
      }
    } else if !alpha && !digit {
      return false
    }
  }
  true
}

///|
/// True if a `pipeline` runs a fetch tool (`curl`/`wget`) and ends in a
/// shell interpreter — position-aware, unlike the old
/// `contains("curl ") && contains("| sh")` heuristic, which fires on script
/// text that merely mentions both substrings anywhere, in any order. Sees
/// through `sudo`/`env`/`exec`/`nohup` wrappers (`command_shell_name`), so
/// `curl x | sudo bash` is caught, not just a bare `curl x | bash`.
fn analyze_unpinned_tools(root : ShellNode) -> Bool {
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
    if !has_fetch {
      continue
    }
    match last_pipeline_command(pipeline) {
      Some(last_cmd) =>
        match command_shell_name(last_cmd) {
          Some(sh) => if shells.contains(sh) { return true }
          None => ()
        }
      None => ()
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
fn analyze_unredacted_secrets(root : ShellNode) -> String? {
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
fn analyze_trusted_publishing(root : ShellNode) -> Bool {
  for cmd in shell_node_find_all(root, "command") {
    if command_is_publish(cmd) {
      return true
    }
  }
  false
}

///|
/// Replaces a bash (`\<EOL>`) or PowerShell (`` `<EOL> ``) line
/// continuation with a single space, so a publish command split across
/// lines (`npm \`\n  publish`, a real invocation on a pwsh runner) still
/// tokenizes as one logical line instead of two — `npm` alone and
/// `publish` alone each fail to match `words_are_publish` on their own.
/// Ported from the pre-#113 hand-rolled tokenizer's own
/// `collapse_continuations`, which handled the same two continuation
/// styles for the same reason.
fn collapse_shell_continuations(s : String) -> String {
  let chars = s.to_array()
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
/// Non-bash fallback for a `run:` script tree-sitter-bash can't parse.
/// Unlike `unpinned-tools`/`unredacted-secrets` (whose patterns — piping to
/// `sh`, piping through `base64`/`xxd`/etc. — are Unix-shell idioms that
/// essentially never appear verbatim outside bash/sh), a publish command
/// like `npm publish` is a plain executable with no shell-specific syntax:
/// it runs identically under pwsh or cmd. And windows-family runners
/// *default* to pwsh (see `effective_shell`'s runner-default fallback), so
/// without this, a completely ordinary `runs-on: windows-latest` step with
/// no explicit `shell:` at all — not just one that explicitly opts into
/// `shell: pwsh` — would silently stop being checked. Deliberately
/// conservative (whitespace-tokenized, `;`/`&&`/`||`-segmented, no
/// quote-awareness): reintroducing exactly the imprecision #113 replaced
/// tree-sitter-bash *for bash scripts*, but this only ever runs as a
/// fallback when a real bash parse isn't applicable in the first place.
fn text_has_publish_cmd(run : String) -> Bool {
  for v in collapse_shell_continuations(run).split("\n") {
    let line = v.to_owned()
    for segment in split_command_segments(line) {
      if words_are_publish(naive_tokenize(segment)) {
        return true
      }
    }
  }
  false
}

///|
/// Splits `line` on `;`/`&&`/`||` into independent segments, so a chained
/// line (`cd dist && npm publish`) is evaluated per-segment instead of as
/// one flat token stream.
fn split_command_segments(line : String) -> Array[String] {
  let chars = line.to_array()
  let n = chars.length()
  let segments : Array[String] = []
  let buf = StringBuilder::new()
  let mut i = 0
  while i < n {
    let c = chars[i]
    if (c == '&' || c == '|') && i + 1 < n && chars[i + 1] == c {
      segments.push(buf.to_string())
      buf.reset()
      i = i + 2
      continue
    }
    if c == ';' {
      segments.push(buf.to_string())
      buf.reset()
      i = i + 1
      continue
    }
    buf.write_char(c)
    i = i + 1
  }
  segments.push(buf.to_string())
  segments
}

///|
/// Whitespace-tokenizes `segment` into words — no quote-awareness, since
/// this is only reached for a shell tree-sitter-bash can't parse anyway.
fn naive_tokenize(segment : String) -> Array[String] {
  let out : Array[String] = []
  let buf = StringBuilder::new()
  let mut in_word = false
  for ch in segment {
    if ch == ' ' || ch == '\t' {
      if in_word {
        out.push(buf.to_string())
        buf.reset()
        in_word = false
      }
    } else {
      buf.write_char(ch)
      in_word = true
    }
  }
  if in_word {
    out.push(buf.to_string())
  }
  out
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
/// Every publish-command family the old hand-rolled tokenizer recognized
/// (`rules_catalog.md`'s `use-trusted-publishing` entry): `cargo`, `twine`,
/// `npm`/`pnpm`/`bun`/`yarn`, `gem`, `nuget`/`dotnet nuget`, `poetry`,
/// `hatch`/`pdm`, `uv`/`uvx`, `python -m twine`, `pipx run twine`,
/// `bundle exec gem push`, `bunx npm publish`. Where the original checked
/// "does `rest` contain the token `publish` anywhere" for a tool's own
/// subcommand, this checks `first_non_flag_word(rest) == Some("publish")`
/// instead — stricter, and the reason a dlx-style wrapper (`pnpm dlx X
/// publish`) doesn't false-positive without needing the old code's
/// curated non-registry-tool allowlist (`is_known_non_registry_dlx_tool`,
/// which only covered `pkg-pr-new` and would still have flagged `pnpm dlx
/// some-other-tool publish` as a real npm publish): the dlx'd tool's own
/// `publish` argument is never `rest`'s first non-flag word, `dlx`/`exec`
/// is.
fn command_is_publish(cmd : ShellNode) -> Bool {
  words_are_publish(command_words(cmd))
}

///|
/// The actual family-matching table, factored out of `command_is_publish`
/// so `text_has_publish_cmd` (the non-bash fallback below) can reuse the
/// exact same publish-command recognition — including the dlx
/// false-positive protection — over a naively-tokenized word list instead
/// of a real AST's `command_name`/`word`/`string` nodes.
fn words_are_publish(words : Array[String]) -> Bool {
  if words.length() == 0 {
    return false
  }
  let head = words[0].to_lower()
  let rest = words[1:]
  if head == "cargo" {
    return first_non_flag_word(rest) == Some("publish") &&
      !words_contain(rest, "--dry-run") &&
      !words_contain(rest, "-n")
  }
  if head == "twine" {
    return words_contain(rest, "upload")
  }
  if head == "npm" || head == "pnpm" || head == "bun" {
    return first_non_flag_word(rest) == Some("publish") &&
      !words_contain(rest, "--dry-run")
  }
  if head == "yarn" {
    return first_non_flag_word(rest) == Some("publish") &&
      !words_contain(rest, "--dry-run") &&
      !words_contain(rest, "-n")
  }
  if head == "gem" {
    return words_contain(rest, "push")
  }
  if head == "nuget" || head == "nuget.exe" {
    return words_contain(rest, "push")
  }
  if head == "dotnet" {
    return words_contain(rest, "nuget") && words_contain(rest, "push")
  }
  if head == "poetry" {
    return first_non_flag_word(rest) == Some("publish") &&
      !words_contain(rest, "--dry-run")
  }
  if head == "hatch" || head == "pdm" {
    return first_non_flag_word(rest) == Some("publish")
  }
  if head == "uv" {
    if first_non_flag_word(rest) == Some("publish") {
      return true
    }
    return words_contain(rest, "twine") && words_contain(rest, "upload")
  }
  if head == "uvx" {
    let twine_like = words_contain(rest, "twine") ||
      words_contain_prefix(rest, "twine==") ||
      words_contain_prefix(rest, "twine@")
    return twine_like && words_contain(rest, "upload")
  }
  if head == "python" || head.has_prefix("python3") {
    return words_contain(rest, "-m") &&
      words_contain(rest, "twine") &&
      words_contain(rest, "upload")
  }
  if head == "pipx" {
    if rest.length() > 0 && rest[0].to_lower() == "run" {
      let twine_like = words_contain(rest, "twine") ||
        words_contain_prefix(rest, "twine==") ||
        words_contain_prefix(rest, "twine@")
      return twine_like && words_contain(rest, "upload")
    }
    return false
  }
  if head == "bundle" {
    return words_contain(rest, "exec") &&
      words_contain(rest, "gem") &&
      words_contain(rest, "push")
  }
  if head == "bunx" {
    let npm_like = words_contain(rest, "npm") ||
      words_contain_prefix(rest, "npm@")
    return npm_like &&
      words_contain(rest, "publish") &&
      !words_contain(rest, "--dry-run")
  }
  false
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
fn analyze_quote_safety(
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
/// `'...'` as an expansion at all) — or a `heredoc_body`: unlike an
/// unquoted command argument, heredoc content is never word-split or
/// glob-expanded (it's just literal text handed to the reading command's
/// stdin, after expansion of `$VAR`/backticks/etc.), so this rule's actual
/// hazard — an attacker-controlled value injecting extra arguments via
/// word-splitting — doesn't apply there. `github-env` already covers the
/// real hazard specific to heredocs (dynamic content written into
/// `$GITHUB_ENV`), separately.
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
  let child_in_string = in_string ||
    node.t == "string" ||
    node.t == "heredoc_body"
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
/// POSIX "special builtins" (plus bash's `.`): unlike an ordinary command, a
/// prefix assignment on one of these persists in the current shell after it
/// completes instead of being scoped to just that invocation — e.g. `FOO=bar
/// export FOO` really does leave `$FOO` set afterward, unlike `FOO=bar echo
/// hi`. Used by `collect_persistent_assignments` below.
fn is_special_builtin_keeping_prefix_assignment(name : String) -> Bool {
  let special_builtins = [
    "break", ":", "continue", ".", "eval", "exec", "exit", "export", "readonly",
    "return", "set", "shift", "times", "trap", "unset",
  ]
  special_builtins.contains(name.to_lower())
}

///|
/// Every `variable_assignment` that actually persists for later statements
/// — i.e. `FOO=bar` on its own line — as `(name, end_offset)`. Excludes a
/// *prefix* assignment on an ordinary command with its own name (`FOO=bar
/// echo hi`): in bash that only sets `$FOO` in `echo`'s environment for
/// that one invocation, it does not persist afterward. tree-sitter-bash
/// represents the difference structurally: a bare `FOO=bar` statement is a
/// top-level `variable_assignment` node (a sibling of `command` nodes),
/// while a prefix assignment is nested *inside* a `command` node alongside
/// that command's own `command_name` — so a `variable_assignment` child of
/// a `command` that also has a `command_name` is normally prefix-only and
/// skipped, *except* when that command name is a special builtin
/// (`is_special_builtin_keeping_prefix_assignment`), where the prefix
/// assignment persists just like a bare one. (This also means an
/// assignment inside a `$(...)` command substitution's own subshell is
/// correctly never treated as persisting to the outer script — bash
/// subshells don't leak variables back to the parent either.)
fn collect_persistent_assignments(root : ShellNode) -> Array[(String, Int)] {
  let out : Array[(String, Int)] = []
  fn walk(node : ShellNode) -> Unit {
    if node.t == "command" {
      match shell_node_find_child(node, "command_name") {
        Some(cn) =>
          if !is_special_builtin_keeping_prefix_assignment(cn.x) {
            for c in node.c {
              if c.t != "variable_assignment" {
                walk(c)
              }
            }
            return
          }
        None => ()
      }
    }
    if node.t == "variable_assignment" {
      match shell_node_find_child(node, "variable_name") {
        Some(vn) => out.push((vn.x, node.e))
        None => ()
      }
      return
    }
    for c in node.c {
      walk(c)
    }
  }

  walk(root)
  out
}

///|
/// Every referenced variable name with no visible declaration — neither in
/// `declared` (the caller's merged workflow/job/step `env:` keys, visible
/// for the whole script) nor assigned *earlier* in `root` itself (`FOO=bar`
/// — a `variable_assignment` node whose own span ends before the
/// reference starts) nor a well-known built-in. Position-aware by design:
/// an assignment later in the script doesn't retroactively excuse an
/// earlier use-before-def, which is exactly the class of bug this rule
/// exists to catch. A *prefix* assignment on a named command (`FOO=bar echo
/// hi`) is excluded from what counts as a persistent declaration — see
/// `collect_persistent_assignments`. Dedup'd, AST-visit order.
fn analyze_undefined_vars(
  root : ShellNode,
  declared : Array[String],
) -> Array[String] {
  let assignments = collect_persistent_assignments(root)
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
