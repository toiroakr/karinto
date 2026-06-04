///|
/// Source-position lookup for diagnostics.
///
/// Positions come from the `yamlpos` parser's position-carrying `Node` tree
/// (`parse_with_positions`), which records each node's source offsets and
/// resolves line/column lazily via a `LineCounter`. `fill_positions` is the
/// final engine pass: it stamps `Diagnostic::pos` onto findings already tied to
/// a concrete job or step (a job finding resolves to the job key node, a step
/// finding to the step entry node). Workflow-global findings are left
/// untouched.

///|
/// Look up the value node for `key` in a mapping node.
fn node_get(node : @yaml.Node, key : String) -> @yaml.Node? {
  match node {
    Mapping(entries, ..) => {
      for e in entries {
        let (k, v) = e
        if k.as_string() is Some(ks) && ks == key {
          return Some(v)
        }
      }
      None
    }
    _ => None
  }
}

///|
/// The key node for job `name` under `jobs:` (so its position is the job key).
fn job_key_node(root : @yaml.Node, name : String) -> @yaml.Node? {
  guard node_get(root, "jobs") is Some(Mapping(entries, ..)) else { None }
  for e in entries {
    let (k, _) = e
    if k.as_string() is Some(ks) && ks == name {
      return Some(k)
    }
  }
  None
}

///|
/// The `steps:` sequence for a workflow job, or the composite action's
/// `runs.steps:` when `job` is `None`.
fn steps_seq(root : @yaml.Node, job : String?) -> @yaml.Node? {
  let holder = match job {
    Some(name) => {
      guard node_get(root, "jobs") is Some(Mapping(entries, ..)) else { None }
      let mut found : @yaml.Node? = None
      for e in entries {
        let (k, v) = e
        if k.as_string() is Some(ks) && ks == name {
          found = Some(v)
          break
        }
      }
      found
    }
    None => node_get(root, "runs")
  }
  match holder {
    Some(h) => node_get(h, "steps")
    None => None
  }
}

///|
/// The step item node at `index` within its (job or action) steps sequence.
fn step_node(root : @yaml.Node, job : String?, index : Int) -> @yaml.Node? {
  match steps_seq(root, job) {
    Some(Sequence(items, ..)) =>
      if index >= 0 && index < items.length() {
        Some(items[index])
      } else {
        None
      }
    _ => None
  }
}

///|
/// Stamp `pos` onto every diagnostic tied to a concrete job or step that has no
/// explicit position yet, resolving line/column from the `yamlpos` node tree.
fn fill_positions(
  out : Array[Diagnostic],
  position_root : @yaml.Node?,
  lc : @yaml.LineCounter,
) -> Unit {
  guard position_root is Some(root) else { return }
  let mut k = 0
  while k < out.length() {
    let d = out[k]
    if d.pos is None {
      let node = match d.step {
        Some(s) => step_node(root, d.job, s.index)
        None =>
          match d.job {
            Some(j) => job_key_node(root, j)
            None => None
          }
      }
      match node {
        Some(n) => {
          let (line, col) = n.start_pos(lc)
          out[k] = Diagnostic::{ ..d, pos: Some(Position::{ line, col }) }
        }
        None => ()
      }
    }
    k = k + 1
  }
}
