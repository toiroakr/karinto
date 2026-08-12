///|
/// js-only FFI seam for the tree-sitter-bash shell rules (#113).
///
/// This is deliberately the ONLY js-gated file for this feature (see
/// `shell_ts_ffi_stub.mbt` for the non-js counterpart) — everything else
/// (the JSON-AST type, its parser, and every rule's analysis logic) lives in
/// ordinary target-agnostic `.mbt` files and is exercised by plain `test {
/// }` fixtures under the default `moon test` (wasm-gc), using captured JSON
/// AST snapshots instead of a live parse. That keeps this project's
/// fixture/coverage discipline (`coverage_test.mbt`) honest for these rules
/// too, even though the actual tree-sitter parse only runs under
/// `--target js`.
///
/// All async setup (`Parser.init()` / `Language.load()`) happens in the
/// hand-written `shell-ts-adapter/index.mjs` adapter, awaited once by each
/// host (the Worker's fetch handler, the CLI's entry wrapper,
/// `scripts/test-shell-rules.mjs`) *before* any lint call — never here.
/// `ts_parse_json` only wraps a already-initialized synchronous call
/// (`Parser.parse()` is sync once a language is loaded), and no-ops safely
/// if that never happened (e.g. `moon test --target js`, which reaches this
/// file via the `#module` import below but never awaits the adapter's init).
#module("@karinto/shell-ts-adapter")
extern "js" fn js_ts_is_ready() -> Bool = "isReady"

///|
#module("@karinto/shell-ts-adapter")
extern "js" fn js_ts_parse_json(source : String) -> String = "parseJson"

///|
/// `None` when the adapter was never initialized (safe no-op for callers).
fn ts_parse_json(source : String) -> String? {
  if !js_ts_is_ready() {
    None
  } else {
    Some(js_ts_parse_json(source))
  }
}
