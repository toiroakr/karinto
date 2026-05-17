///|
/// JS entry point for the Cloudflare Worker.
///
/// Takes the YAML content, file kind hint (`"workflow"` | `"action"` | `""`),
/// a comma-separated `disable` glob list, and a CSV of `uses:` refs the
/// caller already knows are vulnerable (e.g. fetched from OSV.dev). Returns
/// a JSON string with the lint diagnostics and metadata.

///|
pub fn lint_string(
  content : String,
  kind_str : String,
  disable_str : String,
  vuln_uses_str : String,
) -> String {
  let kind = match kind_str {
    "workflow" => @curllint.FileKind::Workflow
    "action" => @curllint.FileKind::Action
    _ => @curllint.FileKind::Unknown
  }
  let disabled = split_csv(disable_str)
  let vuln_uses = split_csv(vuln_uses_str)
  let result = @curllint.lint(content, kind~, disabled~, vuln_uses~)
  let body : Map[String, Json] = {
    "ok": (result.parse_error is None).to_json(),
    "result": result.to_json(),
  }
  body.to_json().stringify()
}

///|
fn split_csv(s : String) -> Array[String] {
  if s == "" {
    return []
  }
  let out : Array[String] = []
  let buf = StringBuilder::new()
  for ch in s {
    if ch == ',' {
      let piece = buf.to_string().trim(chars=" \t").to_owned()
      if piece != "" {
        out.push(piece)
      }
      buf.reset()
    } else {
      buf.write_char(ch)
    }
  }
  let last = buf.to_string().trim(chars=" \t").to_owned()
  if last != "" {
    out.push(last)
  }
  out
}
