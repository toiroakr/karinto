///|
/// Non-js counterpart of `shell_ts_ffi.mbt` — native/wasm-gc builds have no
/// tree-sitter runtime, so the shell rules that depend on it just see no
/// AST and no-op, the same as they do on the js target whenever the host
/// never awaited the adapter's init. See `shell_ts_ffi.mbt` for the full
/// architecture note.
fn ts_parse_json(_source : String) -> String? {
  None
}
