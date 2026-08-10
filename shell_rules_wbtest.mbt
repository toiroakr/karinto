///|
/// Fixture tests for the tree-sitter-bash shell rules (#113), using JSON AST
/// snapshots captured once via `web-tree-sitter`/`tree-sitter-bash` under
/// Node (see `scripts/gen-shell-ast-fixtures.mjs`) and pasted in verbatim —
/// this file needs no live tree-sitter parse, so it runs under the default
/// `moon test` (wasm-gc) same as every other rule's fixtures. The
/// integration seam that actually produces this JSON from a live parse is
/// covered separately by `scripts/test-shell-rules.mjs` (one end-to-end case
/// per rule, run via `npm run test:shell-rules`).

///|
let ghenv_true_positive : String = "{\"t\":\"program\",\"s\":0,\"e\":37,\"x\":\"echo \\\"VAR=$USER_INPUT\\\" >> $GITHUB_ENV\",\"c\":[{\"t\":\"redirected_statement\",\"s\":0,\"e\":37,\"x\":\"echo \\\"VAR=$USER_INPUT\\\" >> $GITHUB_ENV\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":22,\"x\":\"echo \\\"VAR=$USER_INPUT\\\"\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"echo\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"echo\"}]},{\"t\":\"string\",\"s\":5,\"e\":22,\"x\":\"\\\"VAR=$USER_INPUT\\\"\",\"c\":[{\"t\":\"string_content\",\"s\":6,\"e\":10,\"x\":\"VAR=\"},{\"t\":\"simple_expansion\",\"s\":10,\"e\":21,\"x\":\"$USER_INPUT\",\"c\":[{\"t\":\"variable_name\",\"s\":11,\"e\":21,\"x\":\"USER_INPUT\"}]}]}]},{\"t\":\"file_redirect\",\"s\":23,\"e\":37,\"x\":\">> $GITHUB_ENV\",\"c\":[{\"t\":\"simple_expansion\",\"s\":26,\"e\":37,\"x\":\"$GITHUB_ENV\",\"c\":[{\"t\":\"variable_name\",\"s\":27,\"e\":37,\"x\":\"GITHUB_ENV\"}]}]}]}]}"

///|
let ghenv_true_negative : String = "{\"t\":\"program\",\"s\":0,\"e\":34,\"x\":\"echo \\\"VAR=static\\\" >> \\\"$GITHUB_ENV\\\"\",\"c\":[{\"t\":\"redirected_statement\",\"s\":0,\"e\":34,\"x\":\"echo \\\"VAR=static\\\" >> \\\"$GITHUB_ENV\\\"\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":17,\"x\":\"echo \\\"VAR=static\\\"\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"echo\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"echo\"}]},{\"t\":\"string\",\"s\":5,\"e\":17,\"x\":\"\\\"VAR=static\\\"\",\"c\":[{\"t\":\"string_content\",\"s\":6,\"e\":16,\"x\":\"VAR=static\"}]}]},{\"t\":\"file_redirect\",\"s\":18,\"e\":34,\"x\":\">> \\\"$GITHUB_ENV\\\"\",\"c\":[{\"t\":\"string\",\"s\":21,\"e\":34,\"x\":\"\\\"$GITHUB_ENV\\\"\",\"c\":[{\"t\":\"simple_expansion\",\"s\":22,\"e\":33,\"x\":\"$GITHUB_ENV\",\"c\":[{\"t\":\"variable_name\",\"s\":23,\"e\":33,\"x\":\"GITHUB_ENV\"}]}]}]}]}]}"

///|
let ghenv_heredoc_true_positive : String = "{\"t\":\"program\",\"s\":0,\"e\":46,\"x\":\"cat <<EOF >> \\\"$GITHUB_ENV\\\"\\nVAR=$USER_INPUT\\nEOF\",\"c\":[{\"t\":\"redirected_statement\",\"s\":0,\"e\":46,\"x\":\"cat <<EOF >> \\\"$GITHUB_ENV\\\"\\nVAR=$USER_INPUT\\nEOF\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":3,\"x\":\"cat\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":3,\"x\":\"cat\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":3,\"x\":\"cat\"}]}]},{\"t\":\"heredoc_redirect\",\"s\":4,\"e\":46,\"x\":\"<<EOF >> \\\"$GITHUB_ENV\\\"\\nVAR=$USER_INPUT\\nEOF\",\"c\":[{\"t\":\"heredoc_start\",\"s\":6,\"e\":9,\"x\":\"EOF\"},{\"t\":\"file_redirect\",\"s\":10,\"e\":26,\"x\":\">> \\\"$GITHUB_ENV\\\"\",\"c\":[{\"t\":\"string\",\"s\":13,\"e\":26,\"x\":\"\\\"$GITHUB_ENV\\\"\",\"c\":[{\"t\":\"simple_expansion\",\"s\":14,\"e\":25,\"x\":\"$GITHUB_ENV\",\"c\":[{\"t\":\"variable_name\",\"s\":15,\"e\":25,\"x\":\"GITHUB_ENV\"}]}]}]},{\"t\":\"heredoc_body\",\"s\":27,\"e\":43,\"x\":\"VAR=$USER_INPUT\\n\",\"c\":[{\"t\":\"simple_expansion\",\"s\":31,\"e\":42,\"x\":\"$USER_INPUT\",\"c\":[{\"t\":\"variable_name\",\"s\":32,\"e\":42,\"x\":\"USER_INPUT\"}]},{\"t\":\"heredoc_content\",\"s\":43,\"e\":43,\"x\":\"\"}]},{\"t\":\"heredoc_end\",\"s\":43,\"e\":46,\"x\":\"EOF\"}]}]}]}"

///|
/// The improvement over the old line-based regex, which never even looked
/// inside a heredoc body: a quoted heredoc delimiter (`<<'EOF'`) disables
/// expansion, and tree-sitter-bash's grammar already encodes that itself —
/// no `simple_expansion` child nodes appear inside this body at all, so
/// there's nothing extra to special-case here.
let ghenv_heredoc_quoted_safe : String = "{\"t\":\"program\",\"s\":0,\"e\":50,\"x\":\"cat <<'EOF' >> \\\"$GITHUB_ENV\\\"\\nVAR=$NOT_EXPANDED\\nEOF\",\"c\":[{\"t\":\"redirected_statement\",\"s\":0,\"e\":50,\"x\":\"cat <<'EOF' >> \\\"$GITHUB_ENV\\\"\\nVAR=$NOT_EXPANDED\\nEOF\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":3,\"x\":\"cat\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":3,\"x\":\"cat\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":3,\"x\":\"cat\"}]}]},{\"t\":\"heredoc_redirect\",\"s\":4,\"e\":50,\"x\":\"<<'EOF' >> \\\"$GITHUB_ENV\\\"\\nVAR=$NOT_EXPANDED\\nEOF\",\"c\":[{\"t\":\"heredoc_start\",\"s\":6,\"e\":11,\"x\":\"'EOF'\"},{\"t\":\"file_redirect\",\"s\":12,\"e\":28,\"x\":\">> \\\"$GITHUB_ENV\\\"\",\"c\":[{\"t\":\"string\",\"s\":15,\"e\":28,\"x\":\"\\\"$GITHUB_ENV\\\"\",\"c\":[{\"t\":\"simple_expansion\",\"s\":16,\"e\":27,\"x\":\"$GITHUB_ENV\",\"c\":[{\"t\":\"variable_name\",\"s\":17,\"e\":27,\"x\":\"GITHUB_ENV\"}]}]}]},{\"t\":\"heredoc_body\",\"s\":29,\"e\":47,\"x\":\"VAR=$NOT_EXPANDED\\n\"},{\"t\":\"heredoc_end\",\"s\":47,\"e\":50,\"x\":\"EOF\"}]}]}]}"

///|
let ghenv_overwrite_not_append : String = "{\"t\":\"program\",\"s\":0,\"e\":27,\"x\":\"echo \\\"VAR=$X\\\" > $GITHUB_ENV\",\"c\":[{\"t\":\"redirected_statement\",\"s\":0,\"e\":27,\"x\":\"echo \\\"VAR=$X\\\" > $GITHUB_ENV\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":13,\"x\":\"echo \\\"VAR=$X\\\"\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"echo\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"echo\"}]},{\"t\":\"string\",\"s\":5,\"e\":13,\"x\":\"\\\"VAR=$X\\\"\",\"c\":[{\"t\":\"string_content\",\"s\":6,\"e\":10,\"x\":\"VAR=\"},{\"t\":\"simple_expansion\",\"s\":10,\"e\":12,\"x\":\"$X\",\"c\":[{\"t\":\"variable_name\",\"s\":11,\"e\":12,\"x\":\"X\"}]}]}]},{\"t\":\"file_redirect\",\"s\":14,\"e\":27,\"x\":\"> $GITHUB_ENV\",\"c\":[{\"t\":\"simple_expansion\",\"s\":16,\"e\":27,\"x\":\"$GITHUB_ENV\",\"c\":[{\"t\":\"variable_name\",\"s\":17,\"e\":27,\"x\":\"GITHUB_ENV\"}]}]}]}]}"

///|
test "github-env: dynamic content appended to $GITHUB_ENV" {
  let src = "echo \"VAR=$USER_INPUT\" >> $GITHUB_ENV"
  let root = parse_shell_ast(ghenv_true_positive).unwrap()
  assert_eq(analyze_github_env(root, src), Some("GITHUB_ENV"))
}

///|
test "github-env: static content is not flagged" {
  let src = "echo \"VAR=static\" >> \"$GITHUB_ENV\""
  let root = parse_shell_ast(ghenv_true_negative).unwrap()
  assert_eq(analyze_github_env(root, src), None)
}

///|
test "github-env: heredoc body with live expansion is flagged (old regex missed this)" {
  let src = "cat <<EOF >> \"$GITHUB_ENV\"\nVAR=$USER_INPUT\nEOF"
  let root = parse_shell_ast(ghenv_heredoc_true_positive).unwrap()
  assert_eq(analyze_github_env(root, src), Some("GITHUB_ENV"))
}

///|
test "github-env: quoted heredoc delimiter disables expansion" {
  let src = "cat <<'EOF' >> \"$GITHUB_ENV\"\nVAR=$NOT_EXPANDED\nEOF"
  let root = parse_shell_ast(ghenv_heredoc_quoted_safe).unwrap()
  assert_eq(analyze_github_env(root, src), None)
}

///|
let ghenv_heredoc_overwrite_not_append : String = "{\"t\":\"program\",\"s\":0,\"e\":45,\"x\":\"cat <<EOF > \\\"$GITHUB_ENV\\\"\\nVAR=$USER_INPUT\\nEOF\",\"c\":[{\"t\":\"redirected_statement\",\"s\":0,\"e\":45,\"x\":\"cat <<EOF > \\\"$GITHUB_ENV\\\"\\nVAR=$USER_INPUT\\nEOF\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":3,\"x\":\"cat\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":3,\"x\":\"cat\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":3,\"x\":\"cat\"}]}]},{\"t\":\"heredoc_redirect\",\"s\":4,\"e\":45,\"x\":\"<<EOF > \\\"$GITHUB_ENV\\\"\\nVAR=$USER_INPUT\\nEOF\",\"c\":[{\"t\":\"heredoc_start\",\"s\":6,\"e\":9,\"x\":\"EOF\"},{\"t\":\"file_redirect\",\"s\":10,\"e\":25,\"x\":\"> \\\"$GITHUB_ENV\\\"\",\"c\":[{\"t\":\"string\",\"s\":12,\"e\":25,\"x\":\"\\\"$GITHUB_ENV\\\"\",\"c\":[{\"t\":\"simple_expansion\",\"s\":13,\"e\":24,\"x\":\"$GITHUB_ENV\",\"c\":[{\"t\":\"variable_name\",\"s\":14,\"e\":24,\"x\":\"GITHUB_ENV\"}]}]}]},{\"t\":\"heredoc_body\",\"s\":26,\"e\":42,\"x\":\"VAR=$USER_INPUT\\n\",\"c\":[{\"t\":\"simple_expansion\",\"s\":30,\"e\":41,\"x\":\"$USER_INPUT\",\"c\":[{\"t\":\"variable_name\",\"s\":31,\"e\":41,\"x\":\"USER_INPUT\"}]},{\"t\":\"heredoc_content\",\"s\":42,\"e\":42,\"x\":\"\"}]},{\"t\":\"heredoc_end\",\"s\":42,\"e\":45,\"x\":\"EOF\"}]}]}]}"

///|
/// A heredoc *overwrite* (single `>`, not `>>`) must not fire — the same
/// append-only guard the direct-redirect case gets. Without it, this would
/// have been (incorrectly) flagged despite the existing plain `>` test
/// above covering the non-heredoc case.
test "github-env: heredoc overwrite (`>`) is not an append, not flagged" {
  let src = "cat <<EOF > \"$GITHUB_ENV\"\nVAR=$USER_INPUT\nEOF"
  let root = parse_shell_ast(ghenv_heredoc_overwrite_not_append).unwrap()
  assert_eq(analyze_github_env(root, src), None)
}

///|
test "github-env: overwrite (`>`) is not an append, not flagged" {
  let src = "echo \"VAR=$X\" > $GITHUB_ENV"
  let root = parse_shell_ast(ghenv_overwrite_not_append).unwrap()
  assert_eq(analyze_github_env(root, src), None)
}

///|
let ghenv_similarly_named_not_target : String = "{\"t\":\"program\",\"s\":0,\"e\":42,\"x\":\"echo \\\"VAR=$USER_INPUT\\\" >> $GITHUB_ENV_FILE\",\"c\":[{\"t\":\"redirected_statement\",\"s\":0,\"e\":42,\"x\":\"echo \\\"VAR=$USER_INPUT\\\" >> $GITHUB_ENV_FILE\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":22,\"x\":\"echo \\\"VAR=$USER_INPUT\\\"\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"echo\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"echo\"}]},{\"t\":\"string\",\"s\":5,\"e\":22,\"x\":\"\\\"VAR=$USER_INPUT\\\"\",\"c\":[{\"t\":\"string_content\",\"s\":6,\"e\":10,\"x\":\"VAR=\"},{\"t\":\"simple_expansion\",\"s\":10,\"e\":21,\"x\":\"$USER_INPUT\",\"c\":[{\"t\":\"variable_name\",\"s\":11,\"e\":21,\"x\":\"USER_INPUT\"}]}]}]},{\"t\":\"file_redirect\",\"s\":23,\"e\":42,\"x\":\">> $GITHUB_ENV_FILE\",\"c\":[{\"t\":\"simple_expansion\",\"s\":26,\"e\":42,\"x\":\"$GITHUB_ENV_FILE\",\"c\":[{\"t\":\"variable_name\",\"s\":27,\"e\":42,\"x\":\"GITHUB_ENV_FILE\"}]}]}]}]}"

///|
/// `$GITHUB_ENV_FILE` merely *contains* "GITHUB_ENV" as a substring — must
/// not be treated as a write to the real `$GITHUB_ENV`. `github_env_target`
/// matches the `variable_name` node's text exactly, not via `contains`.
test "github-env: a similarly-named-but-different var is not the real target" {
  let src = "echo \"VAR=$USER_INPUT\" >> $GITHUB_ENV_FILE"
  let root = parse_shell_ast(ghenv_similarly_named_not_target).unwrap()
  assert_eq(analyze_github_env(root, src), None)
}

///|
/// The `${{ }}`-sanitization pitfall: the AST is parsed from the
/// *sanitized* script (`${{ … }}` → underscores, so it can't confuse the
/// bash grammar), which means a `${{ github.event... }}` expression
/// embedded directly in `run:` — the classic github-env attack shape —
/// leaves no `simple_expansion` node behind for a pure-AST check to find.
/// `analyze_github_env` also checks the matching span of the *original*
/// (pre-sanitization) source for a literal `${{`, which is what actually
/// catches this case.
let ghenv_sanitized_expr_true_positive : String = "{\"t\":\"program\",\"s\":0,\"e\":66,\"x\":\"echo \\\"TITLE=______________________________________\\\" >> $GITHUB_ENV\",\"c\":[{\"t\":\"redirected_statement\",\"s\":0,\"e\":66,\"x\":\"echo \\\"TITLE=______________________________________\\\" >> $GITHUB_ENV\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":51,\"x\":\"echo \\\"TITLE=______________________________________\\\"\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"echo\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"echo\"}]},{\"t\":\"string\",\"s\":5,\"e\":51,\"x\":\"\\\"TITLE=______________________________________\\\"\",\"c\":[{\"t\":\"string_content\",\"s\":6,\"e\":50,\"x\":\"TITLE=______________________________________\"}]}]},{\"t\":\"file_redirect\",\"s\":52,\"e\":66,\"x\":\">> $GITHUB_ENV\",\"c\":[{\"t\":\"simple_expansion\",\"s\":55,\"e\":66,\"x\":\"$GITHUB_ENV\",\"c\":[{\"t\":\"variable_name\",\"s\":56,\"e\":66,\"x\":\"GITHUB_ENV\"}]}]}]}]}"

///|
test "github-env: a raw ${{ }} expression (not a shell var) is still flagged via the original-source fallback" {
  let sanitized_src = "echo \"TITLE=______________________________________\" >> $GITHUB_ENV"
  let original_src = "echo \"TITLE=${{ github.event.pull_request.title }}\" >> $GITHUB_ENV"
  assert_eq(sanitize_expr_placeholders(original_src), sanitized_src)
  let root = parse_shell_ast(ghenv_sanitized_expr_true_positive).unwrap()
  assert_eq(analyze_github_env(root, original_src), Some("GITHUB_ENV"))
}

///|
let unpinned_curl_pipe_sh : String = "{\"t\":\"program\",\"s\":0,\"e\":40,\"x\":\"curl https://example.com/install.sh | sh\",\"c\":[{\"t\":\"pipeline\",\"s\":0,\"e\":40,\"x\":\"curl https://example.com/install.sh | sh\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":35,\"x\":\"curl https://example.com/install.sh\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"curl\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"curl\"}]},{\"t\":\"word\",\"s\":5,\"e\":35,\"x\":\"https://example.com/install.sh\"}]},{\"t\":\"command\",\"s\":38,\"e\":40,\"x\":\"sh\",\"c\":[{\"t\":\"command_name\",\"s\":38,\"e\":40,\"x\":\"sh\",\"c\":[{\"t\":\"word\",\"s\":38,\"e\":40,\"x\":\"sh\"}]}]}]}]}"

///|
let unpinned_curl_pipe_bash : String = "{\"t\":\"program\",\"s\":0,\"e\":47,\"x\":\"curl -sSL https://example.com/install.sh | bash\",\"c\":[{\"t\":\"pipeline\",\"s\":0,\"e\":47,\"x\":\"curl -sSL https://example.com/install.sh | bash\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":40,\"x\":\"curl -sSL https://example.com/install.sh\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"curl\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"curl\"}]},{\"t\":\"word\",\"s\":5,\"e\":9,\"x\":\"-sSL\"},{\"t\":\"word\",\"s\":10,\"e\":40,\"x\":\"https://example.com/install.sh\"}]},{\"t\":\"command\",\"s\":43,\"e\":47,\"x\":\"bash\",\"c\":[{\"t\":\"command_name\",\"s\":43,\"e\":47,\"x\":\"bash\",\"c\":[{\"t\":\"word\",\"s\":43,\"e\":47,\"x\":\"bash\"}]}]}]}]}"

///|
let unpinned_curl_saved_then_run : String = "{\"t\":\"program\",\"s\":0,\"e\":63,\"x\":\"curl -o install.sh https://example.com/install.sh\\nsh install.sh\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":49,\"x\":\"curl -o install.sh https://example.com/install.sh\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"curl\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"curl\"}]},{\"t\":\"word\",\"s\":5,\"e\":7,\"x\":\"-o\"},{\"t\":\"word\",\"s\":8,\"e\":18,\"x\":\"install.sh\"},{\"t\":\"word\",\"s\":19,\"e\":49,\"x\":\"https://example.com/install.sh\"}]},{\"t\":\"command\",\"s\":50,\"e\":63,\"x\":\"sh install.sh\",\"c\":[{\"t\":\"command_name\",\"s\":50,\"e\":52,\"x\":\"sh\",\"c\":[{\"t\":\"word\",\"s\":50,\"e\":52,\"x\":\"sh\"}]},{\"t\":\"word\",\"s\":53,\"e\":63,\"x\":\"install.sh\"}]}]}"

///|
let unpinned_safe_curl : String = "{\"t\":\"program\",\"s\":0,\"e\":46,\"x\":\"curl -o out.json https://example.com/data.json\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":46,\"x\":\"curl -o out.json https://example.com/data.json\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"curl\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"curl\"}]},{\"t\":\"word\",\"s\":5,\"e\":7,\"x\":\"-o\"},{\"t\":\"word\",\"s\":8,\"e\":16,\"x\":\"out.json\"},{\"t\":\"word\",\"s\":17,\"e\":46,\"x\":\"https://example.com/data.json\"}]}]}"

///|
let unpinned_wget_pipe_sh : String = "{\"t\":\"program\",\"s\":0,\"e\":45,\"x\":\"wget -qO- https://example.com/install.sh | sh\",\"c\":[{\"t\":\"pipeline\",\"s\":0,\"e\":45,\"x\":\"wget -qO- https://example.com/install.sh | sh\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":40,\"x\":\"wget -qO- https://example.com/install.sh\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"wget\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"wget\"}]},{\"t\":\"word\",\"s\":5,\"e\":9,\"x\":\"-qO-\"},{\"t\":\"word\",\"s\":10,\"e\":40,\"x\":\"https://example.com/install.sh\"}]},{\"t\":\"command\",\"s\":43,\"e\":45,\"x\":\"sh\",\"c\":[{\"t\":\"command_name\",\"s\":43,\"e\":45,\"x\":\"sh\",\"c\":[{\"t\":\"word\",\"s\":43,\"e\":45,\"x\":\"sh\"}]}]}]}]}"

///|
test "unpinned-tools: curl piped straight to sh" {
  let root = parse_shell_ast(unpinned_curl_pipe_sh).unwrap()
  assert_true(analyze_unpinned_tools(root))
}

///|
test "unpinned-tools: curl piped straight to bash" {
  let root = parse_shell_ast(unpinned_curl_pipe_bash).unwrap()
  assert_true(analyze_unpinned_tools(root))
}

///|
test "unpinned-tools: wget piped straight to sh" {
  let root = parse_shell_ast(unpinned_wget_pipe_sh).unwrap()
  assert_true(analyze_unpinned_tools(root))
}

///|
test "unpinned-tools: curl saved to disk then run separately is out of scope (matches old behavior)" {
  let root = parse_shell_ast(unpinned_curl_saved_then_run).unwrap()
  assert_false(analyze_unpinned_tools(root))
}

///|
test "unpinned-tools: plain curl download is not flagged" {
  let root = parse_shell_ast(unpinned_safe_curl).unwrap()
  assert_false(analyze_unpinned_tools(root))
}

///|
let unpinned_curl_pipe_sudo_bash : String = "{\"t\":\"program\",\"s\":0,\"e\":47,\"x\":\"curl https://example.com/install.sh | sudo bash\",\"c\":[{\"t\":\"pipeline\",\"s\":0,\"e\":47,\"x\":\"curl https://example.com/install.sh | sudo bash\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":35,\"x\":\"curl https://example.com/install.sh\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"curl\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"curl\"}]},{\"t\":\"word\",\"s\":5,\"e\":35,\"x\":\"https://example.com/install.sh\"}]},{\"t\":\"command\",\"s\":38,\"e\":47,\"x\":\"sudo bash\",\"c\":[{\"t\":\"command_name\",\"s\":38,\"e\":42,\"x\":\"sudo\",\"c\":[{\"t\":\"word\",\"s\":38,\"e\":42,\"x\":\"sudo\"}]},{\"t\":\"word\",\"s\":43,\"e\":47,\"x\":\"bash\"}]}]}]}"

///|
/// The pipeline's last *command_name* is `sudo`, not `bash` — the old
/// naive "last command_name is a shell" check would have missed this.
/// `command_shell_name` sees through the wrapper to `sudo`'s first
/// non-flag argument.
test "unpinned-tools: curl piped to sudo bash is still flagged" {
  let root = parse_shell_ast(unpinned_curl_pipe_sudo_bash).unwrap()
  assert_true(analyze_unpinned_tools(root))
}

///|
let unpinned_curl_pipe_env_assignment_bash : String = "{\"t\":\"program\",\"s\":0,\"e\":54,\"c\":[{\"t\":\"pipeline\",\"s\":0,\"e\":54,\"c\":[{\"t\":\"command\",\"s\":0,\"e\":35,\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"curl\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"curl\"}]},{\"t\":\"word\",\"s\":5,\"e\":35,\"x\":\"https://example.com/install.sh\"}]},{\"t\":\"command\",\"s\":38,\"e\":54,\"c\":[{\"t\":\"command_name\",\"s\":38,\"e\":41,\"x\":\"env\",\"c\":[{\"t\":\"word\",\"s\":38,\"e\":41,\"x\":\"env\"}]},{\"t\":\"word\",\"s\":42,\"e\":49,\"x\":\"FOO=bar\"},{\"t\":\"word\",\"s\":50,\"e\":54,\"x\":\"bash\"}]}]}]}"

///|
/// `env FOO=bar bash` — `env`'s own `NAME=VALUE` assignment syntax, not a
/// `-`-prefixed flag. `command_shell_name` must skip `FOO=bar` too, or it
/// mistakes the assignment for the shell name and never reaches `bash`.
test "unpinned-tools: curl piped to env with a NAME=VALUE assignment before bash is still flagged" {
  let root = parse_shell_ast(unpinned_curl_pipe_env_assignment_bash).unwrap()
  assert_true(analyze_unpinned_tools(root))
}

///|
let unpinned_curl_pipe_env_dash_u_bash : String = "{\"t\":\"program\",\"s\":0,\"e\":54,\"c\":[{\"t\":\"pipeline\",\"s\":0,\"e\":54,\"c\":[{\"t\":\"command\",\"s\":0,\"e\":35,\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"curl\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"curl\"}]},{\"t\":\"word\",\"s\":5,\"e\":35,\"x\":\"https://example.com/install.sh\"}]},{\"t\":\"command\",\"s\":38,\"e\":54,\"c\":[{\"t\":\"command_name\",\"s\":38,\"e\":41,\"x\":\"env\",\"c\":[{\"t\":\"word\",\"s\":38,\"e\":41,\"x\":\"env\"}]},{\"t\":\"word\",\"s\":42,\"e\":44,\"x\":\"-u\"},{\"t\":\"word\",\"s\":45,\"e\":49,\"x\":\"PATH\"},{\"t\":\"word\",\"s\":50,\"e\":54,\"x\":\"bash\"}]}]}]}"

///|
/// `env -u PATH bash` — `-u` takes `PATH` as its own argument (unset that
/// var before running the command), so `PATH` must not be mistaken for the
/// shell name; `command_shell_name` needs to skip both tokens to reach
/// `bash`.
test "unpinned-tools: curl piped to env -u PATH bash (flag with its own argument) is still flagged" {
  let root = parse_shell_ast(unpinned_curl_pipe_env_dash_u_bash).unwrap()
  assert_true(analyze_unpinned_tools(root))
}

///|
let unpinned_curl_pipe_sudo_dash_u_bash : String = "{\"t\":\"program\",\"s\":0,\"e\":55,\"c\":[{\"t\":\"pipeline\",\"s\":0,\"e\":55,\"c\":[{\"t\":\"command\",\"s\":0,\"e\":35,\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"curl\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"curl\"}]},{\"t\":\"word\",\"s\":5,\"e\":35,\"x\":\"https://example.com/install.sh\"}]},{\"t\":\"command\",\"s\":38,\"e\":55,\"c\":[{\"t\":\"command_name\",\"s\":38,\"e\":42,\"x\":\"sudo\",\"c\":[{\"t\":\"word\",\"s\":38,\"e\":42,\"x\":\"sudo\"}]},{\"t\":\"word\",\"s\":43,\"e\":45,\"x\":\"-u\"},{\"t\":\"word\",\"s\":46,\"e\":50,\"x\":\"root\"},{\"t\":\"word\",\"s\":51,\"e\":55,\"x\":\"bash\"}]}]}]}"

///|
/// `sudo -u root bash` — same issue as `env -u`: `-u`'s argument (`root`)
/// must not be mistaken for the shell name.
test "unpinned-tools: curl piped to sudo -u root bash (flag with its own argument) is still flagged" {
  let root = parse_shell_ast(unpinned_curl_pipe_sudo_dash_u_bash).unwrap()
  assert_true(analyze_unpinned_tools(root))
}

///|
let unredacted_base64_pipe : String = "{\"t\":\"program\",\"s\":0,\"e\":26,\"x\":\"echo \\\"$MY_SECRET\\\" | base64\",\"c\":[{\"t\":\"pipeline\",\"s\":0,\"e\":26,\"x\":\"echo \\\"$MY_SECRET\\\" | base64\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":17,\"x\":\"echo \\\"$MY_SECRET\\\"\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"echo\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"echo\"}]},{\"t\":\"string\",\"s\":5,\"e\":17,\"x\":\"\\\"$MY_SECRET\\\"\",\"c\":[{\"t\":\"simple_expansion\",\"s\":6,\"e\":16,\"x\":\"$MY_SECRET\",\"c\":[{\"t\":\"variable_name\",\"s\":7,\"e\":16,\"x\":\"MY_SECRET\"}]}]}]},{\"t\":\"command\",\"s\":20,\"e\":26,\"x\":\"base64\",\"c\":[{\"t\":\"command_name\",\"s\":20,\"e\":26,\"x\":\"base64\",\"c\":[{\"t\":\"word\",\"s\":20,\"e\":26,\"x\":\"base64\"}]}]}]}]}"

///|
let unredacted_plain_echo : String = "{\"t\":\"program\",\"s\":0,\"e\":17,\"x\":\"echo \\\"$MY_SECRET\\\"\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":17,\"x\":\"echo \\\"$MY_SECRET\\\"\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"echo\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"echo\"}]},{\"t\":\"string\",\"s\":5,\"e\":17,\"x\":\"\\\"$MY_SECRET\\\"\",\"c\":[{\"t\":\"simple_expansion\",\"s\":6,\"e\":16,\"x\":\"$MY_SECRET\",\"c\":[{\"t\":\"variable_name\",\"s\":7,\"e\":16,\"x\":\"MY_SECRET\"}]}]}]}]}"

///|
let unredacted_xxd_pipe : String = "{\"t\":\"program\",\"s\":0,\"e\":19,\"x\":\"echo \\\"$TOKEN\\\" | xxd\",\"c\":[{\"t\":\"pipeline\",\"s\":0,\"e\":19,\"x\":\"echo \\\"$TOKEN\\\" | xxd\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":13,\"x\":\"echo \\\"$TOKEN\\\"\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"echo\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"echo\"}]},{\"t\":\"string\",\"s\":5,\"e\":13,\"x\":\"\\\"$TOKEN\\\"\",\"c\":[{\"t\":\"simple_expansion\",\"s\":6,\"e\":12,\"x\":\"$TOKEN\",\"c\":[{\"t\":\"variable_name\",\"s\":7,\"e\":12,\"x\":\"TOKEN\"}]}]}]},{\"t\":\"command\",\"s\":16,\"e\":19,\"x\":\"xxd\",\"c\":[{\"t\":\"command_name\",\"s\":16,\"e\":19,\"x\":\"xxd\",\"c\":[{\"t\":\"word\",\"s\":16,\"e\":19,\"x\":\"xxd\"}]}]}]}]}"

///|
test "unredacted-secrets: piped through base64" {
  let root = parse_shell_ast(unredacted_base64_pipe).unwrap()
  assert_eq(analyze_unredacted_secrets(root), Some("base64"))
}

///|
test "unredacted-secrets: piped through xxd" {
  let root = parse_shell_ast(unredacted_xxd_pipe).unwrap()
  assert_eq(analyze_unredacted_secrets(root), Some("xxd"))
}

///|
test "unredacted-secrets: no pipe at all is not flagged" {
  let root = parse_shell_ast(unredacted_plain_echo).unwrap()
  assert_eq(analyze_unredacted_secrets(root), None)
}

///|
let publish_twine_upload : String = "{\"t\":\"program\",\"s\":0,\"e\":29,\"x\":\"python -m twine upload dist/*\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":29,\"x\":\"python -m twine upload dist/*\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":6,\"x\":\"python\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":6,\"x\":\"python\"}]},{\"t\":\"word\",\"s\":7,\"e\":9,\"x\":\"-m\"},{\"t\":\"word\",\"s\":10,\"e\":15,\"x\":\"twine\"},{\"t\":\"word\",\"s\":16,\"e\":22,\"x\":\"upload\"},{\"t\":\"word\",\"s\":23,\"e\":29,\"x\":\"dist/*\"}]}]}"

///|
let publish_npm_publish : String = "{\"t\":\"program\",\"s\":0,\"e\":11,\"x\":\"npm publish\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":11,\"x\":\"npm publish\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":3,\"x\":\"npm\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":3,\"x\":\"npm\"}]},{\"t\":\"word\",\"s\":4,\"e\":11,\"x\":\"publish\"}]}]}"

///|
let publish_npm_dry_run : String = "{\"t\":\"program\",\"s\":0,\"e\":21,\"x\":\"npm publish --dry-run\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":21,\"x\":\"npm publish --dry-run\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":3,\"x\":\"npm\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":3,\"x\":\"npm\"}]},{\"t\":\"word\",\"s\":4,\"e\":11,\"x\":\"publish\"},{\"t\":\"word\",\"s\":12,\"e\":21,\"x\":\"--dry-run\"}]}]}"

///|
test "use-trusted-publishing: python -m twine upload" {
  let root = parse_shell_ast(publish_twine_upload).unwrap()
  assert_true(analyze_trusted_publishing(root))
}

///|
test "use-trusted-publishing: npm publish" {
  let root = parse_shell_ast(publish_npm_publish).unwrap()
  assert_true(analyze_trusted_publishing(root))
}

///|
test "use-trusted-publishing: npm publish --dry-run is not a real publish" {
  let root = parse_shell_ast(publish_npm_dry_run).unwrap()
  assert_false(analyze_trusted_publishing(root))
}

///|
let publish_cargo_publish : String = "{\"t\":\"program\",\"s\":0,\"e\":13,\"x\":\"cargo publish\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":13,\"x\":\"cargo publish\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":5,\"x\":\"cargo\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":5,\"x\":\"cargo\"}]},{\"t\":\"word\",\"s\":6,\"e\":13,\"x\":\"publish\"}]}]}"

///|
let publish_cargo_dry_run : String = "{\"t\":\"program\",\"s\":0,\"e\":23,\"x\":\"cargo publish --dry-run\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":23,\"x\":\"cargo publish --dry-run\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":5,\"x\":\"cargo\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":5,\"x\":\"cargo\"}]},{\"t\":\"word\",\"s\":6,\"e\":13,\"x\":\"publish\"},{\"t\":\"word\",\"s\":14,\"e\":23,\"x\":\"--dry-run\"}]}]}"

///|
let publish_bun_publish : String = "{\"t\":\"program\",\"s\":0,\"e\":11,\"x\":\"bun publish\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":11,\"x\":\"bun publish\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":3,\"x\":\"bun\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":3,\"x\":\"bun\"}]},{\"t\":\"word\",\"s\":4,\"e\":11,\"x\":\"publish\"}]}]}"

///|
let publish_gem_push : String = "{\"t\":\"program\",\"s\":0,\"e\":25,\"x\":\"gem push my-gem-1.0.0.gem\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":25,\"x\":\"gem push my-gem-1.0.0.gem\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":3,\"x\":\"gem\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":3,\"x\":\"gem\"}]},{\"t\":\"word\",\"s\":4,\"e\":8,\"x\":\"push\"},{\"t\":\"word\",\"s\":9,\"e\":25,\"x\":\"my-gem-1.0.0.gem\"}]}]}"

///|
let publish_dotnet_nuget_push : String = "{\"t\":\"program\",\"s\":0,\"e\":31,\"x\":\"dotnet nuget push package.nupkg\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":31,\"x\":\"dotnet nuget push package.nupkg\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":6,\"x\":\"dotnet\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":6,\"x\":\"dotnet\"}]},{\"t\":\"word\",\"s\":7,\"e\":12,\"x\":\"nuget\"},{\"t\":\"word\",\"s\":13,\"e\":17,\"x\":\"push\"},{\"t\":\"word\",\"s\":18,\"e\":31,\"x\":\"package.nupkg\"}]}]}"

///|
let publish_poetry_publish : String = "{\"t\":\"program\",\"s\":0,\"e\":14,\"x\":\"poetry publish\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":14,\"x\":\"poetry publish\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":6,\"x\":\"poetry\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":6,\"x\":\"poetry\"}]},{\"t\":\"word\",\"s\":7,\"e\":14,\"x\":\"publish\"}]}]}"

///|
let publish_uv_publish : String = "{\"t\":\"program\",\"s\":0,\"e\":10,\"x\":\"uv publish\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":10,\"x\":\"uv publish\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":2,\"x\":\"uv\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":2,\"x\":\"uv\"}]},{\"t\":\"word\",\"s\":3,\"e\":10,\"x\":\"publish\"}]}]}"

///|
let publish_uvx_twine_upload : String = "{\"t\":\"program\",\"s\":0,\"e\":23,\"x\":\"uvx twine upload dist/*\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":23,\"x\":\"uvx twine upload dist/*\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":3,\"x\":\"uvx\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":3,\"x\":\"uvx\"}]},{\"t\":\"word\",\"s\":4,\"e\":9,\"x\":\"twine\"},{\"t\":\"word\",\"s\":10,\"e\":16,\"x\":\"upload\"},{\"t\":\"word\",\"s\":17,\"e\":23,\"x\":\"dist/*\"}]}]}"

///|
test "use-trusted-publishing: cargo publish" {
  let root = parse_shell_ast(publish_cargo_publish).unwrap()
  assert_true(analyze_trusted_publishing(root))
}

///|
test "use-trusted-publishing: cargo publish --dry-run is not a real publish" {
  let root = parse_shell_ast(publish_cargo_dry_run).unwrap()
  assert_false(analyze_trusted_publishing(root))
}

///|
test "use-trusted-publishing: bun publish" {
  let root = parse_shell_ast(publish_bun_publish).unwrap()
  assert_true(analyze_trusted_publishing(root))
}

///|
test "use-trusted-publishing: gem push" {
  let root = parse_shell_ast(publish_gem_push).unwrap()
  assert_true(analyze_trusted_publishing(root))
}

///|
test "use-trusted-publishing: dotnet nuget push" {
  let root = parse_shell_ast(publish_dotnet_nuget_push).unwrap()
  assert_true(analyze_trusted_publishing(root))
}

///|
test "use-trusted-publishing: poetry publish" {
  let root = parse_shell_ast(publish_poetry_publish).unwrap()
  assert_true(analyze_trusted_publishing(root))
}

///|
test "use-trusted-publishing: uv publish" {
  let root = parse_shell_ast(publish_uv_publish).unwrap()
  assert_true(analyze_trusted_publishing(root))
}

///|
test "use-trusted-publishing: uvx twine upload" {
  let root = parse_shell_ast(publish_uvx_twine_upload).unwrap()
  assert_true(analyze_trusted_publishing(root))
}

///|
/// `text_has_publish_cmd` is the non-bash fallback (pwsh/cmd, where a real
/// tree-sitter-bash parse isn't applicable) — a plain `npm publish` is an
/// ordinary executable invocation with no shell-specific syntax, so it must
/// still be recognized without an AST.
test "use-trusted-publishing (text fallback): plain npm publish is flagged" {
  assert_true(text_has_publish_cmd("npm publish"))
}

///|
/// Same dlx false-positive protection as the AST path
/// (`command_is_publish`'s doc comment): `pnpm dlx pkg-pr-new publish`'s
/// `publish` belongs to the dlx'd tool, not to pnpm itself —
/// `first_non_flag_word(rest)` for `pnpm` sees `dlx`, not `publish`.
test "use-trusted-publishing (text fallback): pnpm dlx pkg-pr-new publish is not a real publish" {
  assert_false(
    text_has_publish_cmd("pnpm dlx pkg-pr-new@0.0.78 publish --compact"),
  )
}

///|
/// `;`/`&&`/`||`-chained lines are split into segments so a publish
/// command after a `cd`/build step is still caught.
test "use-trusted-publishing (text fallback): chained command after && is flagged" {
  assert_true(text_has_publish_cmd("cd dist && npm publish"))
}

///|
test "use-trusted-publishing (text fallback): a plain download is not flagged" {
  assert_false(
    text_has_publish_cmd("Invoke-WebRequest -Uri https://example.com/a.txt"),
  )
}

///|
let publish_npm_dry_run_quoted : String = "{\"t\":\"program\",\"s\":0,\"e\":23,\"c\":[{\"t\":\"command\",\"s\":0,\"e\":23,\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":3,\"x\":\"npm\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":3,\"x\":\"npm\"}]},{\"t\":\"word\",\"s\":4,\"e\":11,\"x\":\"publish\"},{\"t\":\"string\",\"s\":12,\"e\":23,\"x\":\"\\\"--dry-run\\\"\",\"c\":[{\"t\":\"string_content\",\"s\":13,\"e\":22,\"x\":\"--dry-run\"}]}]}]}"

///|
/// A quoted `"--dry-run"` must still be recognized as the dry-run flag —
/// `command_words`/`string_literal_text` strip the surrounding quotes
/// before comparing, instead of matching the raw `string` node text
/// (`"--dry-run"` with quotes) against the literal token `--dry-run`.
test "use-trusted-publishing: a quoted --dry-run flag is still recognized" {
  let root = parse_shell_ast(publish_npm_dry_run_quoted).unwrap()
  assert_false(analyze_trusted_publishing(root))
}

///|
let publish_pkg_pr_new_dlx : String = "{\"t\":\"program\",\"s\":0,\"e\":61,\"x\":\"pnpm dlx pkg-pr-new@0.0.78 publish --commentWithSha --compact\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":61,\"x\":\"pnpm dlx pkg-pr-new@0.0.78 publish --commentWithSha --compact\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"pnpm\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"pnpm\"}]},{\"t\":\"word\",\"s\":5,\"e\":8,\"x\":\"dlx\"},{\"t\":\"word\",\"s\":9,\"e\":26,\"x\":\"pkg-pr-new@0.0.78\"},{\"t\":\"word\",\"s\":27,\"e\":34,\"x\":\"publish\"},{\"t\":\"word\",\"s\":35,\"e\":51,\"x\":\"--commentWithSha\"},{\"t\":\"word\",\"s\":52,\"e\":61,\"x\":\"--compact\"}]}]}"

///|
let publish_pkg_pr_new_dlx_yflag : String = "{\"t\":\"program\",\"s\":0,\"e\":47,\"x\":\"pnpm dlx -y pkg-pr-new@0.0.78 publish --compact\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":47,\"x\":\"pnpm dlx -y pkg-pr-new@0.0.78 publish --compact\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"pnpm\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"pnpm\"}]},{\"t\":\"word\",\"s\":5,\"e\":8,\"x\":\"dlx\"},{\"t\":\"word\",\"s\":9,\"e\":11,\"x\":\"-y\"},{\"t\":\"word\",\"s\":12,\"e\":29,\"x\":\"pkg-pr-new@0.0.78\"},{\"t\":\"word\",\"s\":30,\"e\":37,\"x\":\"publish\"},{\"t\":\"word\",\"s\":38,\"e\":47,\"x\":\"--compact\"}]}]}"

///|
let publish_npm_exec_yes : String = "{\"t\":\"program\",\"s\":0,\"e\":46,\"x\":\"npm exec --yes pkg-pr-new -- publish --compact\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":46,\"x\":\"npm exec --yes pkg-pr-new -- publish --compact\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":3,\"x\":\"npm\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":3,\"x\":\"npm\"}]},{\"t\":\"word\",\"s\":4,\"e\":8,\"x\":\"exec\"},{\"t\":\"word\",\"s\":9,\"e\":14,\"x\":\"--yes\"},{\"t\":\"word\",\"s\":15,\"e\":25,\"x\":\"pkg-pr-new\"},{\"t\":\"word\",\"s\":26,\"e\":28,\"x\":\"--\"},{\"t\":\"word\",\"s\":29,\"e\":36,\"x\":\"publish\"},{\"t\":\"word\",\"s\":37,\"e\":46,\"x\":\"--compact\"}]}]}"

///|
let publish_dlx_then_real_publish : String = "{\"t\":\"program\",\"s\":0,\"e\":60,\"x\":\"pnpm dlx pkg-pr-new@0.0.78 publish --compact && pnpm publish\",\"c\":[{\"t\":\"list\",\"s\":0,\"e\":60,\"x\":\"pnpm dlx pkg-pr-new@0.0.78 publish --compact && pnpm publish\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":44,\"x\":\"pnpm dlx pkg-pr-new@0.0.78 publish --compact\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"pnpm\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"pnpm\"}]},{\"t\":\"word\",\"s\":5,\"e\":8,\"x\":\"dlx\"},{\"t\":\"word\",\"s\":9,\"e\":26,\"x\":\"pkg-pr-new@0.0.78\"},{\"t\":\"word\",\"s\":27,\"e\":34,\"x\":\"publish\"},{\"t\":\"word\",\"s\":35,\"e\":44,\"x\":\"--compact\"}]},{\"t\":\"command\",\"s\":48,\"e\":60,\"x\":\"pnpm publish\",\"c\":[{\"t\":\"command_name\",\"s\":48,\"e\":52,\"x\":\"pnpm\",\"c\":[{\"t\":\"word\",\"s\":48,\"e\":52,\"x\":\"pnpm\"}]},{\"t\":\"word\",\"s\":53,\"e\":60,\"x\":\"publish\"}]}]}]}"

///|
test "use-trusted-publishing: pnpm dlx pkg-pr-new preview publish is not a registry publish" {
  let root = parse_shell_ast(publish_pkg_pr_new_dlx).unwrap()
  assert_false(analyze_trusted_publishing(root))
}

///|
test "use-trusted-publishing: pnpm dlx -y pkg-pr-new is still recognized as dlx (not pnpm's own publish)" {
  let root = parse_shell_ast(publish_pkg_pr_new_dlx_yflag).unwrap()
  assert_false(analyze_trusted_publishing(root))
}

///|
test "use-trusted-publishing: npm exec --yes pkg is not npm's own publish" {
  let root = parse_shell_ast(publish_npm_exec_yes).unwrap()
  assert_false(analyze_trusted_publishing(root))
}

///|
test "use-trusted-publishing: a real publish chained after a pkg-pr-new dlx still fires" {
  let root = parse_shell_ast(publish_dlx_then_real_publish).unwrap()
  assert_true(analyze_trusted_publishing(root))
}

///|
test "sanitize_expr_placeholders: keeps offsets stable" {
  let src = "echo ${{ inputs.x }} done"
  let out = sanitize_expr_placeholders(src)
  assert_eq(out.length(), src.length())
  assert_eq(out, "echo _______________ done")
}

///|
test "sanitize_expr_placeholders: no-op without any ${{ }}" {
  assert_eq(sanitize_expr_placeholders("echo hi"), "echo hi")
}

///|
let quote_unsafe_unquoted : String = "{\"t\":\"program\",\"s\":0,\"e\":11,\"x\":\"echo $TITLE\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":11,\"x\":\"echo $TITLE\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"echo\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"echo\"}]},{\"t\":\"simple_expansion\",\"s\":5,\"e\":11,\"x\":\"$TITLE\",\"c\":[{\"t\":\"variable_name\",\"s\":6,\"e\":11,\"x\":\"TITLE\"}]}]}]}"

///|
let quote_safe_quoted : String = "{\"t\":\"program\",\"s\":0,\"e\":13,\"x\":\"echo \\\"$TITLE\\\"\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":13,\"x\":\"echo \\\"$TITLE\\\"\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"echo\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"echo\"}]},{\"t\":\"string\",\"s\":5,\"e\":13,\"x\":\"\\\"$TITLE\\\"\",\"c\":[{\"t\":\"simple_expansion\",\"s\":6,\"e\":12,\"x\":\"$TITLE\",\"c\":[{\"t\":\"variable_name\",\"s\":7,\"e\":12,\"x\":\"TITLE\"}]}]}]}]}"

///|
let quote_safe_unrelated_var : String = "{\"t\":\"program\",\"s\":0,\"e\":11,\"x\":\"echo $OTHER\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":11,\"x\":\"echo $OTHER\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"echo\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"echo\"}]},{\"t\":\"simple_expansion\",\"s\":5,\"e\":11,\"x\":\"$OTHER\",\"c\":[{\"t\":\"variable_name\",\"s\":6,\"e\":11,\"x\":\"OTHER\"}]}]}]}"

///|
test "shell-quote-safety: unquoted expansion of a dynamic env var is flagged" {
  let root = parse_shell_ast(quote_unsafe_unquoted).unwrap()
  assert_eq(analyze_quote_safety(root, ["TITLE"]), ["TITLE"])
}

///|
test "shell-quote-safety: quoted expansion is safe" {
  let root = parse_shell_ast(quote_safe_quoted).unwrap()
  assert_eq(analyze_quote_safety(root, ["TITLE"]), [])
}

///|
test "shell-quote-safety: unquoted expansion of an unrelated (non-dynamic) var is not flagged" {
  let root = parse_shell_ast(quote_safe_unrelated_var).unwrap()
  assert_eq(analyze_quote_safety(root, ["TITLE"]), [])
}

///|
let undef_unknown_ref : String = "{\"t\":\"program\",\"s\":0,\"e\":17,\"x\":\"echo $MYSTERY_VAR\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":17,\"x\":\"echo $MYSTERY_VAR\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"echo\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"echo\"}]},{\"t\":\"simple_expansion\",\"s\":5,\"e\":17,\"x\":\"$MYSTERY_VAR\",\"c\":[{\"t\":\"variable_name\",\"s\":6,\"e\":17,\"x\":\"MYSTERY_VAR\"}]}]}]}"

///|
let undef_assigned_first : String = "{\"t\":\"program\",\"s\":0,\"e\":17,\"x\":\"FOO=bar\\necho $FOO\",\"c\":[{\"t\":\"variable_assignment\",\"s\":0,\"e\":7,\"x\":\"FOO=bar\",\"c\":[{\"t\":\"variable_name\",\"s\":0,\"e\":3,\"x\":\"FOO\"},{\"t\":\"word\",\"s\":4,\"e\":7,\"x\":\"bar\"}]},{\"t\":\"command\",\"s\":8,\"e\":17,\"x\":\"echo $FOO\",\"c\":[{\"t\":\"command_name\",\"s\":8,\"e\":12,\"x\":\"echo\",\"c\":[{\"t\":\"word\",\"s\":8,\"e\":12,\"x\":\"echo\"}]},{\"t\":\"simple_expansion\",\"s\":13,\"e\":17,\"x\":\"$FOO\",\"c\":[{\"t\":\"variable_name\",\"s\":14,\"e\":17,\"x\":\"FOO\"}]}]}]}"

///|
let undef_well_known : String = "{\"t\":\"program\",\"s\":0,\"e\":16,\"x\":\"echo $GITHUB_SHA\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":16,\"x\":\"echo $GITHUB_SHA\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"echo\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"echo\"}]},{\"t\":\"simple_expansion\",\"s\":5,\"e\":16,\"x\":\"$GITHUB_SHA\",\"c\":[{\"t\":\"variable_name\",\"s\":6,\"e\":16,\"x\":\"GITHUB_SHA\"}]}]}]}"

///|
test "shell-undefined-var: reference with no declared source is flagged" {
  let root = parse_shell_ast(undef_unknown_ref).unwrap()
  assert_eq(analyze_undefined_vars(root, []), ["MYSTERY_VAR"])
}

///|
test "shell-undefined-var: a variable assigned earlier in the same script is not flagged" {
  let root = parse_shell_ast(undef_assigned_first).unwrap()
  assert_eq(analyze_undefined_vars(root, []), [])
}

///|
let undef_used_before_assigned : String = "{\"t\":\"program\",\"s\":0,\"e\":17,\"x\":\"echo $FOO\\nFOO=bar\",\"c\":[{\"t\":\"command\",\"s\":0,\"e\":9,\"x\":\"echo $FOO\",\"c\":[{\"t\":\"command_name\",\"s\":0,\"e\":4,\"x\":\"echo\",\"c\":[{\"t\":\"word\",\"s\":0,\"e\":4,\"x\":\"echo\"}]},{\"t\":\"simple_expansion\",\"s\":5,\"e\":9,\"x\":\"$FOO\",\"c\":[{\"t\":\"variable_name\",\"s\":6,\"e\":9,\"x\":\"FOO\"}]}]},{\"t\":\"variable_assignment\",\"s\":10,\"e\":17,\"x\":\"FOO=bar\",\"c\":[{\"t\":\"variable_name\",\"s\":10,\"e\":13,\"x\":\"FOO\"},{\"t\":\"word\",\"s\":14,\"e\":17,\"x\":\"bar\"}]}]}"

///|
/// Position-aware: an assignment *later* in the script doesn't excuse a use
/// that comes before it — `echo $FOO` on line 1, `FOO=bar` on line 2.
test "shell-undefined-var: a use before its assignment is still flagged" {
  let root = parse_shell_ast(undef_used_before_assigned).unwrap()
  assert_eq(analyze_undefined_vars(root, []), ["FOO"])
}

///|
let undef_prefix_assignment_does_not_persist : String = "{\"t\":\"program\",\"s\":0,\"e\":25,\"c\":[{\"t\":\"command\",\"s\":0,\"e\":15,\"c\":[{\"t\":\"variable_assignment\",\"s\":0,\"e\":7,\"c\":[{\"t\":\"variable_name\",\"s\":0,\"e\":3,\"x\":\"FOO\"},{\"t\":\"word\",\"s\":4,\"e\":7,\"x\":\"bar\"}]},{\"t\":\"command_name\",\"s\":8,\"e\":12,\"x\":\"echo\",\"c\":[{\"t\":\"word\",\"s\":8,\"e\":12,\"x\":\"echo\"}]},{\"t\":\"word\",\"s\":13,\"e\":15,\"x\":\"hi\"}]},{\"t\":\"command\",\"s\":16,\"e\":25,\"c\":[{\"t\":\"command_name\",\"s\":16,\"e\":20,\"x\":\"echo\",\"c\":[{\"t\":\"word\",\"s\":16,\"e\":20,\"x\":\"echo\"}]},{\"t\":\"simple_expansion\",\"s\":21,\"e\":25,\"c\":[{\"t\":\"variable_name\",\"s\":22,\"e\":25,\"x\":\"FOO\"}]}]}]}"

///|
/// `FOO=bar echo hi` is a *prefix* assignment scoped to that one `echo`
/// invocation's environment — it does not persist for the next statement,
/// unlike a bare `FOO=bar` line (see `undef_assigned_first` above). The
/// later `echo $FOO` must still be flagged as undefined.
test "shell-undefined-var: a prefix assignment on a command (FOO=bar echo hi) does not persist to later statements" {
  let root = parse_shell_ast(undef_prefix_assignment_does_not_persist).unwrap()
  assert_eq(analyze_undefined_vars(root, []), ["FOO"])
}

///|
test "shell-undefined-var: a declared env: key is not flagged" {
  let root = parse_shell_ast(undef_unknown_ref).unwrap()
  assert_eq(analyze_undefined_vars(root, ["MYSTERY_VAR"]), [])
}

///|
test "shell-undefined-var: a well-known GITHUB_* context var is not flagged" {
  let root = parse_shell_ast(undef_well_known).unwrap()
  assert_eq(analyze_undefined_vars(root, []), [])
}
