///|
/// A tree-sitter-bash parse tree, as bridged from JS via
/// `shell-ts-adapter/index.mjs`'s `serialize()` — target-agnostic, so every
/// shell rule's actual analysis logic can be tested under the default
/// `moon test` (wasm-gc) with a captured JSON snapshot, without a live
/// tree-sitter parse. Only *named* nodes are carried (tree-sitter's stable,
/// public grammar surface); anonymous tokens like a redirect's `>>` operator
/// are recovered from a parent's own `text` instead of as child nodes — see
/// e.g. `shell_node_is_append_redirect`.
///
/// `s`/`e` are UTF-16 code-unit offsets into the (already `${{ }}`-sanitized)
/// script text tree-sitter parsed, matching tree-sitter's own indexing.
priv struct ShellNode {
  t : String
  s : Int
  e : Int
  x : String
  c : Array[ShellNode]
} derive(Debug)

///|
/// Parses the JSON produced by `shell-ts-adapter`'s `parseJson()`. `None` on
/// malformed JSON (defensive only — the adapter is our own code) or an
/// empty/non-object payload.
fn parse_shell_ast(json_str : String) -> ShellNode? {
  let parsed : Json = @json.parse(json_str) catch { _ => Json::null() }
  shell_node_from_json(parsed)
}

///|
fn shell_node_from_json(j : Json) -> ShellNode? {
  match j {
    Object(m) => {
      let t = match m.get("t") {
        Some(String(s)) => s
        _ => return None
      }
      let s = match m.get("s") {
        Some(Number(n, ..)) => n.to_int()
        _ => 0
      }
      let e = match m.get("e") {
        Some(Number(n, ..)) => n.to_int()
        _ => 0
      }
      let x = match m.get("x") {
        Some(String(s)) => s
        _ => ""
      }
      let c : Array[ShellNode] = match m.get("c") {
        Some(Array(items)) => {
          let out : Array[ShellNode] = []
          for item in items {
            match shell_node_from_json(item) {
              Some(n) => out.push(n)
              None => ()
            }
          }
          out
        }
        _ => []
      }
      Some(ShellNode::{ t, s, e, x, c })
    }
    _ => None
  }
}

///|
/// Depth-first pre-order walk. `visit` returning early doesn't prune —
/// every rule so far wants a flat scan, not a cutoff.
fn shell_node_walk(node : ShellNode, visit : (ShellNode) -> Unit) -> Unit {
  visit(node)
  for child in node.c {
    shell_node_walk(child, visit)
  }
}

///|
/// Every descendant (including `node` itself) whose type equals `t`.
fn shell_node_find_all(node : ShellNode, t : String) -> Array[ShellNode] {
  let out : Array[ShellNode] = []
  shell_node_walk(node, fn(n) { if n.t == t { out.push(n) } })
  out
}

///|
/// A `file_redirect` node's own text starts with its (anonymous, so not a
/// child in this tree) operator token — `>>`/`&>>`/`1>>`/... all append;
/// anything else (`>`, `2>`, ...) overwrites. Used because tree-sitter-bash
/// doesn't expose the operator as a named field.
fn shell_node_is_append_redirect(file_redirect : ShellNode) -> Bool {
  let t = file_redirect.x.trim(chars=" \t").to_owned()
  // Skip the descriptor digits (`1>>`, `2>>`) and leading `&`, then look for
  // `>>` at the front of what remains.
  let chars = t.to_array()
  let mut i = 0
  let n = chars.length()
  while i < n && (chars[i] == '&' || (chars[i] >= '0' && chars[i] <= '9')) {
    i = i + 1
  }
  i < n && chars[i] == '>' && i + 1 < n && chars[i + 1] == '>'
}
