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
/// Look up the `(key, value)` entry for `key` in a mapping node.
fn node_get_entry(node : @yaml.Node, key : String) -> (@yaml.Node, @yaml.Node)? {
  match node {
    Mapping(entries, ..) => {
      for e in entries {
        let (k, v) = e
        if k.as_string() is Some(ks) && ks == key {
          return Some((k, v))
        }
      }
      None
    }
    _ => None
  }
}

///|
/// Position for a `key: value` field. When the value sits on the key's own
/// line it is the most precise location (`uses: actions/checkout@v4` points at
/// the ref); when the value spans following lines — a multi-line
/// `permissions:` block, a `run: |` script body — the key itself is what an
/// annotation should point at. Empty values also fall back to the key.
fn entry_field_pos(
  k : @yaml.Node,
  v : @yaml.Node,
  lc : @yaml.LineCounter,
) -> Position {
  let (kl, kc) = k.start_pos(lc)
  let vr = v.range()
  if vr.node_end > vr.start {
    let (vl, vc) = v.start_pos(lc)
    // The value must both start *and* end on the key's line — a `run: |`
    // block scalar starts at the `|` header on the key's line but its body
    // lives below, and should be reported at the key.
    let (el, _) = lc.line_col(vr.node_end - 1)
    if vl == kl && el == kl {
      return Position::{ line: vl, col: vc }
    }
  }
  Position::{ line: kl, col: kc }
}

///|
/// Resolve the position of a job's `key` field, e.g. the `uses:` or
/// `permissions:` field under `jobs.<job>.<key>`. Returns `None` when the
/// positioned parse is unavailable or the field is absent — callers fall back
/// to the job/step node position so `pos` is never lost.
fn job_field_pos(ctx : WalkCtx, job : String, key : String) -> Position? {
  guard ctx.position_root is Some(root) else { return None }
  guard ctx.line_counter is Some(lc) else { return None }
  guard node_get(root, "jobs") is Some(Mapping(entries, ..)) else { None }
  for e in entries {
    let (k, v) = e
    if k.as_string() is Some(ks) && ks == job {
      match node_get_entry(v, key) {
        Some((fk, fv)) => return Some(entry_field_pos(fk, fv, lc))
        None => return None
      }
    }
  }
  None
}

///|
/// Resolve the position of a step's `key` field within its (job or
/// composite-action) steps sequence. `key` may be a plain field (`uses`,
/// `run`) or a `with.<input>` path, resolved into the step's `with:` mapping.
/// Returns `None` when unavailable; callers fall back to the step node.
fn step_field_pos(
  ctx : WalkCtx,
  job : String?,
  step_index : Int,
  key : String,
) -> Position? {
  guard ctx.position_root is Some(root) else { return None }
  guard ctx.line_counter is Some(lc) else { return None }
  guard step_node(root, job, step_index) is Some(step) else { return None }
  let entry = match key.find(".") {
    Some(i) => {
      let head = key[0:i].to_owned()
      let tail = key[i + 1:].to_owned()
      match node_get(step, head) {
        Some(sub) => node_get_entry(sub, tail)
        None => None
      }
    }
    None => node_get_entry(step, key)
  }
  match entry {
    Some((fk, fv)) => Some(entry_field_pos(fk, fv, lc))
    None => None
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
